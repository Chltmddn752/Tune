import CryptoKit
import Security
import Foundation
import JavaScriptCore

/// Mornye JS 확장 하나를 JavaScriptCore에서 실행한다.
/// 확장은 자기 스레드(serial queue)에서만 돌고, 호스트 함수는 그 스레드에서 동기로 응답한다.
final class JSContextRuntime: @unchecked Sendable {
    enum RuntimeError: LocalizedError {
        case missingMethod(String)
        case notRegistered
        case script(String)
        case timeout(String)
        case cancelled
        case denied(String)
        case file(String)

        var errorDescription: String? {
            switch self {
            case .missingMethod(let name): "확장에 \(name) 함수가 없어요."
            case .notRegistered: "확장이 registerExtension()을 호출하지 않았어요."
            case .script(let message): message
            case .timeout(let message): message
            case .cancelled: "다운로드를 취소했어요."
            case .denied(let message), .file(let message): message
            }
        }
    }

    let extensionID: String
    let root: URL
    let stagingRoot: URL
    let manifest: ExtensionManifest
    let permissions: NetworkPermission
    let storage: ExtensionStorage

    private let queue: DispatchQueue
    private let context: JSContext
    private let session: URLSession
    private let redirectGuard: RedirectGuard
    private let logger: (String, String) -> Void
    private let progress: @Sendable (Double) -> Void

    private var timers: [Int: TimerEntry] = [:]
    private var nextTimerID = 1
    private var pumpingTimers = false
    private var lastException: String?
    private var callDeadline = Date.distantFuture

    private let stateLock = NSLock()
    private var cancelled = false
    private var currentTask: URLSessionTask?

    private final class TimerEntry {
        let fireAt: Date
        let callback: JSValue

        init(fireAt: Date, callback: JSValue) {
            self.fireAt = fireAt
            self.callback = callback
        }
    }

    private final class PromiseBox {
        var done = false
        var value: JSValue?
        var failure: String?
    }

    init(
        installed: InstalledExtension,
        root: URL,
        stagingRoot: URL,
        settings: [String: JSONValue],
        storage: ExtensionStorage,
        prelude: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        logger: @escaping (String, String) -> Void = { _, _ in }
    ) throws {
        self.extensionID = installed.id
        self.root = root
        self.stagingRoot = stagingRoot
        self.manifest = installed.manifest
        self.permissions = NetworkPermission(patterns: installed.manifest.permissions.hosts,
                                             allowHTTP: installed.manifest.permissions.allowHttp == true)
        self.storage = storage
        self.progress = progress
        self.logger = logger
        self.queue = DispatchQueue(label: "com.chltmddn752.tune.extension.\(installed.id)")
        self.context = JSContext()!
        self.redirectGuard = RedirectGuard(permissions: permissions)
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)

