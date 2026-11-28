import SwiftUI

/// 키보드 컨트롤러와 SwiftUI 화면을 이어주는 모델
final class KeyboardModel: ObservableObject {
    @Published var needsGlobe = true
    @Published var hasFullAccess = false
    let store = CooldownStore()
    var insertText: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var clearText: () -> Void = {}
    var nextKeyboard: () -> Void = {}

    func tap(_ cmd: Cmd) {
        insertText(cmd.text)
        store.didTap(cmd)
    }

    func clearAll() {
        store.undoLastIfRecent()
        clearText()
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var store: CooldownStore
    @AppStorage("selectedTab") private var tab = 0

    init(model: KeyboardModel) {
        _model = ObservedObject(wrappedValue: model)
        _store = ObservedObject(wrappedValue: model.store)
    }

    // 탭: 0 = 추천, 1...n = 명령어 그룹, 그 뒤 가이드·통계·설정
    private var tabTitles: [String] {
        ["⭐ 추천"] + Commands.groups.map(\.title) + ["📖 가이드", "📊", "⚙️"]
    }
    private var guideTab: Int { Commands.groups.count + 1 }
    private var statsTab: Int { Commands.groups.count + 2 }
    private var settingsTab: Int { Commands.groups.count + 3 }

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 6)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                tabBar
                content(now: context.date)
                    .frame(maxHeight: .infinity)
                bottomRow
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let safe = min(max(tab, 0), settingsTab)
        if safe == 0 {
            recommendView(now: now)
        } else if safe == guideTab {
            GuidePane(store: store, insert: model.insertText)
        } else if safe == statsTab {
            StatsPane(store: store)
        } else if safe == settingsTab {
            SettingsPane(store: store, hasFullAccess: model.hasFullAccess)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Commands.groups[safe - 1].items, id: \.self) { cmd in
                        commandButton(cmd, now: now)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    // MARK: 추천 탭

    @ViewBuilder
    private func recommendView(now: Date) -> some View {
        let candidates = Commands.recommendations(
            area: store.area,
            huntTogether: store.huntTogether,
            hidden: store.hidden,
            healFirst: store.isHealPinned(now: now)
        )
        let ready = candidates.filter { cmd in
            guard let cd = cmd.cd else { return true }
            return store.isReady(cd, now: now)
        }
        // 기다리는 쿨타임 (같은 쿨타임은 한 번만, 빨리 끝나는 순)
        let waitingKeys = Array(Set(candidates.compactMap(\.cd)))
            .filter { !store.isReady($0, now: now) }
            .sorted { store.remaining($0, now: now) < store.remaining($1, now: now) }

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if ready.isEmpty {
                    Text(waitingKeys.first.map {
                        "지금 준비된 명령어가 없어 · 다음: \($0.title) \(TimeText.short(store.remaining($0, now: now)))"
                    } ?? "지금 준비된 명령어가 없어")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(ready, id: \.self) { cmd in
                            KeyButton(
                                title: cmd.text == "rpg heal" ? "❤️ heal" : cmd.label,
                                prominent: false
                            ) { model.tap(cmd) }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }

                if !waitingKeys.isEmpty {
                    Text("⏳ 대기 중 · 탭하면 준비됨으로 바꿔")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(waitingKeys, id: \.self) { key in
                                Button {
                                    store.markReady(key)
                                } label: {
                                    Text("\(key.title) \(TimeText.short(store.remaining(key, now: now)))")
                                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.gray.opacity(0.25)))
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .animation(.easeOut(duration: 0.2), value: ready)
        }
    }

    // MARK: 일반 탭 버튼 (쿨타임 중이면 흐리게 + 남은 시간)

    private func commandButton(_ cmd: Cmd, now: Date) -> some View {
        let remaining = cmd.cd.map { store.remaining($0, now: now) } ?? 0
        return KeyButton(
            title: cmd.label,
            subtitle: remaining > 0 ? TimeText.short(remaining) : nil,
            prominent: false
        ) { model.tap(cmd) }
        .opacity(remaining > 0 ? 0.5 : 1)
    }

    // MARK: 탭 바 / 하단 줄

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabTitles.indices, id: \.self) { i in
                    Button {
                        tab = i
                    } label: {
                        Text(tabTitles[i])
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(tab == i ? Color.accentColor : Color.gray.opacity(0.25))
                            )
                            .foregroundColor(tab == i ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.needsGlobe {
                KeyButton(systemImage: "globe", prominent: true) { model.nextKeyboard() }
                    .frame(width: 44)
            }
            KeyButton(title: "space", prominent: false) { model.insertText(" ") }
            KeyButton(title: "전체 지움", prominent: true) { model.clearAll() }
                .frame(width: 82)
            KeyButton(systemImage: "delete.left", prominent: true) { model.deleteBackward() }
                .frame(width: 52)
            KeyButton(systemImage: "return", prominent: true) { model.insertText("\n") }
                .frame(width: 52)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: 📖 가이드 (Epic RPG Guide 봇 스타일 지역 공략)

struct GuidePane: View {
    @ObservedObject var store: CooldownStore
    let insert: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { if store.area > 1 { store.area -= 1 } } label: {
                        Image(systemName: "chevron.left")
                    }
                    Text("Area \(store.area) 공략")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                    Button { if store.area < 21 { store.area += 1 } } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)

                if let tip = AreaGuide.tip(for: store.area) {
                    if tip.area != store.area {
                        Text("Area \(tip.area) 기준 공략")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("🔓 해금: \(tip.unlocks)")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(tip.tips, id: \.self) { line in
                        Text("• \(line)").font(.system(size: 13))
                    }
                }

                Divider()
                ForEach(AreaGuide.general, id: \.self) { line in
                    Text("💡 \(line)").font(.system(size: 12)).foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    KeyButton(title: "rpg area", prominent: false) { insert("rpg area") }
                    KeyButton(title: "rpg trade", prominent: false) { insert("rpg trade") }
                    KeyButton(title: "rpg p", prominent: false) { insert("rpg p") }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: 📊 통계 (Navi /stats 스타일)

struct StatsPane: View {
    @ObservedObject var store: CooldownStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section("오늘", store.todayStats())
                section("최근 7일", store.weekStats())
                Button(role: .destructive) { store.clearStats() } label: {
                    Text("통계 지우기").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                Text("키보드 버튼을 누른 횟수 기준이야.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [(String, Int)]) -> some View {
        Text(title).font(.system(size: 14, weight: .bold))
        if rows.isEmpty {
            Text("기록 없음").font(.caption).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 4) {
                ForEach(rows.indices, id: \.self) { i in
                    Text("\(rows[i].0) ×\(rows[i].1)")
                        .font(.system(size: 13).monospacedDigit())
                }
            }
        }
    }
}

// MARK: ⚙️ 설정 (키보드 안에서)

struct SettingsPane: View {
    @ObservedObject var store: CooldownStore
    let hasFullAccess: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Stepper("최대 지역: Area \(store.area)", value: $store.area, in: 1...21)
                    .font(.system(size: 15))

                labeled("EPIC RPG 도네이터 쿨타임 감소") {
                    Picker("도네이터", selection: $store.donorPercent) {
                        Text("없음").tag(0)
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("35%").tag(35)
                    }
                    .pickerStyle(.segmented)
                }

                labeled("이벤트 쿨타임 감소 (이벤트 중일 때만)") {
                    Picker("이벤트", selection: $store.eventPercent) {
                        Text("없음").tag(0)
                        Text("25%").tag(25)
                        Text("35%").tag(35)
                        Text("50%").tag(50)
                        Text("75%").tag(75)
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("hunt 대신 hunt t (같이 사냥) 추천", isOn: $store.huntTogether)
                    .font(.system(size: 14))
                Toggle("adv 뒤에 heal 먼저 추천", isOn: $store.healWarning)
                    .font(.system(size: 14))
                Toggle("준비되면 알림 (실험적)", isOn: $store.notify)
                    .font(.system(size: 14))
                if store.notify && !hasFullAccess {
                    Text("⚠️ 알림은 전체 접근 허용이 켜져 있어야 동작할 수 있어. 앱에서 알림 권한도 허용해 줘.")
                        .font(.caption).foregroundStyle(.orange)
                }

                labeled("추천에 띄울 명령어 (끄면 숨김)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                        ForEach(CooldownKey.allCases, id: \.self) { key in
                            let on = !store.hidden.contains(key)
                            Button { store.toggleHidden(key) } label: {
                                Text(key.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(on ? Color.accentColor : Color.gray.opacity(0.25))
                                    )
                                    .foregroundColor(on ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button(role: .destructive) {
                    store.resetAll()
                } label: {
                    Text("모든 타이머 초기화")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)

                Text("버튼을 누른 순간부터 타이머가 돌아. 잘못 눌렀으면 30초 안에 '전체 지움'을 누르면 타이머도 취소돼. 정확한 쿨타임은 rpg cd로 확인해.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14))
            content()
        }
    }
}

// MARK: 버튼

struct KeyButton: View {
    var title: String? = nil
    var subtitle: String? = nil
    var systemImage: String? = nil
    let prominent: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                } else {
                    VStack(spacing: 0) {
                        Text(title ?? "")
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(fill)
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
            )
            .foregroundColor(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var fill: Color {
        if prominent {
            return scheme == .dark ? Color(white: 0.27) : Color(white: 0.68)
        }
        return scheme == .dark ? Color(white: 0.42) : .white
    }
}

/// 누를 때 살짝 어두워지는 효과
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
