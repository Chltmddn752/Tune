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
    @State private var query = ""
    @State private var showLinkLookup = false
    @State private var scope: SearchScope = .top
    @State private var providerResults: [ProviderTrack] = []
    @State private var providerError: String?
    @State private var isProviderLoading = false
    @State private var providerID = ""
    @State private var searchToken = UUID()
    @State private var isSelecting = false
    @State private var selectedTrackIDs: Set<String> = []

    private var recent: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                browse
            } else {
                results
            }
        }
        .navigationTitle("검색")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showLinkLookup = true } label: { Label("링크로 찾기", systemImage: "link") }
                    NavigationLink { DownloadListView() } label: { Label("다운로드", systemImage: "arrow.down.circle") }
                    NavigationLink(value: Route.wishlist) { Label("사고 싶은 곡", systemImage: "heart.text.square") }
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .accessibilityLabel("링크로 찾기, 다운로드, 사고 싶은 곡")
            }
        }
        .sheet(isPresented: $showLinkLookup) { LinkLookupView() }
        .searchable(text: $query, prompt: "노래, 앨범, 아티스트")
        .onSubmit(of: .search) { remember(query) }
        .task { normalizeProvider() }
        .task(id: query) {
            clearSelection()
            await searchOnline()
        }
        .onChange(of: providerID) { _, _ in
            clearSelection()
            Task { await searchOnline() }
        }
        .onChange(of: scope) { _, newValue in
            if newValue != .top && newValue != .online {
                clearSelection()
            }
        }
        .onChange(of: extensionStore.installed.map(\.id).joined(separator: ",")) { _, _ in
            normalizeProvider()
            Task { await searchOnline() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .signedSessionAuthenticated)) { note in
            guard let id = note.object as? String, id == providerID else { return }
            Task { await searchOnline() }
        }
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
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(term) 지우기")
                            }
                            .frame(minHeight: 36)
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
                    ContentUnavailableView("내 보관함에서 찾아보세요", systemImage: "magnifyingglass",
                                           description: Text("초성으로도 찾을 수 있어요. 예: ㄴㅈㅅ"))
                        .padding(.top, 60)
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
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.s) {
                        ForEach(SearchScope.allCases) { option in
                            FilterChip(title: option.rawValue, isSelected: scope == option) { scope = option }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .listRowSeparator(.hidden)
            }

            if scope == .top, let best = bestMatch(songs: songHits, albums: albumHits, artists: artistHits) {
                Section {
                    best
                        .listRowSeparator(.hidden)
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
                            }
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
                                ArtworkView(file: album.artworkFile, cornerRadius: Radius.listArtwork).frame(width: 48, height: 48)
                                VStack(alignment: .leading) {
                                    Text(album.title).lineLimit(1)
                                    Text("앨범 · \(album.artistName)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
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
                            }
                        }
                    }
                }
            }
            if scope != .online && songHits.isEmpty && albumHits.isEmpty && artistHits.isEmpty && playlistHits.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            batchBar
        }
    }

    @ViewBuilder private var onlineSection: some View {
        if scope == .top || scope == .online {
            Section(scope == .top ? "온라인" : "") {
                let providers = extensionStore.compatibleInstallableExtensions
                if providers.isEmpty {
                    NavigationLink {
                        ExtensionStoreView()
                    } label: {
                        Label("음원 확장 설치하기", systemImage: "puzzlepiece.extension")
                    }
                    .listRowSeparator(.hidden)
                } else {
                    if providers.count > 1 {
                        Picker("음원", selection: $providerID) {
                            ForEach(providers) { provider in
                                Text(provider.title).tag(provider.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    if isProviderLoading {
                        HStack(spacing: Spacing.s) {
                            ProgressView()
                            Text("\(providerTitle)에서 찾는 중").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else if let providerError {
                        Text(providerError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !selectableTracks.isEmpty {
                        HStack(spacing: Spacing.m) {
                            if isSelecting {
                                Text("받을 곡을 골라 주세요")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(allSelectableSelected ? "전체 해제" : "전체 선택") {
                                    toggleSelectAll()
                                }
                                .font(.footnote)
                                Button("선택 취소") { clearSelection() }
                                    .font(.footnote)
                            } else {
                                Button {
                                    isSelecting = true
                                } label: {
                                    Label("여러 곡 한 번에 받기", systemImage: "checklist")
                                        .font(.subheadline)
                                }
                                Spacer()
                            }
                        }
                        .listRowSeparator(.hidden)
                    }

                    ForEach(providerResults) { track in
                        if let installed = extensionStore.installedExtension(id: track.providerID) {
                            if isSelecting, canSelect(track) {
                                Button {
                                    toggleSelection(track)
                                } label: {
                                    ProviderResultRow(
                                        track: track,
                                        installed: installed,
                                        job: downloadJob(for: track),
                                        isSelecting: true,
                                        isSelected: selectedTrackIDs.contains(track.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                ProviderResultRow(
                                    track: track,
                                    installed: installed,
                                    job: downloadJob(for: track),
                                    isSelecting: isSelecting,
                                    isSelected: selectedTrackIDs.contains(track.id)
                                )
                            }
                        }
                    }

                    if scope == .online && providerResults.isEmpty && !isProviderLoading && providerError == nil {
                        Text("확장에서 곡을 찾지 못했어요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var providerTitle: String {
        extensionStore.compatibleInstallableExtensions.first { $0.id == providerID }?.title ?? "확장"
    }

    private var currentInstalled: InstalledExtension? {
        extensionStore.installedExtension(id: providerID)
    }

    private var selectableTracks: [ProviderTrack] {
        providerResults.filter(canSelect)
    }

    private var selectedTracks: [ProviderTrack] {
        providerResults.filter { selectedTrackIDs.contains($0.id) && canSelect($0) }
    }

    private var allSelectableSelected: Bool {
        !selectableTracks.isEmpty && selectableTracks.allSatisfy { selectedTrackIDs.contains($0.id) }
    }

    @ViewBuilder private var batchBar: some View {
        if isSelecting {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedTracks.count)곡 선택")
                        .font(.subheadline.weight(.semibold))
                    Text(allSelectableSelected ? "전체 선택됨" : "받을 곡을 골라 주세요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                if let installed = currentInstalled {
                    Menu {
                        ForEach(installed.manifest.qualityOptions) { quality in
                            Button {
                                enqueueSelected(quality: quality.id, in: installed)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(quality.label)
                                    if let description = quality.description {
                                        Text(description)
                                    }
                                }
                            }
                        }
                        if installed.manifest.qualityOptions.isEmpty {
                            Button("최고 음질로 대기열에 넣기") {
                                enqueueSelected(quality: nil, in: installed)
                            }
                        }
                    } label: {
                        Label("대기열에 넣기", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Color.tuneAccent, in: Capsule())
                    }
                    .disabled(selectedTracks.isEmpty)
                    .opacity(selectedTracks.isEmpty ? 0.45 : 1)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func canSelect(_ track: ProviderTrack) -> Bool {
        downloadJob(for: track) == nil
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

    private func clearSelection() {
        isSelecting = false
        selectedTrackIDs.removeAll()
    }

    private func enqueueSelected(quality: String?, in installed: InstalledExtension) {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        for track in tracks {
            guard let provider = extensionStore.installedExtension(id: track.providerID) else { continue }
            downloads.enqueue(track: track, extension: provider, quality: quality)
        }
        clearSelection()
    }

    private func downloadJob(for track: ProviderTrack) -> DownloadJob? {
        downloads.jobs.first { $0.providerID == track.providerID && $0.trackID == track.trackID }
    }

    private func normalizeProvider() {
        let providers = extensionStore.compatibleInstallableExtensions
        if !providers.contains(where: { $0.id == providerID }) {
            providerID = providers.first?.id ?? ""
        }
    }

    private func searchOnline() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = extensionStore.compatibleInstallableExtensions
        guard !trimmed.isEmpty, !providers.isEmpty else {
            providerResults = []
            providerError = nil
            isProviderLoading = false
            clearSelection()
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
            selectedTrackIDs.formIntersection(Set(results.map(\.id)))
            if results.isEmpty { providerError = "\(installed.title)에서 찾지 못했어요." }
        } catch is CancellationError {
            return
        } catch {
            guard searchToken == token else { return }
            providerResults = []
            providerError = error.localizedDescription
        }
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
                    ArtworkView(file: album.artworkFile, cornerRadius: Radius.card)
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
                ArtworkView(file: track.artworkFile, cornerRadius: Radius.card)
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
                    ArtworkView(file: album.artworkFile, cornerRadius: 6)
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
