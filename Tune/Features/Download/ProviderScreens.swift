import Combine
import SwiftUI

// MARK: - 검색 결과 행

struct ProviderArtistRow: View {
    let artist: ProviderArtist
    let providerName: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            RemoteArtwork(url: artist.imageURL.flatMap(URL.init(string:)), circle: true)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text("아티스트 · \(providerName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

struct ProviderAlbumRow: View {
    let album: ProviderAlbum
    let providerName: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            RemoteArtwork(url: album.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.listArtwork)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                Text(album.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    private var meta: String {
        [album.typeLabel, album.year.map(String.init), album.totalTracks > 0 ? "\(album.totalTracks)곡" : nil, providerName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct ProviderPlaylistRow: View {
    let playlist: ProviderPlaylist
    let providerName: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            RemoteArtwork(url: playlist.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.listArtwork)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                if !playlist.owner.isEmpty {
                    Text(playlist.owner)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    private var meta: String {
        let songs = playlist.totalTracks > 0 ? "\(playlist.totalTracks)곡" : nil
        return [songs, "플레이리스트 · \(providerName)"].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ProviderAlbumCard: View {
    let album: ProviderAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteArtwork(url: album.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.listArtwork)
            Text(album.title)
                .font(.tuneSubtitle.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(album.displayArtist)
                .font(.tuneCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text([album.typeLabel, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 온라인 앨범

struct ProviderAlbumScreen: View {
    let route: ProviderAlbumRoute

    @Environment(ExtensionStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var details: ProviderAlbumDetails?
    @State private var isLoading = true
    @State private var error: String?
    @State private var isPreparing = false
    @State private var prepareStatus: String?

    private var installed: InstalledExtension? { store.installedExtension(id: route.providerID) }
    private var padding: CGFloat { Spacing.screen(sizeClass) }

    var body: some View {
        Group {
            if isLoading {
                ProviderLoadingView(text: "앨범을 불러오는 중")
            } else if let details {
                content(details)
            } else {
                ContentUnavailableView {
                    Label("앨범을 불러오지 못했어요", systemImage: "square.stack")
                } description: {
                    Text(error ?? "잠시 뒤 다시 시도해 주세요.")
                } actions: {
                    Button("다시 시도") { Task { await load() } }
                }
            }
        }
        .navigationTitle(details?.album.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .signedSessionAuthenticated)) { note in
            guard note.object as? String == route.providerID else { return }
            Task { await load() }
        }
    }

    private func content(_ details: ProviderAlbumDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header(details)

                if details.tracks.isEmpty {
                    ContentUnavailableView("앨범에 받을 수 있는 곡이 없어요", systemImage: "music.note")
                        .padding(.top, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                            if let installed {
                                ProviderResultRow(
                                    track: track,
                                    installed: installed,
                                    job: downloadJob(for: track),
                                    number: index + 1,
                                    artworkSize: 44
                                )
                                Divider().padding(.leading, 34)
                            }
                        }
                        .padding(.horizontal, padding)
                    }
                }
            }
            .padding(.top, Spacing.l)
            .padding(.bottom, 140)
        }
        .background(alignment: .top) { ProviderWash(seed: route.albumID) }
    }

    private func header(_ details: ProviderAlbumDetails) -> some View {
        let album = details.album
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .bottom, spacing: Spacing.l) {
                RemoteArtwork(url: album.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.playerArtwork)
                    .frame(width: coverSize, height: coverSize)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title)
                        .font(.title.bold())
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    if let artistID = album.artistID ?? route.artistID, !artistID.isEmpty {
                        NavigationLink(value: Route.providerArtist(ProviderArtistRoute(
                            providerID: album.providerID,
                            artistID: artistID,
                            name: album.displayArtist,
                            imageURL: nil
                        ))) {
                            Text(album.displayArtist)
                                .font(.title3)
                                .foregroundStyle(Color.tuneAccent)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(album.displayArtist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(meta(album, trackCount: details.tracks.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padding)

            HStack(spacing: Spacing.m) {
                downloadAllButton(count: details.tracks.count) {
                    Task {
                        if let installed, !installed.manifest.isDownloadProvider {
                            await downloadAllMatched(details.tracks)
                        } else {
                            await downloadAll(details.tracks)
                        }
                    }
                }
                .disabled(details.tracks.isEmpty || isPreparing)

                extensionMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padding)
        }
    }

    private var coverSize: CGFloat { sizeClass == .regular ? 240 : 220 }

    private func meta(_ album: ProviderAlbum, trackCount: Int) -> String {
        [album.typeLabel, album.year.map(String.init), "\(max(album.totalTracks, trackCount))곡"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func downloadJob(for track: ProviderTrack) -> DownloadJob? {
        downloads.jobs.first { $0.providerID == track.providerID && $0.trackID == track.trackID }
    }

    @ViewBuilder private var extensionMenu: some View {
        if let installed {
            Menu {
                Text("\(installed.title) · \(qualityLabel(installed))")
                Button {
                    coordinator.showSettingsSheet = true
                } label: {
                    Label("다운로드 설정", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .tuneGlass(in: Circle())
            .accessibilityLabel("앨범 더 보기")
        }
    }

    private func load() async {
        guard let installed else {
            error = "확장을 찾을 수 없어요."
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            details = try await ExtensionSearch.album(id: route.albumID, extension: installed, store: store)
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            self.error = ExtensionErrorText.localized(error)
            isLoading = false
        }
    }

    private func downloadAll(_ tracks: [ProviderTrack]) async {
        guard let installed else { return }
        isPreparing = true
        prepareStatus = "준비 중 0/\(tracks.count)"
        defer {
            isPreparing = false
            prepareStatus = nil
        }
        for (index, track) in tracks.enumerated() {
            downloads.enqueue(track: track, extension: installed)
            prepareStatus = "준비 중 \(index + 1)/\(tracks.count)"
        }
        toasts.show("\(tracks.count)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
    }

    /// 정보만 주는 확장의 앨범: 설치된 다운로드 확장에서 같은 곡을 찾아 대기열에 넣는다.
    private func downloadAllMatched(_ tracks: [ProviderTrack]) async {
        isPreparing = true
        prepareStatus = "곡 찾는 중"
        defer {
            isPreparing = false
            prepareStatus = nil
        }
        let summary = await ProviderMatching.enqueue(tracks: tracks, store: store, downloads: downloads) { done, total in
            Task { @MainActor in prepareStatus = "찾는 중 \(done)/\(total)" }
        }
        if summary.isEmpty {
            toasts.show(
                store.compatibleInstallableExtensions.isEmpty
                    ? "음원을 받으려면 확장이 필요해요"
                    : "다른 확장에서 같은 곡을 찾지 못했어요",
                symbol: "exclamationmark.circle",
                actionTitle: "설정"
            ) { coordinator.showSettingsSheet = true }
        } else {
            toasts.show(summary.message, symbol: "arrow.down.circle.fill")
        }
    }

    private func downloadAllButton(count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isPreparing {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                }
                Text(isPreparing ? (prepareStatus ?? "준비 중") : "앨범 전체 받기")
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 46)
            .foregroundStyle(.white)
            .background(Color.tuneAccent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("앨범 전체 받기")
    }

    private func qualityLabel(_ installed: InstalledExtension) -> String {
        let id = store.defaultQuality(for: installed)
        return installed.manifest.qualityOptions.first { $0.id == id }?.label ?? "확장 기본값"
    }
}

// MARK: - 온라인 아티스트

struct ProviderArtistScreen: View {
    let route: ProviderArtistRoute

    @Environment(ExtensionStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var details: ProviderArtistDetails?
    @State private var isLoading = true
    @State private var error: String?
    @State private var isPreparing = false
    @State private var prepareStatus: String?
    @State private var busyAlbums: Set<String> = []
    @State private var showAllConfirm = false

    private var installed: InstalledExtension? { store.installedExtension(id: route.providerID) }
    private var padding: CGFloat { Spacing.screen(sizeClass) }
    private var albums: [ProviderAlbum] {
        (details?.albums ?? []).sorted {
            ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProviderLoadingView(text: "아티스트를 불러오는 중")
            } else if let details {
                content(details)
            } else {
                ContentUnavailableView {
                    Label("아티스트를 불러오지 못했어요", systemImage: "music.mic")
                } description: {
                    Text(error ?? "잠시 뒤 다시 시도해 주세요.")
                } actions: {
                    Button("다시 시도") { Task { await load() } }
                }
            }
        }
        .navigationTitle(details?.artist.displayName ?? route.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .signedSessionAuthenticated)) { note in
            guard note.object as? String == route.providerID else { return }
            Task { await load() }
        }
        .alert("모든 앨범을 받을까요?", isPresented: $showAllConfirm) {
            Button("취소", role: .cancel) {}
            Button("대기열에 넣기") { Task { await downloadAllAlbums() } }
        } message: {
            Text("앨범 \(albums.count)개의 곡을 차례로 확인해 대기열에 넣어요. 앨범이 많으면 시간이 걸릴 수 있어요.")
        }
    }

    private func content(_ details: ProviderArtistDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header(details)

                if !albums.isEmpty {
                    albumGrid
                }

                if !details.topTracks.isEmpty {
                    topTracks(details.topTracks)
                }

                if albums.isEmpty && details.topTracks.isEmpty {
                    ContentUnavailableView("앨범이나 곡을 찾지 못했어요", systemImage: "music.note")
                        .padding(.top, 30)
                }
            }
            .padding(.top, Spacing.l)
            .padding(.bottom, 140)
        }
        .background(alignment: .top) { ProviderWash(seed: route.artistID) }
    }

    private func header(_ details: ProviderArtistDetails) -> some View {
        let artist = details.artist
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .bottom, spacing: Spacing.l) {
                RemoteArtwork(url: artist.imageURL.flatMap(URL.init(string:)), circle: true)
                    .frame(width: sizeClass == .regular ? 200 : 150, height: sizeClass == .regular ? 200 : 150)
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(artist.displayName)
                        .font(.tuneArtistName)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text("앨범 \(albums.count)개 · \(details.topTracks.count)곡")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padding)

            HStack(spacing: Spacing.m) {
                Button {
                    showAllConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        if isPreparing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isPreparing ? (prepareStatus ?? "준비 중") : "모든 앨범 받기")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 46)
                    .foregroundStyle(.white)
                    .background(Color.tuneAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(albums.isEmpty || isPreparing)
                .accessibilityLabel("모든 앨범 받기")

                if !details.topTracks.isEmpty {
                    GlassIconButton(systemImage: "arrow.down", label: "인기곡 받기") {
                        Task { await downloadTopTracks(details.topTracks) }
                    }
                    .disabled(isPreparing)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padding)
        }
    }

    private var albumGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("앨범").font(.tuneSection)
                .padding(.horizontal, padding)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 170 : 140), spacing: Spacing.l)],
                alignment: .leading,
                spacing: Spacing.xl
            ) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 4) {
                        NavigationLink(value: Route.providerAlbum(ProviderAlbumRoute(
                            providerID: album.providerID,
                            albumID: album.albumID,
                            title: album.title,
                            artist: album.artist,
                            coverURL: album.coverURL,
                            artistID: album.artistID
                        ))) {
                            ProviderAlbumCard(album: album)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 4) {
                            Text(album.totalTracks > 0 ? "\(album.totalTracks)곡" : album.typeLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            if busyAlbums.contains(album.albumID) {
                                ProgressView().controlSize(.small).frame(width: 44, height: 44)
                            } else {
                                Button {
                                    Task { await downloadAlbum(album) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3)
                                        .foregroundStyle(Color.tuneAccent)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(album.title) 전체 받기")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, padding)
        }
    }

    private func topTracks(_ tracks: [ProviderTrack]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("인기곡").font(.tuneSection)
                .padding(.horizontal, padding)
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    if let installed {
                        ProviderResultRow(
                            track: track,
                            installed: installed,
                            job: downloadJob(for: track),
                            number: index + 1,
                            artworkSize: 44
                        )
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .padding(.horizontal, padding)
        }
    }

    private func downloadJob(for track: ProviderTrack) -> DownloadJob? {
        downloads.jobs.first { $0.providerID == track.providerID && $0.trackID == track.trackID }
    }

    private func load() async {
        guard let installed else {
            error = "확장을 찾을 수 없어요."
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            details = try await ExtensionSearch.artist(id: route.artistID, extension: installed, store: store)
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            self.error = ExtensionErrorText.localized(error)
            isLoading = false
        }
    }

    private func downloadTopTracks(_ tracks: [ProviderTrack]) async {
        guard let installed else { return }
        if !installed.manifest.isDownloadProvider {
            isPreparing = true
            prepareStatus = "곡 찾는 중"
            defer {
                isPreparing = false
                prepareStatus = nil
            }
            let summary = await ProviderMatching.enqueue(tracks: tracks, store: store, downloads: downloads)
            toasts.show(
                summary.isEmpty ? "다른 확장에서 같은 곡을 찾지 못했어요" : "인기곡 \(summary.matched)곡을 대기열에 넣었어요",
                symbol: summary.isEmpty ? "exclamationmark.circle" : "arrow.down.circle.fill"
            )
            return
        }
        for track in tracks {
            downloads.enqueue(track: track, extension: installed)
        }
        toasts.show("인기곡 \(tracks.count)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
    }

    private func downloadAlbum(_ album: ProviderAlbum) async {
        guard let installed else { return }
        busyAlbums.insert(album.albumID)
        defer { busyAlbums.remove(album.albumID) }
        do {
            let result = try await ExtensionSearch.albumTracks(
                albums: [album],
                extension: installed,
                store: store
            )
            guard !result.tracks.isEmpty else {
                toasts.show("\(album.title)에서 받을 수 있는 곡을 찾지 못했어요", symbol: "exclamationmark.circle")
                return
            }
            if !installed.manifest.isDownloadProvider {
                let summary = await ProviderMatching.enqueue(tracks: result.tracks, store: store, downloads: downloads)
                toasts.show(
                    summary.isEmpty ? "\(album.title)의 곡을 다른 확장에서 찾지 못했어요" : "\(album.title) \(summary.matched)곡을 대기열에 넣었어요",
                    symbol: summary.isEmpty ? "exclamationmark.circle" : "arrow.down.circle.fill"
                )
                return
            }
            for track in result.tracks {
                downloads.enqueue(track: track, extension: installed)
            }
            toasts.show("\(album.title) \(result.tracks.count)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
        } catch {
            toasts.show(error.localizedDescription, symbol: "exclamationmark.circle")
        }
    }

    private func downloadAllAlbums() async {
        guard let installed else { return }
        let albums = albums
        guard !albums.isEmpty else { return }
        isPreparing = true
        prepareStatus = "앨범 0/\(albums.count)"
        defer {
            isPreparing = false
            prepareStatus = nil
        }
        do {
            let result = try await ExtensionSearch.albumTracks(
                albums: albums,
                extension: installed,
                store: store
            ) { done, total in
                Task { @MainActor in prepareStatus = "앨범 \(done)/\(total)" }
            }
            if !installed.manifest.isDownloadProvider {
                guard !result.tracks.isEmpty else {
                    toasts.show("받을 수 있는 곡을 찾지 못했어요", symbol: "exclamationmark.circle")
                    return
                }
                prepareStatus = "곡 찾는 중"
                let summary = await ProviderMatching.enqueue(tracks: result.tracks, store: store, downloads: downloads) { done, total in
                    Task { @MainActor in prepareStatus = "찾는 중 \(done)/\(total)" }
                }
                toasts.show(
                    summary.isEmpty
                        ? "다른 확장에서 같은 곡을 찾지 못했어요"
                        : "앨범 \(albums.count)개에서 \(summary.matched)곡을 대기열에 넣었어요",
                    symbol: summary.isEmpty ? "exclamationmark.circle" : "arrow.down.circle.fill"
                )
                return
            }
            for track in result.tracks {
                downloads.enqueue(track: track, extension: installed)
            }
            if result.tracks.isEmpty {
                toasts.show("받을 수 있는 곡을 찾지 못했어요", symbol: "exclamationmark.circle")
            } else {
                toasts.show("앨범 \(albums.count)개에서 \(result.tracks.count)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
            }
        } catch {
            toasts.show(error.localizedDescription, symbol: "exclamationmark.circle")
        }
    }
}

// MARK: - 온라인 플레이리스트

struct ProviderPlaylistScreen: View {
    let route: ProviderPlaylistRoute

    @Environment(ExtensionStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var details: ProviderPlaylistDetails?
    @State private var isLoading = true
    @State private var error: String?
    @State private var isPreparing = false
    @State private var prepareStatus: String?

    private var installed: InstalledExtension? { store.installedExtension(id: route.providerID) }
    private var padding: CGFloat { Spacing.screen(sizeClass) }

    var body: some View {
        Group {
            if isLoading {
                ProviderLoadingView(text: "플레이리스트를 불러오는 중")
            } else if let details {
                content(details)
            } else {
                ContentUnavailableView {
                    Label("플레이리스트를 불러오지 못했어요", systemImage: "music.note.list")
                } description: {
                    Text(error ?? "잠시 뒤 다시 시도해 주세요.")
                } actions: {
                    Button("다시 시도") { Task { await load() } }
                }
            }
        }
        .navigationTitle(details?.playlist.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .signedSessionAuthenticated)) { note in
            guard note.object as? String == route.providerID else { return }
            Task { await load() }
        }
    }

    private func content(_ details: ProviderPlaylistDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header(details)

                if details.tracks.isEmpty {
                    ContentUnavailableView("플레이리스트에 받을 수 있는 곡이 없어요", systemImage: "music.note")
                        .padding(.top, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                            if let installed {
                                ProviderResultRow(
                                    track: track,
                                    installed: installed,
                                    job: downloadJob(for: track),
                                    number: index + 1,
                                    artworkSize: 44
                                )
                                Divider().padding(.leading, 34)
                            }
                        }
                        .padding(.horizontal, padding)
                    }
                }
            }
            .padding(.top, Spacing.l)
            .padding(.bottom, 140)
        }
        .background(alignment: .top) { ProviderWash(seed: route.playlistID) }
    }

    private func header(_ details: ProviderPlaylistDetails) -> some View {
        let playlist = details.playlist
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .bottom, spacing: Spacing.l) {
                RemoteArtwork(url: playlist.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.playerArtwork)
                    .frame(width: coverSize, height: coverSize)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.displayTitle)
                        .font(.title.bold())
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    if !playlist.owner.isEmpty {
                        Text(playlist.owner)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text([
                        details.tracks.count > 0 ? "\(details.tracks.count)곡" : nil,
                        playlist.totalTracks > 0 && playlist.totalTracks != details.tracks.count ? "\(playlist.totalTracks)곡" : nil,
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padding)

            if !playlist.detail.isEmpty {
                Text(playlist.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.horizontal, padding)
            }

            HStack(spacing: Spacing.m) {
                Button {
                    Task {
                        if let installed, !installed.manifest.isDownloadProvider {
                            await downloadAllMatched(details.tracks)
                        } else {
                            await downloadAll(details.tracks)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isPreparing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isPreparing ? (prepareStatus ?? "준비 중") : "플레이리스트 전체 받기")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 46)
                    .foregroundStyle(.white)
                    .background(Color.tuneAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(details.tracks.isEmpty || isPreparing)
                .accessibilityLabel("플레이리스트 전체 받기")

                if let installed {
                    Menu {
                        Text("\(installed.title)")
                        Button {
                            coordinator.showSettingsSheet = true
                        } label: {
                            Label("다운로드 설정", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .frame(width: 46, height: 46)
                            .contentShape(Rectangle())
                    }
                    .tuneGlass(in: Circle())
                    .accessibilityLabel("플레이리스트 더 보기")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padding)
        }
    }

    private var coverSize: CGFloat { sizeClass == .regular ? 240 : 220 }

    private func downloadJob(for track: ProviderTrack) -> DownloadJob? {
        downloads.jobs.first { $0.providerID == track.providerID && $0.trackID == track.trackID }
    }

    private func load() async {
        guard let installed else {
            error = "확장을 찾을 수 없어요."
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            details = try await ExtensionSearch.playlist(id: route.playlistID, extension: installed, store: store)
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            self.error = ExtensionErrorText.localized(error)
            isLoading = false
        }
    }

    private func downloadAll(_ tracks: [ProviderTrack]) async {
        guard let installed else { return }
        isPreparing = true
        prepareStatus = "준비 중 0/\(tracks.count)"
        defer {
            isPreparing = false
            prepareStatus = nil
        }
        for (index, track) in tracks.enumerated() {
            downloads.enqueue(track: track, extension: installed)
            prepareStatus = "준비 중 \(index + 1)/\(tracks.count)"
        }
        toasts.show("\(tracks.count)곡을 대기열에 넣었어요", symbol: "arrow.down.circle.fill")
    }

    private func downloadAllMatched(_ tracks: [ProviderTrack]) async {
        isPreparing = true
        prepareStatus = "곡 찾는 중"
        defer {
            isPreparing = false
            prepareStatus = nil
        }
        let summary = await ProviderMatching.enqueue(tracks: tracks, store: store, downloads: downloads) { done, total in
            Task { @MainActor in prepareStatus = "찾는 중 \(done)/\(total)" }
        }
        if summary.isEmpty {
            toasts.show(
                store.compatibleInstallableExtensions.isEmpty
                    ? "음원을 받으려면 확장이 필요해요"
                    : "다른 확장에서 같은 곡을 찾지 못했어요",
                symbol: "exclamationmark.circle",
                actionTitle: "설정"
            ) { coordinator.showSettingsSheet = true }
        } else {
            toasts.show(summary.message, symbol: "arrow.down.circle.fill")
        }
    }
}

// MARK: - 공통

struct ProviderLoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: Spacing.m) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 온라인 컬렉션 위쪽에 까는 옅은 색 번짐. 커버에서 색을 뽑는 대신 제목에서 안정적으로 고른다.
struct ProviderWash: View {
    let seed: String

    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.35, green: 0.36, blue: 0.62),
            Color(red: 0.55, green: 0.32, blue: 0.42),
            Color(red: 0.28, green: 0.45, blue: 0.50),
            Color(red: 0.48, green: 0.36, blue: 0.25),
            Color(red: 0.40, green: 0.30, blue: 0.55),
            Color(red: 0.30, green: 0.42, blue: 0.35),
        ]
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    var body: some View {
        LinearGradient(colors: [color.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 380)
            .ignoresSafeArea()
    }
}
