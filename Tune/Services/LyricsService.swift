import Foundation
import SwiftData

struct LyricWord: Hashable {
    var text: String
    var start: Double
    var end: Double
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    var start: Double
    var end: Double
    var text: String
    var words: [LyricWord]
    var isBackground: Bool
    var hasWordTiming: Bool
    /// 같은 시각에 한 줄 더 적힌 번역 가사 (원문 아래 작게)
    var translation: String? = nil

    /// 마지막 단어가 끝나는 시각 (간주 판단용)
    var singingEnd: Double { words.last?.end ?? end }
}

struct Lyrics: Equatable {
    var lines: [LyricLine]
    var isSynced: Bool
    var hasWordTiming: Bool
    var source: String
    var plainText: String

    static func == (lhs: Lyrics, rhs: Lyrics) -> Bool {
        lhs.lines == rhs.lines && lhs.plainText == rhs.plainText
    }

    func lineIndex(at time: Double) -> Int? {
        guard isSynced, !lines.isEmpty else { return nil }
        // 이진 탐색으로 지금 시각에 해당하는 줄을 찾는다.
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // 배경 보컬 줄이면 그 앞의 본 줄을 기준으로 삼는다.
        if var r = result {
            while r > 0, lines[r].isBackground { r -= 1 }
            return r
        }
        return nil
    }
}

