import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    var artistName: String
    var albumTitle: String
    var albumArtistName: String
    var trackNumber: Int
    var discNumber: Int
    var year: Int?
    var genre: String
    var duration: Double
    /// Documents 폴더 기준 상대 경로
    var relativePath: String
    var fileFormat: String
    var isLossless: Bool
    var fileSize: Int64
    var artworkFile: String?
    var embeddedLyrics: String?
    var playCount: Int
    var lastPlayedAt: Date?
    var isFavorite: Bool
    var addedAt: Date
    var dedupeKey: String
    var album: Album?
    var artist: Artist?

    init(
        title: String, artistName: String, albumTitle: String, albumArtistName: String,
        trackNumber: Int, discNumber: Int, year: Int?, genre: String, duration: Double,
        relativePath: String, fileFormat: String, isLossless: Bool, fileSize: Int64,
        artworkFile: String?, embeddedLyrics: String?, dedupeKey: String
    ) {
        self.id = UUID()
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.albumArtistName = albumArtistName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.duration = duration
        self.relativePath = relativePath
        self.fileFormat = fileFormat
        self.isLossless = isLossless
        self.fileSize = fileSize
        self.artworkFile = artworkFile
        self.embeddedLyrics = embeddedLyrics
        self.playCount = 0
        self.lastPlayedAt = nil
        self.isFavorite = false
        self.addedAt = .now
        self.dedupeKey = dedupeKey
    }

    var fileURL: URL { LibraryPaths.url(forRelative: relativePath) }
}

@Model
final class Album {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var title: String
    var artistName: String
    var year: Int?
    var genre: String
    var artworkFile: String?
    /// 대표색 (#RRGGBB)
    var colorHex: String?
    /// 재생 화면 배경용 색 여러 개 (쉼표로 구분)
    var paletteHex: String?
    var addedAt: Date
    var lastPlayedAt: Date?
    var isPinned: Bool
    @Relationship(deleteRule: .nullify, inverse: \Track.album) var tracks: [Track] = []
    var artist: Artist?

    init(key: String, title: String, artistName: String, year: Int?, genre: String, artworkFile: String?) {
        self.id = UUID()
        self.key = key
        self.title = title
        self.artistName = artistName
        self.year = year
        self.genre = genre
        self.artworkFile = artworkFile
        self.addedAt = .now
        self.isPinned = false
    }

    var sortedTracks: [Track] {
        tracks.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
    }

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var isLossless: Bool { !tracks.isEmpty && tracks.allSatisfy(\.isLossless) }
    var isSingleOrEP: Bool { tracks.count <= 6 }
}

@Model
final class Artist {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var name: String
    var imageFile: String?
    var imageFetchedAt: Date?
    var lastPlayedAt: Date?
    var isPinned: Bool
    @Relationship(deleteRule: .nullify, inverse: \Track.artist) var tracks: [Track] = []
    @Relationship(deleteRule: .nullify, inverse: \Album.artist) var albums: [Album] = []

    init(key: String, name: String) {
        self.id = UUID()
        self.key = key
        self.name = name
        self.isPinned = false
    }
}

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var detail: String
    var coverFile: String?
    var createdAt: Date
    var updatedAt: Date
    var lastPlayedAt: Date?
    var isPinned: Bool
    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist) var entries: [PlaylistEntry] = []

    init(name: String, detail: String = "") {
        self.id = UUID()
        self.name = name
        self.detail = detail
        self.createdAt = .now
        self.updatedAt = .now
        self.isPinned = false
    }

    var sortedEntries: [PlaylistEntry] { entries.sorted { $0.order < $1.order } }
}

@Model
final class PlaylistEntry {
    @Attribute(.unique) var id: UUID
    var order: Int
    var trackID: UUID
    var playlist: Playlist?

    init(order: Int, trackID: UUID) {
        self.id = UUID()
        self.order = order
        self.trackID = trackID
    }
}

/// 30초 이상 들은 재생 한 번. 통계용이라 곡 정보를 같이 저장한다.
@Model
final class PlayEvent {
    @Attribute(.unique) var id: UUID
    var trackID: UUID
    var date: Date
    var seconds: Double
    var trackTitle: String
    var artistName: String
    var albumTitle: String
    var albumArtistName: String
    var genre: String
    var artworkFile: String?

    init(trackID: UUID, date: Date, seconds: Double, trackTitle: String, artistName: String,
         albumTitle: String, albumArtistName: String, genre: String, artworkFile: String?) {
        self.id = UUID()
        self.trackID = trackID
        self.date = date
        self.seconds = seconds
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.albumArtistName = albumArtistName
        self.genre = genre
        self.artworkFile = artworkFile
    }
}

@Model
final class LyricsCache {
    @Attribute(.unique) var trackID: UUID
    var raw: String
    /// "lrc" | "ttml" | "plain" | "none"
    var format: String
    var source: String
    var offset: Double
    var fetchedAt: Date

    init(trackID: UUID, raw: String, format: String, source: String) {
        self.trackID = trackID
        self.raw = raw
        self.format = format
        self.source = source
        self.offset = 0
        self.fetchedAt = .now
    }
}

enum LibraryPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var importedFolder: URL {
        let url = documents.appendingPathComponent("가져온 음악", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 저장된 곡 경로 → 실제 파일 주소 (Tune 폴더 또는 연결한 폴더)
    static func url(forRelative relative: String) -> URL {
        if relative.hasPrefix(LinkedFolders.prefix) {
            return LinkedFolders.shared.fileURL(forRelative: relative)
                ?? URL(fileURLWithPath: "/dev/null/missing").appendingPathComponent(relative)
        }
        return documents.appendingPathComponent(relative)
    }

    static func relativePath(for url: URL) -> String {
        if let linked = LinkedFolders.shared.relativePath(for: url) { return linked }
        let base = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(base) {
            return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }
}


extension Album {
    /// 앨범을 묶는 기준: 앨범 제목 + 앨범 가수 중 첫 사람.
    /// ("ROSÉ"와 "ROSÉ & Bruno Mars"처럼 곡마다 가수 칸이 달라도 같은 앨범으로 묶인다)
    static func makeKey(title: String, artist: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).libraryKey
        let a = NameSplitter.primaryArtist(artist).trimmingCharacters(in: .whitespacesAndNewlines).libraryKey
        return "\(t)|\(a)"
    }
}

extension String {
    /// 유니코드 정규화(NFC). "É"가 한 글자로 저장된 파일과 "E + ´" 두 글자로 저장된 파일(예: MP4 태그)을 같게 본다.
    var nfc: String { precomposedStringWithCanonicalMapping }
    /// 보관함에서 같은 것으로 볼 때 쓰는 열쇠 (정규화 + 소문자)
    var libraryKey: String { precomposedStringWithCanonicalMapping.lowercased() }
}
