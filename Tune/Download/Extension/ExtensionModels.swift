import Foundation

/// 확장이 쓰는 JSON 값. 확장마다 모양이 달라서 원형을 그대로 보관한다.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "지원하지 않는 JSON 값")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

// MARK: - Manifest

struct ExtensionManifest: Codable, Hashable, Sendable {
    struct Permissions: Codable, Hashable, Sendable {
        var network: [String]?
        var storage: Bool?
        var file: Bool?
        var allowHttp: Bool?

        var hosts: [String] { network ?? [] }
    }

    struct Setting: Codable, Identifiable, Hashable, Sendable {
        var key: String
        var label: String
        var type: String
        var description: String?
        var required: Bool?
        var secret: Bool?
        var defaultValue: JSONValue?
        var options: [String]?
        var action: String?

        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, label, type, description, required, secret, options, action
            case defaultValue = "default"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? key
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
            description = try container.decodeIfPresent(String.self, forKey: .description)
            required = try container.decodeIfPresent(Bool.self, forKey: .required)
            secret = try container.decodeIfPresent(Bool.self, forKey: .secret)
            defaultValue = try container.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
            options = try container.decodeIfPresent([String].self, forKey: .options)
            action = try container.decodeIfPresent(String.self, forKey: .action)
        }
    }

    struct Quality: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var description: String?
        var kind: String?

        enum CodingKeys: String, CodingKey { case id, label, description, kind }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
            description = try container.decodeIfPresent(String.self, forKey: .description)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
        }
    }

    struct SearchBehavior: Codable, Hashable, Sendable {
        var enabled: Bool?
        var primary: Bool?
        var placeholder: String?
    }

    struct URLHandler: Codable, Hashable, Sendable {
        var enabled: Bool?
        var patterns: [String]?
    }

    var name: String
    var displayName: String
    var version: String
    var description: String
    var type: [String]
    var minAppVersion: String?
    var requiredRuntimeFeatures: [String]
    var permissions: Permissions
    var qualityOptions: [Quality]
    var settings: [Setting]
    var capabilities: [String: JSONValue]
    var searchBehavior: SearchBehavior?
    var urlHandler: URLHandler?
    var icon: String?
    var skipLyrics: Bool?

    var isDownloadProvider: Bool { type.contains("download_provider") }
    var isMetadataProvider: Bool { type.contains("metadata_provider") }
    var isLyricsProvider: Bool { type.contains("lyrics_provider") }
    var hasCustomSearch: Bool { searchBehavior?.enabled == true }

    var networkTimeout: TimeInterval {
        if let value = capabilities["networkTimeoutSeconds"]?.doubleValue, value > 0 { return value }
        return 30
    }

    enum CodingKeys: String, CodingKey {
        case name, displayName, version, description, type, minAppVersion
        case requiredRuntimeFeatures, permissions, qualityOptions, settings
        case capabilities, searchBehavior, urlHandler, icon, skipLyrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? "이름 없는 확장"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? displayName
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""

        if let list = try? container.decode([String].self, forKey: .type) {
            type = list
        } else if let single = try? container.decode(String.self, forKey: .type) {
            type = [single]
        } else {
            type = []
        }

        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
        requiredRuntimeFeatures = try container.decodeIfPresent([String].self, forKey: .requiredRuntimeFeatures) ?? []
        permissions = try container.decodeIfPresent(Permissions.self, forKey: .permissions) ?? Permissions()
        qualityOptions = try container.decodeIfPresent([Quality].self, forKey: .qualityOptions) ?? []
        settings = try container.decodeIfPresent([Setting].self, forKey: .settings) ?? []
        capabilities = try container.decodeIfPresent([String: JSONValue].self, forKey: .capabilities) ?? [:]
        searchBehavior = try container.decodeIfPresent(SearchBehavior.self, forKey: .searchBehavior)
        urlHandler = try container.decodeIfPresent(URLHandler.self, forKey: .urlHandler)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        skipLyrics = try container.decodeIfPresent(Bool.self, forKey: .skipLyrics)
    }
}

enum ExtensionCompatibility {
    static let supportedRuntimeFeatures: Set<String> = [
        "preparedContext@1",
        "downloadSegments@1",
    ]

    /// Tune의 확장 런타임이 실제로 제공하는 기능만 통과시킨다.
    /// 서명 세션·패턴 파일 변환처럼 Mornye 고유 서버에 기대는 기능은 막는다.
    static func blockedReason(for manifest: ExtensionManifest) -> String? {
        for feature in manifest.requiredRuntimeFeatures {
            if supportedRuntimeFeatures.contains(feature) { continue }
            if feature.hasPrefix("signedSession") || feature.hasPrefix("sessionGrant") {
                return "Mornye 서명 세션(\(feature))이 필요한 확장이에요. Tune에서는 아직 지원하지 않아요."
            }
            if feature.hasPrefix("patternedFileTransform") {
                return "패턴 파일 변환(\(feature))이 필요한 확장이에요. Tune에서는 아직 지원하지 않아요."
            }
            return "확장 기능 \(feature)이(가) 필요해서 Tune에서 실행할 수 없어요."
        }
        return nil
    }
}

// MARK: - Registry

struct ExtensionRegistry: Codable, Sendable {
    var version: Int?
    var extensions: [RegistryEntry]
}

struct RegistryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String?
    var displayName: String?
    var version: String
    var description: String?
    var downloadURL: String
    var sha256: String?
    var iconURL: String?
    var category: String?
    var minAppVersion: String?

    var title: String { displayName ?? name ?? id }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, sha256, category
        case displayName = "display_name"
        case downloadURL = "download_url"
        case iconURL = "icon_url"
        case minAppVersion = "min_app_version"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
    }
}

// MARK: - Installed

struct InstalledExtension: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var manifest: ExtensionManifest
    var directory: String
    var installedAt: Date
    var sourceURL: String?
    var registryURL: String?
    var enabled: Bool
    var blockedReason: String?
    var iconURL: String?

    var isCompatible: Bool { blockedReason == nil }
    var isDownloadProvider: Bool { manifest.isDownloadProvider }

    var title: String { manifest.displayName.isEmpty ? id : manifest.displayName }
}

// MARK: - Provider results

struct ProviderTrack: Codable, Identifiable, Hashable, Sendable {
    var providerID: String
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var durationMs: Int
    var coverURL: String?
    var isrc: String?
    var previewURL: String?
    var preparedContext: JSONValue?

    var id: String { "\(providerID):\(trackID)" }

    init(
        providerID: String,
        trackID: String,
        title: String,
        artist: String,
        album: String = "",
        albumArtist: String = "",
        durationMs: Int = 0,
        coverURL: String? = nil,
        isrc: String? = nil,
        previewURL: String? = nil,
        preparedContext: JSONValue? = nil
    ) {
        self.providerID = providerID
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist.isEmpty ? artist : albumArtist
        self.durationMs = durationMs
        self.coverURL = coverURL
        self.isrc = isrc
        self.previewURL = previewURL
        self.preparedContext = preparedContext
    }
}
