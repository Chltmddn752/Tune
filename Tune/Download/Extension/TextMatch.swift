import Foundation

enum TextMatch {
    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 0...1. 확장의 matching.compareStrings와 같은 용도로 쓴다.
    static func similarity(_ first: String, _ second: String) -> Double {
        let a = normalize(first)
        let b = normalize(second)
        if a.isEmpty || b.isEmpty { return a == b ? 1 : 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.88 }

        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        let union = aTokens.union(bTokens).count
        let jaccard = union == 0 ? 0 : Double(aTokens.intersection(bTokens).count) / Double(union)
        let edit = 1 - Double(levenshtein(Array(a), Array(b))) / Double(max(a.count, b.count))
        return max(0, min(1, jaccard * 0.55 + edit * 0.45))
    }

    static func durationMatches(_ first: Int, _ second: Int, tolerance: Int = 3_000) -> Bool {
        guard first > 0, second > 0 else { return true }
        return abs(first - second) <= max(0, tolerance)
    }

    static func bestMatch(for wanted: ProviderTrack, in results: [ProviderTrack]) -> ProviderTrack? {
        results.max { lhs, rhs in
            score(wanted, lhs) < score(wanted, rhs)
        }.flatMap { best in
            score(wanted, best) >= 0.45 ? best : nil
        }
    }

    static func score(_ wanted: ProviderTrack, _ candidate: ProviderTrack) -> Double {
        var score = similarity(wanted.title, candidate.title) * 0.62
        score += similarity(wanted.artist, candidate.artist) * 0.28
        if durationMatches(wanted.durationMs, candidate.durationMs) { score += 0.10 }
        return score
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
