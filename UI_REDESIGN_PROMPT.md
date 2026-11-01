# Tune UI 리디자인 프롬프트

**Apple Music의 정보 구조 × Liquid Glass 크롬 / iOS 26.1 SwiftUI**

> **사용법**
> 1. 이 문서 전체를 저장소 루트에서 코딩 에이전트(Claude Code, Cursor, Codex 등)에 붙여넣는다.
> 2. 한 번에 전부 시키지 말고 §15의 Phase 0 → 5 순서로 진행시킨다. 각 Phase 끝에서 빌드와 스크린샷을 확인한다.
> 3. Apple Music 화면 캡처 3장(홈 / 보관함 / 재생)을 함께 첨부하면 결과가 훨씬 좋아진다.
> 4. "리퀴드 디스플레이"는 **Liquid Glass**(iOS 26)로 해석했다. 화면 전체를 유리로 덮는 것이 아니라, Apple HIG대로 **내비게이션·컨트롤 레이어에만** 쓴다. 콘텐츠(표지·텍스트·리스트 행)는 불투명하게 둔다. 유리 위에 유리를 겹치지 않는다.
> 5. 이 문서는 디자인 계약이다. 코드 구조상 불가능한 것(다운로드 속도/남은 시간, 대기열 재정렬, 일시정지)은 구현하지 말고 보고한다.

---

## 0. 역할

너는 iOS 26 SwiftUI 앱의 UI를 다시 설계하는 **시니어 프로덕트 디자이너이자 iOS 엔지니어**다.

대상은 `Tune` — 내 음악 파일을 Apple Music처럼 재생하고, 확장(extension)으로 온라인 음원을 내려받는 한국어 iPhone·iPad 앱이다. 목표는 두 가지다.

1. **Apple Music 수준의 위계와 차분함**을 갖춘 시각 언어로 앱 전체를 통일한다.
2. **다운로드 플로우를 "한 번 탭 + 한눈에 보임"**으로 다시 만든다. 지금은 다운로드가 세 군데에 숨어 있고, 곡마다 음질 메뉴를 골라야 하며, 진행 상황이 설정 화면에만 나온다.

기능을 새로 만들지 않는다. 아키텍처를 갈아엎지 않는다. **있는 기능을 Apple Music의 문법으로 다시 배치하고, 다운로드의 진입·결정·피드백을 단순화한다.**

---

## 1. 제품과 사용자

- **누구**: 자기 음악 파일을 모으는 1인 사용자. 계정·클라우드·구독 없음. SideStore로 설치.
- **무엇**: (A) 보관함의 파일을 재생하는 플레이어, (B) 확장으로 온라인 곡을 찾아 파일로 받는 다운로더.
- **확장**: `.sflx` JavaScriptCore 번들. 레지스트리에서 설치. 두 종류가 있다.
  - **다운로드 가능**: 곡 파일을 실제로 받는다.
  - **정보 전용**: 검색·앨범·아티스트 정보만 준다. 실제 파일은 설치된 다른 다운로드 확장에서 같은 곡을 찾아 받는다.
- **저장**: 받은 파일은 `Tune/다운로드` 폴더에 저장되고 보관함에 자동으로 들어온다.
- **현재 탭**: 홈 · 보관함 · 통계 · 검색. 다운로드는 홈 툴바 아이콘, 검색 툴바 메뉴, 설정 행에 숨어 있다.
- **현재 다운로드 엔진**: `DownloadManager`는 **직렬 큐**다. `enqueue`가 자동으로 시작하고, 한 번에 한 곡만 받는다. 속도·ETA·일시정지·재정렬 API는 없다.
- **현재 UI 테스트**: `TuneUITests`가 특정 한국어 라벨을 검사한다(§부록 C). 라벨을 바꾸면 테스트도 같이 고쳐야 한다.

---

## 2. 성공 기준 (숫자로)

- **첫 설정 이후**, 앱 실행 → 검색 탭 → 검색어 입력 → 결과의 `↓` **1회**로 다운로드가 시작된다. 음질 메뉴, 확인 대화상자, 대기열 화면 방문이 없다.
- **어느 탭에서든** 0.5초 안에 진행 중인 다운로드의 존재를 알 수 있다(탭 배지).
- 다운로드 화면 **한 스크린**에서 "지금 받는 중 / 다음에 받을 것 / 받은 것 / 실패한 것"이 모두 보인다. 세그먼트 전환 없이.
- 화면당 커스텀 글래스 표면은 **최대 3개 클러스터**, 리스트 행 안에는 **0개**.
- `xcodebuild` 빌드 성공. 엔진·모델 파일 diff 0. UI 테스트는 라벨 변경분을 반영하거나, 실행 불가 사유를 보고.

---

## 3. 절대 규칙 (하지 말 것)

1. **엔진·모델을 건드리지 말 것**: `Tune/Player/PlayerEngine.swift`, `Tune/Download/DownloadManager.swift`, `Tune/Download/Extension/*`, `Tune/Download/ProviderClient.swift`, `Tune/Download/MetadataWriter.swift`, `Tune/Library/*`, `Shared/*`, `TuneWidgets/*`. UI가 필요로 하는 읽기 전용 computed property만 예외적으로 추가하고, 동작은 바꾸지 않는다.
2. **기능 삭제 금지**: 통계, 위시리스트, 링크로 찾기, CSV 가져오기, 태그 정리, iPad 재생 패널, 위젯, 수면 타이머, 가사, 볼륨 슬라이더. 전부 남긴다.
3. **의존성·에셋 추가 금지**: 외부 패키지, 웹폰트, 커스텀 이미지 금지. SF Symbols + 시스템 폰트만. 새 이미지가 필요하면 SF Symbol과 `Color(hex:)`로 만든다.
4. **프로젝트 수동 편집 금지**: `Tune.xcodeproj/project.pbxproj`를 손으로 고치지 않는다. 새 파일은 `Tune/` 아래에 두고 `xcodegen generate`로 재생성한다. `project.yml`의 타깃 구조는 유지.
5. **번들 ID·배포 타깃·entitlement·Info.plist 변경 금지**.
6. **한국어 UI 유지**: 새 카피도 해요체. 영어 문자열을 넣지 않는다(시스템 라벨 제외).
7. **글래스 남용 금지**: 리스트 행, 앨범 아트, 텍스트 블록에 `.glassEffect` 금지. `GlassEffectContainer` 밖에서 글래스 위에 글래스 금지. 새 `.ultraThinMaterial` 금지.
8. **없는 정보 만들지 말 것**: 다운로드 속도, ETA, 남은 시간, 병렬 다운로드, 일시정지, 재정렬. `DownloadManager`에 없다.
9. **가짜 데이터 금지**: 프로덕션 뷰에 `#if DEBUG` 데모 데이터를 넣지 않는다. `#Preview`에만 목 데이터를 둔다.
10. **커밋 금지**: 사용자가 요청하기 전에는 `git commit`/`push`하지 않는다. 변경 요약과 스크린샷만 남긴다.
11. **다크/라이트 둘 다**: 한쪽만 확인하고 끝내지 않는다. `ThemeOption`(시스템/라이트/다크)을 존중한다.
12. **iPad를 큰 아이폰으로 만들지 말 것**: `.sidebarAdaptable` TabView, 사이드바 섹션, 오른쪽 재생 패널, 폭 조절 손잡이를 유지한다.

---

## 4. 코드 지도 (먼저 읽을 것)

