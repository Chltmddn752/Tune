import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    var jobs: [DownloadJob] = []
    var activeJobID: UUID?
    var lastMessage: String?

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var currentBox: ProviderClientBox?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        load()
    }

    var activeJob: DownloadJob? {
        guard let activeJobID else { return nil }
        return jobs.first { $0.id == activeJobID }
    }

    var finishedJobs: [DownloadJob] {
        jobs.filter { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }

    func attach(context: ModelContext) {
        modelContext = context
        if jobs.contains(where: { $0.status == .running }) {
            recoverInterruptedJobs()
        }
        startNext()
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(track: ProviderTrack, extension installed: InstalledExtension, quality: String? = nil) -> UUID {
        if let existing = jobs.first(where: {
            $0.providerID == installed.id && $0.trackID == track.trackID && $0.isActive
        }) {
            lastMessage = "이미 대기열에 있어요."
            return existing.id
        }
        let job = DownloadJob(
            id: UUID(),
            providerID: installed.id,
            providerName: installed.title,
            trackID: track.trackID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumArtist: track.albumArtist,
            durationMs: track.durationMs,
            coverURL: track.coverURL,
            isrc: track.isrc,
            quality: quality ?? ExtensionStore.shared.defaultQuality(for: installed),
            status: .queued,
            progress: 0,
            statusText: "대기 중",
            error: nil,
            createdAt: .now,
            finishedAt: nil,
            relativePath: nil,
            preparedContext: track.preparedContext,
            tagWarning: nil
        )
        jobs.insert(job, at: 0)
        saveNow()
        // 보관함 연결 전에 눌렀으면 대기열에만 두고, 연결되면 시작한다.
        if modelContext != nil { startNext() }
        return job.id
    }

    func cancel(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].isActive else { return }
        if jobs[index].status == .queued {
            jobs[index].status = .cancelled
            jobs[index].statusText = "취소됨"
            jobs[index].finishedAt = .now
            saveNow()
            return
        }
        jobs[index].status = .cancelled
        jobs[index].statusText = "취소 중"
        jobs[index].error = "사용자가 취소했어요."
        currentBox?.cancel()
        saveNow()
    }

    func retry(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].status != .running else { return }
        jobs[index].status = .queued
        jobs[index].progress = 0
        jobs[index].statusText = "대기 중"
        jobs[index].error = nil
        jobs[index].finishedAt = nil
        jobs[index].relativePath = nil
        jobs[index].tagWarning = nil
        saveNow()
        if modelContext != nil { startNext() }
    }

    func remove(_ jobID: UUID) {
        if activeJobID == jobID {
            currentBox?.cancel()
            currentBox = nil
            endBackgroundTask()
            activeJobID = nil
        }
        try? FileManager.default.removeItem(at: ExtensionPaths.downloads.appendingPathComponent(jobID.uuidString))
        jobs.removeAll { $0.id == jobID }
        saveNow()
        if activeJobID == nil { startNext() }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        saveNow()
    }

    func startNext() {
        guard activeJobID == nil else { return }
        // jobs는 최신순이라, 가장 먼저 넣은 곡(뒤쪽)부터 받는다.
        guard let index = jobs.lastIndex(where: { $0.status == .queued }) else { return }
        let job = jobs[index]
        jobs[index].status = .running
        jobs[index].statusText = "준비 중"
        jobs[index].progress = 0
        activeJobID = job.id
        saveNow()
        Task { await run(job) }
    }

    // MARK: - Worker

    private func run(_ job: DownloadJob) async {
        guard let context = modelContext else {
            finish(job.id, error: "보관함을 열 수 없어요.")
            return
        }
        guard let installed = ExtensionStore.shared.installedExtension(id: job.providerID) else {
            finish(job.id, error: "확장을 찾을 수 없어요. 다시 설치해 주세요.")
            return
        }

        let staging = ExtensionPaths.staging(for: job.id)
        let output = staging.appendingPathComponent("track.flac")
        let box = ProviderClientBox()
        var movedFile: URL?
        currentBox = box
        beginBackgroundTask()

        do {
            let environment = try ExtensionStore.shared.providerEnvironment(for: installed)
            let track = ProviderTrack(
                providerID: job.providerID,
                trackID: job.trackID,
                title: job.title,
                artist: job.artist,
                album: job.album,
                albumArtist: job.albumArtist,
                durationMs: job.durationMs,
                coverURL: job.coverURL,
                isrc: job.isrc,
                preparedContext: job.preparedContext
            )
            let jobID = job.id
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    DownloadManager.shared.updateProgress(jobID, value: value)
                }
            }
            let logger: @Sendable (String, String) -> Void = { level, message in
                #if DEBUG
                print("[Extension \(environment.installed.id)] \(level): \(message)")
                #endif
            }

            let result = try await Self.performDownload(
                environment: environment,
                staging: staging,
                track: track,
                quality: job.quality,
                output: output,
                box: box,
                progress: progress,
                logger: logger
            )
            guard !box.isCancelled,
                  jobs.contains(where: { $0.id == job.id && $0.status != .cancelled }) else {
                finish(job.id, error: "사용자가 취소했어요.", cancelled: true)
                return
            }

            let destination = try moveToLibrary(result, job: job)
            movedFile = destination
            // 보관함 폴더를 지켜보는 감시자가 같은 파일을 먼저 집어가지 않게 잠깐 가린다.
            LibraryImporter.suppressedPaths.insert(destination.standardizedFileURL.path)
            defer {
                LibraryImporter.suppressedPaths.remove(destination.standardizedFileURL.path)
            }

            let artwork = await artworkData(result.metadata.coverURL ?? job.coverURL)
            let tagResult = await MetadataWriter.write(
                tags(from: result.metadata, job: job, cover: artwork),
                to: destination
            )
            guard await MetadataReader.isPlayable(destination) else {
                throw ProviderError.downloadFailed("내려받은 파일을 재생할 수 없어요.")
            }
            guard !box.isCancelled, jobs.contains(where: { $0.id == job.id && $0.status != .cancelled }) else {
                if let movedFile { try? FileManager.default.removeItem(at: movedFile) }
                finish(job.id, error: "사용자가 취소했어요.", cancelled: true)
                return
            }
            let importer = LibraryImporter()
            guard let imported = await importer.importDownloaded(
                file: destination,
                metadata: result.metadata,
                artworkData: artwork,
                context: context
            ) else {
                throw ProviderError.downloadFailed("보관함에 넣지 못했어요.")
            }
            movedFile = nil

            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].status = .completed
                jobs[index].progress = 1
                jobs[index].statusText = "완료"
                jobs[index].relativePath = imported.relativePath
                jobs[index].finishedAt = .now
                jobs[index].error = nil
                jobs[index].tagWarning = tagResult.warning
            }
            lastMessage = "\(imported.title) 다운로드 완료"
            try? FileManager.default.removeItem(at: staging)
            finishWorker(job.id)
        } catch {
            if let movedFile { try? FileManager.default.removeItem(at: movedFile) }
            finish(job.id, error: error.localizedDescription)
        }
    }

    nonisolated private static func performDownload(
        environment: ProviderEnvironment,
        staging: URL,
        track: ProviderTrack,
        quality: String,
        output: URL,
        box: ProviderClientBox,
        progress: @escaping @Sendable (Double) -> Void,
        logger: @escaping @Sendable (String, String) -> Void
    ) async throws -> ProviderDownloadResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let client = try ProviderClient(
                        environment: environment,
                        staging: staging,
                        progress: progress,
                        logger: logger
                    )
                    box.set(client)
                    let result = try client.download(track, quality: quality, output: output)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func updateProgress(_ jobID: UUID, value: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].status == .running else { return }
        jobs[index].progress = max(0, min(1, value))
        jobs[index].statusText = "\(Int((jobs[index].progress * 100).rounded()))%"
        if Date().timeIntervalSince(lastSave) > 0.5 { saveNow() }
    }

    private func finish(_ jobID: UUID, error: String, cancelled: Bool = false) {
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            if cancelled || jobs[index].status == .cancelled {
                jobs[index].status = .cancelled
                jobs[index].statusText = "취소됨"
            } else {
                jobs[index].status = .failed
                jobs[index].statusText = "실패"
            }
            jobs[index].error = error
            jobs[index].finishedAt = .now
        }
        try? FileManager.default.removeItem(at: ExtensionPaths.downloads.appendingPathComponent(jobID.uuidString))
        finishWorker(jobID)
    }

    private func finishWorker(_ jobID: UUID) {
        guard activeJobID == jobID else {
            // 이미 목록에서 뺐거나 다음 작업이 시작됐으면 새 작업의 상태를 건드리지 않는다.
            saveNow()
            return
        }
        endBackgroundTask()
        currentBox = nil
        activeJobID = nil
        saveNow()
        startNext()
    }

    private func moveToLibrary(_ result: ProviderDownloadResult, job: DownloadJob) throws -> URL {
        let source = URL(fileURLWithPath: result.filePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw ProviderError.outputMissing }
        let libraryRoot = ExtensionPaths.libraryDownloads.standardizedFileURL.path
        if source.standardizedFileURL.path.hasPrefix(libraryRoot + "/") { return source }

        let fileExtension = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let artist = result.metadata.artist.isEmpty ? job.artist : result.metadata.artist
        let title = result.metadata.title.isEmpty ? job.title : result.metadata.title
        let base = Self.safeFilename("\(artist) - \(title)")
        var destination = ExtensionPaths.libraryDownloads.appendingPathComponent("\(base).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = ExtensionPaths.libraryDownloads.appendingPathComponent("\(base) (\(counter)).\(fileExtension)")
            counter += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private func tags(from metadata: DownloadedMetadata, job: DownloadJob, cover: Data?) -> MetadataWriter.Tags {
        var tags = MetadataWriter.Tags()
        tags.title = metadata.title.isEmpty ? job.title : metadata.title
        tags.artist = metadata.artist.isEmpty ? job.artist : metadata.artist
        tags.album = metadata.album.isEmpty ? job.album : metadata.album
        tags.albumArtist = metadata.albumArtist.isEmpty
            ? (tags.artist.isEmpty ? job.albumArtist : tags.artist)
            : metadata.albumArtist
        tags.trackNumber = metadata.trackNumber
        tags.trackTotal = nil
        tags.discNumber = metadata.discNumber
        tags.discTotal = nil
        tags.year = metadata.year
        tags.genre = metadata.genre ?? ""
        tags.isrc = metadata.isrc ?? job.isrc ?? ""
        tags.cover = cover
        return tags
    }

    private func artworkData(_ urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Tune/\(ExtensionStore.appVersion) (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count < 8 * 1024 * 1024 else { return nil }
        return data
    }

    static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var result = value.components(separatedBy: invalid).joined(separator: " ")
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if result.isEmpty { result = "다운로드" }
        if result.count > 120 { result = String(result.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return result
    }

    // MARK: - Persistence

    private static var jobsURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tune", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("download-jobs.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.jobsURL),
              let decoded = try? JSONDecoder().decode([DownloadJob].self, from: data) else {
            jobs = []
            return
        }
        jobs = decoded
        recoverInterruptedJobs()
    }

    private func recoverInterruptedJobs() {
        var changed = false
        for index in jobs.indices where jobs[index].status == .running {
            jobs[index].status = .failed
            jobs[index].statusText = "중단됨"
            jobs[index].error = "앱이 다시 시작되어 멈췄어요. 다시 시도해 주세요."
            jobs[index].progress = 0
            jobs[index].finishedAt = .now
            changed = true
        }
        if activeJobID != nil { activeJobID = nil }
        if changed { saveNow() }
        currentBox = nil
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: Self.jobsURL, options: .atomic)
        lastSave = Date()
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TuneDownload") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

final class ProviderClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var client: ProviderClient?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ client: ProviderClient) {
        lock.lock()
        self.client = client
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { client.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = client
        lock.unlock()
        current?.cancel()
    }
}
