"""Swift 정렬 결과를 파이썬 기준 결과와 비교한다(표준 라이브러리만 사용).
python3 compare.py swift_out.json ref_aligned.json ref_debug.json"""
import json
import math
import sys

swift = json.load(open(sys.argv[1]))
ref = json.load(open(sys.argv[2]))["words"]
dbg = json.load(open(sys.argv[3]))
sd = swift["debug"]
ok = True


def pct(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(p / 100 * len(v)))] if v else float("nan")


# 1) 보컬 분리: 0.1초 RMS의 상관계수
a, b = sd["vocals_rms_100ms"], dbg["vocals_rms_100ms"]
n = min(len(a), len(b))
ma, mb = sum(a[:n]) / n, sum(b[:n]) / n
cov = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
corr = cov / math.sqrt(sum((x - ma) ** 2 for x in a[:n]) * sum((x - mb) ** 2 for x in b[:n]))
scale = mb / ma if ma else 0
print(f"separation: rms correlation {corr:.4f}, level ratio ref/swift {scale:.3f}")
ok &= corr > 0.98

# 2) 글자 확률: 프레임별 최고 글자 일치율
fa, fb = sd["argmax"], dbg["argmax"]
print(f"emissions: frames swift {len(fa)} ref {len(fb)}")
n = min(len(fa), len(fb))
agree = sum(fa[i] == fb[i] for i in range(n)) / n
print(f"emissions: argmax agreement {agree:.4f}")
ok &= abs(len(fa) - len(fb)) <= 2 and agree > 0.97

# 3) 목소리 판정
va, vb = sd["voiced"], dbg["voiced"]
n = min(len(va), len(vb))
vagree = sum(va[i] == vb[i] for i in range(n)) / n
print(f"voicing: agreement {vagree:.4f} (frames {len(va)} vs {len(vb)})")
ok &= vagree > 0.9

# 4) 최종 단어 시간
sw = swift["words"]
print(f"words: swift {len(sw)} ref {len(ref)}")
ok &= len(sw) == len(ref)
ds, de = [], []
for x, y in zip(sw, ref):
    if x["start"] is None or y["start"] is None:
        continue
    ds.append(abs(x["start"] - y["start"]))
    de.append(abs(x["end"] - y["end"]))
print(f"word start diff: median {pct(ds, 50)*1000:.0f}ms p90 {pct(ds, 90)*1000:.0f}ms max {max(ds)*1000:.0f}ms")
print(f"word end diff:   median {pct(de, 50)*1000:.0f}ms p90 {pct(de, 90)*1000:.0f}ms max {max(de)*1000:.0f}ms")
ok &= pct(ds, 50) <= 0.03 and pct(ds, 90) <= 0.1
print("seconds:", sd["seconds"])
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
