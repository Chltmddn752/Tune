import Foundation

enum DownloadStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: "대기 중"
        case .running: "받는 중"
        case .completed: "완료"
        case .failed: "실패"
        case .cancelled: "취소됨"
        }
    }
}

struct DownloadJob: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var providerID: String
    var providerName: String
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var durationMs: Int
    var coverURL: String?
    var isrc: String?
    var quality: String
    var status: DownloadStatus
    var progress: Double
    var statusText: String
    var error: String?
    var createdAt: Date
    var finishedAt: Date?
    var relativePath: String?
    var preparedContext: JSONValue?
    /// 태그를 파일에 쓰지 못했을 때의 안내. 성공했거나 건너뛰면 nil.
    var tagWarning: String? = nil

    var displayArtist: String { artist.isEmpty ? "알 수 없는 아티스트" : artist }
    var displayAlbum: String { album.isEmpty ? "앨범 없음" : album }
    var isActive: Bool { status == .queued || status == .running }
}

struct DownloadedMetadata: Sendable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var isrc: String?
    var coverURL: String?
    var duration: Double?

    func mergingMissing(from other: DownloadedMetadata) -> DownloadedMetadata {
        var value = self
        if value.title.isEmpty { value.title = other.title }
        if value.artist.isEmpty { value.artist = other.artist }
        if value.album.isEmpty { value.album = other.album }
        if value.albumArtist.isEmpty { value.albumArtist = other.albumArtist }
        value.trackNumber = value.trackNumber ?? other.trackNumber
        value.discNumber = value.discNumber ?? other.discNumber
        value.year = value.year ?? other.year
        value.genre = value.genre ?? other.genre
        value.isrc = value.isrc ?? other.isrc
        value.coverURL = value.coverURL ?? other.coverURL
        value.duration = value.duration ?? other.duration
        return value
    }
}

struct ProviderDownloadResult {
    var filePath: String
    var metadata: DownloadedMetadata
    var raw: [String: Any]
}

struct ProviderEnvironment: Sendable {
    var installed: InstalledExtension
    var root: URL
    var prelude: String
    var settings: [String: JSONValue]
}
