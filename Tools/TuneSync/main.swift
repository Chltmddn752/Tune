import AVFoundation
import CoreML
import Foundation

// tune-sync: 컴퓨터(Mac)에서 음악 폴더의 곡들을 한꺼번에 분석해 정확한 단어(음절) 싱크를 만든다.
// 곡마다 옆에 같은 이름의 .ttml을 남기고, Tune은 이 파일을 다른 가사보다 먼저 쓴다.
//
//   ./tune-sync <폴더나 파일…> [--force] [--no-internet] [--dry-run]
//
// 가사는 곡 옆 .lrc/.ttml → 파일 안 가사 → LRCLIB 순서로 찾는다. 이미 만든 곡은 건너뛴다(--force면 다시).
// 만들고 나면 원래 가사 파일(같은 이름의 .lrc)은 지운다. --force로 다시 만들 땐 만들어 둔 .ttml을 원본으로 쓴다.

setvbuf(stdout, nil, _IONBF, 0)

let version = "1"
let modelTag = "aligner-models-v3"
let releaseBase = URL(string: "https://github.com/Chltmddn752/Tune/releases/download/\(modelTag)/")!

var inputs: [String] = []
var force = false, internet = true, dryRun = false
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--force": force = true
    case "--no-internet": internet = false
    case "--dry-run": dryRun = true
    case "-h", "--help":
        print("""
        tune-sync \(version) — 음악 폴더의 곡에 정확한 단어 싱크(.ttml)를 만들어 곡 옆에 저장해요.

          ./tune-sync <폴더나 파일…> [--force] [--no-internet] [--dry-run]

          --force        이미 만든 곡도 다시 만들어요
          --no-internet  LRCLIB에서 가사를 찾지 않아요(곡 옆 가사 파일·파일 안 가사만)
          --dry-run      무엇을 할지만 보여 줘요
        """)
        exit(0)
    default: inputs.append(arg)
    }
}
guard !inputs.isEmpty else {
    print("사용법: ./tune-sync <음악 폴더> [--force] [--no-internet] [--dry-run]   (--help로 자세히)")
    exit(2)
}

// 한글 로마자 표는 실행 파일 옆 hangul_roman.txt
let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
if ProcessInfo.processInfo.environment["TUNE_HANGUL_TABLE"] == nil {
    setenv("TUNE_HANGUL_TABLE", executableDir.appendingPathComponent("hangul_roman.txt").path, 1)
}
if AlignerTokenizer.hangulTable.count != 11172 {
    print("⚠️  hangul_roman.txt를 찾지 못했어요. tune-sync와 같은 폴더에 두세요(한국어 노래를 맞출 수 없어요).")
}

// MARK: 모델

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("TuneSync/\(modelTag)", isDirectory: true)

func compiled(_ name: String) -> URL { supportDir.appendingPathComponent("\(name).mlmodelc", isDirectory: true) }

func download(_ url: URL, to target: URL) async throws {
    for attempt in 0..<3 {
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: target)
            return
        } catch {
            if attempt == 2 { throw error }
            try await Task.sleep(for: .seconds(2 * (attempt + 1)))
        }
    }
}

func ensureModels() async throws {
    let fm = FileManager.default
    for name in ["VocalSeparator", "LyricsAligner"] where !fm.fileExists(atPath: compiled(name).path) {
        print("모델 받는 중: \(name)\(name == "LyricsAligner" ? " (약 350MB)" : "")…")
        let package = supportDir.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        try? fm.removeItem(at: package)
        for (asset, path) in [("\(name).Manifest.json", "Manifest.json"),
                              ("\(name).model.mlmodel", "Data/com.apple.CoreML/model.mlmodel"),
                              ("\(name).weight.bin", "Data/com.apple.CoreML/weights/weight.bin")] {
            try await download(releaseBase.appendingPathComponent(asset), to: package.appendingPathComponent(path))
        }
        print("이 Mac에 맞게 준비하는 중…")
        let out = try await MLModel.compileModel(at: package)
        try? fm.removeItem(at: compiled(name))
        try fm.moveItem(at: out, to: compiled(name))
        try? fm.removeItem(at: package)
    }
}

// MARK: 가사 찾기

struct LRCLIBResponse: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
}

func lrclib(title: String, artist: String, album: String, duration: Double) async -> (String, String)? {
    func get(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("TuneSync/\(version) (personal music player)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
    var c = URLComponents(string: "https://lrclib.net/api/get")!
    c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                    .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration.rounded())))]
    if let data = await get(c.url), let r = try? JSONDecoder().decode(LRCLIBResponse.self, from: data) {
        if let s = r.syncedLyrics, !s.isEmpty { return (s, "lrc") }
    }
    var s = URLComponents(string: "https://lrclib.net/api/search")!
    s.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
    guard let data = await get(s.url), let results = try? JSONDecoder().decode([LRCLIBResponse].self, from: data) else { return nil }
    let matching = results.filter { r in
        guard duration > 0, let length = r.duration, length > 0 else { return true }
        return abs(length - duration) <= 3
    }
    if let synced = matching.first(where: { $0.syncedLyrics?.isEmpty == false })?.syncedLyrics { return (synced, "lrc") }
    if let plain = results.first(where: { $0.plainLyrics?.isEmpty == false })?.plainLyrics { return (plain, "plain") }
    return nil
}

