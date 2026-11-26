"""가사 단어·음절 싱크 정렬기 (실험용)

보컬만 분리한 오디오 + 가사 텍스트 → 음절마다 시작·끝 시간.
1) MMS-300m forced aligner(1130개 언어, 로마자 글자 단위 CTC)로 강제 정렬 → 음절 시작
2) 보컬 음높이(pYIN)와 세기로 "목소리가 실제로 이어지는 동안"을 찾아 → 길게 끄는 음의 끝

사용: python align.py vocals.wav lyrics.txt out_prefix [--lang eng|kor] [--no-source] [--no-anchor]
lyrics.txt: 한 줄에 가사 한 줄. [mm:ss.xx] 줄 시간이 있으면 그 근처(±1초)에서만 찾는다.
"""
import hashlib
import json
import os
import re
import sys
import unicodedata

import librosa
import numpy as np
import soundfile as sf
import torch
from transformers import Wav2Vec2ForCTC

MODEL = "MahmoudAshraf/mms-300m-1130-forced-aligner"
SR = 16000
FRAME = 0.02  # wav2vec2 한 프레임 = 20ms
HOP = 320     # 음높이·세기도 같은 20ms 간격으로 본다


# ---------- 가사 읽기 ----------

def clean_line(line):
    line = re.sub(r"\[[^\]]*\]", "", line)
    line = re.sub(r"<\d+:\d+(?:\.\d+)?>", "", line)
    line = re.sub(r"^\s*v\d+:", "", line)
    return line.strip()


def _sec(tag):
    m, x = tag.split(":")
    return int(m) * 60 + float(x)


def read_lyrics(path):
    """가사 줄과 (있으면) 줄 시작·끝 시간."""
    lines, times = [], []
    for raw in open(path, encoding="utf-8"):
        line = clean_line(raw)
        if not line:
            continue
        m = re.match(r"\s*\[(\d+:\d+(?:\.\d+)?)\]", raw)
        tags = re.findall(r"<(\d+:\d+(?:\.\d+)?)>", raw)
        lines.append(line)
        times.append([_sec(m.group(1)) if m else None, _sec(tags[-1]) if tags else None])
    if all(t[0] is None for t in times):
        return lines, None
    for i, t in enumerate(times):
        if t[1] is None:
            t[1] = times[i + 1][0] if i + 1 < len(times) and times[i + 1][0] else t[0] + 5
    return lines, times


def read_source_words(path):
    """이미 단어 시간이 있는 LRC(Musixmatch·lrc.red 등)면 단어마다 (시작, 끝). 음절 조각은 합친다."""
    res = []
    for raw in open(path, encoding="utf-8"):
        if not clean_line(raw):
            continue
        parts = re.findall(r"<(\d+:\d+(?:\.\d+)?)>([^<]*)", raw.strip())
        cur, line_words = None, []
        for t, txt in parts:
            if txt == "":
                if cur:
                    cur[1] = _sec(t)
                continue
            if cur is None:
                cur = [_sec(t), None]
            if txt.endswith(" "):
                line_words.append(cur)
                cur = None
        if cur:
            line_words.append(cur)
        for k, w in enumerate(line_words):
            if w[1] is None and k + 1 < len(line_words):
                w[1] = line_words[k + 1][0]
        n_words = len(clean_line(raw).split())
        if len(line_words) != n_words:
            line_words = [None] * n_words
        res.extend(tuple(w) if w and w[1] else None for w in line_words)
    return res if any(res) else None


# ---------- 음절 나누기 ----------

_pyphen = None


def syllables(word):
    """한글은 글자마다, 영어는 하이픈 사전(pyphen)으로. 이어 붙이면 원래 단어가 된다."""
    global _pyphen
    if re.search(r"[가-힣]", word):
        out = []
        for ch in word:
            if re.match(r"[가-힣]", ch) or not out:
                out.append(ch)
            else:
                out[-1] += ch  # 문장부호는 앞 글자에 붙인다
        return out
    if re.search(r"\d", word):
        return [word]
    if _pyphen is None:
        import pyphen
        _pyphen = pyphen.Pyphen(lang="en_US")
    out = []
    for chunk in re.findall(r"[^-]+-?|-", word):  # Ooh-ooh-ooh → Ooh- / ooh- / ooh
        core = re.sub(r"\W", "", chunk)
        if "-" in word and len(core) <= 4:  # 감탄사 조각(ooh, hmm, da)은 한 음절
            out.append(chunk.rstrip("-"))
        else:
            out.extend(p for p in _pyphen.inserted(chunk).split("-") if p)
        if chunk.endswith("-"):
            out[-1] += "-"
    # pyphen이 하이픈을 지워서 길이가 달라졌으면 단어째로
    return out if "".join(out) == word else [word]


_ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def _two(n):
    return _ONES[n] if n < 20 else _TENS[n // 10] + ("" if n % 10 == 0 else " " + _ONES[n % 10])


def number_words(s):
    """영어 노래 속 숫자. 4자리는 연도처럼 읽는다(2085 → twenty eighty five)."""
    n = int(s)
    if len(s) == 4 and n % 100 != 0:
        return _two(n // 100) + " " + _two(n % 100)
    if n < 100:
        return _two(n)
    if n < 1000:
        return _ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + _two(n % 100))
    return " ".join(_ONES[int(c)] for c in s)


_uroman = None


def tokens_of(text, lang, vocab):
    global _uroman
    t = text.replace("’", "'")
    t = re.sub(r"\d+", lambda m: " " + number_words(m.group()) + " ", t)
    if re.search(r"[^\x00-\x7f]", t):
        if _uroman is None:
            import uroman as ur
            _uroman = ur.Uroman()
        t = _uroman.romanize_string(t, lcode=lang)
    t = unicodedata.normalize("NFKD", t).lower()
    return [vocab[c] for c in t if c in vocab and c not in "<>"]


# ---------- 음향 ----------

def emissions(model, audio):
    """30초 창(앞뒤 2초 겹침)으로 나눠 log-softmax를 이어 붙인다."""
    win, ctx = 30 * SR, 2 * SR
    outs = []
    with torch.inference_mode():
        for start in range(0, len(audio), win):
            a0, a1 = max(0, start - ctx), min(len(audio), start + win + ctx)
            chunk = torch.from_numpy(audio[a0:a1]).float()[None]
            chunk = (chunk - chunk.mean()) / (chunk.std() + 1e-7)
            lp = torch.log_softmax(model(chunk).logits[0], -1).numpy()
            f0 = round((start - a0) / SR / FRAME)
            n = round((min(start + win, len(audio)) - start) / SR / FRAME)
            outs.append(lp[f0:f0 + n])
    return np.concatenate(outs)


def voicing(audio):
    """20ms마다 (목소리 있음 여부, 세기 dB). 길게 끄는 음의 끝을 찾을 때 쓴다."""
    _, voiced, prob = librosa.pyin(audio, fmin=70, fmax=1100, sr=SR, frame_length=1024, hop_length=HOP)
    rms = librosa.feature.rms(y=audio, frame_length=1024, hop_length=HOP)[0]
    db = librosa.amplitude_to_db(rms, ref=np.max)
    n = min(len(voiced), len(db))
    return voiced[:n], db[:n]


def ctc_viterbi(lp, tokens, blank=0, lo=None, hi=None):
    """CTC 강제 정렬. 상태: blank, t1, blank, t2, ..., blank (2L+1개).
    lo/hi가 있으면 토큰마다 그 프레임 범위 안에서만 나올 수 있다."""
    T, L = lp.shape[0], len(tokens)
    S = 2 * L + 1
    labels = np.full(S, blank)
    labels[1::2] = tokens
    skip = np.zeros(S, bool)
    for s in range(3, S, 2):
        skip[s] = labels[s] != labels[s - 2]
    NEG = -1e30
    s_lo, s_hi = np.zeros(S, int), np.full(S, T)
    if lo is not None:
        s_lo[1::2], s_hi[1::2] = lo, hi
    alpha = np.full(S, NEG)
    alpha[0] = lp[0, blank]
    alpha[1] = lp[0, labels[1]]
    back = np.zeros((T, S), np.int8)
    idx = np.arange(S)
    for t in range(1, T):
        one = np.concatenate([[NEG], alpha[:-1]])
        two = np.where(skip, np.concatenate([[NEG, NEG], alpha[:-2]]), NEG)
        stack = np.stack([alpha, one, two])
        choice = stack.argmax(0)
        allowed = (t >= s_lo) & (t <= s_hi)
        alpha = stack[choice, idx] + np.where(allowed, lp[t, labels], NEG)
        back[t] = choice
    s = S - 1 if alpha[S - 1] >= alpha[S - 2] else S - 2
    path = np.empty(T, np.int32)
    for t in range(T - 1, -1, -1):
        path[t] = s
        s -= int(back[t, s])
    return path, labels


# ---------- 정렬 ----------

def emissions_fixed(model, audio):
    """Swift(Core ML)과 같은 방식: 34초 고정 입력, 짧은 조각은 정규화 뒤 0으로 채운다."""
    win, ctx = 30 * SR, 2 * SR
    fix = win + 2 * ctx
    outs = []
    with torch.inference_mode():
        for start in range(0, len(audio), win):
            a0, a1 = max(0, start - ctx), min(len(audio), start + win + ctx)
            c = audio[a0:a1]
            c = (c - c.mean()) / (c.std() + 1e-7)
            buf = np.zeros(fix, np.float32)
            buf[:len(c)] = c
            lp = torch.log_softmax(model(torch.from_numpy(buf)[None]).logits[0], -1).numpy()
            f0 = round((start - a0) / SR / FRAME)
            n = round((min(start + win, len(audio)) - start) / SR / FRAME)
            outs.append(lp[f0:f0 + n])
    return np.concatenate(outs)


def align(vocals_path, lines, lang="eng", line_times=None, margin=1.0, source_words=None, mode="pyin"):
    model = Wav2Vec2ForCTC.from_pretrained(MODEL, cache_dir="models/hf").eval()
    audio, sr = sf.read(vocals_path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(1)
    audio = librosa.resample(audio, orig_sr=sr, target_sr=SR)
    key = hashlib.md5(vocals_path.encode()).hexdigest()[:8]
    if mode == "swift":
        from voicing_yin import yin_voicing
        lp = emissions_fixed(model, audio)
        voiced, db = yin_voicing(audio, 0.4, -55)
    else:
        if os.path.exists(f"cache_{key}.npy"):
            lp = np.load(f"cache_{key}.npy")
        else:
            lp = emissions(model, audio)
            np.save(f"cache_{key}.npy", lp)
        if os.path.exists(f"voice_{key}.npz"):
            z = np.load(f"voice_{key}.npz")
            voiced, db = z["voiced"], z["db"]
        else:
            voiced, db = voicing(audio)
            np.savez(f"voice_{key}.npz", voiced=voiced, db=db)
    return align_core(lp, voiced, db, lines, lang, line_times, margin, source_words)


def align_core(lp, voiced, db, lines, lang="eng", line_times=None, margin=1.0, source_words=None):
    from huggingface_hub import hf_hub_download
    vocab = json.load(open(hf_hub_download(MODEL, "vocab.json", cache_dir="models/hf")))
    T = lp.shape[0]

    # 단어 → 음절 → 토큰
    words, tokens, tok_line = [], [], []
    for li, line in enumerate(lines):
        for w in line.split():
            sy = []
            for piece in syllables(w):
                tk = tokens_of(piece, lang, vocab)
                sy.append(dict(text=piece, tok=(len(tokens), len(tokens) + len(tk))))
                tokens.extend(tk)
                tok_line.extend([li] * len(tk))
            words.append(dict(line=li, word=w, syl=sy))

    lo = hi = None
    if line_times:
        lo = np.array([max(0, int((line_times[l][0] - margin) / FRAME)) for l in tok_line])
        hi = np.array([int((line_times[l][1] + margin) / FRAME) for l in tok_line])
    path, labels = ctc_viterbi(lp, tokens, lo=lo, hi=hi)

    first = np.full(len(tokens), -1)
    last = np.full(len(tokens), -1)
    best = np.full(len(tokens), -1e9)
    for t, s in enumerate(path):
        if s % 2:
            k = s // 2
            if first[k] < 0:
                first[k] = t
            last[k] = t
            best[k] = max(best[k], lp[t, labels[s]])

    # 음절 시작(첫 글자가 처음 나온 프레임)과 소리의 "핵심 끝"(마지막 글자 프레임)
    for w in words:
        confs = []
        for s in w["syl"]:
            a, b = s["tok"]
            if a == b:
                s["f0"] = s["f1"] = None
                continue
            s["f0"], s["f1"] = int(first[a]), int(last[b - 1])
            confs.extend(best[a:b])
        w["conf"] = round(float(np.exp(np.mean(confs))), 3) if confs else 0.0
        # 토큰이 없는 음절(기호 등)은 앞 음절에 붙인다
        good = [s for s in w["syl"] if s["f0"] is not None]
        if not good:
            w["f0"] = None
            continue
        w["f0"], w["f1"] = good[0]["f0"], good[-1]["f1"]

    timed = [w for w in words if w.get("f0") is not None]
    for j, w in enumerate(timed):
        nxt = timed[j + 1]["f0"] if j + 1 < len(timed) else T
        same_line = j + 1 < len(timed) and timed[j + 1]["line"] == w["line"]
        # 단어의 마지막 음절 끝 = 목소리가 실제로 이어지는 마지막 순간.
        # 핵심 끝에서 시작해, 목소리가 있고 세기가 그 음절 최고치에서 18dB 안쪽이면 계속 늘린다.
        # 60ms 이하의 끊김(자음·숨)은 무시한다. 다음 단어 시작은 넘지 않는다.
        lastsyl = [s for s in w["syl"] if s["f0"] is not None][-1]
        peak = db[lastsyl["f0"]:max(lastsyl["f1"] + 1, lastsyl["f0"] + 1)].max() if lastsyl["f0"] < len(db) else 0
        end, gap, t = w["f1"] + 1, 0, w["f1"] + 1
        limit = min(nxt, len(db))
        while t < limit:
            if voiced[t] and db[t] > peak - 18:
                end, gap = t + 1, 0
            else:
                gap += 1
                if gap > 3:
                    break
            t += 1
        if same_line and nxt - end <= 5:  # 100ms 이하 틈은 이어 부른 것으로 본다
            end = nxt
        end = max(end, w["f0"] + 3)
        w["end_f"] = min(end, nxt) if nxt > w["f0"] + 3 else end
        # 음절: 다음 음절 시작까지가 이 음절(모음을 끄는 동안 칠해진다)
        good = [s for s in w["syl"] if s["f0"] is not None]
        for k, s in enumerate(good):
            s["start"] = round(s["f0"] * FRAME, 3)
            s["end"] = round((good[k + 1]["f0"] if k + 1 < len(good) else w["end_f"]) * FRAME, 3)
        merge_empty_syllables(w)
        w["start"], w["end"] = w["syl"][0]["start"], w["syl"][-1]["end"]

    for w in words:
        for s in w["syl"]:
            for k in ("tok", "f0", "f1"):
                s.pop(k, None)
        for k in ("f0", "f1", "end_f"):
            w.pop(k, None)
        w.setdefault("start", None)
        w.setdefault("end", None)

    fix_unsure(words, line_times, source_words)
    return words


def merge_empty_syllables(w):
    out = []
    for s in w["syl"]:
        if "start" not in s:
            if out:
                out[-1]["text"] += s["text"]
            else:
                out.append(s)
            continue
        if out and "start" not in out[-1]:
            s["text"] = out.pop()["text"] + s["text"]
        out.append(s)
    w["syl"] = out


def spread_syllables(w, a, b):
    """단어 시간 [a, b]를 음절 글자 수 비율로 나눈다."""
    sy = w["syl"]
    weights = np.array([max(1, len(re.sub(r"\W", "", s["text"]))) for s in sy], float)
    edges = a + np.concatenate([[0], np.cumsum(weights)]) / weights.sum() * (b - a)
    for s, x, y in zip(sy, edges[:-1], edges[1:]):
        s["start"], s["end"] = round(float(x), 3), round(float(y), 3)
    w["start"], w["end"] = round(a, 3), round(b, 3)


def fix_unsure(words, line_times, source_words=None, thresh=0.01):
    """모델이 거의 못 알아들은 단어(보코더·코러스·허밍)가 몰리거나(70ms 미만) 늘어진(3초 초과) 구간만 고친다.
    원래 가사에 단어 시간이 있으면 그걸 쓰고, 없으면 앞뒤 믿을 만한 단어 사이를 글자 수로 나눈다."""
    n = len(words)
    sure = [w["start"] is not None and w["conf"] >= thresh for w in words]
    i = 0
    while i < n:
        if sure[i]:
            i += 1
            continue
        j = i
        while j < n and not sure[j]:
            j += 1
        run = list(range(i, j))
        durs = [words[k]["end"] - words[k]["start"] for k in run if words[k]["start"] is not None]
        if len(durs) == len(run) and min(durs) >= 0.07 and max(durs) <= 3.0:
            i = j
            continue
        if source_words and all(source_words[k] for k in run):
            for k in run:
                spread_syllables(words[k], *source_words[k])
                words[k]["fallback"] = "source"
        else:
            for li in sorted({words[k]["line"] for k in run}):
                ks = [k for k in run if words[k]["line"] == li]
                lo = line_times[li][0] if line_times else None
                hi = line_times[li][1] if line_times else None
                if ks[0] > 0 and sure[ks[0] - 1] and words[ks[0] - 1]["line"] == li:
                    lo = words[ks[0] - 1]["end"]
                if ks[-1] + 1 < n and sure[ks[-1] + 1] and words[ks[-1] + 1]["line"] == li:
                    hi = words[ks[-1] + 1]["start"]
                if lo is None or hi is None or hi <= lo:
                    continue
                weights = np.array([max(1, len(re.sub(r"\W", "", words[k]["word"]))) for k in ks], float)
                edges = lo + np.concatenate([[0], np.cumsum(weights)]) / weights.sum() * (hi - lo)
                for k, a, b in zip(ks, edges[:-1], edges[1:]):
                    spread_syllables(words[k], float(a), float(b))
                    words[k]["fallback"] = "spread"
        i = j


if __name__ == "__main__":
    vocals, lyr, prefix = sys.argv[1:4]
    lang = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else "eng"
    lines, times = read_lyrics(lyr)
    if "--no-anchor" in sys.argv:
        times = None
    src = None if "--no-source" in sys.argv else read_source_words(lyr)
    res = align(vocals, lines, lang, times, source_words=src, mode="swift" if "--swift" in sys.argv else "pyin")
    json.dump(dict(lines=lines, words=res), open(prefix + ".json", "w"), ensure_ascii=False, indent=1)
    print("ok", len(res), "words", file=sys.stderr)
