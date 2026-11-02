import XCTest
@testable import Tune

final class LyricsTimingTests: XCTestCase {
    private let accuracy = 0.0001

    private func parse(_ lrc: String, estimateWords: Bool = true) -> Lyrics {
        guard let lyrics = LyricsParser.parseLRC(lrc, estimateWords: estimateWords) else {
            XCTFail("LRC 파싱에 실패했다")
            return Lyrics(lines: [], isSynced: false, hasWordTiming: false, source: "", plainText: "")
        }
        return lyrics
    }

    private func assertLineIsWellFormed(
        _ line: LyricLine,
        upper: Double,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        XCTAssertFalse(line.words.isEmpty, "단어가 없다", file: file, line: lineNumber)
        for (index, word) in line.words.enumerated() {
            XCTAssertGreaterThan(word.end, word.start, "단어 길이가 0 이하", file: file, line: lineNumber)
            XCTAssertGreaterThanOrEqual(word.start, line.start - accuracy, "줄 시작보다 이르다", file: file, line: lineNumber)
            XCTAssertLessThanOrEqual(word.end, upper + accuracy, "줄 끝을 넘는다", file: file, line: lineNumber)
            if index > 0 {
                XCTAssertGreaterThan(
                    word.start, line.words[index - 1].start,
                    "start가 단조 증가하지 않는다", file: file, line: lineNumber
                )
                XCTAssertGreaterThanOrEqual(
                    word.start, line.words[index - 1].end - accuracy,
                    "앞 단어와 겹친다", file: file, line: lineNumber
                )
            }
        }
    }

    private func midProgressCount(_ line: LyricLine, at time: Double) -> Int {
        line.words.reduce(0) { count, word in
            let progress = word.progress(at: time)
            return count + (progress > 0 && progress < 1 ? 1 : 0)
        }
    }

    private func assertAtMostOneWordInProgress(
        _ line: LyricLine,
        upper: Double,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        var time = line.start
        while time <= upper + accuracy {
            let count = midProgressCount(line, at: time)
            XCTAssertLessThanOrEqual(
                count, 1,
                "t=\(time)에서 \(count)개 단어가 동시에 진행 중", file: file, line: lineNumber
            )
            time += 0.005
        }
    }

    // MARK: 어림잡기

    func testEstimateSevenWordsIsMonotonicAndNonOverlapping() {
        let lyrics = parse("""
        [00:10.00]one two three four five six seven
        [00:13.00]next line
        """)
        let line = lyrics.lines[0]
        XCTAssertEqual(line.words.count, 7)
        XCTAssertFalse(line.hasWordTiming)
        assertLineIsWellFormed(line, upper: lyrics.lines[1].start)
        assertAtMostOneWordInProgress(line, upper: lyrics.lines[1].start)
        // 줄 길이의 90%만 쓴다.
        XCTAssertLessThanOrEqual(line.words.last!.end, line.start + 3 * 0.9 + accuracy)
    }

    func testEstimatedLineHasAtMostOneWordInProgress() {
        let lyrics = parse("""
        [00:16.00]I'm zoning out
        [00:19.00]next line
        """)
        let line = lyrics.lines[0]
        XCTAssertEqual(line.words.count, 3)
        assertLineIsWellFormed(line, upper: lyrics.lines[1].start)
        assertAtMostOneWordInProgress(line, upper: lyrics.lines[1].start)
    }

    // MARK: 실제 단어 태그

    func testOverlappingEnhancedLRCTagsAreNormalized() {
        let lyrics = parse("""
        [00:10.00]<00:10.00>And <00:10.50> <00:10.20>I <00:10.40>was <00:13.00>nice
        [00:13.00]next line
        """)
        let line = lyrics.lines[0]
        XCTAssertEqual(line.words.count, 4)
        XCTAssertEqual(
            line.words.map { $0.text.trimmingCharacters(in: .whitespaces) },
            ["And", "I", "was", "nice"]
        )
        assertLineIsWellFormed(line, upper: lyrics.lines[1].start)
        assertAtMostOneWordInProgress(line, upper: lyrics.lines[1].start)
    }