/// (가사, 어디서 찾았는지)
func findLyrics(for audio: URL) async -> (Lyrics, String)? {
    let base = audio.deletingPathExtension()
    for ext in ["ttml", "lrc"] {
        let url = base.appendingPathExtension(ext)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if ext == "ttml", AlignerLyrics.isGenerated(raw), !force { continue }
        if let l = LyricsParser.parse(raw, format: ext, estimateWords: false), !l.lines.isEmpty || !l.plainText.isEmpty {
            return (l, "곡 옆 .\(ext)")
        }
    }
    let meta = await MetadataReader.read(url: audio)
    if let raw = meta.lyrics, let l = LyricsParser.parse(raw, format: "lrc", estimateWords: false),
       !l.lines.isEmpty || !l.plainText.isEmpty {
        // 파일 안 가사가 시간 없는 가사면 인터넷에서 시간 맞춘 가사를 먼저 찾아 본다.
        if l.isSynced || !internet { return (l, "파일 안 가사") }
        if let found = await internetLyrics(meta, audio: audio), found.0.isSynced { return found }
        return (l, "파일 안 가사(시간 없음)")
    }
    guard internet else { return nil }
    return await internetLyrics(meta, audio: audio)
}

func internetLyrics(_ meta: TrackMetadata, audio: URL) async -> (Lyrics, String)? {
    var title = meta.title ?? "", artist = meta.artist ?? meta.albumArtist ?? ""
    if title.isEmpty {  // "가수 - 제목" 파일 이름
        let name = audio.deletingPathExtension().lastPathComponent
        let parts = name.components(separatedBy: " - ")
        if parts.count >= 2 { artist = artist.isEmpty ? parts[0] : artist; title = parts.dropFirst().joined(separator: " - ") } else { title = name }
    }
    guard !title.isEmpty, let (raw, format) = await lrclib(title: title, artist: artist, album: meta.album ?? "", duration: meta.duration),
          let l = LyricsParser.parse(raw, format: format, estimateWords: false) else { return nil }
    return (l, format == "lrc" ? "LRCLIB" : "LRCLIB(시간 없음)")
}

// MARK: 곡 목록

var files: [URL] = []
for input in inputs {
    let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { print("없는 경로: \(input)"); continue }
    if isDir.boolValue {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let f = e?.nextObject() as? URL {
            if MetadataReader.audioExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
        }
    } else {
        files.append(url)
    }
}
files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
let todo = files.filter { f in
    if force { return true }
    guard let raw = try? String(contentsOf: AlignerLyrics.sidecarURL(for: f), encoding: .utf8) else { return true }
    return !AlignerLyrics.isGenerated(raw)
}
print("곡 \(files.count)개 중 \(todo.count)개를 만들어요\(files.count > todo.count ? " (\(files.count - todo.count)개는 이미 만듦)" : "")")
if dryRun {
    for f in todo { print("  \(f.lastPathComponent)") }
    exit(0)
}
guard !todo.isEmpty else { exit(0) }

do { try await ensureModels() } catch {
    print("모델을 받지 못했어요: \(error.localizedDescription)")
    exit(1)
}
let separatorConfig = MLModelConfiguration()
separatorConfig.computeUnits = .all
let alignerConfig = MLModelConfiguration()
alignerConfig.computeUnits = .cpuAndGPU
let pipeline: AlignerPipeline
do {
    pipeline = AlignerPipeline(separator: try MLModel(contentsOf: compiled("VocalSeparator"), configuration: separatorConfig),
                               aligner: try MLModel(contentsOf: compiled("LyricsAligner"), configuration: alignerConfig))
} catch {
    print("모델을 열지 못했어요: \(error.localizedDescription)")
    exit(1)
}

// MARK: 실행

var made = 0, noLyrics: [String] = [], failed: [String] = []
let started = Date()
for (index, file) in todo.enumerated() {
    let name = file.deletingPathExtension().lastPathComponent
    let head = "[\(index + 1)/\(todo.count)] \(name)"
    guard let (lyrics, from) = await findLyrics(for: file), let input = AlignerLyrics.prepare(lyrics) else {
        print("\(head) — 가사가 없어서 건너뜀")
        noLyrics.append(name)
        continue
    }
    var lastShown = -1
    pipeline.progress = { stage, value in
        let overall: Double = switch stage {
        case .separating: value * 0.6
        case .listening: 0.6 + value * 0.35
        case .aligning: 0.95 + value * 0.05
        }
        let percent = Int(overall * 100) / 10 * 10
        if percent != lastShown { lastShown = percent; print("\r\(head) — \(from) · \(percent)%", terminator: "") }
    }
    do {
        let output = try autoreleasepool { try pipeline.run(audioURL: file, lines: input.lines, sourceWords: input.sourceWords) }
        let timed = output.words.filter { $0.start != nil }
        guard !timed.isEmpty else { throw AlignerError.model("가사와 목소리를 맞추지 못했어요") }
        let ttml = AlignedTTML.build(output.words, lineCount: input.lines.count, background: input.background)
        guard AlignerLyrics.writeSidecar(ttml, for: file) else { throw AlignerError.audio("곡 옆에 .ttml을 쓰지 못했어요(폴더 권한 확인)") }
        let sure = timed.filter { $0.fallback == nil && $0.conf >= AlignerConfig.unsureConfidence }.count
        print("\r\(head) — \(from) · 완료 \(String(format: "%.0f", output.seconds))초 · 잘 들린 단어 \(sure * 100 / max(1, output.words.count))%")
        made += 1
    } catch {
        print("\r\(head) — 실패: \(error.localizedDescription)")
        failed.append(name)
    }
}

let minutes = Int(Date().timeIntervalSince(started) / 60)
print("\n끝! \(made)곡 만듦 · 가사 없음 \(noLyrics.count)곡 · 실패 \(failed.count)곡 · \(minutes)분")
if !noLyrics.isEmpty { print("가사가 없던 곡: " + noLyrics.prefix(20).joined(separator: ", ") + (noLyrics.count > 20 ? " …" : "")) }
if !failed.isEmpty { print("실패한 곡: " + failed.prefix(20).joined(separator: ", ")) }
