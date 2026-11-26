import Foundation
import SwiftData

extension Notification.Name {
    /// 가사를 새로 만들거나 바꿨다(object: 곡 UUID). 지금 재생 중인 곡이면 가사 화면이 다시 읽는다.
    static let tuneLyricsReplaced = Notification.Name("tuneLyricsReplaced")
}

/// 가사를 찾는 순서: 같은 이름의 가사 파일 → 저장해 둔 가사 → 파일 안 가사 → LRCLIB
@MainActor
enum LyricsService {
    static func load(for item: QueueItem, context: ModelContext) async -> (Lyrics?, LyricsCache?) {
        let estimate = UserDefaults.standard.object(forKey: SettingsKey.estimateWordTiming) as? Bool ?? true
        let id = item.trackID
        var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        let cached = try? context.fetch(descriptor).first

        // 0. 우리가 만든 정확한 단어 싱크가 가장 먼저.
        //    곡 옆 .ttml(컴퓨터 도구나 이 기기가 남긴 것) → 저장해 둔 가사 순서.
        let sidecar = AlignerLyrics.sidecarURL(for: item.fileURL)
        if CloudFiles.isExternal(sidecar), CloudFiles.exists(sidecar), !CloudFiles.isDownloaded(sidecar) {
            await CloudFiles.ensureDownloaded(sidecar, timeout: 20)
        }
        if let raw = try? String(contentsOf: sidecar, encoding: .utf8), AlignerLyrics.isGenerated(raw),
           var lyrics = LyricsParser.parse(raw, format: "ttml", estimateWords: estimate), lyrics.isSynced {
            lyrics.source = AlignerLyrics.sourceName
            return (shifted(lyrics, by: (cached?.offset ?? 0) + globalTimingOffset), cached)
        }
        if let cached, cached.source == AlignerLyrics.sourceName, cached.format == "ttml",
           var lyrics = LyricsParser.parse(cached.raw, format: "ttml", estimateWords: estimate), lyrics.isSynced {
            lyrics.source = cached.source
            return (shifted(lyrics, by: cached.offset + globalTimingOffset), cached)
        }

        // 1. 곡 옆의 .ttml / .lrc 파일
        for ext in ["ttml", "lrc"] {
            let url = item.fileURL.deletingPathExtension().appendingPathExtension(ext)
            // 클라우드 폴더에 있는 가사 파일은 받아진 다음에 읽는다.
            if CloudFiles.isExternal(url), CloudFiles.exists(url), !CloudFiles.isDownloaded(url) {
                await CloudFiles.ensureDownloaded(url, timeout: 20)
            }
            if let raw = try? String(contentsOf: url, encoding: .utf8),
               var lyrics = LyricsParser.parse(raw, format: ext, estimateWords: estimate) {
                lyrics.source = "가사 파일"
                return (shifted(lyrics, by: (cached?.offset ?? 0) + globalTimingOffset), cached)
            }
        }

        // 2. 저장해 둔 가사
        if let cached, cached.format != "none" {
            if var lyrics = LyricsParser.parse(cached.raw, format: cached.format, estimateWords: estimate) {
                lyrics.source = cached.source
                return (shifted(lyrics, by: cached.offset + globalTimingOffset), cached)
            }
        }

        // 3. 파일 안에 들어있는 가사
        var embeddedPlain: Lyrics?
        if let track = fetchTrack(id, context: context), let embedded = track.embeddedLyrics,
           var lyrics = LyricsParser.parse(embedded, format: "lrc", estimateWords: estimate) {
            lyrics.source = "파일 안 가사"
            if lyrics.isSynced { return (lyrics, cached) }
            embeddedPlain = lyrics
        }

        // 4. 인터넷 (설정에서 끌 수 있음)
        let online = UserDefaults.standard.object(forKey: SettingsKey.onlineLyrics) as? Bool ?? true
        if online, cached == nil || cached?.format == "none" && (cached?.fetchedAt.timeIntervalSinceNow ?? -1e9) < -7 * 86400 {
            let activityID = ActivityCenter.shared.begin(
                title: "가사 찾기", symbol: "quote.bubble", total: 1, detail: item.title
            )
            var found = false
            defer {
                ActivityCenter.shared.finish(activityID, message: found ? "가사를 찾았어요" : "가사를 찾지 못했어요")
            }
            if let fetched = await OnlineLyrics.fetch(title: item.title, artist: item.artist,
                                                      album: item.album, duration: item.duration) {
                found = true
                let entry = cached ?? LyricsCache(trackID: id, raw: fetched.raw, format: fetched.format, source: fetched.source)
                entry.raw = fetched.raw
                entry.format = fetched.format
                entry.source = fetched.source
                entry.fetchedAt = .now
                if cached == nil { context.insert(entry) }
                try? context.save()
                if var lyrics = LyricsParser.parse(fetched.raw, format: fetched.format, estimateWords: estimate) {
                    lyrics.source = fetched.source
                    return (shifted(lyrics, by: entry.offset + globalTimingOffset), entry)
                }
            } else if cached == nil {
                context.insert(LyricsCache(trackID: id, raw: "", format: "none", source: ""))
                try? context.save()
            }
        }
        return (embeddedPlain, cached)
    }