    func testTTMLWordSpansAreNormalized() {
        let ttml = """
        <tt><body><div>
        <p begin="10s" end="15s"><span>And </span><span>I </span><span>was </span><span>always </span><span>nice </span></p>
        <p begin="15s" end="18s"><span>you </span><span>up </span><span>the </span><span>stairs</span></p>
        </div></body></tt>
        """
        guard let lyrics = LyricsParser.parse(ttml, format: "ttml", estimateWords: true) else {
            XCTFail("TTML 파싱에 실패했다")
            return
        }
        let line = lyrics.lines[0]
        XCTAssertEqual(line.words.count, 5)
        XCTAssertFalse(line.hasWordTiming)
        assertLineIsWellFormed(line, upper: lyrics.lines[1].start)
        assertAtMostOneWordInProgress(line, upper: lyrics.lines[1].start)
    }

    func testTimedTTMLSpansKeepTheirTimes() {
        let ttml = """
        <tt><body><div>
        <p begin="10s" end="15s"><span begin="10.0s" end="10.4s">And </span><span begin="10.4s" end="10.6s">I </span><span begin="10.6s" end="11.4s">was </span></p>
        </div></body></tt>
        """
        guard let lyrics = LyricsParser.parse(ttml, format: "ttml", estimateWords: true) else {
            XCTFail("TTML 파싱에 실패했다")
            return
        }
        let line = lyrics.lines[0]
        XCTAssertTrue(line.hasWordTiming)
        XCTAssertEqual(line.words.count, 3)
        XCTAssertEqual(line.words[0].start, 10.0, accuracy: accuracy)
        XCTAssertEqual(line.words[0].end, 10.4, accuracy: accuracy)
        XCTAssertEqual(line.words[1].start, 10.4, accuracy: accuracy)
        XCTAssertEqual(line.words[1].end, 10.6, accuracy: accuracy)
        assertLineIsWellFormed(line, upper: line.end)
        assertAtMostOneWordInProgress(line, upper: line.end)
    }

    // MARK: 어림잡기 끔

    func testLineWithoutWordTimingAndEstimateOffIsOneWholeLineWord() {
        let lyrics = parse("""
        [00:10.00]I'm zoning out
        [00:13.00]next line
        """, estimateWords: false)
        let line = lyrics.lines[0]
        XCTAssertEqual(line.words.count, 1)
        XCTAssertFalse(line.hasWordTiming)
        XCTAssertEqual(line.words[0].start, line.start, accuracy: accuracy)
        XCTAssertEqual(line.words[0].end, line.end, accuracy: accuracy)
        let middle = (line.start + line.end) / 2
        XCTAssertTrue(line.words[0].progress(at: middle) > 0)
        XCTAssertTrue(line.words[0].progress(at: middle) < 1)
        XCTAssertEqual(midProgressCount(line, at: middle), 1)
    }

    // MARK: 줄바꿈

    func testWrappedLayoutKeepsWordOrderAndTiming() {
        let lyrics = parse("""
        [00:10.00]one two three four five six seven
        [00:13.00]next line
        """)
        let line = lyrics.lines[0]
        let layout = LyricLineLayout.make(line, width: 120, fontSize: 28)
        XCTAssertEqual(layout.frames.count, line.words.count)
        XCTAssertEqual(layout.wraps.count, line.words.count)
        XCTAssertGreaterThan(Set(layout.frames.map { $0.minY }).count, 1, "좁은 폭에서는 여러 줄로 접혀야 한다")
        // frames[index]는 line.words[index]의 자리다. 단어 순서가 뒤집히지 않았는지 확인한다.
        for index in 1..<layout.frames.count {
            XCTAssertGreaterThanOrEqual(layout.frames[index].minY, layout.frames[index - 1].minY)
        }
        assertAtMostOneWordInProgress(line, upper: lyrics.lines[1].start)
    }
}
