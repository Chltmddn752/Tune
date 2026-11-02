import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(LibraryImporter.self) private var importer
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @State private var verification = ExtensionVerificationCenter.shared
    @Namespace private var playerNamespace
    @State private var newPlaylistName = ""

    /// 아이패드처럼 넓은 화면이면 오른쪽 재생 패널을 쓴다.
    private var usesPanel: Bool { sizeClass == .regular }
    @State private var windowWidth: CGFloat = 1194
    @State private var windowSize: CGSize = .zero

    private var showsPanel: Bool { usesPanel && router.panelVisible && player.hasItem }
    /// 손으로 끌어서 바꾼 패널 폭 (0이면 화면 크기에 맞춘 기본값)
    @AppStorage("panelWidth") private var savedPanelWidth: Double = 0

    private var defaultPanelWidth: CGFloat { windowWidth >= 1250 ? 400 : (windowWidth >= 1000 ? 360 : 330) }
    private var panelWidthRange: ClosedRange<CGFloat> { 320...max(320, min(560, windowWidth * 0.45)) }
    private var panelWidth: CGFloat {
        let wanted = savedPanelWidth > 0 ? CGFloat(savedPanelWidth) : defaultPanelWidth
        return min(max(wanted, panelWidthRange.lowerBound), panelWidthRange.upperBound)
    }

    /// 패널 왼쪽 가장자리 (끌어서 폭 바꾸기)
    private var panelResizeHandle: some View {
        PanelResizeHandle(width: panelWidth, range: panelWidthRange) { next in
            withAnimation(.smooth(duration: 0.3)) { savedPanelWidth = Double(next) }
        } onReset: {
            withAnimation(.panel) { savedPanelWidth = 0 }
        }
        .zIndex(2)
    }

    var body: some View {
        @Bindable var router = router
        @Bindable var coordinator = coordinator

        HStack(spacing: 0) {
        TabView(selection: $router.selectedTab) {
            Tab("홈", systemImage: "house.fill", value: AppTab.home) {
                stack(.home) { HomeView().screenBackground(nil) }
            }
            Tab("다운로드", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                stack(.downloads) { DownloadsScreen().screenBackground(nil) }
            }
            .badge(downloads.jobs.filter(\.isActive).count)
            // 아이폰: 보관함 탭 하나. 아이패드: 사이드바에 보관함·플레이리스트 섹션을 펼친다.
            if !usesPanel {
                Tab("보관함", systemImage: "square.stack.fill", value: AppTab.library) {
                    stack(.library) { LibraryView().screenBackground(nil) }
                }
            }
            Tab("통계", systemImage: "chart.bar.xaxis", value: AppTab.stats) {
                stack(.stats) { StatsView().screenBackground(nil) }
            }

            if usesPanel {
            TabSection("보관함") {
                Tab("최근 추가된 항목", systemImage: "clock", value: AppTab.libRecent) {
                    stack(.libRecent) { RecentlyAddedView().screenBackground(nil) }
                }
                Tab("아티스트", systemImage: "music.mic", value: AppTab.libArtists) {
                    stack(.libArtists) { ArtistsListView().screenBackground(nil) }
                }
                Tab("앨범", systemImage: "square.stack", value: AppTab.libAlbums) {
                    stack(.libAlbums) { AlbumsListView().screenBackground(nil) }
                }
                Tab("노래", systemImage: "music.note", value: AppTab.libSongs) {
                    stack(.libSongs) { SongsListView().screenBackground(nil) }
                }
                Tab("장르", systemImage: "guitars", value: AppTab.libGenres) {
                    stack(.libGenres) { GenresListView().screenBackground(nil) }
                }
                Tab("좋아요 표시한 곡", systemImage: "star", value: AppTab.libFavorites) {
                    stack(.libFavorites) { FavoritesView().screenBackground(nil) }
                }
            }

            TabSection("플레이리스트") {
                Tab("모든 플레이리스트", systemImage: "square.grid.3x3", value: AppTab.allPlaylists) {
                    stack(.allPlaylists) { PlaylistsListView().screenBackground(nil) }
                }
                ForEach(playlists) { playlist in
                    Tab(playlist.name, systemImage: "music.note.list", value: AppTab.playlist(playlist.id)) {
                        stack(.playlist(playlist.id)) { PlaylistScreen(playlistID: playlist.id) }
                    }
                }
            }
            .sectionActions {
                Button {
                    newPlaylistName = ""
                    router.showNewPlaylist = true
                } label: {
                    Label("새로운 플레이리스트", systemImage: "plus")
                }
            }
            }

            Tab("검색", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                stack(.search) { SearchView().screenBackground(nil) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: router.showNewPlaylist) { _, showing in
            if showing { newPlaylistName = "" }
        }
        .onChange(of: usesPanel) { _, wide in
            // 화면 분할로 좁아졌는데 사이드바 전용 항목을 보고 있었으면 보관함으로 옮긴다.
            if !wide, !router.selectedTab.isCompactTab { router.selectedTab = .library }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSidebarBottomBar {
            Button {
                router.showSettings = true
            } label: {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("설정")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, Spacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .tabViewBottomAccessory(isEnabled: player.hasItem && !showsPanel && !router.hidesMiniPlayer) {
            MiniPlayer {
                if usesPanel {
                    router.openPanel(.artwork)
                } else {
                    router.showPlayer = true
                }
            }
            .matchedTransitionSource(id: "nowPlaying", in: playerNamespace)
        }

            // 아이패드 재생 패널: inspector 대신 옆에 직접 붙인다.
            // (inspector를 쓰면 왼쪽 사이드바·탭 막대가 사라져서 이동할 방법이 없어졌다)
            if showsPanel {
                panelResizeHandle
                    .transition(.opacity)
                NowPlayingPanel()
                    .frame(width: panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background {
            GeometryReader { proxy in
                Color(.systemBackground)
                    .onAppear { windowSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in windowSize = size }
            }
            .ignoresSafeArea()
        }
        .environment(\.windowSize, windowSize)
        .task { verification.install() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .animation(.panel, value: showsPanel)
        .fullScreenCover(isPresented: $router.showPlayer) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "nowPlaying", in: playerNamespace))
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $router.showActivity) {
            ActivityView()
        }
        .alert("새로운 플레이리스트", isPresented: $router.showNewPlaylist) {
            TextField("이름", text: $newPlaylistName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                let playlist = Playlist(name: name.isEmpty ? "새 플레이리스트" : name)
                modelContext.insert(playlist)
                try? modelContext.save()
                if usesPanel {
                    router.selectedTab = .playlist(playlist.id)
                } else {
                    router.open(.playlist(playlist.id))
                }
            }
        }
        .overlay(alignment: .top) {
            GlassToastHost()
        }
        .overlay(alignment: .top) {
            BannerBridge()
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $coordinator.showSetupSheet) {
            DownloadSetupSheet()
        }
        .sheet(isPresented: $coordinator.showSettingsSheet) {
            DownloadSettingsSheet()
        }
        .sheet(item: $coordinator.matchSheet) { sheet in
            DownloadMatchSheet(sheet: sheet)
        }
        .onChange(of: downloads.lastMessage) { _, message in
            guard let message else { return }
            toasts.show(message, symbol: "info.circle")
            downloads.lastMessage = nil
        }
    }

    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: router.path(tab)) {
            content().withRoutes()
        }
    }
}

extension View {
    /// 모든 탭에서 같은 화면 이동 규칙을 쓴다.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestination(route: route)
        }
    }
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id): AlbumScreen(albumID: id)
        case .artist(let id): ArtistScreen(artistID: id)
        case .providerAlbum(let route): ProviderAlbumScreen(route: route).screenBackground(nil)
        case .providerArtist(let route): ProviderArtistScreen(route: route).screenBackground(nil)
        case .providerPlaylist(let route): ProviderPlaylistScreen(route: route).screenBackground(nil)
        case .playlist(let id): PlaylistScreen(playlistID: id)
        case .songs: SongsListView().screenBackground(nil)
        case .albums: AlbumsListView().screenBackground(nil)
        case .artists: ArtistsListView().screenBackground(nil)
        case .playlists: PlaylistsListView().screenBackground(nil)
        case .genres: GenresListView().screenBackground(nil)
        case .genre(let name): GenreView(genre: name).screenBackground(nil)
        case .favorites: FavoritesView().screenBackground(nil)
        case .recentlyAdded: RecentlyAddedView().screenBackground(nil)
        case .mix(let id): MixScreen(mixID: id)
        case .wishlist: WishlistView().screenBackground(nil)
        }
    }
}


