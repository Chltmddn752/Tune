import SwiftUI
import UIKit
import UserNotifications

@main
struct RPGKeysApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var testText = ""
    @State private var notifStatus = "알림 허용하기"

    var body: some View {
        NavigationStack {
            Form {
                Section("키보드 켜기") {
                    Step(n: 1, text: "아래 버튼으로 설정을 열고 '키보드'를 눌러")
                    Step(n: 2, text: "'RPG 키보드'를 켜. 전체 접근 허용은 '준비되면 알림'을 쓸 때만 켜면 돼")
                    Step(n: 3, text: "디스코드에서 🌐 버튼을 길게 눌러 RPG 키보드로 바꾸면 끝")
                    Button("설정 열기") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("준비 알림 (실험적)") {
                    Text("키보드 ⚙️ 탭에서 '준비되면 알림'을 켜면, 쿨타임이 끝날 때 아이폰 알림이 와. 먼저 여기서 알림을 허용하고, 키보드의 전체 접근 허용을 켜 줘.")
                        .font(.footnote)
                    Button(notifStatus) {
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                                DispatchQueue.main.async {
                                    notifStatus = granted ? "알림 허용됨 ✅" : "알림이 거부됨 (설정에서 바꿀 수 있어)"
                                }
                            }
                    }
                }

                Section("테스트") {
                    TextField("여기서 키보드를 시험해 봐", text: $testText, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("들어있는 명령어") {
                    ForEach(Commands.groups.indices, id: \.self) { i in
                        let group = Commands.groups[i]
                        DisclosureGroup(group.title) {
                            ForEach(group.items, id: \.self) { cmd in
                                HStack {
                                    Text(cmd.label)
                                    Spacer()
                                    Text(cmd.text)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("쿨타임 추천") {
                    Text("키보드의 ⭐ 추천 탭에는 지금 쿨타임이 끝난 명령어만 떠. 버튼을 누르는 순간 타이머가 시작되고, 끝나면 다시 나타나. 키보드의 ⚙️ 탭에서 내 최대 area, 도네이터·이벤트 쿨타임 감소, 추천에 띄울 명령어를 정할 수 있어. 📖 탭에는 지역별 공략, 📊 탭에는 사용 통계가 있어.")
                        .font(.footnote)
                }

                Section {
                    Text("버튼은 입력만 하고 전송은 직접 눌러야 해. 자동 전송이나 반복 입력 기능은 EPIC RPG 매크로 금지 규칙 때문에 넣지 않았어.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("RPG 키보드")
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
                .foregroundColor(.white)
            Text(text)
        }
    }
}