    /// 설정에서 정한 전체 가사 보정. +면 가사가 조금 빨라진다(시작 시각을 앞당긴다).
    static var globalTimingOffset: Double {
        UserDefaults.standard.double(forKey: SettingsKey.lyricsOffset)
    }

    static func setOffset(_ offset: Double, for item: QueueItem, context: ModelContext) {
        let id = item.trackID
        var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        if let cached = try? context.fetch(descriptor).first {
            cached.offset = offset
        } else {
            let entry = LyricsCache(trackID: id, raw: "", format: "none", source: "")
            entry.offset = offset
            context.insert(entry)
        }
        try? context.save()
    }

    static func shifted(_ lyrics: Lyrics, by offset: Double) -> Lyrics {
        guard offset != 0 else { return lyrics }
        var copy = lyrics
        copy.lines = lyrics.lines.map { line in
            var l = line
            l.start -= offset
            l.end -= offset
            l.words = line.words.map { LyricWord(text: $0.text, start: $0.start - offset, end: $0.end - offset) }
            return l
        }
        return copy
    }

    private static func fetchTrack(_ id: UUID, context: ModelContext) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// lrclib.net 무료 가사 API
enum LRCLIB {
    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> (String, String)? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        if let result = await request(components.url) { return result }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = search.url, let data = await data(from: url),
              let results = try? JSONDecoder().decode([Response].self, from: data) else { return nil }
        // 검색 결과는 다른 버전(MV·라이브·리믹스)일 수 있어서, 시간 맞춘 가사는 길이가 비슷한 것만 쓴다.
        let matching = results.filter { result in
            guard duration > 0, let length = result.duration, length > 0 else { return true }
            return abs(length - duration) <= 3
        }
        if let synced = matching.first(where: { $0.syncedLyrics?.isEmpty == false })?.syncedLyrics { return (synced, "lrc") }
        if let plain = results.first(where: { $0.plainLyrics?.isEmpty == false })?.plainLyrics { return (plain, "plain") }
        return nil
    }

    private static func request(_ url: URL?) async -> (String, String)? {
        guard let url, let data = await data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if let synced = response.syncedLyrics, !synced.isEmpty { return (synced, "lrc") }
        if let plain = response.plainLyrics, !plain.isEmpty { return (plain, "plain") }
        return nil
    }

    private static func data(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Tune/0.1 (personal music player)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return result.0
    }
}

/// 인터넷 가사: LRCLIB(곡 길이가 맞는 시간 맞춘 가사 → 시간 없는 가사).
enum OnlineLyrics {
    struct Found {
        var raw: String
        var format: String
        var source: String
    }

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Found? {
        guard let fetched = await LRCLIB.fetch(title: title, artist: artist, album: album, duration: duration) else { return nil }
        return Found(raw: fetched.0, format: fetched.1, source: "LRCLIB")
    }
}
