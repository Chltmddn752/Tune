import Foundation

/// 확장의 search/customSearch를 백그라운드에서 실행한다.
enum ExtensionSearch {
    @MainActor
    static func search(
        query: String,
        extension installed: InstalledExtension,
        store: ExtensionStore,
        limit: Int = 25
    ) async throws -> [ProviderTrack] {
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
}
