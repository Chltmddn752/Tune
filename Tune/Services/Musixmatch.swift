import Foundation

/// Musixmatch 데스크톱 앱이 쓰는 내부 API(apic-desktop.musixmatch.com)로 가사를 받는다.
/// Spotify·Apple Music에 가사를 대는 곳이라 곡이 가장 많고, 단어 단위 싱크(richsync)도 있다.
///
/// 공식 API가 아니라서 토큰이 막히거나(캡차) 방식이 바뀔 수 있다. 그때는 nil을 돌려주고
/// 호출한 쪽이 LRCLIB로 넘어간다. 캡차에 걸리면 잠시 쉬었다가 다시 시도한다.
enum Musixmatch {
    struct Result {
        /// "lrc"(시간 맞춘 가사) 또는 "plain"
        var raw: String
        var format: String
        var wordSynced: Bool
    }

    enum Outcome {
        case found(Result)
        case notFound
        /// 토큰이 막혔거나 서버가 응답하지 않음 — 잠시 뒤 다시 시도할 수 있다.
        case unavailable(String)
    }

    private static let base = "https://apic-desktop.musixmatch.com/ws/1.1/"
    private static let appID = "web-desktop-app-v1.0"
    private static let tokenKey = "musixmatch.token"
    private static let tokenDateKey = "musixmatch.tokenDate"
    private static let blockedUntilKey = "musixmatch.blockedUntil"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// 길이가 맞는 가사만 받는다(MV·라이브 등 다른 버전 가사가 붙지 않게).
    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Outcome {
        if let until = UserDefaults.standard.object(forKey: blockedUntilKey) as? Date, until > .now {
            return .unavailable("Musixmatch가 잠시 막혀 있어요. 조금 뒤에 다시 시도해요.")
        }
        for attempt in 0..<2 {
            guard let token = await token(refresh: attempt > 0) else {
                return .unavailable("Musixmatch에 연결하지 못했어요.")
            }
            switch await macroSubtitles(token: token, title: title, artist: artist, album: album, duration: duration) {
            case .tokenRejected:
                clearToken()
                continue
            case .outcome(let outcome):
                return outcome
            }
        }
        return .unavailable("Musixmatch 토큰을 받지 못했어요.")
    }

    // MARK: - 토큰

    private static func token(refresh: Bool) async -> String? {
        let defaults = UserDefaults.standard
        if !refresh, let saved = defaults.string(forKey: tokenKey),
           let date = defaults.object(forKey: tokenDateKey) as? Date, date.timeIntervalSinceNow > -6 * 3600 {
            return saved
        }
        guard let json = await get("token.get", [("user_language", "en")]),
              let message = json["message"] as? [String: Any] else { return nil }
        let status = (message["header"] as? [String: Any])?["status_code"] as? Int
        let hint = (message["header"] as? [String: Any])?["hint"] as? String
        if status == 401 || hint == "captcha" {
            // 너무 자주 요청해서 캡차에 걸렸다. 10분 쉬었다가 다시.
            defaults.set(Date().addingTimeInterval(600), forKey: blockedUntilKey)
            return nil
        }
        guard status == 200,
              let token = (message["body"] as? [String: Any])?["user_token"] as? String,
              !token.isEmpty, !token.contains("UpgradeOnly") else { return nil }
        defaults.set(token, forKey: tokenKey)
        defaults.set(Date(), forKey: tokenDateKey)
        return token
    }

