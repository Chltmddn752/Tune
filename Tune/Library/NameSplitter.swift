import Foundation
import SwiftData

/// "A, B" · "A; B" · "A feat. B"처럼 한 칸에 여러 명(여러 장르)이 들어간 태그를 나눈다.
enum NameSplitter {
    /// 이름 자체에 쉼표가 들어간 아티스트는 나누지 않는다.
    private static let protectedNames: Set<String> = [
        "tyler, the creator", "earth, wind & fire", "crosby, stills, nash & young",
        "crosby, stills & nash", "emerson, lake & palmer", "blood, sweat & tears",
        "peter, paul and mary", "panic! at the disco"
    ]

    private static let featPattern = try! NSRegularExpression(
        pattern: #"\s+(?:feat\.?|ft\.?|featuring)\s+"#, options: [.caseInsensitive]
    )

    /// 같은 문자열을 여러 번 나누지 않게 기억해 둔다(목록·통계에서 수천 번 불리기 때문).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var artistCache: [String: [String]] = [:]
    nonisolated(unsafe) private static var genreCache: [String: [String]] = [:]

    static func artists(_ raw: String) -> [String] {
        cacheLock.lock()
        if let cached = artistCache[raw] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let result = splitArtists(raw)
        cacheLock.lock()
        if artistCache.count > 5000 { artistCache.removeAll() }
        artistCache[raw] = result
        cacheLock.unlock()
        return result
    }

    private static func splitArtists(_ raw: String) -> [String] {
        let trimmed = raw.nfc.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if protectedNames.contains(trimmed.lowercased()) { return [trimmed] }

        // feat. 이하도 따로 센다: "A feat. B" → A, B
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let unified = featPattern.stringByReplacingMatches(in: trimmed, range: range, withTemplate: ";")
        // 괄호 안 feat. "(feat. B)" → ";B"
        let noParens = unified
            .replacingOccurrences(of: "(;", with: ";")
            .replacingOccurrences(of: "[;", with: ";")
        var parts = split(noParens, separators: [";", ",", "，", "、", "；"])
        parts = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]")) }.filter { !$0.isEmpty }
        // 나눈 조각이 보호된 이름의 일부면 원래대로
        if parts.count > 1, protectedNames.contains(where: { trimmed.lowercased().contains($0) }) {
            return [trimmed]
        }
        return dedupe(parts)
    }

    static func genres(_ raw: String) -> [String] {
        cacheLock.lock()
        if let cached = genreCache[raw] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let result = dedupe(split(raw.nfc, separators: [";", ",", "/", "，", "、", "；"]).filter { !$0.isEmpty })
        cacheLock.lock()
        if genreCache.count > 2000 { genreCache.removeAll() }
        genreCache[raw] = result
        cacheLock.unlock()
        return result
    }

    static func primaryArtist(_ raw: String) -> String { artists(raw).first ?? raw }

    /// 그 이름이 이 태그에 들어 있는지 (대소문자 무시)
    static func contains(_ raw: String, artist name: String) -> Bool {
        let key = name.libraryKey
        return artists(raw).contains { $0.libraryKey == key }
    }

    static func contains(_ raw: String, genre name: String) -> Bool {
        let key = name.libraryKey
        return genres(raw).contains { $0.libraryKey == key }
    }

    private static func split(_ raw: String, separators: [Character]) -> [String] {
        raw.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func dedupe(_ parts: [String]) -> [String] {
        var seen = Set<String>()
        return parts.filter { seen.insert($0.libraryKey).inserted }
    }
}

