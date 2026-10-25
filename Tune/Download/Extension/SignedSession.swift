import CryptoKit
import Foundation

/// 확장 매니페스트의 `signedSession` 블록. Mornye의 HMAC 서명 세션과 같은 모양이다.
struct SignedSessionConfig: Codable, Hashable, Sendable {
    struct Endpoints: Codable, Hashable, Sendable {
        var bootstrap: String = "/bootstrap"
        var challenge: String = "/challenge"
        var exchange: String = "/session/exchange"
        var refresh: String = ""

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bootstrap = try container.decodeIfPresent(String.self, forKey: .bootstrap) ?? "/bootstrap"
            challenge = try container.decodeIfPresent(String.self, forKey: .challenge) ?? "/challenge"
            exchange = try container.decodeIfPresent(String.self, forKey: .exchange) ?? "/session/exchange"
            refresh = try container.decodeIfPresent(String.self, forKey: .refresh) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case bootstrap, challenge, exchange, refresh
        }
    }

    var namespace: String = ""
    var baseURL: String = ""
    var appVersion: String = "ext-1.0"
    var platform: String = "extension"
    var callbackURL: String = "mornye://session-grant"
    var schemeLabel: String = "SPOTIFLAC-HMAC-V1"
    var headerPrefix: String = "X-Sig-"
    var timeWindowSeconds: Int = 300
    var endpoints = Endpoints()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? "ext-1.0"
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "extension"
        callbackURL = try container.decodeIfPresent(String.self, forKey: .callbackURL) ?? "mornye://session-grant"
        schemeLabel = try container.decodeIfPresent(String.self, forKey: .schemeLabel) ?? "SPOTIFLAC-HMAC-V1"
        headerPrefix = try container.decodeIfPresent(String.self, forKey: .headerPrefix) ?? "X-Sig-"
        timeWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .timeWindowSeconds) ?? 300
        endpoints = try container.decodeIfPresent(Endpoints.self, forKey: .endpoints) ?? Endpoints()
        if timeWindowSeconds <= 0 { timeWindowSeconds = 300 }
    }

    enum CodingKeys: String, CodingKey {
        case namespace
        case baseURL = "baseUrl"
        case appVersion
        case platform
        case callbackURL = "callbackUrl"
        case schemeLabel
        case headerPrefix
        case timeWindowSeconds
        case endpoints
    }
}

// MARK: - Crypto

enum SignedSessionCrypto {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacBase64URL(key: Data, message: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        var value = Data(mac).base64EncodedString()
        value = value.replacingOccurrences(of: "+", with: "-")
        value = value.replacingOccurrences(of: "/", with: "_")
        while value.hasSuffix("=") { value.removeLast() }
        return value
    }

    static func randomHex(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    /// Mornye `signed_headers`와 같은 순서/형식으로 서명 헤더를 만든다.
    static func headers(
        config: SignedSessionConfig,
        sessionID: String,
        sessionSecret: String,
        method: String,
        url: URL,
        body: Data,
        date: Date,
        nonce: String
    ) -> [String: String] {
        let timestamp = self.timestamp(date)
        let bodyHash = sha256Hex(body)
        let window = Int(date.timeIntervalSince1970) / max(1, config.timeWindowSeconds)
        let rolling = hmacBase64URL(
            key: Data(sessionSecret.utf8),
            message: Data("\(window):\(sessionID)".utf8)
        )
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let path = encodedPath.isEmpty ? "/" : encodedPath
        let signing = [
            config.schemeLabel,
            method.uppercased(),
            path,
            "",
            bodyHash,
            timestamp,
            nonce,
            sessionID,
            config.appVersion,
            config.platform,
        ].joined(separator: "\n")
        let signature = hmacBase64URL(key: Data(rolling.utf8), message: Data(signing.utf8))
        let prefix = config.headerPrefix
        return [
            "\(prefix)Session": sessionID,
            "\(prefix)Timestamp": timestamp,
            "\(prefix)Nonce": nonce,
            "\(prefix)Body-SHA256": bodyHash,
            "\(prefix)Signature": signature,
            "\(prefix)App-Version": config.appVersion,
            "\(prefix)Platform": config.platform,
        ]
    }
}

extension Notification.Name {
    /// 서명 세션 인증이 끝났을 때. 확장 검색을 다시 실행하는 데 쓴다.
    static let signedSessionAuthenticated = Notification.Name("TuneSignedSessionAuthenticated")
}

// MARK: - Manager

/// Mornye 서명 세션 v2를 iOS에서 그대로 구현한다.
/// 확장의 JS 스레드에서 동기로 호출되므로 모든 공개 메서드는 직렬화한다.
final class SignedSessionManager: @unchecked Sendable {
    static let shared = SignedSessionManager()

