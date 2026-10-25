import Foundation

/// 공개·공식 API만 써서 곡 정보를 찾는다.
/// - Spotify · YouTube 링크: 각 서비스가 공개한 oEmbed (제목·썸네일만, 인증 없음)
/// - Apple Music · iTunes 링크와 검색: Apple iTunes Search / Lookup API (인증 없음)
/// 음원 파일은 받지 않는다. 결과는 "내 보관함에 있는지"와 공식 듣기·구매 링크를 보여 주는 데만 쓴다.
struct CatalogItem: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var durationSeconds: Double?
    var releaseYear: Int?
    var genre: String?
    /// Apple Music / iTunes Store 페이지 (공식)
    var storeURL: URL?
    /// 사용자가 붙여 넣은 원래 링크
    var sourceURL: URL?
}

enum LinkKind: Equatable {
    case spotify(URL)
    case appleMusic(trackID: String?, albumID: String?)
    case youtube(URL)
    case unknown
}

enum CatalogLookup {
    enum LookupError: LocalizedError {
        case unsupportedLink, notFound, network(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedLink: "Spotify · Apple Music · YouTube 링크만 알아볼 수 있어요."
            case .notFound: "곡 정보를 찾지 못했어요."
            case .network(let message): "인터넷 연결을 확인해 주세요. (\(message))"
            }
        }
    }

    // MARK: 링크 종류

    static func kind(of raw: String) -> LinkKind {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased() else {
            return .unknown
        }
        if host.hasSuffix("spotify.com") || host == "spotify.link" { return .spotify(url) }
        if host.hasSuffix("music.apple.com") || host.hasSuffix("itunes.apple.com") {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let trackID = items.first { $0.name == "i" }?.value
            // .../album/name/123456789 → 마지막 숫자 조각이 앨범 ID
            let albumID = url.pathComponents.last { $0.allSatisfy(\.isNumber) && !$0.isEmpty }
                ?? url.pathComponents.last.flatMap { last in last.hasPrefix("id") ? String(last.dropFirst(2)) : nil }
            return .appleMusic(trackID: trackID, albumID: albumID)
        }
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return .youtube(url) }
        return .unknown
    }

    // MARK: 링크 → 곡 후보

    /// 링크를 알아보고, 같은 곡일 가능성이 높은 순으로 후보를 돌려준다.
    static func resolve(_ raw: String, country: String = Locale.current.region?.identifier ?? "KR") async throws -> [CatalogItem] {
        switch kind(of: raw) {
        case .spotify(let url):
            let embed = try await oEmbed("https://open.spotify.com/oembed?url=", url)
            let results = try await search(embed.title, country: country, limit: 8)
            return results.map { var item = $0; item.sourceURL = url; return item }
        case .youtube(let url):
            let embed = try await oEmbed("https://www.youtube.com/oembed?format=json&url=", url)
            let cleaned = cleanVideoTitle(embed.title)
            let author = (embed.authorName ?? "").replacingOccurrences(of: " - Topic", with: "")
            let results = try await search("\(author) \(cleaned)", country: country, limit: 8)
            return results.map { var item = $0; item.sourceURL = url; return item }
        case .appleMusic(let trackID, let albumID):
            if let id = trackID ?? albumID {
                let results = try await lookup(id: id, country: country)
                guard !results.isEmpty else { throw LookupError.notFound }
                return results
            }
            throw LookupError.notFound
        case .unknown:
            throw LookupError.unsupportedLink
        }
    }

    // MARK: Apple iTunes Search / Lookup

    struct ITunesResponse: Decodable {
        struct Result: Decodable {
            var wrapperType: String?
            var kind: String?
            var trackId: Int?
            var collectionId: Int?
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var artworkUrl100: String?
            var trackTimeMillis: Double?
            var releaseDate: String?
            var primaryGenreName: String?
            var trackViewUrl: String?
            var collectionViewUrl: String?
        }
        var results: [Result]
    }

    static func search(_ term: String, country: String = "KR", entity: String = "song", limit: Int = 10) async throws -> [CatalogItem] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term), .init(name: "entity", value: entity),
            .init(name: "country", value: country), .init(name: "limit", value: String(limit))
        ]
        return try await fetchITunes(components.url!)
    }

    static func lookup(id: String, country: String = "KR") async throws -> [CatalogItem] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: id), .init(name: "country", value: country), .init(name: "entity", value: "song")]
        return try await fetchITunes(components.url!)
    }

    private static func fetchITunes(_ url: URL) async throws -> [CatalogItem] {
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw LookupError.network(error.localizedDescription)
        }
        let response = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return response.results.compactMap(item(from:))
    }

    static func item(from r: ITunesResponse.Result) -> CatalogItem? {
        let isAlbum = r.wrapperType == "collection"
        guard let title = isAlbum ? r.collectionName : r.trackName, let artist = r.artistName else { return nil }
        let id = (isAlbum ? r.collectionId : r.trackId).map(String.init) ?? UUID().uuidString
        // 100x100 썸네일 주소를 큰 크기로 바꾼다(Apple이 안내하는 방식).
        let artwork = r.artworkUrl100.map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }.flatMap(URL.init(string:))
        let year = r.releaseDate.flatMap { Int($0.prefix(4)) }
        let store = (isAlbum ? r.collectionViewUrl : (r.trackViewUrl ?? r.collectionViewUrl)).flatMap(URL.init(string:))
        return CatalogItem(id: (isAlbum ? "album-" : "song-") + id, title: title, artist: artist,
                           album: r.collectionName ?? "", artworkURL: artwork,
                           durationSeconds: r.trackTimeMillis.map { $0 / 1000 }, releaseYear: year,
                           genre: r.primaryGenreName, storeURL: store, sourceURL: nil)
    }

    // MARK: oEmbed (Spotify · YouTube 공개 규격)

    struct OEmbed: Decodable {
        var title: String
        var authorName: String?
        var thumbnailUrl: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailUrl = "thumbnail_url"
        }
    }

    private static func oEmbed(_ base: String, _ url: URL) async throws -> OEmbed {
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?"))),
              let endpoint = URL(string: base + encoded) else { throw LookupError.unsupportedLink }
        do {
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw LookupError.notFound }
            return try JSONDecoder().decode(OEmbed.self, from: data)
        } catch let error as LookupError {
            throw error
        } catch {
            throw LookupError.network(error.localizedDescription)
        }
    }

    /// "Artist - Title (Official Music Video)" 같은 영상 제목에서 곡 제목만 남긴다.
    static func cleanVideoTitle(_ raw: String) -> String {
        var title = raw
        let noise = try! NSRegularExpression(
            pattern: #"\s*[\(\[【][^\)\]】]*(official|mv|m/v|lyric|audio|video|visualizer|live|가사|공식)[^\)\]】]*[\)\]】]"#,
            options: [.caseInsensitive])
        title = noise.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        return title.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 공식 듣기 · 구매 · 검색 링크

    struct StoreLink: Identifiable, Hashable {
        let id: String
        let label: String
        let symbol: String
        let url: URL
    }

    /// 곡을 합법적으로 듣거나 사는 곳 (검색 결과 페이지로 연결)
    static func storeLinks(for item: CatalogItem) -> [StoreLink] {
        let query = "\(item.artist) \(item.title)"
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        var links: [StoreLink] = []
        if let store = item.storeURL {
            links.append(.init(id: "apple", label: "Apple Music · iTunes에서 열기", symbol: "apple.logo", url: store))
        }
        let searches: [(String, String, String, String)] = [
            ("bandcamp", "Bandcamp에서 찾기 (구매 · 무손실 다운로드)", "cart", "https://bandcamp.com/search?q="),
            ("qobuz", "Qobuz 스토어에서 찾기 (무손실 구매)", "cart", "https://www.qobuz.com/us-en/search?q="),
            ("spotify", "Spotify에서 찾기", "music.note", "https://open.spotify.com/search/"),
            ("youtube", "YouTube Music에서 찾기", "play.rectangle", "https://music.youtube.com/search?q=")
        ]
        for (id, label, symbol, base) in searches {
            if let url = URL(string: base + enc(query)) { links.append(.init(id: id, label: label, symbol: symbol, url: url)) }
        }
        return links
    }
}
