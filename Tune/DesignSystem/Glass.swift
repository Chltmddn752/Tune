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
    /// 사용자가 진행 토스트를 손으로 닫았다. 같은 작업이 끝날 때까지 다시 띄우지 않는다.
    private(set) var progressDismissed = false
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// 진행 중 안내. 계속 같은 토스트의 글자만 바꾼다.
    func progress(_ message: String, symbol: String? = nil, action: (@MainActor () -> Void)? = nil) {
        if current?.isProgress == true {
            current?.message = message
            current?.action = action
            return
        }
        // 스와이프로 닫은 작업은 끝날 때까지 다시 띄우지 않는다(작업은 계속된다).
        guard !progressDismissed else { return }
        // 짧은 안내가 떠 있어도 진행 안내가 우선한다. 그 안내는 큐에 다시 넣지 않는다.
        dismissTask?.cancel()
        display(Toast(message: message, symbol: symbol, actionTitle: nil, action: action,
                      isProgress: true, duration: nil))
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

    /// 진행 안내만 닫는다. 결과 안내나 대기 중인 메시지는 건드리지 않는다.
    /// (진행 안내는 시간 제한이 없어서, 끝났다는 신호를 따로 받아야 사라진다)
    func endProgress() {
        progressDismissed = false
        guard current?.isProgress == true else { return }
        advance()
    }

    /// 진행 안내를 결과 안내로 바꾼다.
    func finish(_ message: String, symbol: String? = "checkmark.circle.fill", actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        progressDismissed = false
        guard let progress = current, progress.isProgress else {
            show(message, symbol: symbol, actionTitle: actionTitle, action: action)
            return
        }
        dismissTask?.cancel()
        current = Toast(message: message, symbol: symbol, actionTitle: actionTitle, action: action, isProgress: false, duration: .seconds(3))
        scheduleDismiss(for: current?.id)
    }

    func dismiss() {
        // 진행 안내를 닫으면 그 작업이 끝날 때까지 다시 띄우지 않는다.
        if current?.isProgress == true { progressDismissed = true }
        advance()
    }

    /// 다음 안내로 넘어간다. 진행 안내 숨김 상태는 건드리지 않는다.
    private func advance() {
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

/// 화면 아래(미니 플레이어 바로 위)에 뜨는 Material 3 스낵바.
/// 아래·좌·우로 밀면 닫힌다.
struct GlassToastHost: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var drag: CGSize = .zero

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: Spacing.s) {
            if let toast = toasts.current {
                content(toast)
                    .offset(x: drag.width, y: drag.height)
                    .opacity(1 - min(0.75, max(abs(drag.width), abs(drag.height)) / 260))
                    .gesture(dismissGesture)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Spacing.l)
        .animation(.smooth(duration: 0.28), value: toasts.current?.id)
        .allowsHitTesting(toasts.current != nil)
        .onChange(of: toasts.current?.id) { _, _ in drag = .zero }
    }

    /// 손가락을 따라 움직이다가 충분히 멀거나 빠르면 위로 사라지고, 아니면 제자리로 돌아온다.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in drag = value.translation }
            .onEnded { value in
                let farEnough = value.translation.height > 36 || abs(value.translation.width) > 90
                let fastEnough = value.predictedEndTranslation.height > 140
                    || abs(value.predictedEndTranslation.width) > 220
                if farEnough || fastEnough {
                    let end = CGSize(width: value.predictedEndTranslation.width,
                                     height: max(value.predictedEndTranslation.height, 180))
                    withAnimation(.smooth(duration: 0.2)) { drag = end }
                    toasts.dismiss()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) { drag = .zero }
                }
            }
    }

    private func content(_ toast: ToastCenter.Toast) -> some View {
        HStack(spacing: Spacing.m) {
            if toast.isProgress {
                ProgressView().controlSize(.small).tint(Color.m3InversePrimary)
            } else if let symbol = toast.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Color.m3InversePrimary)
                    .font(.system(size: 18, weight: .semibold))
            }

            Text(toast.message)
                .font(.m3BodyMedium.weight(.medium))
                .foregroundStyle(Color.m3InverseOnSurface)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    toasts.dismiss()
                }
                .font(.m3LabelLarge.weight(.bold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.m3InversePrimary)
            }

            // 진행 안내에도 닫기 버튼을 둔다(접근성). 작업은 계속된다.
            Button {
                toasts.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.m3InverseOnSurface.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(toast.isProgress ? "진행 안내 숨기기" : "안내 닫기")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, toast.isProgress ? 12 : 10)
        .frame(maxWidth: 560)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            // 탭하면 연결된 화면(활동)을 연다. 버튼이 있는 안내는 버튼이 먼저 받는다.
            guard let action = toast.action else { return }
            action()
            toasts.dismiss()
        }
        .background(Color.m3InverseSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .accessibilityHint("아래로 밀어서 닫을 수 있어요")
    }
}

// MARK: - 글래스 표면

extension View {
    /// Material 3: 유리 대신 색조가 들어간 불투명 면 (tint가 있으면 그 색, 없으면 surfaceContainerHigh).
    func tuneGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        background(tint ?? Color.m3SurfaceContainerHigh, in: shape)
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
        .foregroundStyle(selected ? Color.m3OnPrimary : Color.m3OnSurfaceVariant)
        .tuneGlass(in: Circle(), tint: selected ? Color.m3Primary : nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 하단 액션 바

/// 선택 모드에서 미니 플레이어 자리를 대신하는 글래스 액션 바.
struct GlassActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: Spacing.m) {
            content()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: 560)
        .background(Color.m3SurfaceContainer, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.s)
    }
}

// MARK: - 검색 스코프

/// Material 3 필터 칩 줄 (선택한 칩은 체크 + secondaryContainer).
struct GlassSegmented<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    var onChange: ((Item) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    M3FilterChip(title: title(item), isSelected: selection == item) {
                        withAnimation(M3Motion.standard) { selection = item }
                        onChange?(item)
                    }
                }
            }
            .padding(.horizontal, Spacing.screen(nil))
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, Spacing.s)
    }
}
