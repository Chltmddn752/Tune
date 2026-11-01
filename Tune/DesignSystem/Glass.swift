import SwiftUI

// MARK: - 토스트

/// 화면 위에 잠깐 떠 있는 안내. 한 번에 하나만 보여 주고 나머지는 줄을 세운다.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable {
        let id = UUID()
        var message: String
        var symbol: String?
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
        var isProgress = false
        var duration: Duration? = .seconds(3)
    }

    private(set) var current: Toast?
    private var queue: [Toast] = []
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// 진행 중 안내. 계속 같은 토스트의 글자만 바꾼다.
    func progress(_ message: String, symbol: String? = nil) {
        if current?.isProgress == true {
            current?.message = message
            return
        }
        show(message, symbol: symbol, isProgress: true, duration: nil)
    }

    func show(
        _ message: String,
        symbol: String? = nil,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil,
        isProgress: Bool = false,
        duration: Duration? = .seconds(3)
    ) {
        guard !message.isEmpty else { return }
        if current == nil {
            display(Toast(message: message, symbol: symbol, actionTitle: actionTitle, action: action, isProgress: isProgress, duration: duration))
            return
        }
        // 같은 내용이 이미 떠 있으면 쌓지 않는다.
        if current?.message == message, current?.actionTitle == nil, !isProgress { return }
        if queue.contains(where: { $0.message == message }) { return }
        queue.append(Toast(message: message, symbol: symbol, actionTitle: actionTitle, action: action, isProgress: isProgress, duration: duration))
        if queue.count > 4 { queue.removeFirst(queue.count - 4) }
    }

    /// 진행 안내를 결과 안내로 바꾼다.
    func finish(_ message: String, symbol: String? = "checkmark.circle.fill", actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        guard let progress = current, progress.isProgress else {
            show(message, symbol: symbol, actionTitle: actionTitle, action: action)
            return
        }
        dismissTask?.cancel()
        current = Toast(message: message, symbol: symbol, actionTitle: actionTitle, action: action, isProgress: false, duration: .seconds(3))
        scheduleDismiss(for: current?.id)
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if self.current == nil { self.display(next) }
        }
    }

    private func display(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        scheduleDismiss(for: toast.id)
    }

    private func scheduleDismiss(for id: UUID?) {
        guard let id, let duration = current?.duration else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, current?.id == id else { return }
            dismiss()
        }
    }
}

/// 화면 맨 위에 뜨는 글래스 안내.
struct GlassToastHost: View {
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: Spacing.s) {
            if let toast = toasts.current {
                content(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xs)
        .animation(.smooth(duration: 0.28), value: toasts.current?.id)
        .allowsHitTesting(toasts.current != nil)
    }

    private func content(_ toast: ToastCenter.Toast) -> some View {
        HStack(spacing: Spacing.m) {
            if toast.isProgress {
                ProgressView().controlSize(.small)
            } else if let symbol = toast.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Color.tuneAccent)
                    .font(.subheadline.weight(.semibold))
            }

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    toasts.dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tuneAccent)
            }

            if !toast.isProgress {
                Button {
                    toasts.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("안내 닫기")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, toast.isProgress ? 12 : 10)
        .frame(maxWidth: 520)
        .tuneGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - 글래스 표면

extension View {
    /// Reduce Transparency에서는 불투명 면으로 대신한다.
    @ViewBuilder
    func tuneGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if UIAccessibility.isReduceTransparencyEnabled {
            background(tint?.opacity(0.22) ?? Color(.secondarySystemBackground), in: shape)
        } else if let tint {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            glassEffect(.regular.interactive(), in: shape)
        }
    }
}

// MARK: - 아이콘 버튼

/// 44×44 히트 영역을 가진 글래스 아이콘 버튼.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var selected = false
    var tint: Color { .tuneAccent }
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .tuneGlass(in: Circle(), tint: selected ? tint : nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 하단 액션 바

/// 선택 모드에서 미니 플레이어 자리를 대신하는 글래스 액션 바.
struct GlassActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: Spacing.m) {
                content()
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: 560)
            .tuneGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.s)
    }
}

// MARK: - 검색 스코프

/// 선택한 칩만 글래스로 띄우는 가로 스코프 바.
struct GlassSegmented<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    var onChange: ((Item) -> Void)? = nil

    @Namespace private var namespace

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        let isSelected = selection == item
                        Button {
                            withAnimation(.smooth(duration: 0.28)) { selection = item }
                            onChange?(item)
                        } label: {
                            Text(title(item))
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .modifier(SelectedGlass(isSelected: isSelected, namespace: namespace, id: item))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Spacing.screen(nil))
            }
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, Spacing.s)
    }
}

private struct SelectedGlass<ID: Hashable>: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID
    let id: ID

    func body(content: Content) -> some View {
        if isSelected {
            content
                .tuneGlass(in: Capsule(), tint: .tuneAccent)
                .glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}
