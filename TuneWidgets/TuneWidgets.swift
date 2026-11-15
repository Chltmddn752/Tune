import AppIntents
import SwiftUI
import WidgetKit

@main
struct TuneWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        PlayPauseControl()
        ShuffleLibraryControl()
        FavoritesControl()
    }
}

// MARK: - 데이터

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: SharedPlaybackState
    let artwork: UIImage?
    var upNextArtwork: [String: UIImage] = [:]
    var recentArtwork: [String: UIImage] = [:]
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, state: SharedPlaybackState(
            title: "곡 제목", artist: "아티스트", album: "앨범", artworkFile: nil,
            isPlaying: true, elapsed: 40, duration: 200, updatedAt: .now, isFavorite: true
        ), artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : makeEntries().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // 앱이 곡·재생 상태가 바뀔 때마다 위젯을 다시 그리게 한다.
        // 그 사이에도 지금 곡이 끝나는 시각에 맞춰 다음 곡으로 넘어가도록 몇 칸 미리 만들어 둔다.
        completion(Timeline(entries: makeEntries(), policy: .never))
    }

    private func thumbnail(_ url: URL?, size: CGFloat) -> UIImage? {
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        // 위젯은 메모리가 적어서 작게 줄여서 쓴다.
        return image.preparingThumbnail(of: CGSize(width: size, height: size)) ?? image
    }

    private func makeEntries() -> [NowPlayingEntry] {
        let state = SharedPlaybackState.load() ?? .empty
        var upNextArt: [String: UIImage] = [:]
        for item in state.upNext ?? [] {
            if let image = thumbnail(item.artworkURL, size: 400) { upNextArt[item.id] = image }
        }
        var recentArt: [String: UIImage] = [:]
        for album in state.recent ?? [] {
            if let image = thumbnail(album.artworkURL, size: 180) { recentArt[album.id] = image }
        }
        let now = NowPlayingEntry(date: .now, state: state, artwork: thumbnail(state.artworkURL, size: 400),
                                  upNextArtwork: upNextArt, recentArtwork: recentArt)
        var entries = [now]

        // 재생 중이면 곡이 끝나는 시각마다 다음 곡을 보여 준다(앱이 위젯을 못 깨우는 경우 대비).
        guard state.isPlaying, state.duration > 0, let upNext = state.upNext, !upNext.isEmpty else { return entries }
        var switchAt = state.updatedAt.addingTimeInterval(max(state.duration - state.elapsed, 0))
        var remaining = upNext
        while let next = remaining.first, switchAt > .now {
            remaining.removeFirst()
            var predicted = state
            predicted.title = next.title
            predicted.artist = next.artist
            predicted.album = ""
            predicted.artworkFile = next.artworkFile
            predicted.elapsed = 0
            predicted.duration = next.duration
            predicted.updatedAt = switchAt
            predicted.isFavorite = false
            predicted.upNext = remaining
            entries.append(NowPlayingEntry(date: switchAt, state: predicted, artwork: upNextArt[next.id],
                                           upNextArtwork: upNextArt, recentArtwork: recentArt))
            switchAt = switchAt.addingTimeInterval(max(next.duration, 1))
        }
        return entries
    }
}

