import CoreML
import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

/// 기기에서 노래를 직접 분석해 음절 단위 가사 싱크를 만든다.
/// 보컬 분리(UVR-MDX-NET-Voc_FT)와 강제 정렬(MMS-300m) 모델은 처음 한 번 받아 둔다(약 350MB).
@MainActor
@Observable
final class AlignerModelStore {
    static let shared = AlignerModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded

    struct ModelFile {
        let name: String
        /// 릴리스 자산 이름 → mlpackage 안 경로
        let files: [(asset: String, path: String)]
        let approxBytes: Int64
    }

    static let releaseBase = URL(string: "https://github.com/Chltmddn752/Tune/releases/download/aligner-models-v3/")!
    static let models: [ModelFile] = ["VocalSeparator", "LyricsAligner"].map { name in
        ModelFile(name: name, files: [
            ("\(name).Manifest.json", "Manifest.json"),
            ("\(name).model.mlmodel", "Data/com.apple.CoreML/model.mlmodel"),
            ("\(name).weight.bin", "Data/com.apple.CoreML/weights/weight.bin"),
        ], approxBytes: name == "VocalSeparator" ? 33_000_000 : 340_000_000)
    }
    static var totalBytes: Int64 { models.reduce(0) { $0 + $1.approxBytes } }

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Aligner", isDirectory: true)
    }

    nonisolated static func compiledURL(_ name: String) -> URL { folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true) }

    private init() {
        refresh()
    }

    func refresh() {
        if case .downloading = state { return }
        if state == .preparing { return }
        let ready = Self.models.allSatisfy { FileManager.default.fileExists(atPath: Self.compiledURL($0.name).path) }
        state = ready ? .ready : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    var sizeOnDisk: Int64 {
        guard let e = FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// 모델을 받아서 이 기기용으로 컴파일해 둔다.
    func download() async {
        if case .downloading = state { return }
        if state == .preparing || state == .ready { return }
        state = .downloading(0)
        let activity = ActivityCenter.shared.begin(title: "단어 싱크 모델 받기", symbol: "arrow.down.circle", total: 100)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            var done: Int64 = 0
            for model in Self.models where !fm.fileExists(atPath: Self.compiledURL(model.name).path) {
                let package = Self.folder.appendingPathComponent("\(model.name).mlpackage", isDirectory: true)
                try? fm.removeItem(at: package)
                for file in model.files {
                    let target = package.appendingPathComponent(file.path)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let base = done
                    let temp = try await FileDownloader.downloadWithRetry(Self.releaseBase.appendingPathComponent(file.asset)) { written in
                        Task { @MainActor in
                            let fraction = Double(base + written) / Double(Self.totalBytes)
                            self.state = .downloading(min(fraction, 0.99))
                            ActivityCenter.shared.update(activity, completed: Int(fraction * 100))
                        }
                    }
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: temp, to: target)
                    done += Int64((try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0)
                }
                state = .preparing
                ActivityCenter.shared.update(activity, detail: "이 기기에 맞게 준비하는 중")
                let compiled = try await MLModel.compileModel(at: package)
                let destination = Self.compiledURL(model.name)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: compiled, to: destination)
                try? fm.removeItem(at: package)
                state = .downloading(Double(done) / Double(Self.totalBytes))
            }
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var folder = Self.folder
            try? folder.setResourceValues(excluded)
            state = .ready
            ActivityCenter.shared.finish(activity, message: "단어 싱크 모델을 받았어요")
        } catch {
            state = .failed(error.localizedDescription)
            ActivityCenter.shared.fail(activity, message: "모델을 받지 못했어요: \(error.localizedDescription)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notDownloaded
    }

    /// 모델 두 개를 불러온다(무거우니 일이 끝나면 버린다).
    nonisolated static func loadModels() throws -> (separator: MLModel, aligner: MLModel) {
        do {
            let separatorConfig = MLModelConfiguration()
            separatorConfig.computeUnits = .all
            let alignerConfig = MLModelConfiguration()
            // 큰 트랜스포머는 Neural Engine 준비가 오래 걸리고 실패하기도 해서 GPU로 돌린다.
            alignerConfig.computeUnits = .cpuAndGPU
            let separator = try MLModel(contentsOf: compiledURL("VocalSeparator"), configuration: separatorConfig)
            let aligner = try MLModel(contentsOf: compiledURL("LyricsAligner"), configuration: alignerConfig)
            return (separator, aligner)
        } catch {
            throw AlignerError.model(error.localizedDescription)
        }
    }
}

/// 진행률을 알려 주는 단순 다운로드
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Int64) -> Void

    private init(onProgress: @escaping (Int64) -> Void) {
        self.onProgress = onProgress
    }

    /// 연결이 끊기면 3번까지 다시 받는다.
    static func downloadWithRetry(_ url: URL, onProgress: @escaping (Int64) -> Void) async throws -> URL {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do { return try await download(url, onProgress: onProgress) } catch {
                lastError = error
                if (error as? URLError)?.code == .badServerResponse { break }
                try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw lastError
    }

    static func download(_ url: URL, onProgress: @escaping (Int64) -> Void) async throws -> URL {
        let delegate = FileDownloader(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            return
        }
        // 이 함수가 끝나면 임시 파일이 지워지므로 옮겨 둔다.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

/// 곡을 분석해 정렬한 가사를 저장해 둔 가사로 넣는다.
@MainActor
enum AutoSync {
    static let sourceName = "Tune 정렬"

    enum Outcome {
        case done(words: Int, seconds: Double)
        case noLyrics
        case modelsMissing
        case failed(String)
    }

    private(set) static var isRunning = false
    private static var cancelled = false

    /// 한 곡 분석. progress(0…1, 단계 설명)
    static func align(_ track: Track, context: ModelContext,
                      models: (separator: MLModel, aligner: MLModel)? = nil,
                      progress: @escaping (Double, String) -> Void = { _, _ in }) async -> Outcome {
        guard AlignerModelStore.shared.isReady else { return .modelsMissing }
        let item = QueueItem(track)
        if CloudFiles.isExternal(item.fileURL), !CloudFiles.isDownloaded(item.fileURL) {
            _ = await CloudFiles.ensureDownloaded(item.fileURL)
        }
        let (loaded, _) = await LyricsService.load(for: item, context: context)
        guard var lyrics = loaded, !lyrics.lines.isEmpty || !lyrics.plainText.isEmpty else { return .noLyrics }
        // 표시용 전체 보정은 되돌린다(곡별 보정은 원래 가사의 시간을 고친 것이라 그대로 쓴다).
        if lyrics.isSynced { lyrics = LyricsService.shifted(lyrics, by: -LyricsService.globalTimingOffset) }

        // 정렬할 줄(배경 보컬 줄은 빼고, 나중에 원래 시간으로 붙인다)
        var lines: [CTCAligner.Line] = []
        var sourceWords: [(Double, Double)?] = []
        var background: [AlignedTTML.Background] = []
        if lyrics.isSynced {
            for line in lyrics.lines {
                if line.isBackground {
                    if !lines.isEmpty {
                        background.append(.init(afterLine: lines.count - 1,
                                                words: line.words.map { ($0.text, $0.start, $0.end) }))
                    }
                    continue
                }
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                lines.append(.init(text: text, start: line.start, end: max(line.end, line.start + 0.5)))
                sourceWords.append(contentsOf: wordTimes(line, wordCount: text.split(whereSeparator: { $0.isWhitespace }).count))
            }
        } else {
            for text in lyrics.plainText.components(separatedBy: .newlines) {
                let t = text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(.init(text: t, start: nil, end: nil)) }
            }
        }
        guard !lines.isEmpty else { return .noLyrics }
        let source: [(Double, Double)?]? = sourceWords.contains { $0 != nil } ? sourceWords : nil
        let url = item.fileURL

        let result: Result<AlignerPipeline.Output, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let m = try models ?? AlignerModelStore.loadModels()
                let pipeline = AlignerPipeline(separator: m.separator, aligner: m.aligner)
                pipeline.isCancelled = { AutoSync.cancelledFlag.value }
                pipeline.progress = { stage, value in
                    let (fraction, label): (Double, String) = switch stage {
                    case .separating: (value * 0.6, "목소리 분리하는 중")
                    case .listening: (0.6 + value * 0.35, "가사 듣는 중")
                    case .aligning: (0.95 + value * 0.05, "맞추는 중")
                    }
                    Task { @MainActor in progress(fraction, label) }
                }
                return .success(try pipeline.run(audioURL: url, lines: lines, sourceWords: source))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .failure(let error):
            return .failed(error.localizedDescription)
        case .success(let output):
            let timed = output.words.filter { $0.start != nil }
            guard !timed.isEmpty else { return .failed("가사와 목소리를 맞추지 못했어요") }
            let ttml = AlignedTTML.build(output.words, lineCount: lines.count, background: background)
            save(ttml, for: track.id, context: context)
            return .done(words: timed.count, seconds: output.seconds)
        }
    }

    /// 원래 가사의 단어 시간(있을 때만). 음절 조각은 띄어쓰기 기준으로 합친다.
    private static func wordTimes(_ line: LyricLine, wordCount: Int) -> [(Double, Double)?] {
        let none = [(Double, Double)?](repeating: nil, count: wordCount)
        guard line.hasWordTiming else { return none }
        var words: [(Double, Double)] = []
        var current: (Double, Double)?
        for token in line.words {
            if current == nil { current = (token.start, token.end) } else { current!.1 = token.end }
            if token.text.hasSuffix(" ") { words.append(current!); current = nil }
        }
        if let current { words.append(current) }
        return words.count == wordCount ? words.map { $0 } : none
    }

    private static func save(_ ttml: String, for id: UUID, context: ModelContext) {
        var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        let cached = try? context.fetch(descriptor).first
        let entry = cached ?? LyricsCache(trackID: id, raw: ttml, format: "ttml", source: sourceName)
        entry.raw = ttml
        entry.format = "ttml"
        entry.source = sourceName
        entry.offset = 0
        entry.fetchedAt = .now
        if cached == nil { context.insert(entry) }
        try? context.save()
        NotificationCenter.default.post(name: .tuneLyricsReplaced, object: id)
    }

    /// 다른 스레드에서 읽는 멈춤 표시
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
    nonisolated static let cancelledFlag = Flag()

    /// 여러 곡을 차례로. 진행 상황은 알림 센터에.
    @discardableResult
    static func run(_ tracks: [Track], context: ModelContext) -> Bool {
        guard !isRunning, !tracks.isEmpty, AlignerModelStore.shared.isReady else { return false }
        isRunning = true
        cancelledFlag.value = false
        let single = tracks.count == 1
        let activity = ActivityCenter.shared.begin(
            title: single ? "단어 싱크 만들기" : "단어 싱크 만들기 (\(tracks.count)곡)",
            symbol: "waveform", total: 100, detail: tracks.first?.title,
            onCancel: { AutoSync.cancelledFlag.value = true }
        )
        let background = UIApplication.shared.beginBackgroundTask(withName: "AutoSync") {}
        Task { @MainActor in
            var done = 0, missing = 0
            var failure: String?
            let models: (separator: MLModel, aligner: MLModel)?
            do {
                models = try await Task.detached { try AlignerModelStore.loadModels() }.value
            } catch {
                models = nil
                failure = error.localizedDescription
            }
            if let models {
                for (index, track) in tracks.enumerated() {
                    if cancelledFlag.value { failure = "멈췄어요"; break }
                    // 진행 안내는 숫자나 단계가 바뀔 때만 바꾼다(화면을 덜 다시 그리게).
                    var shown = (percent: -1, label: "")
                    let outcome = await align(track, context: context, models: models) { fraction, label in
                        let percent = Int((Double(index) + fraction) / Double(tracks.count) * 100)
                        guard percent != shown.percent || label != shown.label else { return }
                        shown = (percent, label)
                        ActivityCenter.shared.update(activity, completed: percent,
                                                     detail: single ? label : "\(track.title) · \(label)")
                    }
                    switch outcome {
                    case .done: done += 1
                    case .noLyrics: missing += 1
                    case .modelsMissing: failure = "모델이 없어요"
                    case .failed(let message): failure = message
                    }
                    if failure != nil, !single, failure != "멈췄어요" {
                        // 한 곡 실패는 건너뛰고 계속한다.
                        failure = nil
                    }
                    if failure != nil { break }
                }
            }
            isRunning = false
            UIApplication.shared.endBackgroundTask(background)
            if let failure, done == 0 {
                ActivityCenter.shared.fail(activity, message: failure)
            } else {
                var parts = ["\(done)곡 맞춤"]
                if missing > 0 { parts.append("\(missing)곡은 가사가 없음") }
                if let failure { parts.append(failure) }
                ActivityCenter.shared.finish(activity, message: parts.joined(separator: " · "))
            }
        }
        return true
    }
}

