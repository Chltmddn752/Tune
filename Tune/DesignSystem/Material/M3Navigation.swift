import SwiftUI

/// 하단 내비게이션 바 · 내비게이션 레일에 들어가는 항목
struct M3NavItem: Identifiable {
    let tab: AppTab
    let title: String
    let icon: String
    let selectedIcon: String
    var badge: Int = 0
    var id: AppTab { tab }
}

/// SpatialFlow 하단 바: 높이 80, 선택한 항목은 알약(64×32) 인디케이터 안에 아이콘.
/// '동적 하단바'를 켜면 64로 낮아지고 아이콘이 커진다.
struct M3NavigationBar: View {
    let items: [M3NavItem]
    @Binding var selection: AppTab
    var onReselect: (AppTab) -> Void = { _ in }

    @AppStorage(M3SettingsKey.hideNavLabels) private var hideLabels = false
    @AppStorage(M3SettingsKey.dynamicNavStyle) private var dynamicStyle = false
    @Namespace private var indicator

    static func height(dynamicStyle: Bool) -> CGFloat { dynamicStyle ? 64 : 80 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let selected = item.tab == selection
                Button {
                    if selected {
                        onReselect(item.tab)
                    } else {
                        withAnimation(M3Motion.tab) { selection = item.tab }
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if selected {
                                Capsule()
                                    .fill(Color.m3SecondaryContainer)
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                            Image(systemName: selected ? item.selectedIcon : item.icon)
                                .font(.system(size: dynamicStyle ? 24 : 20, weight: dynamicStyle ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.m3OnSecondaryContainer : Color.m3OnSurfaceVariant)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .frame(width: 64, height: 32)
                        .overlay(alignment: .topTrailing) {
                            if item.badge > 0 {
                                Text(item.badge > 99 ? "99+" : "\(item.badge)")
                                    .font(.m3(10, .bold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Color.m3Error, in: Capsule())
                                    .offset(x: -8, y: -2)
                            }
                        }
                        if !hideLabels {
                            Text(item.title)
                                .font(.m3LabelMedium.weight(selected ? .bold : .medium))
                                .foregroundStyle(selected ? Color.m3OnSurface : Color.m3OnSurfaceVariant)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height(dynamicStyle: dynamicStyle))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .background {
            Color.m3SurfaceContainer
                .shadow(color: .black.opacity(dynamicStyle ? 0.18 : 0.08), radius: dynamicStyle ? 8 : 3, y: -1)
                .ignoresSafeArea(edges: .bottom)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .animation(M3Motion.standard, value: dynamicStyle)
    }
}

/// 아이패드: 왼쪽 내비게이션 레일 (폭 88)
struct M3NavigationRail: View {
    let items: [M3NavItem]
    @Binding var selection: AppTab
    var onReselect: (AppTab) -> Void = { _ in }
    var onNewPlaylist: () -> Void

    @Namespace private var indicator

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onNewPlaylist) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.m3OnPrimaryContainer)
                    .frame(width: 56, height: 56)
                    .background(Color.m3PrimaryContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("새로운 플레이리스트")
            .padding(.bottom, 20)

            ForEach(items) { item in
                let selected = item.tab == selection
                Button {
                    if selected {
                        onReselect(item.tab)
                    } else {
                        withAnimation(M3Motion.tab) { selection = item.tab }
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if selected {
                                Capsule()
                                    .fill(Color.m3SecondaryContainer)
                                    .matchedGeometryEffect(id: "rail", in: indicator)
                            }
                            Image(systemName: selected ? item.selectedIcon : item.icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(selected ? Color.m3OnSecondaryContainer : Color.m3OnSurfaceVariant)
                        }
                        .frame(width: 56, height: 32)
                        .overlay(alignment: .topTrailing) {
                            if item.badge > 0 {
                                Circle().fill(Color.m3Error).frame(width: 8, height: 8).offset(x: -10, y: 2)
                            }
                        }
                        Text(item.title)
                            .font(.m3LabelMedium.weight(selected ? .bold : .medium))
                            .foregroundStyle(selected ? Color.m3OnSurface : Color.m3OnSurfaceVariant)
                    }
                    .frame(width: 80, height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.top, 24)
        .frame(width: 88)
        .frame(maxHeight: .infinity)
        .background(Color.m3Shell.ignoresSafeArea())
    }
}
