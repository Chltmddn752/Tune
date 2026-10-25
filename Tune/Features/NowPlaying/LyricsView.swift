import SwiftUI

/// Apple Music 방식 가사: 현재 줄이 화면 35% 지점에 머물고, 단어가 불리는 대로 왼쪽부터 밝아진다.
///
/// 부드럽게 돌리기 위한 구조
/// - 매 프레임 다시 그리는 건 "지금 부르는 줄"의 단어들과 간주 점뿐이다.
/// - 나머지 줄의 위치·흐림은 줄이 바뀔 때만 바뀌고, 그 사이는 스프링 애니메이션이 채운다.
/// - 줄이 바뀌는 시각은 매 프레임 확인하지 않고, 다음 줄 시작 시각까지 기다렸다가 깬다.
/// - 화면 밖의 줄은 그리지 않는다.
/// - 줄 높이·단어 위치는 글꼴로 미리 계산해 두고(측정 → 다시 그리기 반복 없음), 같은 가사·폭이면 다시 쓰지 않는다.
/// - 가사 화면을 열 때는 지금 줄 위치에서 바로 시작한다(첫 줄에서 미끄러져 내려오지 않게).
struct LyricsView: View {
    let lyrics: Lyrics?
    var isLoading: Bool
    var onTapEmpty: (() -> Void)? = nil
    /// 패널 안 가사 카드처럼 좁은 곳에서는 글자를 줄인다.
    var scale: CGFloat = 1

    @Environment(PlayerEngine.self) private var player
    @AppStorage(SettingsKey.lyricsBlur) private var blurEnabled = true
    @AppStorage(SettingsKey.lyricsSize) private var size: LyricsSize = .medium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var state = LyricsState.start
    @State private var ready = false
    /// state를 계산한 가사 (곡이 바뀐 직후 이전 곡 줄 위치로 한 번 그려지는 걸 막는다)
    @State private var stateLyricsKey = 0
    @State private var layoutCache = LyricsLayoutCache()
    @State private var dragOffset: CGFloat = 0
    @State private var manualOffset: CGFloat = 0
    @State private var isUserScrolling = false
    /// 한두 줄씩 넘어갈 때만 아래 줄이 조금씩 늦게 따라온다. 멀리 건너뛸 땐 다 같이 움직인다(줄끼리 겹치지 않게).
    @State private var staggered = true
    /// 방금 누른 줄 (살짝 눌리는 효과)
    @State private var pressedLine: Int?
    @State private var resumeTask: Task<Void, Never>?

    private let lineSpacing: CGFloat = 30
    private let backgroundSpacing: CGFloat = 8

