import Foundation

/// 정보 전용 확장(Apple Music·Spotify)에서 찾은 곡을 실제로 받을 수 있는 확장의 곡과 짝지은 것.
struct ProviderMatch: Identifiable {
    var installed: InstalledExtension
    var track: ProviderTrack

    var id: String { "\(installed.id):\(track.trackID)" }
}

/// 여러 곡을 짝지어 대기열에 넣은 결과.
struct ProviderBatchSummary {
    var matched = 0
    var unmatched = 0
    var usedProviders: [String] = []

    var isEmpty: Bool { matched == 0 }

    var message: String {
        guard matched > 0 else { return "" }
        let names = usedProviders.joined(separator: ", ")
        if unmatched > 0 {
            return "\(matched)곡을 \(names) 대기열에 넣었어요. 찾지 못한 곡 \(unmatched)곡."
        }
        return "\(matched)곡을 \(names) 대기열에 넣었어요."
    }
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

    /// 정보 전용 확장의 곡 여러 개를 다운로드 확장에서 찾아 바로 대기열에 넣는다.
    /// 앞쪽 확장에서 찾은 곡은 뒤쪽 확장에서 다시 찾지 않는다.
    @MainActor
    static func enqueue(
        tracks: [ProviderTrack],
        store: ExtensionStore,
        downloads: DownloadManager,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> ProviderBatchSummary {
        var summary = ProviderBatchSummary()
        var pending = tracks
        guard !pending.isEmpty else { return summary }
        let providers = store.compatibleInstallableExtensions
        guard !providers.isEmpty else {
            summary.unmatched = pending.count
            return summary
        }
        var used: Set<String> = []
        for provider in providers where !pending.isEmpty {
            if Task.isCancelled { break }
            let found = await ExtensionSearch.matchTracks(
                pending,
                extension: provider,
                store: store,
                progress: progress
            )
            guard !found.isEmpty else { continue }
            var remaining: [ProviderTrack] = []
            for track in pending {
                guard let hit = found[track.id] else {
                    remaining.append(track)
                    continue
                }
                var matched = track
                matched.providerID = provider.id
                matched.trackID = hit.trackID
                matched.preparedContext = hit.preparedContext
                downloads.enqueue(track: matched, extension: provider)
                summary.matched += 1
                used.insert(provider.title)
            }
            pending = remaining
        }
        summary.unmatched = pending.count
        summary.usedProviders = providers.map(\.title).filter { used.contains($0) }
        return summary
    }
}