    private static func clearToken() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: tokenDateKey)
    }

    // MARK: - 가사

    private enum MacroResult {
        case tokenRejected
        case outcome(Outcome)
    }

    private static func macroSubtitles(token: String, title: String, artist: String, album: String,
                                       duration: Double) async -> MacroResult {
        var query: [(String, String)] = [
            ("format", "json"),
            ("namespace", "lyrics_richsynched"),
            ("subtitle_format", "mxm"),
            ("optional_calls", "track.richsync"),
            ("q_track", title),
            ("q_artist", artist),
            ("q_artists", artist),
            ("q_album", album),
            ("usertoken", token),
        ]
        let seconds = Int(duration.rounded())
        if seconds > 0 {
            query += [
                ("q_duration", String(seconds)),
                ("f_subtitle_length", String(seconds)),
                ("f_subtitle_length_max_deviation", "3"),
            ]
        }
        guard let json = await get("macro.subtitles.get", query) else {
            return .outcome(.unavailable("Musixmatch가 응답하지 않아요."))
        }
        let calls = dig(json, "message", "body", "macro_calls") as? [String: Any] ?? [:]
        let headerStatus = dig(json, "message", "header", "status_code") as? Int
        let matcherStatus = dig(calls["matcher.track.get"], "message", "header", "status_code") as? Int
        if headerStatus == 401 || matcherStatus == 401 {
            if (dig(json, "message", "header", "hint") as? String) == "captcha" {
                UserDefaults.standard.set(Date().addingTimeInterval(600), forKey: blockedUntilKey)
                return .outcome(.unavailable("Musixmatch가 잠시 막혔어요. 조금 뒤에 다시 시도해요."))
            }
            return .tokenRejected
        }
        guard matcherStatus == 200,
              let track = dig(calls["matcher.track.get"], "message", "body", "track") as? [String: Any] else {
            return .outcome(.notFound)
        }
        if (track["instrumental"] as? Int) == 1 { return .outcome(.notFound) }

        // 찾은 곡 길이가 많이 다르면 다른 버전이다 → 시간이 어긋나므로 쓰지 않는다.
        let trackLength = Double(track["track_length"] as? Int ?? 0)
        let lengthMatches = duration <= 0 || trackLength <= 0 || abs(trackLength - duration) <= 4

        if lengthMatches {
            // 1) 단어 싱크
            var richBody = dig(calls["track.richsync.get"], "message", "body", "richsync", "richsync_body") as? String
            if richBody == nil, (track["has_richsync"] as? Int) == 1, let id = track["track_id"] as? Int {
                let rich = await get("track.richsync.get", [("track_id", String(id)), ("usertoken", token)])
                richBody = dig(rich, "message", "body", "richsync", "richsync_body") as? String
            }
            if let richBody, let lrc = enhancedLRC(fromRichsync: richBody) {
                return .outcome(.found(Result(raw: lrc, format: "lrc", wordSynced: true)))
            }
            // 2) 줄 싱크
            if let list = dig(calls["track.subtitles.get"], "message", "body", "subtitle_list") as? [[String: Any]],
               let body = dig(list.first, "subtitle", "subtitle_body") as? String,
               let lrc = lrc(fromSubtitle: body) {
                return .outcome(.found(Result(raw: lrc, format: "lrc", wordSynced: false)))
            }
        }
        // 3) 시간 없는 가사
        if let lyrics = dig(calls["track.lyrics.get"], "message", "body", "lyrics") as? [String: Any],
           (lyrics["restricted"] as? Int) != 1,
           let body = lyrics["lyrics_body"] as? String {
            let plain = body.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("*******") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                return .outcome(.found(Result(raw: plain, format: "plain", wordSynced: false)))
            }
        }
        return .outcome(.notFound)
    }

    // MARK: - 변환

    /// richsync → "[00:12.30]<00:12.30>단어 <00:12.80>단어<00:13.40>" (끝 태그는 마지막 단어가 끝나는 시각)
    static func enhancedLRC(fromRichsync body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let lines = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !lines.isEmpty else { return nil }
        var output: [String] = []
        for line in lines {
            guard let start = number(line["ts"]) else { continue }
            let end = number(line["te"])
            var tokens: [(time: Double, text: String)] = []
            for piece in line["l"] as? [[String: Any]] ?? [] {
                let text = piece["c"] as? String ?? ""
                let time = start + (number(piece["o"]) ?? 0)
                // 공백만 있는 조각은 앞 단어 뒤에 붙인다(따로 태그를 달면 단어 사이 띄어쓰기가 사라진다).
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !tokens.isEmpty { tokens[tokens.count - 1].text += text }
                    continue
                }
                tokens.append((time, text))
            }
            if tokens.isEmpty {
                let text = line["x"] as? String ?? ""
                output.append("[\(timeTag(start))]\(text)")
                continue
            }
            var text = "[\(timeTag(start))]"
            for token in tokens { text += "<\(timeTag(token.time))>\(token.text)" }
            if let end { text += "<\(timeTag(end))>" }
            output.append(text)
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    /// mxm 자막 → 일반 LRC
    static func lrc(fromSubtitle body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let lines = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !lines.isEmpty else { return nil }
        let output = lines.compactMap { line -> String? in
            guard let time = number(dig(line, "time", "total")) else { return nil }
            return "[\(timeTag(time))]\(line["text"] as? String ?? "")"
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    private static func timeTag(_ seconds: Double) -> String {
        let centiseconds = Int((max(0, seconds) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    // MARK: - 요청

    private static func get(_ method: String, _ query: [(String, String)]) async -> [String: Any]? {
        guard var components = URLComponents(string: base + method) else { return nil }
        components.queryItems = [URLQueryItem(name: "app_id", value: appID)]
            + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            + [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        // URLComponents는 '+'를 그대로 두는데, 서버는 공백으로 읽는다.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("AWSELBCORS=0; AWSELB=0", forHTTPHeaderField: "Cookie")
        request.setValue("apic-desktop.musixmatch.com", forHTTPHeaderField: "authority")
        guard let fetched = try? await session.data(for: request),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: fetched.0) as? [String: Any] else { return nil }
        return json
    }

    private static func dig(_ value: Any?, _ keys: String...) -> Any? {
        var current = value
        for key in keys {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }
}
