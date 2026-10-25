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

/// 위젯 색: 앨범 색을 어둡게 눌러서 흰 글자가 잘 보이게
private enum WidgetColors {
    static func color(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func deep(_ color: Color, brightness: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s * 1.1, 1), brightness: min(b, brightness))
    }

    static let fallback = Color(red: 0.86, green: 0.16, blue: 0.38)
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var state: SharedPlaybackState { entry.state }
    private var isFavorite: Bool { state.isFavorite ?? false }

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

    private var baseColor: Color {
        WidgetColors.color(state.palette?.first) ?? WidgetColors.fallback
    }

    /// 앨범 색 그라데이션 + 흐린 커버 + 위에서 빛이 드는 느낌
    private var background: some View {
        let top = WidgetColors.deep(baseColor, brightness: 0.62)
        let second = WidgetColors.color(state.palette?.dropFirst().first).map { WidgetColors.deep($0, brightness: 0.4) }
            ?? WidgetColors.deep(baseColor, brightness: 0.3)
        return ZStack {
            LinearGradient(colors: [top, second, .black.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = entry.artwork {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .opacity(0.45)
                    .blendMode(.plusLighter)
            }
            RadialGradient(colors: [.white.opacity(0.14), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
        }
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
                    LinearGradient(colors: [baseColor, WidgetColors.deep(baseColor, brightness: 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private var titleText: String { state.hasTrack ? state.title : "재생 중인 음악 없음" }
    private var artistText: String { state.hasTrack ? state.artist : "Tune을 열어 음악을 틀어 보세요" }

    private func favoriteButton(size: CGFloat) -> some View {
        Button(intent: ToggleFavoriteIntent()) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isFavorite ? Color(red: 1, green: 0.42, blue: 0.62) : .white.opacity(0.85))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "좋아요 취소" : "좋아요")
    }

    private func skipButton(_ symbol: String, intent: some AppIntent, size: CGFloat, label: String) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 흰 동그라미 안 재생/일시정지
    private func playButton(size: CGFloat) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(WidgetColors.deep(baseColor, brightness: 0.35))
                .offset(x: state.isPlaying ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPlaying ? "일시정지" : "재생")
    }

    private func controls(play: CGFloat, skip: CGFloat, star: CGFloat) -> some View {
        HStack(spacing: 0) {
            favoriteButton(size: star)
            Spacer(minLength: 0)
            skipButton("backward.fill", intent: PreviousTrackIntent(), size: skip, label: "이전 곡")
            Spacer(minLength: 0)
            playButton(size: play)
            Spacer(minLength: 0)
            skipButton("forward.fill", intent: NextTrackIntent(), size: skip, label: "다음 곡")
        }
    }

    /// 재생 중이면 위젯이 스스로 진행 막대를 움직인다.
    @ViewBuilder
    private func progressBar(showTimes: Bool) -> some View {
        let start = state.updatedAt.addingTimeInterval(-state.elapsed)
        let end = start.addingTimeInterval(max(state.duration, 1))
        VStack(spacing: 3) {
            Group {
                if state.isPlaying, state.duration > 0, end > .now {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: state.duration > 0 ? min(state.elapsed / state.duration, 1) : 0)
                }
            }
            .progressViewStyle(.linear)
            .tint(.white)
            .background(Capsule().fill(.white.opacity(0.22)))
            .scaleEffect(y: 0.8)

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
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
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
                cover(entry.artwork, radius: 12)
                    .frame(width: 62, height: 62)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                Spacer(minLength: 0)
                if state.hasTrack { favoriteButton(size: 30) }
            }
            Spacer(minLength: 6)
            Text(titleText)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            Text(artistText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 6)
            if state.hasTrack {
                HStack(spacing: 0) {
                    skipButton("backward.fill", intent: PreviousTrackIntent(), size: 32, label: "이전 곡")
                    Spacer(minLength: 0)
                    playButton(size: 38)
                    Spacer(minLength: 0)
                    skipButton("forward.fill", intent: NextTrackIntent(), size: 32, label: "다음 곡")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .containerBackground(for: .widget) { background }
    }

    // MARK: 중간 위젯

    private var medium: some View {
        HStack(spacing: 14) {
            cover(entry.artwork, radius: 16)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(titleText)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(2)
                Text(artistText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.top, 1)
                Spacer(minLength: 6)
                if state.hasTrack {
                    progressBar(showTimes: false)
                    controls(play: 40, skip: 34, star: 30)
                        .padding(.top, 8)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .containerBackground(for: .widget) { background }
    }

    // MARK: 큰 위젯

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 14) {
                cover(entry.artwork, radius: 18)
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 7)
                VStack(alignment: .leading, spacing: 2) {
                    if !state.album.isEmpty {
                        Text(state.album.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Text(titleText)
                        .font(.system(size: 19, weight: .heavy))
                        .lineLimit(2)
                    Text(artistText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            if state.hasTrack {
                progressBar(showTimes: true)
                controls(play: 50, skip: 42, star: 36)
            }

            upNextList
        }
        .foregroundStyle(.white)
        .padding(16)
        .containerBackground(for: .widget) { background }
    }

    // MARK: 아주 큰 위젯 (아이패드)
    // 왼쪽 큰 커버 · 가운데 곡 정보와 조작 · 오른쪽 다음 곡과 최근 앨범

    private var extraLarge: some View {
        HStack(alignment: .center, spacing: 24) {
            cover(entry.artwork, radius: 22)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.45), radius: 20, y: 10)

            VStack(alignment: .leading, spacing: 0) {
                if !state.album.isEmpty {
                    Text(state.album.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Text(titleText)
                    .font(.system(size: 26, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
                Text(artistText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .padding(.top, 2)
                Spacer(minLength: 12)
                if state.hasTrack {
                    progressBar(showTimes: true)
                    controls(play: 60, skip: 48, star: 42)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                sidePanelUpNext
                Spacer(minLength: 0)
                sidePanelRecent
            }
            .frame(width: 210)
        }
        .foregroundStyle(.white)
        .padding(22)
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder
    private var sidePanelUpNext: some View {
        let next = Array((state.upNext ?? []).prefix(3))
        VStack(alignment: .leading, spacing: 8) {
            Text("다음 곡")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            if next.isEmpty {
                Text("대기열이 비어 있어요")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(next) { item in
                HStack(spacing: 10) {
                    cover(entry.upNextArtwork[item.id], radius: 7)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(item.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var sidePanelRecent: some View {
        let recent = Array((state.recent ?? []).prefix(4))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("최근 재생")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    ForEach(recent) { album in
                        Button(intent: PlayAlbumIntent(albumID: album.id)) {
                            cover(entry.recentArtwork[album.id], radius: 7)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(album.title) 재생")
                    }
                    ForEach(recent.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                }
            }
        }
    }

    @ViewBuilder
    private var upNextList: some View {
        let next = Array((state.upNext ?? []).prefix(2))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("다음 곡")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                ForEach(next) { item in
                    HStack(spacing: 10) {
                        cover(entry.upNextArtwork[item.id], radius: 6)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(item.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            recentAlbums
        }
    }

    @ViewBuilder
    private var recentAlbums: some View {
        let recent = Array((state.recent ?? []).prefix(4))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("최근 재생")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 8) {
                    ForEach(recent) { album in
                        Button(intent: PlayAlbumIntent(albumID: album.id)) {
                            cover(entry.recentArtwork[album.id], radius: 8)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(album.title) 재생")
                    }
                    ForEach(recent.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                }
            }
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
                if state.hasTrack { progressBar(showTimes: false).tint(.primary) }
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