        context.name = installed.id
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "JavaScript 오류"
        }

        try queue.sync {
            installHost()
            try evaluate(prelude, name: "tune-prelude.js")
            guard let source = try? String(contentsOf: installedDirectory.appendingPathComponent("index.js"), encoding: .utf8) else {
                throw RuntimeError.script("확장의 index.js를 읽을 수 없어요.")
            }
            try evaluate(source, name: "\(installed.id)/index.js")
            let registered = context.objectForKeyedSubscript("extension")
            guard let registered, !registered.isUndefined, !registered.isNull else {
                throw RuntimeError.notRegistered
            }
            try initialize(settings: settings)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let task = currentTask
        stateLock.unlock()
        task?.cancel()
        queue.async { [weak self] in
            self?.pumpTimers()
        }
    }

    // MARK: - Calls

    func has(_ method: String) -> Bool {
        queue.sync { function(named: method) != nil }
    }

    func call(_ method: String, argumentsJSON: String = "[]", timeout: TimeInterval = 60) throws -> Any? {
        try queue.sync {
            lastException = nil
            callDeadline = Date().addingTimeInterval(timeout)
            guard let function = function(named: method) else { throw RuntimeError.missingMethod(method) }
            let args = try jsonArray(argumentsJSON)
            let value = function.call(withArguments: args)
            if let message = lastException {
                lastException = nil
                throw RuntimeError.script(message)
            }
            return try resolve(value, timeout: timeout)
        }
    }

    func callDownload(
        method: String,
        trackID: String,
        quality: String,
        outputPath: String,
        options: [String: Any],
        timeout: TimeInterval = 600
    ) throws -> Any? {
        try queue.sync {
            lastException = nil
            callDeadline = Date().addingTimeInterval(timeout)
            guard let function = function(named: method) else { throw RuntimeError.missingMethod(method) }

            let callback: @convention(block) (Double) -> Void = { [weak self] value in
                self?.progress(max(0, min(1, value)))
            }
            guard let callbackValue = JSValue(object: callback, in: context),
                  let optionsValue = jsonValue(options) else {
                throw RuntimeError.script("다운로드 인자를 만들 수 없어요.")
            }
            let args: [Any] = [trackID, quality, outputPath, callbackValue, optionsValue]
            let value = function.call(withArguments: args)
            if let message = lastException {
                lastException = nil
                throw RuntimeError.script(message)
            }
            return try resolve(value, timeout: timeout)
        }
    }

    private func initialize(settings: [String: JSONValue]) throws {
        guard let function = function(named: "initialize") else { return }
        guard let settingsValue = jsonValue(settings.mapValues(encodeJSONValue)) else { return }
        let value = function.call(withArguments: [settingsValue])
        if let message = lastException {
            lastException = nil
            throw RuntimeError.script(message)
        }
        if let value, isThenable(value) {
            _ = try awaitPromise(value, timeout: 60)
        }
    }

    private func function(named name: String) -> JSValue? {
        guard let extensionObject = context.objectForKeyedSubscript("extension"),
              !extensionObject.isUndefined else { return nil }
        let function = extensionObject.objectForKeyedSubscript(name)
        guard let function, !function.isUndefined, function.isObject else { return nil }
        return function
    }

    private func jsonArray(_ source: String) throws -> [Any] {
        guard let parse = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("parse"),
              let value = parse.call(withArguments: [source]),
              let array = value.toArray() else {
            return []
        }
        return array
    }

    private func jsonValue(_ value: Any) -> JSValue? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8),
              let parse = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("parse") else {
            return nil
        }
        return parse.call(withArguments: [text])
    }

    private func resolve(_ value: JSValue?, timeout: TimeInterval) throws -> Any? {
        guard let value else { return nil }
        if isThenable(value) {
            return try awaitPromise(value, timeout: timeout)
        }
        return try serialize(value)
    }

    private func isThenable(_ value: JSValue) -> Bool {
        guard value.isObject else { return false }
        let then = value.objectForKeyedSubscript("then")
        return then?.isUndefined == false
    }

    private func awaitPromise(_ promise: JSValue, timeout: TimeInterval) throws -> Any? {
        let box = PromiseBox()
        let onFulfilled: @convention(block) (JSValue?) -> Void = { value in
            box.value = value
            box.done = true
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { value in
            box.failure = value?.toString() ?? "확장에서 오류가 났어요."
            box.done = true
        }
        promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])

        let deadline = Date().addingTimeInterval(timeout)
        while !box.done {
            if isCancelled { throw RuntimeError.cancelled }
            if Date() > deadline {
                throw RuntimeError.timeout("확장 응답이 \(Int(timeout))초 안에 오지 않았어요.")
            }
            pumpTimers()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure = box.failure {
            throw RuntimeError.script(failure)
        }
        return try serialize(box.value)
    }

    private func serialize(_ value: JSValue?) throws -> Any? {
        guard let value, !value.isUndefined else { return nil }
        guard let stringify = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("stringify") else {
            return nil
        }
        let encoded = stringify.call(withArguments: [value])
        if let message = lastException {
            lastException = nil
            throw RuntimeError.script(message)
        }
        guard let encoded, !encoded.isUndefined, let text = encoded.toString() else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func evaluate(_ source: String, name: String) throws {
        lastException = nil
        context.evaluateScript(source, withSourceURL: URL(string: "tune://extension/\(name)"))
        if let message = lastException {
            lastException = nil
            throw RuntimeError.script(message)
        }
    }

    // MARK: - Timers

    private func pumpTimers() {
        guard !pumpingTimers else { return }
        pumpingTimers = true
        defer { pumpingTimers = false }
        while true {
            let now = Date()
            let due = timers.filter { $0.value.fireAt <= now }.sorted { $0.value.fireAt < $1.value.fireAt }
            guard !due.isEmpty else { break }
            for (identifier, entry) in due {
                timers.removeValue(forKey: identifier)
                lastException = nil
                entry.callback.call(withArguments: [])
                if let message = lastException {
                    lastException = nil
                    logger("ERROR", "타이머 오류: \(message)")
                }
                if Date() > callDeadline { break }
            }
        }
    }

    // MARK: - Host bridge

    private func installHost() {
        let request: @convention(block) (String, String, String, String?, Double) -> String = { [weak self] method, url, headers, body, timeout in
            guard let self else { return #"{"error":"runtime closed"}"# }
            return self.handleRequest(method: method, url: url, headersJSON: headers, body: body, timeout: timeout)
        }

        let file: @convention(block) (String, String) -> String = { [weak self] method, args in
            guard let self else { return #"{"success":false,"error":"runtime closed"}"# }
            return self.handleFile(method: method, argsJSON: args)
        }

        let download: @convention(block) (String, String, String, JSValue?) -> String = { [weak self] url, path, headers, callback in
            guard let self else { return #"{"success":false,"error":"runtime closed"}"# }
            return self.handleDownload(url: url, path: path, headersJSON: headers, callback: callback)
        }

        let downloadSegments: @convention(block) (String, String, String, JSValue?) -> String = { [weak self] segments, path, options, callback in
            guard let self else { return #"{"success":false,"error":"runtime closed"}"# }
            return self.handleDownloadSegments(segmentsJSON: segments, path: path, optionsJSON: options, callback: callback)
        }

        let storageBlock: @convention(block) (String, String, String?, Bool) -> String = { [weak self] method, key, value, secret in
            guard let self else { return #"{"success":false,"error":"runtime closed"}"# }
            return self.handleStorage(method: method, key: key, valueJSON: value, secret: secret)
        }

        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.logger(level, message)
        }

        let timerSet: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, milliseconds in
            guard let self else { return 0 }
            let identifier = self.nextTimerID
            self.nextTimerID += 1
            self.timers[identifier] = TimerEntry(
                fireAt: Date().addingTimeInterval(max(0, milliseconds) / 1000),
                callback: callback
            )
            return identifier
        }

        let timerClear: @convention(block) (Int) -> Void = { [weak self] identifier in
            self?.timers.removeValue(forKey: identifier)
        }

        let cancelled: @convention(block) () -> Bool = { [weak self] in
            self?.isCancelled ?? true
        }

        let sleep: @convention(block) (Double) -> Bool = { [weak self] milliseconds in
            guard let self, !self.isCancelled else { return false }
            let interval = min(max(0, milliseconds) / 1000, 300)
            let end = Date().addingTimeInterval(interval)
            while Date() < end {
                if self.isCancelled { return false }
                self.pumpTimers()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(min(0.02, end.timeIntervalSinceNow)))
            }
            return true
        }

        let info: @convention(block) () -> String = { [weak self] in
            self?.appInfoJSON() ?? "{}"
        }

        let compareStrings: @convention(block) (String, String) -> Double = { first, second in
            TextMatch.similarity(first, second)
        }

        let compareDuration: @convention(block) (Double, Double, Double) -> Bool = { first, second, tolerance in
            TextMatch.durationMatches(Int(first), Int(second), tolerance: Int(tolerance))
        }

        let normalize: @convention(block) (String) -> String = { value in
            TextMatch.normalize(value)
        }

        let hash: @convention(block) (String, String, String, Bool) -> String = { algorithm, data, key, base64 in
            Self.hash(algorithm: algorithm, data: data, key: key, base64: base64)
        }

        let crypt: @convention(block) (String, String, String) -> String = { operation, data, key in
            Self.crypt(operation: operation, data: data, key: key)
        }

        let generateKey: @convention(block) (Int) -> String = { length in
            Self.generateKey(length: length)
        }

        let blockTransform: @convention(block) (String, String) -> String = { _, _ in
            #"{"success":false,"error":"block cipher helpers are not supported by Tune"}"#
        }

        let ffmpeg: @convention(block) (String, String) -> String = { operation, _ in
            #"{"success":false,"error":"ffmpeg.\\#(operation) is not supported by Tune"}"#
        }

        let utf8Encode: @convention(block) (String) -> [Int] = { value in
            value.utf8.map(Int.init)
        }

        let utf8Decode: @convention(block) ([Int]) -> String = { values in
            String(decoding: values.map { UInt8(clamping: $0) }, as: UTF8.self)
        }

        let base64Encode: @convention(block) (String) -> String = { value in
            Data(value.utf8).base64EncodedString()
        }

        let base64Decode: @convention(block) (String) -> String = { value in
            guard let data = Data(base64Encoded: value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        context.setObject(request, forKeyedSubscript: "__host_request" as NSString)
        context.setObject(file, forKeyedSubscript: "__host_file" as NSString)
        context.setObject(download, forKeyedSubscript: "__host_download" as NSString)
        context.setObject(downloadSegments, forKeyedSubscript: "__host_download_segments" as NSString)
        context.setObject(storageBlock, forKeyedSubscript: "__host_storage" as NSString)
        context.setObject(logBlock, forKeyedSubscript: "__host_log" as NSString)
        context.setObject(timerSet, forKeyedSubscript: "__host_timer_set" as NSString)
        context.setObject(timerClear, forKeyedSubscript: "__host_timer_clear" as NSString)
        context.setObject(cancelled, forKeyedSubscript: "__host_cancelled" as NSString)
        context.setObject(sleep, forKeyedSubscript: "__host_sleep" as NSString)
        context.setObject(info, forKeyedSubscript: "__host_info" as NSString)
        context.setObject(compareStrings, forKeyedSubscript: "__host_compare_strings" as NSString)
        context.setObject(compareDuration, forKeyedSubscript: "__host_compare_duration" as NSString)
        context.setObject(normalize, forKeyedSubscript: "__host_normalize" as NSString)
        context.setObject(hash, forKeyedSubscript: "__host_hash" as NSString)
        context.setObject(crypt, forKeyedSubscript: "__host_crypt" as NSString)
        context.setObject(generateKey, forKeyedSubscript: "__host_generate_key" as NSString)
        context.setObject(blockTransform, forKeyedSubscript: "__host_block_transform" as NSString)
        context.setObject(ffmpeg, forKeyedSubscript: "__host_ffmpeg" as NSString)
        context.setObject(utf8Encode, forKeyedSubscript: "__host_utf8_encode" as NSString)
        context.setObject(utf8Decode, forKeyedSubscript: "__host_utf8_decode" as NSString)
        context.setObject(base64Encode, forKeyedSubscript: "__host_base64_encode" as NSString)
        context.setObject(base64Decode, forKeyedSubscript: "__host_base64_decode" as NSString)
    }

    private var installedDirectory: URL {
        root
    }

    // MARK: - App info

    private func appInfoJSON() -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.8.4"
        let info: [String: Any] = [
            "appVersion": "Tune \(version)",
            "appUserAgent": "Tune/\(version) (iOS)",
            "randomUserAgent": Self.userAgents.randomElement() ?? Self.userAgents[0],
            "resolutionRemainingMs": max(0, Int(callDeadline.timeIntervalSinceNow * 1000)),
        ]
        return Self.jsonString(info)
    }

    private static let userAgents = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    ]

    // MARK: - HTTP

    private func handleRequest(method: String, url: String, headersJSON: String, body: String?, timeout: Double) -> String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Self.jsonString(["error": "invalid URL", "status": 0])
        }
        guard permissions.allows(parsed) else {
            logger("ERROR", "HTTP denied: \(parsed.absoluteString) host=\(parsed.host ?? "nil")")
            return Self.jsonString(["error": "network access denied for \(parsed.host ?? "host")", "status": 0])
        }
        guard !isCancelled else {
            return Self.jsonString(["error": "cancelled", "status": 0])
        }

        var request = URLRequest(url: parsed, timeoutInterval: min(max(1, timeout), 120))
        request.httpMethod = method.isEmpty ? "GET" : method.uppercased()
        if let body, !body.isEmpty, method.uppercased() != "GET" && method.uppercased() != "HEAD" {
            request.httpBody = body.data(using: .utf8)
        }
        let headers = Self.parseHeaders(headersJSON)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        logger("DEBUG", "HTTP start \(request.httpMethod ?? "GET") \(parsed.absoluteString) body=\(request.httpBody?.count ?? 0) headers=\(headers.keys.sorted())")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: HTTPURLResponse?
        var responseError: Error?

        let task = session.dataTask(with: request) { data, urlResponse, error in
            responseData = data
            response = urlResponse as? HTTPURLResponse
            responseError = error
            semaphore.signal()
        }
        task.resume()

        while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
            if isCancelled {
                task.cancel()
                break
            }
            pumpTimers()
        }

        if isCancelled {
            return Self.jsonString(["error": "cancelled", "status": 0])
        }
        if let responseError {
            logger("ERROR", "HTTP error: \(responseError.localizedDescription)")
            return Self.jsonString(["error": responseError.localizedDescription, "status": 0])
        }
        guard let response else {
            return Self.jsonString(["error": "no response", "status": 0])
        }

        let data = responseData ?? Data()
        var payload: [String: Any] = [
            "status": response.statusCode,
            "statusCode": response.statusCode,
            "url": response.url?.absoluteString ?? url,
            "headers": response.allHeaderFields.reduce(into: [String: String]()) { result, item in
                if let key = item.key as? String { result[key] = String(describing: item.value) }
            },
        ]
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            payload["body"] = text
        } else {
            payload["body"] = ""
            payload["base64"] = data.base64EncodedString()
        }
        logger("DEBUG", "HTTP \(request.httpMethod ?? "GET") \(parsed.absoluteString) -> \(response.statusCode) \(data.count) bytes")
        if parsed.host?.contains("youtube.com") == true {
            logger("DEBUG", "HTTP body: \(String(decoding: data.prefix(800), as: UTF8.self))")
        }
        return Self.jsonString(payload)
    }

    // MARK: - Downloads

    private func handleDownload(url: String, path: String, headersJSON: String, callback: JSValue?) -> String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Self.jsonString(["success": false, "error": "invalid download URL", "error_type": "invalid_request"])
        }
        guard permissions.allows(parsed) else {
            return Self.jsonString(["success": false, "error": "network access denied for \(parsed.host ?? "host")", "error_type": "permission"])
        }
        guard let destination = resolvePath(path), isAllowed(destination) else {
            return Self.jsonString(["success": false, "error": "output path is outside the extension sandbox", "error_type": "permission"])
        }
        guard !isCancelled else {
            return Self.jsonString(["success": false, "error": "cancelled", "error_type": "cancelled"])
        }

        var request = URLRequest(url: parsed, timeoutInterval: 600)
        request.httpMethod = "GET"
        for (key, value) in Self.parseHeaders(headersJSON) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var temporary: URL?
        var response: HTTPURLResponse?
        var responseError: Error?

        let task = session.downloadTask(with: request) { location, urlResponse, error in
            temporary = location
            response = urlResponse as? HTTPURLResponse
            responseError = error
            semaphore.signal()
        }
        setCurrentTask(task)
        task.resume()

        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled {
                task.cancel()
                continue
            }
            let total = task.progress.totalUnitCount
            let completed = task.progress.completedUnitCount
            if let callback, total > 0 {
                callback.call(withArguments: [Double(completed), Double(total)])
            }
            pumpTimers()
        }
        setCurrentTask(nil)

        if isCancelled {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            return Self.jsonString(["success": false, "error": "cancelled", "error_type": "cancelled"])
        }
        if let responseError {
            return Self.jsonString(["success": false, "error": responseError.localizedDescription, "error_type": "network"])
        }
        guard let temporary else {
            return Self.jsonString(["success": false, "error": "no download response", "error_type": "network"])
        }
        if let response, !(200..<300).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            return Self.jsonString([
                "success": false,
                "error": "HTTP \(response.statusCode)",
                "error_type": response.statusCode == 429 ? "rate_limit" : "http_error",
                "http_status": response.statusCode,
            ])
        }

        do {
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            if let callback {
                callback.call(withArguments: [Double(size), Double(size)])
            }
            return Self.jsonString([
                "success": true,
                "path": destination.path,
                "size": size,
                "http_status": response?.statusCode ?? 200,
            ])
        } catch {
            return Self.jsonString(["success": false, "error": error.localizedDescription, "error_type": "storage_error"])
        }
    }

    private func handleDownloadSegments(segmentsJSON: String, path: String, optionsJSON: String, callback: JSValue?) -> String {
        guard let destination = resolvePath(path), isAllowed(destination) else {
            return Self.jsonString(["success": false, "error": "output path is outside the extension sandbox", "error_type": "permission"])
        }
        guard let data = segmentsJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !raw.isEmpty else {
            return Self.jsonString(["success": false, "error": "segments must be a non-empty array", "error_type": "invalid_request"])
        }
        let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
        let commonHeaders = Self.parseHeaders(Self.jsonString(options["headers"] ?? [:]))

        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            return Self.jsonString(["success": false, "error": "failed to create output file", "error_type": "storage_error"])
        }
        defer { try? handle.close() }

        var written: Int64 = 0
        for (index, segment) in raw.enumerated() {
            if isCancelled {
                return Self.jsonString(["success": false, "error": "cancelled", "error_type": "cancelled"])
            }
            guard let urlString = segment["url"] as? String,
                  let parsed = URL(string: urlString),
                  permissions.allows(parsed) else {
                return Self.jsonString(["success": false, "error": "segment \(index) is not allowed", "error_type": "permission"])
            }
            var request = URLRequest(url: parsed, timeoutInterval: 300)
            request.httpMethod = "GET"
            for (key, value) in commonHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            var segmentHeaders: [String: String] = [:]
            if let values = segment["headers"] as? [String: Any] {
                for (key, value) in values { segmentHeaders[key] = String(describing: value) }
            }
            for (key, value) in segmentHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let semaphore = DispatchSemaphore(value: 0)
            var responseData: Data?
            var responseError: Error?
            let task = session.dataTask(with: request) { data, _, error in
                responseData = data
                responseError = error
                semaphore.signal()
            }
            task.resume()
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                if isCancelled {
                    task.cancel()
                    break
                }
                pumpTimers()
            }
            if isCancelled {
                return Self.jsonString(["success": false, "error": "cancelled", "error_type": "cancelled"])
            }
            if let responseError {
                return Self.jsonString(["success": false, "error": responseError.localizedDescription, "error_type": "network"])
            }
            guard let responseData else {
                return Self.jsonString(["success": false, "error": "segment \(index) returned no data", "error_type": "network"])
            }
            do {
                try handle.write(contentsOf: responseData)
            } catch {
                return Self.jsonString(["success": false, "error": error.localizedDescription, "error_type": "storage_error"])
            }
            written += Int64(responseData.count)
            if let callback {
                callback.call(withArguments: [Double(written), Double(0), Double(index + 1), Double(raw.count)])
            }
        }
        return Self.jsonString(["success": true, "path": destination.path, "size": written])
    }

    private func setCurrentTask(_ task: URLSessionTask?) {
        stateLock.lock()
        currentTask = task
        stateLock.unlock()
    }

    // MARK: - Files

    private func handleFile(method: String, argsJSON: String) -> String {
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.jsonString(["success": false, "error": "invalid file arguments"])
        }
        let path = args["path"] as? String ?? ""
        let value = args["value"] as? String
        guard let url = resolvePath(path), isAllowed(url) else {
            return Self.jsonString(["success": false, "error": "path is outside the extension sandbox", "error_type": "permission"])
        }

        do {
            switch method {
            case "exists":
                return Self.jsonString(["success": true, "exists": FileManager.default.fileExists(atPath: url.path)])
            case "delete":
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return Self.jsonString(["success": true])
            case "read":
                let data = try Data(contentsOf: url)
                return Self.jsonString(["success": true, "data": String(decoding: data, as: UTF8.self)])
            case "readBytes":
                let data = try Data(contentsOf: url)
                return Self.jsonString(["success": true, "data": data.base64EncodedString()])
            case "write":
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((value ?? "").utf8).write(to: url, options: .atomic)
                return Self.jsonString(["success": true, "path": url.path])
            case "writeBytes":
                guard let data = Data(base64Encoded: value ?? "") else {
                    return Self.jsonString(["success": false, "error": "invalid base64"])
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return Self.jsonString(["success": true, "path": url.path])
            case "getSize":
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                return Self.jsonString(["success": true, "size": size])
            case "copy", "move":
                guard let destinationString = value, let destination = resolvePath(destinationString), isAllowed(destination) else {
                    return Self.jsonString(["success": false, "error": "destination is outside the extension sandbox"])
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if method == "copy" {
                    try FileManager.default.copyItem(at: url, to: destination)
                } else {
                    try FileManager.default.moveItem(at: url, to: destination)
                }
                return Self.jsonString(["success": true, "path": destination.path])
            default:
                return Self.jsonString(["success": false, "error": "unsupported file operation: \(method)"])
            }
        } catch {
            return Self.jsonString(["success": false, "error": error.localizedDescription, "error_type": "storage_error"])
        }
    }

    private func resolvePath(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            url = root.appendingPathComponent("files").appendingPathComponent(trimmed)
        }
        return url.standardizedFileURL
    }

    private func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let allowedRoots = [root.standardizedFileURL.path, stagingRoot.standardizedFileURL.path]
        return allowedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Storage

    private func handleStorage(method: String, key: String, valueJSON: String?, secret: Bool) -> String {
        switch method {
        case "get":
            if let value = storage.get(key: key, secret: secret) {
                return Self.jsonString(["found": true, "value": encodeJSONValue(value)])
            }
            return Self.jsonString(["found": false])
        case "set":
            storage.set(key: key, json: valueJSON ?? "null", secret: secret)
            return Self.jsonString(["success": true])
        case "remove":
            storage.remove(key: key, secret: secret)
            return Self.jsonString(["success": true])
        case "has":
            return Self.jsonString(["found": storage.get(key: key, secret: secret) != nil])
        default:
            return Self.jsonString(["success": false, "error": "unsupported storage operation"])
        }
    }

    // MARK: - Hashing / crypto

    private static func hash(algorithm: String, data: String, key: String, base64: Bool) -> String {
        let payload = Data(data.utf8)
        let keyData = Data(key.utf8)
        switch algorithm.lowercased() {
        case "md5":
            return digest(Insecure.MD5.hash(data: payload), base64: base64)
        case "sha1":
            return digest(Insecure.SHA1.hash(data: payload), base64: base64)
        case "sha256":
            return digest(SHA256.hash(data: payload), base64: base64)
        case "hmac-sha1":
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: payload, using: SymmetricKey(data: keyData))
            return encode(Data(mac), base64: base64)
        case "hmac-sha256":
            let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: keyData))
            return encode(Data(mac), base64: base64)
        default:
            return ""
        }
    }

    private static func digest<D: Digest>(_ digest: D, base64: Bool) -> String {
        encode(Data(digest), base64: base64)
    }

    private static func encode(_ data: Data, base64: Bool) -> String {
        if base64 { return data.base64EncodedString() }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func crypt(operation: String, data: String, key: String) -> String {
        let keyData = Data(SHA256.hash(data: Data(key.utf8)))
        let symmetricKey = SymmetricKey(data: keyData)
        switch operation.lowercased() {
        case "encrypt":
            guard let sealed = try? AES.GCM.seal(Data(data.utf8), using: symmetricKey),
                  let combined = sealed.combined else {
                return #"{"success":false,"error":"encryption failed"}"#
            }
            return jsonString(["success": true, "data": combined.base64EncodedString()])
        case "decrypt":
            guard let combined = Data(base64Encoded: data),
                  let box = try? AES.GCM.SealedBox(combined: combined),
                  let plain = try? AES.GCM.open(box, using: symmetricKey) else {
                return #"{"success":false,"error":"decryption failed"}"#
            }
            return jsonString(["success": true, "data": String(decoding: plain, as: UTF8.self)])
        default:
            return #"{"success":false,"error":"unsupported crypto operation"}"#
        }
    }

    private static func generateKey(length: Int) -> String {
        let size = min(max(length, 1), 4096)
        var bytes = [UInt8](repeating: 0, count: size)
        _ = SecRandomCopyBytes(kSecRandomDefault, size, &bytes)
        let data = Data(bytes)
        return jsonString(["success": true, "key": data.base64EncodedString(), "hex": encode(data, base64: false)])
    }

    // MARK: - Helpers

    private func encodeJSONValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(encodeJSONValue)
        case .array(let value): value.map(encodeJSONValue)
        case .null: NSNull()
        }
    }

    private static func parseHeaders(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.reduce(into: [String: String]()) { result, item in
            result[item.key] = String(describing: item.value)
        }
    }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// 확장 매니페스트의 network 권한만 통과시킨다.
