import Foundation

// 가사 단어·음절 싱크 정렬기의 핵심 계산 (UI·SwiftData·Core ML과 무관).
// 파이썬 기준 구현(align.py --swift)과 같은 결과를 내도록 옮긴 것이다.
//
// 1) 가사를 음절로 나누고, 음절마다 로마자 글자(토큰)로 바꾼다.
// 2) MMS 모델이 낸 프레임별 글자 확률(CTC)에서 Viterbi로 가장 그럴듯한 위치를 찾는다 → 음절 시작
// 3) 보컬의 '목소리 있음'(YIN)과 세기로 길게 끄는 음의 끝을 찾는다 → 단어 끝
// 4) 모델이 못 알아들은 단어가 몰리거나 늘어지면, 원래 단어 시간이나 글자 수 비율로 고친다.

enum AlignerConfig {
    static let sampleRate = 16000
    /// wav2vec2 한 프레임 = 20ms
    static let frame = 0.02
    static let hop = 320
    /// 줄 시간 앞뒤로 이만큼까지만 찾는다
    static let lineMargin = 1.0
    static let unsureConfidence = 0.01
}

struct AlignedSyllable: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct AlignedWord: Codable, Equatable {
    var line: Int
    var word: String
    var start: Double?
    var end: Double?
    var conf: Double
    var syl: [AlignedSyllable]
    /// nil: 모델이 맞춤, "source": 원래 단어 시간, "spread": 글자 수 비율
    var fallback: String?
}

// MARK: - 토큰

enum AlignerTokenizer {
    /// MMS forced aligner 어휘(vocab.json): 0 = blank
    static let vocab: [Character: Int] = [
        "a": 4, "i": 5, "e": 6, "n": 7, "o": 8, "u": 9, "t": 10, "s": 11, "r": 12, "m": 13, "k": 14,
        "l": 15, "d": 16, "g": 17, "h": 18, "y": 19, "b": 20, "p": 21, "w": 22, "c": 23, "v": 24,
        "j": 25, "z": 26, "f": 27, "'": 28, "q": 29, "x": 30,
    ]
    static let vocabSize = 31

    /// 한글 음절 11,172자의 로마자(uroman과 같음). 줄 번호 = 코드포인트 - 0xAC00
    static let hangulTable: [String] = loadHangulTable()

    static func loadHangulTable(from url: URL? = nil) -> [String] {
        let source = url
            ?? Bundle.main.url(forResource: "hangul_roman", withExtension: "txt")
            ?? ProcessInfo.processInfo.environment["TUNE_HANGUL_TABLE"].map { URL(fileURLWithPath: $0) }
        guard let source, let text = try? String(contentsOf: source, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value)
    }

