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
    @Environment(Router.self) private var router
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass

    init() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        _recentEvents = Query(filter: #Predicate<PlayEvent> { $0.date > cutoff })
    }

    var body: some View {
        Group {
            if albums.isEmpty && playlists.isEmpty {
                ScrollView { EmptyLibraryView() }
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
        let headerColor = shortcuts.first.flatMap { colorHex(for: $0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxxl) {
                if !shortcuts.isEmpty {
                    shortcutGrid(shortcuts)
                        .padding(.horizontal, padding)
                }

                shelf("최근 추가", destination: .recentlyAdded, items: Array(albums.prefix(15)))

                let frequent = frequentAlbums
                if !frequent.isEmpty {
                    shelf("자주 듣는", destination: nil, items: frequent)
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("내 플레이리스트", destination: .playlists)
                        .padding(.horizontal, padding)
                    if playlists.isEmpty {
                        // 플레이리스트가 없을 때는 큰 카드 대신 한 줄 버튼만.
                        Button { router.newPlaylist() } label: {
                            Label("새 플레이리스트 만들기", systemImage: "plus")
                                .font(.tuneSubtitle.weight(.semibold))
                                .foregroundStyle(Color.tuneAccent)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, padding)
                        .accessibilityHint("새 플레이리스트를 만들어요")
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: Spacing.l) {
                                ForEach(playlists.prefix(15)) { PlaylistCard(playlist: $0, width: cardWidth) }
                                NewPlaylistCard(width: cardWidth)
                            }
                            .padding(.horizontal, padding)
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                if let active = downloads.activeJob {
                    downloadActivity(active)
                        .padding(.horizontal, padding)
                }
            }
            .padding(.vertical, Spacing.l)
            .padding(.bottom, 96)
        }
        .background(alignment: .top) {
            // 마지막에 들은 곡 커버색이 위에서 아래로 사라진다.
            LinearGradient(colors: [Color(hex: headerColor, fallback: .clear).opacity(0.35), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .ignoresSafeArea()
                .animation(.backgroundFade, value: headerColor)
        }
    }

    private var cardWidth: CGFloat { sizeClass == .regular ? 180 : 152 }

    private func shortcutGrid(_ shortcuts: [Shortcut]) -> some View {
        let columns = sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 230), spacing: Spacing.m)]
            : Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 2)
        return LazyVGrid(columns: columns, spacing: Spacing.m) {
            ForEach(shortcuts) { shortcut in
                ShortcutTile(
                    shortcut: shortcut,
                    colorHex: colorHex(for: shortcut),
                    tracks: tracks(for: shortcut)
                )
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

    private func downloadActivity(_ job: DownloadJob) -> some View {
        Button {
            router.selectedTab = .downloads
        } label: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.tuneAccent)
                    Text(job.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.tuneTime)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                ProgressView(value: min(max(job.progress, 0), 1))
                    .tint(Color.tuneAccent)
                HStack {
                    Text("\(job.displayArtist) · \(job.providerName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text("다운로드 열기")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.tuneAccent)
                }
            }
            .padding(Spacing.l)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 데이터

    private var recentShortcuts: [Shortcut] {
        let played = albums.filter { $0.lastPlayedAt != nil }.map(Shortcut.album)
            + playlists.filter { $0.lastPlayedAt != nil }.map(Shortcut.playlist)
        var result = played.sorted { $0.date > $1.date }
        if result.count < 8 {
            // 아직 들은 게 적으면 최근 추가한 앨범으로 채운다.
            let ids = Set(result.map(\.id))
            result += albums.filter { !ids.contains($0.id) }.prefix(8 - result.count).map(Shortcut.album)
        }
        return Array(result.prefix(8))
    }

    private func colorHex(for shortcut: Shortcut) -> String? {
        switch shortcut {
        case .album(let album):
            return album.colorHex
        case .playlist(let playlist):
            let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for entry in playlist.sortedEntries {
                if let hex = byID[entry.trackID]?.album?.colorHex { return hex }
            }
            return nil
        }
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

/// 바로가기 칸: 왼쪽 정사각형 커버 + 오른쪽 두 줄 제목. 배경은 시스템 채움색 하나로 통일한다.
private struct ShortcutTile: View {
    let shortcut: Shortcut
    let colorHex: String?
    let tracks: [Track]

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        NavigationLink(value: shortcut.route) {
            HStack(spacing: 0) {
                cover
                    .frame(width: 56, height: 56)
                    .clipped()
                Text(shortcut.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 56)
            .background(Color(.secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