struct NetworkPermission: Sendable {
    let patterns: [String]
    let allowHTTP: Bool

    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if scheme == "http" && !allowHTTP { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return patterns.contains { pattern in
            let value = pattern
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                .split(separator: "/").first.map(String.init) ?? ""
            if value.isEmpty { return false }
            if value == host { return true }
            if value.hasPrefix("*.") {
                let suffix = String(value.dropFirst())
                return host.hasSuffix(suffix) && host.count > suffix.count
            }
            return false
        }
    }
}

/// 리다이렉트도 같은 네트워크 권한으로 검사한다.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let permissions: NetworkPermission

    init(permissions: NetworkPermission) {
        self.permissions = permissions
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, permissions.allows(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

/// 확장별 저장소. 일반 값과 비밀 값을 따로 둔다.
final class ExtensionStorage: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var regular: [String: String] = [:]
    private var secret: [String: String] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        regular = Self.load(directory.appendingPathComponent("storage.json"))
        secret = Self.load(directory.appendingPathComponent("credentials.json"))
    }

    func get(key: String, secret isSecret: Bool) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        let raw = isSecret ? secret[key] : regular[key]
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func set(key: String, json: String, secret isSecret: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isSecret { secret[key] = json } else { regular[key] = json }
        save(isSecret ? secret : regular, name: isSecret ? "credentials.json" : "storage.json")
    }

    func remove(key: String, secret isSecret: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isSecret { secret.removeValue(forKey: key) } else { regular.removeValue(forKey: key) }
        save(isSecret ? secret : regular, name: isSecret ? "credentials.json" : "storage.json")
    }

    private func save(_ values: [String: String], name: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }
}