    typealias Transport = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// 테스트에서 네트워크를 가로챌 때만 쓴다. 앱에서는 nil.
    var transport: Transport?
    /// 인증이 필요해질 때 UI에 알린다. (extensionID, 인증 URL)
    var onVerificationRequired: (@Sendable (String, String) -> Void)?

    private struct PendingChallenge {
        var state: String
        var authURL: String
        var createdAt: Date
    }

    private final class Client {
        let id: String
        var config: SignedSessionConfig
        let root: URL
        var record: Record
        var pending: PendingChallenge?
        var blockedGeneration = ""
        var completedGrantHash = ""

        init(id: String, config: SignedSessionConfig, root: URL) {
            self.id = id
            self.config = config
            self.root = root
            self.record = Record()
        }
    }

    private struct Record: Codable {
        var installID = ""
        var sessionID = ""
        var sessionSecret = ""
        var expiresAt = ""
        var namespace = ""
        var baseURL = ""
        var appVersion = ""
        var platform = ""

        enum CodingKeys: String, CodingKey {
            case installID = "install_id"
            case sessionID = "session_id"
            case sessionSecret = "session_secret"
            case expiresAt = "expires_at"
            case namespace
            case baseURL = "base_url"
            case appVersion = "app_version"
            case platform
        }

        var usable: Bool {
            guard !sessionID.trimmingCharacters(in: .whitespaces).isEmpty,
                  !sessionSecret.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            guard let expiry = SignedSessionCrypto.parseDate(expiresAt) else { return true }
            return Date() < expiry
        }

        var generation: String {
            guard !sessionID.isEmpty, !sessionSecret.isEmpty else { return "" }
            return SignedSessionCrypto.sha256Hex(Data("\(sessionID)\n\(sessionSecret)".utf8))
        }

        func sameSession(as other: Record) -> Bool {
            !sessionID.isEmpty && sessionID == other.sessionID && sessionSecret == other.sessionSecret
        }

        mutating func clearSession() {
            sessionID = ""
            sessionSecret = ""
            expiresAt = ""
        }
    }

    private struct ErrorContract {
        var error = ""
        var code = ""
        var origin = ""
        var action = ""
        var retryable = false
        var retryMode = ""
        var retryAfterSeconds = 0

