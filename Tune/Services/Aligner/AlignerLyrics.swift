import Foundation

// 읽어 둔 가사(Lyrics) → 정렬기 입력, 그리고 정렬 결과를 곡 옆 .ttml 파일로 남기기.
// 앱(AutoSync)과 컴퓨터용 도구(Tools/TuneSync)가 같이 쓴다.

enum AlignerLyrics {
    /// 우리가 만든 TTML이라는 표시(<head> 안). 이 표시가 있으면 Tune이 가장 먼저 쓴다.
    static let generatorTag = "tune:generator"
    static let sourceName = "Tune 정렬"

    static func isGenerated(_ raw: String) -> Bool {
        raw.contains("<\(generatorTag)")
    }

    struct Input {
        var lines: [CTCAligner.Line]
        var sourceWords: [(Double, Double)?]?
        var background: [AlignedTTML.Background]
    }

    /// 가사 줄을 정렬기 입력으로. 배경 보컬 줄은 빼고(나중에 원래 시간으로 붙인다), 단어 시간이 있으면 같이 넘긴다.
    static func prepare(_ lyrics: Lyrics) -> Input? {
        var lines: [CTCAligner.Line] = []
        var sourceWords: [(Double, Double)?] = []
        var background: [AlignedTTML.Background] = []
        if lyrics.isSynced {
            for line in lyrics.lines {
                if line.isBackground {
                    if !lines.isEmpty {
                        background.append(.init(afterLine: lines.count - 1,
                                                words: line.words.map { ($0.text, $0.start, $0.end) }))
                    }
                    continue
                }
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                lines.append(.init(text: text, start: line.start, end: max(line.end, line.start + 0.5)))
                sourceWords.append(contentsOf: wordTimes(line, wordCount: text.split(whereSeparator: { $0.isWhitespace }).count))
            }
        } else {
            for text in lyrics.plainText.components(separatedBy: .newlines) {
                let t = text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(.init(text: t, start: nil, end: nil)) }
            }
        }
        guard !lines.isEmpty else { return nil }
        return Input(lines: lines, sourceWords: sourceWords.contains { $0 != nil } ? sourceWords : nil, background: background)
    }

    /// 원래 가사의 단어 시간(있을 때만). 음절 조각은 띄어쓰기 기준으로 합친다.
    static func wordTimes(_ line: LyricLine, wordCount: Int) -> [(Double, Double)?] {
        let none = [(Double, Double)?](repeating: nil, count: wordCount)
        guard line.hasWordTiming else { return none }
        var words: [(Double, Double)] = []
        var current: (Double, Double)?
        for token in line.words {
            if current == nil { current = (token.start, token.end) } else { current!.1 = token.end }
            if token.text.hasSuffix(" ") { words.append(current!); current = nil }
        }
        if let current { words.append(current) }
        return words.count == wordCount ? words.map { $0 } : none
    }

    /// 곡 파일 옆의 같은 이름 .ttml
    static func sidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("ttml")
    }

    /// 곡 옆에 .ttml로 저장하고, 원래 가사 파일(같은 이름의 .lrc, 예전 .original.ttml)은 지운다.
    /// 우리가 만들지 않은 .ttml이 있었다면 덮어쓴다. 다시 만들 때는 이 .ttml을 원본으로 쓴다.
    @discardableResult
    static func writeSidecar(_ ttml: String, for audio: URL) -> Bool {
        do {
            try ttml.write(to: sidecarURL(for: audio), atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        let base = audio.deletingPathExtension()
        for leftover in [base.appendingPathExtension("lrc"), base.appendingPathExtension("original.ttml")] {
            try? FileManager.default.removeItem(at: leftover)
        }
        return true
    }
}
