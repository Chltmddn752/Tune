import AVKit
import MediaPlayer
import SwiftUI

// MARK: - 고무 슬라이더 (진행 막대 · 볼륨)

/// 누르면 두꺼워지고, 끝에서 더 당기면 고무처럼 늘어나는 슬라이더.
struct ElasticSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var height: CGFloat = 7
    var activeHeight: CGFloat = 12
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var dragStartValue: Double = 0
    @State private var stretch: CGFloat = 0
    @State private var hitExtreme = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = range.upperBound > range.lowerBound
                ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
            let trackHeight = isDragging ? activeHeight : height

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white.opacity(isDragging ? 1 : 0.75))
                    .frame(width: max(0, min(width, width * fraction)))
            }
            .frame(width: width + abs(stretch), height: trackHeight)
            .offset(x: stretch < 0 ? stretch : 0)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            onEditingChanged(true)
                        }
                        let span = range.upperBound - range.lowerBound
                        let proposed = dragStartValue + Double(gesture.translation.width / max(width, 1)) * span
                        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
                        value = clamped
                        // 범위를 넘어서 당기면 고무처럼 조금만 늘어난다.
                        let overshoot = (proposed - clamped) / span * Double(width)
                        stretch = CGFloat(overshoot >= 0 ? rubber(overshoot) : -rubber(-overshoot))
                        let extreme = clamped == range.lowerBound || clamped == range.upperBound
                        if extreme != hitExtreme { hitExtreme = extreme }
                    }
                    .onEnded { _ in
                        isDragging = false
                        stretch = 0
                        onEditingChanged(false)
                    }
            )
            .animation(.sliderPress, value: isDragging)
            .animation(.sliderPress, value: stretch == 0)
        }
        .frame(height: 24)
        .sensoryFeedback(.increase, trigger: hitExtreme) { _, new in new }
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001) * 100))%"))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func rubber(_ distance: Double) -> Double {
        let limit = 18.0
        return limit * (1 - exp(-distance / 60))
    }
}

// MARK: - 흐르는 글자

/// 칸보다 길면 옆으로 천천히 흐르는 한 줄 글자.
struct MarqueeText: View {
    let text: String
    var font: Font = .tunePlayerTitle

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var startDate = Date()

    var body: some View {
        let overflow = textWidth > containerWidth + 1
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !overflow)) { context in
                let gap: CGFloat = 40
                let cycle = Double(textWidth + gap) / 30 + 3 // 3초 쉼
                let elapsed = context.date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: max(cycle, 0.1))
                let moving = max(0, elapsed - 3)
                let offset = overflow ? -CGFloat(moving * 30) : 0
                HStack(spacing: gap) {
                    label
                    if overflow { label }
                }
                .offset(x: offset)
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .onAppear { containerWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, new in containerWidth = new }
        }
        .frame(height: lineHeight)
        .clipped()
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: overflow ? 8 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: overflow ? 16 : 0)
            }
        )
        .onChange(of: text) { _, _ in startDate = Date() }
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }

    private var lineHeight: CGFloat {
        font == .tunePlayerTitle ? 26 : 20
    }
}

// MARK: - 움직이는 배경

/// 커버에서 뽑은 색으로 천천히 움직이는 메시 그라데이션.
struct MeshBackground: View {
    var colors: [Color]
    var fallback: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = filled()
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate)
            let w: (Float, Float) -> Float = { speed, phase in reduceMotion ? 0 : sin(t * speed + phase) * 0.12 }
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + w(0.21, 0), 0], [1, 0],
                    [0, 0.5 + w(0.17, 1)], [0.5 + w(0.23, 2), 0.5 + w(0.19, 3)], [1, 0.5 + w(0.15, 4)],
                    [0, 1], [0.5 + w(0.2, 5), 1], [1, 1]
                ],
                colors: palette
            )
        }
        .overlay(Color.black.opacity(0.28))
        .ignoresSafeArea()
        .animation(.backgroundFade, value: colors)
    }

    private func filled() -> [Color] {
        let base = colors.isEmpty ? [fallback, fallback.opacity(0.8), .black] : colors
        let order = [0, 1, 2, 2, 0, 3, 1, 3, 0]
        return order.map { base[$0 % base.count] }
    }
}

// MARK: - AirPlay · 볼륨

struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint.withAlphaComponent(0.8)
        view.activeTintColor = tint
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint.withAlphaComponent(0.8)
    }
}

/// 기기 볼륨을 읽고 바꾼다. iOS는 볼륨을 직접 바꾸는 API가 없어서 숨긴 MPVolumeView의 슬라이더를 쓴다.
@MainActor
@Observable
final class SystemVolume {
    var level: Double = Double(AVAudioSession.sharedInstance().outputVolume)

    @ObservationIgnored private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            // 볼륨 버튼으로 바뀐 값은 부드럽게 따라가게 한다(손으로 끄는 중에는 set()이 바로 바꾼다).
            Task { @MainActor in
                guard let self, abs(self.level - Double(value)) > 0.001 else { return }
                withAnimation(.smooth(duration: 0.28)) { self.level = Double(value) }
            }
        }
    }

    var hiddenView: MPVolumeView { volumeView }

    func set(_ value: Double) {
        level = value
        if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = Float(value)
        }
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.alpha = 0.01
        container.addSubview(volume.hiddenView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 줄바꿈 배치 (가사 단어)

struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let maxWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            case .trailing: x = bounds.maxX - row.width
            default: x = bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
