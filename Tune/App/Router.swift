import Observation
import SwiftUI

enum AppTab: Hashable {
    case home, library, stats, search
    // 아이패드 사이드바 전용
    case libRecent, libArtists, libAlbums, libSongs, libGenres, libFavorites
    case allPlaylists
    case playlist(UUID)

    /// 아이폰 탭 바에 있는 탭인지
    var isCompactTab: Bool {
        switch self {
        case .home, .library, .stats, .search: true
        default: false
        }
    }
}

/// 다운로드 확장이 알려 준 앨범·아티스트. 보관함 모델이 아니라 확장에서 그때그때 불러온다.
struct ProviderAlbumRoute: Hashable {
    var providerID: String
    var albumID: String
    var title: String
    var artist: String
    var coverURL: String?
    var artistID: String?
}

struct ProviderArtistRoute: Hashable {
    var providerID: String
    var artistID: String
    var name: String
    var imageURL: String?
}

struct ProviderPlaylistRoute: Hashable {
    var providerID: String
    var playlistID: String
    var title: String
    var owner: String
    var coverURL: String?
}

enum Route: Hashable {
    case album(UUID)
    case artist(UUID)
    case providerAlbum(ProviderAlbumRoute)
    case providerArtist(ProviderArtistRoute)
    case providerPlaylist(ProviderPlaylistRoute)
    case playlist(UUID)
    case songs
    case albums
    case artists
    case playlists
    case genres
    case genre(String)
    case favorites
    case recentlyAdded
    /// 자동 믹스 ("recent", "genre-rock", "track:<id>" …)
    case mix(String)
    case wishlist
}

@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .home
    /// 탭마다 따로 쌓이는 화면 이동 기록
    var paths: [AppTab: [Route]] = [:]

    var showPlayer = false
    var showSettings = false
    var showNewPlaylist = false
    /// 아이패드 오른쪽 재생 패널을 펼쳐 둘지
    var panelVisible = true
    /// 아이패드 재생 패널에서 보고 있는 화면
    var panelPane: PlayerPane = .artwork

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(
            get: { self.paths[tab] ?? [] },
            set: { self.paths[tab] = Self.deduped($0) }
        )
    }

    /// 지금 보고 있는 탭에서 화면을 연다.
    /// 이미 열린 화면이면 새로 쌓지 않고 그 화면으로 돌아간다(같은 아티스트를 여러 번 눌러도 한 번만).
    func open(_ route: Route) {
        paths[selectedTab] = Self.deduped((paths[selectedTab] ?? []) + [route])
    }

    /// 방금 연 화면이 이미 쌓여 있으면 그 위의 화면들을 걷어 내고 그 화면으로 간다.
    private static func deduped(_ path: [Route]) -> [Route] {
        guard let last = path.last, let first = path.firstIndex(of: last), first < path.count - 1 else { return path }
        return Array(path[...first])
    }

    /// 새 플레이리스트 만들기 창을 띄운다.
    func newPlaylist() {
        showNewPlaylist = true
    }

    /// 아이패드 패널을 특정 화면으로 연다.
    func openPanel(_ pane: PlayerPane) {
        panelPane = pane
        withAnimation(.panel) { panelVisible = true }
    }
}