| 파일 | 지금 하는 일 | 리디자인에서 |
|---|---|---|
| `Tune/App/RootView.swift` | TabView, 상단 배너 3종, iPad 패널, 미니 플레이어 액세서리 | 탭 추가·배지, 선택 액션 바, 토스트 호스트 |
| `Tune/App/Router.swift` | `AppTab`, `Route`, 화면 열기 | `.downloads` 추가, 선택 상태 공유 |
| `Tune/App/AppSettings.swift` | 테마·포인트색·설정 키, `Color.tuneAccent` | 그대로 |
| `Tune/DesignSystem/Theme.swift` | `Spacing`, `Radius`, `Font.tune*`, `Animation.*` | 토큰 확장 |
| `Tune/DesignSystem/Components.swift` | `ArtworkView`, `RemoteArtwork`, `TrackRow`, `AlbumCard`, `FilterChip`, `SectionHeader`, `PlayShuffleButtons`, `EmptyLibraryView` | Apple Music식 행·카드·빈 상태 |
| `Tune/DesignSystem/CollectionComponents.swift` | iPad용 컬렉션 헤더, `WideTrackRow` | 헤더 액션 통일, 글래스 버튼 |
| `Tune/DesignSystem/PlayerComponents.swift` | `ElasticSlider`, `MarqueeText`, `MeshBackground`, `FlowLayout` | 유지, 재생 화면 크롬만 조정 |
| `Tune/Features/Home/HomeView.swift` | 필터 칩, 2열 바로가기, 셸프 | 필터 제거, Apple Music 홈 셸프 |
| `Tune/Features/Library/LibraryView.swift` | 카테고리 행 + 앨범 그리드 | Apple Music 보관함 |
| `Tune/Features/Search/SearchView.swift` | 로컬+온라인 검색, 스코프 칩, 배치 선택 | 한 번 탭 받기, 선택 모드, 프로바이더 메뉴 |
| `Tune/Features/Download/DownloadViews.swift` | `ProviderResultRow`, `DownloadListView`, 진행 카드, 작업 행 | 새 다운로드 화면·버튼으로 분해 |
| `Tune/Features/Download/ProviderScreens.swift` | 온라인 앨범·아티스트·플레이리스트 | 로컬 컬렉션과 같은 헤더·행 |
| `Tune/Features/Download/ExtensionStoreView.swift` | 레지스트리 URL이 맨 위인 List | 스토어 우선, 고급 설정 접기 |
| `Tune/Features/NowPlaying/*` | 전체 재생, 가사, 대기열, 미니 플레이어 | Apple Music 재생 화면 정리 |
| `Tune/Features/Album/AlbumScreen.swift` | 전체 폭 커버 + 색 번짐(이미 Apple Music식) | 기준점으로 삼아 다른 화면을 맞춤 |
| `Tune/Features/Artist/ArtistScreen.swift`, `Playlist/*` | 헤더·트랙 리스트 | 동일 문법으로 통일 |
| `Tune/Features/Settings/SettingsView.swift` | Form 설정, 다운로드 섹션 | 다운로드는 보조로, 기본 음질·확장 |
| `Tune/Features/Stats/*` | 통계 카드·히트맵 | 가벼운 색·카드 정리만 |
| `Tune/Download/DownloadModels.swift` | `DownloadStatus`(대기/받는 중/완료/실패/취소), 작업 필드 | 그대로 |
| `Tune/Download/DownloadManager.swift` | 직렬 큐, 자동 시작, `jobs`/`activeJob`/`lastMessage` | 그대로 |

**읽는 순서**: `README.md` → `project.yml` → `RootView.swift` → `Theme.swift` → `Components.swift` → `DownloadViews.swift` → `ProviderScreens.swift` → `SearchView.swift` → `LibraryView.swift` → `HomeView.swift` → `NowPlayingView.swift`. 읽기 전에 추측하지 말 것.

---

## 5. 현재 UI 진단 (왜 답답한가)

1. **진입점이 세 곳에 흩어져 있다.** 홈 툴바의 `↓` 아이콘, 검색 툴바의 `⋯` 메뉴 안 "다운로드", 설정의 "다운로드" 행. 탭도, 배지도, 상시 진행 표시도 없다.
2. **전제 조건이 숨어 있다.** 다운로드하려면 음원 확장을 먼저 설치해야 하는데, 그 사실은 다운로드 목록의 footer 문구와 설정에서야 나온다. 확장 스토어는 **레지스트리 URL 입력창이 첫 화면**이고, `.sflx`·JavaScriptCore·Mornye 같은 내부 용어가 본문에 있다.
3. **곡마다 음질을 고르게 한다.** 온라인 결과 행의 `↓`를 누르면 `qualityOptions` 메뉴가 열린다. 52pt 행에서 32pt 아이콘을 정확히 눌러야 하고, 결정을 한 번 더 해야 한다. 음질은 **한 번 정하는 기본값**이어야 한다.
4. **내부 사정이 UI에 노출된다.** "정보 전용", "다운로드 확장에서 찾기", "다른 확장에서 같은 곡을 찾아 받아요", "어느 확장에서 받을까요?" — 사용자는 확장이 두 종류라는 사실을 몰라도 된다.
5. **배치 선택이 리스트 안에 숨었다.** "여러 곡 한 번에 받기"를 눌러야 선택 모드가 되고, 하단 바는 `.ultraThinMaterial` + 진한 액센트 캡슐이라 Apple Music과 따로 논다. 선택 진입은 내비게이션 바의 `선택`이어야 한다.
6. **다운로드 목록이 상태의 모음이 아니라 작업 로그다.** "받는 중 / 대기열 / 완료 / 받지 못한 곡" 4개 섹션 + "묶어 보기" 세그먼트 + 완료 행의 재생 아이콘. 한 화면에서 전체 상태를 읽기 어렵고, 완료 항목이 보관함과 중복된다.
7. **전역 피드백이 없다.** 진행 중인 작업은 설정 화면에 들어가야 보인다. `DownloadManager.lastMessage`("이미 대기열에 있어요")는 화면에 뜨지 않는다. 완료 토스트도 없다.
8. **화면마다 문법이 다르다.** 로컬 `AlbumView`는 전체 폭 커버 + 색 번짐으로 이미 Apple Music식인데, 온라인 앨범/아티스트/플레이리스트는 190pt 커버 + `title2` 헤더 + 번호/행 혼합으로 따로 만든 화면처럼 보인다.
9. **보관함이 설정 목록처럼 보인다.** 카테고리 행은 Apple Music과 유사하지만, 아이콘 색이 전부 액센트이고 행 높이·구분선·그리드 간격이 촘촘하다.
10. **홈에 필터 칩이 있다.** "전체/앨범/플레이리스트/아티스트" 칩이 셸프 구조와 같은 일을 두 번 한다. Apple Music 홈에는 이런 필터가 없다.
11. **글래스가 시스템이 아니라 장식이다.** 배너 3종에 `.glassEffect()`, 재생 화면 두 곳에 `.glass`, 홈 타일·배치 바·확장 로딩 캡슐에 `.ultraThinMaterial`. 컨테이너·모프·일관된 계층이 없다.
12. **용어가 흔들린다.** 받기/다운로드/내려받기, 확장/음원 확장/다운로드 확장, 정보 전용/정보, 대기열/받는 중.
13. **접근성**: 다운로드 아이콘 32×32, 상태를 아이콘 모양과 색으로만 전달, 큰 글자에서 큰 제목이 잘릴 수 있음, 선택 상태가 색뿐.
14. **통계**는 카드·히트맵·다색 차트가 자체 완결적이라 Apple Music 문법과 무관하다. 기능은 건드리지 않고 색·카드만 정리한다.

---

## 6. 레퍼런스에서 가져올 것

| 앱 | 가져올 것 | 가져오지 말 것 |
|---|---|---|
| **Apple Music** (주 레퍼런스) | 홈 셸프, 보관함 카테고리+그리드, 검색의 상위 결과/장르 타일, 앨범 전체 폭 커버, 재생 화면, 미니 플레이어, 큰 제목·여백·타이포 | Apple Music 레드, 애플 뮤직 전용 탭(라디오/새 음악)을 억지로 흉내 내기 |
| **Spotify** | 다운로드 상태를 라이브러리의 필터/아이콘으로 표현, 음질은 설정에서 한 번, 대기열은 별도 화면 | 초록색, 과한 그라데이션, 카드 중첩 |
| **YouTube Music** | 곡 옆 한 번 탭 다운로드, 기본 음질, "다운로드" 자동 재생목록 | 빨간색, 하단 시트 남발 |
| **Apple Podcasts** | 에피소드별 진행 링(다운로드 중), "다운로드됨" 상태 | 팟캐스트 특유의 에피소드 카드 |
| **파일 앱** | 전송 목록의 재시도·지우기·실패 사유 | 파일 브라우저 UI |

