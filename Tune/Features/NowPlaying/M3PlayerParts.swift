import SwiftData
import SwiftUI

// 재생 화면 조각들. 아이폰 재생 시트, 아이패드 재생 패널, 크게 보기에서 같이 쓴다.

extension PlayerEngine {
    /// 지금 곡 앨범색으로 만든 재생 화면 색
    var m3Colors: M3PlayerColors { M3PlayerColors(seed: currentColor) }
}

// MARK: - 제목 · 아티스트

struct M3PlayerTitle: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarqueeText(text: player.current?.title ?? "재생 중인 곡 없음", font: .m3(26, .bold))
                .foregroundStyle(.white)
            ArtistLinksText(raw: player.current?.artist ?? "", font: .m3(15),
                            color: .white.opacity(0.6), lineLimit: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

// MARK: - 칩 줄 (좋아요 · 가사 · 대기열 · 수면 타이머 · AirPlay)

struct M3PlayerChipRow: View {
    var lyricsOn: Bool
    var queueOn: Bool
    var onLyrics: () -> Void
    var onQueue: () -> Void
    var onSleepTimer: () -> Void
    /// 가사 칩의 가운데 (가사 화면이 이 점에서 원으로 퍼진다)
    var onLyricsChipFrame: ((CGRect) -> Void)? = nil
    var coordinateSpace: NamedCoordinateSpace = .named("m3sheet")

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let colors = player.m3Colors
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                M3PillChip(player.isCurrentFavorite ? "좋아요 취소" : "좋아요",
                           systemImage: player.isCurrentFavorite ? "heart.fill" : "heart",
                           isSelected: player.isCurrentFavorite, colors: colors) {
                    player.toggleFavorite()
                }
                .sensoryFeedback(.impact(weight: .light), trigger: player.isCurrentFavorite)

                M3PillChip("가사", systemImage: lyricsOn ? "quote.bubble.fill" : "quote.bubble",
                           isSelected: lyricsOn, colors: colors, action: onLyrics)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: coordinateSpace)
                    } action: { frame in
                        onLyricsChipFrame?(frame)
                    }

                M3PillChip("대기열", systemImage: "list.bullet", isSelected: queueOn, colors: colors, action: onQueue)

                M3PillChip(sleepLabel, systemImage: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
                           isSelected: player.isSleepTimerActive, colors: colors, action: onSleepTimer)

                M3PillChip(label: "AirPlay", colors: colors, action: {}) {
                    AirPlayButton(tint: UIColor.white.withAlphaComponent(0.8))
                }
                .overlay {
                    // 칩 전체를 누르면 AirPlay 고르기 창이 열리게 투명한 선택기를 덮는다.
                    AirPlayButton(tint: .clear)
                        .opacity(0.02)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var sleepLabel: String {
        if let end = player.sleepTimerEnd {
            let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
            return "\(minutes)분 뒤 멈춤"
        }
        return player.sleepAtTrackEnd ? "곡 끝나면 멈춤" : "수면 타이머"
    }
}

// MARK: - 물결 진행 막대 + 시간