enum LyricsParser {
    static func parse(_ raw: String, format: String, estimateWords: Bool) -> Lyrics? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if format == "ttml" || trimmed.hasPrefix("<?xml") || trimmed.contains("<tt") {
            if let lyrics = TTMLParser.parse(trimmed) { return lyrics }
        }
        if let lyrics = parseLRC(trimmed, estimateWords: estimateWords) { return lyrics }
        return Lyrics(lines: [], isSynced: false, hasWordTiming: false, source: "", plainText: trimmed)
    }

    // MARK: LRC

    private static let lineTagPattern = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let wordTagPattern = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>"#)
    private static let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\]"#, options: .caseInsensitive)

    static func parseLRC(_ raw: String, estimateWords: Bool) -> Lyrics? {
        var offset = 0.0
        let ns = raw as NSString
        if let match = offsetPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            offset = (Double(ns.substring(with: match.range(at: 1))) ?? 0) / 1000
        }

        struct RawLine {
            var start: Double; var text: String; var words: [LyricWord]; var order = 0; var translation: String?
            var background = false
        }
        var rawLines: [RawLine] = []
        var anyWordTiming = false

        for line in raw.components(separatedBy: .newlines) {
            let lineNS = line as NSString
            let matches = lineTagPattern.matches(in: line, range: NSRange(location: 0, length: lineNS.length))
            guard !matches.isEmpty else { continue }
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let body = lineNS.substring(from: lastEnd)
            var (text, words) = parseWordTags(body)
            // "v1:" "v2:" (부르는 사람) · "bg:" (배경 코러스) 같은 표시는 글자에서 뺀다.
            var voiceBackground = false
            if let marker = voiceMarker(in: text) {
                voiceBackground = marker.isBackground
                text = String(text.dropFirst(marker.length))
                if let first = words.indices.first {
                    let trimmed = words[first].text.drop { $0 == " " }
                    if trimmed.count >= marker.length {
                        words[first].text = String(trimmed.dropFirst(marker.length))
                    }
                    if words[first].text.trimmingCharacters(in: .whitespaces).isEmpty { words.removeFirst() }
                }
            }
            if !words.isEmpty { anyWordTiming = true }
            for match in matches {
                guard let time = time(minutes: lineNS.substring(with: match.range(at: 1)),
                                      seconds: lineNS.substring(with: match.range(at: 2))) else { continue }
                rawLines.append(RawLine(start: time - offset, text: text, words: words.map {
                    LyricWord(text: $0.text, start: $0.start - offset, end: $0.end - offset)
                }, order: rawLines.count, background: voiceBackground))
            }
        }
        guard !rawLines.isEmpty else { return nil }
        rawLines.sort { ($0.start, $0.order) < ($1.start, $1.order) }
        // 같은 시각에 두 줄이 있으면 두 번째 줄은 번역으로 본다.
        var merged: [RawLine] = []
        for line in rawLines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if let last = merged.indices.last, abs(merged[last].start - line.start) < 0.02,
               merged[last].translation == nil, !text.isEmpty,
               !merged[last].text.trimmingCharacters(in: .whitespaces).isEmpty {
                merged[last].translation = text
            } else {
                merged.append(line)
            }
        }
        rawLines = merged

        var lines: [LyricLine] = []
        for (i, rawLine) in rawLines.enumerated() {
            let text = rawLine.text.trimmingCharacters(in: .whitespaces)
            let nextStart = i + 1 < rawLines.count ? rawLines[i + 1].start : rawLine.start + 6
            if text.isEmpty { continue }
            var words = rawLine.words
            let hasTiming = !words.isEmpty
            if hasTiming {
                for w in words.indices where w + 1 < words.count && words[w].end <= words[w].start {
                    words[w].end = words[w + 1].start
                }
                if let last = words.indices.last, words[last].end <= words[last].start {
                    words[last].end = min(nextStart, words[last].start + 1.2)
                }
            } else if estimateWords {
                words = estimate(text: text, start: rawLine.start, end: nextStart)
            } else {
                words = [LyricWord(text: text, start: rawLine.start, end: nextStart)]
            }
            // 줄 전체가 괄호로 감싸진 줄은 배경 코러스로 (작고 흐리게, 앞 줄에 붙여서)
            let isBackground = lines.count > 0
                && (rawLine.background || (text.count > 2 && text.hasPrefix("(") && text.hasSuffix(")")))
            lines.append(LyricLine(id: lines.count, start: rawLine.start, end: nextStart, text: text,
                                   words: words, isBackground: isBackground, hasWordTiming: hasTiming,
                                   translation: rawLine.translation))
        }
        guard !lines.isEmpty else { return nil }
        let plain = lines.map(\.text).joined(separator: "\n")
        return Lyrics(lines: lines, isSynced: true, hasWordTiming: anyWordTiming, source: "", plainText: plain)
    }

    private static let voicePattern = try! NSRegularExpression(pattern: #"^\s*(v\d{1,2}|bg|f|m|d)\s*:\s*"#, options: .caseInsensitive)

    /// 줄 앞의 "v1:" 같은 표시 (길이와 배경 코러스 여부)
    private static func voiceMarker(in text: String) -> (length: Int, isBackground: Bool)? {
        let ns = text as NSString
        guard let match = voicePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let tag = ns.substring(with: match.range(at: 1)).lowercased()
        return (match.range.length, tag == "bg")
    }

    /// "<00:12.30>안녕 <00:12.80>하세요" 같은 단어 태그를 읽는다.
    private static func parseWordTags(_ body: String) -> (String, [LyricWord]) {
        let ns = body as NSString
        let matches = wordTagPattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (body, []) }
        var words: [LyricWord] = []
        for (i, match) in matches.enumerated() {
            guard let start = time(minutes: ns.substring(with: match.range(at: 1)),
                                   seconds: ns.substring(with: match.range(at: 2))) else { continue }
            let textStart = match.range.location + match.range.length
            let textEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                // 끝 시각만 표시한 태그
                if let last = words.indices.last { words[last].end = start }
                continue
            }
            if let last = words.indices.last, words[last].end <= words[last].start { words[last].end = start }
            words.append(LyricWord(text: text, start: start, end: start))
        }
        let plain = words.map(\.text).joined()
        return (plain, words)
    }

    /// 줄 시간만 있을 때 글자 수에 맞춰 단어 시간을 어림잡는다.
    static func estimate(text: String, start: Double, end: Double) -> [LyricWord] {
        let pieces = splitWords(text)
        let totalChars = max(1, pieces.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespaces).count })
        let available = max(0.6, end - start)
        let singing = min(available * 0.9, max(1.0, Double(totalChars) * 0.3))
        var cursor = start
        return pieces.map { piece in
            let weight = Double(max(1, piece.trimmingCharacters(in: .whitespaces).count)) / Double(totalChars)
            let length = singing * weight
            defer { cursor += length }
            return LyricWord(text: piece, start: cursor, end: cursor + length)
        }
    }

    /// 띄어쓰기로 나누고, 띄어쓰기가 없는 일본어·중국어는 글자 단위로 나눈다. 띄어쓰기는 앞 단어에 붙인다.
    static func splitWords(_ text: String) -> [String] {
        if !text.contains(" "), text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
            return text.map(String.init)
        }
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func time(minutes: String, seconds: String) -> Double? {
        guard let m = Double(minutes) else { return nil }
        let s = Double(seconds.replacingOccurrences(of: ":", with: ".")) ?? 0
        return m * 60 + s
    }
}

/// Apple Music 방식 TTML(단어별 <span>)을 읽는다.
final class TTMLParser: NSObject, XMLParserDelegate {
    private var lines: [LyricLine] = []
    private var currentLineStart: Double?
    private var currentLineEnd: Double?
    private var currentWords: [LyricWord] = []
    private var backgroundWords: [LyricWord] = []
    private var spanStack: [(begin: Double?, end: Double?, isBackground: Bool)] = []
    private var pendingText = ""
    private var inParagraph = false