    var body: some View {
        Group {
            if let lyrics, lyrics.isSynced, !lyrics.lines.isEmpty {
                synced(lyrics)
            } else if let lyrics, !lyrics.plainText.isEmpty {
                plain(lyrics.plainText)
            } else if isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("가사 없음", systemImage: "quote.bubble",
                                       description: Text("곡과 같은 이름의 .lrc / .ttml 파일을 넣으면 가사가 나와요."))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: 시간 맞춘 가사

    private func synced(_ lyrics: Lyrics) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let layouts = layoutCache.layouts(for: lyrics, width: width, fontSize: (size.points * scale))
            let positions = linePositions(lyrics.lines, layouts: layouts)
            // 처음 그릴 때부터 지금 줄에 맞춰 둔다.
            let current = ready && stateLyricsKey == Self.key(lyrics)
                ? state
                : LyricsState(lyrics: lyrics, time: player.lyricsTime())
            let referenceHeight = layouts[safe: current.reference]?.height ?? 40
            let anchor = geometry.size.height * 0.35 - referenceHeight / 2
            let base = positions[safe: current.reference] ?? 0
            let scroll = manualOffset + dragOffset

            ZStack(alignment: .topLeading) {
                ForEach(lyrics.lines) { line in
                    let i = line.id
                    // 간주 중에는 점 3개가 들어갈 자리를 비운다(점이 앞 줄 글자와 겹치지 않게).
                    let gap: CGFloat = current.inInterlude && i >= current.reference ? 52 : 0
                    let y = (positions[safe: i] ?? 0) - base + anchor + gap
                    let height = layouts[safe: i]?.height ?? 40
                    // 화면 밖(위아래 조금 여유)의 줄은 그리지 않는다.
                    if y + scroll + height > -160, y + scroll < geometry.size.height + 160 {
                        let onScreen = y + scroll + height > 0 && y + scroll < geometry.size.height
                        // 위아래 흐려지는 부분이나 화면 밖(잘려서 안 보여도 누를 수 있었다)에 걸친 줄은 누르지 못하게
                        let middle = y + scroll + height / 2
                        let tappable = middle >= geometry.size.height * 0.03 && middle <= geometry.size.height * 0.95
                        lineView(line, lyrics: lyrics, layout: layouts[safe: i] ?? .empty, state: current,
                                 y: y, width: width, onScreen: onScreen, tappable: tappable)
                    }
                }

                if current.inInterlude {
                    InterludeDots(start: current.interludeStart, end: current.interludeEnd)
                        .offset(y: anchor + 8)
                        .transition(.opacity)
                }
            }
            .offset(y: scroll)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(scrollGesture)
            .onTapGesture { onTapEmpty?() }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
        .clipped()
        // 손으로 넘겨 보는 중이면 지금 부르는 곳으로 돌아가는 버튼
        .overlay(alignment: .bottom) {
            if isUserScrolling {
                Button {
                    resetScroll()
                } label: {
                    Label("지금 가사로", systemImage: "arrow.down.to.line")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isUserScrolling)
        .onAppear {
            update(lyrics, time: player.lyricsTime(), animated: false)
            ready = true
        }
        // 재생 중에는 다음 줄 시각에 맞춰 깨어나고, 멈춰 있을 때는 구간 이동만 반영한다.
        .task(id: ClockKey(lyrics: Self.key(lyrics), playing: player.isPlaying, active: scenePhase == .active)) {
            await runClock(lyrics)
        }
        .background(PausedSeekWatcher { update(lyrics, time: $0) })
    }

    private func press(_ index: Int) {
        withAnimation(.easeOut(duration: 0.1)) { pressedLine = index }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.spring(duration: 0.35, bounce: 0.4)) { if pressedLine == index { pressedLine = nil } }
        }
    }

    /// 가사를 누르면 그 줄(단어를 누르면 그 단어)부터 다시 듣는다.
    private func jump(to time: Double, lyrics: Lyrics) {
        let target = max(0, time - 0.05)
        player.seek(to: target)
        update(lyrics, time: target + 0.05)
        if !player.isPlaying { player.resume() }
        resetScroll()
    }

    static func key(_ lyrics: Lyrics) -> Int {
        var hasher = Hasher()
        hasher.combine(lyrics.lines.count)
        hasher.combine(lyrics.lines.first?.start)
        hasher.combine(lyrics.lines.last?.start)
        hasher.combine(lyrics.lines.last?.text)
        return hasher.finalize()
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, lyrics: Lyrics, layout: LyricLineLayout, state: LyricsState,
                          y: CGFloat, width: CGFloat, onScreen: Bool, tappable: Bool) -> some View {
        let i = line.id
        let isActive = i == state.active
        let distance = abs(i - state.reference)
        let fontSize = line.isBackground ? (size.points * scale) * 0.68 : (size.points * scale)

        // 지금 줄·지난 줄·다음 줄 모두 같은 단어 배치를 써서, 줄이 바뀌어도 글자 자리가 튀지 않는다.
        LyricLineContent(
            line: line,
            layout: layout,
            fontSize: fontSize,
            soft: !line.hasWordTiming,
            phase: isActive ? .active : (i < max(state.active, state.reference) ? .sung : .upcoming),
            onTapWord: { word in
                press(i)
                jump(to: word.start, lyrics: lyrics)
            }
        )
        .frame(width: width, height: layout.height, alignment: .topLeading)
        // 누르는 영역은 줄을 옮기기(offset) 전에 정해야 줄과 함께 움직인다.
        // (뒤에 두면 모든 줄의 누르는 영역이 가사 화면 맨 위에 겹쳐 있었다)
        .contentShape(Rectangle())
        .onTapGesture {
            press(i)
            jump(to: line.start, lyrics: lyrics)
        }
        .scaleEffect(pressedLine == i ? 0.96 : 1, anchor: .leading)
        .opacity(isActive ? 1 : (state.inInterlude ? 0.3 : 0.38))
        .blur(radius: onScreen ? blurRadius(distance: distance, active: isActive) : 0)
        .scaleEffect(isActive ? 1 : 0.97, anchor: .leading)
        .offset(y: y)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .lyricsMove.delay(delay(for: i, reference: state.reference)), value: state.reference)
        .animation(.lyricsScale, value: isActive)
        .allowsHitTesting(tappable)
        .transition(.identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private struct ClockKey: Hashable {
        let lyrics: Int
        let playing: Bool
        let active: Bool
    }

    /// 다음 줄이 시작하거나 간주가 시작되는 시각까지 기다렸다가 상태를 바꾼다.
    private func runClock(_ lyrics: Lyrics) async {
        // 곡이 바뀌었거나 다시 재생할 때 첫 맞춤은 애니메이션 없이
        update(lyrics, time: player.lyricsTime(), animated: false)
        guard player.isPlaying else { return }
        while !Task.isCancelled {
            let now = player.lyricsTime()
            update(lyrics, time: now)
            let next = LyricsState.nextEventTime(lyrics: lyrics, after: now)
            // 구간 이동을 놓치지 않게 길어도 0.25초마다 한 번은 확인한다.
            let wait = min(max(next - now, 0.008), 0.25)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func update(_ lyrics: Lyrics, time: Double, animated: Bool = true) {
        let new = LyricsState(lyrics: lyrics, time: time)
        let key = Self.key(lyrics)
        if stateLyricsKey != key {
            // 다른 곡 가사로 바뀌면 애니메이션 없이 바로 맞춘다.
            stateLyricsKey = key
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state = new }
            return
        }
        guard new != state else { return }
        let step = abs(new.reference - state.reference)
        if (step <= 2) != staggered { staggered = step <= 2 }
        if animated {
            state = new
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state = new }
        }
    }

    private func linePositions(_ lines: [LyricLine], layouts: [LyricLineLayout]) -> [CGFloat] {
        var positions: [CGFloat] = []
        positions.reserveCapacity(lines.count)
        var y: CGFloat = 0
        for index in lines.indices {
            positions.append(y)
            let nextIsBackground = index + 1 < lines.count && lines[index + 1].isBackground
            y += (layouts[safe: index]?.height ?? 40) + (nextIsBackground ? backgroundSpacing : lineSpacing)
        }
        return positions
    }

    /// 지금 줄에서 멀수록 더 흐리게. 손으로 스크롤하는 동안은 흐림 없음.
    private func blurRadius(distance: Int, active: Bool) -> CGFloat {
        guard blurEnabled, !isUserScrolling, !active, distance > 0 else { return 0 }
        return min(CGFloat(distance) * 1.0 + 0.5, 5)
    }

    /// 아래 줄일수록 조금씩 늦게 따라 올라온다.
    private func delay(for index: Int, reference: Int) -> Double {
        guard staggered, index >= reference - 1 else { return 0 }
        return min(Double(index - reference + 1) * 0.035, 0.3)
    }

    private var scrollGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                resumeTask?.cancel()
                if !isUserScrolling { isUserScrolling = true }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                withAnimation(.smooth(duration: 0.4)) {
                    manualOffset += value.translation.height + (value.predictedEndTranslation.height - value.translation.height) * 0.3
                    dragOffset = 0
                }
                resumeTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    resetScroll()
                }
            }
    }

    private func resetScroll() {
        resumeTask?.cancel()
        withAnimation(.lyricsMove) {
            manualOffset = 0
            dragOffset = 0
            isUserScrolling = false
        }
    }

    // MARK: 시간 없는 가사

    private func plain(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: (size.points * scale) * 0.85, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 40)
        }
        .scrollIndicators(.hidden)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.9), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
    }
}

