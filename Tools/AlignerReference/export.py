"""정렬 결과(json) → Tune이 읽는 음절 싱크 .lrc(enhanced) / .ttml

LRC: [줄]<음절>for<음절>ev<음절>er <단어 끝><다음 단어>... (lrc.red·Mornye와 같은 꼴)
     단어 사이 공백은 앞 음절 글자에 붙이고, 끝 시각만 있는 빈 태그로 "목소리가 멈춘 때"를 적는다.
TTML: 음절마다 <span begin end>, 단어 사이에만 공백.
"""
import json
import sys
from xml.sax.saxutils import escape


def lrc_t(t):
    m, s = divmod(max(0.0, t), 60)
    return f"{int(m):02d}:{s:06.3f}"


def ttml_t(t):
    m, s = divmod(max(0.0, t), 60)
    return f"{int(m)}:{s:06.3f}"


def by_line(data):
    lines = [[] for _ in data["lines"]]
    for w in data["words"]:
        if w["start"] is not None:
            lines[w["line"]].append(w)
    return [ws for ws in lines if ws]


def to_lrc(data, title="", artist=""):
    out = [f"[ti:{title}]", f"[ar:{artist}]", "[by:Tune syllable aligner]", ""]
    for ws in by_line(data):
        s = f"[{lrc_t(ws[0]['start'])}]"
        for i, w in enumerate(ws):
            for k, sy in enumerate(w["syl"]):
                text = sy["text"] + (" " if k == len(w["syl"]) - 1 and i < len(ws) - 1 else "")
                s += f"<{lrc_t(sy['start'])}>{text}"
            nxt = ws[i + 1]["start"] if i + 1 < len(ws) else None
            if nxt is None or nxt - w["end"] > 0.02:
                s += f"<{lrc_t(w['end'])}>"
        out.append(s)
    return "\n".join(out) + "\n"


def to_ttml(data):
    body = []
    for ws in by_line(data):
        words = []
        for w in ws:
            words.append("".join(
                f'<span begin="{ttml_t(s["start"])}" end="{ttml_t(s["end"])}">{escape(s["text"])}</span>'
                for s in w["syl"]))
        body.append(f'      <p begin="{ttml_t(ws[0]["start"])}" end="{ttml_t(ws[-1]["end"])}">{" ".join(words)}</p>')
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" '
            'itunes:timing="Word" xml:lang="und">\n  <body>\n    <div>\n'
            + "\n".join(body) + "\n    </div>\n  </body>\n</tt>\n")


if __name__ == "__main__":
    src, prefix, title, artist = sys.argv[1:5]
    data = json.load(open(src))
    open(prefix + ".lrc", "w").write(to_lrc(data, title, artist))
    open(prefix + ".ttml", "w").write(to_ttml(data))
