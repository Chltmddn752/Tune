import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @State private var verification = ExtensionVerificationCenter.shared
    @Namespace private var playerNamespace
    @State private var newPlaylistName = ""

    /// 아이패드처럼 넓은 화면이면 오른쪽 재생 패널을 쓴다.
    private var usesPanel: Bool { sizeClass == .regular }
    @State private var windowWidth: CGFloat = 1194

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

        HStack(spacing: 0) {
        TabView(selection: $router.selectedTab) {
            Tab("홈", systemImage: "house.fill", value: AppTab.home) {
                stack(.home) { HomeView() }
            }
            // 아이폰: 보관함 탭 하나. 아이패드: 사이드바에 보관함·플레이리스트 섹션을 펼친다.
            if !usesPanel {
                Tab("보관함", systemImage: "square.stack.fill", value: AppTab.library) {
                    stack(.library) { LibraryView() }
                }
            }
            Tab("통계", systemImage: "chart.bar.xaxis", value: AppTab.stats) {
                stack(.stats) { StatsView() }
            }

            if usesPanel {
            TabSection("보관함") {
                Tab("최근 추가된 항목", systemImage: "clock", value: AppTab.libRecent) {
                    stack(.libRecent) { RecentlyAddedView() }
                }
                Tab("아티스트", systemImage: "music.mic", value: AppTab.libArtists) {
                    stack(.libArtists) { ArtistsListView() }
                }
                Tab("앨범", systemImage: "square.stack", value: AppTab.libAlbums) {
                    stack(.libAlbums) { AlbumsListView() }
                }
                Tab("노래", systemImage: "music.note", value: AppTab.libSongs) {
                    stack(.libSongs) { SongsListView() }
                }
                Tab("장르", systemImage: "guitars", value: AppTab.libGenres) {
                    stack(.libGenres) { GenresListView() }
                }
                Tab("좋아요 표시한 곡", systemImage: "star", value: AppTab.libFavorites) {
                    stack(.libFavorites) { FavoritesView() }
                }
            }

            TabSection("플레이리스트") {
                Tab("모든 플레이리스트", systemImage: "square.grid.3x3", value: AppTab.allPlaylists) {
                    stack(.allPlaylists) { PlaylistsListView() }
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
                stack(.search) { SearchView() }
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
        .tabViewBottomAccessory(isEnabled: player.hasItem && !showsPanel) {
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
        .background(Color(.systemBackground).ignoresSafeArea())
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
            VStack(spacing: 6) {
                ImportBanner()
                VerificationBanner()
                PlaybackNoticeBanner()
            }
        }
    }

    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: router.path(tab)) {
            content().withRoutes()
        }
    }
}

/// 재생하지 못한 곡 안내를 위에 잠깐 보여 준다.
struct PlaybackNoticeBanner: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Group {
            if let notice = player.playbackNotice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.horizontal, 24)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if player.playbackNotice == notice { player.playbackNotice = nil }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: player.playbackNotice)
    }
}

/// 서명 세션 인증이 필요하거나 끝났을 때 위에 잠깐 보여 준다.
struct VerificationBanner: View {
    @Environment(ExtensionStore.self) private var extensions
    @State private var center = ExtensionVerificationCenter.shared

    private var title: String {
        guard let id = center.pending?.extensionID,
              let installed = extensions.installedExtension(id: id) else { return "확장 인증" }
        return installed.title
    }

    var body: some View {
        Group {
            if let error = center.lastError, center.pending != nil {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(title) 인증이 필요해요").font(.subheadline.weight(.semibold))
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("다시 열기") { center.start() }
                        .font(.caption.weight(.semibold))
                    Button { center.dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("인증 안내 닫기")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.horizontal, 24)
            } else if center.isAuthenticating, center.pending != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("\(title) 인증 페이지를 여는 중").font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
            } else if center.pending != nil {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.key").foregroundStyle(Color.tuneAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(title) 인증이 필요해요").font(.subheadline.weight(.semibold))
                        Text("서비스 계정을 확인하면 다운로드를 이어갈 수 있어요.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("인증하기") { center.start() }
                        .font(.caption.weight(.semibold))
                    Button { center.dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("인증 안내 닫기")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.horizontal, 24)
            } else if let message = center.lastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tuneAccent)
                    Text(message).font(.subheadline.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { center.clearMessage() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("인증 완료 안내 닫기")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.horizontal, 24)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(6))
                    if center.lastMessage == message { center.clearMessage() }
                }
            }
        }
        .animation(.smooth, value: center.pending)
        .animation(.smooth, value: center.lastError)
        .animation(.smooth, value: center.lastMessage)
    }
}

/// 가져오는 중 / 가져오기 결과를 위에 잠깐 보여준다.
struct ImportBanner: View {
    @Environment(LibraryImporter.self) private var importer
    @State private var visibleResult: String?

    var body: some View {
        Group {
            if importer.isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("가져오는 중 \(importer.done)/\(importer.total)")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
            } else if let visibleResult {
                Text(visibleResult)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
            }
        }
        .padding(.top, 4)
        .animation(.smooth, value: importer.isWorking)
        .animation(.smooth, value: visibleResult)
        .onChange(of: importer.lastResult) { _, result in
            guard let result else { return }
            visibleResult = result
            Task {
                try? await Task.sleep(for: .seconds(3))
                if visibleResult == result { visibleResult = nil }
                importer.lastResult = nil
            }
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
        case .providerAlbum(let route): ProviderAlbumScreen(route: route)
        case .providerArtist(let route): ProviderArtistScreen(route: route)
        case .playlist(let id): PlaylistScreen(playlistID: id)
        case .songs: SongsListView()
        case .albums: AlbumsListView()
        case .artists: ArtistsListView()
        case .playlists: PlaylistsListView()
        case .genres: GenresListView()
        case .genre(let name): GenreView(genre: name)
        case .favorites: FavoritesView()
        case .recentlyAdded: RecentlyAddedView()
        case .mix(let id): MixScreen(mixID: id)
        case .wishlist: WishlistView()
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

    @GestureState private var translation: CGFloat = 0

    private var offset: CGFloat {
        let target = min(max(width - translation, range.lowerBound), range.upperBound)
        return width - target
    }

    var body: some View {
        let dragging = translation != 0
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(dragging ? Color.tuneAccent : Color.secondary.opacity(0.35))
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