    static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && isHangulSyllable(character.unicodeScalars.first!)
    }

    /// 음절 하나(또는 단어 조각) → 토큰 번호들
    static func tokens(_ text: String) -> [Int] {
        var t = text.replacingOccurrences(of: "\u{2019}", with: "'")
        t = replaceNumbers(t)
        var out: [Int] = []
        for character in t {
            if isHangul(character) {
                let index = Int(character.unicodeScalars.first!.value) - 0xAC00
                if index < hangulTable.count {
                    out.append(contentsOf: hangulTable[index].compactMap { vocab[$0] })
                }
                continue
            }
            // 악센트 등은 떼고(NFKD) 소문자 a-z와 '만 남긴다.
            for scalar in String(character).decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
                if let id = vocab[Character(scalar)] { out.append(id) }
            }
        }
        return out
    }

    private static let ones = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(separator: " ").map(String.init)
    private static let tens = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split(separator: " ").map(String.init)

    private static func two(_ n: Int) -> String {
        n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : " " + ones[n % 10])
    }

    /// 노래 속 숫자. 4자리는 연도처럼 읽는다(2085 → twenty eighty five).
    static func numberWords(_ s: String) -> String {
        guard let n = Int(s) else { return s }
        if s.count == 4, n % 100 != 0 { return two(n / 100) + " " + two(n % 100) }
        if n < 100 { return two(n) }
        if n < 1000 { return ones[n / 100] + " hundred" + (n % 100 == 0 ? "" : " " + two(n % 100)) }
        return s.compactMap { $0.wholeNumberValue }.map { ones[$0] }.joined(separator: " ")
    }

    private static func replaceNumbers(_ s: String) -> String {
        guard s.contains(where: { $0.isASCII && $0.isNumber }) else { return s }
        var out = "", digits = ""
        for c in s {
            if c.isASCII && c.isNumber { digits.append(c); continue }
            if !digits.isEmpty { out += " " + numberWords(digits) + " "; digits = "" }
            out.append(c)
        }
        if !digits.isEmpty { out += " " + numberWords(digits) + " " }
        return out
    }

    /// 단어 → 음절. 한글은 글자마다, 영어는 하이픈 사전으로. 이어 붙이면 원래 단어가 된다.
    static func syllables(_ word: String) -> [String] {
        if word.contains(where: isHangul) {
            var out: [String] = []
            for c in word {
                if isHangul(c) || out.isEmpty { out.append(String(c)) } else { out[out.count - 1].append(c) }
            }
            return out
        }
        if word.contains(where: { $0.isASCII && $0.isNumber }) { return [word] }
        var out: [String] = []
        for var chunk in hyphenChunks(word) {
            let core = chunk.filter(isWordCharacter)
            let trailingHyphen = chunk.hasSuffix("-")
            if word.contains("-") && core.count <= 4 {  // 감탄사 조각(ooh, hmm, da)은 한 음절
                while chunk.hasSuffix("-") { chunk.removeLast() }
                out.append(chunk)
            } else {
                out.append(contentsOf: hyphenate(trailingHyphen ? String(chunk.dropLast()) : chunk))
            }
            if trailingHyphen, !out.isEmpty { out[out.count - 1] += "-" }
        }
        return out.joined() == word ? out : [word]
    }

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// "Ooh-ooh-ooh" → ["Ooh-", "ooh-", "ooh"]
    private static func hyphenChunks(_ word: String) -> [String] {
        var out: [String] = [], cur = ""
        for c in word {
            cur.append(c)
            if c == "-" { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 시스템 하이픈 사전(en_US)으로 음절 경계를 찾는다.
    static func hyphenate(_ word: String) -> [String] {
        let ns = word as NSString
        guard ns.length > 3 else { return [word] }
        #if canImport(Darwin)
        let locale = Locale(identifier: "en_US") as CFLocale
        guard CFStringIsHyphenationAvailableForLocale(locale) else { return [word] }
        var cuts: [Int] = []
        var index = ns.length
        while index > 0 {
            let loc = CFStringGetHyphenationLocationBeforeIndex(
                word as CFString, index, CFRange(location: 0, length: ns.length), 0, locale, nil)
            if loc == kCFNotFound || loc <= 0 || loc >= index { break }
            cuts.append(loc)
            index = loc
        }
        guard !cuts.isEmpty else { return [word] }
        var parts: [String] = []
        var prev = 0
        for cut in cuts.reversed() {
            parts.append(ns.substring(with: NSRange(location: prev, length: cut - prev)))
            prev = cut
        }
        parts.append(ns.substring(from: prev))
        return parts.filter { !$0.isEmpty }
        #else
        return [word]
        #endif
    }
}

// MARK: - CTC 강제 정렬

enum CTCAligner {
    /// lp: 프레임 T × 어휘 V (log 확률, 행 우선). 토큰마다 (처음, 마지막) 프레임과 최고 log 확률.
    static func viterbi(lp: [Float], frames T: Int, vocab V: Int, tokens: [Int],
                        lo: [Int]? = nil, hi: [Int]? = nil) -> (first: [Int], last: [Int], best: [Float])? {
        let L = tokens.count
        guard L > 0, T >= L else { return nil }
        let S = 2 * L + 1
        var labels = [Int](repeating: 0, count: S)
        for k in 0..<L { labels[2 * k + 1] = tokens[k] }
        var skip = [Bool](repeating: false, count: S)
        if S > 3 { for s in stride(from: 3, to: S, by: 2) { skip[s] = labels[s] != labels[s - 2] } }
        var sLo = [Int](repeating: 0, count: S), sHi = [Int](repeating: T, count: S)
        if let lo, let hi {
            for k in 0..<L { sLo[2 * k + 1] = lo[k]; sHi[2 * k + 1] = hi[k] }
        }
        // 누적 점수는 Double로(파이썬 float64와 같은 결과)
        let NEG = -1e30
        var alpha = [Double](repeating: NEG, count: S)
        var next = [Double](repeating: NEG, count: S)
        alpha[0] = Double(lp[0])
        if S > 1 { alpha[1] = Double(lp[labels[1]]) }
        var back = [UInt8](repeating: 0, count: T * S)
        back.withUnsafeMutableBufferPointer { backPtr in
            lp.withUnsafeBufferPointer { lpPtr in
                for t in 1..<T {
                    let row = t * V
                    let bRow = t * S
                    for s in 0..<S {
                        var best = alpha[s]
                        var choice: UInt8 = 0
                        if s >= 1, alpha[s - 1] > best { best = alpha[s - 1]; choice = 1 }
                        if s >= 2, skip[s], alpha[s - 2] > best { best = alpha[s - 2]; choice = 2 }
                        let allowed = t >= sLo[s] && t <= sHi[s]
                        next[s] = best + (allowed ? Double(lpPtr[row + labels[s]]) : NEG)
                        backPtr[bRow + s] = choice
                    }
                    swap(&alpha, &next)
                }
            }
        }
        var s = (S == 1 || alpha[S - 1] >= alpha[S - 2]) ? S - 1 : S - 2
        var first = [Int](repeating: -1, count: L)
        var last = [Int](repeating: -1, count: L)
        var bestLP = [Float](repeating: -1e9, count: L)
        for t in stride(from: T - 1, through: 0, by: -1) {
            if s % 2 == 1 {
                let k = s / 2
                first[k] = t
                if last[k] < 0 { last[k] = t }
                bestLP[k] = max(bestLP[k], lp[t * V + labels[s]])
            }
            s -= Int(back[t * S + s])
            if s < 0 { s = 0 }
        }
        return (first, last, bestLP)
    }

    struct Line {
        var text: String
        /// 줄 시작·끝(초). nil이면 곡 전체에서 찾는다.
        var start: Double?
        var end: Double?
    }

    /// 정렬 전체. voiced/db는 20ms 프레임(YIN). sourceWords: 단어마다 (시작, 끝) 또는 nil.
    static func align(lp: [Float], frames T: Int, vocab V: Int, voiced: [Bool], db: [Float],
                      lines: [Line], sourceWords: [(Double, Double)?]? = nil) -> [AlignedWord] {
        let frame = AlignerConfig.frame
        let anchored = lines.allSatisfy { $0.start != nil && $0.end != nil }
        var lines = lines
        if anchored, let last = lines.indices.last {
            // 마지막 줄은 끝이 정해져 있지 않다(다음 줄이 없음) → 곡 끝까지 찾게 한다.
            lines[last].end = max(lines[last].end!, Double(T) * frame)
        }

        struct Syl { var text: String; var a: Int; var b: Int; var f0: Int?; var f1: Int?; var start: Double?; var end: Double? }
        struct Word { var line: Int; var text: String; var syl: [Syl]; var conf = 0.0; var f0: Int?; var f1: Int? }

        var words: [Word] = []
        var tokens: [Int] = []
        var tokLine: [Int] = []
        for (li, line) in lines.enumerated() {
            for w in line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                var sy: [Syl] = []
                for piece in AlignerTokenizer.syllables(w) {
                    let tk = AlignerTokenizer.tokens(piece)
                    sy.append(Syl(text: piece, a: tokens.count, b: tokens.count + tk.count))
                    tokens.append(contentsOf: tk)
                    tokLine.append(contentsOf: Array(repeating: li, count: tk.count))
                }
                words.append(Word(line: li, text: w, syl: sy))
            }
        }

        var lo: [Int]?, hi: [Int]?
        if anchored {
            lo = tokLine.map { max(0, Int((lines[$0].start! - AlignerConfig.lineMargin) / frame)) }
            hi = tokLine.map { Int((lines[$0].end! + AlignerConfig.lineMargin) / frame) }
        }
        guard let result = viterbi(lp: lp, frames: T, vocab: V, tokens: tokens, lo: lo, hi: hi) else {
            return words.map { AlignedWord(line: $0.line, word: $0.text, start: nil, end: nil, conf: 0, syl: [], fallback: nil) }
        }

        // 음절 시작과 핵심 끝, 단어 자신감
        for wi in words.indices {
            var confs: [Double] = []
            for si in words[wi].syl.indices {
                let (a, b) = (words[wi].syl[si].a, words[wi].syl[si].b)
                guard a < b, result.first[a] >= 0, result.last[b - 1] >= 0 else { continue }
                words[wi].syl[si].f0 = result.first[a]
                words[wi].syl[si].f1 = result.last[b - 1]
                confs.append(contentsOf: result.best[a..<b].map(Double.init))
            }
            if !confs.isEmpty {
                let mean = confs.reduce(0, +) / Double(confs.count)
                words[wi].conf = (exp(mean) * 1000).rounded() / 1000
            }
            let good = words[wi].syl.filter { $0.f0 != nil }
            if let g0 = good.first, let g1 = good.last {
                words[wi].f0 = g0.f0
                words[wi].f1 = g1.f1
            }
        }

        // 끝: 목소리가 실제로 이어지는 마지막 순간(다음 단어 시작은 넘지 않음)
        let timed = words.indices.filter { words[$0].f0 != nil }
        for (j, wi) in timed.enumerated() {
            let w = words[wi]
            let f0 = w.f0!, f1 = w.f1!
            let nxt = j + 1 < timed.count ? words[timed[j + 1]].f0! : T
            let sameLine = j + 1 < timed.count && words[timed[j + 1]].line == w.line
            let lastSyl = w.syl.last(where: { $0.f0 != nil })!
            var peak: Float = 0
            if lastSyl.f0! < db.count {
                let upper = min(db.count, max(lastSyl.f1! + 1, lastSyl.f0! + 1))
                peak = db[lastSyl.f0!..<upper].max() ?? 0
            }
            var end = f1 + 1, gap = 0, t = f1 + 1
            let limit = min(nxt, db.count)
            while t < limit {
                if t < voiced.count, voiced[t], db[t] > peak - 18 {
                    end = t + 1; gap = 0
                } else {
                    gap += 1
                    if gap > 3 { break }
                }
                t += 1
            }
            if sameLine && nxt - end <= 5 { end = nxt }  // 100ms 이하 틈은 이어 부른 것
            end = max(end, f0 + 3)
            let endF = nxt > f0 + 3 ? min(end, nxt) : end
            let goodIdx = w.syl.indices.filter { w.syl[$0].f0 != nil }
            for (k, si) in goodIdx.enumerated() {
                let s0 = w.syl[si].f0!
                let s1 = k + 1 < goodIdx.count ? w.syl[goodIdx[k + 1]].f0! : endF
                words[wi].syl[si].start = round3(Double(s0) * frame)
                words[wi].syl[si].end = round3(Double(s1) * frame)
            }
        }

        // 결과로 바꾸기: 토큰 없는 음절은 옆 음절에 붙인다
        var out: [AlignedWord] = words.map { w in
            var syl: [AlignedSyllable] = []
            var pendingPrefix = ""
            for s in w.syl {
                if let start = s.start, let end = s.end {
                    syl.append(AlignedSyllable(text: pendingPrefix + s.text, start: start, end: end))
                    pendingPrefix = ""
                } else if !syl.isEmpty {
                    syl[syl.count - 1].text += s.text
                } else {
                    pendingPrefix += s.text
                }
            }
            if !pendingPrefix.isEmpty, !syl.isEmpty { syl[syl.count - 1].text += pendingPrefix }
            return AlignedWord(line: w.line, word: w.text, start: syl.first?.start, end: syl.last?.end,
                               conf: w.conf, syl: syl, fallback: nil)
        }
        fixUnsure(&out, lines: anchored ? lines : nil, sourceWords: sourceWords)
        return out
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    static func letterCount(_ s: String) -> Int { max(1, s.filter(AlignerTokenizer.isWordCharacter).count) }

    /// 단어 시간 [a, b]를 음절 글자 수 비율로 나눈다.
    static func spread(_ w: inout AlignedWord, _ a: Double, _ b: Double) {
        if w.syl.isEmpty {
            w.syl = AlignerTokenizer.syllables(w.word).map { AlignedSyllable(text: $0, start: 0, end: 0) }
        }
        let weights = w.syl.map { Double(letterCount($0.text)) }
        let total = weights.reduce(0, +)
        var acc = 0.0
        for i in w.syl.indices {
            let x = a + acc / total * (b - a)
            acc += weights[i]
            let y = a + acc / total * (b - a)
            w.syl[i].start = round3(x)
            w.syl[i].end = round3(y)
        }
        w.start = round3(a)
        w.end = round3(b)
    }

    /// 모델이 거의 못 알아들은 단어가 몰리거나(70ms 미만) 늘어진(3초 초과) 구간만 고친다.
    static func fixUnsure(_ words: inout [AlignedWord], lines: [Line]?, sourceWords: [(Double, Double)?]?) {
        let n = words.count
        let sure = words.map { $0.start != nil && $0.conf >= AlignerConfig.unsureConfidence }
        var i = 0
        while i < n {
            if sure[i] { i += 1; continue }
            var j = i
            while j < n && !sure[j] { j += 1 }
            let run = Array(i..<j)
            let durs = run.compactMap { k -> Double? in
                guard let s = words[k].start, let e = words[k].end else { return nil }
                return e - s
            }
            if durs.count == run.count, (durs.min() ?? 0) >= 0.07, (durs.max() ?? 0) <= 3.0 {
                i = j
                continue
            }
            if let sourceWords, run.allSatisfy({ $0 < sourceWords.count && sourceWords[$0] != nil }) {
                for k in run {
                    let (a, b) = sourceWords[k]!
                    spread(&words[k], a, b)
                    words[k].fallback = "source"
                }
            } else {
                for li in Set(run.map { words[$0].line }).sorted() {
                    let ks = run.filter { words[$0].line == li }
                    var lo = lines?[li].start, hi = lines?[li].end
                    if ks[0] > 0, sure[ks[0] - 1], words[ks[0] - 1].line == li { lo = words[ks[0] - 1].end }
                    if ks.last! + 1 < n, sure[ks.last! + 1], words[ks.last! + 1].line == li { hi = words[ks.last! + 1].start }
                    guard let a0 = lo, let b0 = hi, b0 > a0 else { continue }
                    let weights = ks.map { Double(letterCount(words[$0].word)) }
                    let total = weights.reduce(0, +)
                    var acc = 0.0
                    for (idx, k) in ks.enumerated() {
                        let a = a0 + acc / total * (b0 - a0)
                        acc += weights[idx]
                        let b = a0 + acc / total * (b0 - a0)
                        spread(&words[k], a, b)
                        words[k].fallback = "spread"
                    }
                }
            }
            i = j
        }
    }
}

// MARK: - TTML

enum AlignedTTML {
    struct Background {
        var afterLine: Int
        var words: [(text: String, start: Double, end: Double)]
    }

    private static func time(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t / 60)
        return String(format: "%d:%06.3f", m, t - Double(m) * 60)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 줄마다 <p>, 음절마다 <span>. 단어 사이에만 공백. 배경 보컬은 앞 줄 안에 x-bg로.
    static func build(_ words: [AlignedWord], lineCount: Int, background: [Background] = []) -> String {
        var byLine = [[AlignedWord]](repeating: [], count: lineCount)
        for w in words where w.start != nil && !w.syl.isEmpty && w.line < lineCount { byLine[w.line].append(w) }
        var body: [String] = []
        for (li, ws) in byLine.enumerated() {
            let bgs = background.filter { $0.afterLine == li }
            guard let first = ws.first, let last = ws.last else { continue }
            var spans = ws.map { w in
                w.syl.map { "<span begin=\"\(time($0.start))\" end=\"\(time($0.end))\">\(escape($0.text))</span>" }.joined()
            }.joined(separator: " ")
            var end = last.end ?? first.start!
            for bg in bgs where !bg.words.isEmpty {
                let inner = bg.words.map { "<span begin=\"\(time($0.start))\" end=\"\(time($0.end))\">\(escape($0.text.trimmingCharacters(in: .whitespaces)))</span>" }.joined(separator: " ")
                spans += " <span ttm:role=\"x-bg\">\(inner)</span>"
                end = max(end, bg.words.last!.end)
            }
            body.append("      <p begin=\"\(time(first.start!))\" end=\"\(time(end))\">\(spans)</p>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="und">
          <head><metadata><ttm:agent xml:id="v1" type="person"/></metadata></head>
          <body>
            <div>
        \(body.joined(separator: "\n"))
            </div>
          </body>
        </tt>

        """
    }
}
