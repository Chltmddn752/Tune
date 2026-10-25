import Foundation

/// 확장 하나를 감싸서 Tune이 쓰는 곡 모양으로 바꾼다.
final class ProviderClient: @unchecked Sendable {
    let installed: InstalledExtension
    private let runtime: JSContextRuntime

    init(
        environment: ProviderEnvironment,
        staging: URL,
        progress: @escaping @Sendable (Double) -> Void,
        logger: @escaping (String, String) -> Void
    ) throws {
        installed = environment.installed
        let storage = ExtensionStorage(directory: environment.root)
        runtime = try JSContextRuntime(
            installed: environment.installed,
            root: environment.root,
            stagingRoot: staging,
            settings: environment.settings,
            storage: storage,
            prelude: environment.prelude,
            progress: progress,
            logger: logger
        )
    }

    func cancel() {
        runtime.cancel()
    }

    // MARK: - Search

    /// 확장의 통합 검색을 한 번 돌려 곡·앨범·아티스트를 모두 나눠 담는다.
    /// 필터를 넘기지 않아야 Amazon처럼 `all`을 모르는 확장에서도 전체 결과가 온다.
    func search(query: String, limit: Int = 20) throws -> ProviderSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ProviderSearchResults() }

        if runtime.has("customSearch") {
            let options: [String: Any] = ["limit": max(limit, 20)]
            let raw = try runtime.call(
                "customSearch",
                argumentsJSON: Self.jsonString([trimmed, options]),
                timeout: 60
            )
            var results = Self.parseSearchResults(raw, providerID: installed.id)

            // Amazon처럼 통합 검색에 곡이 빠지고 앨범·아티스트만 오는 확장은
            // 매니페스트가 알려 준 곡 필터로 한 번 더 찾는다.
            if results.tracks.isEmpty {
                for filter in Self.filterCandidates(for: "track", manifest: installed.manifest) {
                    let filtered = try runtime.call(
                        "customSearch",
                        argumentsJSON: Self.jsonString([trimmed, ["filter": filter, "limit": max(limit, 20)]]),
                        timeout: 60
                    )
                    let tracks = Self.parseTracks(filtered, providerID: installed.id)
                    if !tracks.isEmpty {
                        results.tracks = Array(tracks.prefix(max(limit, 20)))
                        break
                    }
                }
            }
            // 플레이리스트를 통합 검색에 넣지 않거나 몇 개만 넣는 확장은
            // 매니페스트가 알려 준 플레이리스트 필터로 한 번 더 찾는다.
            if results.playlists.isEmpty {
                for filter in Self.filterCandidates(for: "playlist", manifest: installed.manifest) {
                    let filtered = try runtime.call(
                        "customSearch",
                        argumentsJSON: Self.jsonString([trimmed, ["filter": filter, "limit": max(limit, 20)]]),
                        timeout: 60
                    )
                    let playlists = Self.parsePlaylists(filtered, providerID: installed.id)
                    if !playlists.isEmpty {
                        results.playlists = Array(playlists.prefix(max(limit, 20)))
                        break
                    }
                }
            }
            if !results.isEmpty { return results }
        }

        // customSearch가 없는 예전 확장은 곡 검색만 지원한다.
        if runtime.has("searchTracks") {
            let raw = try runtime.call("searchTracks", argumentsJSON: Self.jsonString([trimmed, limit]), timeout: 60)
            return ProviderSearchResults(tracks: Array(Self.parseTracks(raw, providerID: installed.id).prefix(limit)))
        }
        return ProviderSearchResults()
    }

    // MARK: - Collections

    func album(id: String) throws -> ProviderAlbumDetails {
        guard runtime.has("getAlbum") else { throw ProviderError.invalidResponse }
        let raw = try runtime.call("getAlbum", argumentsJSON: Self.jsonString([id]), timeout: 120)
        guard let object = raw as? [String: Any] else { throw ProviderError.invalidResponse }
        let info = object["album_info"] as? [String: Any] ?? object
        guard var album = Self.parseAlbum(info, providerID: installed.id, allowUntyped: true) else {
            throw ProviderError.invalidResponse
        }
        if album.title.isEmpty { album.title = Self.string(info["title"]) ?? "" }
        let rawTracks = object["tracks"] ?? object["track_list"] ?? info["tracks"]
        let tracks = Self.parseTracks(rawTracks, providerID: installed.id).map { track in
            Self.enrich(track, with: album)
        }
        return ProviderAlbumDetails(album: album, tracks: tracks)
    }

    func artist(id: String) throws -> ProviderArtistDetails {
        guard runtime.has("getArtist") else { throw ProviderError.invalidResponse }
        let raw = try runtime.call("getArtist", argumentsJSON: Self.jsonString([id]), timeout: 120)
        guard let object = raw as? [String: Any] else { throw ProviderError.invalidResponse }
        let info = object["artist_info"] as? [String: Any] ?? object
        guard let artist = Self.parseArtist(info, providerID: installed.id, allowUntyped: true) else {
            throw ProviderError.invalidResponse
        }

        let albumLists = [object["albums"], info["albums"], object["releases"], info["releases"]]
        var albums: [ProviderAlbum] = []
        var seenAlbums = Set<String>()
        for list in albumLists {
            for album in Self.parseAlbums(list, providerID: installed.id) where seenAlbums.insert(album.albumID).inserted {
                albums.append(album)
            }
        }

        let topTracks = Self.parseTracks(object["top_tracks"] ?? info["top_tracks"], providerID: installed.id)
        return ProviderArtistDetails(artist: artist, albums: albums, topTracks: topTracks)
    }

    /// 플레이리스트를 연다. getPlaylist가 없는 확장은 앨범처럼 열어 준다.
    func playlist(id: String) throws -> ProviderPlaylistDetails {
        let methods = ["getPlaylist", "getAlbum"].filter { runtime.has($0) }
        guard !methods.isEmpty else { throw ProviderError.invalidResponse }
        var lastError: Error?
        for method in methods {
            do {
                let raw = try runtime.call(method, argumentsJSON: Self.jsonString([id]), timeout: 120)
                guard let object = raw as? [String: Any] else { throw ProviderError.invalidResponse }
                let info = object["playlist_info"] as? [String: Any] ?? object
                guard var playlist = Self.parsePlaylist(info, providerID: installed.id, allowUntyped: true) else {
                    throw ProviderError.invalidResponse
                }
                if playlist.title.isEmpty { playlist.title = Self.string(info["title"]) ?? "" }
                let rawTracks = object["tracks"] ?? object["track_list"] ?? info["tracks"]
                let tracks = Self.parseTracks(rawTracks, providerID: installed.id).map { track -> ProviderTrack in
                    var value = track
                    if value.coverURL == nil { value.coverURL = playlist.coverURL }
                    return value
                }
                return ProviderPlaylistDetails(playlist: playlist, tracks: tracks)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProviderError.invalidResponse
    }

    func resolveLink(_ url: String) throws -> [ProviderTrack] {
        guard runtime.has("handleUrl") else { return [] }
        let raw = try runtime.call("handleUrl", argumentsJSON: Self.jsonString([url]), timeout: 60)
        guard let object = raw as? [String: Any] else { return [] }
        if let track = object["track"] as? [String: Any], let parsed = Self.parseTrack(track, providerID: installed.id) {
            return [parsed]
        }
        if let tracks = object["tracks"] as? [[String: Any]] {
            return tracks.compactMap { Self.parseTrack($0, providerID: installed.id) }
        }
        for key in ["album", "playlist"] {
            if let collection = object[key] as? [String: Any],
               let tracks = collection["tracks"] as? [[String: Any]] {
                return tracks.compactMap { Self.parseTrack($0, providerID: installed.id) }
            }
        }
        if object["id"] != nil, let parsed = Self.parseTrack(object, providerID: installed.id) {
            return [parsed]
        }
        return []
    }

    func checkAvailability(for track: ProviderTrack, isrc: String? = nil) throws -> (trackID: String, preparedContext: JSONValue?)? {
        guard runtime.has("checkAvailability") else { return nil }
        let options: [String: Any] = [
            "duration_ms": track.durationMs,
            "track": Self.trackDictionary(track),
        ]
        let arguments = Self.jsonString([isrc ?? track.isrc ?? "", track.title, track.artist, options])
        let raw = try runtime.call("checkAvailability", argumentsJSON: arguments, timeout: 60)
        guard let object = raw as? [String: Any] else { return nil }
        guard Self.bool(object["available"]) != false else { return nil }
        let identifier = Self.string(object["track_id"] ?? object["trackId"]) ?? track.trackID
        guard !identifier.isEmpty else { return nil }
        let prepared = (object["prepared_context"] ?? object["preparedContext"]).flatMap(Self.jsonValue)
        return (identifier, prepared)
    }

    // MARK: - Download

    func download(
        _ track: ProviderTrack,
        quality: String,
        output: URL,
        preparedContext: JSONValue? = nil
    ) throws -> ProviderDownloadResult {
        var options: [String: Any] = [
            "duration_ms": track.durationMs,
            "track": Self.trackDictionary(track),
        ]
        if let preparedContext {
            options["preparedContext"] = Self.anyValue(preparedContext)
        } else if let context = track.preparedContext {
            options["preparedContext"] = Self.anyValue(context)
        }

        let raw = try runtime.callDownload(
            method: "download",
            trackID: track.trackID,
            quality: quality,
            outputPath: output.path,
            options: options,
            timeout: 900
        )
        guard let object = raw as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        guard Self.bool(object["success"]) == true else {
            let message = Self.string(object["error_message"] ?? object["errorMessage"] ?? object["error"]) ?? "다운로드에 실패했어요."
            throw ProviderError.downloadFailed(message)
        }

        let resolvedPath = Self.string(object["file_path"] ?? object["filePath"] ?? object["path"])
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) }
            ?? Self.findProducedFile(in: output.deletingLastPathComponent(), preferred: output)
        guard let resolvedPath, FileManager.default.fileExists(atPath: resolvedPath.path) else {
            throw ProviderError.outputMissing
        }

        // Amazon Music처럼 확장이 암호화한 통(ISO-BMFF)으로 내려주면 여기서 풀어 준다.
        let finalPath = try Self.playableFile(at: resolvedPath, result: object)

        let metadata = Self.metadata(from: object, fallback: track)
        return ProviderDownloadResult(filePath: finalPath.path, metadata: metadata, raw: object)
    }

    // MARK: - Decryption

    private struct DecryptionInfo {
        var strategy: String
        var key: String
    }

    private static func decryptionInfo(from raw: [String: Any]) -> DecryptionInfo? {
        let legacy = string(raw["decryption_key"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let info = raw["decryption"] as? [String: Any] else {
            return legacy.isEmpty ? nil : DecryptionInfo(strategy: "ffmpeg.mov_key", key: legacy)
        }
        let strategy = string(info["strategy"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let key = string(info["key"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? legacy
        return DecryptionInfo(strategy: strategy, key: key)
    }

    /// 확장이 알려 준 암호화 정보로 재생 가능한 파일을 만든다.
    /// 암호화와 상관없이 FLAC을 MP4 통에 담아 준 경우에도 꺼내 준다.
    private static func playableFile(at url: URL, result: [String: Any]) throws -> URL {
        let decryption = decryptionInfo(from: result)
        if let decryption {
            let supported = [
                "", "ffmpeg.mov_key", "ffmpeg_mov_key", "mov_decryption_key",
                "mp4_decryption_key", "ffmpeg.mp4_decryption_key",
            ]
            guard supported.contains(decryption.strategy) else {
                throw ProviderError.downloadFailed("이 확장은 \(decryption.strategy) 방식으로 암호화해서 Tune에서 풀 수 없어요.")
            }
        }
        do {
            if let converted = try ProtectedMedia.normalize(fileAt: url, decryptionKey: decryption?.key) {
                return converted
            }
        } catch {
            throw ProviderError.downloadFailed(error.localizedDescription)
        }
        if let decryption, decryption.key.isEmpty {
            throw ProviderError.downloadFailed("암호화된 음원인데 복호화 키가 없어요. 확장을 다시 설치해 주세요.")
        }
        if decryption != nil {
            throw ProviderError.downloadFailed("암호화된 음원인데 형식을 알아보지 못했어요.")
        }
        return url
    }

    // MARK: - Parsing

    private static func filterCandidates(for kind: String, manifest: ExtensionManifest) -> [String] {
        let declared = manifest.searchBehavior?.filters?.map { $0.id.lowercased() } ?? []
        let preferred: [String]
        switch kind {
        case "track": preferred = ["track", "songs", "song", "tracks"]
        case "album": preferred = ["album", "albums"]
        case "playlist": preferred = ["playlists", "playlist", "lists"]
        default: preferred = ["artist", "artists"]
        }
        let fromManifest = preferred.filter { declared.contains($0) }
        return fromManifest.isEmpty ? preferred : fromManifest + preferred.filter { !fromManifest.contains($0) }
    }

    private static func parseSearchResults(_ raw: Any?, providerID: String) -> ProviderSearchResults {
        var results = ProviderSearchResults()
        var seenTracks = Set<String>()
        var seenAlbums = Set<String>()
        var seenArtists = Set<String>()
        var seenPlaylists = Set<String>()

        func add(_ item: [String: Any]) {
            let type = string(item["item_type"] ?? item["itemType"] ?? item["type"])?.lowercased()
            switch type {
            case "album":
                if let album = parseAlbum(item, providerID: providerID), seenAlbums.insert(album.albumID).inserted {
                    results.albums.append(album)
                }
            case "artist":
                if let artist = parseArtist(item, providerID: providerID), seenArtists.insert(artist.artistID).inserted {
                    results.artists.append(artist)
                }
            case "playlist":
                if let playlist = parsePlaylist(item, providerID: providerID), seenPlaylists.insert(playlist.playlistID).inserted {
                    results.playlists.append(playlist)
                }
            case "show", "episode":
                return
            default:
                if let track = parseTrack(item, providerID: providerID), seenTracks.insert(track.trackID).inserted {
                    results.tracks.append(track)
                }
            }
        }

        if let list = raw as? [[String: Any]] {
            list.forEach(add)
        } else if let object = raw as? [String: Any] {
            for key in ["tracks", "results", "items"] {
                if let list = object[key] as? [[String: Any]] {
                    list.forEach(add)
                }
            }
            for (key, type) in [("albums", "album"), ("artists", "artist"), ("playlists", "playlist")] {
                guard let list = object[key] as? [[String: Any]] else { continue }
                for item in list {
                    var value = item
                    if value["item_type"] == nil { value["item_type"] = type }
                    add(value)
                }
            }
            if results.isEmpty { add(object) }
        }
        return results
    }

    private static func parseTracks(_ raw: Any?, providerID: String) -> [ProviderTrack] {
        if let list = raw as? [[String: Any]] {
            return dedupe(list.compactMap { parseTrack($0, providerID: providerID) })
        }
        if let object = raw as? [String: Any] {
            if let list = object["tracks"] as? [[String: Any]] {
                return dedupe(list.compactMap { parseTrack($0, providerID: providerID) })
            }
            if let list = object["track_list"] as? [[String: Any]] {
                return dedupe(list.compactMap { parseTrack($0, providerID: providerID) })
            }
            if let list = object["results"] as? [[String: Any]] {
                return dedupe(list.compactMap { parseTrack($0, providerID: providerID) })
            }
            if let single = parseTrack(object, providerID: providerID) {
                return [single]
            }
        }
        return []
    }

    private static func parseTrack(_ raw: [String: Any], providerID: String) -> ProviderTrack? {
        let id = string(raw["id"] ?? raw["track_id"] ?? raw["trackId"])
        guard let id, !id.isEmpty else { return nil }
        let type = string(raw["item_type"] ?? raw["itemType"] ?? raw["type"])?.lowercased()
        if let type, !["track", "song", "video"].contains(type) { return nil }

        let title = string(raw["name"] ?? raw["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let artist = artists(raw["artists"] ?? raw["artist"] ?? raw["album_artist"] ?? raw["albumArtist"])
        let album = string(raw["album_name"] ?? raw["albumName"] ?? raw["album"]) ?? ""
        let albumArtist = string(raw["album_artist"] ?? raw["albumArtist"]) ?? artist
        let duration = durationMs(raw)
        let cover = coverURL(raw)
        let isrc = string(raw["isrc"])
        let preview = string(raw["preview_url"] ?? raw["previewUrl"])
        let prepared = (raw["prepared_context"] ?? raw["preparedContext"]).flatMap(jsonValue)

        return ProviderTrack(
            providerID: providerID,
            trackID: id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            durationMs: duration,
            coverURL: cover,
            isrc: isrc,
            previewURL: preview,
            preparedContext: prepared,
            albumID: string(raw["album_id"] ?? raw["albumId"]),
            artistID: string(raw["artist_id"] ?? raw["artistId"]),
            trackNumber: int(raw["track_number"] ?? raw["trackNumber"]),
            discNumber: int(raw["disc_number"] ?? raw["discNumber"]),
            releaseDate: string(raw["release_date"] ?? raw["releaseDate"]),
            albumType: string(raw["album_type"] ?? raw["albumType"]),
            isExplicit: bool(raw["explicit"]) == true
        )
    }

    private static func parseAlbums(_ raw: Any?, providerID: String) -> [ProviderAlbum] {
        if let list = raw as? [[String: Any]] {
            return list.compactMap { parseAlbum($0, providerID: providerID) }
        }
        if let object = raw as? [String: Any], let album = parseAlbum(object, providerID: providerID) {
            return [album]
        }
        return []
    }

    private static func parseAlbum(
        _ raw: [String: Any],
        providerID: String,
        allowUntyped: Bool = false
    ) -> ProviderAlbum? {
        let type = string(raw["item_type"] ?? raw["itemType"] ?? raw["type"])?.lowercased()
        if let type, !["album", "ep", "single", "compilation"].contains(type) {
            guard allowUntyped, raw["total_tracks"] != nil || raw["album_type"] != nil else { return nil }
        }
        if type == nil, !allowUntyped,
           raw["total_tracks"] == nil, raw["album_type"] == nil {
            return nil
        }

        let id = string(raw["id"] ?? raw["album_id"] ?? raw["albumId"])
        guard let id, !id.isEmpty else { return nil }
        let title = string(raw["name"] ?? raw["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        return ProviderAlbum(
            providerID: providerID,
            albumID: id,
            title: title,
            artist: artists(raw["artists"] ?? raw["artist"] ?? raw["album_artist"] ?? raw["albumArtist"]),
            artistID: string(raw["artist_id"] ?? raw["artistId"]),
            coverURL: coverURL(raw),
            releaseDate: string(raw["release_date"] ?? raw["releaseDate"]),
            totalTracks: int(raw["total_tracks"] ?? raw["totalTracks"] ?? raw["track_count"]) ?? 0,
            albumType: string(raw["album_type"] ?? raw["albumType"] ?? raw["record_type"]),
            isExplicit: bool(raw["explicit"]) == true
        )
    }

    private static func parsePlaylists(_ raw: Any?, providerID: String) -> [ProviderPlaylist] {
        if let list = raw as? [[String: Any]] {
            var seen = Set<String>()
            return list.compactMap { parsePlaylist($0, providerID: providerID) }
                .filter { seen.insert($0.playlistID).inserted }
        }
        if let object = raw as? [String: Any] {
            for key in ["playlists", "results", "items"] {
                if let list = object[key] as? [[String: Any]] {
                    return parsePlaylists(list, providerID: providerID)
                }
            }
            if let playlist = parsePlaylist(object, providerID: providerID) {
                return [playlist]
            }
        }
        return []
    }

    private static func parsePlaylist(
        _ raw: [String: Any],
        providerID: String,
        allowUntyped: Bool = false
    ) -> ProviderPlaylist? {
        let type = string(raw["item_type"] ?? raw["itemType"] ?? raw["type"])?.lowercased()
        if let type, type != "playlist", !allowUntyped { return nil }

        let id = string(raw["id"] ?? raw["playlist_id"] ?? raw["playlistId"])
        guard let id, !id.isEmpty else { return nil }
        let title = string(raw["name"] ?? raw["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        let detail = string(raw["description"] ?? raw["detail"] ?? raw["summary"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ProviderPlaylist(
            providerID: providerID,
            playlistID: id,
            title: title,
            owner: string(raw["owner"] ?? raw["curator"] ?? raw["owner_name"] ?? raw["ownerName"]
                ?? raw["artists"] ?? raw["artist"]) ?? "",
            detail: detail,
            coverURL: coverURL(raw),
            totalTracks: int(raw["total_tracks"] ?? raw["totalTracks"] ?? raw["track_count"] ?? raw["trackCount"]) ?? 0
        )
    }

    private static func parseArtist(
        _ raw: [String: Any],
        providerID: String,
        allowUntyped: Bool = false
    ) -> ProviderArtist? {
        let type = string(raw["item_type"] ?? raw["itemType"] ?? raw["type"])?.lowercased()
        if let type, type != "artist", !allowUntyped { return nil }
        if type == nil, !allowUntyped, raw["listeners"] == nil, raw["followers"] == nil { return nil }

        let id = string(raw["id"] ?? raw["artist_id"] ?? raw["artistId"])
        guard let id, !id.isEmpty else { return nil }
        let name = string(raw["name"] ?? raw["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        return ProviderArtist(
            providerID: providerID,
            artistID: id,
            name: name,
            imageURL: coverURL(raw),
            listeners: int(raw["listeners"] ?? raw["followers"] ?? raw["nb_fan"])
        )
    }

    private static func enrich(_ track: ProviderTrack, with album: ProviderAlbum) -> ProviderTrack {
        var value = track
        if value.album.isEmpty { value.album = album.title }
        if value.albumArtist.isEmpty { value.albumArtist = album.artist }
        if value.coverURL == nil { value.coverURL = album.coverURL }
        if value.albumID == nil { value.albumID = album.albumID }
        if value.artistID == nil { value.artistID = album.artistID }
        if value.releaseDate == nil { value.releaseDate = album.releaseDate }
        if value.albumType == nil { value.albumType = album.albumType }
        return value
    }

    private static func dedupe(_ tracks: [ProviderTrack]) -> [ProviderTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.trackID).inserted }
    }

    private static func metadata(from raw: [String: Any], fallback: ProviderTrack) -> DownloadedMetadata {
        let release = string(raw["release_date"] ?? raw["releaseDate"]) ?? ""
        let year = Int(release.prefix(4)).flatMap { $0 > 1800 ? $0 : nil }
        return DownloadedMetadata(
            title: string(raw["title"]) ?? fallback.title,
            artist: string(raw["artist"] ?? raw["artists"]) ?? fallback.artist,
            album: string(raw["album"]) ?? fallback.album,
            albumArtist: string(raw["album_artist"] ?? raw["albumArtist"]) ?? fallback.albumArtist,
            trackNumber: int(raw["track_number"] ?? raw["trackNumber"]),
            discNumber: int(raw["disc_number"] ?? raw["discNumber"]),
            year: year,
            genre: string(raw["genre"]),
            isrc: string(raw["isrc"]) ?? fallback.isrc,
            coverURL: string(raw["cover_url"] ?? raw["coverUrl"]) ?? fallback.coverURL,
            duration: nil
        )
    }

    static func trackDictionary(_ track: ProviderTrack) -> [String: Any] {
        var value: [String: Any] = [
            "id": track.trackID,
            "name": track.title,
            "artists": track.artist,
            "album_name": track.album,
            "album_artist": track.albumArtist,
            "duration_ms": track.durationMs,
            "provider_id": track.providerID,
            "item_type": "track",
        ]
        if let isrc = track.isrc { value["isrc"] = isrc }
        if let cover = track.coverURL { value["cover_url"] = cover }
        if let albumID = track.albumID { value["album_id"] = albumID }
        if let artistID = track.artistID { value["artist_id"] = artistID }
        if let number = track.trackNumber { value["track_number"] = number }
        if let disc = track.discNumber { value["disc_number"] = disc }
        if let date = track.releaseDate { value["release_date"] = date }
        if track.isExplicit { value["explicit"] = true }
        return value
    }

    private static func artists(_ value: Any?) -> String {
        if let text = string(value) { return text }
        if let list = value as? [String] { return list.joined(separator: ", ") }
        if let object = value as? [String: Any], let name = string(object["name"]) {
            return name
        }
        if let list = value as? [[String: Any]] {
            return list.compactMap { string($0["name"] ?? $0["artist"] ?? $0["title"]) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        return ""
    }

    private static func coverURL(_ raw: [String: Any]) -> String? {
        for key in ["cover_url", "coverUrl", "image_url", "header_image", "image", "thumbnail"] {
            if let value = string(raw[key]), !value.isEmpty { return value }
        }
        if let images = raw["images"] as? String { return images.isEmpty ? nil : images }
        if let images = raw["images"] as? [[String: Any]] {
            return images.compactMap { string($0["url"]) }.last
        }
        return nil
    }

    private static func durationMs(_ raw: [String: Any]) -> Int {
        if let value = int(raw["duration_ms"] ?? raw["durationMs"]) { return value }
        if let value = int(raw["duration"]) {
            return value > 0 && value < 1_000 ? value * 1000 : value
        }
        return 0
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as NSNumber: value.intValue
        case let value as String: Int(value) ?? Double(value).map(Int.init)
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func jsonValue(_ value: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return decoded
    }

    private static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(anyValue)
        case .array(let value): value.map(anyValue)
        case .null: NSNull()
        }
    }

    private static func findProducedFile(in directory: URL, preferred: URL) -> URL? {
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return nil }
        return files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .max { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
    }
}

enum ProviderError: LocalizedError {
    case invalidResponse
    case downloadFailed(String)
    case outputMissing
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "확장이 이상한 응답을 보냈어요."
        case .downloadFailed(let message): message
        case .outputMissing: "내려받은 파일을 찾지 못했어요."
        case .unavailable(let message): message
        }
    }
}