/// 멈춘 상태에서 구간을 옮겼을 때만 알려준다.
/// 재생 시간은 0.25초마다 바뀌는데, 이 작은 뷰만 다시 그려지고 가사 전체는 다시 그려지지 않는다.
private struct PausedSeekWatcher: View {
    let onSeek: (Double) -> Void
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Color.clear
            .onChange(of: player.elapsed) { _, elapsed in
                if !player.isPlaying { onSeek(elapsed) }
            }
    }
}

/// 지금 시각 기준으로 어느 줄이 현재 줄인지, 간주 중인지 계산한다.
/// 줄이 바뀔 때만 값이 달라지므로 이 값이 바뀔 때만 가사 전체를 다시 그린다.
struct LyricsState: Equatable {
    /// 화면 35% 지점에 맞출 줄
    var reference: Int
    /// 밝게 표시할 줄 (간주 중이면 -1)
    var active: Int
    var inInterlude: Bool
    var interludeStart: Double
    var interludeEnd: Double

    static let start = LyricsState(reference: 0, active: -1, inInterlude: false, interludeStart: 0, interludeEnd: 0)

    init(reference: Int, active: Int, inInterlude: Bool, interludeStart: Double, interludeEnd: Double) {
        self.reference = reference
        self.active = active
        self.inInterlude = inInterlude
        self.interludeStart = interludeStart
        self.interludeEnd = interludeEnd
    }

