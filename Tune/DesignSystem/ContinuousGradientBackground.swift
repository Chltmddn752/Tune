import SwiftUI

/// 창 전체를 기준으로 정의한 그라데이션을, 이 뷰의 전역 위치만큼 옮겨 그린다.
/// 왼쪽 화면과 오른쪽 재생 패널이 같은 캔버스를 각자 잘라 쓰므로 카드 바깥 테두리가 이어진다.
struct ContinuousGradientBackground: View {
    var colors: [Color]
    var style: ArtworkGradientBackground.Style = .vivid
    var isLight = false
    var parallax: CGFloat = 0
    /// 있으면 메시 대신 커버 아래쪽 색 → 맨 아래 색 캔버스를 그린다.
    var backdrop: CoverBackdrop?
    /// 왼쪽 화면의 전역 프레임. nil이면 이 뷰 자신의 프레임을 기준으로 쓴다.
    var anchor: CGRect?
    var edges: Edge.Set = .all
    var onFrameChange: ((CGRect) -> Void)?

    @Environment(\.windowSize) private var windowSize

    init(
        colors: [Color],
        style: ArtworkGradientBackground.Style = .vivid,
        isLight: Bool = false,
        parallax: CGFloat = 0,
        backdrop: CoverBackdrop? = nil,
        anchor: CGRect? = nil,
        edges: Edge.Set = .all,
        onFrameChange: ((CGRect) -> Void)? = nil
    ) {
        self.colors = colors
        self.style = style
        self.isLight = isLight
        self.parallax = parallax
        self.backdrop = backdrop
        self.anchor = anchor
        self.edges = edges
        self.onFrameChange = onFrameChange
    }

    var body: some View {
        GeometryReader { proxy in
            let target = proxy.frame(in: .global)
            let source = anchor ?? target
            let window = resolvedWindow(fallback: target)
            let canvasWidth = max(1, window.width - source.minX)
            let sourceWidth = min(max(source.width, 1), canvasWidth)
            let split = sourceWidth / canvasWidth

            gradientCanvas(split: split, canvasWidth: canvasWidth, height: window.height)
                .frame(width: canvasWidth, height: window.height, alignment: .topLeading)
                .offset(x: source.minX - target.minX, y: -target.minY)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .onAppear { onFrameChange?(target) }
                .onChange(of: target) { _, newFrame in onFrameChange?(newFrame) }
        }
        .ignoresSafeArea(edges: edges)
        .allowsHitTesting(false)
    }

    private func resolvedWindow(fallback: CGRect) -> CGSize {
        let width = windowSize.width > 1 ? windowSize.width : fallback.maxX
        let height = windowSize.height > 1 ? windowSize.height : fallback.maxY
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private func gradientCanvas(split: CGFloat, canvasWidth: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let backdrop {
                backdropCanvas(backdrop, split: split)
            } else {
                mesh(split: split)
                    .scaleEffect(1.3)
                    .offset(y: -min(max(parallax, 0), 320) * 0.1)

                overlay
            }
        }
        .frame(width: canvasWidth, height: height)
        .animation(.backgroundFade, value: colors)
        .animation(.backgroundFade, value: isLight)
        .animation(.backgroundFade, value: backdrop)
    }

    /// 왼쪽 화면 폭에 커버 아래쪽 색을 펼치고, 패널 쪽은 오른쪽 끝 색을 이어 간다.
    private func backdropCanvas(_ backdrop: CoverBackdrop, split: CGFloat) -> some View {
        ZStack {
            backdrop.bottom
            LinearGradient(stops: backdrop.edgeStops(span: min(split, 1)), startPoint: .leading, endPoint: .trailing)
                .mask { SmoothFade.mask(from: 0.12, to: 0.55) }
        }
    }

    @ViewBuilder
    private func mesh(split: CGFloat) -> some View {
        let base = baseColors
        if split >= 0.999 {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: [0, 1, 2, 2, 0, 3, 1, 3, 0].map { base[$0 % base.count] }
            )
        } else {
            let s = min(max(split, 0.05), 0.999)
            // 각 색 위치를 창 전체 캔버스의 1.3배 확대 기준으로 되돌린다.
            // 왼쪽 화면 영역(split)은 지금의 3×3 메시와 같은 위치를 유지하고,
            // 오른쪽은 마지막 색을 이어 붙인다.
            let x0 = 0.15 * (1 - s) / 1.3
            let x1 = (0.5 * s + 0.15) / 1.3
            let x2 = (1.15 * s + 0.15) / 1.3
            MeshGradient(
                width: 4, height: 3,
                points: [
                    [Float(x0), 0], [Float(x1), 0], [Float(x2), 0], [1, 0],
                    [Float(x0), 0.5], [Float(x1), 0.5], [Float(x2), 0.5], [1, 0.5],
                    [Float(x0), 1], [Float(x1), 1], [Float(x2), 1], [1, 1]
                ],
                colors: [0, 1, 2, 2, 2, 0, 3, 3, 1, 3, 0, 0].map { base[$0 % base.count] }
            )
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch style {
        case .vivid:
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.28), location: 0.55),
                    .init(color: .black.opacity(isLight ? 0.18 : 0.55), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        case .soft:
            LinearGradient(
                stops: [
                    .init(color: Color(.systemBackground).opacity(0), location: 0),
                    .init(color: Color(.systemBackground).opacity(0.55), location: 0.55),
                    .init(color: Color(.systemBackground), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var baseColors: [Color] {
        let base = colors.isEmpty ? [Color(.systemGray4)] : Array(colors.prefix(4))
        return base
    }
}

private struct WindowSizeKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    /// RootView가 창 전체 크기를 읽어 내려 준다.
    var windowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}
