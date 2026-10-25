import Foundation
import Observation
import SwiftData

/// 보관함에 이미 들어온 곡들의 파일 태그를 Tune 정보로 다시 쓴다.
/// 다운로드할 때 하는 태그 정리를, 예전에 가져온 곡에도 한 번에 적용하는 용도다.
@MainActor
@Observable
final class LibraryTagger {
    static let shared = LibraryTagger()

    var isRunning = false
    var done = 0
    var total = 0
    var written = 0
    var skipped = 0
    var unsupported = 0
    var failed = 0
    var currentTitle: String?
    var lastResult: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var unsupportedFormats = Set<String>()
    @ObservationIgnored private var failureMessages: [String] = []

    private init() {}

    func start(context: ModelContext) {
        guard !isRunning else { return }
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        guard !tracks.isEmpty else {
            lastResult = "정리할 곡이 없어요."
            return
        }

        isRunning = true
        done = 0
        total = tracks.count
        written = 0
        skipped = 0
        unsupported = 0
        failed = 0
        currentTitle = nil
        lastResult = nil
        unsupportedFormats = []
        failureMessages = []

        task = Task { [weak self] in
            guard let self else { return }
            await self.run(tracks, context: context)
        }
    }

    func cancel() {
        task?.cancel()
        if isRunning { lastResult = "중단하는 중…" }
    }

    private func run(_ tracks: [Track], context: ModelContext) async {
        var completed = 0
        for track in tracks {
            if Task.isCancelled { break }
            currentTitle = track.title
            switch await write(track) {
            case .written:
                written += 1
            case .skipped:
                skipped += 1
            case .unsupported(let format):
                unsupported += 1
                unsupportedFormats.insert(format)
            case .failed(let message):
                failed += 1
                if failureMessages.count < 3 { failureMessages.append(message) }
            }
            completed += 1
            done = completed
            if completed % 10 == 0 {
                try? context.save()
                await Task.yield()
            }
        }
        try? context.save()
        currentTitle = nil
        isRunning = false

        if Task.isCancelled {
            lastResult = "중단했어요. \(written)곡은 정리했어요."
            return
        }
        var parts = ["\(written)곡 태그 정리"]
        if skipped > 0 { parts.append("\(skipped)곡 건너뜀") }
        if unsupported > 0 {
            let formats = unsupportedFormats.sorted().joined(separator: ", ")
            parts.append("\(unsupported)곡 형식 미지원\(formats.isEmpty ? "" : " (\(formats))")")
        }
        if failed > 0 {
            let detail = failureMessages.first.map { " — \($0)" } ?? ""
            parts.append("\(failed)곡 실패\(detail)")
        }
        lastResult = parts.joined(separator: " · ")
    }

    private func write(_ track: Track) async -> MetadataWriter.Outcome {
        let url = track.fileURL
        // 클라우드에만 있는 파일을 억지로 내려받지 않는다. 기기에 있는 곡만 정리한다.
        guard FileManager.default.fileExists(atPath: url.path), CloudFiles.isDownloaded(url) else {
            return .skipped
        }

        var tags = MetadataWriter.Tags()
        tags.title = track.title
        tags.artist = track.artistName
        tags.album = track.albumTitle
        tags.albumArtist = track.albumArtistName
        tags.trackNumber = track.trackNumber > 0 ? track.trackNumber : nil
        tags.discNumber = track.discNumber > 0 ? track.discNumber : nil
        tags.year = track.year
        tags.genre = track.genre
        if let artwork = track.artworkFile ?? track.album?.artworkFile,
           let coverURL = ArtworkStore.url(artwork) {
            tags.cover = await Task.detached(priority: .utility) {
                try? Data(contentsOf: coverURL)
            }.value
        }

        let outcome = await MetadataWriter.write(tags, to: url)
        if case .written = outcome {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                track.fileSize = Int64(size)
            }
        }
        return outcome
    }
}