색은 전부 `Color.tuneAccent`와 앨범 색으로 번역한다.

---

## 7. 디자인 원칙

1. **콘텐츠가 먼저, 크롬은 떠 있다.** 표지·제목·목록이 주인공. 글래스는 탭 바, 미니 플레이어, 떠 있는 액션, 재생 컨트롤에만.
2. **한 화면에 한 가지 결정.** 재생 화면은 재생, 다운로드 화면은 받기/관리, 검색은 찾기. 결정을 두 번 시키지 않는다.
3. **다운로드는 한 번 탭, 음질은 한 번 설정.** 기본 음질은 확장별 설정. 예외는 롱프레스 메뉴.
4. **상태는 항상 보인다.** 탭 배지(진행 수) + 다운로드 화면 히어로 + 완료/실패 토스트.
5. **Apple Music의 위계를 따른다.** 큰 제목 → 큰 표지 → 제목/아티스트 → 메타 → 액션 → 트랙 리스트. 여백 20/24pt, 섹션 22pt bold, 행 17pt.
6. **Liquid Glass는 내비게이션 레이어의 재료다.** 콘텐츠 카드는 불투명. 유리 위 유리 금지. 한 영역에 한 클러스터.
7. **색은 절제.** 배경은 중성, 앨범 색은 상단 워시, 액센트는 "지금 재생/선택/받기"에만.
8. **카피는 동사 우선, 짧게.** "받기", "다시 받기", "받는 중 62%". 내부 용어는 고급 설정으로.
9. **모션은 변화를 설명한다.** 0.25–0.35초, `.smooth` 기본. 완료에만 가벼운 바운스. Reduce Motion 존중.
10. **iPad는 별도 레이아웃.** 사이드바 + 재생 패널. iPhone을 늘리지 않는다.

---

## 8. 디자인 토큰

### 8.1 색

- 배경: `Color(.systemBackground)`. 콘텐츠 카드/보조 면: `Color(.secondarySystemBackground)`. 입력/칩 비선택: `Color(.tertiarySystemFill)`.
- 액센트: `Color.tuneAccent` — **현재 재생 곡, 선택 상태, 받기 진행, 링크**에만. 큰 배경 금지.
- 앨범 색: `Color(hex: album.colorHex)` — 앨범/재생 화면 상단 워시(불투명도 0.35–0.55), 홈 바로가기 타일 배경.
- 상태: 진행=액센트, 대기=secondary, 완료=액센트(체크), 실패=`.red`는 **텍스트/아이콘에만**, 취소=secondary.
- 다크/라이트 모두 대비 4.5:1 이상. 흰 텍스트는 스크림(검정 0.35–0.55) 위에서만.

### 8.2 타이포 (Dynamic Type)

| 역할 | 스타일 | 비고 |
|---|---|---|
| 탭 큰 제목 | `.largeTitle.bold()` 34 | 스크롤과 함께 접히는 기본 large title |
| 아티스트 이름 | `.largeTitle.heavy()` 34 | 2줄, `minimumScaleFactor(0.6)` |
| 섹션 제목 | `.title2.bold()` 22 | "최근 추가", "받은 음악" |
| 재생 화면 제목 | `.title3.semibold()` 20 | 마퀴 |
| 곡 제목/본문 | `.body` 17 | 1–2줄 |
| 아티스트/부제 | `.subheadline` 15 | secondary |
| 메타/캡션 | `.footnote` 13 | tertiary |
| 시간 | `.caption` 12, monospacedDigit, semibold | |

- 텍스트에 `.system(size:)` 고정값 금지(글리프 제외). 기존 `Font.tune*`을 우선 사용하고 필요한 것만 추가.
- 큰 글자(AX3)에서 2줄 허용, 핵심 정보는 자르지 않는다.

### 8.3 여백·반경

- 여백: 4 / 8 / 12 / 16 / 20 / 24 / 32. 화면 좌우 20(iPhone), 24(iPad). 섹션 간 28–32.
- 행 최소 높이 52, 다운로드/곡 행 56. 아이콘 버튼 히트 영역 44×44.
- 표지 반경: 리스트 6, 카드 8, 큰 카드 12, 재생 10. 글래스는 캡슐 또는 연속 곡률 20–26.
- 그리드: iPhone 2열(간격 16, 행 간 24), iPad `adaptive(minimum: 170)`.

### 8.4 Liquid Glass

- **자동**: 시스템 탭 바, 내비게이션 바, 시트, 미니 플레이어 액세서리. 직접 다시 칠하지 않는다.
- **커스텀 허용처**: 상단 토스트, 재생 화면의 닫기/좋아요/더 보기/가사·대기열 칩, 배치 선택 바, 검색 스코프의 선택 칩, 온라인 프로바이더 메뉴 버튼.
- **금지**: 리스트 행, 앨범 아트, 카드, 폼, 통계 카드, 설정 행.
- 변형: 기본 `.regular`. 이미지 위에만 `.clear` + 스크림. 선택/주요 액션에 `.tint(.tuneAccent)`. 누르는 것은 `.interactive()`.
- 버튼은 가능하면 `.buttonStyle(.glass)` / `.glassProminent` + `.buttonBorderShape(.circle)`.
- 2개 이상 붙은 커스텀 글래스는 `GlassEffectContainer(spacing: 8–16)` + `.glassEffectID(_, in:)`로 묶는다.
- 화면당 커스텀 글래스 클러스터 최대 3개. 리스트 안 `ForEach`에서 `.glassEffect` 금지.
- Reduce Transparency에서 시스템이 대체하게 두고, 커스텀 글래스에는 불투명 폴백을 둔다.

### 8.5 그림자·스크림

- 표지 그림자: 검정 0.08–0.18, radius 8–20, y 4–10. 글래스에는 그림자 금지.
- 큰 표지 위 텍스트: 상단/하단 검정 그라데이션 스크림. 색 번짐은 `LinearGradient` 3-stop.
- `MeshBackground`는 재생 화면 전용. 다른 화면에 메시 그라데이션 금지.

### 8.6 모션·햅틱

- 기본 `.smooth(duration: 0.28)`, 스냅 `.snappy(duration: 0.22)`. 완료에만 `.bouncy(duration: 0.35, extraBounce: 0.15)`.
- 재생 화면 열기/닫기: 기존 `matchedTransitionSource` + `.navigationTransition(.zoom)` 유지.
- 진행률: `contentTransition(.numericText())`, 링은 `.trim` 애니메이션 0.35.
- 심볼: `.contentTransition(.symbolEffect(.replace))`. 완료 체크는 `.symbolEffect(.bounce)` 1회.
- 햅틱: 칩 선택 `.selection`, 받기 시작 `.impact(weight: .light)`, 완료 `.success`, 실패 `.warning`(포그라운드일 때만).
- Reduce Motion: 메시·마퀴·바운스 정지, 페이드만.

---

## 9. 정보 구조

### 9.1 탭 (iPhone)

| 지금 | 바꿀 것 |
|---|---|
| 홈 / 보관함 / 통계 / 검색 | **홈 / 다운로드 / 보관함 / 통계 / 검색** |

- 검색은 마지막, `Tab(role: .search)` 유지.
- 다운로드 탭에 `.badge(activeCount)` — `queued + running` 수. 0이면 배지 없음. 접근성 라벨은 "다운로드, 2곡 받는 중".
- iPad: `.sidebarAdaptable` 유지. 최상위 "다운로드" 탭 + 기존 "보관함" 섹션(최근 추가/아티스트/앨범/노래/장르/좋아요) + "플레이리스트" 섹션 + 통계 + 검색. 사이드바 하단 설정 유지.
- `AppTab`에 `.downloads` 추가, `isCompactTab`에 포함. `RootView`의 iPhone/iPad 분기 모두에서 탭이 보이게.

### 9.2 라우팅·상태