    static func parse(_ raw: String) -> Lyrics? {
        guard let data = raw.data(using: .utf8) else { return nil }
        let delegate = TTMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.lines.isEmpty else { return nil }
        let sorted = delegate.lines.sorted { $0.start < $1.start }.enumerated().map { offset, line in
            LyricLine(id: offset, start: line.start, end: line.end, text: line.text, words: line.words,
                      isBackground: line.isBackground, hasWordTiming: line.hasWordTiming)
        }
        let hasWords = sorted.contains { $0.hasWordTiming }
        return Lyrics(lines: sorted, isSynced: true, hasWordTiming: hasWords, source: "",
                      plainText: sorted.filter { !$0.isBackground }.map(\.text).joined(separator: "\n"))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "p" {
            inParagraph = true
            currentLineStart = attributes["begin"].flatMap(Self.parseTime)
            currentLineEnd = attributes["end"].flatMap(Self.parseTime)
            currentWords = []
            backgroundWords = []
            pendingText = ""
        } else if name == "span", inParagraph {
            flushText()
            let role = attributes["ttm:role"] ?? attributes["role"] ?? ""
            let parentBackground = spanStack.last?.isBackground ?? false
            spanStack.append((attributes["begin"].flatMap(Self.parseTime),
                              attributes["end"].flatMap(Self.parseTime),
                              parentBackground || role == "x-bg"))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inParagraph else { return }
        pendingText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "span", inParagraph {
            flushText()
            _ = spanStack.popLast()
        } else if name == "p" {
            flushText()
            finishLine()
            inParagraph = false
        }
    }

    /// 단어 사이 띄어쓰기는 앞 단어에 붙인다.
    private func flushText() {
        let text = pendingText.replacingOccurrences(of: "\n", with: " ")
        pendingText = ""
        guard !text.isEmpty else { return }
        let top = spanStack.last
        let isBackground = top?.isBackground ?? false
        if let begin = top?.begin, text.trimmingCharacters(in: .whitespaces).isEmpty == false {
            let word = LyricWord(text: text, start: begin, end: top?.end ?? begin)
            if isBackground { backgroundWords.append(word) } else { currentWords.append(word) }
        } else if text.allSatisfy({ $0 == " " }) {
            if isBackground, let last = backgroundWords.indices.last { backgroundWords[last].text += " " }
            else if let last = currentWords.indices.last { currentWords[last].text += " " }
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let start = currentLineStart ?? 0
            let word = LyricWord(text: text, start: start, end: currentLineEnd ?? start + 3)
            if isBackground { backgroundWords.append(word) } else { currentWords.append(word) }
        }
    }

    private func finishLine() {
        func makeLine(_ words: [LyricWord], background: Bool) -> LyricLine? {
            guard !words.isEmpty else { return nil }
            let start = words.first?.start ?? currentLineStart ?? 0
            let end = currentLineEnd ?? words.last?.end ?? start + 3
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let timed = words.count > 1 || words.first?.end != end
            return LyricLine(id: 0, start: background ? start : (currentLineStart ?? start), end: end, text: text,
                             words: words, isBackground: background, hasWordTiming: timed)
        }
        if let main = makeLine(currentWords, background: false) { lines.append(main) }
        if let bg = makeLine(backgroundWords, background: true) {
            var adjusted = bg
            // 배경 보컬은 본 줄 바로 뒤에 오도록 시작 시각을 살짝 늦춘다.
            adjusted.start = max(bg.start, (lines.last?.start ?? bg.start) + 0.001)
            lines.append(adjusted)
        }
    }

    static func parseTime(_ value: String) -> Double? {
        var string = value.trimmingCharacters(in: .whitespaces)
        if string.hasSuffix("ms"), let ms = Double(string.dropLast(2)) { return ms / 1000 }
        if string.hasSuffix("s") { string.removeLast() }
        let parts = string.split(separator: ":").map(String.init)
        switch parts.count {
        case 1: return Double(parts[0])
        case 2: return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
        case 3: return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + (Double(parts[2]) ?? 0)
        default: return nil
        }
    }
}

/// 가사를 찾는 순서: 같은 이름의 가사 파일 → 저장해 둔 가사 → 파일 안 가사 → LRCLIB
@MainActor
enum LyricsService {
    static func load(for item: QueueItem, context: ModelContext) async -> (Lyrics?, LyricsCache?) {
        let estimate = UserDefaults.standard.object(forKey: SettingsKey.estimateWordTiming) as? Bool ?? true
        let id = item.trackID
        var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        let cached = try? context.fetch(descriptor).first

        // 1. 곡 옆의 .ttml / .lrc 파일
        for ext in ["ttml", "lrc"] {
            let url = item.fileURL.deletingPathExtension().appendingPathExtension(ext)
            // 클라우드 폴더에 있는 가사 파일은 받아진 다음에 읽는다.
            if CloudFiles.isExternal(url), CloudFiles.exists(url), !CloudFiles.isDownloaded(url) {
                await CloudFiles.ensureDownloaded(url, timeout: 20)
            }
            if let raw = try? String(contentsOf: url, encoding: .utf8),
               var lyrics = LyricsParser.parse(raw, format: ext, estimateWords: estimate) {
                lyrics.source = "가사 파일"
                return (shifted(lyrics, by: cached?.offset ?? 0), cached)
            }
        }

        // 2. 저장해 둔 가사
        if let cached, cached.format != "none" {
            if var lyrics = LyricsParser.parse(cached.raw, format: cached.format, estimateWords: estimate) {
                lyrics.source = cached.source
                return (shifted(lyrics, by: cached.offset), cached)
            }
        }

        // 3. 파일 안에 들어있는 가사
        var embeddedPlain: Lyrics?
        if let track = fetchTrack(id, context: context), let embedded = track.embeddedLyrics,
           var lyrics = LyricsParser.parse(embedded, format: "lrc", estimateWords: estimate) {
            lyrics.source = "파일 안 가사"
            if lyrics.isSynced { return (lyrics, cached) }
            embeddedPlain = lyrics
        }

        // 4. 인터넷 (설정에서 끌 수 있음)
        let online = UserDefaults.standard.object(forKey: SettingsKey.onlineLyrics) as? Bool ?? true
        if online, cached == nil || cached?.format == "none" && (cached?.fetchedAt.timeIntervalSinceNow ?? -1e9) < -7 * 86400 {
            if let fetched = await LRCLIB.fetch(item) {
                let (raw, format) = fetched
                let entry = cached ?? LyricsCache(trackID: id, raw: raw, format: format, source: "LRCLIB")
                entry.raw = raw
                entry.format = format
                entry.source = "LRCLIB"
                entry.fetchedAt = .now
                if cached == nil { context.insert(entry) }
                try? context.save()
                if var lyrics = LyricsParser.parse(raw, format: format, estimateWords: estimate) {
                    lyrics.source = "LRCLIB"
                    return (shifted(lyrics, by: entry.offset), entry)
                }
            } else if cached == nil {
                context.insert(LyricsCache(trackID: id, raw: "", format: "none", source: ""))
                try? context.save()
            }
        }
        return (embeddedPlain, cached)
    }

