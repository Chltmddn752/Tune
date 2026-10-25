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

    func search(query: String, limit: Int = 20) throws -> [ProviderTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if runtime.has("customSearch") {
            let options: [String: Any] = ["filter": "tracks", "limit": limit]
            let arguments = Self.jsonString([trimmed, options])
            var raw = try runtime.call("customSearch", argumentsJSON: arguments, timeout: 60)
            var tracks = Self.parseTracks(raw, providerID: installed.id)
            if tracks.isEmpty {
                let allOptions: [String: Any] = ["filter": "all", "limit": limit]
                raw = try runtime.call("customSearch", argumentsJSON: Self.jsonString([trimmed, allOptions]), timeout: 60)
                tracks = Self.parseTracks(raw, providerID: installed.id)
            }
            if !tracks.isEmpty { return Array(tracks.prefix(limit)) }
        }

        if runtime.has("searchTracks") {
            let raw = try runtime.call("searchTracks", argumentsJSON: Self.jsonString([trimmed, limit]), timeout: 60)
            return Array(Self.parseTracks(raw, providerID: installed.id).prefix(limit))
        }
        return []
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

        let metadata = Self.metadata(from: object, fallback: track)
        return ProviderDownloadResult(filePath: resolvedPath.path, metadata: metadata, raw: object)
    }

    // MARK: - Parsing

    private static func parseTracks(_ raw: Any?, providerID: String) -> [ProviderTrack] {
        if let list = raw as? [[String: Any]] {
            return dedupe(list.compactMap { parseTrack($0, providerID: providerID) })
        }
        if let object = raw as? [String: Any] {
            if let list = object["tracks"] as? [[String: Any]] {
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
            preparedContext: prepared
        )
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
        return value
    }

    private static func artists(_ value: Any?) -> String {
        if let text = string(value) { return text }
        if let list = value as? [String] { return list.joined(separator: ", ") }
        if let list = value as? [[String: Any]] {
            return list.compactMap { string($0["name"] ?? $0["artist"] ?? $0["title"]) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        return ""
    }

    private static func coverURL(_ raw: [String: Any]) -> String? {
        if let value = string(raw["cover_url"] ?? raw["coverUrl"] ?? raw["thumbnail"] ?? raw["image"]) {
            return value.isEmpty ? nil : value
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