- `Router`에 다운로드 선택 상태를 둔다: `isSelectingDownloads: Bool`, `selectedDownloadCount: Int`(또는 `DownloadSelection` @Observable environment). 선택 모드에서 `tabViewBottomAccessory`를 미니 플레이어 대신 **선택 액션 바**로 교체한다.
- `Router.openOnlineSearch()` 추가: `selectedTab = .search` + 검색 화면 스코프를 `.online`으로. 다운로드 빈 상태의 [음악 찾기]가 이걸 호출한다.
- 기존 `Route`는 유지. 다운로드 화면은 탭 루트라 `Route` 추가 불필요. 설정의 "다운로드" 행은 제거한다(탭이 대신한다).
- `tune://` URL 처리(현재 재생 화면 열기)는 건드리지 않는다.

### 9.3 화면 지도

```
홈 ── 앨범/플레이리스트/아티스트 (기존 Route)
다운로드 ── (탭 루트) 설정 시트 / 확장 스토어
보관함 ── 카테고리 6종 ── 앨범/아티스트/플레이리스트/장르/곡
통계 ── 요약/순위/패턴/발견/돌아보기 (기존)
검색 ── 로컬 결과 / 온라인 결과 ── 온라인 앨범·아티스트·플레이리스트
```

---

## 10. 화면별 명세

### 10.1 홈

- 내비: 큰 제목 "홈"(`.large`, 스크롤 접힘), 우상단 설정 아바타. **다운로드 아이콘 제거**(탭으로 이동).
- 순서:
  1. **지금 듣기** — 최근 재생 앨범/플레이리스트 2×2 바로가기(최대 8). 타일: 왼쪽 제목 2줄, 오른쪽 56pt 표지, 배경 `Color(hex:)` 0.85 + 검정 0.15 오버레이, 흰 텍스트, 반경 8. 플레이리스트는 첫 곡 앨범 색, 없으면 액센트. `.ultraThinMaterial` 금지.
  2. **최근 추가** — 가로 셸프, 앨범 카드 152(iPhone)/180(iPad). "모두 보기"는 `SectionHeader`의 chevron.
  3. **자주 듣는** — 가로 셸프.
  4. **내 플레이리스트** — "새 플레이리스트" 카드 + 플레이리스트 카드.
  5. **다운로드 활동 카드** — 진행 중인 작업이 있을 때만. 1줄 상태 + 진행 바 + "다운로드 열기". 불투명 카드(글래스 금지).
- **필터 칩("전체/앨범/플레이리스트/아티스트") 제거.** 셸프가 이미 목적을 드러낸다. 필터가 꼭 필요하면 내비게이션 바 `보기` 메뉴로 옮기고 칩 줄은 만들지 않는다.
- 배경: 마지막 재생 앨범 색의 상단 워시 320pt, 불투명도 0.35. 콘텐츠는 스크롤.
- 빈 보관함: 큰 `music.note` 심볼 + "아직 음악이 없어요" + [음악 가져오기] + [음원으로 받기] + 파일 폴더 안내. `EmptyLibraryView`를 재사용하되 Apple Music식 여백으로.

### 10.2 다운로드 (신규 탭)

내비: 큰 제목 "다운로드", 우상단 `⋯` 메뉴 — 정렬(최근/앨범/아티스트), "기록 지우기"(완료·실패 기록만, 파일은 유지), "다운로드 설정". `선택`은 두지 않는다(관리는 스와이프/롱프레스).

한 스크롤, 세그먼트 없음. 순서:

1. **지금 받는 중** (활성 작업이 있을 때만)
   - 64pt 표지, 제목 17 semibold, 아티스트 15 secondary, 메타 13("Apple Music · FLAC 16/44").
   - 2pt 진행 바(액센트) + "62%" + "대기 4곡" + [취소] 44pt.
   - 배경: `secondarySystemBackground` 카드, 반경 12. 글래스 금지(콘텐츠).
2. **대기 중 N곡** — 44pt 표지, 제목/아티스트 1줄, 우측 "대기 중". 스와이프로 취소. 진행률 없음.
3. **받은 음악** — 기본적으로 **앨범 묶음**. 헤더: 앨범명 + "아티스트 · N곡". 행: 44pt 표지, 제목/아티스트, 탭하면 재생. 우측에 다운로드 아이콘 없음. 컨텍스트: "보관함에서 보기", "앨범으로 이동", "기록에서 지우기". "기록 지우기"는 **기록만** 지우고 파일은 남긴다는 문구 유지.
4. **받지 못한 곡 N** — 접히는 섹션(기본 접힘). 사유 1줄 + [다시 받기]. "실패 항목 지우기"(실패 작업만 `remove`로 제거, 파일 없음).
5. **빈 상태** (작업 0, 완료 0): 큰 `arrow.down.circle` + "아직 받은 음악이 없어요" + "검색에서 곡을 찾아 ↓ 한 번만 누르면 돼요." + [음악 찾기](검색 탭 온라인 스코프로) + [음원 확장 설정].
6. **확장 없음**: 1–4 대신 설정 카드(§11.2). 탭 배지 없음.

완료 시: 히어로에서 사라지고 "받은 음악" 맨 위로 `withAnimation(.smooth)` + 상단 토스트 "보관함에 추가했어요 · Ditto". 토스트 탭 → 재생.

### 10.3 보관함

- 큰 제목 "보관함", 우상단 `편집`(메뉴 편집) + `+`(가져오기/새 플레이리스트).
- 카테고리 행 6개: 플레이리스트/아티스트/앨범/노래/장르/좋아요 표시한 곡. 29pt 둥근 사각 아이콘 + 17pt 제목 + chevron. 아이콘 색은 Apple Music처럼 카테고리별(플레이리스트 핑크, 아티스트 인디고, 앨범 오렌지, 노래 틸, 장르 퍼플, 좋아요 옐로) — 채도는 낮게, 선택/재생은 액센트.
- 행 높이 50–52, 구분선은 아이콘 오른쪽부터. 섹션 간 28.
- "최근 추가" 헤더 + 2열 그리드(iPhone). 카드: 표지 반경 6, 제목 15 semibold, 아티스트 13 secondary, 2줄.
- 고정 앨범은 그리드 맨 앞. 빈 보관함은 홈과 같은 빈 상태(가져오기 중심).
- `LibraryMenuEditor`는 유지하되 Form 대신 Apple Music식 순서 편집(드래그 핸들, 체크). 기능 동일.

### 10.4 검색

- 검색 탭, `.searchable` 유지. 검색 필드는 상단 고정, 스크롤 시 미니화.
- **입력 전**: 최근 검색(시계 아이콘, x 삭제), "장르 둘러보기" 2열 컬러 타일(기존 `GenreTile` 개선: 100pt 높이, 17 bold, 64pt 표지 회전, 반경 12).
- **입력 후**: 검색 필드 아래 **가로 스코프 바** — 상위 결과 / 온라인 / 노래 / 앨범 / 아티스트 / 플레이리스트. 선택 칩만 글래스 tint, 나머지는 텍스트. 리스트 안 섹션으로 넣지 않는다.
- **상위 결과**: 88pt 표지/아티스트 원, 제목 22 bold, 부제 15. 카드 배경 `secondarySystemBackground`, 반경 12. 재생 버튼은 우측 원형 액센트.
- **온라인 섹션**:
  - 헤더 왼쪽 "온라인", 오른쪽에 **프로바이더 메뉴 버튼**(아이콘 + 이름 + chevron, 글래스 캡슐). `Picker`를 리스트 행으로 넣지 않는다.
  - 결과 행: 52pt 표지, 제목 17, 아티스트 15, 메타 13("Apple Music · 3:42"), 우측 `DownloadButton` 44pt.
  - 정보 전용 프로바이더여도 행은 똑같이 `↓` 하나. 탭하면 설치된 다운로드 확장에서 매칭. 매칭 결과가 1개면 즉시 enqueue, 2개 이상이면 글래스 확인 시트("어느 확장으로 받을까요?" + 확장명/기본 음질).
  - "정보 전용" 텍스트를 행에서 제거. 필요하면 프로바이더 메뉴에 작은 "정보" 라벨만.
  - 로딩: 스피너 대신 3–4개 스켈레톤 행(redacted). 로컬 결과는 즉시, 온라인은 스트리밍.
  - 오류: 섹션 안 인라인 카드 "Apple Music에서 결과를 가져오지 못했어요" + [다시 시도]. 빨간 footnote 금지.