    init(lyrics: Lyrics, time: Double) {
        let lines = lyrics.lines
        guard let index = lyrics.lineIndex(at: time) else {
            // 첫 줄 전
            let first = lines.first?.start ?? 0
            self.init(reference: 0, active: -1, inInterlude: first >= 5 && time < first,
                      interludeStart: 0, interludeEnd: first)
            return
        }
        let line = lines[index]
        let next = lines[(index + 1)...].first { !$0.isBackground }
        let singingEnd = line.singingEnd
        if let next, next.start - singingEnd >= 5, time > singingEnd + 0.5 {
            self.init(reference: next.id, active: -1, inInterlude: true,
                      interludeStart: singingEnd, interludeEnd: next.start)
        } else {
            self.init(reference: index, active: index, inInterlude: false, interludeStart: 0, interludeEnd: 0)
        }
    }

    /// 상태가 바뀔 수 있는 다음 시각 (다음 줄 시작 또는 간주 시작)
    static func nextEventTime(lyrics: Lyrics, after time: Double) -> Double {
        var next = Double.greatestFiniteMagnitude
        for line in lyrics.lines {
            if line.start > time { next = min(next, line.start); break }
        }
        if let index = lyrics.lineIndex(at: time) {
            let interlude = lyrics.lines[index].singingEnd + 0.5
            if interlude > time { next = min(next, interlude) }
        }
        return next
    }
}

/// 가사 한 줄의 단어 자리 (글꼴로 미리 계산)
struct LyricLineLayout {
    var frames: [CGRect]
    /// 줄 폭보다 긴 단어(띄어쓰기 없는 긴 줄)는 그 단어 안에서 줄을 바꾼다.
    var wraps: [Bool]
    var height: CGFloat
    /// 번역 줄 위치 (없으면 nil)
    var translationFrame: CGRect? = nil

    static let empty = LyricLineLayout(frames: [], wraps: [], height: 40)

    static func translationFontSize(_ fontSize: CGFloat) -> CGFloat { max(13, fontSize * 0.56) }

