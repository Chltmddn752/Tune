import SwiftUI

// Material 3 Expressive 부품들 (SpatialFlow 화면에서 쓰는 모양 그대로)

// MARK: - 스위치 (켜지면 손잡이 안에 체크)

struct M3ToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.l) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            M3Switch(isOn: configuration.isOn) {
                configuration.isOn.toggle()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

struct M3Switch: View {
    var isOn: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.m3Primary : Color.m3SurfaceContainerHighest)
                    .overlay {
                        Capsule().strokeBorder(isOn ? Color.clear : Color.m3Outline, lineWidth: 2)
                    }
                    .frame(width: 52, height: 32)
                Circle()
                    .fill(isOn ? Color.m3OnPrimary : Color.m3Outline)
                    .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.m3Primary)
                        }
                    }
                    .padding(.horizontal, isOn ? 4 : 8)
            }
            .opacity(isEnabled ? 1 : 0.38)
            .animation(M3Motion.press, value: isOn)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - 필터 칩 (모서리 8, 고르면 체크 + secondaryContainer)

struct M3FilterChip: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.scale.combined(with: .opacity))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.m3LabelLarge.weight(.semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.m3LabelSmall.weight(.bold))
                        .foregroundStyle(Color.m3OnPrimary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.m3Primary, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .foregroundStyle(isSelected ? Color.m3OnSecondaryContainer : Color.m3OnSurfaceVariant)
            .background(isSelected ? Color.m3SecondaryContainer : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color.m3OutlineVariant, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(M3Motion.standard, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 재생 화면 알약 칩 (높이 36, 아이콘 18 + 글자 12)

struct M3PillChip<Icon: View>: View {
    let label: String
    var isSelected = false
    /// 0...1이면 바탕이 왼쪽부터 차오른다(다운로드 진행 등).
    var progress: Double? = nil
    var colors: M3PlayerColors
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18, height: 18)
                Text(label)
                    .font(.m3(12, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? colors.accent : colors.content.opacity(0.8))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                ZStack(alignment: .leading) {
                    Capsule().fill(isSelected ? colors.accent.opacity(0.25) : colors.chip)
                    if let progress, progress > 0 {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(colors.accent.opacity(0.35))
                                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                        .clipShape(Capsule())
                        .animation(M3Motion.spring(stiffness: 150, damping: 0.85), value: progress)
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension M3PillChip where Icon == Image {
    init(_ label: String, systemImage: String, isSelected: Bool = false, progress: Double? = nil,
         colors: M3PlayerColors, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.progress = progress
        self.colors = colors
        self.action = action
        self.icon = { Image(systemName: systemImage) }
    }
}

// MARK: - 누르면 모서리가 줄고 살짝 넓어지는 버튼 (M3 Expressive ButtonGroup)

struct M3ExpressiveButtonStyle: ButtonStyle {
    var container: Color
    var content: Color
    var radius: CGFloat = 28
    var pressedRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(container, in: RoundedRectangle(cornerRadius: pressed ? pressedRadius : radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(x: pressed ? 1.06 : 1, y: pressed ? 0.98 : 1)
            .animation(M3Motion.press, value: pressed)
    }
}

// MARK: - 세그먼트 카드 묶음 (설정·효과·대기열에서 쓰는 붙은 카드)

/// 안에 넣은 줄마다 카드 한 칸씩. 첫 칸은 위, 마지막 칸은 아래만 크게 둥글다.
struct M3Group<Content: View>: View {
    var outer: CGFloat = 28
    var inner: CGFloat = 4
    var fill: Color = .m3SurfaceContainerHigh
    var padding = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(spacing: M3Shape.segmentGap) {
                ForEach(subviews.indices, id: \.self) { index in
                    subviews[index]
                        .padding(padding)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(fill, in: M3Shape.segment(index: index, count: subviews.count, outer: outer, inner: inner))
                }
            }
        }
    }
}

/// 묶음 위 파란 소제목 (위 24 / 아래 12)
struct M3SectionTitle: View {
    let title: String
    var footer: String? = nil

    var body: some View {
        Text(title)
            .font(.m3TitleSmall.weight(.semibold))
            .foregroundStyle(Color.m3Primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }
}

/// 묶음 아래 설명 글
struct M3Footnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.m3BodySmall)
            .foregroundStyle(Color.m3OnSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

/// 묶음 안 한 줄: 제목 + 설명 + 오른쪽 부품
struct M3Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.l) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.m3OnSurfaceVariant)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.m3BodyLarge)
                    .foregroundStyle(Color.m3OnSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(.m3BodyMedium)
                        .foregroundStyle(Color.m3OnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .contentShape(Rectangle())
    }
}

extension M3Row where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = EmptyView()
    }
}

/// 설정 첫 화면의 카테고리 줄: 48pt 원 안 아이콘 + 제목 + 설명
struct M3CategoryRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.l) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.m3OnPrimaryContainer)
                .frame(width: 48, height: 48)
                .background(Color.m3PrimaryContainer, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.m3TitleMedium.weight(.semibold))
                    .foregroundStyle(Color.m3OnSurface)
                Text(subtitle)
                    .font(.m3BodyMedium)
                    .foregroundStyle(Color.m3OnSurfaceVariant)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - 탭 맨 위 제목 줄