/// 이미 들어 있는 보관함 정리: "A, B" 같은 아티스트를 A와 B로 나눈다.
@MainActor
enum LibraryMaintenance {
    static func splitCombinedArtists(context: ModelContext) {
        let artists = (try? context.fetch(FetchDescriptor<Artist>())) ?? []
        var byKey = Dictionary(artists.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false

        func artist(named name: String) -> Artist {
            let key = name.libraryKey
            if let existing = byKey[key] { return existing }
            let created = Artist(key: key, name: name)
            context.insert(created)
            byKey[key] = created
            changed = true
            return created
        }

        // 1. 묶여 있는 아티스트를 첫 번째 사람에게 넘기고 지운다.
        for combined in artists {
            let parts = NameSplitter.artists(combined.name)
            guard parts.count > 1 else { continue }
            let first = artist(named: parts[0])
            for part in parts.dropFirst() { _ = artist(named: part) }
            for track in combined.tracks { track.artist = first }
            for album in combined.albums { album.artist = first }
            byKey.removeValue(forKey: combined.key)
            context.delete(combined)
            changed = true
        }

        // 2. 곡에 적힌 모든 이름에 아티스트가 있게 한다(참여한 사람도 아티스트 목록에 나오게).
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        for track in tracks {
            let names = NameSplitter.artists(track.artistName) + NameSplitter.artists(track.albumArtistName)
            for name in names where byKey[name.libraryKey] == nil { _ = artist(named: name) }
            if track.artist == nil, let first = names.first { track.artist = artist(named: first) }
        }

        if changed { try? context.save() }
    }
}


extension LibraryMaintenance {
    /// 같은 이름이 유니코드 표기만 달라(예: MP4 태그의 "ROSÉ") 따로 생긴 곡·앨범·아티스트 정보를 한 표기로 맞추고,
    /// 같은 아티스트가 둘이 된 경우 하나로 합친다.
    static func normalizeUnicode(context: ModelContext) {
        var changed = false
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            if track.title != track.title.nfc { track.title = track.title.nfc; changed = true }
            if track.artistName != track.artistName.nfc { track.artistName = track.artistName.nfc; changed = true }
            if track.albumTitle != track.albumTitle.nfc { track.albumTitle = track.albumTitle.nfc; changed = true }
            if track.albumArtistName != track.albumArtistName.nfc { track.albumArtistName = track.albumArtistName.nfc; changed = true }
        }
        for album in (try? context.fetch(FetchDescriptor<Album>())) ?? [] {
            if album.title != album.title.nfc { album.title = album.title.nfc; changed = true }
            if album.artistName != album.artistName.nfc { album.artistName = album.artistName.nfc; changed = true }
        }
        if changed { try? context.save() }

        // 아티스트 합치기
        let artists = (try? context.fetch(FetchDescriptor<Artist>())) ?? []
        let groups = Dictionary(grouping: artists) { $0.name.libraryKey }
        var rekey: [(Artist, String)] = []
        var merged = false
        for (key, group) in groups {
            guard let keeper = group.max(by: { $0.tracks.count + $0.albums.count < $1.tracks.count + $1.albums.count }) else { continue }
            for other in group where other.id != keeper.id {
                for track in other.tracks { track.artist = keeper }
                for album in other.albums { album.artist = keeper }
                if keeper.imageFile == nil { keeper.imageFile = other.imageFile }
                keeper.isPinned = keeper.isPinned || other.isPinned
                context.delete(other)
                merged = true
            }
            if keeper.key != key || keeper.name != keeper.name.nfc { rekey.append((keeper, key)) }
        }
        if merged { try? context.save() }
        guard !rekey.isEmpty else { return }
        for (artist, key) in rekey {
            artist.key = key
            artist.name = artist.name.nfc
        }
        try? context.save()
    }

    /// 예전 기준(제목 + 앨범 가수 칸 전체)으로 따로 갈라진 같은 앨범을 하나로 합친다.
    static func mergeSplitAlbums(context: ModelContext) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let groups = Dictionary(grouping: albums) { Album.makeKey(title: $0.title, artist: $0.artistName) }
        var rekey: [(Album, String)] = []
        var changed = false
        for (key, group) in groups {
            guard let keeper = group.max(by: { $0.tracks.count < $1.tracks.count }) else { continue }
            for other in group where other.id != keeper.id {
                for track in other.tracks { track.album = keeper }
                if keeper.artworkFile == nil {
                    keeper.artworkFile = other.artworkFile
                    keeper.colorHex = other.colorHex
                    keeper.paletteHex = other.paletteHex
                }
                if keeper.year == nil { keeper.year = other.year }
                if keeper.genre.isEmpty { keeper.genre = other.genre }
                if let played = other.lastPlayedAt, played > (keeper.lastPlayedAt ?? .distantPast) { keeper.lastPlayedAt = played }
                keeper.isPinned = keeper.isPinned || other.isPinned
                if keeper.artist == nil { keeper.artist = other.artist }
                context.delete(other)
                changed = true
            }
            if keeper.key != key { rekey.append((keeper, key)) }
        }
        if changed { try? context.save() }
        // 지운 뒤에 새 기준 키로 바꾼다(키는 겹치면 안 돼서 순서가 중요).
        guard !rekey.isEmpty else { return }
        for (album, key) in rekey { album.key = key }
        try? context.save()
    }
}

/// 곡에 적힌 가수 이름들 → 보관함의 아티스트들 (적힌 순서대로)
@MainActor
enum ArtistLookup {
    static func artists(for track: Track, context: ModelContext) -> [Artist] {
        let names = NameSplitter.artists(track.artistName)
        var result: [Artist] = []
        for name in names {
            let key = name.libraryKey
            var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.key == key })
            descriptor.fetchLimit = 1
            if let artist = try? context.fetch(descriptor).first, !result.contains(where: { $0.id == artist.id }) {
                result.append(artist)
            }
        }
        if result.isEmpty, let artist = track.artist { result = [artist] }
        return result
    }
}
