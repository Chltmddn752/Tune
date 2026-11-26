import AVFoundation
import Accelerate
import CoreMedia
import CoreML
import Foundation

// 곡 파일 → 보컬 분리(Core ML) → 16kHz 보컬 → MMS 글자 확률(Core ML) + 목소리 판정 → 정렬.
// UI와 상관없는 부분이라 앱과 시험용 명령줄 도구(Tools/AlignerCLI)가 같이 쓴다.

enum AlignerError: LocalizedError {
    case audio(String)
    case model(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .audio(let message): "곡을 읽지 못했어요: \(message)"
        case .model(let message): "모델을 실행하지 못했어요: \(message)"
        case .cancelled: "멈췄어요"
        }
    }
}

enum AlignerStage: Equatable {
    case separating
    case listening
    case aligning
}

final class AlignerPipeline {
    let separator: MLModel
    let aligner: MLModel
    /// (단계, 0…1)
    var progress: ((AlignerStage, Double) -> Void)?
    var isCancelled: () -> Bool = { false }
    /// 진단용 기록(시험 도구에서만 씀)
    var debugLog: ((String) -> Void)?

    init(separator: MLModel, aligner: MLModel) {
        self.separator = separator
        self.aligner = aligner
    }

    struct Output {
        var words: [AlignedWord]
        var seconds: Double
    }

    /// 전체 실행. lines: 정렬할 가사 줄(줄 시간이 있으면 그 근처에서만 찾는다).
    func run(audioURL: URL, lines: [CTCAligner.Line], sourceWords: [(Double, Double)?]?) throws -> Output {
        let started = Date()
        // 큰 배열(원곡·보컬 44.1kHz)은 다 쓰면 바로 놓아 준다(정렬 모델을 돌릴 때 메모리가 모자라지 않게).
        let mono16: [Float] = try {
            let vocals = try separate(try Self.loadStereo44k(audioURL))
            return try Self.resampleMono(vocals, from: 44100, to: Double(AlignerConfig.sampleRate))
        }()
        let (lp, frames) = try emissions(mono16)
        if isCancelled() { throw AlignerError.cancelled }
        progress?(.aligning, 0)
        let (voiced, db) = VoicingDetector.detect(mono16)
        let words = CTCAligner.align(lp: lp, frames: frames, vocab: AlignerTokenizer.vocabSize,
                                     voiced: voiced, db: db, lines: lines, sourceWords: sourceWords)
        progress?(.aligning, 1)
        return Output(words: words, seconds: Date().timeIntervalSince(started))
    }

    // MARK: 오디오

    /// 44.1kHz 스테레오 Float32 [왼쪽, 오른쪽].
    /// 재생과 같은 AVFoundation 디코더(AVAssetReader)로 읽는다. AAC(m4a)를 AVAudioFile로 한 번에 읽으면
    /// 'wht?'(2003334207) 오류가 나는 파일이 있어서, 그때만 AVAudioFile로 조금씩 읽는 방법으로 다시 해 본다.
    static func loadStereo44k(_ url: URL) throws -> [[Float]] {
        do {
            return try readWithAssetReader(url)
        } catch let first {
            do { return try readWithAudioFile(url) } catch { throw first }
        }
    }

