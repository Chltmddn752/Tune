import SwiftData
import SwiftUI

/// 앱의 뼈대 (Material 3, SpatialFlow 구조)
/// - 아이폰: 아래 내비게이션 바 + 그 위에 떠 있는 알약 미니 플레이어(끌어 올리면 전체 재생 화면)
/// - 아이패드: 왼쪽 내비게이션 레일 + 오른쪽 재생 패널
struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(LibraryImporter.self) private var importer
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var verification = ExtensionVerificationCenter.shared
    @State private var newPlaylistName = ""
    @State private var visited: Set<AppTab> = [.home]
    @State private var previousIndex = 0

    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .pink
    @AppStorage(M3SettingsKey.dynamicColors) private var dynamicColors = true
    @AppStorage(M3SettingsKey.amoled) private var amoled = false
    @AppStorage(M3SettingsKey.dynamicNavStyle) private var dynamicNavStyle = false

    /// 아이패드처럼 넓은 화면이면 오른쪽 재생 패널을 쓴다.
    private var usesPanel: Bool { sizeClass == .regular }
    @State private var windowWidth: CGFloat = 1194
    @State private var windowSize: CGSize = .zero

    private var showsPanel: Bool { usesPanel && router.panelVisible && player.hasItem }
    @AppStorage("panelWidth") private var savedPanelWidth: Double = 0

    private var defaultPanelWidth: CGFloat { windowWidth >= 1250 ? 400 : (windowWidth >= 1000 ? 360 : 330) }
    private var panelWidthRange: ClosedRange<CGFloat> { 320...max(320, min(560, windowWidth * 0.45)) }
    private var panelWidth: CGFloat {
        let wanted = savedPanelWidth > 0 ? CGFloat(savedPanelWidth) : defaultPanelWidth
        return min(max(wanted, panelWidthRange.lowerBound), panelWidthRange.upperBound)
    }

    private static let tabs: [AppTab] = [.home, .search, .library, .stats, .settings]

    private var navItems: [M3NavItem] {
        let active = downloads.jobs.filter(\.isActive).count
        return [
            M3NavItem(tab: .home, title: "홈", icon: "house", selectedIcon: "house.fill"),
            M3NavItem(tab: .search, title: "검색", icon: "magnifyingglass", selectedIcon: "magnifyingglass"),
            M3NavItem(tab: .library, title: "보관함", icon: "square.stack", selectedIcon: "square.stack.fill", badge: active),
            M3NavItem(tab: .stats, title: "통계", icon: "chart.bar", selectedIcon: "chart.bar.fill"),
            M3NavItem(tab: .settings, title: "설정", icon: "gearshape", selectedIcon: "gearshape.fill")
        ]
    }

    var body: some View {
        @Bindable var router = router
        @Bindable var coordinator = coordinator

        Group {
            if usesPanel {
                regularLayout
            } else {
                compactLayout
            }
        }
        .background(Color.m3Background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .tint(Color.m3Primary)
        .environment(\.windowSize, windowSize)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            windowSize = size
            windowWidth = size.width
        }
        .task { verification.install() }
        .onAppear { updateTheme() }
        .onChange(of: player.currentColor) { _, _ in updateTheme() }
        .onChange(of: accent) { _, _ in updateTheme() }
        .onChange(of: dynamicColors) { _, _ in updateTheme() }
        .onChange(of: amoled) { _, _ in updateTheme() }
        .onChange(of: router.selectedTab) { _, tab in
            visited.insert(tab)
            router.navHidden = false
        }
        .onChange(of: router.showSettings) { _, show in
            // 예전 '설정 창 열기' 요청은 설정 탭으로 바꾼다.
            guard show else { return }
            router.showSettings = false
            router.showPlayer = false
            router.selectedTab = .settings
        }
        .onChange(of: router.showNewPlaylist) { _, showing in
            if showing { newPlaylistName = "" }
        }
        .animation(.panel, value: showsPanel)
        .fullScreenCover(isPresented: Binding(
            get: { usesPanel && router.showPlayer },
            set: { router.showPlayer = $0 }
        )) {
            NowPlayingView()
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
                router.open(.playlist(playlist.id))
            }
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

    // MARK: 아이폰

    private var compactLayout: some View {
        @Bindable var router = router
        return GeometryReader { proxy in
            let barHeight = M3NavigationBar.height(dynamicStyle: dynamicNavStyle)
            let bottomSafe = proxy.safeAreaInsets.bottom
            let navVisible = !router.navHidden
            let navInset = navVisible ? barHeight + bottomSafe : bottomSafe
            let miniReserve: CGFloat = player.hasItem && !router.hidesMiniPlayer ? 80 + 16 : 0

            ZStack(alignment: .bottom) {
                tabContent(bottomReserve: (navVisible ? barHeight : 0) + miniReserve + 8)

                M3NavigationBar(items: navItems, selection: $router.selectedTab) { tab in
                    popToRoot(tab)
                }
                .offset(y: navVisible && !router.showPlayer ? 0 : barHeight + bottomSafe + 4)
                .animation(M3Motion.navBar, value: router.navHidden)
                .animation(M3Motion.sheet, value: router.showPlayer)

                M3PlayerSheet(bottomInset: navInset)
                    .animation(M3Motion.navBar, value: router.navHidden)

                snackbarHost(bottom: (navVisible ? barHeight : 0) + miniReserve + 8)
            }
        }
    }

    // MARK: 아이패드

    private var regularLayout: some View {
        @Bindable var router = router
        return HStack(spacing: 0) {
            M3NavigationRail(items: navItems, selection: $router.selectedTab, onReselect: { popToRoot($0) }) {
                router.newPlaylist()
            }

            ZStack(alignment: .bottom) {
                tabContent(bottomReserve: player.hasItem && !showsPanel ? 96 : 16)
                if player.hasItem && !showsPanel && !router.hidesMiniPlayer {
                    MiniPlayer { router.openPanel(.artwork) }
                        .frame(maxWidth: 640)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                snackbarHost(bottom: player.hasItem && !showsPanel ? 104 : 24)
            }
            .frame(maxWidth: .infinity)

            if showsPanel {
                PanelResizeHandle(width: panelWidth, range: panelWidthRange) { next in
                    withAnimation(.smooth(duration: 0.3)) { savedPanelWidth = Double(next) }
                } onReset: {
                    withAnimation(.panel) { savedPanelWidth = 0 }
                }
                .zIndex(2)
                .transition(.opacity)
                NowPlayingPanel()
                    .frame(width: panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: 탭 내용 (한 번 연 탭은 살려 두어 스크롤 위치가 남는다)

    private func tabContent(bottomReserve: CGFloat) -> some View {
        let selectedIndex = Self.tabs.firstIndex(of: router.selectedTab) ?? 0
        return GeometryReader { proxy in
            ZStack {
                ForEach(Array(Self.tabs.enumerated()), id: \.element) { index, tab in
                    if visited.contains(tab) || tab == router.selectedTab {
                        let selected = tab == router.selectedTab
                        stack(tab)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                Color.clear.frame(height: bottomReserve)
                            }
                            .opacity(selected ? 1 : 0)
                            .offset(x: selected ? 0 : (index < selectedIndex ? -proxy.size.width / 3 : proxy.size.width / 3))
                            .allowsHitTesting(selected)
                            .accessibilityHidden(!selected)
                            .zIndex(selected ? 1 : 0)
                    }
                }
            }
            .animation(M3Motion.tab, value: router.selectedTab)
        }
    }

    @ViewBuilder
    private func stack(_ tab: AppTab) -> some View {
        NavigationStack(path: router.path(tab)) {
            Group {
                switch tab {
                case .home: HomeView()
                case .search: SearchView()
                case .library: LibraryView()
                case .stats: StatsView()
                case .settings: SettingsView()
                default: HomeView()
                }
            }
            .screenBackground(nil)
            .background(Color.m3Background.ignoresSafeArea())
            .withRoutes()
        }
    }

    /// 지금 탭을 다시 누르면 맨 처음 화면으로 돌아간다.
    private func popToRoot(_ tab: AppTab) {
        withAnimation(M3Motion.tab) { router.paths[tab] = [] }
        router.navHidden = false
    }

    // MARK: 스낵바

    private func snackbarHost(bottom: CGFloat) -> some View {
        GlassToastHost()
            .padding(.bottom, bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .animation(M3Motion.navBar, value: bottom)
    }

    // MARK: 색

    private func updateTheme() {
        let seed: UIColor
        if dynamicColors, player.hasItem {
            seed = UIColor(player.currentColor)
        } else {
            seed = UIColor(accent.color)
        }
        M3ThemeStore.shared.update(seed: seed, amoled: amoled)
    }
}

extension View {
    /// 모든 탭에서 같은 화면 이동 규칙을 쓴다.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestination(route: route)
                .background(Color.m3Background.ignoresSafeArea())
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
        case .downloads: DownloadsScreen().screenBackground(nil)
        }
    }
}

/// 패널 폭 손잡이. 끄는 동안에는 손잡이만 움직이고, 손을 떼면 한 번에 폭이 바뀐다. 두 번 누르면 기본 폭.
private struct PanelResizeHandle: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void
    let onReset: () -> Void

    @GestureState private var translation: CGFloat = 0

    private var offset: CGFloat {
        let target = min(max(width - translation, range.lowerBound), range.upperBound)
        return width - target
    }

    var body: some View {
        let dragging = translation != 0
        Color.m3Background
            .frame(width: 12)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(dragging ? Color.m3Primary : Color.m3OutlineVariant)
                    .frame(width: 4, height: dragging ? 88 : 44)
                    .offset(x: offset)
            }
            .overlay {
                if dragging {
                    Rectangle()
                        .fill(Color.m3Primary.opacity(0.5))
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