    static func make(_ line: LyricLine, width: CGFloat, fontSize: CGFloat) -> LyricLineLayout {
        let font = UIFont.systemFont(ofSize: fontSize, weight: line.isBackground ? .semibold : .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let available = max(width, 1)

        // 단어 폭은 한 번만 잰다.
        let measured: [(full: CGFloat, ink: CGFloat)] = line.words.map { word in
            let text = word.text as NSString
            let full = ceil(text.size(withAttributes: attributes).width)
            let trimmed = word.text.trimmingCharacters(in: .whitespaces) as NSString
            return (full, trimmed.length == text.length ? full : ceil(trimmed.size(withAttributes: attributes).width))
        }

        // 여러 줄로 넘어가면 줄 길이가 고르게 되는 가장 좁은 폭을 찾는다(한 단어만 다음 줄로 떨어지지 않게).
        var target = available
        let fullRows = rowCount(measured, width: available)
        if fullRows >= 2 {
            var lo = measured.map(\.ink).max() ?? 1
            var hi = available
            for _ in 0..<14 where hi - lo > 1 {
                let mid = (lo + hi) / 2
                if rowCount(measured, width: mid) <= fullRows { hi = mid } else { lo = mid }
            }
            target = min(available, hi + 1)
        }

        var layout = place(line, measured: measured, width: target, available: available, font: font, attributes: attributes)
        if let translation = line.translation, !translation.isEmpty {
            let tFont = UIFont.systemFont(ofSize: translationFontSize(fontSize), weight: .semibold)
            let box = (translation as NSString).boundingRect(
                with: CGSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: tFont], context: nil)
            let frame = CGRect(x: 0, y: layout.height + 4, width: available, height: ceil(box.height))
            layout.translationFrame = frame
            layout.height = frame.maxY
        }
        return layout
    }

    private static func rowCount(_ measured: [(full: CGFloat, ink: CGFloat)], width: CGFloat) -> Int {
        var rows = 1
        var x: CGFloat = 0
        for word in measured {
            if word.ink > width { rows += x > 0 ? 2 : 1; x = 0; continue }
            if x > 0, x + word.ink > width { rows += 1; x = 0 }
            x += word.full
        }
        return rows
    }

    private static func place(_ line: LyricLine, measured: [(full: CGFloat, ink: CGFloat)], width: CGFloat,
                              available: CGFloat, font: UIFont, attributes: [NSAttributedString.Key: Any]) -> LyricLineLayout {
        let rowHeight = ceil(font.lineHeight)
        let rowSpacing: CGFloat = 2
        var frames: [CGRect] = []
        var wraps: [Bool] = []
        var x: CGFloat = 0
        var y: CGFloat = 0

        for (index, word) in line.words.enumerated() {
            let size = measured[index]
            if size.ink > available {
                if x > 0 { y += rowHeight + rowSpacing; x = 0 }
                let box = (word.text as NSString).boundingRect(
                    with: CGSize(width: available, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
                let height = max(ceil(box.height), rowHeight)
                frames.append(CGRect(x: 0, y: y, width: available, height: height))
                wraps.append(true)
                y += height + rowSpacing
                continue
            }
            if x > 0, x + size.ink > width {
                y += rowHeight + rowSpacing
                x = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.full, height: rowHeight))
            wraps.append(false)
            x += size.full
        }
        let height = frames.map(\.maxY).max() ?? rowHeight
        return LyricLineLayout(frames: frames, wraps: wraps, height: max(height, rowHeight))
    }
}

/// 같은 가사·같은 폭·같은 글자 크기면 줄 배치를 다시 계산하지 않는다.
/// 화면을 다시 그리게 만들지 않도록 관찰하지 않는 보통 클래스로 둔다.
final class LyricsLayoutCache {
    private var lyrics: Lyrics?
    private var width: CGFloat = -1
    private var fontSize: CGFloat = -1
    private var layouts: [LyricLineLayout] = []

    func layouts(for lyrics: Lyrics, width: CGFloat, fontSize: CGFloat) -> [LyricLineLayout] {
        if width == self.width, fontSize == self.fontSize, lyrics == self.lyrics { return layouts }
        self.lyrics = lyrics
        self.width = width
        self.fontSize = fontSize
        layouts = lyrics.lines.map { line in
            LyricLineLayout.make(line, width: width, fontSize: line.isBackground ? fontSize * 0.68 : fontSize)
        }
        return layouts
    }
}

/// 가사 한 줄. 지금 부르는 줄만 화면 주사율(최대 120Hz)로 다시 그리고,
/// 나머지 줄은 단어마다 글자 하나만 그린다(가리개·빛 효과 없음).
struct LyricLineContent: View {
    enum Phase: Equatable { case active, sung, upcoming }

