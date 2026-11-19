import Foundation
import SwiftData

/// 확장의 플레이리스트를 통째로 받을 때, 받은 곡을 Tune 플레이리스트 하나로 묶는다.
/// 곡마다 앨범은 원래대로 따로 정리되고, 플레이리스트에는 원본 순서대로 들어간다.
@MainActor
enum PlaylistDownloads {
    /// 원본 플레이리스트("확장 id:플레이리스트 id") → Tune 플레이리스트 id.
    /// 같은 플레이리스트를 다시 받으면 새로 만들지 않고 빠진 곡만 채운다.
    private static let mapKey = "downloadedPlaylistMap"

    private static var map: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: mapKey) }
    }

    /// 받을 곡들을 담을 Tune 플레이리스트를 찾거나 새로 만든다.
    static func prepare(for source: ProviderPlaylist, providerName: String, context: ModelContext) async -> Playlist {
        if let idString = map[source.id], let id = UUID(uuidString: idString),
           let existing = fetchPlaylist(id, context: context) {
            return existing
        }

        let detail = [source.owner.isEmpty ? nil : source.owner, "\(providerName)에서 받은 플레이리스트"]
            .compactMap { $0 }
            .joined(separator: " · ")
        let playlist = Playlist(name: source.displayTitle, detail: detail)
        if let urlString = source.coverURL, let url = URL(string: urlString),
           let fetched = try? await URLSession.shared.data(from: url),
           ((fetched.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
            playlist.coverFile = ArtworkStore.save(fetched.0)
        }
        context.insert(playlist)
        try? context.save()

        var current = map
        current[source.id] = playlist.id.uuidString
        map = current
        return playlist
    }

    /// 이미 보관함에 있는 곡은 받지 않고 바로 플레이리스트에 넣는다.
    /// 바로 넣은(또는 이미 들어 있던) 곡의 순서 번호를 돌려준다.
    static func addOwned(_ tracks: [ProviderTrack], to playlist: Playlist, context: ModelContext) -> Set<Int> {
        let library = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var byKey: [String: Track] = [:]
        for track in library where byKey[track.dedupeKey] == nil {
            byKey[track.dedupeKey] = track
        }
        var found: Set<Int> = []
        for (position, track) in tracks.enumerated() {
            // 파일 길이와 서비스가 알려 준 길이가 1초쯤 다를 수 있어 앞뒤 1초까지 본다.
            let seconds = Double(track.durationMs) / 1000
            let owned = [-1.0, 0, 1].lazy.compactMap { delta in
                byKey[LibraryImporter.dedupeKey(title: track.title, artist: track.artist, duration: seconds + delta)]
            }.first
            guard let owned else { continue }
            insert(owned.id, at: position, into: playlist, context: context)
            found.insert(position)
        }
        if !found.isEmpty {
            playlist.updatedAt = .now
            try? context.save()
        }
        return found
    }

    /// 다운로드가 끝난 곡을 플레이리스트의 원래 자리에 넣는다. 플레이리스트를 지웠으면 그냥 넘어간다.
    static func add(trackID: UUID, target: DownloadPlaylistTarget, context: ModelContext) {
        guard let playlist = fetchPlaylist(target.playlistID, context: context) else { return }
        insert(trackID, at: target.position, into: playlist, context: context)
        playlist.updatedAt = .now
        try? context.save()
    }

    private static func insert(_ trackID: UUID, at position: Int, into playlist: Playlist, context: ModelContext) {
        guard !playlist.entries.contains(where: { $0.trackID == trackID }) else { return }
        let entry = PlaylistEntry(order: position, trackID: trackID)
        context.insert(entry)
        entry.playlist = playlist
    }

    private static func fetchPlaylist(_ id: UUID, context: ModelContext) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
