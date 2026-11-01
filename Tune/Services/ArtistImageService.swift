import Foundation
import SwiftData
import UIKit

/// Deezer 무료 API로 아티스트 사진을 받아 저장한다.
///
/// 이름만으로 찾으면 동명이인 사진이 붙는다(예: ARASHI). 그래서 내 보관함의 곡·앨범 제목과
/// 겹치는지로 검증하고, 확신이 없으면 사진을 비워 둔다. **틀린 사진보다 빈 원이 낫다.**
///
/// 실패(네트워크 오류·쿼터 초과)는 "이미 찾아봄"으로 기록하지 않고 지수 백오프로 다시 시도한다.
/// 요청은 전역 큐에서 초당 5건 이하로 내보낸다.
@MainActor
enum ArtistImageService {
    struct ArtistPhotoCandidate: Identifiable, Hashable {
        let id: Int
        let name: String
        let pictureURL: URL
        let fans: Int
    }

    private static var inFlight: Set<UUID> = []

    private static let manualKey = "artistImageManual."
    // 모델에 필드를 더하면 기존 SwiftData 보관함 마이그레이션이 필요해서, ID는 UserDefaults에 둔다.
    private static let deezerIDKey = "artistDeezerID."
    private static let backoffKey = "artistImageBackoff."
    private static let failureKey = "artistImageFailures."
    private static let signatureKey = "artistImageSignature."

    // MARK: - 공개 API

    static func fetchIfNeeded(_ artist: Artist, context: ModelContext, force: Bool = false) async {
        let enabled = UserDefaults.standard.object(forKey: SettingsKey.artistPhotos) as? Bool ?? true
        guard enabled, !LibraryText.looksLikeChannel(artist.name) else { return }
        guard artist.name != "알 수 없는 아티스트" else { return }
        guard !inFlight.contains(artist.id) else { return }

        let key = artist.key
        if UserDefaults.standard.bool(forKey: manualKey + key), !force { return }
        if !force {
            // 결과를 확정한 적이 있으면(사진 또는 "없음") 곡이 새로 들어오기 전에는 다시 묻지 않는다.
            if let fetched = artist.imageFetchedAt {
                let signature = signature(for: artist, context: context)
                let fresh = Date().timeIntervalSince(fetched) < 7 * 86400
                if fresh, UserDefaults.standard.string(forKey: signatureKey + key) == signature { return }
            }
            if let next = UserDefaults.standard.object(forKey: backoffKey + key) as? Date, next > .now { return }
        }

        inFlight.insert(artist.id)
        defer { inFlight.remove(artist.id) }

        let outcome = await resolve(artist, context: context, force: force)
        guard !Task.isCancelled else { return }

        switch outcome {
        case .photo(let data, let deezerID):
            guard let saved = ArtworkStore.save(data) else {
                noteFailure(key)
                return
            }
            artist.imageFile = saved
            setStoredDeezerID(deezerID, for: artist)
            artist.imageFetchedAt = .now
            clearFailure(key)
            UserDefaults.standard.set(signature(for: artist, context: context), forKey: signatureKey + key)
            try? context.save()
        case .none:
            // "확실히 없음"도 확정 결과로 기록하되, 곡이 새로 추가되면 signature가 달라져 다시 찾는다.
            artist.imageFetchedAt = .now
            clearFailure(key)
            UserDefaults.standard.set(signature(for: artist, context: context), forKey: signatureKey + key)
            try? context.save()
        case .cancelled:
            break
        case .transient:
            noteFailure(key)
        }
    }

    /// 설정의 "아티스트 사진 모두 다시 받기": 잘못 붙은 자동 사진을 지우고 새 검증 방식으로 다시 받는다.
    static func refreshAll(context: ModelContext) async {
        let artists = ((try? context.fetch(FetchDescriptor<Artist>())) ?? [])
            .filter { !$0.tracks.isEmpty || !$0.albums.isEmpty }
        guard !artists.isEmpty else { return }
        let activityID = ActivityCenter.shared.begin(
            title: "아티스트 사진 받기", symbol: "person.crop.circle", total: artists.count
        )
        for (index, artist) in artists.enumerated() {
            guard !Task.isCancelled else { break }
            ActivityCenter.shared.update(activityID, completed: index, total: artists.count, detail: artist.name)
            if !UserDefaults.standard.bool(forKey: manualKey + artist.key) {
                artist.imageFile = nil
                artist.imageFetchedAt = nil
                setStoredDeezerID(nil, for: artist)
                UserDefaults.standard.removeObject(forKey: signatureKey + artist.key)
                try? context.save()
                await fetchIfNeeded(artist, context: context, force: true)
            }
        }
        ActivityCenter.shared.finish(activityID, message: "아티스트 사진을 다시 확인했어요")
    }

