import SwiftData
import SwiftUI

enum LibraryMenuItem: String, CaseIterable, Identifiable {
    case playlists, artists, albums, songs, genres, favorites
    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: "플레이리스트"
        case .artists: "아티스트"
        case .albums: "앨범"
        case .songs: "노래"
        case .genres: "장르"
        case .favorites: "좋아요 표시한 곡"
        }
    }

    var icon: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .favorites: "star"
        }
    }

    var route: Route {
        switch self {
        case .playlists: .playlists
        case .artists: .artists
        case .albums: .albums
        case .songs: .songs
        case .genres: .genres
        case .favorites: .favorites
        }
    }
}

/// 보관함 메뉴 순서와 숨김. "albums,-genres,..." 형태로 저장한다(앞에 -가 붙으면 숨김).
struct LibraryMenuConfig {
    var order: [LibraryMenuItem]
    var hidden: Set<LibraryMenuItem>

    init(raw: String) {
        var order: [LibraryMenuItem] = []
        var hidden: Set<LibraryMenuItem> = []
        for part in raw.split(separator: ",") {
            let isHidden = part.hasPrefix("-")
            if let item = LibraryMenuItem(rawValue: String(isHidden ? part.dropFirst() : part)), !order.contains(item) {
                order.append(item)
                if isHidden { hidden.insert(item) }
            }
        }
        for item in LibraryMenuItem.allCases where !order.contains(item) { order.append(item) }
        self.order = order
        self.hidden = hidden
    }

    var raw: String {
        order.map { hidden.contains($0) ? "-\($0.rawValue)" : $0.rawValue }.joined(separator: ",")
    }

    var visible: [LibraryMenuItem] { order.filter { !hidden.contains($0) } }
}

struct LibraryView: View {
    @Query(sort: \Album.addedAt, order: .reverse) private var albums: [Album]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(SettingsKey.libraryMenu) private var menuRaw = ""
    @Environment(Router.self) private var router
    @State private var showImporter = false
    @State private var showMenuEditor = false

    var body: some View {
        let menu = LibraryMenuConfig(raw: menuRaw).visible
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(spacing: 0) {
                    ForEach(menu) { item in
                        NavigationLink(value: item.route) {
                            HStack(spacing: Spacing.l) {
                                Image(systemName: item.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color.tuneAccent)
                                    .frame(width: 30)
                                Text(item.title)
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 46)
                    }
                }
                .padding(.horizontal, Spacing.screen(sizeClass))

                if albums.isEmpty {
                    EmptyLibraryView()
                } else {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SectionHeader("최근 추가", destination: .recentlyAdded)
                        AlbumGrid(albums: Array(albums.prefix(sizeClass == .regular ? 15 : 12)))
                    }
                    .padding(.horizontal, Spacing.screen(sizeClass))
                }
            }
            .padding(.vertical, Spacing.m)
        }
        .navigationTitle("보관함")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showMenuEditor = true } label: { Text("편집") }
                Menu {
                    Button { showImporter = true } label: { Label("음악 가져오기", systemImage: "square.and.arrow.down") }
                    Button { router.newPlaylist() } label: { Label("새 플레이리스트", systemImage: "music.note.list") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("추가")
            }
        }
        .musicImporter(isPresented: $showImporter)
        .sheet(isPresented: $showMenuEditor) {
            LibraryMenuEditor(raw: $menuRaw)
        }
    }
}

/// 보관함 메뉴 순서 바꾸기·숨기기
struct LibraryMenuEditor: View {
    @Binding var raw: String
    @Environment(\.dismiss) private var dismiss
    @State private var config = LibraryMenuConfig(raw: "")

