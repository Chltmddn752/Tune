import SwiftData
import SwiftUI

/// 바로가기 칸 하나 (앨범 또는 플레이리스트)
private enum Shortcut: Identifiable {
    case album(Album)
    case playlist(Playlist)

    var id: UUID {
        switch self {
        case .album(let a): a.id
        case .playlist(let p): p.id
        }
    }

    var date: Date {
        switch self {
        case .album(let a): a.lastPlayedAt ?? .distantPast
        case .playlist(let p): p.lastPlayedAt ?? .distantPast
        }
    }

    var title: String {
        switch self {
        case .album(let a): a.title
        case .playlist(let p): p.name
        }
    }

    var route: Route {
        switch self {
        case .album(let a): .album(a.id)
        case .playlist(let p): .playlist(p.id)
        }
    }
}

struct HomeView: View {
    @Query(sort: \Album.addedAt, order: .reverse) private var albums: [Album]
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]
    @Query(sort: \Artist.name) private var artists: [Artist]
    @Query private var tracks: [Track]
    @Query private var recentEvents: [PlayEvent]
    @Query private var allEvents: [PlayEvent]
    @Environment(Router.self) private var router
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(M3SettingsKey.userName) private var userName = ""
    @State private var scrollOffset: CGFloat = 0

    init() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        _recentEvents = Query(filter: #Predicate<PlayEvent> { $0.date > cutoff })
    }

    var body: some View {
        ZStack(alignment: .top) {
            M3TopGradient(scrollOffset: scrollOffset)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if albums.isEmpty && playlists.isEmpty {
                        EmptyLibraryView()
                            .padding(.top, 40)
                    } else {
                        content
                    }
                }
                .padding(.bottom, 24)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrollOffset = max(0, offset)
            }
            .m3HidesNavOnScroll()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: 맨 위: 검색 막대 · 장르 칩 · 인사말

    private var header: some View {
        let padding = Spacing.screen(sizeClass)
        return VStack(alignment: .leading, spacing: 12) {
            // 누르면 검색 탭으로 가는 알약 검색 막대 (오른쪽은 설정으로 가는 동그라미)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.m3OnSurfaceVariant)
                Text("노래, 앨범, 아티스트 검색")
                    .font(.m3BodyLarge)
                    .foregroundStyle(Color.m3OnSurfaceVariant)
                Spacer(minLength: 0)
                Button {
                    router.selectedTab = .settings
                } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.m3Primary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("설정")
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(height: 56)
            .background(Color.m3SurfaceContainerLow, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { router.selectedTab = .search }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("검색")
            .padding(.horizontal, padding)
            .padding(.top, 8)

            let genres = topGenres
            if !genres.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        M3FilterChip(title: "좋아요", systemImage: "heart", isSelected: false) {
                            router.open(.favorites)
                        }
                        ForEach(genres, id: \.self) { genre in
                            M3FilterChip(title: genre, isSelected: false) {
                                router.open(.genre(genre))
                            }
                        }
                    }
                    .padding(.horizontal, padding)
                }
                .scrollIndicators(.hidden)
            }

            greeting
                .padding(.horizontal, padding + 8)
                .padding(.vertical, 12)
        }
    }

    /// "좋은 저녁이에요" + 이름 (SpatialFlow WelcomeGreetingBanner)
    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: .now)
        let (text, symbol): (String, String) = switch hour {
        case 0..<12: ("좋은 아침이에요", "sun.horizon.fill")
        case 12..<17: ("좋은 오후예요", "sun.max.fill")
        default: ("좋은 저녁이에요", "moon.stars.fill")
        }
        let name = userName.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.m3Primary)
                Text(text)
                    .font(.m3TitleMedium)
                    .foregroundStyle(Color.m3OnSurfaceVariant)
            }
            Text(name.isEmpty ? "리스너" : name)
                .font(.m3(32, .heavy))
                .tracking(-1)
                .foregroundStyle(Color.m3OnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: 섹션들

    private var content: some View {
        let padding = Spacing.screen(sizeClass)
        let shortcuts = recentShortcuts

        return VStack(alignment: .leading, spacing: 28) {
            if !shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    M3ShelfHeader(title: "빠른 선택")
                        .padding(.horizontal, padding)
                    speedDial(shortcuts)
                        .padding(.horizontal, padding)
                }
            }

            let mixes = MixMaker.mixes(tracks: tracks, events: allEvents)
            if !mixes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    M3ShelfHeader(title: "나를 위한 믹스")
                        .padding(.horizontal, padding)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(mixes) { mix in
                                NavigationLink(value: Route.mix(mix.id)) {
                                    MixDiscoverCard(mix: mix, size: sizeClass == .regular ? 320 : 300)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, padding)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            shelf("최근 추가", destination: .recentlyAdded, items: Array(albums.prefix(15)))

            let frequent = frequentAlbums
            if !frequent.isEmpty {
                shelf("자주 듣는", destination: nil, items: frequent)
            }

            VStack(alignment: .leading, spacing: 8) {
                M3ShelfHeader(title: "내 플레이리스트", destination: .playlists)
                    .padding(.horizontal, padding)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(playlists.prefix(15)) { PlaylistCard(playlist: $0, width: cardWidth) }
                        NewPlaylistCard(width: cardWidth)
                    }
                    .padding(.horizontal, padding)
                }
                .scrollIndicators(.hidden)
            }

            if let active = downloads.activeJob {
                downloadActivity(active)
                    .padding(.horizontal, padding)
            }
        }
    }

    private var cardWidth: CGFloat { sizeClass == .regular ? 180 : 160 }

    /// 3×3 정사각형 바로가기 (SpatialFlow Speed dial)
    private func speedDial(_ shortcuts: [Shortcut]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: sizeClass == .regular ? 5 : 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(shortcuts) { shortcut in
                ShortcutTile(shortcut: shortcut, tracks: tracks(for: shortcut))
            }
        }
    }

    private func shelf(_ title: String, destination: Route?, items: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            M3ShelfHeader(title: title, playAll: items.isEmpty ? nil : {
                player.play(items.flatMap(\.sortedTracks))
            }, destination: destination)
                .padding(.horizontal, Spacing.screen(sizeClass))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { AlbumCard(album: $0, width: cardWidth) }
                }
                .padding(.horizontal, Spacing.screen(sizeClass))
            }
            .scrollIndicators(.hidden)
        }
    }

    private func downloadActivity(_ job: DownloadJob) -> some View {
        Button {
            router.openDownloads()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.m3Primary)
                    Text(job.title)
                        .font(.m3TitleSmall.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.tuneTime)
                        .foregroundStyle(Color.m3OnSurfaceVariant)
                        .contentTransition(.numericText())
                }
                M3LinearProgress(progress: min(max(job.progress, 0), 1))
                HStack {
                    Text("\(job.displayArtist) · \(job.providerName)")
                        .font(.m3BodySmall)
                        .foregroundStyle(Color.m3OnSurfaceVariant)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text("다운로드 열기")
                        .font(.m3LabelMedium.weight(.bold))
                        .foregroundStyle(Color.m3Primary)
                }
            }
            .padding(Spacing.l)
            .m3Card(.m3SurfaceContainerHigh, radius: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 데이터

    private var topGenres: [String] {
        var counts: [String: Int] = [:]
        for track in tracks where !track.genre.isEmpty {
            counts[track.genre, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(8).map(\.key)
    }

    private var recentShortcuts: [Shortcut] {
        let played = albums.filter { $0.lastPlayedAt != nil }.map(Shortcut.album)
            + playlists.filter { $0.lastPlayedAt != nil }.map(Shortcut.playlist)
        var result = played.sorted { $0.date > $1.date }
        if result.count < 9 {
            // 아직 들은 게 적으면 최근 추가한 앨범으로 채운다.
            let ids = Set(result.map(\.id))
            result += albums.filter { !ids.contains($0.id) }.prefix(9 - result.count).map(Shortcut.album)
        }
        return Array(result.prefix(9))
    }

    private func tracks(for shortcut: Shortcut) -> [Track] {
        switch shortcut {
        case .album(let album):
            return album.sortedTracks
        case .playlist(let playlist):
            let order = playlist.sortedEntries.map(\.trackID)
            let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return order.compactMap { byID[$0] }
        }
    }

    private var frequentAlbums: [Album] {
        let counts = Dictionary(grouping: recentEvents) { Album.makeKey(title: $0.albumTitle, artist: $0.albumArtistName) }
            .mapValues(\.count)
        return albums
            .filter { (counts[$0.key] ?? 0) >= 2 }
            .sorted { (counts[$0.key] ?? 0) > (counts[$1.key] ?? 0) }
            .prefix(15)
            .map { $0 }
    }
}

/// 믹스 큰 카드 (SpatialFlow "Your daily discover"): 커버를 꽉 채우고 아래 그라데이션 위에 제목 · 설명 · 추천 이유
struct MixDiscoverCard: View {
    let mix: Mix
    var size: CGFloat = 300
    @Query private var tracks: [Track]

    init(mix: Mix, size: CGFloat = 300) {
        self.mix = mix
        self.size = size
        let ids = Array(mix.trackIDs.prefix(12))
        _tracks = Query(filter: #Predicate<Track> { ids.contains($0.id) })
    }

    var body: some View {
        let files = Array((NSOrderedSet(array: tracks.compactMap(\.artworkFile)).array as? [String] ?? []).prefix(4))
        let tint = Color(hex: tracks.first?.album?.colorHex, fallback: Color.m3Primary)
        let artists = Array(NSOrderedSet(array: tracks.map(\.artistName)).array as? [String] ?? []).prefix(2)
        ZStack(alignment: .bottomLeading) {
            Group {
                if files.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { ArtworkView(file: files[0], cornerRadius: 0); ArtworkView(file: files[1], cornerRadius: 0) }
                        GridRow { ArtworkView(file: files[2], cornerRadius: 0); ArtworkView(file: files[3], cornerRadius: 0) }
                    }
                } else if let first = files.first {
                    ArtworkView(file: first, cornerRadius: 0)
                } else {
                    tint
                }
            }
            .frame(width: size, height: size)

            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: mix.symbol)
                    Text(mix.title)
                        .lineLimit(1)
                }
                .font(.m3(20, .bold))
                Text(mix.subtitle)
                    .font(.m3(13))
                    .opacity(0.85)
                    .lineLimit(1)
                if !artists.isEmpty {
                    Text("\(artists.joined(separator: ", ")) 같은 곡이 좋았다면")
                        .font(.m3(12).italic())
                        .opacity(0.7)
                        .lineLimit(1)
                        .padding(.top, 6)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// M3 선형 진행 막대 (둥근 끝 + 사이 틈)
struct M3LinearProgress: View {
    var progress: Double

    var body: some View {
        GeometryReader { proxy in
            let filled = proxy.size.width * CGFloat(min(max(progress, 0), 1))
            HStack(spacing: 4) {
                Capsule().fill(Color.m3Primary).frame(width: max(4, filled))
                if filled < proxy.size.width - 8 {
                    Capsule().fill(Color.m3SecondaryContainer)
                }
            }
        }
        .frame(height: 4)
        .animation(.smooth, value: progress)
    }
}

/// 바로가기 칸 (SpatialFlow Speed dial): 정사각형 커버 위 아래 그라데이션에 제목
private struct ShortcutTile: View {
    let shortcut: Shortcut
    let tracks: [Track]

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        NavigationLink(value: shortcut.route) {
            ZStack(alignment: .bottomLeading) {
                cover
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Text(shortcut.title)
                    .font(.m3(12, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !tracks.isEmpty {
                Button { play(shuffled: false) } label: { Label("재생", systemImage: "play") }
                Button { play(shuffled: true) } label: { Label("셔플", systemImage: "shuffle") }
            }
        }
    }

    @ViewBuilder private var cover: some View {
        switch shortcut {
        case .album(let album):
            ArtworkView(file: album.artworkFile, cornerRadius: 0,
                        colorHex: album.colorHex, title: album.title)
        case .playlist(let playlist):
            PlaylistCover(playlist: playlist, cornerRadius: 0)
        }
    }

    private func play(shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        player.play(tracks, shuffled: shuffled)
    }
}

/// "새 플레이리스트" 카드 (플레이리스트 줄 맨 끝)
private struct NewPlaylistCard: View {
    var width: CGFloat
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.newPlaylist()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.m3PrimaryContainer)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(Color.m3OnPrimaryContainer)
                    }
                Text("새 플레이리스트")
                    .font(.tuneSubtitle)
                    .foregroundStyle(.primary)
                Text(" ").font(.tuneCaption)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("새 플레이리스트 만들기")
    }
}
