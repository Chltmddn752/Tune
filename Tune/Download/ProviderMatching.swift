import Foundation

/// 정보 전용 확장(Apple Music·Spotify)에서 찾은 곡을 실제로 받을 수 있는 확장의 곡과 짝지은 것.
struct ProviderMatch: Identifiable {
    var installed: InstalledExtension
    var track: ProviderTrack

    var id: String { "\(installed.id):\(track.trackID)" }
}

enum ProviderMatching {
    /// ISRC와 곡 정보로 설치된 다운로드 확장에서 같은 곡을 찾는다.
    /// 결과가 없으면 빈 배열, 있으면 확장마다 하나씩 돌려준다.
    @MainActor
    static func find(track: ProviderTrack, store: ExtensionStore) async -> [ProviderMatch] {
        let providers = store.compatibleInstallableExtensions.filter { $0.id != track.providerID }
        var matches: [ProviderMatch] = []
        for provider in providers {
            guard !Task.isCancelled else { break }
            guard let resolved = try? await ExtensionSearch.availability(
                track: track,
                extension: provider,
                store: store
            ) else { continue }
            var matched = track
            matched.providerID = provider.id
            matched.trackID = resolved.trackID
            matched.preparedContext = resolved.preparedContext
            matches.append(ProviderMatch(installed: provider, track: matched))
        }
        return matches
    }
}
