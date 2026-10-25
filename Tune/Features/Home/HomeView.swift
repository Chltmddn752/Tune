import SwiftData
import SwiftUI

enum HomeFilter: String, CaseIterable, Identifiable {
    case all = "전체", albums = "앨범", playlists = "플레이리스트", artists = "아티스트"
    var id: String { rawValue }
}

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
}

struct HomeView: View {
    @Query(sort: \Album.addedAt, order: .reverse) private var albums: [Album]
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]
    @Query(sort: \Artist.name) private var artists: [Artist]
    @Query private var recentEvents: [PlayEvent]
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: HomeFilter = .all

    init() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        _recentEvents = Query(filter: #Predicate<PlayEvent> { $0.date > cutoff })
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                EmptyLibraryView()
            } else {
                content
            }
        }
        .navigationTitle("홈")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showSettings = true } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("설정")
            }
        }
    }

    private var content: some View {
        let padding = Spacing.screen(sizeClass)
        let shortcuts = recentShortcuts
        let headerColor = shortcuts.first.flatMap { shortcut -> String? in
            if case .album(let album) = shortcut { return album.colorHex }
            return nil
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxxl) {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.s) {
                            ForEach(HomeFilter.allCases) { option in
                                FilterChip(title: option.rawValue, isSelected: filter == option) { filter = option }
                            }
                        }
                        .padding(.horizontal, padding)
                    }
                    .scrollIndicators(.hidden)

                    if !shortcuts.isEmpty && (filter == .all || filter == .albums || filter == .playlists) {
                        shortcutGrid(shortcuts)
                            .padding(.horizontal, padding)
                    }
                }

                if filter == .all || filter == .albums {
                    shelf("최근 추가한 앨범", destination: .recentlyAdded, items: Array(albums.prefix(15)))
                    let frequent = frequentAlbums
                    if !frequent.isEmpty { shelf("자주 듣는 앨범", destination: nil, items: frequent) }
                }

                if filter == .all || filter == .artists {
                    let topArtists = frequentArtists
                    if !topArtists.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            SectionHeader("자주 듣는 아티스트", destination: .artists)
                                .padding(.horizontal, padding)
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: Spacing.l) {
                                    ForEach(topArtists) { ArtistCircle(artist: $0, width: cardWidth) }
                                }
                                .padding(.horizontal, padding)
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                }

                if filter == .all || filter == .playlists {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SectionHeader("내 플레이리스트", destination: .playlists)
                            .padding(.horizontal, padding)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: Spacing.l) {
                                NewPlaylistCard(width: cardWidth)
                                ForEach(playlists.prefix(15)) { PlaylistCard(playlist: $0, width: cardWidth) }
                            }
                            .padding(.horizontal, padding)
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                if filter == .all || filter == .albums {
                    let forgotten = forgottenAlbums
                    if !forgotten.isEmpty { shelf("오랫동안 안 들은 앨범", destination: nil, items: forgotten) }
                }
            }
            .padding(.vertical, Spacing.l)
        }
        .background(alignment: .top) {
            // 마지막에 들은 곡 커버색이 위에서 아래로 사라진다.
            LinearGradient(colors: [Color(hex: headerColor, fallback: .clear).opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 360)
                .ignoresSafeArea()
                .animation(.backgroundFade, value: headerColor)
        }
    }

    private var cardWidth: CGFloat { sizeClass == .regular ? 180 : 160 }

    private func shortcutGrid(_ shortcuts: [Shortcut]) -> some View {
        // 넓은 화면(재생 패널을 열어 둔 아이패드 포함)에서는 칸 폭에 맞춰 열 수를 정한다.
        let columns = sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 230), spacing: Spacing.s)]
            : Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 2)
        return LazyVGrid(columns: columns, spacing: Spacing.s) {
            ForEach(shortcuts) { shortcut in
                ShortcutTile(shortcut: shortcut)
            }
        }
    }

    private func shelf(_ title: String, destination: Route?, items: [Album]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title, destination: destination)
                .padding(.horizontal, Spacing.screen(sizeClass))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.l) {
                    ForEach(items) { AlbumCard(album: $0, width: cardWidth) }
                }
                .padding(.horizontal, Spacing.screen(sizeClass))
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 데이터

    private var recentShortcuts: [Shortcut] {
        let played = albums.filter { $0.lastPlayedAt != nil }.map(Shortcut.album)
            + playlists.filter { $0.lastPlayedAt != nil }.map(Shortcut.playlist)
        var result = played.sorted { $0.date > $1.date }
        if filter == .albums { result = result.filter { if case .album = $0 { true } else { false } } }
        if filter == .playlists { result = result.filter { if case .playlist = $0 { true } else { false } } }
        if result.count < 8 && filter != .playlists {
            // 아직 들은 게 적으면 최근 추가한 앨범으로 채운다.
            let ids = Set(result.map(\.id))
            result += albums.filter { !ids.contains($0.id) }.prefix(8 - result.count).map(Shortcut.album)
        }
        return Array(result.prefix(8))
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

    private var frequentArtists: [Artist] {
        var counts: [String: Int] = [:]
        for event in recentEvents {
            for name in NameSplitter.artists(event.artistName) { counts[name.lowercased(), default: 0] += 1 }
        }
        let ranked = artists.filter { (counts[$0.key] ?? 0) > 0 }.sorted { (counts[$0.key] ?? 0) > (counts[$1.key] ?? 0) }
        return Array((ranked.isEmpty ? Array(artists.prefix(12)) : ranked).prefix(15))
    }

    private var forgottenAlbums: [Album] {
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        return albums.filter { ($0.lastPlayedAt ?? .distantFuture) < cutoff }.shuffled().prefix(15).map { $0 }
    }
}

/// Spotify 방식 바로가기 칸: 왼쪽에 커버, 오른쪽에 굵은 제목 두 줄
private struct ShortcutTile: View {
    let shortcut: Shortcut
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: Spacing.s) {
                cover
                    .frame(width: 56, height: 56)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(height: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { play(shuffled: false) } label: { Label("재생", systemImage: "play") }
            Button { play(shuffled: true) } label: { Label("셔플", systemImage: "shuffle") }
        }
    }

    @ViewBuilder private var cover: some View {
        switch shortcut {
        case .album(let album): ArtworkView(file: album.artworkFile, cornerRadius: 0)
        case .playlist(let playlist): PlaylistCover(playlist: playlist)
        }
    }

    private var title: String {
        switch shortcut {
        case .album(let album): album.title
        case .playlist(let playlist): playlist.name
        }
    }

    private var route: Route {
        switch shortcut {
        case .album(let album): .album(album.id)
        case .playlist(let playlist): .playlist(playlist.id)
        }
    }

    private func play(shuffled: Bool) {
        switch shortcut {
        case .album(let album):
            player.play(album.sortedTracks, shuffled: shuffled, context: .album(album.id))
        case .playlist:
            break
        }
    }
}

/// "새 플레이리스트" 카드 (플레이리스트 줄 맨 앞)
private struct NewPlaylistCard: View {
    var width: CGFloat
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.newPlaylist()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(Color.tuneAccent)
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