struct M3TabHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Text(title)
                .font(.m3(30, .bold))
                .foregroundStyle(Color.m3OnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: Spacing.s)
            trailing
        }
        .frame(minHeight: 52)
    }
}

extension M3TabHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// 제목 줄 오른쪽 아이콘 버튼 (40pt)
struct M3IconButton: View {
    let systemImage: String
    let label: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(filled ? Color.m3OnSecondaryContainer : Color.m3OnSurfaceVariant)
                .frame(width: 40, height: 40)
                .background(filled ? Color.m3SecondaryContainer : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 섹션 제목 + Play all / 더 보기

struct M3ShelfHeader: View {
    let title: String
    var playAll: (() -> Void)? = nil
    var destination: Route? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Text(title)
                .font(.m3(24, .semibold))
                .foregroundStyle(Color.m3OnSurface)
                .lineLimit(1)
            Spacer(minLength: Spacing.s)
            if let playAll {
                Button(action: playAll) {
                    Text("모두 재생")
                        .font(.m3LabelMedium.weight(.semibold))
                        .foregroundStyle(Color.m3OnSurface)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .overlay(Capsule().strokeBorder(Color.m3OutlineVariant, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if let destination {
                NavigationLink(value: destination) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.m3OnSurfaceVariant)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) 모두 보기")
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - 쉬머 (로딩 뼈대)

struct M3Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.18), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func m3Shimmer() -> some View { modifier(M3Shimmer()) }

    /// M3 카드 바탕 (surfaceContainerHigh + 큰 모서리)
    func m3Card(_ fill: Color = .m3SurfaceContainerHigh, radius: CGFloat = 24) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - 위쪽에서 사라지는 색 그라데이션 (Explore 배경)

struct M3TopGradient: View {
    var height: CGFloat = 500
    var scrollOffset: CGFloat = 0

    var body: some View {
        LinearGradient(
            colors: [Color.m3Primary.opacity(0.2), Color.m3Tertiary.opacity(0.15),
                     Color.m3Secondary.opacity(0.05), Color.m3Background],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .opacity(Double(max(0, min(1, 1 - scrollOffset / 600))))
        .offset(y: -scrollOffset * 0.1)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 하단바 숨김 신호

/// 스크롤을 내리면 하단바를 숨기고, 올리면 다시 보인다(10pt 이상 움직였을 때만).
struct M3HidesNavOnScroll: ViewModifier {
    @Environment(Router.self) private var router
    @State private var last: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                let delta = offset - last
                if offset < 40 {
                    if router.navHidden { router.navHidden = false }
                    last = offset
                } else if delta > 10 {
                    if !router.navHidden { router.navHidden = true }
                    last = offset
                } else if delta < -10 {
                    if router.navHidden { router.navHidden = false }
                    last = offset
                }
            }
    }
}

extension View {
    func m3HidesNavOnScroll() -> some View { modifier(M3HidesNavOnScroll()) }
}
