import Foundation

/// 제목·이름 비교에 쓰는 공통 정리 규칙.
enum LibraryText {
    /// 괄호 안의 (Remastered) · [MV] · (feat. X) 같은 꼬리표를 뗀 제목.
    static func strippedTitle(_ raw: String) -> String {
        var value = raw.nfc
        let patterns = [
            #"\([^)]*\)"#, #"\[[^\]]*\]"#, #"【[^】]*】"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // "Artist - Title" 형태의 채널 제목에서 뒤쪽만 남기지는 않는다(곡 비교용이라 앞뒤를 합친다).
        value = value.replacingOccurrences(
            of: #"\s*[-–—]\s*(topic|official audio|official video|lyrics?|mv|m/v)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return value
    }

    /// 대소문자·공백·문장부호·괄호 꼬리표를 무시한 비교용 열쇠.
    static func key(_ raw: String) -> String {
        let stripped = strippedTitle(raw)
        let folded = stripped.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let allowed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(allowed).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 라이브·리믹스·인스트·어쿠스틱처럼 다른 버전을 구분하는 꼬리표가 있는지.
    static func versionTag(_ raw: String) -> String? {
        let lower = raw.nfc.lowercased()
        let tags = ["live", "remix", "inst", "instrumental", "acoustic", "ver.", "version", "karaoke", "sped up", "slowed"]
        for tag in tags where lower.contains(tag) {
            return tag
        }
        return nil
    }

    /// 목록 정렬은 대소문자·숫자를 사람이 읽는 순서로 맞춘다.
    /// (`@Query(sort:)`의 SQLite 비교는 대문자를 먼저 두고 소문자를 Z 뒤로 보낸다)
    static func compare(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    static func sorted<T>(_ items: [T], by name: (T) -> String) -> [T] {
        items.sorted { compare(name($0), name($1)) }
    }

    /// 첫 글자(가나다·A~Z·#)로 묶는다. 정렬된 배열을 한 번만 훑는다.
    static func grouped<T>(_ items: [T], by name: (T) -> String) -> [(key: String, items: [T])] {
        var order: [String] = []
        var groups: [String: [T]] = [:]
        for item in items {
            let key = IndexKey.of(name(item))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// YouTube 업로더 이름이 아티스트 칸에 들어온 경우.
    /// (Official髭男dism처럼 'Official'이 이름의 일부인 진짜 아티스트는 건드리지 않는다)
    static func looksLikeChannel(_ raw: String) -> Bool {
        let name = raw.nfc.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        guard !name.isEmpty else { return false }
        if lower.hasSuffix(" - topic") || lower.hasSuffix("- topic") { return true }
        if lower.hasSuffix("official channel") || lower.hasSuffix("official youtube channel") { return true }
        if lower.contains("the first take") { return true }
        if lower.contains("viral songs") { return true }
        if lower.contains("(cv:") || lower.contains("(cv：") { return true }
        if lower.hasSuffix(" official") || lower.hasSuffix(" official.") { return true }
        if lower.contains("official channel") { return true }
        // "【...】Official Channel" 같은 제목형 이름
        if name.contains("【"), lower.contains("official") { return true }
        return false
    }

    /// "아티스트 - 제목" 형태에서 아티스트로 보이는 앞부분을 제안한다.
    static func suggestedArtist(fromTitle title: String, fallback: String) -> String? {
        let separators = [" - ", " – ", " — ", "｜", "|"]
        for separator in separators {
            let parts = title.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let candidate = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 2, candidate.count <= 40, key(candidate) != key(fallback) {
                return candidate
            }
        }
        return nil
    }
}
