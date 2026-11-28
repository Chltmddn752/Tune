# RPG 키보드

EPIC RPG 명령어를 버튼 한 번으로 입력해 주는 iOS/iPadOS 커스텀 키보드.
버튼은 **입력만** 하고, 전송은 직접 눌러야 해 (자동 전송·반복 입력 없음).

## 빌드
Tune 저장소의 `rpg-keyboard` 브랜치에 푸시하면 GitHub Actions(macOS 26)가 XcodeGen으로 프로젝트를 만들고
서명 없는 `RPGKeys.ipa`를 빌드해 Releases(`rpgkeys-build-N`)에 올린다. SideStore로 설치한다.
빌드 로그 요약은 `ci-logs-rpg` 브랜치에 저장된다.

## 켜기
설정 → 앱 → RPG 키보드 → 키보드 → **RPG 키보드** 켜기
(또는 설정 → 일반 → 키보드 → 키보드 → 새로운 키보드 추가)
디스코드에서 🌐 버튼을 길게 눌러 전환.

## 명령어 바꾸기
`Shared/Commands.swift` 의 목록만 고치고 다시 푸시하면 돼.
`Cmd("버튼 글자", "입력될 글자")` 형식.
끝에 공백이 있는 항목(`rpg open ` 등)은 뒤에 이름이나 @멘션을 이어서 치라는 뜻.

## ⭐ 추천 탭 (쿨타임 추천)
- 버튼을 누르는 순간 그 명령어의 쿨타임 타이머가 시작돼. 같은 쿨타임을 쓰는 명령어(작업 명령어 전체, dungeon+miniboss 등)는 같이 사라졌다가 같이 다시 나타나.
- 쿨타임이 끝난 명령어만 우선순위 순서대로 떠. 작업 명령어는 내 area에서 쓸 수 있는 가장 높은 단계만 보여줘.
- 아래 ⏳ 줄에 남은 시간이 보이고, 칩을 탭하면 '준비됨'으로 바뀌어 (실제 `rpg cd`와 다를 때).
- 잘못 눌렀으면 30초 안에 **전체 지움**을 누르면 타이머도 취소돼.
- ⚙️ 탭에서 최대 area와 도네이터 쿨타임 감소(10/20/35%)를 설정해.
- 쿨타임 초 단위 값은 `Shared/Commands.swift`의 `CooldownKey.base`에서 고칠 수 있어.
- 한계: 키보드가 디스코드 화면을 읽을 수는 없어서, 다른 기기에서 친 명령어나 이벤트로 쿨타임이 줄어든 건 반영되지 않아.

## 보조 봇에서 가져온 기능
| 원래 봇 | 기능 | 키보드에서 |
|---|---|---|
| Navi / Epic RPG Reminder | 쿨타임 알림, ready 목록 | ⭐ 추천 탭 + (실험적) 준비 알림 |
| Navi | 명령어별 알림 켜기/끄기 | ⚙️ 추천에 띄울 명령어 선택 |
| Navi / Epic RPG Reminder | 도네이터·이벤트 쿨타임 배율, hunt together | ⚙️ 도네이터/이벤트 감소, hunt t 옵션 |
| Navi | heal warning | adv 직후 2분 동안 ❤️ heal 을 맨 앞에 추천 |
| Navi | 사용 통계 | 📊 오늘/7일 명령어 사용 횟수 |
| Epic RPG Guide | 지역별 가이드 ($a1~) | 📖 Area별 해금·공략 요약 |

키보드는 디스코드 화면을 못 읽어서 training 정답 도우미, ruby 개수 세기, 인벤토리 계산기처럼 봇 응답을 읽어야 하는 기능은 넣지 못했어.

## 준비 알림 (실험적)
1. 앱에서 '알림 허용하기'
2. 설정 → 키보드 → RPG 키보드 → 전체 접근 허용 켜기
3. 키보드 ⚙️ → '준비되면 알림' 켜기
키보드 확장에서 보내는 로컬 알림이라 기기나 iOS 버전에 따라 안 될 수도 있어.

## 탭 구성
- ⚔️ 기본: hunt, adv, training, heal, cd, rd, daily, weekly, vote, quest …
- 🪓 작업: chop ~ chainsaw, fish ~ bigboat, pickup ~ greenhouse, mine ~ dynamite, farm
- 🎒 아이템: lootbox, open, craft, dismantle, trade, enchant/refine
- 👥 파티: dungeon, miniboss, arena, duel, horse, guild, pets
- 🎉 이벤트: catch, chop, fish, summon, join, time to fight
- 📖 가이드 / 📊 통계 / ⚙️ 설정

## 참고
- SideStore 무료 계정에서는 앱 + 키보드 확장이 App ID 2개를 차지해.
- 하단 줄: 🌐(키보드 전환) / space / 전체 지움 / ⌫ / ⏎
