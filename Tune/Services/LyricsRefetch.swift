import Foundation
import SwiftData

extension Notification.Name {
    /// 가사를 새로 받아 바꿨다(object: 곡 UUID). 지금 재생 중인 곡이면 가사 화면이 다시 읽는다.
    static let tuneLyricsReplaced = Notification.Name("tuneLyricsReplaced")
}

/// 이미 받아 둔 가사를 Musixmatch 가사로 바꾼다. 한 곡씩, 앨범·플레이리스트 단위, 보관함 전체 모두 여기로 온다.
@MainActor
enum LyricsRefetch {
    enum Scope: String, CaseIterable, Identifiable {
        case lrclib
        case missing
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lrclib: "LRCLIB에서 받은 가사만"
            case .missing: "가사가 없거나 시간이 안 맞춰진 곡만"
            case .all: "모든 곡"
            }
        }
    }

    enum Outcome {
        case replaced(wordSynced: Bool)
        /// 받은 게 지금 가사보다 나을 게 없어서(시간 없는 가사 등) 그대로 둠
        case kept
        case notFound
        /// 곡 옆에 .lrc/.ttml 파일이 있어서 그걸 계속 씀
        case lyricsFile
        case unavailable(String)
    }

    private(set) static var isRunning = false
    private static var cancelled = false

    /// 범위에 맞는 곡들
    static func tracks(for scope: Scope, context: ModelContext) -> [Track] {
        let tracks = (try? context.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.title)]))) ?? []
        guard scope != .all else { return tracks }
        let caches = (try? context.fetch(FetchDescriptor<LyricsCache>())) ?? []
        var byTrack: [UUID: LyricsCache] = [:]
        for cache in caches { byTrack[cache.trackID] = cache }
        return tracks.filter { track in
            let cache = byTrack[track.id]
            switch scope {
            case .lrclib:
                return cache?.source == "LRCLIB"
            case .missing:
                guard let cache else { return track.embeddedLyrics?.contains("[") != true }
                return cache.format == "none" || cache.format == "plain"
            case .all:
                return true
            }
        }
    }

    /// 한 곡을 Musixmatch에서 다시 받아 바꾼다.
    static func refetch(_ track: Track, context: ModelContext) async -> Outcome {
        let item = QueueItem(track)
        for ext in ["ttml", "lrc"] where CloudFiles.exists(item.fileURL.deletingPathExtension().appendingPathExtension(ext)) {
            return .lyricsFile
        }
        switch await Musixmatch.fetch(title: item.title, artist: item.artist, album: item.album, duration: item.duration) {
        case .unavailable(let message):
            return .unavailable(message)
        case .notFound:
            return .notFound
        case .found(let result):
            let id = track.id
            var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
            descriptor.fetchLimit = 1
            let cached = try? context.fetch(descriptor).first
            // 시간 맞춘 가사를 시간 없는 가사로 바꾸지는 않는다.
            if result.format == "plain", let cached, cached.format == "lrc" || cached.format == "ttml" {
                return .kept
            }
            let entry = cached ?? LyricsCache(trackID: id, raw: result.raw, format: result.format, source: "Musixmatch")
            entry.raw = result.raw
            entry.format = result.format
            entry.source = "Musixmatch"
            entry.offset = 0  // 예전 가사에 맞춘 보정은 새 가사엔 안 맞는다.
            entry.fetchedAt = .now
            if cached == nil { context.insert(entry) }
            try? context.save()
            NotificationCenter.default.post(name: .tuneLyricsReplaced, object: id)
            return result.format == "lrc" ? .replaced(wordSynced: result.wordSynced) : .replaced(wordSynced: false)
        }
    }

    /// 여러 곡을 차례로 바꾼다. 진행 상황은 알림 센터(진행 안내)에 보인다.
    /// 이미 다른 일괄 작업이 돌고 있거나 곡이 없으면 false.
    @discardableResult
    static func run(_ tracks: [Track], title: String, context: ModelContext) -> Bool {
        guard !isRunning, !tracks.isEmpty else { return false }
        isRunning = true
        cancelled = false
        let activity = ActivityCenter.shared.begin(
            title: title, symbol: "quote.bubble", total: tracks.count, detail: tracks.first?.title,
            onCancel: { LyricsRefetch.cancelled = true }
        )
        Task { @MainActor in
            var replaced = 0, wordSynced = 0, kept = 0, missing = 0
            var stopReason: String?
            for (index, track) in tracks.enumerated() {
                if cancelled { stopReason = "멈췄어요"; break }
                ActivityCenter.shared.update(activity, completed: index, detail: track.title)
                switch await refetch(track, context: context) {
                case .replaced(let word):
                    replaced += 1
                    if word { wordSynced += 1 }
                case .kept, .lyricsFile:
                    kept += 1
                case .notFound:
                    missing += 1
                case .unavailable(let message):
                    stopReason = message
                }
                if stopReason != nil { break }
                // 너무 빠르게 연달아 물으면 캡차에 걸려서 조금씩 쉰다.
                try? await Task.sleep(for: .milliseconds(700))
            }
            var parts = ["\(replaced)곡 바꿈" + (wordSynced > 0 ? "(단어 싱크 \(wordSynced))" : "")]
            if kept > 0 { parts.append("\(kept)곡 그대로") }
            if missing > 0 { parts.append("\(missing)곡 못 찾음") }
            if let stopReason { parts.append(stopReason) }
            ActivityCenter.shared.finish(activity, message: parts.joined(separator: " · "))
            isRunning = false
        }
        return true
    }

    /// 한 곡 결과를 짧은 문장으로
    static func message(for outcome: Outcome) -> String {
        switch outcome {
        case .replaced(let word): word ? "Musixmatch 단어 싱크 가사로 바꿨어요" : "Musixmatch 가사로 바꿨어요"
        case .kept: "Musixmatch엔 시간 맞춘 가사가 없어서 그대로 뒀어요"
        case .notFound: "Musixmatch에서 이 곡 가사를 찾지 못했어요"
        case .lyricsFile: "곡 옆의 가사 파일을 쓰고 있어서 바꾸지 않았어요"
        case .unavailable(let message): message
        }
    }
}