/// 곡 메뉴: 기기에서 분석해 음절 단위 싱크 만들기
struct AutoSyncButton: View {
    let tracks: [Track]
    var title = "정확한 단어 싱크 만들기"

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            let store = AlignerModelStore.shared
            store.refresh()
            guard store.isReady else {
                toasts.show("설정 › 가사 › 정확한 단어 싱크에서 분석 모델을 먼저 받아 주세요", symbol: "arrow.down.circle")
                return
            }
            if AutoSync.run(tracks, context: modelContext) {
                toasts.show(tracks.count == 1 ? "곡을 분석하기 시작했어요. 진행 상황은 알림에서 볼 수 있어요"
                                              : "\(tracks.count)곡을 분석하기 시작했어요", symbol: "waveform")
            } else {
                toasts.show(tracks.isEmpty ? "분석할 곡이 없어요" : "이미 분석하는 중이에요")
            }
        } label: {
            Label(title, systemImage: "waveform")
        }
    }
}

/// 설정 › 가사: 분석 모델 받기·지우기
struct AlignerSettingsSection: View {
    @State private var store = AlignerModelStore.shared
    @State private var confirmDelete = false

    var body: some View {
        M3SectionTitle(title: "정확한 단어 싱크")
        M3Group {
            switch store.state {
            case .notDownloaded, .failed:
                Button {
                    Task { await store.download() }
                } label: {
                    M3Row(title: "분석 모델 받기", subtitle: "약 \(ByteCountFormatter.string(fromByteCount: AlignerModelStore.totalBytes, countStyle: .file)) · 와이파이에서 받는 걸 추천해요",
                          systemImage: "arrow.down.circle") {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.m3OnSurfaceVariant.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                if case .failed(let message) = store.state {
                    Text("받지 못했어요: \(message)")
                        .font(.m3BodySmall)
                        .foregroundStyle(.red)
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    M3Row(title: "분석 모델 받는 중", systemImage: "arrow.down.circle") {
                        Text("\(Int(fraction * 100))%")
                            .font(.m3BodyMedium.monospacedDigit())
                            .foregroundStyle(Color.m3Primary)
                    }
                    ProgressView(value: fraction)
                }
            case .preparing:
                M3Row(title: "이 기기에 맞게 준비하는 중", systemImage: "gearshape.2") {
                    ProgressView()
                }
            case .ready:
                M3Row(title: "분석 모델 준비됨",
                      subtitle: ByteCountFormatter.string(fromByteCount: store.sizeOnDisk, countStyle: .file),
                      systemImage: "checkmark.circle") { EmptyView() }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    M3Row(title: "분석 모델 지우기", systemImage: "trash") { EmptyView() }
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { store.refresh() }
        .confirmationDialog("분석 모델을 지울까요? 이미 만든 단어 싱크는 그대로 남아요.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("지우기", role: .destructive) { store.delete() }
            Button("취소", role: .cancel) {}
        }
        M3Footnote(text: "곡을 길게 누르거나 ⋯ 메뉴에서 '정확한 단어 싱크 만들기'를 고르면, 기기에서 노래의 목소리만 분리해 듣고 가사를 음절마다 맞춰요. 길게 끄는 음도 실제로 부르는 동안만 칠해져요. 한 곡에 1분 안팎 걸리고, 만든 싱크는 가사 파일보다 먼저 쓰여요. 한국어·영어에 맞춰 두었어요.")
    }
}