- **선택 모드**: 내비게이션 바 `선택`(온라인 결과가 있을 때). 행 앞 22pt 체크 원, 탭으로 토글. 진입 시 미니 플레이어를 숨기고 하단 액션 바(글래스): "3곡 선택" + [전체 선택] + [받기]. `받기`는 기본 음질로 일괄 enqueue 후 토스트 "3곡을 대기열에 넣었어요" + 선택 종료.
- 기존 리스트 안의 "여러 곡 한 번에 받기" 버튼과 배치 바(`.ultraThinMaterial`) 제거.
- 검색은 350ms 디바운스 유지. 프로바이더 변경 시 재검색. 확장 인증 알림 수신 시 재검색 유지.

### 10.5 앨범·아티스트·플레이리스트 (로컬 + 온라인 통일)

- **로컬 `AlbumView`가 기준**이다: 전체 폭 커버, 당겨서 커지는 헤더, 색 번짐, 큰 제목, 트랙 리스트. 이 문법을 온라인 화면에도 적용한다.
- 온라인 앨범/플레이리스트: 상단 전체 폭 또는 220–240pt 표지 + 색 번짐, 제목 28–34 bold, 아티스트 링크 20, 메타 13("EP · 2024 · 5곡"), 액션 행.
- 액션 행: 주 액션 1개(솔리드 액센트 캡슐) + 보조 1개(글래스 원형). 라벨은 기존 UI 테스트 문자열을 유지한다: "앨범 전체 받기", "플레이리스트 전체 받기", "모든 앨범 받기". (바꾸려면 테스트를 같은 변경에서 고친다.)
- 트랙 행: 왼쪽 번호 22pt(현재 재생이면 `PlayingBars`), 44pt 표지, 제목/아티스트, 우측 `DownloadButton`. 행 전체 탭 = 받기. 이미 받은 행은 체크 표시, 재생은 컨텍스트 메뉴(보관함 곡과 매핑된 경우). 32pt 아이콘만 탭하게 만들지 않는다.
- 행별 음질 `Menu` 제거. 롱프레스/컨텍스트 메뉴에 "다른 음질로 받기"(있는 경우), "확장 선택"(2개 이상), "대기열에서 빼기".
- 준비 중 상태는 헤더 액션 버튼 자체에 표시("준비 중 12/40"). 화면 하단 `.ultraThinMaterial` 캡슐 금지.
- 결과 메시지는 화면을 밀어내는 footnote 문단이 아니라 상단 토스트.
- 아티스트: 원형 사진 150/200, 이름 34 heavy, 액션 2개, 앨범 그리드 2/4열, 인기곡 리스트. 앨범 카드마다 작은 `↓` 유지하되 44pt 히트 영역.

### 10.6 재생 화면

- 이미 Apple Music에 가깝다. 구조 유지, 크롬만 정리.
- 배경: `MeshBackground` 유지(콘텐츠 배경이므로 글래스 아님). 오버레이 0.28 → 0.35로 대비 확보. Reduce Motion이면 정지.
- 표지: 30pt 여백, 반경 10, 재생 중 1.0 / 일시정지 0.8 스케일 유지.
- 타이틀 블록: 제목 20 semibold(마퀴), 아티스트 20 white 0.65, 좋아요/더 보기는 **글래스 원형 36pt**(현재 white 0.15 배경 대체).
- 진행: `ElasticSlider` 유지(시그니처). 시간 12 mono. 무손실 배지 유지.
- 트랜스포트: 흰 글리프 유지(원 배경 없음). 재생/일시정지 44–48pt, 심볼 전환.
- 볼륨 줄: 기능 유지(삭제 금지). 트랙 1pt + 작은 스피커 아이콘으로 낮추고, 글래스 캡슐에 넣지 않는다.
- 하단: 가사/대기열 버튼은 글래스 원형, 선택 시 tint. AirPlay 유지.
- 가사: 전체 화면 큰 글자, 현재 줄 액센트, 나머지 white 0.45. 기존 `LyricsView` 로직 유지.
- iPad: 좌 표지+컨트롤 / 우 가사·대기열 패널 유지. 닫기 버튼만 글래스. 패널 폭 조절 손잡이 유지.
- 미니 플레이어: 시스템 액세서리 유지. 표지 반경 6, 제목 15 semibold, 아티스트 13 secondary, 재생/다음 44pt. 커스텀 글래스 배경을 덧칠하지 않는다.

### 10.7 설정

- 시트 + `NavigationStack` + Form 유지(설정은 Form이 맞다). 큰 제목 "설정", `완료`.
- 섹션 순서: 모양 → 재생 → 가사 → 보관함/가져오기 → **다운로드** → 저장 공간/정보.
- 다운로드 섹션: "기본 음질"(확장별 요약 + [변경]), "저장 위치"(Tune/다운로드, [파일 앱에서 열기]), "음원 확장 관리", "기록 지우기". 진행 바는 넣지 않는다(탭 배지/다운로드 화면이 담당). 기존 `DownloadListView` 링크는 제거한다(탭이 대신한다).
- footer의 `.sflx`/JavaScriptCore 설명은 "고급"으로 이동.

### 10.8 통계

- 기능·계산·섹션 구조 유지. 큰 제목 "통계", 상단 세그먼트는 시스템 세그먼트 유지(글래스로 감싸지 않음).
- 카드 배경 `secondarySystemBackground`, 반경 12, 그림자 없음. 차트 색은 액센트 단색 + secondary. 1–3위만 액센트, 나머지 중성.
- 히트맵은 액센트 4단계 유지. 다색 팔레트 제거.
- 이 화면은 글래스 0개.

---

## 11. 다운로드 플로우 (핵심)

### 11.1 한 번 탭 모델

`DownloadButton` 하나로 통일한다.

| 상태 | 글리프 | 동작 |
|---|---|---|
| 받을 수 있음 | `arrow.down.circle` | 탭 → 기본 음질로 enqueue |
| 대기 중 | `clock` 또는 링 0% | 탭 → 다운로드 탭 |
| 받는 중 | 2.5pt 링 + % | 탭 → 다운로드 탭 |
| 받음 | `checkmark.circle.fill` | 탭 → 보관함에서 보기(매핑되면 재생) |
| 실패 | `arrow.clockwise.circle` | 탭 → 재시도 |
| 확장 없음 | `arrow.down.circle` + 작은 `exclamationmark` | 탭 → 설정 시트 |
| 정보 전용 + 매칭 필요 | `arrow.down.circle` | 탭 → 매칭(1개 즉시, 2+ 시트) |

- 44×44 히트, 22pt 글리프, 액센트. `.contentTransition(.symbolEffect(.replace))`.
- 행 전체도 같은 동작을 하도록 `contentShape(Rectangle())`. 단, 행에 다른 탭 동작(재생)이 있으면 충돌하지 않게 trailing 버튼만 다운로드, 행은 재생.
- 롱프레스/컨텍스트: "다른 음질로 받기", "확장 선택", "대기열에서 빼기".
- `DownloadManager.enqueue`는 자동 시작하므로 "대기열 시작" 버튼을 만들지 않는다.
- 중복: 이미 active 작업이면 토스트 "이미 대기 중이에요." (기존 `lastMessage` 활용). 완료 작업이 있으면 체크 상태.

### 11.2 첫 실행 / 확장 없음

- `DownloadSetupSheet` (medium/large detent, 시스템 시트 글래스):
  - 제목 "음원을 받으려면 확장이 필요해요"
  - 본문 "확장은 곡을 찾고 파일로 저장하는 작은 도구예요. 한 번만 설치하면 계속 써요."
  - 3단계 아이콘 행: 1) 음원 확장 설치 2) 필요하면 로그인 3) 곡 옆 ↓ 누르기
  - 설치 가능한 확장 리스트: 52pt 아이콘, 이름, 한 줄 설명, [설치] / "설치됨" + [설정]. 레지스트리에서 로드.
  - 주 버튼 [확장 설치] (첫 항목), 보조 [나중에].
  - `고급` disclosure: "레지스트리 주소" TextField, "파일에서 .sflx 설치". 기본 화면에서 숨긴다.
  - 레지스트리 실패: 인라인 오류 + [다시 불러오기]. 로컬 재생은 막지 않는다.
