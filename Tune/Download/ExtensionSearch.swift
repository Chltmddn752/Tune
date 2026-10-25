import Foundation

/// 확장의 search/customSearch와 getAlbum/getArtist를 백그라운드에서 실행한다.
enum ExtensionSearch {
    @MainActor
    static func search(
        query: String,
        extension installed: InstalledExtension,
        store: ExtensionStore,
        limit: Int = 25
    ) async throws -> ProviderSearchResults {
        let environment = try store.providerEnvironment(for: installed)
        let staging = ExtensionPaths.staging(for: UUID())
        defer { try? FileManager.default.removeItem(at: staging) }
        return try await Task.detached(priority: .userInitiated) {
            let client = try ProviderClient(
                environment: environment,
                staging: staging,
                progress: { _ in },
                logger: { _, _ in }
            )
            return try client.search(query: query, limit: limit)
        }.value
    }

    @MainActor
    static func album(
        id: String,
        extension installed: InstalledExtension,
        store: ExtensionStore
    ) async throws -> ProviderAlbumDetails {
        let environment = try store.providerEnvironment(for: installed)
        let staging = ExtensionPaths.staging(for: UUID())
        defer { try? FileManager.default.removeItem(at: staging) }
        return try await Task.detached(priority: .userInitiated) {
            let client = try ProviderClient(
                environment: environment,
                staging: staging,
                progress: { _ in },
                logger: { _, _ in }
            )
            return try client.album(id: id)
        }.value
    }

    @MainActor
    static func artist(
        id: String,
        extension installed: InstalledExtension,
        store: ExtensionStore
    ) async throws -> ProviderArtistDetails {
        let environment = try store.providerEnvironment(for: installed)
        let staging = ExtensionPaths.staging(for: UUID())
        defer { try? FileManager.default.removeItem(at: staging) }
        return try await Task.detached(priority: .userInitiated) {
            let client = try ProviderClient(
                environment: environment,
                staging: staging,
                progress: { _ in },
                logger: { _, _ in }
            )
            return try client.artist(id: id)
        }.value
    }

    /// 정보 전용 확장에서 찾은 곡을 다운로드 확장에서 같은 곡으로 찾아 준다.
    @MainActor
    static func availability(
        track: ProviderTrack,
        extension installed: InstalledExtension,
        store: ExtensionStore
    ) async throws -> (trackID: String, preparedContext: JSONValue?)? {
        let environment = try store.providerEnvironment(for: installed)
        let staging = ExtensionPaths.staging(for: UUID())
        defer { try? FileManager.default.removeItem(at: staging) }
        return try await Task.detached(priority: .userInitiated) {
            let client = try ProviderClient(
                environment: environment,
                staging: staging,
                progress: { _ in },
                logger: { _, _ in }
            )
            return try client.checkAvailability(for: track, isrc: track.isrc)
        }.value
    }

    /// 아티스트 페이지의 여러 앨범을 한 번의 확장 런타임으로 순서대로 열어 트랙을 모은다.
    /// 한 앨범이 실패해도 나머지는 계속 받고, 실패한 앨범 이름만 돌려준다.
    @MainActor
    static func albumTracks(
        albums: [ProviderAlbum],
        extension installed: InstalledExtension,
        store: ExtensionStore,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> ProviderBatchTracks {
        guard !albums.isEmpty else { return ProviderBatchTracks(tracks: [], failures: []) }
        let environment = try store.providerEnvironment(for: installed)
        let staging = ExtensionPaths.staging(for: UUID())
        defer { try? FileManager.default.removeItem(at: staging) }
        return try await Task.detached(priority: .userInitiated) {
            let client = try ProviderClient(
                environment: environment,
                staging: staging,
                progress: { _ in },
                logger: { _, _ in }
            )
            var tracks: [ProviderTrack] = []
            var seen = Set<String>()
            var failures: [String] = []
            for (index, album) in albums.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                progress(index, albums.count)
                do {
                    let details = try client.album(id: album.albumID)
                    for track in details.tracks where seen.insert(track.trackID).inserted {
                        tracks.append(track)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(album.title.isEmpty ? album.albumID : album.title)
                }
            }
            progress(albums.count, albums.count)
            return ProviderBatchTracks(tracks: tracks, failures: failures)
        }.value
    }
}
