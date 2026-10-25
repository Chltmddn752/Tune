import Foundation

/// 위젯이 읽는 "지금 재생 중" 정보.
struct SharedPlaybackState: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkFile: String?
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    var updatedAt: Date
    /// 큰 위젯에 보여줄 최근 앨범 (예전 저장분에는 없을 수 있음)
    var recent: [RecentAlbum]? = nil
    /// 좋아요 여부
    var isFavorite: Bool? = nil
    /// 앨범 색 (#RRGGBB, 위젯 배경용)
    var palette: [String]? = nil
    /// 다음에 나올 곡 (앱이 꺼져 있어도 곡이 끝나는 시각에 위젯이 다음 곡으로 넘어가게)
    var upNext: [UpNextItem]? = nil

    struct UpNextItem: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var artworkFile: String?
        var duration: Double

        var artworkURL: URL? {
            artworkFile.map { AppGroup.artworkDirectory.appendingPathComponent($0) }
        }
    }

    struct RecentAlbum: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var artworkFile: String?

        var artworkURL: URL? {
            artworkFile.map { AppGroup.artworkDirectory.appendingPathComponent($0) }
        }
    }

    static let empty = SharedPlaybackState(
        title: "", artist: "", album: "", artworkFile: nil,
        isPlaying: false, elapsed: 0, duration: 0, updatedAt: .distantPast
    )

    var hasTrack: Bool { !title.isEmpty }

    var artworkURL: URL? {
        guard let artworkFile else { return nil }
        return AppGroup.artworkDirectory.appendingPathComponent(artworkFile)
    }

    static func load() -> SharedPlaybackState? {
        guard let data = try? Data(contentsOf: AppGroup.stateURL) else { return nil }
        return try? JSONDecoder().decode(SharedPlaybackState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: AppGroup.stateURL, options: .atomic)
    }
}