- 설치 완료 후 시트가 "준비됐어요" 상태로 바뀌고 [곡 찾기] → 검색 탭 온라인 스코프.
- `ExtensionStoreView` 재구성: (1) 사용 가능한 확장 스토어, (2) 설치됨, (3) 고급(레지스트리/파일). 기술 설명은 footer로.
- 로그인 필요: 기존 `VerificationBanner` 흐름 유지, 스타일만 `GlassToast`로 통일. 인증 대기 중 작업은 실패가 아니라 "인증 후 이어져요"로 표시.

### 11.3 음질

- 확장별 `기본 음질`을 설정에서 한 번 고른다. 확장 행에 "기본: FLAC 16/44" 요약.
- 행 탭은 항상 기본 음질. 다른 음질은 롱프레스/컨텍스트 메뉴에서만.
- `qualityOptions`가 비어 있으면 기본값으로 enqueue(현재 동작 유지).
- 다운로드 탭 `⋯` → "다운로드 설정" 시트: 확장 목록 + 기본 음질 + 저장 위치 + 확장 관리.

### 11.4 여러 곡

- 검색: 내비게이션 바 `선택` → 체크 → 하단 글래스 액션 바 → [받기].
- 앨범/플레이리스트: 기존 "전체 받기" 캡슐이 곧 배치. 개수 표시("12곡").
- 아티스트: "모든 앨범 받기"는 확인 알림 유지(현재 동작), 스타일만 Apple Music식 알림.
- 대량 enqueue 중에는 버튼 라벨이 "준비 중 12/40"으로 바뀌고 스피너는 버튼 안에만.
- 완료 후 토스트 하나("40곡을 대기열에 넣었어요"), 행별 알림 금지.

### 11.5 다운로드 화면 상태 매트릭스

| 상황 | 화면 | 탭 배지 | 전역 |
|---|---|---|---|
| 확장 없음 | 설정 카드 + 스토어 | 없음 | 없음 |
| 확장 있음, 작업 0 | 빈 상태(음악 찾기/설정) | 없음 | 없음 |
| 대기만 | "대기 중 N곡" | N | 없음 |
| 받는 중 | 히어로 + 대기 | N | 배지 |
| 완료 추가 | "받은 음악" 맨 위 | 활성 수(0이면 없음) | 완료 토스트 |
| 실패 | 접힌 실패 섹션 | 활성 수(0이면 없음) | 실패 토스트 1회(배치당) |
| 혼합 | 히어로 → 대기 → 받은 → 실패 | 활성 수(0이면 없음) | 완료/실패 토스트 |

### 11.6 전역 피드백

- **탭 배지**가 유일한 상시 표시. 미니 플레이어 위에 떠 있는 다운로드 알약은 만들지 않는다(겹침·소음).
- 완료 토스트: 상단, 글래스, 3초, 탭하면 재생. 연속 완료는 마지막 것만.
- 실패 토스트: 배치당 1회, "1곡을 받지 못했어요" + [보기].
- 기존 `ImportBanner`/`VerificationBanner`/`PlaybackNoticeBanner`를 `GlassToast` 하나로 통일한다. 액션 버튼 1개, 진행(인디터미닛) 변형, 닫기 버튼을 지원하고 한 번에 하나만 큐로 표시(최대 2줄).
- `DownloadManager.lastMessage`를 토스트로 승격.

### 11.7 카피

| 위치 | 지금 | 바꿀 것 |
|---|---|---|
| 탭 | (없음) | 다운로드 |
| 섹션 | 받는 중 | 지금 받는 중 |
| 섹션 | 완료 | 받은 음악 |
| 섹션 | 대기열 | 대기 중 N곡 |
| 섹션 | 받지 못한 곡 | 받지 못한 곡 N |
| 행 버튼 | (아이콘) | 받기 / 받는 중 62% / 받음 / 다시 받기 |
| 행 메타 | 정보 전용 | (제거) |
| 행 버튼 | 다운로드 확장에서 찾기 | 받기 |
| 설정 | 다운로드 확장 | 음원 확장 |
| 설정 | 내려받기 | 받기 |
| 목록 | 묶어 보기 | (제거, `⋯` 정렬) |
| 목록 | 대기열 시작 | (제거, 자동 시작) |
| 목록 | 완료·실패 항목 지우기 | 기록 지우기 / 실패 항목 지우기 |
| 토스트 | (없음) | 보관함에 추가했어요 · 곡명 |
| 토스트 | (없음) | 이미 대기 중이에요. |
| 빈 상태 | (없음) | 아직 받은 음악이 없어요 / 검색에서 곡을 찾아 ↓ 한 번만 누르면 돼요. |
| 설정 시트 | (없음) | 음원을 받으려면 확장이 필요해요 |

- "정보 전용", "다운로드 확장에서 찾기", "내려받기"는 **주 UI에서 제거**한다. 단, UI 테스트가 이 문자열을 검사하므로 §17대로 테스트를 함께 수정한다.
- 오류는 사유 + 행동: "확장에서 로그인이 필요해요" + [로그인], "파일을 저장할 공간이 부족해요" + [정리하기].

### 11.8 엣지 케이스

- **확장 삭제됨**: 작업이 실패하면 "확장을 찾을 수 없어요" + [확장 설정]. 재설치 후 [다시 받기].
- **로그인 필요**: 작업은 대기 유지, 배너/토스트 "인증 후 이어져요". 인증 완료 알림 수신 시 재개.
- **오프라인**: 검색은 인라인 오류, 다운로드는 실패 사유, 보관함 재생은 정상.
- **앱 재실행**: `recoverInterruptedJobs` 결과를 다운로드 화면에 반영. 이전에 실패한 항목은 실패 섹션.
- **파일은 있지만 작업 기록이 없는 경우**: 완료 행은 `relativePath`로 보관함 곡을 찾아 재생. 없으면 체크만.
- **iPad 패널 열림 + 선택 모드**: 하단 액세서리 교체가 패널과 겹치지 않게 `showsPanel` 분기 확인.
- **저장 공간 부족**: `job.error`를 그대로 길게 보여주지 말고 1줄 요약 + 상세는 컨텍스트 메뉴.

---

## 12. 컴포넌트 명세

| 컴포넌트 | 위치 | 메모 |
|---|---|---|
| `DownloadButton` | `DesignSystem/DownloadComponents.swift` | 7상태, 44pt, 링, 심볼 전환, 접근성 라벨 |
| `DownloadProgressRing` | 동일 | 2.5pt trim, % 텍스트는 히어로에만 |
| `DownloadStatusChip` | 동일 | "대기 중/받는 중/완료/실패" 13pt, 캡슐 아님(텍스트+작은 아이콘) |
| `DownloadHeroCard` | `Features/Download/DownloadsScreen.swift` | 불투명 카드, 64pt 표지, 진행 바, 취소 |
| `DownloadRow` | 동일 | 44pt 표지, 1–2줄, 스와이프 |
| `DownloadSetupSheet` | `Features/Download/DownloadSetupSheet.swift` | 3단계 + 스토어, 고급 접기 |
| `DownloadSettingsSheet` | `Features/Download/DownloadSettingsSheet.swift` | 기본 음질·저장 위치·확장 |
| `GlassToast` | `DesignSystem/Glass.swift` | 상단, 1–2줄, 액션 1개, 진행 변형, 자동 dismiss |
| `GlassActionBar` | 동일 | 선택 모드 하단, `GlassEffectContainer` |
| `GlassSegmented` | 동일 | 검색 스코프, 선택 칩만 tint |
| `ProviderMenuButton` | `Features/Search/SearchView.swift` | 아이콘+이름+chevron, 글래스 캡슐 |
| `EmptyStateView` | `DesignSystem/EmptyState.swift` | 심볼 56, 제목 22, 본문 15, 주/보조 버튼 |
| `ArtworkTile` | `Features/Home/HomeView.swift` | 색 배경 + 56pt 표지 + 2줄 제목 |
| `TrackRow` | `DesignSystem/Components.swift` | 56pt, 번호/표지, 재생 표시, 우측 `DownloadButton` 옵션 |
| `AlbumCard` | 동일 | 2열 그리드, 반경 6, 2줄 |
| `PlayShuffleButtons` | 동일 | Apple Music식 캡슐, `재생`은 솔리드, `셔플`은 글래스 |
| `CollectionHeaderWide` | `CollectionComponents.swift` | iPad 헤더, 주/보조 버튼 통일 |