    let line: LyricLine
    let layout: LyricLineLayout
    let fontSize: CGFloat
    /// 단어 시간이 어림값이면 경계를 조금 더 부드럽게
    var soft: Bool
    var phase: Phase
    var onTapWord: ((LyricWord) -> Void)? = nil

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let font = Font.system(size: fontSize, weight: line.isBackground ? .semibold : .bold)
        ZStack(alignment: .topLeading) {
            words(font: font)
            // 번역 줄은 매 프레임 다시 그릴 필요가 없어서 밖에 둔다.
            if let translation = line.translation, let frame = layout.translationFrame {
                Text(translation)
                    .font(.system(size: LyricLineLayout.translationFontSize(fontSize), weight: .semibold))
                    .foregroundStyle(.white.opacity(phase == .active ? 0.75 : 0.5))
                    .frame(width: frame.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: frame.minY)
                    .transaction { $0.animation = nil }
            }
        }
    }

    private func words(font: Font) -> some View {
        // 뷰 구조를 항상 같게 두고(깜빡임 방지) 지금 줄일 때만 매 프레임 갱신한다.
        TimelineView(.animation(paused: phase != .active || !player.isPlaying)) { _ in
            let time = phase == .active ? player.lyricsTime() : 0
            ZStack(alignment: .topLeading) {
                ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                    let frame = layout.frames[safe: index] ?? .zero
                    LyricWordView(word: word, time: time, font: font, soft: soft,
                                  phase: phase, wraps: layout.wraps[safe: index] ?? false, width: frame.width)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapWord?(word) }
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }
}

struct LyricWordView: View {
    let word: LyricWord
    let time: Double
    let font: Font
    var soft: Bool
    var phase: LyricLineContent.Phase
    var wraps: Bool
    var width: CGFloat

    var body: some View {
        let active = phase == .active
        let progress = active ? wordProgress : 0

        sized(Text(word.text).font(font))
            .foregroundStyle(.white.opacity(phase == .sung ? 1 : 0.38))
            .overlay(alignment: .topLeading) {
                if active { highlight(progress) }
            }
            .offset(y: active ? -2.5 * easeOut(progress) : 0)
            // 줄이 바뀔 때 글자색은 바로 바꾼다(겹친 두 글자가 따로 바래면 잠깐 어두워진다).
            .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func sized(_ text: some View) -> some View {
        if wraps {
            text.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } else {
            text.fixedSize()
        }
    }

    @ViewBuilder
    private func highlight(_ progress: Double) -> some View {
        let fade = soft ? 0.45 : 0.3
        // 칠해지는 경계가 단어 왼쪽 밖(-fade)에서 오른쪽 밖(1+fade)까지 끊김 없이 지나간다.
        let edge = progress * (1 + fade)
        let lit = sized(Text(word.text).font(font))
            .foregroundStyle(.white)
            .mask {
                LinearGradient(
                    colors: [.white, .white.opacity(0)],
                    startPoint: UnitPoint(x: edge - fade, y: 0.5),
                    endPoint: UnitPoint(x: edge, y: 0.5)
                )
            }
        // 1초 이상 길게 끄는 단어만 은은하게 빛난다(짧은 단어엔 그림자 자체를 안 붙인다).
        if word.end - word.start >= 1 {
            lit.shadow(color: .white.opacity(glow(progress)), radius: 8)
        } else {
            lit
        }
    }

    private var wordProgress: Double {
        let duration = max(word.end - word.start, 0.05)
        return min(max((time - word.start) / duration, 0), 1)
    }

    private func glow(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        return 0.55 * sin(p * .pi)
    }

    private func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
}

/// 간주 중에 숨 쉬듯 커졌다 작아지는 점 3개
struct InterludeDots: View {
    let start: Double
    let end: Double
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { context in
            let time = player.lyricsTime()
            let progress = end > start ? min(max((time - start) / (end - start), 0), 1) : 0
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.12 * sin(t * 2.4)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    let fill = min(max(progress * 3 - Double(i), 0), 1)
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * fill))
                        .frame(width: 12, height: 12)
                }
            }
            .scaleEffect(breathe * (progress > 0.92 ? max(0.01, (1 - progress) * 12) : 1), anchor: .leading)
        }
        .accessibilityLabel("간주")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