// MARK: - 위젯

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlayingWidget", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("지금 재생 중")
        .description("곡이 바뀌면 같이 바뀌고, 재생·이전·다음·좋아요를 바로 누를 수 있어요.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

/// 위젯 색: 앱 재생 화면과 같은 Material 3 공식(SpatialFlow deriveArtworkSurfaceColor).
/// 앨범 대표색의 색상만 살리고 밝기·채도를 고정해서, 어떤 커버든 흰 글자가 잘 보이는 판을 만든다.
private struct WidgetM3Colors {
    let background: Color
    let container: Color
    let tonal: Color
    let accent: Color
    let onAccent = Color(red: 0.11, green: 0.106, blue: 0.12)
    let content = Color.white
    let secondary = Color.white.opacity(0.65)
    let track: Color

    init(seed: Color) {
        let (h, s, l) = Self.hsl(UIColor(seed))
        let mono = s < 0.06
        func surface(_ lightness: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Color {
            Self.color(h: h, s: mono ? 0 : min(max(s, low), high), l: lightness)
        }
        background = surface(0.155, 0.32, 0.54)
        container = surface(0.21, 0.30, 0.58)
        tonal = surface(0.27, 0.28, 0.58)
        track = surface(0.33, 0.24, 0.55)
        if s < 0.08 {
            accent = Color(white: 0.91)
        } else {
            accent = Self.color(h: h, s: max(s, 0.45), l: min(max(l, 0.55), 0.78))
        }
    }

    static func hex(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static let fallbackSeed = Color(red: 0.86, green: 0.16, blue: 0.38)

    private static func hsl(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1)
        let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
        let l = (maxV + minV) / 2
        guard delta > 0.00001 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxV - minV) : delta / (maxV + minV)
        var h: CGFloat
        if maxV == r { h = (g - b) / delta + (g < b ? 6 : 0) } else if maxV == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
        h *= 60
        return (h, s, l)
    }

    private static func color(h: CGFloat, s: CGFloat, l: CGFloat) -> Color {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0.00001 else { return Color(white: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: CGFloat) -> CGFloat {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return Color(red: channel(hue + 1.0 / 3), green: channel(hue), blue: channel(hue - 1.0 / 3))
    }
}

/// Material 3 글꼴 (앱과 같은 둥근 글꼴)
private extension Font {
    static func m3(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var state: SharedPlaybackState { entry.state }
    private var isFavorite: Bool { state.isFavorite ?? false }
    private var colors: WidgetM3Colors {
        WidgetM3Colors(seed: WidgetM3Colors.hex(state.palette?.first) ?? WidgetM3Colors.fallbackSeed)
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            case .systemLarge: large
            case .systemExtraLarge: extraLarge
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: small
            }
        }
        .widgetURL(URL(string: "tune://nowplaying"))
    }

    // MARK: 공용 조각

    /// 앨범색 하나로 칠한 단색 판 (M3 tonal surface)
    private var background: some View {
        colors.background
    }

    private func cover(_ image: UIImage?, radius: CGFloat) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                ZStack {
                    colors.tonal
                    Image(systemName: "music.note")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(colors.accent)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var titleText: String { state.hasTrack ? state.title : "재생 중인 음악 없음" }
    private var artistText: String { state.hasTrack ? state.artist : "Tune을 열어 음악을 틀어 보세요" }

    /// 좋아요: 동그란 토널 버튼. 켜지면 강조색으로 채워진다.
    private func favoriteButton(size: CGFloat) -> some View {
        Button(intent: ToggleFavoriteIntent()) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isFavorite ? colors.onAccent : colors.content)
                .frame(width: size, height: size)
                .background(isFavorite ? colors.accent : colors.tonal, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "좋아요 취소" : "좋아요")
    }

    /// 이전/다음: 둥근 사각형 토널 버튼
    private func skipButton(_ symbol: String, intent: some AppIntent, height: CGFloat, label: String) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: height * 0.38, weight: .semibold))
                .foregroundStyle(colors.content)
                .frame(width: height, height: height)
                .background(colors.tonal, in: RoundedRectangle(cornerRadius: height * 0.36, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: height * 0.36, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 재생/일시정지: 남는 폭을 다 쓰는 강조색 알약 (M3 Expressive 버튼 묶음의 가운데)
    private func playButton(height: CGFloat) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: height * 0.42, weight: .bold))
                .foregroundStyle(colors.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(colors.accent, in: RoundedRectangle(cornerRadius: height * 0.36, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: height * 0.36, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPlaying ? "일시정지" : "재생")
    }

    /// 이전 · 재생 · 다음을 붙여 놓은 버튼 묶음
    private func controls(height: CGFloat) -> some View {
        HStack(spacing: 6) {
            skipButton("backward.fill", intent: PreviousTrackIntent(), height: height, label: "이전 곡")
            playButton(height: height)
            skipButton("forward.fill", intent: NextTrackIntent(), height: height, label: "다음 곡")
        }
    }

    /// 굵고 둥근 M3 진행 막대. 재생 중이면 위젯이 스스로 움직인다.
    @ViewBuilder
    private func progressBar(showTimes: Bool, accessory: Bool = false) -> some View {
        let start = state.updatedAt.addingTimeInterval(-state.elapsed)
        let end = start.addingTimeInterval(max(state.duration, 1))
        VStack(spacing: 4) {
            Group {
                if state.isPlaying, state.duration > 0, end > .now {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: state.duration > 0 ? min(state.elapsed / state.duration, 1) : 0)
                }
            }
            .progressViewStyle(.linear)
            .tint(accessory ? Color.primary : colors.accent)
            .scaleEffect(y: accessory ? 1 : 1.6)
            .background {
                if !accessory { Capsule().fill(colors.track).frame(height: 6) }
            }
            .clipShape(Capsule())

            if showTimes, state.duration > 0 {
                HStack {
                    if state.isPlaying, end > .now {
                        Text(start, style: .timer)
                    } else {
                        Text(Self.clock(state.elapsed))
                    }
                    Spacer()
                    Text(Self.clock(state.duration))
                }
                .font(.m3(11, .semibold).monospacedDigit())
                .foregroundStyle(colors.secondary)
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: 작은 위젯

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                cover(entry.artwork, radius: 16)
                    .frame(width: 60, height: 60)
                Spacer(minLength: 0)
                if state.hasTrack { favoriteButton(size: 32) }
            }
            Spacer(minLength: 6)
            Text(titleText)
                .font(.m3(15, .bold))
                .lineLimit(1)
            Text(artistText)
                .font(.m3(12, .medium))
                .foregroundStyle(colors.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if state.hasTrack {
                controls(height: 36)
            }
        }
        .foregroundStyle(colors.content)
        .padding(14)
        .containerBackground(for: .widget) { background }
    }

    // MARK: 중간 위젯

    private var medium: some View {
        HStack(spacing: 14) {
            cover(entry.artwork, radius: 24)
                .frame(width: 130, height: 130)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText)
                            .font(.m3(17, .bold))
                            .lineLimit(2)
                        Text(artistText)
                            .font(.m3(13, .medium))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if state.hasTrack { favoriteButton(size: 30) }
                }
                Spacer(minLength: 6)
                if state.hasTrack {
                    progressBar(showTimes: false)
                    controls(height: 38)
                        .padding(.top, 10)
                }
            }
        }
        .foregroundStyle(colors.content)
        .padding(14)
        .containerBackground(for: .widget) { background }
    }

    // MARK: 큰 위젯

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 14) {
                cover(entry.artwork, radius: 28)
                    .frame(width: 132, height: 132)
                VStack(alignment: .leading, spacing: 2) {
                    if !state.album.isEmpty {
                        Text(state.album)
                            .font(.m3(12, .semibold))
                            .foregroundStyle(colors.accent)
                            .lineLimit(1)
                    }
                    Text(titleText)
                        .font(.m3(20, .bold))
                        .lineLimit(2)
                    Text(artistText)
                        .font(.m3(14, .medium))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if state.hasTrack { favoriteButton(size: 40) }
            }

            if state.hasTrack {
                progressBar(showTimes: true)
                controls(height: 48)
            }

            upNextList
        }
        .foregroundStyle(colors.content)
        .padding(16)
        .containerBackground(for: .widget) { background }
    }

    // MARK: 아주 큰 위젯 (아이패드)
    // 왼쪽 큰 커버 · 가운데 곡 정보와 조작 · 오른쪽 다음 곡과 최근 앨범

    private var extraLarge: some View {
        HStack(alignment: .center, spacing: 22) {
            cover(entry.artwork, radius: 32)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 230)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !state.album.isEmpty {
                            Text(state.album)
                                .font(.m3(13, .semibold))
                                .foregroundStyle(colors.accent)
                                .lineLimit(1)
                        }
                        Text(titleText)
                            .font(.m3(26, .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                        Text(artistText)
                            .font(.m3(16, .medium))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if state.hasTrack { favoriteButton(size: 40) }
                }
                Spacer(minLength: 12)
                if state.hasTrack {
                    progressBar(showTimes: true)
                    controls(height: 50)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                sidePanelUpNext
                sidePanelRecent
            }
            .frame(width: 200)
        }
        .foregroundStyle(colors.content)
        .padding(20)
        .containerBackground(for: .widget) { background }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.m3(12, .semibold))
            .foregroundStyle(colors.accent)
    }

    private func trackRow(_ item: SharedPlaybackState.UpNextItem, art: CGFloat, radius: CGFloat) -> some View {
        HStack(spacing: 10) {
            cover(entry.upNextArtwork[item.id], radius: radius)
                .frame(width: art, height: art)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.m3(13, .semibold)).lineLimit(1)
                Text(item.artist).font(.m3(11)).foregroundStyle(colors.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var sidePanelUpNext: some View {
        let next = Array((state.upNext ?? []).prefix(3))
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("다음 곡")
            if next.isEmpty {
                Text("대기열이 비어 있어요")
                    .font(.m3(12))
                    .foregroundStyle(colors.secondary)
            }
            ForEach(next) { item in
                trackRow(item, art: 38, radius: 10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.container, in: UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 6,
                                                                bottomTrailingRadius: 6, topTrailingRadius: 24,
                                                                style: .continuous))
    }

    @ViewBuilder
    private var sidePanelRecent: some View {
        let recent = Array((state.recent ?? []).prefix(4))
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("최근 재생")
            HStack(spacing: 6) {
                ForEach(recent) { album in
                    Button(intent: PlayAlbumIntent(albumID: album.id)) {
                        cover(entry.recentArtwork[album.id], radius: 10)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(album.title) 재생")
                }
                ForEach(recent.count..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colors.tonal.opacity(0.5))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.container, in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 24,
                                                                bottomTrailingRadius: 24, topTrailingRadius: 6,
                                                                style: .continuous))
    }

    @ViewBuilder
    private var upNextList: some View {
        let next = Array((state.upNext ?? []).prefix(2))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("다음 곡")
                ForEach(next) { item in
                    trackRow(item, art: 34, radius: 9)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.container, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            recentAlbums
        }
    }

    @ViewBuilder
    private var recentAlbums: some View {
        let recent = Array((state.recent ?? []).prefix(4))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("최근 재생")
                HStack(spacing: 8) {
                    ForEach(recent) { album in
                        Button(intent: PlayAlbumIntent(albumID: album.id)) {
                            cover(entry.recentArtwork[album.id], radius: 12)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(album.title) 재생")
                    }
                    ForEach(recent.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                }
            }
            .padding(12)
            .background(colors.container, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: 잠금화면

    private var circular: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                if state.duration > 0 {
                    Gauge(value: min(state.elapsed / state.duration, 1)) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .opacity(0.6)
                }
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.hasTrack ? state.title : "Tune")
                    .font(.headline)
                    .lineLimit(1)
                Text(state.hasTrack ? state.artist : "재생 중인 음악 없음")
                    .font(.caption)
                    .lineLimit(1)
                    .opacity(0.8)
                if state.hasTrack { progressBar(showTimes: false, accessory: true) }
            }
            Spacer(minLength: 0)
            if state.hasTrack {
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var inline: some View {
        Label(state.hasTrack ? "\(state.title) · \(state.artist)" : "Tune", systemImage: state.isPlaying ? "waveform" : "music.note")
            .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - 제어 센터

/// 재생 중인지 위젯 공유 파일에서 읽는다.
struct PlaybackValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SharedPlaybackState.load()?.isPlaying ?? false
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.chltmddn752.tune.playpause", provider: PlaybackValueProvider()) { isPlaying in
            ControlWidgetToggle("Tune", isOn: isPlaying, action: SetPlayingIntent()) { on in
                Label(on ? "재생 중" : "일시정지됨", systemImage: on ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Tune 재생/일시정지")
        .description("제어 센터에서 바로 재생하거나 멈춰요.")
    }
}

struct ShuffleLibraryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.chltmddn752.tune.shuffle") {
            ControlWidgetButton(action: ShuffleLibraryIntent()) {
                Label("보관함 셔플", systemImage: "shuffle")
            }
        }
        .displayName("Tune 보관함 셔플")
        .description("보관함의 모든 곡을 섞어서 재생합니다.")
    }
}

struct FavoritesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.chltmddn752.tune.favorites") {
            ControlWidgetButton(action: PlayFavoritesIntent()) {
                Label("좋아요 곡 재생", systemImage: "star.fill")
            }
        }
        .displayName("Tune 좋아요 곡")
        .description("좋아요 표시한 곡을 섞어서 재생합니다.")
    }
}
