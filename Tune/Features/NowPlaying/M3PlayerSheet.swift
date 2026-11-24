import SwiftData
import SwiftUI

/// 아이폰 재생 시트. 미니 플레이어(높이 80 알약)와 전체 재생 화면은 따로 있는 화면이 아니라
/// 하나의 판이 늘어나는 것이다. 모든 값은 펼침 정도 t(0 = 미니, 1 = 전체) 하나에서 계산한다.
/// (SpatialFlow PlayerBottomSheetCompose · FullPlayer 를 옮김)
struct M3PlayerSheet: View {
    /// 지금 보이는 하단바 높이(아래 안전 영역 포함). 미니 플레이어가 그 위 12pt에 뜬다.
    var bottomInset: CGFloat

    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var modelContext

    @State private var t: CGFloat = 0
    @State private var presence: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var dragAxis: Axis?
    @State private var squash: CGFloat = 1
    @State private var swipeX: CGFloat = 0
    @State private var swipePassed = false
    @State private var lyricsLoader = LyricsLoader()
    @State private var lyricsOpen = false
    @State private var lyricsReveal: CGFloat = 0
    @State private var lyricsChip: CGRect = .zero
    @State private var queueOpen = false
    @State private var showSleepTimer = false

    private let miniHeight: CGFloat = 80
    private let sidePadding: CGFloat = 12

    private var visible: Bool { player.hasItem && !router.hidesMiniPlayer }

    var body: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            let width = proxy.size.width
            let height = proxy.size.height + safe.top + safe.bottom
            let gap: CGFloat = router.navHidden ? 8 : 12
            let collapsedY = height - miniHeight - bottomInset - gap
            let hiddenY = height + 40
            let sheetY = lerp(lerp(hiddenY, collapsedY, presence), 0, t)
            let sheetHeight = lerp(miniHeight, height, t)
            let hPad = lerp(sidePadding, 0, t)
            let topRadius = lerp(40, 0, t)
            let bottomRadius = t < 0.2 ? lerp(40, 26, t / 0.2) : lerp(26, 0, (t - 0.2) / 0.8)
            let colors = player.m3Colors
            let layout = FullLayout(width: width, height: height, safe: safe)

