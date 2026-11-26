"""UVR-MDX-NET-Voc_FT 보컬 분리를 numpy만으로 (Swift로 옮길 기준 구현).
audio-separator의 demix(overlap 0.25, hop 1024, segment 256)와 같은 결과를 내야 한다.

STFT: n_fft 7680, hop 1024, periodic Hann, center=True(reflect pad), 앞 3072 bin만 모델에 넣는다.
모델 입력 [1, 4, 3072, 256] = (왼쪽 실수, 왼쪽 허수, 오른쪽 실수, 오른쪽 허수)
"""
import sys
import numpy as np

N_FFT, HOP, DIM_F, DIM_T = 7680, 1024, 3072, 256
CHUNK = HOP * (DIM_T - 1)          # 261120 샘플(약 5.9초)
TRIM = N_FFT // 2                   # 3840
OVERLAP = 0.25
WIN = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)  # periodic Hann


def stft(x):
    """x: [CHUNK] → [n_bins, DIM_T] complex (torch.stft center=True, reflect)."""
    p = N_FFT // 2
    xp = np.pad(x, (p, p), mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(xp, N_FFT)[::HOP][:DIM_T]
    return np.fft.rfft(frames * WIN, axis=1).T


def istft(spec, length):
    """spec: [n_bins, DIM_T] → [length] (torch.istft center=True: window²로 나눈다)."""
    frames = np.fft.irfft(spec.T, n=N_FFT, axis=1) * WIN
    total = N_FFT + HOP * (spec.shape[1] - 1)
    out = np.zeros(total)
    norm = np.zeros(total)
    for t in range(spec.shape[1]):
        out[t * HOP:t * HOP + N_FFT] += frames[t]
        norm[t * HOP:t * HOP + N_FFT] += WIN ** 2
    p = N_FFT // 2
    out, norm = out[p:p + length], norm[p:p + length]
    return out / np.where(norm > 1e-11, norm, 1)


def run_chunk(model, chunk):
    """chunk: [2, CHUNK] → [2, CHUNK] 보컬"""
    spec = np.stack([stft(chunk[c]) for c in range(2)])          # [2, bins, T]
    x = np.stack([spec[0].real, spec[0].imag, spec[1].real, spec[1].imag])[:, :DIM_F]  # [4, 3072, 256]
    x[:, :3, :] = 0
    y = model(x[None].astype(np.float32))[0]                    # [4, 3072, 256]
    bins = N_FFT // 2 + 1
    full = np.zeros((4, bins, DIM_T), np.float32)
    full[:, :DIM_F] = y
    left = full[0] + 1j * full[1]
    right = full[2] + 1j * full[3]
    return np.stack([istft(left, CHUNK), istft(right, CHUNK)])


def separate(mix, model, progress=None):
    """mix: [2, N] 44.1kHz → 보컬 [2, N]"""
    n = mix.shape[1]
    gen = CHUNK - 2 * TRIM
    pad = gen + TRIM - (n % gen)
    mixture = np.concatenate([np.zeros((2, TRIM)), mix, np.zeros((2, pad))], 1)
    step = int((1 - OVERLAP) * CHUNK)
    result = np.zeros_like(mixture)
    divider = np.zeros_like(mixture)
    starts = list(range(0, mixture.shape[1], step))
    for k, start in enumerate(starts):
        end = min(start + CHUNK, mixture.shape[1])
        actual = end - start
        part = mixture[:, start:end]
        if actual < CHUNK:
            part = np.concatenate([part, np.zeros((2, CHUNK - actual))], 1)
        out = run_chunk(model, part)
        w = np.hanning(actual)
        result[:, start:end] += out[:, :actual] * w
        divider[:, start:end] += w
        if progress:
            progress(k + 1, len(starts))
    res = result / np.where(divider > 0, divider, 1)
    return res[:, TRIM:TRIM + n]


if __name__ == "__main__":
    import onnxruntime as ort
    import soundfile as sf
    src, out, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0
    sess = ort.InferenceSession(sys.argv[4] if len(sys.argv) > 4 else "models/UVR-MDX-NET-Voc_FT.onnx")
    model = lambda x: sess.run(None, {"input": x})[0]
    mix, sr = sf.read(src, dtype="float32")
    mix = mix.T
    if seconds:
        mix = mix[:, :int(seconds * sr)]
    voc = separate(mix, model, lambda a, b: print(f"{a}/{b}", end="\r", file=sys.stderr))
    sf.write(out, voc.T, sr)