/// 패널 폭 손잡이. 끄는 동안에는 손잡이와 미리보기 선만 움직이고(화면 전체를 매번 다시 배치하면 버벅인다),
/// 손을 떼면 한 번에 폭이 바뀐다. 두 번 누르면 기본 폭.
private struct PanelResizeHandle: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void
    let onReset: () -> Void

    @Environment(ScreenBackgroundCenter.self) private var screenBackgrounds
    @GestureState private var translation: CGFloat = 0

    private var offset: CGFloat {
        let target = min(max(width - translation, range.lowerBound), range.upperBound)
        return width - target
    }

    var body: some View {
        let dragging = translation != 0
        Color.clear
            .frame(width: 12)
            .background {
                if let background = screenBackgrounds.current, background.frame.width > 1 {
                    ContinuousGradientBackground(
                        colors: background.colors,
                        style: background.style,
                        isLight: background.isLight,
                        parallax: background.parallax,
                        anchor: background.frame,
                        edges: .vertical
                    )
                } else {
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(dragging ? Color.tuneAccent : Color.white.opacity(0.82))
                    .overlay { Capsule().stroke(.black.opacity(0.25), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 4, height: dragging ? 88 : 44)
                    .offset(x: offset)
            }
            .overlay {
                if dragging {
                    Rectangle()
                        .fill(Color.tuneAccent.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: offset)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($translation) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        onCommit(min(max(width - value.translation.width, range.lowerBound), range.upperBound))
                    }
            )
            .onTapGesture(count: 2, perform: onReset)
            .accessibilityLabel("재생 패널 폭 조절")
            .accessibilityHint("왼쪽이나 오른쪽으로 끌어서 폭을 바꿔요. 두 번 누르면 기본 폭으로 돌아가요.")
    }
}
