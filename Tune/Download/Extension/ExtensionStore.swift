import CryptoKit
import Foundation
import Observation

enum ExtensionPaths {
    static var base: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent("Tune/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var downloads: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent("Tune/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var libraryDownloads: URL {
        let url = LibraryPaths.documents.appendingPathComponent("다운로드", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func directory(for identifier: String) -> URL {
        base.appendingPathComponent(identifier, isDirectory: true)
    }

    static func staging(for jobID: UUID) -> URL {
        let url = downloads.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
@Observable
final class ExtensionStore {
    static let shared = ExtensionStore()

    private static let defaultRegistry = "https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/main/registry.json"
    private static let registryKey = "extensionRegistryURL"

    var installed: [InstalledExtension] = []
    var registry: ExtensionRegistry?
    var registryURL: String {
        didSet { UserDefaults.standard.set(registryURL, forKey: Self.registryKey) }
    }
    var isLoadingRegistry = false
    var registryError: String?
    var installMessage: String?
    var installingID: String?
    var installProgress: Double = 0

    private var storedSettings: [String: [String: JSONValue]] = [:]

    private init() {
        registryURL = UserDefaults.standard.string(forKey: Self.registryKey) ?? Self.defaultRegistry
        loadInstalled()
        loadSettings()
    }

    var compatibleInstallableExtensions: [InstalledExtension] {
        installed.filter { $0.enabled && $0.isCompatible && $0.isDownloadProvider }
    }

    var registryEntries: [RegistryEntry] {
        registry?.extensions ?? []
    }

    func installedExtension(id: String) -> InstalledExtension? {
        installed.first { $0.id == id }
    }

    func installedVersion(id: String) -> String? {
        installedExtension(id: id)?.manifest.version
    }

    func isUpdateAvailable(_ entry: RegistryEntry) -> Bool {
        guard let current = installedVersion(id: entry.id) else { return false }
        return current != entry.version
    }

    func refreshRegistry() async {
        isLoadingRegistry = true
        registryError = nil
        defer { isLoadingRegistry = false }
        do {
            guard let url = URL(string: registryURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ExtensionInstallError.invalidRegistryURL
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Tune/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ExtensionInstallError.registryFailed("서버가 \((response as? HTTPURLResponse)?.statusCode ?? 0)을 돌려줬어요.")
            }
            registry = try JSONDecoder().decode(ExtensionRegistry.self, from: data)
        } catch {
            registry = nil
            registryError = error.localizedDescription
        }
    }

    func install(_ entry: RegistryEntry) async {
        installingID = entry.id
        installProgress = 0
        installMessage = nil
        defer { installingID = nil }
        do {
            guard let url = URL(string: entry.downloadURL) else { throw ExtensionInstallError.invalidPackageURL }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue("Tune/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ExtensionInstallError.registryFailed("확장 파일을 받지 못했어요.")
            }
            if let expected = entry.sha256?.lowercased(), !expected.isEmpty {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == expected else { throw ExtensionInstallError.checksumMismatch }
            }
            try installPackage(data: data, entry: entry)
            installMessage = "\(entry.title) \(entry.version)을 설치했어요."
        } catch {
            installMessage = error.localizedDescription
        }
    }

    func installFromFile(_ url: URL) async {
        installMessage = nil
        installingID = "file"
        defer { installingID = nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try installPackage(data: data, entry: nil)
            installMessage = "확장을 설치했어요."
        } catch {
            installMessage = error.localizedDescription
        }
    }

    func remove(_ extensionID: String) {
        guard let index = installed.firstIndex(where: { $0.id == extensionID }) else { return }
        let directory = ExtensionPaths.directory(for: installed[index].directory)
        try? FileManager.default.removeItem(at: directory)
        installed.remove(at: index)
        storedSettings.removeValue(forKey: extensionID)
        saveInstalled()
        saveSettings()
        installMessage = "\(extensionID)을 삭제했어요."
    }

    func setEnabled(_ enabled: Bool, for extensionID: String) {
        guard let index = installed.firstIndex(where: { $0.id == extensionID }) else { return }
        installed[index].enabled = enabled
        saveInstalled()
    }

    func directory(for installedExtension: InstalledExtension) -> URL {
        ExtensionPaths.directory(for: installedExtension.directory)
    }

    // MARK: - Runtime

    func providerEnvironment(for installedExtension: InstalledExtension) throws -> ProviderEnvironment {
        guard installedExtension.isCompatible else {
            throw ExtensionInstallError.incompatible(installedExtension.blockedReason ?? "이 확장은 실행할 수 없어요.")
        }
        guard installedExtension.enabled else {
            throw ExtensionInstallError.incompatible("확장이 꺼져 있어요.")
        }
        let directory = directory(for: installedExtension)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.js").path) else {
            throw ExtensionInstallError.missingEntryPoint
        }
        return ProviderEnvironment(
            installed: installedExtension,
            root: directory,
            prelude: try preludeSource(),
            settings: settingsJSON(for: installedExtension)
        )
    }

    func defaultQuality(for installedExtension: InstalledExtension) -> String {
        let key = "downloadQuality.\(installedExtension.id)"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        return installedExtension.manifest.qualityOptions.first?.id ?? "best"
    }

    func setDefaultQuality(_ quality: String, for installedExtension: InstalledExtension) {
        UserDefaults.standard.set(quality, forKey: "downloadQuality.\(installedExtension.id)")
    }

    /// 확장 설정의 버튼(예: 캐시 지우기)이 가리키는 JS 함수를 실행한다.
    func performAction(_ action: String, for installedExtension: InstalledExtension) async -> String {
        do {
            let staging = ExtensionPaths.staging(for: UUID())
            defer { try? FileManager.default.removeItem(at: staging) }
            let runtime = try makeRuntime(for: installedExtension, staging: staging)
            return try await Task.detached(priority: .userInitiated) {
                let value = try runtime.call(action, timeout: 90)
                if let text = value as? String, !text.isEmpty { return text }
                return "완료했어요."
            }.value
        } catch {
            return error.localizedDescription
        }
    }

    func makeRuntime(
        for installedExtension: InstalledExtension,
        staging: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        logger: @escaping (String, String) -> Void = { _, _ in }
    ) throws -> JSContextRuntime {
        guard installedExtension.isCompatible else {
            throw ExtensionInstallError.incompatible(installedExtension.blockedReason ?? "이 확장은 실행할 수 없어요.")
        }
        guard installedExtension.enabled else {
            throw ExtensionInstallError.incompatible("확장이 꺼져 있어요.")
        }
        let directory = directory(for: installedExtension)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.js").path) else {
            throw ExtensionInstallError.missingEntryPoint
        }
        let prelude = try preludeSource()
        let storage = ExtensionStorage(directory: directory)
        return try JSContextRuntime(
            installed: installedExtension,
            root: directory,
            stagingRoot: staging,
            settings: settingsJSON(for: installedExtension),
            storage: storage,
            prelude: prelude,
            progress: progress,
            logger: logger
        )
    }

    private func preludeSource() throws -> String {
        let candidates = [
            Bundle.main.url(forResource: "extension-prelude", withExtension: "js"),
            Bundle.main.bundleURL.appendingPathComponent("extension-prelude.js"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let source = try? String(contentsOf: url, encoding: .utf8) { return source }
        }
        throw ExtensionInstallError.missingPrelude
    }

    // MARK: - Settings

    func settingsValues(for installedExtension: InstalledExtension) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for setting in installedExtension.manifest.settings {
            if let value = setting.defaultValue { values[setting.key] = value }
        }
        for (key, value) in storedSettings[installedExtension.id] ?? [:] {
            values[key] = value
        }
        return values
    }

    func settingValue(_ key: String, for installedExtension: InstalledExtension) -> JSONValue? {
        settingsValues(for: installedExtension)[key]
    }

    func setSetting(_ key: String, value: JSONValue, for installedExtension: InstalledExtension) {
        var values = storedSettings[installedExtension.id] ?? [:]
        values[key] = value
        storedSettings[installedExtension.id] = values
        saveSettings()
    }

    func settingsJSON(for installedExtension: InstalledExtension) -> [String: JSONValue] {
        settingsValues(for: installedExtension)
    }

    // MARK: - Persistence

    private func loadInstalled() {
        let url = ExtensionPaths.base.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([InstalledExtension].self, from: data) else {
            installed = []
            return
        }
        installed = decoded.compactMap { item in
            var value = item
            let directory = ExtensionPaths.directory(for: item.directory)
            // 앱을 업데이트하면 예전에 저장한 매니페스트에는 새 필드(예: signedSession)가 없다.
            // 디스크의 manifest.json을 다시 읽어 설치된 확장도 새 기능을 바로 인식하게 한다.
            let manifestURL = directory.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data) {
                value.manifest = manifest
            }
            value.blockedReason = ExtensionCompatibility.blockedReason(for: value.manifest)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.js").path) else { return nil }
            return value
        }
    }

    private func saveInstalled() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: ExtensionPaths.base.appendingPathComponent("installed.json"), options: .atomic)
    }