- 모든 아이콘 버튼은 44×44. 모든 행은 `contentShape(Rectangle())`.
- 새 컴포넌트에는 `#Preview`로 상태별(빈/진행/완료/실패) 미리보기. 프리뷰는 디스크·네트워크를 건드리지 않는다.

---

## 13. 접근성

- Dynamic Type AX3까지: 행 제목 2줄, 아티스트 1줄, 버튼은 `ViewThatFits`로 아이콘만/텍스트+아이콘.
- 다운로드 버튼 라벨: "받기" / "받는 중 62퍼센트" / "받음" / "다시 받기". 힌트: "기본 음질로 받아요".
- 선택 행: `.accessibilityAddTraits(.isSelected)`, 라벨에 "선택됨".
- 탭: "다운로드, 2곡 받는 중". 배지는 시각 정보이므로 라벨에 수를 포함.
- VoiceOver 순서: 표지 → 제목 → 아티스트 → 상태 → 동작. 장식 아이콘은 `.accessibilityHidden(true)`.
- Reduce Transparency: 커스텀 글래스는 `Color(.secondarySystemBackground)` 폴백. 시스템 글래스는 자동.
- Increase Contrast: 스크림 강화, secondary 텍스트를 `.primary.opacity(0.7)`로.
- Reduce Motion: 메시/마퀴/바운스/링 애니메이션 정지, 페이드만.
- 색만으로 상태를 구분하지 않는다: 아이콘 모양 + 텍스트 병행.
- 히트 영역: 44pt. 스와이프 액션에도 버튼 제공(컨텍스트 메뉴).

---

## 14. 성능

- 리스트 행에 `.glassEffect` 금지. `GlassEffectContainer`를 `ForEach` 안에 넣지 않는다.
- 긴 목록은 `List`/`LazyVStack`. 홈 셸프는 `LazyHStack`.
- `MeshBackground`는 재생 화면만. `TimelineView`는 현재 재생 행/마퀴만.
- `AsyncImage`/`RemoteArtwork` 중복 로드 금지. 기존 `ArtworkStore` 캐시 사용.
- 스크롤 60fps: iPhone 16 Pro 시뮬레이터에서 100+ 행 목록 확인. Instruments 없이도 끊김 육안 확인.
- 글래스 클러스터 수: 화면당 3개 이하. 배치 바 + 버튼은 한 컨테이너.

---

## 15. 구현 순서 (각 Phase는 독립적으로 빌드 가능해야 함)

### Phase 0 — 인벤토리 (코드 없음)
- 위 파일들을 읽고, 화면/컴포넌트/상태 목록과 바꿀 파일 목록을 1페이지로 정리.
- 현재 화면 스크린샷 6장(홈/보관함/검색/다운로드/앨범/재생)을 찍어 before로 보관.
- 모호한 점(탭 5개, 통계 유지, 볼륨 줄)을 먼저 보고.

### Phase 1 — 토큰 + 글래스 + 탭 뼈대
- `Theme.swift` 토큰 정리, `DesignSystem/Glass.swift` 추가.
- `AppTab.downloads`, `RootView` 탭·배지·토스트 호스트, `DownloadsScreen` 껍데기(빈 상태/설정 카드).
- 빌드 성공. 기존 화면은 아직 그대로여도 됨.

### Phase 2 — 다운로드 플로우 (가장 큰 단계)
- `DownloadButton`, `DownloadRow`, `DownloadHeroCard`, `DownloadSetupSheet`, `DownloadSettingsSheet`.
- 검색 온라인 행/프로바이더 메뉴/선택 모드, 프로바이더 앨범·아티스트·플레이리스트 행.
- `ExtensionStoreView` 스토어 우선 재구성.
- 토스트/배지/완료·실패 피드백.
- UI 테스트 라벨 갱신. 빌드 성공.

### Phase 3 — 컬렉션 화면 통일
- `ProviderScreens` 헤더/액션/행을 `AlbumView` 문법에 맞춤.
- `CollectionHeaderWide`, `WideTrackRow` 정리.
- 빌드 성공.

### Phase 4 — 홈·보관함·검색 시각
- 홈 필터 제거, 타일/셸프/활동 카드.
- 보관함 카테고리 색·그리드·여백.
- 검색 아이들/결과/스코프/스켈레톤.
- 빌드 성공.

### Phase 5 — 재생·설정·통계 + 마감
- 재생 화면 글래스 크롬, 볼륨 줄 정리, iPad 확인.
- 설정 다운로드 섹션, 통계 색·카드.
- 접근성(AX3, Reduce Motion/Transparency), 성능 스크롤, 스크린샷, 테스트.

각 Phase 종료 조건: **빌드 성공 + 스크린샷 + 엔진 diff 0**. 빨간 빌드면 다음 Phase로 넘어가지 않는다.

---

## 16. 파일 작업 목록

**새 파일 (권장)**
- `Tune/DesignSystem/Glass.swift` — `GlassToast`, `GlassActionBar`, `GlassSegmented`, `GlassIconButton`
- `Tune/DesignSystem/DownloadComponents.swift` — `DownloadButton`, `DownloadProgressRing`, `DownloadStatusChip`
- `Tune/DesignSystem/EmptyState.swift` — 공통 빈 상태
- `Tune/Features/Download/DownloadsScreen.swift` — 탭 루트, 히어로, 목록
- `Tune/Features/Download/DownloadSetupSheet.swift` — 첫 설정/스토어
- `Tune/Features/Download/DownloadSettingsSheet.swift` — 기본 음질/저장 위치

**수정**
- `Tune/App/RootView.swift`, `Tune/App/Router.swift`
- `Tune/DesignSystem/Theme.swift`, `Components.swift`, `CollectionComponents.swift`
- `Tune/Features/Home/HomeView.swift`, `Library/LibraryView.swift`, `Search/SearchView.swift`
- `Tune/Features/Download/DownloadViews.swift` (옛 `DownloadListView` 제거, `ProviderResultRow` 정리)
- `Tune/Features/Download/ProviderScreens.swift`, `ExtensionStoreView.swift`
- `Tune/Features/Album/AlbumScreen.swift`, `Artist/ArtistScreen.swift`, `Playlist/PlaylistScreen.swift`
- `Tune/Features/NowPlaying/NowPlayingView.swift`, `MiniPlayer.swift`, `PlayerComponents.swift`
- `Tune/Features/Settings/SettingsView.swift`
- `Tune/Features/Stats/StatsView.swift`, `StatsSections.swift` (가벼운 색/카드만)
- `TuneUITests/SearchOnlineUITests.swift`, `MetadataSearchUITests.swift` (라벨 변경 시)

**금지**: `Tune/Player/*`, `Tune/Download/DownloadManager.swift`, `Tune/Download/DownloadModels.swift`, `Tune/Download/Extension/*`, `Tune/Library/*`, `Shared/*`, `TuneWidgets/*`, `project.yml`의 타깃 구조.

새 파일은 `project.yml`의 `sources: - path: Tune`에 자동 포함된다. `xcodegen generate` 후 `Tune.xcodeproj` 변경을 함께 둔다. `project.pbxproj` 수동 편집 금지.

---

## 17. 검증

### 빌드 (로컬에 Xcode 26.2 + XcodeGen 있음)

```bash
xcodegen generate
xcodebuild \
  -project Tune.xcodeproj \
  -scheme Tune \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Release/CI 확인이 필요하면:

```bash
xcodebuild -project Tune.xcodeproj -scheme Tune -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

### UI 테스트

