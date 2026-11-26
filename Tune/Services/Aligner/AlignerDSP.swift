import Accelerate
import Foundation

// 보컬 분리용 STFT/역STFT와 목소리 판정(YIN). 파이썬 기준 구현(mdx_np.py, voicing_yin.py)과 같은 계산.

/// UVR-MDX-NET-Voc_FT 입력 형식: n_fft 7680, hop 1024, 3072 bin × 256 프레임
final class MDXSpectrogram {
    static let nFFT = 7680
    static let hop = 1024
    static let dimF = 3072
    static let dimT = 256
    static let chunk = hop * (dimT - 1)  // 261,120 샘플(약 5.9초)
    static let bins = nFFT / 2 + 1       // 3841

    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    /// periodic Hann
    let window: [Float]
    private var inR = [Float](repeating: 0, count: nFFT)
    private var inI = [Float](repeating: 0, count: nFFT)
    private var outR = [Float](repeating: 0, count: nFFT)
    private var outI = [Float](repeating: 0, count: nFFT)

    init() {
        let n = Self.nFFT
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// x(길이 chunk) → 실수·허수 [dimF × dimT] (행 = 주파수). torch.stft(center=True, reflect)와 같음.
    func stft(_ x: UnsafeBufferPointer<Float>, real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        let n = Self.nFFT, p = n / 2, len = x.count
        func padded(_ i: Int) -> Float {
            let j = i - p
            if j < 0 { return x[-j] }
            if j >= len { return x[2 * (len - 1) - j] }
            return x[j]
        }
        for t in 0..<Self.dimT {
            let base = t * Self.hop
            for k in 0..<n {
                inR[k] = padded(base + k) * window[k]
                inI[k] = 0
            }
            vDSP_DFT_Execute(forward, inR, inI, &outR, &outI)
            for f in 0..<Self.dimF {
                real[f * Self.dimT + t] = outR[f]
                imag[f * Self.dimT + t] = outI[f]
            }
        }
    }

    /// 실수·허수 [dimF × dimT] → 길이 chunk 파형. 3072 bin 위는 0. torch.istft(center=True)와 같음.
    func istft(real: UnsafePointer<Float>, imag: UnsafePointer<Float>) -> [Float] {
        let n = Self.nFFT, p = n / 2
        let total = n + Self.hop * (Self.dimT - 1)
        var out = [Float](repeating: 0, count: total)
        var norm = [Float](repeating: 0, count: total)
        let scale = 1 / Float(n)
        for t in 0..<Self.dimT {
            for k in 0..<n { inR[k] = 0; inI[k] = 0 }
            for f in 0..<Self.dimF {
                inR[f] = real[f * Self.dimT + t]
                inI[f] = imag[f * Self.dimT + t]
            }
            inI[0] = 0  // irfft는 DC 허수부를 무시한다
            for f in 1..<Self.dimF {  // 켤레 대칭으로 나머지 절반을 채운다
                inR[n - f] = inR[f]
                inI[n - f] = -inI[f]
            }
            vDSP_DFT_Execute(inverse, inR, inI, &outR, &outI)
            let base = t * Self.hop
            for k in 0..<n {
                out[base + k] += outR[k] * scale * window[k]
                norm[base + k] += window[k] * window[k]
            }
        }
        var result = [Float](repeating: 0, count: Self.chunk)
        for i in 0..<Self.chunk {
            let v = norm[p + i]
            result[i] = v > 1e-11 ? out[p + i] / v : out[p + i]
        }
        return result
    }

    /// numpy.hanning(m) (양 끝이 0인 대칭 창)
    static func hanning(_ m: Int) -> [Float] {
        guard m > 1 else { return [1] }
        return (0..<m).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(m - 1)) }
    }
}

/// YIN으로 20ms마다 '목소리 있음'과 세기(dB, 곡 최대 기준)
enum VoicingDetector {
    static let frameLength = 1024
    static let tauMin = 16000 / 1100  // 14
    static let tauMax = 16000 / 70    // 228

    static func detect(_ audio: [Float], threshold: Float = 0.4, gateDB: Float = -55) -> (voiced: [Bool], db: [Float]) {
        let pad = frameLength / 2, hop = AlignerConfig.hop
        var x = [Float](repeating: 0, count: audio.count + 2 * pad)
        x.replaceSubrange(pad..<(pad + audio.count), with: audio)
        let n = 1 + (x.count - frameLength) / hop
        let W = frameLength - tauMax
        var voiced = [Bool](repeating: false, count: n)
        var db = [Float](repeating: 0, count: n)
        var d = [Float](repeating: 0, count: tauMax + 1)
        var cm = [Float](repeating: 1, count: tauMax + 1)
        x.withUnsafeBufferPointer { xp in
            for i in 0..<n {
                let f = xp.baseAddress! + i * hop
                var ms: Float = 0
                vDSP_measqv(f, 1, &ms, vDSP_Length(frameLength))
                db[i] = 20 * log10(sqrt(ms) + 1e-10)
                // d(τ) = Σ a² + Σ b_τ² − 2 Σ a·b_τ   (j < W)
                var aa: Float = 0
                vDSP_svesq(f, 1, &aa, vDSP_Length(W))
                for t in 0...tauMax {
                    var bb: Float = 0, ab: Float = 0
                    vDSP_svesq(f + t, 1, &bb, vDSP_Length(W))
                    vDSP_dotpr(f, 1, f + t, 1, &ab, vDSP_Length(W))
                    d[t] = max(0, aa + bb - 2 * ab)
                }
                var cum: Float = 0
                cm[0] = 1
                for t in 1...tauMax {
                    cum += d[t]
                    cm[t] = cum > 0 ? d[t] * Float(t) / cum : 1
                }
                var k = tauMin
                var found = false
                while k <= tauMax {
                    if cm[k] < threshold { found = true; break }
                    k += 1
                }
                if found {
                    while k + 1 <= tauMax && cm[k + 1] < cm[k] { k += 1 }
                    voiced[i] = true
                }
            }
        }
        let maxDB = db.max() ?? 0
        for i in 0..<n {
            db[i] -= maxDB
            if db[i] <= gateDB { voiced[i] = false }
        }
        // 짧은 끊김(≤3프레임)은 메우고, 1~2프레임짜리 섬은 지운다
        var i = 0
        while i < n {
            if !voiced[i] {
                var j = i
                while j < n && !voiced[j] { j += 1 }
                if i > 0 && j < n && j - i <= 3 { for k in i..<j { voiced[k] = true } }
                i = j
            } else { i += 1 }
        }
        i = 0
        while i < n {
            if voiced[i] {
                var j = i
                while j < n && voiced[j] { j += 1 }
                if j - i <= 2 { for k in i..<j { voiced[k] = false } }
                i = j
            } else { i += 1 }
        }
        return (voiced, db)
    }
}