    private static func readWithAssetReader(_ url: URL) throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw AlignerError.audio("오디오 트랙이 없어요") }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AlignerError.audio(error.localizedDescription) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AlignerError.audio("디코더를 만들지 못했어요") }
        reader.add(output)
        guard reader.startReading() else { throw AlignerError.audio(reader.error?.localizedDescription ?? "읽기 시작 실패") }
        var left: [Float] = [], right: [Float] = []
        let expected = Int(max(0, asset.duration.seconds) * 44100) + 44100
        left.reserveCapacity(expected)
        right.reserveCapacity(expected)
        var chunk: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            if chunk.count < count { chunk = [Float](repeating: 0, count: count) }
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            var i = 0
            while i + 1 < count {
                left.append(chunk[i])
                right.append(chunk[i + 1])
                i += 2
            }
        }
        if reader.status == .failed { throw AlignerError.audio(reader.error?.localizedDescription ?? "디코딩 실패") }
        guard !left.isEmpty else { throw AlignerError.audio("소리가 없어요") }
        return [left, right]
    }

    /// AVAudioFile로 10초씩 읽어서 44.1kHz 스테레오로 바꾼다.
    private static func readWithAudioFile(_ url: URL) throws -> [[Float]] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AlignerError.audio(error.localizedDescription) }
        let input = file.processingFormat
        let block = AVAudioFrameCount(input.sampleRate * 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: block) else { throw AlignerError.audio("메모리") }
        var channels = [[Float]](repeating: [], count: Int(input.channelCount))
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: block) } catch {
                if channels[0].isEmpty { throw AlignerError.audio(error.localizedDescription) }
                break  // 끝부분에서만 나는 오류는 읽은 데까지 쓴다
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for c in channels.indices {
                channels[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: n))
            }
        }
        if channels.count == 1 { channels.append(channels[0]) }
        var stereo = Array(channels.prefix(2))
        if input.sampleRate != 44100 {
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 2, interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false),
                  let whole = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(stereo[0].count))
            else { throw AlignerError.audio("형식") }
            whole.frameLength = AVAudioFrameCount(stereo[0].count)
            for c in 0..<2 { stereo[c].withUnsafeBufferPointer { whole.floatChannelData![c].update(from: $0.baseAddress!, count: $0.count) } }
            let out = try convert(whole, to: target)
            stereo = (0..<2).map { Array(UnsafeBufferPointer(start: out.floatChannelData![$0], count: Int(out.frameLength))) }
        }
        return stereo
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { throw AlignerError.audio("변환기") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AlignerError.audio("메모리") }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw AlignerError.audio(error?.localizedDescription ?? "변환") }
        return out
    }

    /// 스테레오 → 모노 평균 → 16kHz
    static func resampleMono(_ stereo: [[Float]], from rate: Double, to target: Double) throws -> [Float] {
        let n = stereo[0].count
        var mono = [Float](repeating: 0, count: n)
        vDSP_vasm(stereo[0], 1, stereo[1], 1, [0.5], &mono, 1, vDSP_Length(n))
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n))
        else { throw AlignerError.audio("형식") }
        buffer.frameLength = AVAudioFrameCount(n)
        mono.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        let out = try convert(buffer, to: outFormat)
        let expected = Int((Double(n) * target / rate).rounded())
        var result = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        if result.count > expected { result.removeLast(result.count - expected) }
        while result.count < expected { result.append(0) }
        return result
    }

    // MARK: 보컬 분리 (UVR-MDX-NET-Voc_FT)

    func separate(_ mix: [[Float]]) throws -> [[Float]] {
        let chunk = MDXSpectrogram.chunk, trim = MDXSpectrogram.nFFT / 2
        let gen = chunk - 2 * trim
        let n = mix[0].count
        let pad = gen + trim - (n % gen)
        let total = trim + n + pad
        let step = Int(0.75 * Double(chunk))
        // 앞에 trim만큼, 뒤에 pad만큼 0을 붙인 것처럼 읽는다(큰 배열을 하나 덜 만든다).
        func sample(_ c: Int, _ i: Int) -> Float { i >= trim && i < trim + n ? mix[c][i - trim] : 0 }
        var result = [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)
        var divider = [Float](repeating: 0, count: total)

        let spec = MDXSpectrogram()
        let dimF = MDXSpectrogram.dimF, dimT = MDXSpectrogram.dimT
        let plane = dimF * dimT
        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: dimF), NSNumber(value: dimT)], dataType: .float32)
        let starts = Array(stride(from: 0, to: total, by: step))
        var part = [Float](repeating: 0, count: chunk)

        for (index, start) in starts.enumerated() {
            if isCancelled() { throw AlignerError.cancelled }
            // Core ML 출력은 autorelease 객체라, 조각마다 풀어 주지 않으면 곡 하나 동안 계속 쌓인다.
            try autoreleasepool {
            let end = min(start + chunk, total)
            let actual = end - start
            let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
            for c in 0..<2 {
                for i in 0..<chunk { part[i] = i < actual ? sample(c, start + i) : 0 }
                part.withUnsafeBufferPointer { spec.stft($0, real: ptr + (2 * c) * plane, imag: ptr + (2 * c + 1) * plane) }
            }
            // 가장 낮은 3개 bin은 0으로 (UVR과 같음)
            for ch in 0..<4 { for f in 0..<3 { for t in 0..<dimT { ptr[ch * plane + f * dimT + t] = 0 } } }

            let output: MLFeatureProvider
            do {
                output = try separator.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: input)]))
            } catch { throw AlignerError.model(error.localizedDescription) }
            guard let vocals = output.featureValue(for: "vocals")?.multiArrayValue else { throw AlignerError.model("출력 없음") }
            if index == 0 { debugLog?("vocals shape \(vocals.shape) strides \(vocals.strides) type \(vocals.dataType.rawValue)") }
            let y = Self.floats(vocals, count: 4 * plane)

            let window = MDXSpectrogram.hanning(actual)
            for c in 0..<2 {
                let wave = y.withUnsafeBufferPointer { yp in
                    spec.istft(real: yp.baseAddress! + (2 * c) * plane, imag: yp.baseAddress! + (2 * c + 1) * plane)
                }
                for i in 0..<actual { result[c][start + i] += wave[i] * window[i] }
            }
            for i in 0..<actual { divider[start + i] += window[i] }
            }
            progress?(.separating, Double(index + 1) / Double(starts.count))
        }
        var vocals = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        for c in 0..<2 {
            for i in 0..<n {
                let d = divider[trim + i]
                vocals[c][i] = d > 0 ? result[c][trim + i] / d : result[c][trim + i]
            }
        }
        return vocals
    }

    /// MLMultiArray(Float32 또는 Float16) → 연속된 [Float].
    /// GPU에서 나온 출력은 마지막 축이 정렬 때문에 덧대어져(stride > 크기) 있을 수 있어 stride를 따라 읽는다.
    static func floats(_ array: MLMultiArray, count: Int) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let total = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: min(count, total))
        func read(_ offset: Int) -> Float {
            switch array.dataType {
            case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
            case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
            case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
            default: return array[offset].floatValue
            }
        }
        var index = [Int](repeating: 0, count: shape.count)
        for i in 0..<out.count {
            var offset = 0
            for d in 0..<shape.count { offset += index[d] * strides[d] }
            out[i] = read(offset)
            var d = shape.count - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return out
    }

    /// 행마다 log_softmax (Float32로 계산해 아주 작은 확률도 -inf가 되지 않게)
    static func logSoftmax(_ x: inout [Float], rows: Int, cols: Int) {
        for r in 0..<rows {
            let base = r * cols
            var m = -Float.greatestFiniteMagnitude
            for c in 0..<cols where x[base + c].isFinite { m = max(m, x[base + c]) }
            var sum: Float = 0
            for c in 0..<cols where x[base + c].isFinite { sum += exp(x[base + c] - m) }
            let lse = m + log(sum)
            for c in 0..<cols { x[base + c] = x[base + c].isFinite ? x[base + c] - lse : -1e4 }
        }
    }

    // MARK: 글자 확률 (MMS-300m forced aligner)

    /// 30초씩(앞뒤 2초 겹침, 34초 고정 입력) → [프레임 × 31] log 확률
    func emissions(_ audio: [Float]) throws -> ([Float], Int) {
        let sr = AlignerConfig.sampleRate
        let win = 30 * sr, ctx = 2 * sr, fixed = win + 2 * ctx
        let vocab = AlignerTokenizer.vocabSize
        let input = try MLMultiArray(shape: [1, NSNumber(value: fixed)], dataType: .float32)
        var out: [Float] = []
        var frames = 0
        let starts = Array(stride(from: 0, to: audio.count, by: win))
        for (index, start) in starts.enumerated() {
            if isCancelled() { throw AlignerError.cancelled }
            try autoreleasepool {
            let a0 = max(0, start - ctx), a1 = min(audio.count, start + win + ctx)
            let count = a1 - a0
            var mean: Double = 0
            for i in a0..<a1 { mean += Double(audio[i]) }
            mean /= Double(count)
            var variance: Double = 0
            for i in a0..<a1 { let d = Double(audio[i]) - mean; variance += d * d }
            let std = sqrt(variance / Double(count)) + 1e-7
            let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<fixed { ptr[i] = i < count ? Float((Double(audio[a0 + i]) - mean) / std) : 0 }
            let output: MLFeatureProvider
            do {
                output = try aligner.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)]))
            } catch { throw AlignerError.model(error.localizedDescription) }
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else { throw AlignerError.model("출력 없음") }
            let modelFrames = logits.shape[1].intValue
            if index == 0 { debugLog?("logits shape \(logits.shape) strides \(logits.strides) type \(logits.dataType.rawValue)") }
            var all = Self.floats(logits, count: modelFrames * vocab)
            Self.logSoftmax(&all, rows: modelFrames, cols: vocab)
            let f0 = Int((Double(start - a0) / Double(AlignerConfig.hop)).rounded(.toNearestOrEven))
            let n = Int((Double(min(start + win, audio.count) - start) / Double(AlignerConfig.hop)).rounded(.toNearestOrEven))
            let take = max(0, min(n, modelFrames - f0))
            out.append(contentsOf: all[(f0 * vocab)..<((f0 + take) * vocab)])
            frames += take
            }
            progress?(.listening, Double(index + 1) / Double(starts.count))
        }
        return (out, frames)
    }
}
