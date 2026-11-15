import SwiftUI

// SpatialFlow의 WavyMusicSlider와 CircularWavyProgressIndicator.
// 재생 중에는 지나간 부분이 물결치고, 손으로 잡으면 물결이 잦아들며 손잡이가 세로 막대로 바뀐다.

// MARK: - 물결 선

/// 시작점에서 progress 지점까지 사인파를 그린다. 시작 64pt 동안은 진폭이 0에서 커진다.
struct M3WaveLine: Shape {
    var amplitude: CGFloat
    var endX: CGFloat
    var phase: CGFloat
    var wavelength: CGFloat = 48
    var taper: CGFloat = 64

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(amplitude, endX) }
        set {
            amplitude = newValue.first
            endX = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let start = rect.minX
        let end = max(start, min(endX, rect.maxX))
        guard end > start else { return path }
        let frequency = 2 * CGFloat.pi / wavelength
        let step: CGFloat = max(1.2, wavelength / 20)
        func y(_ x: CGFloat) -> CGFloat {
            let ramp = min(max((x - start) / taper, 0), 1)
            return midY + amplitude * ramp * sin(frequency * x + phase)
        }
        path.move(to: CGPoint(x: start, y: y(start)))
        var x = start + step
        while x < end {
            path.addLine(to: CGPoint(x: x, y: y(x)))
            x += step
        }
        path.addLine(to: CGPoint(x: end, y: y(end)))
        return path
    }
}

// MARK: - 물결 슬라이더

struct M3WavySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var isPlaying: Bool = true
    var wavy: Bool = true
    var activeColor: Color = .white
    var inactiveColor: Color = Color.white.opacity(0.08)
    var thumbColor: Color = .white
    var trackHeight: CGFloat = 4
    var thumbRadius: CGFloat = 6
    var amplitude: CGFloat = 6
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var hapticStep = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private var showsWave: Bool { wavy && isPlaying && !isDragging && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let inset = thumbRadius
            let trackWidth = max(0, width - inset * 2)
            let thumbX = inset + trackWidth * fraction
            let gap: CGFloat = isDragging ? 4 : 0
            let activeEnd = max(inset, thumbX - gap - (isDragging ? trackHeight * 0.6 : 0))

            TimelineView(.animation(minimumInterval: 1 / 60, paused: !showsWave)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t.truncatingRemainder(dividingBy: 2.2)) / 2.2) * 2 * .pi

                ZStack(alignment: .leading) {
                    // 남은 부분: 손잡이 오른쪽부터만 직선
                    Path { path in
                        path.move(to: CGPoint(x: min(thumbX + gap + (isDragging ? 3 : 0), width - inset), y: proxy.size.height / 2))
                        path.addLine(to: CGPoint(x: width - inset, y: proxy.size.height / 2))
                    }
                    .stroke(inactiveColor, style: StrokeStyle(lineWidth: trackHeight, lineCap: .round))

                    // 지난 부분: 물결 + 35%→100% 그라데이션
                    M3WaveLine(amplitude: showsWave ? amplitude : 0, endX: activeEnd - inset, phase: phase)
                        .offset(x: inset)
                        .stroke(
                            LinearGradient(colors: [activeColor.opacity(0.35), activeColor],
                                           startPoint: .leading,
                                           endPoint: UnitPoint(x: max(0.01, activeEnd / max(width, 1)), y: 0.5)),
                            style: StrokeStyle(lineWidth: trackHeight, lineCap: .round, lineJoin: .round)
                        )
                        .animation(.easeInOut(duration: 0.3), value: showsWave)

                    // 손잡이: 평소 원 → 잡으면 세로 막대
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(thumbColor)
                        .frame(width: isDragging ? trackHeight * 1.2 : thumbRadius * 2,
                               height: isDragging ? 20 : thumbRadius * 2)
                        .clipShape(Capsule())
                        .position(x: thumbX, y: proxy.size.height / 2)
                        .animation(.easeOut(duration: 0.25), value: isDragging)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let f = min(max((drag.location.x - inset) / max(trackWidth, 1), 0), 1)
                        value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        let step = Int((f * 50).rounded())
                        if step != hapticStep { hapticStep = step }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
        .sensoryFeedback(.selection, trigger: hapticStep)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100))%")
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            switch direction {
            case .increment: value = min(range.upperBound, value + span * 0.05)
            case .decrement: value = max(range.lowerBound, value - span * 0.05)
            @unknown default: break
            }
        }
    }
}

// MARK: - 물결 원형 진행 표시 (미니 플레이어)

/// 원 둘레가 사인파로 출렁이는 고리. progress만큼만 그린다.
struct M3WavyRing: Shape {
    var progress: CGFloat
    var amplitude: CGFloat
    var phase: CGFloat
    var waves: CGFloat = 10

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, amplitude) }
        set {
            progress = newValue.first
            amplitude = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - amplitude
        let end = max(0, min(progress, 1)) * 2 * .pi
        guard end > 0.001 else { return path }
        let steps = max(8, Int(end / (2 * .pi) * 180))
        for i in 0...steps {
            let angle = CGFloat(i) / CGFloat(steps) * end
            let r = radius + amplitude * sin(waves * angle + phase)
            let point = CGPoint(x: center.x + r * cos(angle - .pi / 2), y: center.y + r * sin(angle - .pi / 2))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct M3WavyProgressRing: View {
    var progress: Double
    var isPlaying: Bool
    var isLoading = false
    var color: Color
    var lineWidth: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(isPlaying || isLoading) || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 5.5) / 5.5) * 2 * .pi
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: lineWidth)
                    .padding(1.5)
                if isLoading {
                    M3WavyRing(progress: 0.3, amplitude: 1.5, phase: phase)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.radians(Double(phase) * 2))
                } else {
                    M3WavyRing(progress: CGFloat(progress), amplitude: isPlaying && !reduceMotion ? 1.5 : 0, phase: phase)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .animation(M3Motion.bouncy, value: isPlaying)
                        .animation(.linear(duration: 0.35), value: progress)
                }
            }
        }
    }
}
