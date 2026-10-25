import Foundation
import SwiftData

/// 다른 서비스에서 내보낸 플레이리스트 CSV(Exportify, Soundiiz, TuneMyMusic 등)를
/// 내 보관함 곡과 맞춰서 Tune 플레이리스트로 만든다. 보관함에 없는 곡은 목록으로 돌려준다.
/// (파일을 받지 않는다 — 없는 곡은 "사고 싶은 곡"에 담을 수 있다.)
struct CSVPlaylistResult: Identifiable {
    struct Row: Hashable {
        var title: String
        var artist: String
        var album: String
    }

    let id = UUID()
    let playlistName: String
    let matched: [UUID]
    let missing: [Row]
    var playlistID: UUID?
}

@MainActor
enum CSVPlaylistImporter {
    enum ImportError: LocalizedError {
        case unreadable, noColumns, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "CSV 파일을 읽지 못했어요."
            case .noColumns: "곡 제목 열을 찾지 못했어요. 첫 줄에 'Track Name'·'Title'·'제목' 같은 머리글이 있어야 해요."
            case .empty: "CSV에 곡이 없어요."
            }
        }
    }

    static func importFile(_ url: URL, context: ModelContext) throws -> CSVPlaylistResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw ImportError.unreadable
        }
        let rows = parse(text)
        guard let header = rows.first else { throw ImportError.empty }
        let columns = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        func column(_ names: [String]) -> Int? {
            for name in names { if let i = columns.firstIndex(of: name) { return i } }
            for name in names { if let i = columns.firstIndex(where: { $0.contains(name) }) { return i } }
            return nil
        }
        guard let titleColumn = column(["track name", "title", "track", "name", "song", "제목", "곡"]) else {
            throw ImportError.noColumns
        }
        let artistColumn = column(["artist name(s)", "artist name", "artists", "artist", "가수", "아티스트"])
        let albumColumn = column(["album name", "album", "앨범"])

        let entries: [CSVPlaylistResult.Row] = rows.dropFirst().compactMap { row in
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            let title = value(titleColumn)
            guard !title.isEmpty else { return nil }
            return .init(title: title, artist: value(artistColumn), album: value(albumColumn))
        }
        guard !entries.isEmpty else { throw ImportError.empty }

        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var matched: [UUID] = []
        var missing: [CSVPlaylistResult.Row] = []
        for entry in entries {
            if let track = LibraryMatcher.match(title: entry.title, artist: entry.artist, in: tracks) {
                if !matched.contains(track.id) { matched.append(track.id) }
            } else {
                missing.append(entry)
            }
        }

        let name = url.deletingPathExtension().lastPathComponent
        var result = CSVPlaylistResult(playlistName: name, matched: matched, missing: missing)
        if !matched.isEmpty {
            let playlist = Playlist(name: name, detail: "CSV에서 가져옴")
            context.insert(playlist)
            for (order, id) in matched.enumerated() {
                let entry = PlaylistEntry(order: order, trackID: id)
                context.insert(entry)
                entry.playlist = playlist
            }
            try? context.save()
            result.playlistID = playlist.id
        }
        return result
    }

    static func addMissingToWishlist(_ result: CSVPlaylistResult, context: ModelContext) -> Int {
        let existing = Set(((try? context.fetch(FetchDescriptor<WishItem>())) ?? []).map {
            LibraryMatcher.normalize($0.title) + "|" + LibraryMatcher.normalize($0.artist)
        })
        var added = 0
        for row in result.missing {
            let key = LibraryMatcher.normalize(row.title) + "|" + LibraryMatcher.normalize(row.artist)
            guard !existing.contains(key) else { continue }
            context.insert(WishItem(title: row.title, artist: row.artist, album: row.album))
            added += 1
        }
        try? context.save()
        return added
    }

    /// 따옴표·쉼표·줄바꿈이 들어간 칸도 읽는 CSV 파서 (구분자는 쉼표, 없으면 세미콜론·탭)
    static func parse(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let separator: Character = firstLine.contains(",") ? "," : (firstLine.contains(";") ? ";" : "\t")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = iterator.next()
        if pending == "\u{FEFF}" { pending = iterator.next() }

        while let char = pending {
            pending = iterator.next()
            if inQuotes {
                if char == "\"" {
                    if pending == "\"" { field.append("\""); pending = iterator.next() } else { inQuotes = false }
                } else {
                    field.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == separator {
                row.append(field); field = ""
            } else if char == "\n" || char == "\r" {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(char)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