    /// 사용자가 직접 고를 수 있는 후보 사진들.
    static func candidates(for artist: Artist, context: ModelContext) async -> [ArtistPhotoCandidate] {
        var seen = Set<Int>()
        var result: [ArtistPhotoCandidate] = []
        if let existing = storedDeezerID(for: artist),
           case .success(let detail) = await DeezerAPI.shared.get(
               URL(string: "https://api.deezer.com/artist/\(existing)")!, as: ArtistDetail.self),
           let picture = detail.pictureURL {
            result.append(ArtistPhotoCandidate(id: detail.id, name: detail.name, pictureURL: picture, fans: detail.nb_fan ?? 0))
            seen.insert(detail.id)
        }
        let query = artist.name.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "8")]
        if let url = components.url, case .success(let response) = await DeezerAPI.shared.get(url, as: ArtistSearchResponse.self) {
            for item in response.data {
                guard let picture = item.pictureURL, seen.insert(item.id).inserted else { continue }
                result.append(ArtistPhotoCandidate(id: item.id, name: item.name, pictureURL: picture, fans: item.nb_fan ?? 0))
            }
        }
        return result
    }

    static func applyManual(image: UIImage, to artist: Artist, context: ModelContext) {
        let name = "artist-\(artist.id.uuidString).jpg"
        if let saved = ArtworkStore.save(image: image, name: name) {
            artist.imageFile = saved
            artist.imageFetchedAt = .now
            UserDefaults.standard.set(true, forKey: manualKey + artist.key)
            clearFailure(artist.key)
            try? context.save()
        }
    }

    static func applyRemote(_ candidate: ArtistPhotoCandidate, to artist: Artist, context: ModelContext) async {
        guard let data = await download(candidate.pictureURL) else { return }
        applyManual(imageData: data, to: artist, context: context, deezerID: candidate.id)
    }

    private static func applyManual(imageData: Data, to artist: Artist, context: ModelContext, deezerID: Int?) {
        let name = "artist-\(artist.id.uuidString).jpg"
        guard let image = UIImage(data: imageData) else { return }
        if let saved = ArtworkStore.save(image: image, name: name) {
            artist.imageFile = saved
            if let deezerID { setStoredDeezerID(deezerID, for: artist) }
            artist.imageFetchedAt = .now
            UserDefaults.standard.set(true, forKey: manualKey + artist.key)
            clearFailure(artist.key)
            try? context.save()
        }
    }

    static func removePhoto(from artist: Artist, context: ModelContext) {
        artist.imageFile = nil
        artist.imageFetchedAt = nil
        setStoredDeezerID(nil, for: artist)
        UserDefaults.standard.set(false, forKey: manualKey + artist.key)
        UserDefaults.standard.removeObject(forKey: signatureKey + artist.key)
        clearFailure(artist.key)
        try? context.save()
    }

    // MARK: - 매칭

    private enum Outcome {
        case photo(Data, Int)
        case none
        case transient
        case cancelled
    }

    private static func resolve(_ artist: Artist, context: ModelContext, force: Bool) async -> Outcome {
        // 이미 검증된 ID가 있으면 그 아티스트 정보만 받는다.
        if !force, let id = storedDeezerID(for: artist) {
            switch await DeezerAPI.shared.get(URL(string: "https://api.deezer.com/artist/\(id)")!, as: ArtistDetail.self) {
            case .success(let detail):
                guard let picture = detail.pictureURL else { return .none }
                guard let data = await download(picture) else { return .transient }
                return .photo(data, detail.id)
            case .failure(.quota): return .transient
            case .failure: return .none
            }
        }

        let library = libraryTitles(for: artist, context: context)
        var scores: [Int: (name: String, hits: Double, tracks: Int, albums: Int)] = [:]

        // 1순위: 보관함 곡 제목으로 Deezer 곡 검색 → 여러 곡에서 같은 아티스트가 나오면 확정.
        for title in library.titles.prefix(5) {
            guard !Task.isCancelled else { return .cancelled }
            let query = "artist:\"\(artist.name)\" track:\"\(title)\""
            guard let url = searchURL(path: "search", query: query, limit: 5) else { continue }
            switch await DeezerAPI.shared.get(url, as: TrackSearchResponse.self) {
            case .success(let response):
                var seenArtists = Set<Int>()
                for item in response.data where LibraryText.key(item.title) == LibraryText.key(title) {
                    if seenArtists.insert(item.artist.id).inserted {
                        scores[item.artist.id, default: (item.artist.name, 0, 0, 0)].hits += 1
                    }
                    let nameMatch = LibraryText.key(item.artist.name) == LibraryText.key(artist.name)
                    if nameMatch { scores[item.artist.id]?.hits += 1 }
                }
            case .failure(.quota):
                return .transient
            case .failure:
                continue
            }
        }

        // 2순위: 아티스트 후보의 인기곡·앨범을 보관함과 겹쳐 본다(표기가 달라도 곡으로 찾는다).
        var candidates: [ArtistSearchResponse.Item] = []
        if let url = searchURL(path: "search/artist", query: artist.name, limit: 8),
           case .success(let response) = await DeezerAPI.shared.get(url, as: ArtistSearchResponse.self) {
            candidates = response.data
        }
        for candidate in candidates.prefix(4) where scores[candidate.id] == nil {
            guard !Task.isCancelled else { return .cancelled }
            var hits = 0.0
            var trackHits = 0
            var albumHits = 0
            if let topURL = URL(string: "https://api.deezer.com/artist/\(candidate.id)/top?limit=50"),
               case .success(let top) = await DeezerAPI.shared.get(topURL, as: TrackSearchResponse.self) {
                let topKeys = Set(top.data.map { LibraryText.key($0.title) })
                trackHits = library.trackKeys.filter { topKeys.contains($0) }.count
                hits += Double(trackHits)
            }
            if let albumURL = URL(string: "https://api.deezer.com/artist/\(candidate.id)/albums?limit=100"),
               case .success(let albums) = await DeezerAPI.shared.get(albumURL, as: AlbumListResponse.self) {
                let albumKeys = Set(albums.data.map { LibraryText.key($0.title) })
                albumHits = library.albumKeys.filter { albumKeys.contains($0) }.count
                hits += Double(albumHits) * 1.5
            }
            scores[candidate.id] = (candidate.name, hits, trackHits, albumHits)
        }

        // 채택 기준: 곡이나 앨범이 1개 이상 일치하는 후보.
        let matches = scores.filter { $0.value.tracks + $0.value.albums >= 1 }
            .sorted { $0.value.hits > $1.value.hits }
        if let best = matches.first {
            // 같은 점수의 후보가 둘이면 잘못 고르지 않게 비워 둔다.
            if matches.count > 1, matches[1].value.hits == best.value.hits { return .none }
            return await finish(best.key, artist: artist)
        }

        // 근거가 없으면 이름이 정확히 같고 팬이 충분히 많은 후보가 딱 하나일 때만 쓴다.
        let exact = candidates.filter {
            LibraryText.key($0.name) == LibraryText.key(artist.name) && ($0.nb_fan ?? 0) >= 1000
        }
        guard exact.count == 1, let only = exact.first else { return .none }
        return await finish(only.id, artist: artist)
    }

    private static func finish(_ deezerID: Int, artist: Artist) async -> Outcome {
        switch await DeezerAPI.shared.get(URL(string: "https://api.deezer.com/artist/\(deezerID)")!, as: ArtistDetail.self) {
        case .success(let detail):
            guard let picture = detail.pictureURL else { return .none }
            guard let data = await download(picture) else { return .transient }
            return .photo(data, detail.id)
        case .failure(.quota):
            return .transient
        case .failure:
            return .none
        }
    }

    // MARK: - 보관함에서 비교할 제목 모으기

    private struct LibraryTitles {
        var titles: [String] = []
        var trackKeys: Set<String> = []
        var albumKeys: Set<String> = []
    }

    private static func libraryTitles(for artist: Artist, context: ModelContext) -> LibraryTitles {
        let name = artist.name
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.artistName.contains(name) || $0.albumArtistName.contains(name) }
        )
        var tracks = ((try? context.fetch(descriptor)) ?? []).filter {
            NameSplitter.contains($0.artistName, artist: name) || NameSplitter.contains($0.albumArtistName, artist: name)
        }
        if tracks.isEmpty { tracks = artist.tracks }

        var result = LibraryTitles()
        var seenTitles = Set<String>()
        for track in tracks {
            let key = LibraryText.key(track.title)
            guard !key.isEmpty else { continue }
            result.trackKeys.insert(key)
            if seenTitles.insert(key).inserted, !result.titles.contains(where: { LibraryText.key($0) == key }) {
                let stripped = LibraryText.strippedTitle(track.title).trimmingCharacters(in: .whitespaces)
                result.titles.append(stripped.isEmpty ? track.title : stripped)
            }
        }
        for album in artist.albums {
            let key = LibraryText.key(album.title)
            if !key.isEmpty { result.albumKeys.insert(key) }
        }
        for track in tracks {
            let key = LibraryText.key(track.albumTitle)
            if !key.isEmpty, key != LibraryText.key("앨범 없음") { result.albumKeys.insert(key) }
        }
        return result
    }

    private static func searchURL(path: String, query: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/\(path)")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "\(limit)")]
        return components.url
    }

    private static func storedDeezerID(for artist: Artist) -> Int? {
        let value = UserDefaults.standard.integer(forKey: deezerIDKey + artist.key)
        return value > 0 ? value : nil
    }

    private static func setStoredDeezerID(_ id: Int?, for artist: Artist) {
        if let id {
            UserDefaults.standard.set(id, forKey: deezerIDKey + artist.key)
        } else {
            UserDefaults.standard.removeObject(forKey: deezerIDKey + artist.key)
        }
    }

    // MARK: - 재시도 · 서명

    private static func signature(for artist: Artist, context: ModelContext) -> String {
        let titles = libraryTitles(for: artist, context: context)
        return "\(artist.name)|\(titles.trackKeys.count)|\(titles.titles.prefix(3).joined(separator: "/"))"
    }

    private static func noteFailure(_ key: String) {
        let failures = UserDefaults.standard.integer(forKey: failureKey + key) + 1
        UserDefaults.standard.set(failures, forKey: failureKey + key)
        // 1분 → 5분 → 30분 간격으로 다시 시도한다.
        let delays: [Double] = [60, 300, 1800]
        let delay = delays[min(failures - 1, delays.count - 1)]
        UserDefaults.standard.set(Date().addingTimeInterval(delay), forKey: backoffKey + key)
    }

    private static func clearFailure(_ key: String) {
        UserDefaults.standard.removeObject(forKey: failureKey + key)
        UserDefaults.standard.removeObject(forKey: backoffKey + key)
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 12 * 1024 * 1024 else { return nil }
        return data
    }
}

