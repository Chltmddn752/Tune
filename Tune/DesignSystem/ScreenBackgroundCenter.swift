import Observation
import SwiftUI

/// 왼쪽에서 지금 보이는 화면의 배경색을 오른쪽 재생 패널과 공유한다.
/// 그라데이션 화면은 색을 올리고, 그라데이션이 없는 화면은 nil을 올린다.
@MainActor
@Observable
final class ScreenBackgroundCenter {
    struct Info: Equatable {
        var colors: [Color]
        var style: ArtworkGradientBackground.Style
        var isLight = false
        var parallax: CGFloat = 0
        /// 왼쪽 화면의 전역 프레임. 이 프레임을 기준으로 창 전체 그라데이션을 자른다.
        var frame: CGRect = .zero
        /// 있으면 메시 대신 커버 아래쪽 색 → 맨 아래 색으로 칠한다(앨범 화면).
        var backdrop: CoverBackdrop?
    }

    private(set) var current: Info?

    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var order: [UUID] = []

    private struct Entry {
        var value: Info?
    }

    /// 화면이 나타날 때 부른다. nil이면 기본 배경으로 돌린다.
    func show(id: UUID, value: Info?) {
        entries[id] = Entry(value: value)
        order.removeAll { $0 == id }
        order.append(id)
        refresh()
    }

    /// 이미 떠 있는 화면의 색이나 프레임만 바꾼다(순서는 건드리지 않는다).
    func update(id: UUID, value: Info?) {
        guard entries[id] != nil else {
            show(id: id, value: value)
            return
        }
        entries[id] = Entry(value: value)
        refresh()
    }

    func hide(id: UUID) {
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
        refresh()
    }

    private func refresh() {
        guard let id = order.last, let value = entries[id]?.value else {
            current = nil
            return
        }
        current = value
    }
}

/// 화면이 자기 배경 정보를 알리고, 같은 창 기준 그라데이션을 배경으로 그린다.
private struct ScreenBackgroundModifier: ViewModifier {
    let value: ScreenBackgroundCenter.Info?

    @Environment(ScreenBackgroundCenter.self) private var center
    @State private var id = UUID()
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background {
                if let value {
                    ContinuousGradientBackground(
                        colors: value.colors,
                        style: value.style,
                        isLight: value.isLight,
                        parallax: value.parallax,
                        backdrop: value.backdrop
                    ) { newFrame in
                        frame = newFrame
                        var info = value
                        info.frame = newFrame
                        center.update(id: id, value: info)
                    }
                }
            }
            .onAppear {
                if var info = value {
                    info.frame = frame
                    center.show(id: id, value: info)
                } else {
                    center.show(id: id, value: nil)
                }
            }
            .onDisappear { center.hide(id: id) }
            .onChange(of: value) { _, newValue in
                guard let newValue else {
                    center.update(id: id, value: nil)
                    return
                }
                var info = newValue
                info.frame = frame
                center.update(id: id, value: info)
            }
    }
}

extension View {
    /// 이 화면의 배경색을 패널과 공유한다. nil이면 왼쪽 화면과 같은 기본 배경을 쓴다.
    func screenBackground(_ value: ScreenBackgroundCenter.Info?) -> some View {
        modifier(ScreenBackgroundModifier(value: value))
    }
}
