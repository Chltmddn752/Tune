import Combine
import SwiftData
import SwiftUI

/// 한글 초성 검색("ㄴㅈㅅ" → 뉴진스), 띄어쓰기·대소문자 무시
enum SearchMatcher {
    private static let choseong: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

    static func normalize(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }

    static func initials(_ text: String) -> String {
        String(text.compactMap { character -> Character? in
            guard let scalar = character.unicodeScalars.first else { return nil }
            if (0xAC00...0xD7A3).contains(scalar.value) {
                return choseong[Int((scalar.value - 0xAC00) / 588)]
            }
            return character.isWhitespace ? nil : Character(character.lowercased())
        })
    }

    static func isInitialsQuery(_ query: String) -> Bool {
        let trimmed = query.filter { !$0.isWhitespace }
        return !trimmed.isEmpty && trimmed.allSatisfy { choseong.contains($0) }
    }

    static func matches(_ query: String, _ text: String) -> Bool {
        let q = normalize(query)
        guard !q.isEmpty else { return true }
        if normalize(text).contains(q) { return true }
        if isInitialsQuery(query) { return initials(text).contains(q) }
        return false
    }

    /// 앞부분이 맞으면 점수가 높다.
    static func score(_ query: String, _ text: String) -> Int {
        let q = normalize(query)
        let t = normalize(text)
        if t == q { return 3 }
        if t.hasPrefix(q) { return 2 }
        if t.contains(q) { return 1 }
        return isInitialsQuery(query) && initials(text).hasPrefix(q) ? 1 : 0
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case top = "상위 결과", online = "온라인", songs = "노래", albums = "앨범", artists = "아티스트", playlists = "플레이리스트"
    var id: String { rawValue }
}

struct SearchView: View {
    @Query private var tracks: [Track]
    @Query private var albums: [Album]
    @Query(sort: \Artist.name) private var artists: [Artist]
    @Query private var playlists: [Playlist]
    @AppStorage(SettingsKey.recentSearches) private var recentRaw = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ExtensionStore.self) private var extensionStore
    @Environment(DownloadManager.self) private var downloads
    @Environment(Router.self) private var router
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @State private var query = ""
    @State private var showLinkLookup = false
    @State private var scope: SearchScope = .top
    @State private var providerResults = ProviderSearchResults()
    @State private var providerError: String?
    @State private var isProviderLoading = false
    @State private var providerID = ""
    @State private var searchToken = UUID()
    @State private var isSelecting = false
    @State private var selectedTrackIDs: Set<String> = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasQuery: Bool { !trimmedQuery.isEmpty }