// MARK: - Deezer 응답 · 전역 요청 큐

enum DeezerError: Error {
    case quota
    case transient
}

/// 동시 2건 이하, 초당 5건 이하로 요청을 내보낸다. 쿼터 초과면 잠시 멈춘 뒤 다시 시도한다.
actor DeezerAPI {
    static let shared = DeezerAPI()

    private let minimumInterval: TimeInterval = 0.22
    private var nextAllowed = Date.distantPast
    private var pausedUntil = Date.distantPast

    func get<T: Decodable>(_ url: URL, as type: T.Type) async -> Result<T, DeezerError> {
        await waitForTurn()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Tune/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 { pausedUntil = Date().addingTimeInterval(20); return .failure(.quota) }
                guard (200..<300).contains(http.statusCode) else { return .failure(.transient) }
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any],
               let code = error["code"] as? Int, code == 4 {
                // "Quota limit exceeded" — 20초 쉬었다가 다시 시도한다.
                pausedUntil = Date().addingTimeInterval(20)
                return .failure(.quota)
            }
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(.transient)
        }
    }

    private func waitForTurn() async {
        let now = Date()
        let start = max(now, max(nextAllowed, pausedUntil))
        nextAllowed = start.addingTimeInterval(minimumInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }
}

struct TrackSearchResponse: Decodable {
    struct ArtistRef: Decodable {
        let id: Int
        let name: String
    }
    struct Item: Decodable {
        let title: String
        let artist: ArtistRef
    }
    let data: [Item]
}

struct AlbumListResponse: Decodable {
    struct Item: Decodable {
        let title: String
    }
    let data: [Item]
}

struct ArtistSearchResponse: Decodable {
    struct Item: Decodable {
        let id: Int
        let name: String
        let picture_xl: String?
        let picture_big: String?
        let nb_fan: Int?

        var pictureURL: URL? {
            guard let value = picture_xl ?? picture_big, !value.contains("/artist//") else { return nil }
            return URL(string: value)
        }
    }
    let data: [Item]
}

struct ArtistDetail: Decodable {
    let id: Int
    let name: String
    let picture_xl: String?
    let picture_big: String?
    let nb_fan: Int?

    var pictureURL: URL? {
        guard let value = picture_xl ?? picture_big, !value.contains("/artist//") else { return nil }
        return URL(string: value)
    }
}