    static func setOffset(_ offset: Double, for item: QueueItem, context: ModelContext) {
        let id = item.trackID
        var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        if let cached = try? context.fetch(descriptor).first {
            cached.offset = offset
        } else {
            let entry = LyricsCache(trackID: id, raw: "", format: "none", source: "")
            entry.offset = offset
            context.insert(entry)
        }
        try? context.save()
    }

    static func shifted(_ lyrics: Lyrics, by offset: Double) -> Lyrics {
        guard offset != 0 else { return lyrics }
        var copy = lyrics
        copy.lines = lyrics.lines.map { line in
            var l = line
            l.start -= offset
            l.end -= offset
            l.words = line.words.map { LyricWord(text: $0.text, start: $0.start - offset, end: $0.end - offset) }
            return l
        }
        return copy
    }

    private static func fetchTrack(_ id: UUID, context: ModelContext) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// lrclib.net 무료 가사 API
enum LRCLIB {
    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    static func fetch(_ item: QueueItem) async -> (String, String)? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: item.title),
            URLQueryItem(name: "artist_name", value: item.artist),
            URLQueryItem(name: "album_name", value: item.album),
            URLQueryItem(name: "duration", value: String(Int(item.duration.rounded())))
        ]
        if let result = await request(components.url) { return result }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: item.title),
            URLQueryItem(name: "artist_name", value: item.artist)
        ]
        guard let url = search.url, let data = await data(from: url),
              let results = try? JSONDecoder().decode([Response].self, from: data) else { return nil }
        if let synced = results.first(where: { $0.syncedLyrics?.isEmpty == false })?.syncedLyrics { return (synced, "lrc") }
        if let plain = results.first(where: { $0.plainLyrics?.isEmpty == false })?.plainLyrics { return (plain, "plain") }
        return nil
    }

    private static func request(_ url: URL?) async -> (String, String)? {
        guard let url, let data = await data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if let synced = response.syncedLyrics, !synced.isEmpty { return (synced, "lrc") }
        if let plain = response.plainLyrics, !plain.isEmpty { return (plain, "plain") }
        return nil
    }

    private static func data(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Tune/0.1 (personal music player)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return result.0
    }
}
