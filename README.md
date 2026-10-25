# Tune

내 음악 파일을 Apple Music처럼 재생하는 아이폰·아이패드 앱 (SwiftUI, iOS 26.1+).

## 빌드
`main`에 푸시하면 GitHub Actions(macOS 26)가 XcodeGen으로 프로젝트를 만들고 서명 없는 `Tune.ipa`를 빌드해 Releases에 올린다. SideStore로 설치한다.

## 구조
- `Tune/App` 앱 시작, 탭, 화면 이동
- `Tune/Player` 재생 엔진(AVQueuePlayer), 잠금화면, 재생 기록
- `Tune/Library` SwiftData 모델, 파일 가져오기, 태그·커버 읽기
- `Tune/Services` 가사(LRC/TTML/LRCLIB), 아티스트 사진(Deezer)
- `Tune/Features` 홈·보관함·통계·검색·앨범·아티스트·플레이리스트·재생 화면·설정
- `TuneWidgets` 홈·잠금화면 위젯
- `Shared` 앱과 위젯이 같이 쓰는 코드