    private var recent: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        Group {
            if hasQuery {
                VStack(spacing: 0) {
                    GlassSegmented(items: SearchScope.allCases, title: { $0.rawValue }, selection: $scope) { newValue in
                        if newValue != .top && newValue != .online { endSelection() }
                    }
                    results
                }
            } else {
                browse
            }
        }
        .navigationTitle("검색")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showLinkLookup = true } label: { Label("링크로 찾기", systemImage: "link") }
                    NavigationLink(value: Route.wishlist) { Label("사고 싶은 곡", systemImage: "heart.text.square") }
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .accessibilityLabel("링크로 찾기, 사고 싶은 곡")
            }
            if hasQuery, !providerResults.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "선택 취소" : "선택") {
                        withAnimation(.smooth(duration: 0.28)) {
                            isSelecting ? endSelection() : startSelection()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showLinkLookup) { LinkLookupView() }
        .searchable(text: $query, prompt: "노래, 앨범, 아티스트, 플레이리스트")
        .onSubmit(of: .search) { remember(query) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting { selectionBar }
        }
        .task { normalizeProvider() }
        .task(id: query) {
            endSelection()
            await searchOnline()
        }
        .onChange(of: providerID) { _, _ in
            endSelection()
            Task { await searchOnline() }
        }
        .onChange(of: isSelecting) { _, selecting in
            router.hidesMiniPlayer = selecting
        }
        .onDisappear { router.hidesMiniPlayer = false }
        .onChange(of: router.searchRequest) { _, _ in applyRequestedScope() }
        .onAppear { applyRequestedScope() }
        .onChange(of: extensionStore.installed.map(\.id).joined(separator: ",")) { _, _ in
            normalizeProvider()
            Task { await searchOnline() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .signedSessionAuthenticated)) { note in
            guard let id = note.object as? String, id == providerID else { return }
            Task { await searchOnline() }
        }
    }

    private func applyRequestedScope() {
        guard let requested = router.requestedSearchScope else { return }
        scope = requested
        router.requestedSearchScope = nil
    }

    // MARK: 입력 전: 최근 검색어 + 장르 타일

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack {
                            Text("최근 검색").font(.tuneSection)
                            Spacer()
                            Button("지우기") { recentRaw = "" }.font(.subheadline)
                        }
                        ForEach(recent, id: \.self) { term in
                            HStack {
                                Button {
                                    query = term
                                } label: {
                                    Label(term, systemImage: "clock.arrow.circlepath")
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    recentRaw = recent.filter { $0 != term }.joined(separator: "\n")
                                } label: {
                                    Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(term) 지우기")
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }

                let genres = genreTiles
                if !genres.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("장르 둘러보기").font(.tuneSection)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: sizeClass == .regular ? 4 : 2),
                                  spacing: Spacing.m) {
                            ForEach(genres, id: \.name) { tile in
                                GenreTile(name: tile.name, album: tile.album)
                            }
                        }
                    }
                }

                if recent.isEmpty && genres.isEmpty {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "내 보관함에서 찾아보세요",
                        message: "초성으로도 찾을 수 있어요. 예: ㄴㅈㅅ"
                    )
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, Spacing.screen(sizeClass))
            .padding(.vertical, Spacing.m)
        }
    }

    private var genreTiles: [(name: String, album: Album?)] {
        var grouped: [String: [Album]] = [:]
        for album in albums {
            for name in NameSplitter.genres(album.genre) { grouped[name, default: []].append(album) }
        }
        return grouped.keys.sorted { (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0) }
            .prefix(16)
            .map { ($0, grouped[$0]?.first { $0.artworkFile != nil }) }
    }

    // MARK: 입력 중: 결과

    private var results: some View {
        let songHits = tracks.filter { SearchMatcher.matches(query, $0.title) || SearchMatcher.matches(query, $0.artistName) }
            .sorted { SearchMatcher.score(query, $0.title) > SearchMatcher.score(query, $1.title) }
        let albumHits = albums.filter { SearchMatcher.matches(query, $0.title) || SearchMatcher.matches(query, $0.artistName) }
        let artistHits = artists.filter { SearchMatcher.matches(query, $0.name) && !$0.tracks.isEmpty }
        let playlistHits = playlists.filter { SearchMatcher.matches(query, $0.name) }

        return List {
            if scope == .top, let best = bestMatch(songs: songHits, albums: albumHits, artists: artistHits) {
                Section {
                    best
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: Spacing.screen(sizeClass), bottom: 8, trailing: Spacing.screen(sizeClass)))
                }
            }

            onlineSection

            if scope == .top || scope == .artists, !artistHits.isEmpty {
                Section(scope == .top ? "아티스트" : "") {
                    ForEach(artistHits.prefix(scope == .top ? 3 : 100)) { artist in
                        NavigationLink(value: Route.artist(artist.id)) {
                            HStack(spacing: Spacing.m) {
                                ArtistImage(artist: artist).frame(width: 48, height: 48)
                                Text(artist.name)
                                    .lineLimit(2)
                            }
                            .frame(minHeight: 52)
                        }
                        .simultaneousGesture(TapGesture().onEnded { remember(query) })
                    }
                }
            }
            if scope == .top || scope == .albums, !albumHits.isEmpty {
                Section(scope == .top ? "앨범" : "") {
                    ForEach(albumHits.prefix(scope == .top ? 4 : 200)) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            HStack(spacing: Spacing.m) {
                                ArtworkView(file: album.artworkFile, cornerRadius: Radius.listArtwork,
                                            colorHex: album.colorHex, title: album.title)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).lineLimit(1)
                                    Text("앨범 · \(album.artistName)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(minHeight: 52)
                        }
                        .simultaneousGesture(TapGesture().onEnded { remember(query) })
                    }
                }
            }
            if scope == .top || scope == .songs, !songHits.isEmpty {
                Section(scope == .top ? "노래" : "") {
                    ForEach(songHits.prefix(scope == .top ? 8 : 300)) { track in
                        TrackRow(track: track, queue: [track])
                            .simultaneousGesture(TapGesture().onEnded { remember(query) })
                    }
                }
            }
            if scope == .top || scope == .playlists, !playlistHits.isEmpty {
                Section(scope == .top ? "플레이리스트" : "") {
                    ForEach(playlistHits) { playlist in
                        NavigationLink(value: Route.playlist(playlist.id)) {
                            HStack(spacing: Spacing.m) {
                                PlaylistCover(playlist: playlist).frame(width: 48, height: 48)
                                Text(playlist.name)
                                    .lineLimit(2)
                            }
                            .frame(minHeight: 52)
                        }
                    }
                }
            }
            if !isProviderLoading && !hasRelevantResults(
                songs: songHits,
                albums: albumHits,
                artists: artistHits,
                playlists: playlistHits
            ) {
                ContentUnavailableView.search(text: query)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    // MARK: 온라인

    @ViewBuilder private var onlineSection: some View {
        if showsOnline {
            let providers = extensionStore.searchExtensions
            if providers.isEmpty {
                Section {
                    Button {
                        coordinator.showSetupSheet = true
                    } label: {
                        Label("음원 확장 설치하기", systemImage: "puzzlepiece.extension")
                    }
                    .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    HStack {
                        Text("온라인")
                            .font(.tuneSection)
                            .textCase(nil)
                        Spacer()
                        ProviderMenuButton(providers: providers, selectedID: providerID) { id in
                            providerID = id
                            remember(query)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: Spacing.screen(sizeClass), bottom: 4, trailing: Spacing.screen(sizeClass)))

                    if isProviderLoading {
                        ForEach(0..<3, id: \.self) { _ in
                            OnlineSkeletonRow()
                                .listRowSeparator(.hidden)
                        }
                    } else if let providerError {
                        onlineErrorCard(providerError)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: Spacing.screen(sizeClass), bottom: 4, trailing: Spacing.screen(sizeClass)))
                    } else if scope == .online && providerResults.isEmpty {
                        Text("\(providerTitle)에서 결과를 찾지 못했어요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }

                if showsOnlineArtists, !providerResults.artists.isEmpty {
                    Section(onlineHeader("아티스트")) {
                        ForEach(providerResults.artists.prefix(scope == .top ? 3 : 50)) { artist in
                            Button {
                                remember(query)
                                router.open(.providerArtist(ProviderArtistRoute(
                                    providerID: artist.providerID,
                                    artistID: artist.artistID,
                                    name: artist.name,
                                    imageURL: artist.imageURL
                                )))
                            } label: {
                                ProviderArtistRow(artist: artist, providerName: providerTitle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showsOnlineAlbums, !providerResults.albums.isEmpty {
                    Section(onlineHeader("앨범")) {
                        ForEach(providerResults.albums.prefix(scope == .top ? 4 : 50)) { album in
                            Button {
                                remember(query)
                                router.open(.providerAlbum(ProviderAlbumRoute(
                                    providerID: album.providerID,
                                    albumID: album.albumID,
                                    title: album.title,
                                    artist: album.artist,
                                    coverURL: album.coverURL,
                                    artistID: album.artistID
                                )))
                            } label: {
                                ProviderAlbumRow(album: album, providerName: providerTitle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showsOnlinePlaylists, !providerResults.playlists.isEmpty {
                    Section(onlineHeader("플레이리스트")) {
                        ForEach(providerResults.playlists.prefix(scope == .top ? 3 : 50)) { playlist in
                            Button {
                                remember(query)
                                router.open(.providerPlaylist(ProviderPlaylistRoute(
                                    providerID: playlist.providerID,
                                    playlistID: playlist.playlistID,
                                    title: playlist.title,
                                    owner: playlist.owner,
                                    coverURL: playlist.coverURL
                                )))
                            } label: {
                                ProviderPlaylistRow(playlist: playlist, providerName: providerTitle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showsOnlineTracks, !providerResults.tracks.isEmpty {
                    Section(onlineHeader("노래")) {
                        ForEach(providerResults.tracks.prefix(scope == .top ? 8 : 50)) { track in
                            if let installed = extensionStore.installedExtension(id: track.providerID) {
                                ProviderResultRow(
                                    track: track,
                                    installed: installed,
                                    job: downloadJob(for: track),
                                    isSelecting: isSelecting && canSelect(track),
                                    isSelected: selectedTrackIDs.contains(track.id),
                                    onTap: isSelecting ? { toggleSelection(track) } : nil
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func onlineErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(providerTitle)에서 결과를 가져오지 못했어요")
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button("다시 시도") {
                    Task { await searchOnline() }
                }
                .font(.footnote.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    private var showsOnline: Bool {
        switch scope {
        case .top, .online, .songs, .albums, .artists, .playlists: true
        }
    }

    private var showsOnlineArtists: Bool { scope == .top || scope == .online || scope == .artists }
    private var showsOnlineAlbums: Bool { scope == .top || scope == .online || scope == .albums }
    private var showsOnlineTracks: Bool { scope == .top || scope == .online || scope == .songs }
    private var showsOnlinePlaylists: Bool { scope == .top || scope == .online || scope == .playlists }

    private func onlineHeader(_ title: String) -> String {
        scope == .online ? title : "온라인 \(title)"
    }

    private var providerTitle: String {
        extensionStore.searchExtensions.first { $0.id == providerID }?.title ?? "확장"
    }

    // MARK: 선택 모드

    private var selectableTracks: [ProviderTrack] {
        providerResults.tracks.filter(canSelect)
    }

    private var selectedTracks: [ProviderTrack] {
        providerResults.tracks.filter { selectedTrackIDs.contains($0.id) && canSelect($0) }
    }

    private var allSelectableSelected: Bool {
        !selectableTracks.isEmpty && selectableTracks.allSatisfy { selectedTrackIDs.contains($0.id) }
    }

    private var selectionBar: some View {
        GlassActionBar {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selectedTracks.count)곡 선택")
                    .font(.subheadline.weight(.semibold))
                Text(allSelectableSelected ? "전체 선택됨" : "받을 곡을 골라 주세요")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Button(allSelectableSelected ? "전체 해제" : "전체 선택") { toggleSelectAll() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tuneAccent)
                .frame(minHeight: 44)
            Button {
                downloadSelected()
            } label: {
                Text("받기")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 40)
                    .foregroundStyle(.white)
                    .background(Color.tuneAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedTracks.isEmpty)
            .opacity(selectedTracks.isEmpty ? 0.45 : 1)
        }
    }

    private func startSelection() {
        isSelecting = true
        selectedTrackIDs.removeAll()
    }

    private func endSelection() {
        isSelecting = false
        selectedTrackIDs.removeAll()
        router.hidesMiniPlayer = false
    }

    private func canSelect(_ track: ProviderTrack) -> Bool {
        guard extensionStore.installedExtension(id: track.providerID) != nil else { return false }
        return downloadJob(for: track) == nil
    }

    private func toggleSelection(_ track: ProviderTrack) {
        guard canSelect(track) else { return }
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
    }

    private func toggleSelectAll() {
        if allSelectableSelected {
            selectedTrackIDs.removeAll()
        } else {
            selectedTrackIDs.formUnion(selectableTracks.map(\.id))
        }
    }

    /// 고른 곡을 기본 음질로 대기열에 넣는다. 정보만 주는 확장의 곡은 다른 확장에서 찾는다.
    private func downloadSelected() {
        let chosen = selectedTracks
        guard !chosen.isEmpty else { return }
        var direct = 0
        var infoOnly: [ProviderTrack] = []
        for track in chosen {
            guard let installed = extensionStore.installedExtension(id: track.providerID) else { continue }
            if installed.manifest.isDownloadProvider {
                downloads.enqueue(track: track, extension: installed)
                direct += 1
            } else {
                infoOnly.append(track)
            }
        }
        if infoOnly.isEmpty {
            toasts.show("\(direct)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
            endSelection()
            return
        }
        endSelection()
        Task { @MainActor in
            let summary = await ProviderMatching.enqueue(tracks: infoOnly, store: extensionStore, downloads: downloads)
            let total = direct + summary.matched
            if total > 0 {
                toasts.show("\(total)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
            } else {
                toasts.show("다른 확장에서 같은 곡을 찾지 못했어요", symbol: "exclamationmark.circle", actionTitle: "확장") {
                    coordinator.showSetupSheet = true
                }
            }
        }
    }

    private func downloadJob(for track: ProviderTrack) -> DownloadJob? {
        downloads.jobs.first { $0.providerID == track.providerID && $0.trackID == track.trackID }
    }

    // MARK: 데이터

    private func normalizeProvider() {
        let providers = extensionStore.searchExtensions
        if !providers.contains(where: { $0.id == providerID }) {
            providerID = providers.first?.id ?? ""
        }
    }

    private func searchOnline() async {
        let trimmed = trimmedQuery
        let providers = extensionStore.searchExtensions
        guard !trimmed.isEmpty, !providers.isEmpty else {
            providerResults = ProviderSearchResults()
            providerError = nil
            isProviderLoading = false
            endSelection()
            return
        }
        if !providers.contains(where: { $0.id == providerID }) {
            providerID = providers[0].id
        }
        guard let installed = providers.first(where: { $0.id == providerID }) else { return }

        let token = UUID()
        searchToken = token
        providerError = nil
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            isProviderLoading = true
            defer {
                if searchToken == token { isProviderLoading = false }
            }
            let results = try await ExtensionSearch.search(query: trimmed, extension: installed, store: extensionStore)
            guard !Task.isCancelled, searchToken == token else { return }
            providerResults = results
            // 확장이 결과를 새로 고쳐도 고른 곡은 유지한다. 사라진 곡만 뺀다.
            selectedTrackIDs.formIntersection(Set(results.tracks.map(\.id)))
        } catch is CancellationError {
            return
        } catch {
            guard searchToken == token else { return }
            providerResults = ProviderSearchResults()
            providerError = ExtensionErrorText.localized(error)
        }
    }

    private func hasRelevantResults(
        songs: [Track],
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist]
    ) -> Bool {
        if scope == .playlists { return !playlists.isEmpty || !providerResults.playlists.isEmpty }
        if scope == .online { return !providerResults.isEmpty || providerError != nil }
        let hasLocal: Bool
        switch scope {
        case .songs: hasLocal = !songs.isEmpty
        case .albums: hasLocal = !albums.isEmpty
        case .artists: hasLocal = !artists.isEmpty
        case .top: hasLocal = !songs.isEmpty || !albums.isEmpty || !artists.isEmpty || !playlists.isEmpty
        default: hasLocal = false
        }
        let hasOnline: Bool
        switch scope {
        case .songs: hasOnline = !providerResults.tracks.isEmpty
        case .albums: hasOnline = !providerResults.albums.isEmpty
        case .artists: hasOnline = !providerResults.artists.isEmpty
        case .playlists: hasOnline = !providerResults.playlists.isEmpty
        case .top: hasOnline = !providerResults.isEmpty
        default: hasOnline = false
        }
        return hasLocal || hasOnline || (providerError != nil && showsOnline)
    }

    /// 가장 잘 맞는 것 하나를 큰 카드로
    private func bestMatch(songs: [Track], albums: [Album], artists: [Artist]) -> AnyView? {
        let artist = artists.max { SearchMatcher.score(query, $0.name) < SearchMatcher.score(query, $1.name) }
        let album = albums.max { SearchMatcher.score(query, $0.title) < SearchMatcher.score(query, $1.title) }
        let song = songs.first
        let artistScore = artist.map { SearchMatcher.score(query, $0.name) } ?? -1
        let albumScore = album.map { SearchMatcher.score(query, $0.title) } ?? -1
        let songScore = song.map { SearchMatcher.score(query, $0.title) } ?? -1

        if let artist, artistScore >= albumScore, artistScore >= songScore {
            return AnyView(NavigationLink(value: Route.artist(artist.id)) {
                TopResultCard(title: artist.name, subtitle: "아티스트") { ArtistImage(artist: artist) }
            }.buttonStyle(.plain))
        }
        if let album, albumScore >= songScore {
            return AnyView(NavigationLink(value: Route.album(album.id)) {
                TopResultCard(title: album.title, subtitle: "앨범 · \(album.artistName)") {
                    ArtworkView(file: album.artworkFile, cornerRadius: Radius.card,
                                colorHex: album.colorHex, title: album.title)
                }
            }.buttonStyle(.plain))
        }
        if let song {
            return AnyView(TopSongCard(track: song))
        }
        return nil
    }

    private func remember(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let updated = [trimmed] + recent.filter { $0 != trimmed }
        recentRaw = updated.prefix(10).joined(separator: "\n")
    }
}

// MARK: - 구성 요소

/// 지금 쓰는 음원을 고르는 글래스 캡슐 버튼.
private struct ProviderMenuButton: View {
    let providers: [InstalledExtension]
    let selectedID: String
    let onSelect: (String) -> Void

    private var selected: InstalledExtension? {
        providers.first { $0.id == selectedID } ?? providers.first
    }

    var body: some View {
        Menu {
            ForEach(providers) { provider in
                Button {
                    onSelect(provider.id)
                } label: {
                    Text(provider.manifest.isDownloadProvider ? provider.title : "\(provider.title) · 정보")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.footnote)
                Text(selected?.title ?? "음원")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, Spacing.m)
            .frame(height: 34)
            .tuneGlass(in: Capsule())
        }
        .accessibilityLabel("음원, \(selected?.title ?? "")")
    }
}

/// 온라인 결과를 기다리는 동안 보여 주는 자리 표시 줄.
private struct OnlineSkeletonRow: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            RoundedRectangle(cornerRadius: Radius.listArtwork)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 3).fill(Color(.quaternarySystemFill)).frame(width: 110, height: 10)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .accessibilityHidden(true)
    }
}

private struct TopResultCard<Artwork: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        HStack(spacing: Spacing.l) {
            artwork().frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold()).lineLimit(2)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Spacing.l)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

private struct TopSongCard: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Button { player.play([track]) } label: {
            TopResultCard(title: track.title, subtitle: "노래 · \(track.artistName)") {
                ArtworkView(file: track.artworkFile, cornerRadius: Radius.card,
                            colorHex: track.album?.colorHex, title: track.album?.title ?? track.title)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct GenreTile: View {
    let name: String
    let album: Album?

    var body: some View {
        NavigationLink(value: Route.genre(name)) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .fill(Color(hex: album?.colorHex, fallback: .tuneAccent))
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .padding(Spacing.m)
                if let album {
                    ArtworkView(file: album.artworkFile, cornerRadius: 6,
                                colorHex: album.colorHex, title: album.title)
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(22))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(x: 14, y: 8)
                }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
