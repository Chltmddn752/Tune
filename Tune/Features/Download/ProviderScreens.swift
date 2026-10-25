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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        [album.typeLabel, album.year.map(String.init), album.totalTracks > 0 ? "\(album.totalTracks)곡" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct ProviderAlbumCard: View {
    let album: ProviderAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteArtwork(url: album.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.tile)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(album.displayArtist)
                .font(.caption)
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var details: ProviderAlbumDetails?
    @State private var isLoading = true
    @State private var error: String?
    @State private var message: String?
    @State private var isPreparing = false

    private var installed: InstalledExtension? { store.installedExtension(id: route.providerID) }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("앨범을 불러오는 중").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.screen(sizeClass))
                }

                if details.tracks.isEmpty {
                    ContentUnavailableView("앨범에 받을 수 있는 곡이 없어요", systemImage: "music.note")
                        .padding(.top, 24)
                } else {
                    trackList(details)
                }
            }
            .padding(.top, Spacing.l)
            .padding(.bottom, 120)
        }
        .overlay(alignment: .bottom) {
            if isPreparing {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("앨범을 대기열에 넣는 중").font(.subheadline)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
            }
        }
    }

    private func header(_ details: ProviderAlbumDetails) -> some View {
        let album = details.album
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .bottom, spacing: Spacing.l) {
                RemoteArtwork(url: album.coverURL.flatMap(URL.init(string:)), cornerRadius: Radius.tile)
                    .frame(width: sizeClass == .regular ? 240 : 190, height: sizeClass == .regular ? 240 : 190)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title)
                        .font(.title2.bold())
                        .lineLimit(3)
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
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(album.displayArtist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text(meta(album, trackCount: details.tracks.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.screen(sizeClass))

            HStack(spacing: Spacing.m) {
                Button {
                    Task { await downloadAll(details.tracks) }
                } label: {
                    Label("앨범 전체 받기", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Color.tuneAccent, in: Capsule())
                }
                .disabled(details.tracks.isEmpty || isPreparing)

                if let installed {
                    Text("\(installed.manifest.qualityOptions.count)가지 음질")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.screen(sizeClass))
        }
    }

    private func trackList(_ details: ProviderAlbumDetails) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)
                        .padding(.top, 18)
                    if let installed {
                        ProviderResultRow(
                            track: track,
                            installed: installed,
                            job: downloadJob(for: track)
                        )
                    }
                }
                .padding(.horizontal, Spacing.screen(sizeClass))
                .padding(.vertical, 4)
                if index < details.tracks.count - 1 {
                    Divider().padding(.leading, Spacing.screen(sizeClass) + 34)
                }
            }
        }
    }

    private func meta(_ album: ProviderAlbum, trackCount: Int) -> String {
        [album.typeLabel, album.year.map(String.init), "\(max(album.totalTracks, trackCount))곡"]
            .compactMap { $0 }
            .joined(separator: " · ")
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
            details = try await ExtensionSearch.album(id: route.albumID, extension: installed, store: store)
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func downloadAll(_ tracks: [ProviderTrack]) async {
        guard let installed else { return }
        isPreparing = true
        defer { isPreparing = false }
        for track in tracks {
            downloads.enqueue(track: track, extension: installed)
        }
        message = "\(tracks.count)곡을 대기열에 넣었어요."
    }
}

// MARK: - 온라인 아티스트

struct ProviderArtistScreen: View {
    let route: ProviderArtistRoute

    @Environment(ExtensionStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var details: ProviderArtistDetails?
    @State private var isLoading = true
    @State private var error: String?
    @State private var message: String?
    @State private var isPreparing = false
    @State private var busyAlbums: Set<String> = []
    @State private var showAllConfirm = false

    private var installed: InstalledExtension? { store.installedExtension(id: route.providerID) }
    private var albums: [ProviderAlbum] {
        (details?.albums ?? []).sorted {
            ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("아티스트를 불러오는 중").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.screen(sizeClass))
                }

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
        .overlay(alignment: .bottom) {
            if isPreparing {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("앨범을 하나씩 여는 중").font(.subheadline)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
            }
        }
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
                    Text("\(albums.count)개 앨범 · \(details.topTracks.count)곡")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let installed {
                        Text(installed.title)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.screen(sizeClass))

            HStack(spacing: Spacing.m) {
                Button {
                    showAllConfirm = true
                } label: {
                    Label("모든 앨범 받기", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Color.tuneAccent, in: Capsule())
                }
                .disabled(albums.isEmpty || isPreparing)

                if !details.topTracks.isEmpty {
                    Button {
                        Task { await downloadTopTracks(details.topTracks) }
                    } label: {
                        Label("인기곡 받기", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(isPreparing)
                }
            }
            .padding(.horizontal, Spacing.screen(sizeClass))
        }
    }

    private var albumGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("앨범").font(.tuneSection)
                .padding(.horizontal, Spacing.screen(sizeClass))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 170 : 140), spacing: Spacing.l)],
                alignment: .leading,
                spacing: Spacing.xl
            ) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 6) {
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

                        HStack(spacing: 6) {
                            Text(album.totalTracks > 0 ? "\(album.totalTracks)곡" : album.typeLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            if busyAlbums.contains(album.albumID) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    Task { await downloadAlbum(album) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.body)
                                        .foregroundStyle(Color.tuneAccent)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(album.title) 전체 받기")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screen(sizeClass))
        }
    }

    private func topTracks(_ tracks: [ProviderTrack]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("인기곡").font(.tuneSection)
                .padding(.horizontal, Spacing.screen(sizeClass))
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)
                        .padding(.top, 18)
                    if let installed {
                        ProviderResultRow(
                            track: track,
                            installed: installed,
                            job: downloadJob(for: track)
                        )
                    }
                }
                .padding(.horizontal, Spacing.screen(sizeClass))
                .padding(.vertical, 4)
            }
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
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func downloadTopTracks(_ tracks: [ProviderTrack]) async {
        guard let installed else { return }
        for track in tracks {
            downloads.enqueue(track: track, extension: installed)
        }
        message = "인기곡 \(tracks.count)곡을 대기열에 넣었어요."
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
                message = "\(album.title)에서 받을 수 있는 곡을 찾지 못했어요."
                return
            }
            for track in result.tracks {
                downloads.enqueue(track: track, extension: installed)
            }
            message = "\(album.title) \(result.tracks.count)곡을 대기열에 넣었어요."
        } catch {
            message = error.localizedDescription
        }
    }

    private func downloadAllAlbums() async {
        guard let installed else { return }
        let albums = albums
        guard !albums.isEmpty else { return }
        isPreparing = true
        message = "앨범 0/\(albums.count) 여는 중"
        defer { isPreparing = false }
        do {
            let result = try await ExtensionSearch.albumTracks(
                albums: albums,
                extension: installed,
                store: store
            ) { done, total in
                Task { @MainActor in
                    message = "앨범 \(done)/\(total) 여는 중"
                }
            }
            for track in result.tracks {
                downloads.enqueue(track: track, extension: installed)
            }
            if result.tracks.isEmpty {
                message = "받을 수 있는 곡을 찾지 못했어요."
            } else if result.failures.isEmpty {
                message = "앨범 \(albums.count)개에서 \(result.tracks.count)곡을 대기열에 넣었어요."
            } else {
                message = "\(result.tracks.count)곡을 넣었어요. 열지 못한 앨범 \(result.failures.count)개: \(result.failures.prefix(3).joined(separator: ", "))"
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