struct M3PlaybackProgress: View {
    @Environment(PlayerEngine.self) private var player
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        let colors = player.m3Colors
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying || isScrubbing)) { _ in
            let now = isScrubbing ? scrubValue : (player.isPlaying ? player.currentTime() : player.elapsed)
            VStack(spacing: 2) {
                M3WavySlider(
                    value: Binding(get: { now }, set: { scrubValue = $0 }),
                    range: 0...max(player.duration, 1),
                    isPlaying: player.isPlaying,
                    activeColor: colors.accent,
                    inactiveColor: colors.chip,
                    thumbColor: .white
                ) { editing in
                    if editing {
                        scrubValue = now
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
                HStack {
                    Text(Formatters.time(now))
                    Spacer()
                    if player.current?.isLossless == true {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                            Text("무손실")
                        }
                        .font(.m3(11, .semibold))
                    }
                    Spacer()
                    Text(Formatters.time(player.duration))
                }
                .font(.m3(11, .medium).monospacedDigit())
                .foregroundStyle(colors.contentSecondary)
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - 이전 · 재생 · 다음 (높이 76, 폭 비율 1 : 1.2 : 1, 누르면 모서리 28→12)

struct M3TransportGroup: View {
    var height: CGFloat = 76
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let colors = player.m3Colors
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let unit = max(0, proxy.size.width - spacing * 2) / 3.2
            HStack(spacing: spacing) {
                M3SeekButton(systemImage: "backward.fill", label: "이전 곡", direction: -1,
                             height: height, colors: colors) { player.previous() }
                    .frame(width: unit)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: height * 0.44, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(M3ExpressiveButtonStyle(container: colors.accent, content: colors.onAccent))
                .frame(width: unit * 1.2)
                .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
                .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                M3SeekButton(systemImage: "forward.fill", label: "다음 곡", direction: 1,
                             height: height, colors: colors) { player.next() }
                    .frame(width: unit)
            }
        }
        .frame(height: height)
        .padding(.horizontal, 16)
    }
}

/// 누르면 이전/다음 곡, 길게 누르면 5초씩 감기. 누르는 동안 모서리가 줄어든다.
struct M3SeekButton: View {
    let systemImage: String
    let label: String
    let direction: Double
    var height: CGFloat = 76
    let colors: M3PlayerColors
    let action: () -> Void

    @Environment(PlayerEngine.self) private var player
    @State private var pressed = false
    @State private var seekTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: height * 0.36, weight: .semibold))
            .foregroundStyle(colors.content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.chip, in: RoundedRectangle(cornerRadius: pressed ? 12 : 28, style: .continuous))
            .scaleEffect(x: pressed ? 1.06 : 1, y: pressed ? 0.98 : 1)
            .animation(M3Motion.press, value: pressed)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4, perform: {}) { pressing in
                pressed = pressing
                seekTask?.cancel()
                guard pressing else { return }
                seekTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    while !Task.isCancelled {
                        player.seek(to: player.currentTime() + 5 * direction)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 볼륨

struct M3VolumeRow: View {
    @Environment(PlayerEngine.self) private var player
    @State private var volume = SystemVolume()

    var body: some View {
        let colors = player.m3Colors
        HStack(spacing: Spacing.m) {
            Image(systemName: "speaker.fill").font(.system(size: 12))
            M3WavySlider(
                value: Binding(get: { volume.level }, set: { volume.set($0) }),
                range: 0...1,
                wavy: false,
                activeColor: .white.opacity(0.85),
                inactiveColor: colors.chip,
                thumbColor: .white,
                thumbRadius: 5
            )
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12))
        }
        .foregroundStyle(colors.contentSecondary)
        .padding(.horizontal, 12)
        .background(HiddenVolumeView(volume: volume).frame(width: 1, height: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("볼륨")
    }
}

// MARK: - … 메뉴 (앨범·아티스트로 이동, 플레이리스트에 추가, 가사 타이밍)

struct M3PlayerMoreMenu: View {
    var onNavigate: (Route) -> Void

    @Environment(PlayerEngine.self) private var player
    @Environment(LyricsLoader.self) private var lyricsLoader: LyricsLoader?
    @Environment(\.modelContext) private var modelContext
    @State private var artistChoices: [Artist] = []

    var body: some View {
        Menu {
            Button { goToAlbum() } label: { Label("앨범으로 이동", systemImage: "square.stack") }
            Button { goToArtist() } label: { Label("아티스트로 이동", systemImage: "music.mic") }
            if let track = currentTrack {
                AddToPlaylistMenu(tracks: [track])
                Button {
                    onNavigate(.mix("track:\(track.id.uuidString)"))
                } label: {
                    Label("이 곡으로 믹스 만들기", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            if let track = currentTrack {
                RefetchLyricsButton(tracks: [track])
            }
            if let lyricsLoader, lyricsLoader.lyrics?.isSynced == true {
                Menu {
                    Button("가사를 0.5초 빠르게") { Task { await lyricsLoader.adjustOffset(by: -0.5, item: player.current, context: modelContext) } }
                    Button("가사를 0.5초 느리게") { Task { await lyricsLoader.adjustOffset(by: 0.5, item: player.current, context: modelContext) } }
                    Button("타이밍 초기화") { Task { await lyricsLoader.adjustOffset(by: 0, item: player.current, context: modelContext) } }
                } label: {
                    Label("가사 타이밍 (\(String(format: "%+.1f", lyricsLoader.offset))초)", systemImage: "timer")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("더 보기")
        .confirmationDialog("어느 아티스트로 갈까요?",
                            isPresented: Binding(get: { !artistChoices.isEmpty }, set: { if !$0 { artistChoices = [] } }),
                            titleVisibility: .visible) {
            ForEach(artistChoices) { artist in
                Button(artist.name) {
                    artistChoices = []
                    onNavigate(.artist(artist.id))
                }
            }
            Button("취소", role: .cancel) { artistChoices = [] }
        }
    }

    private var currentTrack: Track? {
        guard let id = player.current?.trackID else { return nil }
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func goToAlbum() {
        guard let album = currentTrack?.album else { return }
        onNavigate(.album(album.id))
    }

    private func goToArtist() {
        guard let track = currentTrack else { return }
        let found = ArtistLookup.artists(for: track, context: modelContext)
        if found.count > 1 {
            artistChoices = found
        } else if let artist = found.first ?? track.artist {
            onNavigate(.artist(artist.id))
        }
    }
}

// MARK: - 수면 타이머 시트

struct M3SleepTimerSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var customMinutes = 20
    @State private var showCustom = false

    private let presets = [15, 30, 45, 60, 90]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("수면 타이머")
                    .font(.m3(24, .semibold))
                    .foregroundStyle(Color.m3OnSurface)
                    .padding(.bottom, 8)

                if player.isSleepTimerActive {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(Color.m3Primary)
                            .font(.system(size: 20))
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(activeText)
                                .font(.m3BodyLarge.weight(.semibold))
                                .foregroundStyle(Color.m3OnPrimaryContainer)
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.m3PrimaryContainer.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                M3Group(outer: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: Spacing.l) {
                            Image(systemName: "timer")
                                .foregroundStyle(Color.m3OnPrimaryContainer)
                                .frame(width: 40, height: 40)
                                .background(Color.m3PrimaryContainer, in: Circle())
                            Text("시간 정하기")
                                .font(.m3TitleMedium.weight(.bold))
                                .foregroundStyle(Color.m3OnSurface)
                        }
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(presets, id: \.self) { minutes in
                                    M3FilterChip(title: minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분",
                                                 isSelected: false) {
                                        player.setSleepTimer(minutes: minutes)
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }

                    Toggle(isOn: Binding(
                        get: { player.sleepAtTrackEnd },
                        set: { on in
                            if on { player.setSleepAtTrackEnd() } else { player.cancelSleepTimer() }
                        }
                    )) {
                        M3Row("이 곡이 끝나면 멈추기", subtitle: "지금 곡이 끝나는 순간 재생을 멈춰요", systemImage: "music.note")
                    }
                    .toggleStyle(M3ToggleStyle())

                    if showCustom {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper(value: $customMinutes, in: 1...240, step: customMinutes < 30 ? 1 : 5) {
                                Text("\(customMinutes)분")
                                    .font(.m3TitleMedium.weight(.semibold))
                                    .foregroundStyle(Color.m3OnSurface)
                                    .contentTransition(.numericText())
                            }
                            Button {
                                player.setSleepTimer(minutes: customMinutes)
                                dismiss()
                            } label: {
                                Text("\(customMinutes)분 뒤 멈추기")
                                    .font(.m3LabelLarge.weight(.bold))
                                    .frame(height: 44)
                            }
                            .buttonStyle(M3ExpressiveButtonStyle(container: .m3Primary, content: .m3OnPrimary, radius: 22, pressedRadius: 10))
                            .frame(height: 44)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        player.cancelSleepTimer()
                        dismiss()
                    } label: {
                        Label("끄기", systemImage: "xmark")
                            .font(.m3(15, .bold))
                    }
                    .buttonStyle(M3ExpressiveButtonStyle(container: .m3SurfaceContainerHighest, content: .m3OnSurface, radius: 24, pressedRadius: 10))
                    .frame(height: 48)
                    .disabled(!player.isSleepTimerActive)

                    Button {
                        withAnimation(M3Motion.standard) { showCustom.toggle() }
                    } label: {
                        Label("직접 정하기", systemImage: "pencil")
                            .font(.m3(15, .bold))
                    }
                    .buttonStyle(M3ExpressiveButtonStyle(container: .m3SecondaryContainer, content: .m3OnSecondaryContainer, radius: 24, pressedRadius: 10))
                    .frame(height: 48)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .background(Color.m3SurfaceContainerLow)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .animation(M3Motion.standard, value: player.isSleepTimerActive)
    }

    private var activeText: String {
        if let end = player.sleepTimerEnd {
            let remaining = max(0, Int(end.timeIntervalSinceNow))
            return String(format: "%02d:%02d 뒤에 멈춰요", remaining / 60, remaining % 60)
        }
        return "이 곡이 끝나면 멈춰요"
    }
}
