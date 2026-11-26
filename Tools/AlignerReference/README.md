# 단어 싱크 정렬기 — 파이썬 기준 구현과 모델 변환

앱의 Swift 정렬기(`Tune/Services/Aligner`)는 여기 파이썬 코드와 같은 결과를 내도록 옮긴 것이다.

| 파일 | 하는 일 |
|---|---|
| `mdx_np.py` | UVR-MDX-NET-Voc_FT 보컬 분리(STFT n_fft 7680, hop 1024, overlap 0.25). `AlignerPipeline.separate`의 기준 |
| `align.py` | MMS-300m 강제 정렬 + 음절·끝 시간 + 못 알아들은 구간 고치기. `--swift`는 앱과 같은 방식(34초 고정 입력, YIN) |
| `voicing_yin.py` | YIN 목소리 판정(threshold 0.4, -55dB). `VoicingDetector`의 기준 |
| `export.py` | 결과 JSON → 음절 단위 enhanced LRC / TTML |
| `convert_mdx.py` | ONNX → Core ML(fp16) `VocalSeparator.mlpackage` |
| `convert_mms.py` | Hugging Face `MahmoudAshraf/mms-300m-1130-forced-aligner` → Core ML(fp16 연산, int8 가중치) `LyricsAligner.mlpackage` |

`Tune/Resources/hangul_roman.txt`는 uroman으로 한글 11,172자를 로마자로 바꾼 표다(모델이 배운 글자와 같아야 한다).

모델은 릴리스 `aligner-models-v1`에 올려 두고 앱이 처음 한 번 받는다. `.github/workflows/aligner-test.yml`이 macOS에서 같은 모델로 Swift 코드를 돌려 파이썬 결과와 비교한다.