- `TuneUITests`는 실제 확장·네트워크가 필요해 로컬에서 실패할 수 있다. 실행을 시도하고, 불가하면 사유를 보고한다.
- 라벨을 바꿨으면 같은 변경에서 테스트를 갱신한다. 특히:
  - "모든 앨범 받기", "앨범 전체 받기", "플레이리스트 전체 받기"
  - "정보 전용", "다운로드 확장에서 찾기"
  - "다른 확장에서 같은 곡을 찾아 받아요"
  - 프로바이더 버튼 라벨 "음원…", "Apple Music · 정보"
  - 알림 "모든 앨범을 받을까요?"
- 테스트를 삭제하거나 느슨하게 만들지 말 것. 새 카피에 맞춰 의도를 유지한다.

### 수동 매트릭스

- iPhone 16 Pro, iPhone SE(작은 화면), iPad Pro 11(가로, 재생 패널 열림).
- 라이트/다크, AX3, Reduce Transparency, Reduce Motion.
- 상태: 확장 없음 / 로그인 필요 / 대기 0 / 받는 중 / 완료 / 실패 / 혼합.
- 스크린샷 8장: 홈, 다운로드 빈 상태, 다운로드 진행, 검색 온라인, 프로바이더 앨범, 보관함, 재생, iPad 패널.
- `rg "ultraThinMaterial" Tune` 결과가 0인지 확인(시스템 크롬 제외).
- 엔진 diff 확인: `git diff --stat -- Tune/Player Tune/Download/DownloadManager.swift Tune/Download/Extension Tune/Library Shared TuneWidgets` 가 비어 있어야 한다.

---

## 18. 완료 기준 (Definition of Done)

- [ ] 검색 결과에서 `↓` 한 번으로 다운로드가 시작된다. 음질 메뉴/확인창이 없다.
- [ ] 어느 탭에서든 다운로드 탭 배지로 진행 수를 알 수 있다.
- [ ] 다운로드 화면 한 스크롤에 진행/대기/완료/실패가 모두 보인다. 세그먼트가 없다.
- [ ] 확장이 없을 때 막다른 알림이 아니라 설정 시트가 열리고, 설치 후 바로 곡을 찾을 수 있다.
- [ ] "정보 전용", "다운로드 확장에서 찾기", "내려받기"가 주 UI에 없다. (테스트는 갱신)
- [ ] 리스트 행에 글래스가 없고, 화면당 글래스 클러스터 ≤3.
- [ ] 라이트/다크, AX3, Reduce Motion/Transparency에서 깨지지 않는다.
- [ ] `xcodegen generate` + `xcodebuild` 성공. UI 테스트는 통과하거나 실행 불가 사유가 보고됨.
- [ ] 엔진·모델·위젯 diff 0.
- [ ] before/after 스크린샷과 Phase별 변경 요약이 있다.

---

## 19. 최종 보고 형식

1. **Phase별로** 바뀐 화면과 파일 목록.
2. **스크린샷**: before/after, iPhone 라이트/다크, iPad 1장.
3. **검증**: 빌드 로그 요약, UI 테스트 결과(또는 불가 사유), `rg`/diff 확인.
4. **남은 것**: 의도적으로 하지 않은 것, 코드상 불가능한 것, 다음 Phase 제안.
5. **하지 않은 것**: 엔진·모델·위젯 무변경 확인.

---

## 부록 A. Liquid Glass API 치트시트 (iOS 26)

```swift
// 1) 기본 글래스 표면
.glassEffect(.regular, in: Capsule())

// 2) 선택/주요 액션에 tint + 누르는 반응
.glassEffect(.regular.tint(Color.tuneAccent).interactive(), in: Circle())

// 3) 시스템 글래스 버튼 (직접 glassEffect를 바르지 말 것)
Button { } label: {
    Image(systemName: "ellipsis").frame(width: 44, height: 44)
}
.buttonStyle(.glass)
.buttonBorderShape(.circle)

// 4) 여러 글래스가 붙을 때: 컨테이너 + ID + namespace
GlassEffectContainer(spacing: 12) {
    HStack(spacing: 12) {
        Button { } label: { Image(systemName: "quote.bubble").frame(width: 44, height: 44) }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .glassEffectID("lyrics", in: namespace)
        Button { } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .glassEffectID("queue", in: namespace)
    }
}

// 5) 스크롤 경계 / 배경 확장
.scrollEdgeEffectStyle(.hard, for: .top)
.backgroundExtensionEffect()
```

규칙:
- 탭 바·내비게이션 바·시트·미니 플레이어는 시스템이 이미 글래스다. 직접 칠하지 않는다.
- `.clear`는 이미지 위에만, 반드시 스크림과 함께.
- 글래스 위에 글래스를 얹지 않는다. 겹치면 `GlassEffectContainer`로 하나의 형태로 묶는다.
- Reduce Transparency에서 커스텀 글래스는 불투명 폴백.
- 글래스는 "떠 있는 컨트롤"에만. 콘텐츠 카드·리스트 행·앨범 아트에는 쓰지 않는다.

---

## 부록 B. 와이어프레임

### 다운로드 탭

```
┌ 다운로드                      ⋯ ┐
│                                  │
│  지금 받는 중                     │
│  ┌────────────────────────────┐  │
│  │ [art]  Supernatural        │  │
│  │        NewJeans            │  │
│  │        Apple Music · FLAC  │  │
│  │  ▓▓▓▓▓▓▓░░░░░░  62%  [취소]│  │
│  └────────────────────────────┘  │
│                                  │
│  대기 중 4곡                      │
│  [art] Ditto · NewJeans   대기 중 │
│  [art] Hype Boy · NewJeans 대기 중│
│                                  │
│  받은 음악                  앨범 ▾ │
│  Supernatural · NewJeans · 5곡   │
│  [art] Supernatural        3:11  │
│  [art] Ditto               3:05  │
│                                  │
│  ▸ 받지 못한 곡 1                 │
└──────────────────────────────────┘
```

### 검색 결과

```
[ 검색 필드 ]
(상위 결과) (온라인) (노래) (앨범) …

┌ 상위 결과 ─────────────────────┐
│ [art] NewJeans                 │
│       아티스트                  │
└───────────────────────────────┘

Apple Music ⌄              온라인
[art] Supernatural · NewJeans   ↓
[art] Ditto · NewJeans          ⟳ 62%
[art] Hype Boy · NewJeans       ✓
```

### 온라인 앨범

```
┌────────────────────────────────┐
│        [ 전체 폭 커버 ]          │
│                                │
│  Supernatural                  │
│  NewJeans                      │
│  EP · 2024 · 5곡                │
│  [ 앨범 전체 받기 ]   [♡]        │
├────────────────────────────────┤
│ 1  [art] Supernatural  3:11  ↓ │
│ 2  [art] Ditto         3:05  ✓ │
│ 3  [art] Hype Boy      2:58  ↓ │
└────────────────────────────────┘
```

### 홈

```
홈
┌──────────────┐ ┌──────────────┐
│ NewJeans   ▣ │ │ Get Up     ▣ │
│ Supernatural │ │ NewJeans     │
└──────────────┘ └──────────────┘

최근 추가 ›
[art]  [art]  [art]  [art]

자주 듣는 ›
[art]  [art]  [art]
```

---

## 부록 C. UI 테스트가 의존하는 문자열

`TuneUITests/SearchOnlineUITests.swift`
- 탭: "검색"
- 검색 필드
- 프로바이더 버튼 라벨: "음원"으로 시작
- "Apple Music · 정보"
- "모든 앨범 받기"
- 알림 "모든 앨범을 받을까요?"
- "앨범 전체 받기"
- "플레이리스트 전체 받기"
- "다른 확장에서 같은 곡을 찾아 받아요"

`TuneUITests/MetadataSearchUITests.swift`
- "Spotify Web", "Apple Music"
- "앨범 ·"
- "앨범 전체 받기"
- "정보 전용"
- "다운로드 확장에서 찾기"
- 결과 문자열에 "대기열" 또는 "찾지 못했"

이 문자열을 바꾸면 테스트를 같은 변경에서 갱신한다. 테스트를 약화시키지 말고, 새 UI의 동등한 요소를 검사하게 한다.