        init(_ object: [String: Any]) {
            error = (object["error"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            code = (object["code"] as? String ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            origin = (object["origin"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            action = (object["action"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            retryable = (object["retryable"] as? Bool) ?? false
            retryMode = (object["retry_mode"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            retryAfterSeconds = max(0, (object["retry_after_seconds"] as? NSNumber)?.intValue ?? 0)
        }

        func gatewayAction(status: Int) -> String {
            switch (status, origin, code, action) {
            case (401, "gateway", "SESSION_INVALID", "bootstrap_session"): "bootstrap_session"
            case (428, "gateway", "VERIFY_REQUIRED", "verify"): "verify"
            default: ""
            }
        }

        func providerRetry(status: Int) -> Bool {
            status == 503 && origin == "provider" && code == "PROVIDER_UNAVAILABLE"
                && retryable && retryMode == "same_operation"
        }

        func requestAuthInvalid(status: Int) -> Bool {
            status == 403 && origin == "gateway" && code == "REQUEST_AUTH_INVALID" && action.isEmpty
        }
    }

    private struct HTTPResult {
        var status: Int
        var headers: [String: String]
        var body: Data
        var url: URL

        var json: [String: Any] {
            guard !body.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
                  let dictionary = object as? [String: Any] else { return [:] }
            return dictionary
        }

        func header(_ name: String) -> String {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
    }

    private enum SessionError: LocalizedError {
        case notConfigured
        case invalidBaseURL
        case invalidEndpoint(String)
        case network(String)
        case timeout
        case cancelled
        case http(Int, String)
        case invalidResponse(String)
        case missingSession
        case noChallenge

        var errorDescription: String? {
            switch self {
            case .notConfigured: "이 확장에는 서명 세션 설정이 없어요."
            case .invalidBaseURL: "서명 세션 주소가 올바르지 않아요."
            case .invalidEndpoint(let value): "서명 세션 주소를 만들지 못했어요: \(value)"
            case .network(let message): message
            case .timeout: "서명 세션 서버가 제때 응답하지 않았어요."
            case .cancelled: "취소했어요."
            case .http(let status, let message): message.isEmpty ? "서명 세션 서버가 HTTP \(status)를 돌려줬어요." : message
            case .invalidResponse(let message): message
            case .missingSession: "서명 세션을 받지 못했어요."
            case .noChallenge: "인증 주소를 만들지 못했어요."
            }
        }
    }

    private let lock = NSRecursiveLock()
    private var clients: [String: Client] = [:]
    private static let pendingStatesKey = "TuneSignedSessionPendingStates"

    private init() {}

    // MARK: - Public API (JS runtime)

    func signedFetch(
        extensionID: String,
        config: SignedSessionConfig,
        root: URL,
        method: String,
        path: String,
        body: String,
        headers: [String: String],
        isCancelled: () -> Bool
    ) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        do {
            let client = try client(id: extensionID, config: config, root: root)
            if let authURL = try ensureSession(client, isCancelled: isCancelled) {
                return verificationRequired(client: client, url: authURL)
            }

            let requestMethod = method.trimmingCharacters(in: .whitespaces).uppercased()
            var record = client.record
            var providerRetries = 0
            var sessionRetries = 0
            var authRetried = false

            while true {
                let response = try signedRequest(
                    client: client,
                    record: record,
                    method: requestMethod,
                    path: path,
                    body: body,
                    extras: headers,
                    isCancelled: isCancelled
                )
                let contract = ErrorContract(response.json)

                if contract.providerRetry(status: response.status) {
                    if providerRetries >= 2 { return responseValue(response) }
                    providerRetries += 1
                    try wait(providerDelay(response: response, contract: contract), isCancelled: isCancelled)
                    continue
                }

                if contract.requestAuthInvalid(status: response.status) {
                    let latest = client.record
                    if !authRetried && latest.usable && !latest.sameSession(as: record) {
                        authRetried = true
                        record = latest
                        continue
                    }
                    return responseValue(response)
                }

                let gatewayAction = contract.gatewayAction(status: response.status)
                switch gatewayAction {
                case "bootstrap_session":
                    let latest = client.record
                    if latest.usable && !latest.sameSession(as: record) {
                        if sessionRetries >= 1 { return responseValue(response) }
                        sessionRetries += 1
                        record = latest
                        continue
                    }
                    if latest.sameSession(as: record) {
                        client.record.clearSession()
                        client.blockedGeneration = ""
                        save(client)
                    }
                    let authURL = try bootstrap(client, isCancelled: isCancelled)
                    if !authURL.isEmpty { return verificationRequired(client: client, url: authURL) }
                    let bootstrapped = client.record
                    if bootstrapped.usable && !bootstrapped.sameSession(as: record) && sessionRetries < 1 {
                        sessionRetries += 1
                        record = bootstrapped
                        continue
                    }
                    return responseValue(response)

                case "verify":
                    let latest = client.record
                    if latest.usable && !latest.sameSession(as: record) {
                        if sessionRetries >= 1 { return responseValue(response) }
                        sessionRetries += 1
                        record = latest
                        continue
                    }
                    if latest.sameSession(as: record) {
                        client.blockedGeneration = record.generation
                    }
                    let authURL = try bootstrap(client, isCancelled: isCancelled)
                    if !authURL.isEmpty { return verificationRequired(client: client, url: authURL) }
                    let bootstrapped = client.record
                    if bootstrapped.usable && !bootstrapped.sameSession(as: record) && sessionRetries < 1 {
                        sessionRetries += 1
                        record = bootstrapped
                        continue
                    }
                    return responseValue(response)

                default:
                    return responseValue(response)
                }
            }
        } catch {
            return ["ok": false, "status": 0, "error": error.localizedDescription]
        }
    }

    func status(extensionID: String, config: SignedSessionConfig, root: URL) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let client = try? client(id: extensionID, config: config, root: root) else {
            return ["authenticated": false, "verification_required": false]
        }
        let blocked = !client.blockedGeneration.isEmpty
            && client.blockedGeneration == client.record.generation
        return [
            "authenticated": client.record.usable && !blocked,
            "verification_required": blocked,
            "expires_at": client.record.expiresAt,
            "install_id": client.record.installID,
            "session_id": client.record.sessionID,
            "app_version": config.appVersion,
            "platform": config.platform,
        ]
    }

    @discardableResult
    func clear(extensionID: String, config: SignedSessionConfig, root: URL) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let client = try? client(id: extensionID, config: config, root: root) else {
            return ["success": false, "error": "세션을 찾지 못했어요."]
        }
        client.record.clearSession()
        client.blockedGeneration = ""
        client.completedGrantHash = ""
        clearPendingState(client.pending?.state)
        client.pending = nil
        save(client)
        return ["success": true]
    }

    /// 확장 설정의 '인증하기'에서 호출한다. 이미 인증돼 있으면 빈 문자열.
    func verificationURL(
        extensionID: String,
        config: SignedSessionConfig,
        root: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let client = try client(id: extensionID, config: config, root: root)
        if client.record.usable && client.blockedGeneration != client.record.generation {
            return ""
        }
        return try bootstrap(client, isCancelled: isCancelled)
    }

    func completeGrant(
        extensionID: String,
        config: SignedSessionConfig,
        root: URL,
        grant: String
    ) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        do {
            let client = try client(id: extensionID, config: config, root: root)
            let trimmed = grant.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Mornye의 `session.completeGrant()`처럼 인자 없이 호출되면
                // 이미 받은 세션을 확인하거나, 없으면 인증 창을 띄운다.
                if client.record.usable && client.blockedGeneration != client.record.generation {
                    return ["success": true]
                }
                let authURL = try bootstrap(client, isCancelled: { false })
                if !authURL.isEmpty { return ["success": true, "pending": true, "auth_url": authURL] }
                guard client.record.usable else {
                    return ["success": false, "error": "서명 세션을 받지 못했어요."]
                }
                return ["success": true]
            }
            try exchange(client, grant: trimmed, isCancelled: { false })
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    /// 콜백 URL의 state로 확장을 찾고 grant를 교환한다.
    func completeGrantFromCallback(state: String, grant: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let extensionID = resolveExtensionID(state: state) else {
            return ["success": false, "error": "인증 요청을 찾지 못했어요. 확장에서 다시 인증해 주세요."]
        }
        guard let (config, root) = Self.configFromDisk(extensionID: extensionID) else {
            return ["success": false, "error": "확장 설정을 읽지 못했어요."]
        }
        do {
            let client = try client(id: extensionID, config: config, root: root)
            let trimmed = grant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ["success": false, "error": "인증 코드가 비어 있어요."] }
            try exchange(client, grant: trimmed, isCancelled: { false })
            clearPendingState(state.isEmpty ? client.pending?.state : state)
            postAuthenticated(extensionID)
            return ["success": true, "extension_id": extensionID]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    func resolveExtensionID(state: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let map = UserDefaults.standard.dictionary(forKey: Self.pendingStatesKey) as? [String: String] ?? [:]
        if !state.isEmpty, let id = map[state] { return id }
        if state.isEmpty {
            let matches = clients.values.filter { $0.pending != nil }
            if matches.count == 1 { return matches[0].id }
        }
        return nil
    }

    // MARK: - Client / store

    private func client(id: String, config: SignedSessionConfig, root: URL) throws -> Client {
        if let existing = clients[id], existing.config == config, existing.root == root {
            return existing
        }
        let value = Client(id: id, config: config, root: root)
        value.record = loadRecord(client: value)
        clients[id] = value
        return value
    }

    private func sessionDirectory(_ root: URL) -> URL {
        let directory = root.appendingPathComponent("signed_sessions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func sessionFile(client: Client) -> URL {
        let namespace = Self.namespace(client.config.namespace)
        let scope = [
            namespace,
            client.config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            client.config.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            client.config.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "\n")
        let digest = SignedSessionCrypto.sha256Hex(Data(scope.utf8))
        return sessionDirectory(client.root)
            .appendingPathComponent("\(namespace.isEmpty ? "session" : namespace)-\(digest.prefix(16)).json")
    }

    private static func namespace(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = lowered.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
        return filtered.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    }

    private func loadRecord(client: Client) -> Record {
        let file = sessionFile(client: client)
        var record = Record()
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(Record.self, from: data) {
            record = decoded
        }

        if record.installID.trimmingCharacters(in: .whitespaces).isEmpty {
            record.installID = SignedSessionCrypto.randomHex(16)
        }

        let namespace = Self.namespace(client.config.namespace)
        let baseURL = client.config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let appVersion = client.config.appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = client.config.platform.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        if record.namespace != namespace
            || record.baseURL != baseURL
            || record.appVersion != appVersion
            || record.platform != platform {
            if !record.namespace.isEmpty || !record.baseURL.isEmpty
                || !record.appVersion.isEmpty || !record.platform.isEmpty {
                record.clearSession()
            }
            record.namespace = namespace
            record.baseURL = baseURL
            record.appVersion = appVersion
            record.platform = platform
            changed = true
        }
        if !FileManager.default.fileExists(atPath: file.path) || changed {
            saveRecord(record, file: file)
        }
        return record
    }

    private func save(_ client: Client) {
        saveRecord(client.record, file: sessionFile(client: client))
    }

    private func saveRecord(_ record: Record, file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - Session lifecycle

    /// 세션이 없거나 만료됐으면 bootstrap한다. 인증이 필요하면 URL을 돌려준다.
    private func ensureSession(_ client: Client, isCancelled: () -> Bool) throws -> String? {
        if !client.record.usable {
            if !client.record.sessionID.isEmpty || !client.record.sessionSecret.isEmpty {
                client.record.clearSession()
                save(client)
            }
            return try bootstrap(client, isCancelled: isCancelled)
        }

        let blocked = !client.blockedGeneration.isEmpty
            && client.blockedGeneration == client.record.generation
        if blocked {
            let url = try bootstrap(client, isCancelled: isCancelled)
            if !url.isEmpty { return url }
            let latest = client.record
            if !latest.usable || client.blockedGeneration == latest.generation {
                throw SessionError.invalidResponse("인증이 필요해요.")
            }
        }

        if refreshDue(client.record, config: client.config) {
            try? refresh(client, isCancelled: isCancelled)
            let latest = client.record
            if !latest.usable || client.blockedGeneration == latest.generation {
                let url = try bootstrap(client, isCancelled: isCancelled)
                if !url.isEmpty { return url }
                if !client.record.usable { throw SessionError.missingSession }
            }
        }
        return nil
    }

    private func refreshDue(_ record: Record, config: SignedSessionConfig) -> Bool {
        guard !config.endpoints.refresh.isEmpty, record.usable,
              let expiry = SignedSessionCrypto.parseDate(record.expiresAt) else { return false }
        return expiry.timeIntervalSinceNow <= 3600
    }

    private enum BootstrapResult {
        case session
        case challenge(String)
    }

    private func bootstrap(_ client: Client, isCancelled: () -> Bool) throws -> String {
        if let pending = client.pending,
           !pending.authURL.isEmpty,
           Date().timeIntervalSince(pending.createdAt) < 180 {
            persistPendingState(extensionID: client.id, state: pending.state)
            notifyVerification(client: client, url: pending.authURL)
            return pending.authURL
        }
        if client.pending != nil {
            clearPendingState(client.pending?.state)
            client.pending = nil
        }

        let result = try performBootstrap(client, isCancelled: isCancelled)
        switch result {
        case .session:
            client.blockedGeneration = ""
            save(client)
            return ""
        case .challenge(let url):
            if let pending = client.pending {
                persistPendingState(extensionID: client.id, state: pending.state)
                notifyVerification(client: client, url: url)
            }
            return url
        }
    }

    private func performBootstrap(_ client: Client, isCancelled: () -> Bool) throws -> BootstrapResult {
        guard let url = endpoint(client.config, path: client.config.endpoints.bootstrap) else {
            throw SessionError.invalidEndpoint(client.config.endpoints.bootstrap)
        }
        let bootstrapURL = Self.withQuery(url, values: [
            ("app_version", client.config.appVersion),
            ("install_id", client.record.installID),
        ])
        let response = try send(
            method: "GET",
            url: bootstrapURL,
            body: Data(),
            headers: [:],
            timeout: 30,
            isCancelled: isCancelled
        )
        guard (200..<300).contains(response.status) else {
            var message = "서명 세션 서버가 HTTP \(response.status)를 돌려줬어요."
            let retry = retryAfter(response, contract: ErrorContract(response.json))
            if retry > 0 { message += " (\(retry)초 뒤 다시 시도해 주세요.)" }
            throw SessionError.http(response.status, message)
        }
        let json = response.json
        let sessionID = Self.string(json["session_id"])
        let secret = Self.string(json["session_secret"])
        let expires = Self.string(json["expires_at"])
        if !sessionID.isEmpty && !secret.isEmpty && !expires.isEmpty {
            client.record.sessionID = sessionID
            client.record.sessionSecret = secret
            client.record.expiresAt = expires
            client.record.namespace = Self.namespace(client.config.namespace)
            client.record.baseURL = client.config.baseURL
            client.record.appVersion = client.config.appVersion
            client.record.platform = client.config.platform
            client.completedGrantHash = ""
            save(client)
            return .session
        }

        var authURL = Self.string(json["auth_url"])
        if authURL.isEmpty { authURL = Self.string(json["challenge_url"]) }
        let challengeID = Self.string(json["challenge_id"])

        var state = SignedSessionCrypto.randomHex(16)
        if !authURL.isEmpty,
           let components = URLComponents(string: authURL),
           let serverState = components.queryItems?.first(where: { $0.name == "state" })?.value,
           !serverState.trimmingCharacters(in: .whitespaces).isEmpty {
            state = serverState
        }

        if authURL.isEmpty && !challengeID.isEmpty {
            authURL = try challengeURL(config: client.config, challengeID: challengeID, state: state)
        } else if !authURL.isEmpty {
            guard let parsed = URL(string: authURL) else { throw SessionError.invalidResponse("인증 주소가 올바르지 않아요.") }
            if !(parsed.query ?? "").contains("state=") {
                authURL = Self.withQuery(parsed, values: [("state", state)]).absoluteString
            }
        }

        guard !authURL.isEmpty else { throw SessionError.noChallenge }
        client.pending = PendingChallenge(state: state, authURL: authURL, createdAt: Date())
        persistPendingState(extensionID: client.id, state: state)
        return .challenge(authURL)
    }

    private func challengeURL(config: SignedSessionConfig, challengeID: String, state: String) throws -> String {
        let callbackBase = config.callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "mornye://session-grant"
            : config.callbackURL
        guard let callback = URL(string: callbackBase) else {
            throw SessionError.invalidResponse("콜백 주소가 올바르지 않아요.")
        }
        let callbackWithState = Self.withQuery(callback, values: [
            ("cb_version", "v2grant"),
            ("state", state),
        ])
        guard let base = endpoint(config, path: config.endpoints.challenge) else {
            throw SessionError.invalidEndpoint(config.endpoints.challenge)
        }
        return Self.withQuery(base, values: [
            ("id", challengeID),
            ("cb", callbackWithState.absoluteString),
        ]).absoluteString
    }

    private func exchange(_ client: Client, grant: String, isCancelled: () -> Bool) throws {
        let grantHash = SignedSessionCrypto.sha256Hex(Data(grant.utf8))
        if client.completedGrantHash == grantHash && client.record.usable { return }
        guard let url = endpoint(client.config, path: client.config.endpoints.exchange) else {
            throw SessionError.invalidEndpoint(client.config.endpoints.exchange)
        }
        let payload: [String: Any] = [
            "grant": grant,
            "install_id": client.record.installID,
            "app_version": client.config.appVersion,
            "platform": client.config.platform,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var attempt = 0
        while true {
            let response = try send(
                method: "POST",
                url: url,
                body: body,
                headers: ["Content-Type": "application/json"],
                timeout: 30,
                isCancelled: isCancelled
            )
            if response.status == 429 && attempt < 2 {
                attempt += 1
                let retry = max(1, min(retryAfter(response, contract: ErrorContract(response.json)), 300))
                try wait(Double(retry), isCancelled: isCancelled)
                continue
            }
            guard (200..<300).contains(response.status) else {
                throw SessionError.http(response.status, exchangeError(response))
            }
            let json = response.json
            let sessionID = Self.string(json["session_id"])
            let secret = Self.string(json["session_secret"])
            let expires = Self.string(json["expires_at"])
            guard !sessionID.isEmpty, !secret.isEmpty, !expires.isEmpty else {
                throw SessionError.invalidResponse("세션 교환 응답에 세션 정보가 없어요.")
            }
            client.record.sessionID = sessionID
            client.record.sessionSecret = secret
            client.record.expiresAt = expires
            client.record.namespace = Self.namespace(client.config.namespace)
            client.record.baseURL = client.config.baseURL
            client.record.appVersion = client.config.appVersion
            client.record.platform = client.config.platform
            client.completedGrantHash = grantHash
            client.blockedGeneration = ""
            clearPendingState(client.pending?.state)
            client.pending = nil
            save(client)
            return
        }
    }

    private func refresh(_ client: Client, isCancelled: () -> Bool) throws {
        guard !client.config.endpoints.refresh.isEmpty,
              let url = endpoint(client.config, path: client.config.endpoints.refresh) else { return }
        let body = try JSONSerialization.data(withJSONObject: ["install_id": client.record.installID])
        let response = try signedRequest(
            client: client,
            record: client.record,
            method: "POST",
            path: client.config.endpoints.refresh,
            body: String(decoding: body, as: UTF8.self),
            extras: [:],
            isCancelled: isCancelled
        )
        guard (200..<300).contains(response.status) else { return }
        let json = response.json
        let sessionID = Self.string(json["session_id"])
        let secret = Self.string(json["session_secret"])
        let expires = Self.string(json["expires_at"])
        var changed = false
        if !sessionID.isEmpty && sessionID != client.record.sessionID { client.record.sessionID = sessionID; changed = true }
        if !secret.isEmpty && secret != client.record.sessionSecret { client.record.sessionSecret = secret; changed = true }
        if !expires.isEmpty && expires != client.record.expiresAt { client.record.expiresAt = expires; changed = true }
        if changed {
            client.blockedGeneration = ""
            save(client)
        }
        _ = url
    }

    // MARK: - Signed request

    private func signedRequest(
        client: Client,
        record: Record,
        method: String,
        path: String,
        body: String,
        extras: [String: String],
        isCancelled: () -> Bool
    ) throws -> HTTPResult {
        guard let url = endpoint(client.config, path: path) else {
            throw SessionError.invalidEndpoint(path)
        }
        let bodyData = Data(body.utf8)
        let nonce = SignedSessionCrypto.randomHex(12)
        var headers = SignedSessionCrypto.headers(
            config: client.config,
            sessionID: record.sessionID,
            sessionSecret: record.sessionSecret,
            method: method,
            url: url,
            body: bodyData,
            date: Date(),
            nonce: nonce
        )
        for (key, value) in extras { headers[key] = value }
        return try send(
            method: method,
            url: url,
            body: bodyData,
            headers: headers,
            timeout: 60,
            isCancelled: isCancelled
        )
    }

    private func send(
        method: String,
        url: URL,
        body: Data,
        headers: [String: String],
        timeout: TimeInterval,
        isCancelled: () -> Bool
    ) throws -> HTTPResult {
        guard !isCancelled() else { throw SessionError.cancelled }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.uppercased()
        if !body.isEmpty {
            request.httpBody = body
            if headers.keys.first(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        if headers.keys.first(where: { $0.caseInsensitiveCompare("Accept") == .orderedSame }) == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if headers.keys.first(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) == nil {
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.8.4"
            request.setValue("Tune/\(version)", forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let transport { return try transportResult(transport, request: request, isCancelled: isCancelled) }

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var response: HTTPURLResponse?
        var error: Error?
        let task = URLSession.shared.dataTask(with: request) { value, urlResponse, failure in
            data = value
            response = urlResponse as? HTTPURLResponse
            error = failure
            semaphore.signal()
        }
        task.resume()
        let deadline = Date().addingTimeInterval(timeout)
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if isCancelled() {
                task.cancel()
                throw SessionError.cancelled
            }
            if Date() > deadline {
                task.cancel()
                throw SessionError.timeout
            }
        }
        if isCancelled() { throw SessionError.cancelled }
        if let error { throw SessionError.network(error.localizedDescription) }
        guard let response, let data else {
            throw SessionError.network("서명 세션 서버에서 응답이 없어요.")
        }
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            values[String(describing: key)] = String(describing: value)
        }
        return HTTPResult(status: response.statusCode, headers: values, body: data, url: response.url ?? url)
    }

    private func transportResult(
        _ transport: Transport,
        request: URLRequest,
        isCancelled: () -> Bool
    ) throws -> HTTPResult {
        guard !isCancelled() else { throw SessionError.cancelled }
        let (response, data) = try transport(request)
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            values[String(describing: key)] = String(describing: value)
        }
        return HTTPResult(status: response.statusCode, headers: values, body: data, url: response.url ?? request.url!)
    }

    private func responseValue(_ response: HTTPResult) -> [String: Any] {
        let contract = ErrorContract(response.json)
        var value: [String: Any] = [
            "statusCode": response.status,
            "status": response.status,
            "ok": (200..<300).contains(response.status),
            "url": response.url.absoluteString,
            "body": String(decoding: response.body, as: UTF8.self),
            "headers": response.headers,
        ]
        let retry = retryAfter(response, contract: contract)
        if retry > 0 { value["retryAfterSeconds"] = retry }
        if !contract.code.isEmpty || !contract.origin.isEmpty || !contract.action.isEmpty {
            value["error"] = contract.error
            value["code"] = contract.code
            value["origin"] = contract.origin
            value["action"] = contract.action
            value["retryable"] = contract.retryable
            value["retryMode"] = contract.retryMode
        }
        return value
    }

    private func verificationRequired(client: Client, url: String) -> [String: Any] {
        notifyVerification(client: client, url: url)
        return [
            "ok": false,
            "needsVerification": true,
            "error": "VERIFY_REQUIRED",
            "open_auth_url": url,
            "auth_url": url,
        ]
    }

    private func notifyVerification(client: Client, url: String) {
        persistPendingState(extensionID: client.id, state: client.pending?.state)
        onVerificationRequired?(client.id, url)
    }

    private func postAuthenticated(_ extensionID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .signedSessionAuthenticated, object: extensionID)
        }
    }

    @discardableResult
    private func wait(_ seconds: TimeInterval, isCancelled: () -> Bool) throws -> Bool {
        let end = Date().addingTimeInterval(max(0, seconds))
        while Date() < end {
            if isCancelled() { throw SessionError.cancelled }
            Thread.sleep(forTimeInterval: min(0.05, max(0, end.timeIntervalSinceNow)))
        }
        return true
    }

    // MARK: - Endpoint / response helpers

    private func endpoint(_ config: SignedSessionConfig, path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("https://") {
            guard let url = URL(string: trimmed), url.scheme == "https", url.host?.isEmpty == false else { return nil }
            return url
        }
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: base), parsed.scheme == "https", parsed.host?.isEmpty == false else {
            return nil
        }
        let baseString = base.hasSuffix("/") ? String(base.dropLast()) : base
        let suffix = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        guard let url = URL(string: baseString + "/" + suffix),
              url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func withQuery(_ url: URL, values: [(String, String)]) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        for (key, value) in values {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url ?? url
    }

    /// Mornye의 provider_delay와 같다. Retry-After(숫자/HTTP 날짜)를 우선 쓰고 최대 120초.
    private func providerDelay(response: HTTPResult, contract: ErrorContract) -> TimeInterval {
        let raw = response.header("Retry-After").trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty, let seconds = Double(raw), seconds > 0 {
            return min(seconds, 120)
        }
        if !raw.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) {
                let seconds = date.timeIntervalSinceNow
                if seconds > 0 { return min(seconds, 120) }
            }
        }
        return TimeInterval(max(1, min(contract.retryAfterSeconds, 120)))
    }

    private func retryAfter(_ response: HTTPResult, contract: ErrorContract) -> Int {
        let raw = response.header("Retry-After").trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty {
            if let seconds = Double(raw) { return max(0, Int(seconds.rounded())) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) {
                return max(0, Int(date.timeIntervalSinceNow.rounded()))
            }
        }
        return max(0, contract.retryAfterSeconds)
    }

    private func exchangeError(_ response: HTTPResult) -> String {
        let json = response.json
        let error = Self.string(json["error"])
        let code = Self.string(json["code"])
        var message = "세션 교환에 실패했어요 (HTTP \(response.status))."
        if !error.isEmpty { message = error }
        else if !code.isEmpty { message = "세션 교환에 실패했어요: \(code)" }
        return message
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: ""
        }
    }

    private func persistPendingState(extensionID: String, state: String?) {
        guard let state, !state.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: Self.pendingStatesKey) as? [String: String] ?? [:]
        map[state] = extensionID
        UserDefaults.standard.set(map, forKey: Self.pendingStatesKey)
    }

    private func clearPendingState(_ state: String?) {
        guard let state, !state.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: Self.pendingStatesKey) as? [String: String] ?? [:]
        map.removeValue(forKey: state)
        UserDefaults.standard.set(map, forKey: Self.pendingStatesKey)
    }

    private static func configFromDisk(extensionID: String) -> (SignedSessionConfig, URL)? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tune/Extensions/\(extensionID)", isDirectory: true)
        let manifest = root.appendingPathComponent("manifest.json")
        struct Envelope: Decodable { var signedSession: SignedSessionConfig? }
        guard let data = try? Data(contentsOf: manifest),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let config = envelope.signedSession else { return nil }
        return (config, root)
    }
}
