import SwiftData
import SwiftUI

enum PlayerPane: Hashable {
    case artwork, lyrics, queue
}

@MainActor
@Observable
final class LyricsLoader {
    var lyrics: Lyrics?
    var isLoading = false
    var offset: Double = 0
    @ObservationIgnored private var loadedFor: UUID?

    func load(_ item: QueueItem?, context: ModelContext, force: Bool = false) async {
        guard let item else { lyrics = nil; loadedFor = nil; return }
        guard force || loadedFor != item.trackID else { return }
        loadedFor = item.trackID
        isLoading = true
        lyrics = nil
        let (result, cache) = await LyricsService.load(for: item, context: context)
        guard loadedFor == item.trackID else { return }
        lyrics = result
        offset = cache?.offset ?? 0
        isLoading = false
    }

    func adjustOffset(by delta: Double, item: QueueItem?, context: ModelContext) async {
        guard let item else { return }
        offset = delta == 0 ? 0 : offset + delta
        LyricsService.setOffset(offset, for: item, context: context)
        await load(item, context: context, force: true)
    }
}

/// 전체 화면 재생 화면 (아이폰, 아이패드 크게 보기)
struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var pane: PlayerPane = .artwork
    @State private var lyricsLoader = LyricsLoader()
    @State private var lyricsOnly = false
    @Namespace private var artworkNamespace

    var body: some View {
        ZStack {
            MeshBackground(colors: player.currentPalette, fallback: player.currentColor)

            if sizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(lyricsLoader)
        .task(id: player.current?.trackID) {
            await lyricsLoader.load(player.current, context: modelContext)
        }
        .onChange(of: player.hasItem) { _, has in
            if !has { dismiss() }
        }
    }

    // MARK: 아이폰

    private var compactLayout: some View {
        VStack(spacing: 0) {
            grabber

            if pane == .artwork {
                Spacer(minLength: Spacing.m)
                bigArtwork
                    .padding(.horizontal, 30)
                Spacer(minLength: Spacing.m)
                PlayerControls(pane: $pane, showTitle: true)
                    .padding(.horizontal, 30)
                    .padding(.bottom, Spacing.s)
            } else {
                compactHeader
                    .padding(.horizontal, 24)
                    .padding(.top, Spacing.m)
                Group {
                    if pane == .lyrics {
                        LyricsView(lyrics: lyricsLoader.lyrics, isLoading: lyricsLoader.isLoading) {
                            withAnimation(.playerExpand) { lyricsOnly.toggle() }
                        }
                        .padding(.horizontal, 24)
                    } else {
                        QueueView()
                    }
                }
                .frame(maxHeight: .infinity)
                if !lyricsOnly || pane != .lyrics {
                    PlayerControls(pane: $pane, showTitle: false)
                        .padding(.horizontal, 30)
                        .padding(.bottom, Spacing.s)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.playerExpand, value: pane)
    }

    private var grabber: some View {
        Button { dismiss() } label: {
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.s)
        .accessibilityLabel("재생 화면 닫기")
    }

    private var bigArtwork: some View {
        ArtworkView(file: player.current?.artworkFile, cornerRadius: Radius.playerArtwork)
            .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
            .scaleEffect(player.isPlaying ? 1 : 0.8)
            .shadow(color: .black.opacity(player.isPlaying ? 0.35 : 0.15), radius: player.isPlaying ? 24 : 10, y: player.isPlaying ? 14 : 4)
            .animation(.artworkPause, value: player.isPlaying)
            .onTapGesture { withAnimation(.playerExpand) { pane = .lyrics } }
    }

    private var compactHeader: some View {
        HStack(spacing: Spacing.m) {
            ArtworkView(file: player.current?.artworkFile, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
                .frame(width: 56, height: 56)
                .onTapGesture { withAnimation(.playerExpand) { pane = .artwork } }
            TitleBlock()
        }
    }

    // MARK: 아이패드 크게 보기

    private var regularLayout: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                Spacer()
                Picker("보기", selection: $pane) {
                    Text("가사").tag(PlayerPane.lyrics)
                    Text("대기열").tag(PlayerPane.queue)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 32)
            .padding(.top, Spacing.l)

            HStack(alignment: .center, spacing: 56) {
                VStack(spacing: Spacing.xxl) {
                    ArtworkView(file: player.current?.artworkFile, cornerRadius: Radius.playerArtwork)
                        .scaleEffect(player.isPlaying ? 1 : 0.85)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                        .animation(.artworkPause, value: player.isPlaying)
                        .frame(maxWidth: 460)
                    PlayerControls(pane: .constant(.lyrics), showTitle: true, showPaneButtons: false)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity)

                Group {
                    if pane == .queue {
                        QueueView()
                    } else {
                        LyricsView(lyrics: lyricsLoader.lyrics, isLoading: lyricsLoader.isLoading, onTapEmpty: nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, Spacing.xxl)
        }
        .onAppear { if pane == .artwork { pane = .lyrics } }
    }
}

/// 제목 · 아티스트 · 좋아요 · … 메뉴
struct TitleBlock: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(LyricsLoader.self) private var lyricsLoader: LyricsLoader?
    @Environment(\.modelContext) private var modelContext

    @State private var artistChoices: [Artist] = []

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: player.current?.title ?? "", font: .tunePlayerTitle)
                Button {
                    goToArtist()
                } label: {
                    Text(player.current?.artist ?? "")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                player.toggleFavorite()
            } label: {
                Image(systemName: player.isCurrentFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: player.isCurrentFavorite)
            .accessibilityLabel(player.isCurrentFavorite ? "좋아요 취소" : "좋아요")

            Menu {
                Button { goToAlbum() } label: { Label("앨범으로 이동", systemImage: "square.stack") }
                Button { goToArtist() } label: { Label("아티스트로 이동", systemImage: "music.mic") }
                if let track = currentTrack {
                    AddToPlaylistMenu(tracks: [track])
                }
                Menu {
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes)분") { player.setSleepTimer(minutes: minutes) }
                    }
                    Button("이 곡이 끝나면") { player.setSleepAtTrackEnd() }
                    if player.isSleepTimerActive {
                        Button("타이머 끄기", role: .destructive) { player.cancelSleepTimer() }
                    }
                } label: {
                    Label(sleepLabel, systemImage: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
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
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("더 보기")
        }
        .confirmationDialog("어느 아티스트로 갈까요?",
                            isPresented: Binding(get: { !artistChoices.isEmpty }, set: { if !$0 { artistChoices = [] } }),
                            titleVisibility: .visible) {
            ForEach(artistChoices) { artist in
                Button(artist.name) {
                    artistChoices = []
                    navigate(.artist(artist.id))
                }
            }
            Button("취소", role: .cancel) { artistChoices = [] }
        }
    }

    private var sleepLabel: String {
        if let end = player.sleepTimerEnd {
            let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
            return "수면 타이머 (\(minutes)분 남음)"
        }
        return player.sleepAtTrackEnd ? "수면 타이머 (이 곡 끝나면)" : "수면 타이머"
    }

    private var currentTrack: Track? {
        guard let id = player.current?.trackID else { return nil }
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func goToAlbum() {
        guard let album = currentTrack?.album else { return }
        navigate(.album(album.id))
    }

    /// 가수가 여러 명이면 누구로 갈지 고르게 한다.
    private func goToArtist() {
        guard let track = currentTrack else { return }
        let found = ArtistLookup.artists(for: track, context: modelContext)
        if found.count > 1 {
            artistChoices = found
        } else if let artist = found.first ?? track.artist {
            navigate(.artist(artist.id))
        }
    }

    private func navigate(_ route: Route) {
        if router.showPlayer {
            router.showPlayer = false
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                router.open(route)
            }
        } else {
            router.open(route)
        }
    }
}

/// 진행 막대 · 재생 버튼 · 볼륨 · 아래 버튼 줄
struct PlayerControls: View {
    @Binding var pane: PlayerPane
    var showTitle: Bool
    var showPaneButtons = true

    @Environment(PlayerEngine.self) private var player
    @State private var volume = SystemVolume()
    @State private var seekTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: Spacing.xl) {
            if showTitle { TitleBlock() }
            progress
            transport
            volumeRow
            if showPaneButtons { bottomRow }
        }
        .background(HiddenVolumeView(volume: volume).frame(width: 1, height: 1))
    }

    private var progress: some View {
        PlaybackProgress()
    }

    private var transport: some View {
        HStack {
            seekButton(systemImage: "backward.fill", label: "이전 곡", direction: -1) { player.previous() }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
            Spacer()
            seekButton(systemImage: "forward.fill", label: "다음 곡", direction: 1) { player.next() }
        }
        .padding(.horizontal, Spacing.xxl)
    }

    /// 누르면 이전/다음 곡, 길게 누르면 빨리 감기
    private func seekButton(systemImage: String, label: String, direction: Double, action: @escaping () -> Void) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 30))
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4, perform: {}) { pressing in
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

    private var volumeRow: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "speaker.fill").font(.caption)
            ElasticSlider(value: Binding(get: { volume.level }, set: { volume.set($0) }), range: 0...1)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("볼륨")
    }

    private var bottomRow: some View {
        HStack {
            paneButton(.lyrics, systemImage: "quote.bubble", label: "가사")
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            Spacer()
            paneButton(.queue, systemImage: "list.bullet", label: "대기열")
        }
        .padding(.horizontal, Spacing.xxl)
    }

    private func paneButton(_ target: PlayerPane, systemImage: String, label: String) -> some View {
        let selected = pane == target
        return Button {
            withAnimation(.playerExpand) { pane = selected ? .artwork : target }
        } label: {
            Image(systemName: selected && systemImage == "quote.bubble" ? "quote.bubble.fill" : systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(selected ? Color.black.opacity(0.7) : Color.white.opacity(0.75))
                .background(selected ? Color.white.opacity(0.9) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.smooth(duration: 0.2, extraBounce: 0.3), value: configuration.isPressed)
    }
}

/// 진행 막대. 재생 중에는 화면 주사율로 매끄럽게 움직이고, 이 뷰만 다시 그려진다.
struct PlaybackProgress: View {
    @Environment(PlayerEngine.self) private var player
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !player.isPlaying || isScrubbing)) { _ in
            let now = isScrubbing ? scrubValue : (player.isPlaying ? player.currentTime() : player.elapsed)
            VStack(spacing: 4) {
                ElasticSlider(
                    value: Binding(get: { now }, set: { scrubValue = $0 }),
                    range: 0...max(player.duration, 1)
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
                        .font(.caption2.weight(.semibold))
                    }
                    Spacer()
                    Text("-" + Formatters.time(max(0, player.duration - now)))
                }
                .font(.tuneTime)
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