    private func loadSettings() {
        let url = ExtensionPaths.base.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data) else {
            storedSettings = [:]
            return
        }
        storedSettings = decoded
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        try? data.write(to: ExtensionPaths.base.appendingPathComponent("settings.json"), options: .atomic)
    }

    // MARK: - Install package

    private func installPackage(data: Data, entry: RegistryEntry?) throws {
        guard data.count < 32 * 1024 * 1024 else { throw ExtensionInstallError.packageTooLarge }
        let incoming = ExtensionPaths.base.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: incoming) }

        try ZipArchive.extract(data: data, to: incoming)
        let manifestURL = incoming.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: incoming.appendingPathComponent("index.js").path) else {
            throw ExtensionInstallError.missingEntryPoint
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        let identifier = manifest.name
        guard identifier.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
            throw ExtensionInstallError.invalidIdentifier
        }

        let destination = ExtensionPaths.directory(for: identifier)
        let previous = installedExtension(id: identifier)
        let enabled = previous?.enabled ?? true
        let wasInstalled = FileManager.default.fileExists(atPath: destination.path)

        // 업데이트할 때 확장 저장소와 파일은 그대로 둔다.
        let preserved = incoming.appendingPathComponent(".preserved", isDirectory: true)
        if wasInstalled {
            try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
            for name in ["storage.json", "credentials.json", "files", "signed_sessions"] {
                let source = destination.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.moveItem(at: source, to: preserved.appendingPathComponent(name))
                }
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: incoming, to: destination)
        let preservedInDestination = destination.appendingPathComponent(".preserved", isDirectory: true)
        for name in ["storage.json", "credentials.json", "files", "signed_sessions"] {
            let source = preservedInDestination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: destination.appendingPathComponent(name))
            }
        }
        _ = try? FileManager.default.removeItem(at: preservedInDestination)

        let installedValue = InstalledExtension(
            id: identifier,
            manifest: manifest,
            directory: identifier,
            installedAt: previous?.installedAt ?? .now,
            sourceURL: entry?.downloadURL,
            registryURL: entry == nil ? nil : registryURL,
            enabled: enabled,
            blockedReason: ExtensionCompatibility.blockedReason(for: manifest),
            iconURL: entry?.iconURL
        )
        installed.removeAll { $0.id == identifier }
        installed.append(installedValue)
        installed.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        saveInstalled()
    }

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.8.4"
    }
}

enum ExtensionInstallError: LocalizedError {
    case invalidRegistryURL
    case invalidPackageURL
    case registryFailed(String)
    case checksumMismatch
    case packageTooLarge
    case invalidIdentifier
    case missingEntryPoint
    case missingPrelude
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .invalidRegistryURL: "확장 스토어 주소가 올바르지 않아요."
        case .invalidPackageURL: "확장 파일 주소가 올바르지 않아요."
        case .registryFailed(let message): message
        case .checksumMismatch: "내려받은 확장 파일의 체크섬이 맞지 않아요. 다시 시도해 주세요."
        case .packageTooLarge: "확장 패키지가 너무 커요(최대 32MB)."
        case .invalidIdentifier: "확장 이름에 쓸 수 없는 문자가 있어요."
        case .missingEntryPoint: "확장 패키지에 index.js가 없어요."
        case .missingPrelude: "앱에 확장 실행 파일(extension-prelude.js)이 빠졌어요."
        case .incompatible(let message): message
        }
    }
}