    var body: some View {
        NavigationStack {
            List {
                ForEach(config.order) { item in
                    Button {
                        if config.hidden.contains(item) { config.hidden.remove(item) } else { config.hidden.insert(item) }
                    } label: {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: config.hidden.contains(item) ? "circle" : "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(config.hidden.contains(item) ? Color.secondary : Color.tuneAccent)
                            Image(systemName: item.icon).foregroundStyle(Color.tuneAccent).frame(width: 26)
                            Text(item.title).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onMove { config.order.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("보관함 메뉴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        raw = config.raw
                        dismiss()
                    }
                }
            }
            .onAppear { config = LibraryMenuConfig(raw: raw) }
        }
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // 화면 폭에 맞춰 열 수를 정한다(아이패드 가로 화면에서는 6~7열).
        let minimum: CGFloat = sizeClass == .regular ? 170 : 140
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Spacing.l, alignment: .top)],
                  spacing: Spacing.xl) {
            ForEach(albums) { AlbumCard(album: $0) }
        }
    }
}

// MARK: - 노래

enum SongSort: String, CaseIterable, Identifiable {
    case title = "제목", artist = "아티스트", added = "최근 추가", played = "최근 재생", count = "재생 횟수"
    var id: String { rawValue }
}

struct SongsListView: View {
    @Query private var tracks: [Track]
    @AppStorage(SettingsKey.songSort) private var sort: SongSort = .title
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let sorted = sortedTracks
        List {
            Section {
                PlayShuffleButtons {
                    player.play(sorted)
                } onShuffle: {
                    player.play(sorted, shuffled: true)
                }
                .listRowSeparator(.hidden)
            }
            if sort == .title || sort == .artist {
                ForEach(indexGroups(sorted), id: \.0) { letter, group in
                    Section {
                        ForEach(group) { TrackRow(track: $0, queue: sorted) }
                    }
                    .sectionIndexLabel(letter)
                }
            } else {
                ForEach(sorted) { TrackRow(track: $0, queue: sorted) }
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .navigationTitle("노래")
        .toolbar { sortMenu }
        .overlay { if tracks.isEmpty { EmptyLibraryView() } }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("정렬", selection: $sort) {
                    ForEach(SongSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("정렬")
        }
    }

    private var sortedTracks: [Track] {
        switch sort {
        case .title: tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: tracks.sorted { ($0.artistName.lowercased(), $0.albumTitle, $0.trackNumber) < ($1.artistName.lowercased(), $1.albumTitle, $1.trackNumber) }
        case .added: tracks.sorted { $0.addedAt > $1.addedAt }
        case .played: tracks.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .count: tracks.sorted { $0.playCount > $1.playCount }
        }
    }

    private func indexGroups(_ sorted: [Track]) -> [(String, [Track])] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for track in sorted {
            let key = IndexKey.of(sort == .artist ? track.artistName : track.title)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// 가나다·A~Z 빠른 이동용 첫 글자
enum IndexKey {
    private static let choseong = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    private static let merged = ["ㄲ": "ㄱ", "ㄸ": "ㄷ", "ㅃ": "ㅂ", "ㅆ": "ㅅ", "ㅉ": "ㅈ"]

    static func of(_ text: String) -> String {
        guard let scalar = text.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return "#" }
        if (0xAC00...0xD7A3).contains(scalar.value) {
            let c = choseong[Int((scalar.value - 0xAC00) / 588)]
            return merged[c] ?? c
        }
        let letter = String(scalar).uppercased()
        if letter.range(of: "^[A-Z]$", options: .regularExpression) != nil { return letter }
        return "#"
    }
}

// MARK: - 앨범

enum AlbumSort: String, CaseIterable, Identifiable {
    case title = "제목", artist = "아티스트", added = "최근 추가", played = "최근 재생", year = "발매 연도"
    var id: String { rawValue }
}

struct AlbumsListView: View {
    @Query private var albums: [Album]
    @AppStorage(SettingsKey.albumSort) private var sort: AlbumSort = .added
    @AppStorage(SettingsKey.albumGrid) private var grid = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let sorted = sortedAlbums
        Group {
            if grid {
                ScrollView {
                    AlbumGrid(albums: sorted)
                        .padding(.horizontal, Spacing.screen(sizeClass))
                        .padding(.vertical, Spacing.m)
                }
            } else {
                List(sorted) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        HStack(spacing: Spacing.m) {
                            ArtworkView(file: album.artworkFile, cornerRadius: Radius.listArtwork).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if album.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.tuneAccent) }
                                    Text(album.title).lineLimit(1)
                                }
                                Text(album.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contextMenu { AlbumMenuItems(album: album) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("앨범")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                    .accessibilityLabel(grid ? "목록으로 보기" : "격자로 보기")
                Menu {
                    Picker("정렬", selection: $sort) {
                        ForEach(AlbumSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .overlay { if albums.isEmpty { EmptyLibraryView() } }
    }

    private var sortedAlbums: [Album] {
        let sorted: [Album]
        switch sort {
        case .title: sorted = albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: sorted = albums.sorted { $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending }
        case .added: sorted = albums.sorted { $0.addedAt > $1.addedAt }
        case .played: sorted = albums.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .year: sorted = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        // 고정한 앨범은 맨 위
        return sorted.filter(\.isPinned) + sorted.filter { !$0.isPinned }
    }
}

struct RecentlyAddedView: View {
    @Query(sort: \Album.addedAt, order: .reverse) private var albums: [Album]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            AlbumGrid(albums: albums)
                .padding(.horizontal, Spacing.screen(sizeClass))
                .padding(.vertical, Spacing.m)
        }
        .navigationTitle("최근 추가")
    }
}

// MARK: - 아티스트

struct ArtistsListView: View {
    @Query(sort: \Artist.name) private var artists: [Artist]

    var body: some View {
        let visible = artists.filter { !$0.tracks.isEmpty || !$0.albums.isEmpty }
        List {
            ForEach(visible) { artist in
                NavigationLink(value: Route.artist(artist.id)) {
                    HStack(spacing: Spacing.m) {
                        ArtistImage(artist: artist).frame(width: 48, height: 48)
                        Text(artist.name).lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("아티스트")
        .overlay { if visible.isEmpty { EmptyLibraryView() } }
    }
}

// MARK: - 장르

struct GenresListView: View {
    @Query private var tracks: [Track]

    /// "Rock; Indie"처럼 여러 장르가 적힌 곡은 장르마다 센다.
    private var genres: [(String, Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for track in tracks {
            for name in NameSplitter.genres(track.genre) {
                counts[name.lowercased(), default: (name: name, count: 0)].count += 1
            }
        }
        return counts.values.map { ($0.name, $0.count) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        let genres = self.genres
        List(genres, id: \.0) { genre, count in
            NavigationLink(value: Route.genre(genre)) {
                HStack {
                    Text(genre)
                    Spacer()
                    Text("\(count)곡").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("장르")
        .overlay {
            if genres.isEmpty {
                ContentUnavailableView("장르 정보가 없어요", systemImage: "guitars", description: Text("음악 파일에 장르 태그가 있으면 여기에 나와요."))
            }
        }
    }
}

struct GenreView: View {
    let genre: String
    @Query private var tracks: [Track]
    @Environment(PlayerEngine.self) private var player

    init(genre: String) {
        self.genre = genre
        _tracks = Query(filter: #Predicate<Track> { $0.genre.localizedStandardContains(genre) }, sort: \Track.title)
    }

    var body: some View {
        let tracks = self.tracks.filter { NameSplitter.contains($0.genre, genre: genre) }
        List {
            PlayShuffleButtons { player.play(tracks) } onShuffle: { player.play(tracks, shuffled: true) }
                .listRowSeparator(.hidden)
            ForEach(tracks) { TrackRow(track: $0, queue: tracks) }
        }
        .listStyle(.plain)
        .navigationTitle(genre)
    }
}

struct FavoritesView: View {
    @Query(filter: #Predicate<Track> { $0.isFavorite }, sort: \Track.title) private var tracks: [Track]
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        List {
            if !tracks.isEmpty {
                PlayShuffleButtons { player.play(tracks) } onShuffle: { player.play(tracks, shuffled: true) }
                    .listRowSeparator(.hidden)
            }
            ForEach(tracks) { TrackRow(track: $0, queue: tracks) }
        }
        .listStyle(.plain)
        .navigationTitle("좋아요 표시한 곡")
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("좋아요 표시한 곡이 없어요", systemImage: "star", description: Text("재생 화면이나 곡 메뉴에서 ☆을 누르면 여기에 모여요."))
            }
        }
    }
}
