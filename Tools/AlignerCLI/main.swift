import CoreML
import Foundation

// 정렬기 시험용 명령줄 도구 (macOS). 앱과 같은 Swift 코드로 곡 하나를 정렬해 JSON으로 쓴다.
// swiftc -O Tune/Services/Aligner/{AlignerCore,AlignerDSP,AlignerPipeline}.swift Tools/AlignerCLI/main.swift -o aligner
// TUNE_HANGUL_TABLE=Tune/Resources/hangul_roman.txt ./aligner sep.mlmodelc aligner.mlmodelc song.flac song.lrc out.json

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 6 else {
    print("usage: aligner <separator.mlmodelc> <aligner.mlmodelc> <audio> <lyrics.lrc> <out.json>")
    exit(2)
}

func seconds(_ tag: String) -> Double {
    let parts = tag.split(separator: ":")
    return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
}

// 파이썬 read_lyrics와 같은 규칙: [mm:ss.xx] 줄 시작, 끝은 줄 안 마지막 <..> 태그 또는 다음 줄 시작(마지막 줄은 +5초)
let lrc = try String(contentsOfFile: args[4], encoding: .utf8)
var texts: [String] = []
var times: [(Double?, Double?)] = []
let lineTag = try NSRegularExpression(pattern: #"^\s*\[(\d+:\d+(?:\.\d+)?)\]"#)
let wordTag = try NSRegularExpression(pattern: #"<(\d+:\d+(?:\.\d+)?)>"#)
let anyTag = try NSRegularExpression(pattern: #"\[[^\]]*\]|<\d+:\d+(?:\.\d+)?>"#)
for raw in lrc.components(separatedBy: .newlines) {
    let ns = raw as NSString
    var text = anyTag.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    text = text.replacingOccurrences(of: #"^\s*v\d+:"#, with: "", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { continue }
    let start = lineTag.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)).map { seconds(ns.substring(with: $0.range(at: 1))) }
    let end = wordTag.matches(in: raw, range: NSRange(location: 0, length: ns.length)).last.map { seconds(ns.substring(with: $0.range(at: 1))) }
    texts.append(text)
    times.append((start, end))
}
for i in times.indices where times[i].1 == nil {
    if let s = times[i].0 { times[i].1 = (i + 1 < times.count ? times[i + 1].0 : nil) ?? s + 5 }
}
let lines = zip(texts, times).map { CTCAligner.Line(text: $0.0, start: $0.1.0, end: $0.1.1) }

let separatorConfig = MLModelConfiguration()
separatorConfig.computeUnits = .all
let alignerConfig = MLModelConfiguration()
alignerConfig.computeUnits = .cpuAndGPU
let separator = try MLModel(contentsOf: URL(fileURLWithPath: args[1]), configuration: separatorConfig)
let alignerModel = try MLModel(contentsOf: URL(fileURLWithPath: args[2]), configuration: alignerConfig)
let pipeline = AlignerPipeline(separator: separator, aligner: alignerModel)
var lastPrint = Date.distantPast
pipeline.progress = { stage, value in
    if Date().timeIntervalSince(lastPrint) > 2 || value >= 1 {
        print("\(stage) \(Int(value * 100))%")
        lastPrint = Date()
    }
}

// 중간값도 함께 남긴다(파이썬 기준과 단계별로 비교)
let t0 = Date()
let mix = try AlignerPipeline.loadStereo44k(URL(fileURLWithPath: args[3]))
let vocals = try pipeline.separate(mix)
let tSep = Date().timeIntervalSince(t0)
let mono = (0..<vocals[0].count).map { (vocals[0][$0] + vocals[1][$0]) / 2 }
let rms = stride(from: 0, to: mono.count, by: 4410).map { i -> Double in
    let seg = mono[i..<min(i + 4410, mono.count)]
    return sqrt(seg.reduce(0) { $0 + Double($1 * $1) } / Double(seg.count))
}
let mono16 = try AlignerPipeline.resampleMono(vocals, from: 44100, to: 16000)
let (lp, frames) = try pipeline.emissions(mono16)
let tEm = Date().timeIntervalSince(t0) - tSep
let argmax = (0..<frames).map { t -> Int in
    var best = 0
    for v in 1..<AlignerTokenizer.vocabSize where lp[t * AlignerTokenizer.vocabSize + v] > lp[t * AlignerTokenizer.vocabSize + best] { best = v }
    return best
}
let (voiced, db) = VoicingDetector.detect(mono16)
let words = CTCAligner.align(lp: lp, frames: frames, vocab: AlignerTokenizer.vocabSize, voiced: voiced, db: db, lines: lines)
let total = Date().timeIntervalSince(t0)
print(String(format: "separate %.1fs, emissions %.1fs, total %.1fs, frames %d, samples16k %d", tSep, tEm, total, frames, mono16.count))

struct Debug: Codable {
    var vocals_rms_100ms: [Double]
    var argmax: [Int]
    var frames: Int
    var voiced: String
    var seconds: [String: Double]
}
struct Out: Codable {
    var words: [AlignedWord]
    var debug: Debug
    var ttml: String
}
let out = Out(words: words,
              debug: Debug(vocals_rms_100ms: rms, argmax: argmax, frames: frames,
                           voiced: String(voiced.map { $0 ? "1" : "0" }),
                           seconds: ["separate": tSep, "emissions": tEm, "total": total]),
              ttml: AlignedTTML.build(words, lineCount: lines.count))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(out).write(to: URL(fileURLWithPath: args[5]))
print("ok \(words.filter { $0.start != nil }.count)/\(words.count) words")
