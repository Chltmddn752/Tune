# tune-sync — Mac에서 보관함 전체 정확한 단어 싱크 만들기

Tune 앱의 '정확한 단어 싱크 만들기'와 같은 코드·모델을 Mac에서 돌려, 곡마다 옆에 같은 이름의 `.ttml`을 만들어요.
Tune은 이 파일을 다른 어떤 가사보다 먼저 써요(앱을 지우거나 가사를 다시 받아도 그대로).

## 준비 (한 번만)

macOS 15 이상, Apple 실리콘 Mac.

```sh
cd ~/Downloads
curl -L -o tune-sync.zip https://github.com/Chltmddn752/Tune/releases/download/tune-sync/tune-sync.zip
unzip -o tune-sync.zip && cd tune-sync
```

터미널의 curl로 받으면 "확인되지 않은 개발자" 경고가 뜨지 않아요. 브라우저로 받았다면 `xattr -dr com.apple.quarantine .`

## 실행

```sh
./tune-sync "음악 폴더 경로"
```

- 처음 한 번 분석 모델(약 390MB)을 받아요.
- 가사는 곡 옆 `.lrc`/`.ttml` → 파일 안 가사 → LRCLIB 순서로 찾아요. 가사를 못 찾은 곡은 건너뛰고 끝에 목록을 보여 줘요.
- 이미 만든 곡은 건너뛰니까, 중간에 멈춰도(⌃C) 다시 실행하면 이어서 해요. 처음부터 다시: `--force`
- 곡 옆에 원래 있던 `.ttml`은 `이름.original.ttml`로 옮겨 두고 가사 원본으로 써요.

## 음악 폴더가 어디 있나요

- **연결한 폴더(iCloud Drive 등)**: Mac의 Finder에서 그 폴더를 그대로 넣으면 돼요. 만든 `.ttml`이 iCloud로 iPad·iPhone에 동기화돼요.
- **Tune 앱 안(나의 iPad/iPhone › Tune)**: 기기를 Mac에 연결 → Finder에서 기기 › 파일 › Tune 폴더를 Mac으로 복사 →
  `tune-sync` 실행 → 생긴 `.ttml` 파일들을 같은 자리로 다시 끌어다 놓아요(곡 파일과 이름이 같아야 해요).