            ZStack(alignment: .topLeading) {
                // 판
                sheetBody(colors: colors, layout: layout, collapsedY: collapsedY)
                    .frame(width: width - hPad * 2, height: sheetHeight, alignment: .top)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
                                                      bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
                                                      style: .continuous))
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
                                               bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
                                               style: .continuous)
                            .fill(colors.background)
                            .shadow(color: .black.opacity(t < 0.05 ? 0.28 : 0), radius: 6, y: 2)
                    }
                    .scaleEffect(x: 1, y: squash, anchor: .bottom)
                    .offset(x: hPad + swipeX * (1 - t), y: sheetY)

                // 미니 ↔ 전체 ↔ 가사 사이를 날아다니는 커버 하나
                flyingArtwork(layout: layout, hPad: hPad, sheetY: sheetY)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .coordinateSpace(.named("m3sheet"))
            .ignoresSafeArea()
        }
        .environment(lyricsLoader)
        .task(id: player.current?.trackID) {
            await lyricsLoader.load(player.current, context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tuneLyricsReplaced)) { note in
            // 지금 곡 가사를 새로 받아 바꿨으면 다시 읽는다.
            guard let id = note.object as? UUID, id == player.current?.trackID else { return }
            Task { await lyricsLoader.load(player.current, context: modelContext, force: true) }
        }
        .onAppear {
            presence = visible ? 1 : 0
            t = router.showPlayer && visible ? 1 : 0
        }
        .onChange(of: visible) { _, show in
            withAnimation(M3Motion.sheet) {
                presence = show ? 1 : 0
                if !show { t = 0 }
            }
            if !show {
                router.showPlayer = false
                closeOverlays()
            }
        }
        .onChange(of: router.showPlayer) { _, open in
            guard visible || !open else { router.showPlayer = false; return }
            if (t > 0.5) != open { settle(expanded: open) }
            if !open { closeOverlays() }
        }
        .sheet(isPresented: $showSleepTimer) {
            M3SleepTimerSheet()
        }
    }

    // MARK: 판 안쪽

    @ViewBuilder
    private func sheetBody(colors: M3PlayerColors, layout: FullLayout, collapsedY: CGFloat) -> some View {
        ZStack(alignment: .top) {
            colors.background

            miniContent(colors: colors, collapsedY: collapsedY)
                .frame(height: miniHeight)
                .opacity(Double(max(0, 1 - t * 2)))
                .allowsHitTesting(t < 0.5)

            if t > 0.01 {
                fullContent(colors: colors, layout: layout, collapsedY: collapsedY)
                    .frame(width: layout.width, height: layout.height)
                    .opacity(Double(max(0, (t - 0.5) * 2)))
                    .scaleEffect(lerp(0.972, 1, t))
                    .offset(y: lerp(100, 0, t))
                    .allowsHitTesting(t > 0.5)
            }
        }
    }

    // MARK: 미니 플레이어 (높이 80 알약)

    private func miniContent(colors: M3PlayerColors, collapsedY: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 커버(48)를 둘러싼 물결 고리(58). 커버 자체는 날아다니는 커버가 그린다.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = max(player.duration, 1)
                let now = player.isPlaying ? player.currentTime() : player.elapsed
                M3WavyProgressRing(progress: min(max(now / duration, 0), 1), isPlaying: player.isPlaying,
                                   color: colors.accent)
            }
            .frame(width: 58, height: 58)
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "")
                    .font(.m3(14, .bold))
                    .foregroundStyle(colors.content)
                    .lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.m3(12))
                    .foregroundStyle(colors.contentSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)

            HStack(spacing: 0) {
                miniIcon("backward.fill", label: "이전 곡") { player.previous() }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(colors.content)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                miniIcon("forward.fill", label: "다음 곡") { player.next() }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { settle(expanded: true) }
        .gesture(miniGesture(collapsedY: collapsedY))
        .contextMenu {
            Button { player.toggleFavorite() } label: {
                Label(player.isCurrentFavorite ? "좋아요 취소" : "좋아요", systemImage: player.isCurrentFavorite ? "heart.slash" : "heart")
            }
        }
        .sensoryFeedback(.selection, trigger: player.current?.uid)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("미니 플레이어")
    }

    private func miniIcon(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 위아래로 끌면 판이 따라 펼쳐지고, 옆으로 밀면 이전·다음 곡.
    /// 옆으로 밀 때 처음 100pt는 고무줄처럼 30pt까지만 따라오다가 넘는 순간 '톡' 붙는다.
    private func miniGesture(collapsedY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                if dragAxis == .horizontal {
                    let dx = value.translation.width
                    if abs(dx) < 100 {
                        swipeX = (abs(dx) / 100 * 30) * (dx < 0 ? -1 : 1)
                        swipePassed = false
                    } else {
                        if !swipePassed { swipePassed = true }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { swipeX = dx }
                    }
                } else {
                    dragSheet(value, collapsedY: collapsedY)
                }
            }
            .onEnded { value in
                if dragAxis == .horizontal {
                    let dx = value.translation.width
                    if abs(dx) > 100 || abs(value.predictedEndTranslation.width) > 260 {
                        if dx < 0 { player.next() } else { player.previous() }
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { swipeX = 0 }
                    swipePassed = false
                } else {
                    endSheetDrag(value)
                }
                dragAxis = nil
            }
    }

    // MARK: 전체 재생 화면

    struct FullLayout {
        let width: CGFloat
        let height: CGFloat
        let safe: EdgeInsets

        /// 커버 밑에 오는 것들(제목 · 칩 · 진행 · 버튼 · 볼륨)의 높이
        var below: CGFloat { 12 + 58 + 16 + 36 + 24 + 46 + 16 + 76 + 14 + 28 + 40 }

        /// 커버 한 변: 화면 폭의 90%, 작은 화면이면 남는 높이에 맞춘다.
        var artwork: CGFloat {
            let room = height - safe.top - safe.bottom - 68 - below
            return max(160, min(width * 0.9, room))
        }

        /// 커버 위쪽 위치
        var artworkTop: CGFloat {
            max(safe.top + 68, (height - artwork) / 2 - 220)
        }
    }

    @ViewBuilder
    private func fullContent(colors: M3PlayerColors, layout: FullLayout, collapsedY: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.safe.top + 12)
                // 머리줄: 접기 · 지금 재생 중 · 더 보기
                HStack {
                    Button { settle(expanded: false) } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("재생 화면 접기")
                    Spacer()
                    Text("지금 재생 중")
                        .font(.m3(14, .bold))
                        .foregroundStyle(colors.contentSecondary)
                    Spacer()
                    M3PlayerMoreMenu { route in navigate(route) }
                }
                .frame(height: 56)
                .padding(.horizontal, 20)

                Color.clear.frame(height: max(0, layout.artworkTop - (layout.safe.top + 68)))
                // 커버 자리 (실제 커버는 날아다니는 커버)
                Color.clear
                    .frame(width: layout.artwork, height: layout.artwork)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleLyrics() }

                Color.clear.frame(height: 12)
                M3PlayerTitle()
                    .padding(.horizontal, 20)
                Color.clear.frame(height: 16)
                M3PlayerChipRow(lyricsOn: lyricsOpen, queueOn: queueOpen,
                                onLyrics: toggleLyrics,
                                onQueue: { setQueue(!queueOpen) },
                                onSleepTimer: { showSleepTimer = true },
                                onLyricsChipFrame: { lyricsChip = $0 })
                Color.clear.frame(height: 24)
                M3PlaybackProgress()
                    .padding(.horizontal, 20)
                Color.clear.frame(height: 16)
                M3TransportGroup()
                    .padding(.horizontal, 4)
                Color.clear.frame(height: 14)
                M3VolumeRow()
                    .padding(.horizontal, 20)
                // 대기열 손잡이: 누르거나 위로 밀면 대기열이 올라온다.
                Image(systemName: "chevron.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
                    .onTapGesture { setQueue(true) }
                    .accessibilityLabel("대기열 열기")
                    .accessibilityAddTraits(.isButton)
                Spacer(minLength: 0)
            }
            .frame(width: layout.width, height: layout.height, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(fullGesture(collapsedY: collapsedY), including: lyricsOpen || queueOpen ? .subviews : .all)

            if lyricsReveal > 0 {
                lyricsOverlay(colors: colors, layout: layout)
            }

            queueDrawer(colors: colors, layout: layout)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// 전체 화면 어디서든 아래로 끌면 접힌다(가사·대기열이 열려 있을 땐 꺼짐).
    private func fullGesture(collapsedY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard !lyricsOpen, !queueOpen else { return }
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .vertical else { return }
                // 아래쪽 1/4에서 위로 밀면 대기열
                if value.translation.height < -40, value.startLocation.y > collapsedY * 0.85 {
                    return
                }
                dragSheet(value, collapsedY: collapsedY)
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard !lyricsOpen, !queueOpen, dragAxis == .vertical else { return }
                if value.translation.height < -40, value.startLocation.y > collapsedY * 0.85 {
                    setQueue(true)
                    return
                }
                endSheetDrag(value)
            }
    }

    // MARK: 날아다니는 커버

    @ViewBuilder
    private func flyingArtwork(layout: FullLayout, hPad: CGFloat, sheetY: CGFloat) -> some View {
        let full = layout.artwork
        let size = lerp(lerp(48, full, t), 44, lyricsReveal > 0 ? lyricsArtProgress : 0)
        let miniX = sidePadding + 16
        let fullX = (layout.width - full) / 2
        let lyricsX: CGFloat = 22
        let normalX = lerp(miniX, fullX, t) + swipeX * (1 - t)
        let normalY = lerp(sheetY + 16, layout.artworkTop, t)
        let p = lyricsArtProgress
        let x = lerp(normalX, lyricsX, p)
        let y = lerp(normalY, layout.safe.top + 18, p)
        let radius = lerp(lerp(24, 16, t), 10, p)

        // 커버는 늘 전체 크기로 그리고 크기만 줄인다(크기가 바뀔 때마다 그림을 다시 읽지 않게).
        let scale = max(size / max(full, 1), 0.01)
        ArtworkView(file: player.current?.artworkFile, cornerRadius: 0, title: player.current?.album)
            .frame(width: full, height: full)
            .clipShape(RoundedRectangle(cornerRadius: radius / scale, style: .continuous))
            .shadow(color: .black.opacity(Double(lerp(0, 0.35, t))), radius: (lerp(0, 16, t) + 6 * p) / scale, y: lerp(0, 8, t) / scale)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: full, height: full, alignment: .topLeading)
            .opacity(queueOpen ? 0 : 1)
            .animation(M3Motion.drawer, value: queueOpen)
            .offset(x: x, y: y)
            .allowsHitTesting(lyricsOpen)
            .onTapGesture { if lyricsOpen { toggleLyrics() } }
            .accessibilityHidden(true)
    }

    private var lyricsArtProgress: CGFloat { lyricsOpen ? 1 : 0 }

    // MARK: 가사

    @ViewBuilder
    private func lyricsOverlay(colors: M3PlayerColors, layout: FullLayout) -> some View {
        let center = lyricsChip == .zero
            ? CGPoint(x: layout.width * 0.9, y: layout.height * 0.72)
            : CGPoint(x: lyricsChip.midX, y: lyricsChip.midY)
        let maxRadius = [CGPoint(x: 0, y: 0), CGPoint(x: layout.width, y: 0),
                         CGPoint(x: 0, y: layout.height), CGPoint(x: layout.width, y: layout.height)]
            .map { hypot($0.x - center.x, $0.y - center.y) }
            .max() ?? layout.height

        VStack(spacing: 0) {
            Color.clear.frame(height: layout.safe.top + 12)
            HStack(spacing: 0) {
                Color.clear.frame(width: 48, height: 48)
                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        Text("가사")
                        if let badge = lyricsBadge {
                            Text(" • \(badge)")
                                .foregroundStyle(.white.opacity(0.4))
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .font(.m3(11, .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
                    Text(player.current?.title ?? "")
                        .font(.m3(16, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .animation(M3Motion.bouncy, value: lyricsBadge)
                M3PlayerMoreMenu { route in navigate(route) }
            }
            .frame(height: 56)
            .padding(.horizontal, 20)

            Group {
                if lyricsReveal > 0.8 {
                    LyricsView(lyrics: lyricsLoader.lyrics, isLoading: lyricsLoader.isLoading)
                        .padding(.horizontal, 28)
                        .transition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(maxHeight: .infinity)

            // 아래 작은 조작 줄
            VStack(spacing: 6) {
                M3PlaybackProgress()
                HStack(spacing: 8) {
                    Button { toggleLyrics() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(M3ExpressiveButtonStyle(container: colors.chip, content: .white, radius: 22, pressedRadius: 10))
                    .frame(width: 64)
                    .accessibilityLabel("가사 닫기")
                    M3TransportGroup(height: 52)
                        .padding(.horizontal, -16)
                }
                .frame(height: 52)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, layout.safe.bottom + 8)
        }
        .frame(width: layout.width, height: layout.height)
        .background(colors.lyricsBackground)
        .mask {
            Circle()
                .frame(width: maxRadius * 2 * lyricsReveal, height: maxRadius * 2 * lyricsReveal)
                .position(center)
                .frame(width: layout.width, height: layout.height)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var lyricsBadge: String? {
        guard let lyrics = lyricsLoader.lyrics else { return nil }
        if lyrics.isSynced {
            return lyrics.lines.contains(where: \.hasWordTiming) ? "단어 싱크" : "줄 싱크"
        }
        return lyrics.plainText.isEmpty ? nil : "일반 가사"
    }

    private func toggleLyrics() {
        let open = !lyricsOpen
        withAnimation(M3Motion.lyricsArtwork) { lyricsOpen = open }
        withAnimation(.easeInOut(duration: 0.34)) { lyricsReveal = open ? 1 : 0 }
    }

    // MARK: 대기열 서랍

    @ViewBuilder
    private func queueDrawer(colors: M3PlayerColors, layout: FullLayout) -> some View {
        M3QueueDrawer(colors: colors, safe: layout.safe,
                      onClose: { setQueue(false) },
                      onSleepTimer: { showSleepTimer = true })
            .frame(width: layout.width, height: layout.height)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: queueOpen ? 0 : 32, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: queueOpen ? 0 : 32,
                                              style: .continuous))
            .offset(y: queueOpen ? 0 : layout.height + 100)
            .animation(M3Motion.drawer, value: queueOpen)
    }

    private func setQueue(_ open: Bool) {
        withAnimation(M3Motion.drawer) { queueOpen = open }
    }

    private func closeOverlays() {
        lyricsOpen = false
        lyricsReveal = 0
        queueOpen = false
    }

    // MARK: 끌기 · 놓기

    private func dragSheet(_ value: DragGesture.Value, collapsedY: CGFloat) {
        if dragStart == nil { dragStart = t }
        guard let start = dragStart else { return }
        if start >= 0.99 && value.translation.height < 0 { return }
        let distance = max(collapsedY, 1)
        t = min(max(start - value.translation.height / distance, 0), 1)
    }

    private func endSheetDrag(_ value: DragGesture.Value) {
        let start = dragStart ?? t
        dragStart = nil
        let dy = value.translation.height
        let velocity = value.velocity.height
        let expand: Bool
        if start >= 0.99 && dy <= 0 {
            expand = true
        } else if abs(dy) > 5 {
            expand = dy < 0
        } else if abs(velocity) > 150 {
            expand = velocity < 0
        } else {
            expand = t > 0.5
        }
        settle(expanded: expand)
    }

    /// 놓은 뒤 스프링으로 끝까지 간다. 접힐 땐 바닥에 닿듯 살짝 눌렸다가 튄다.
    private func settle(expanded: Bool) {
        if !expanded {
            closeOverlays()
            let squashFrom = lerp(1, 0.97, t)
            squash = squashFrom
            withAnimation(M3Motion.spring(stiffness: 50, damping: 0.5)) { squash = 1 }
            withAnimation(M3Motion.spring(stiffness: 200, damping: Double(lerp(1, 0.75, t)))) { t = 0 }
        } else {
            withAnimation(M3Motion.sheet) { t = 1 }
        }
        if router.showPlayer != expanded { router.showPlayer = expanded }
    }

    /// 다른 화면으로 갈 때는 시트를 먼저 접는다.
    private func navigate(_ route: Route) {
        settle(expanded: false)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            router.open(route)
        }
    }
}

// MARK: - 대기열 서랍

struct M3QueueDrawer: View {
    let colors: M3PlayerColors
    let safe: EdgeInsets
    var onClose: () -> Void
    var onSleepTimer: () -> Void

    @Environment(PlayerEngine.self) private var player
    @AppStorage(SettingsKey.autoplay) private var autoplay = true
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            // 머리
            HStack(spacing: 4) {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("대기열 닫기")
                VStack(alignment: .leading, spacing: 0) {
                    Text("재생 중")
                        .font(.m3(16, .medium))
                        .opacity(0.9)
                    Text("대기열")
                        .font(.m3(14, .heavy))
                        .tracking(0.5)
                        .opacity(0.9)
                }
                Spacer()
                if !player.history.isEmpty {
                    Button(showHistory ? "기록 숨기기" : "기록") {
                        withAnimation(M3Motion.standard) { showHistory.toggle() }
                    }
                    .font(.m3(12, .bold))
                    .foregroundStyle(colors.accent)
                    .padding(.trailing, 8)
                }
                Text("\(player.upNext.count + 1)곡")
                    .font(.m3(12, .bold))
                    .foregroundStyle(colors.contentSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, safe.top + 16)
            .padding(.bottom, 8)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            List {
                if showHistory, !player.history.isEmpty {
                    let past = Array(player.history.suffix(30))
                    Section {
                        ForEach(Array(past.enumerated()), id: \.element.id) { index, item in
                            M3QueueRow(item: item, isCurrent: false, colors: colors)
                                .opacity(0.6)
                                .contentShape(Rectangle())
                                .onTapGesture { player.jump(to: item) }
                                .listRowBackground(rowBackground(index: index, count: past.count))
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                }

                if let current = player.current {
                    Section {
                        M3QueueRow(item: current, isCurrent: true, colors: colors)
                            .listRowBackground(
                                M3Shape.segment(index: 0, count: 1, outer: 24).fill(colors.accent.opacity(0.18))
                                    .padding(.horizontal, 16).padding(.vertical, 2)
                            )
                            .moveDisabled(true)
                            .deleteDisabled(true)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }

                Section {
                    let upcoming = player.upNext
                    ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                        M3QueueRow(item: item, isCurrent: false, colors: colors)
                            .contentShape(Rectangle())
                            .onTapGesture { player.jump(to: item) }
                            .listRowBackground(rowBackground(index: index, count: upcoming.count))
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeFromUpNext(at: $0) }
                } header: {
                    HStack {
                        Text("다음 곡")
                        Spacer()
                        if !player.upNext.isEmpty {
                            Button("모두 지우기") { player.clearUpNext() }
                                .foregroundStyle(colors.accent)
                        }
                    }
                    .font(.m3(13, .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .textCase(nil)
                } footer: {
                    if player.upNext.isEmpty {
                        Text(autoplay ? "대기열이 끝나면 비슷한 곡을 이어서 틀어요." : "다음 곡이 없어요.")
                            .font(.m3(12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))

                Color.clear.frame(height: 110)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .environment(\.defaultMinListRowHeight, 60)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(colors.background)
        .overlay(alignment: .bottom) { tray }
        .foregroundStyle(.white)
    }

    private func rowBackground(index: Int, count: Int) -> some View {
        M3Shape.segment(index: index, count: count, outer: 20)
            .fill(Color.white.opacity(0.05))
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
    }

    /// 아래 판: 셔플 · 반복 · 자동 재생 · 수면 타이머 (높이 56, 누르면 모서리 28→12)
    private var tray: some View {
        HStack(spacing: 8) {
            trayButton("shuffle", label: "셔플", active: player.shuffle) { player.shuffle.toggle() }
            trayButton(player.repeatMode.symbol, label: player.repeatMode == .one ? "한 곡 반복" : "반복",
                       active: player.repeatMode != .off) { player.repeatMode = player.repeatMode.next }
            trayButton("infinity", label: "자동 재생", active: autoplay) { autoplay.toggle() }
            trayButton(player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz", label: "수면 타이머",
                       active: player.isSleepTimerActive, action: onSleepTimer)
        }
        .frame(height: 56)
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, max(safe.bottom, 16))
        .background(colors.trayBackground, in: UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0,
                                                                       bottomTrailingRadius: 0, topTrailingRadius: 24,
                                                                       style: .continuous))
    }

    private func trayButton(_ systemImage: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
        }
        .buttonStyle(M3ExpressiveButtonStyle(container: active ? colors.trayActive : colors.trayInactive,
                                             content: active ? colors.trayActiveContent : .white))
        .sensoryFeedback(.selection, trigger: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct M3QueueRow: View {
    let item: QueueItem
    var isCurrent: Bool
    let colors: M3PlayerColors
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: Spacing.m) {
            ArtworkView(file: item.artworkFile, cornerRadius: 12, title: item.album)
                .frame(width: 52, height: 52)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.4))
                        PlayingBars(isAnimating: player.isPlaying, color: .white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.m3(15, isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? colors.accent : .white)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.m3(13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

/// 선형 보간
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}
