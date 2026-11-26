"""pYIN 대신 Swift로 옮기기 쉬운 YIN 기반 '목소리 있음' 판정 (20ms 간격).
librosa.pyin(center=True, frame 1024, hop 320, 16kHz)과 같은 프레임 위치를 쓴다."""
import numpy as np

SR, FRAME_LEN, HOP = 16000, 1024, 320
TAU_MIN, TAU_MAX = SR // 1100, SR // 70  # 14 .. 228


def yin_voicing(audio, thresh=0.2, gate_db=-45):
    pad = FRAME_LEN // 2
    x = np.pad(audio.astype(np.float64), (pad, pad))
    n = 1 + (len(x) - FRAME_LEN) // HOP
    W = FRAME_LEN - TAU_MAX
    voiced = np.zeros(n, bool)
    cmnd_min = np.ones(n)
    rms = np.zeros(n)
    for i in range(n):
        f = x[i * HOP:i * HOP + FRAME_LEN]
        rms[i] = np.sqrt(np.mean(f * f))
        a = f[:W]
        # d(τ) = Σ (x_j − x_{j+τ})²,  j < W
        d = np.array([np.sum((a - f[t:t + W]) ** 2) for t in range(TAU_MAX + 1)])
        cum = np.cumsum(d[1:])
        cm = np.ones(TAU_MAX + 1)
        cm[1:] = d[1:] * np.arange(1, TAU_MAX + 1) / np.where(cum > 0, cum, 1)
        seg = cm[TAU_MIN:TAU_MAX + 1]
        below = np.nonzero(seg < thresh)[0]
        if len(below):
            k = below[0]
            while k + 1 < len(seg) and seg[k + 1] < seg[k]:
                k += 1
            cmnd_min[i] = seg[k]
            voiced[i] = True
        else:
            cmnd_min[i] = seg.min()
    db = 20 * np.log10(rms + 1e-10)
    db -= db.max()
    voiced &= db > gate_db
    # 짧은 끊김(≤3프레임) 메우고, 1~2프레임짜리 섬은 지운다
    v = voiced.copy()
    i = 0
    while i < n:
        if not v[i]:
            j = i
            while j < n and not v[j]:
                j += 1
            if 0 < i and j < n and j - i <= 3:
                v[i:j] = True
            i = j
        else:
            i += 1
    i = 0
    while i < n:
        if v[i]:
            j = i
            while j < n and v[j]:
                j += 1
            if j - i <= 2:
                v[i:j] = False
            i = j
        else:
            i += 1
    return v, db
