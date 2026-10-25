import Foundation
import SwiftData

/// Deezer 무료 API로 아티스트 사진을 받아 저장한다.
@MainActor
enum ArtistImageService {
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let name: String
            let picture_xl: String?
            let picture_big: String?
        }
        let data: [Item]
    }

    private static var inFlight: Set<UUID> = []

    static func fetchIfNeeded(_ artist: Artist, context: ModelContext) async {
        let enabled = UserDefaults.standard.object(forKey: SettingsKey.artistPhotos) as? Bool ?? true
        guard enabled, artist.imageFile == nil, !inFlight.contains(artist.id) else { return }
        if let fetched = artist.imageFetchedAt, Date().timeIntervalSince(fetched) < 7 * 86400 { return }
        guard artist.name != "알 수 없는 아티스트" else { return }

        inFlight.insert(artist.id)
        defer { inFlight.remove(artist.id) }
        artist.imageFetchedAt = .now

        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [URLQueryItem(name: "q", value: artist.name), URLQueryItem(name: "limit", value: "3")]
        guard let url = components.url,
              let result = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: result.0) else { return }

        let match = response.data.first { $0.name.compare(artist.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? response.data.first
        guard let pictureString = match?.picture_xl ?? match?.picture_big,
              let pictureURL = URL(string: pictureString),
              // Deezer 기본 회색 사진은 건너뛴다.
              !pictureString.contains("/artist//"),
              let imageResult = try? await URLSession.shared.data(from: pictureURL),
              let saved = ArtworkStore.save(imageResult.0) else {
            try? context.save()
            return
        }
        artist.imageFile = saved
        try? context.save()
    }
}
