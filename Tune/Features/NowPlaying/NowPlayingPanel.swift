import SwiftData
import SwiftUI

/// 아이패드 오른쪽 재생 패널.
/// 사이드바처럼 떠 있는 둥근 카드 하나에 커버 · 곡 정보 · 조작만 두고,
/// 가사·대기열은 아래 아이콘을 눌렀을 때만 패널 전체에 펼친다.
struct NowPlayingPanel: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var modelContext
    @State private var lyricsLoader = LyricsLoader()

    private let cardRadius: CGFloat = 24

    var body: some View {
        let pane = router.panelPane

        ZStack {
            MeshBackground(colors: player.currentPalette, fallback: player.currentColor)

            VStack(spacing: 0) {
                topBar(pane: pane)

                switch pane {
                case .artwork:
                    mainScroll
                        .transition(.opacity)
                case .lyrics:
                    LyricsView(lyrics: lyricsLoader.lyrics, isLoading: lyricsLoader.isLoading)
                        .padding(.horizontal, Spacing.xl)
                        .transition(.opacity)
                    miniControls
                case .queue:
                    QueueView()
                        .transition(.opacity)
                    miniControls
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(lyricsLoader)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        // 상태 표시줄 아래에서 시작해 화면 아래 끝 가까이까지 (0.6 배치) — 아래는 홈 표시줄 영역까지 내려간다.
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .task(id: player.current?.trackID) {
            await lyricsLoader.load(player.current, context: modelContext)
        }
        .animation(.panel, value: pane)
    }

    // MARK: 위 막대

    private func topBar(pane: PlayerPane) -> some View {
        HStack(spacing: Spacing.s) {
            if pane == .artwork {
                barButton("sidebar.trailing", label: "패널 닫기") {
                    withAnimation(.panel) { router.panelVisible = false }
                }
                barButton("arrow.up.left.and.arrow.down.right", label: "전체 화면으로 보기") {
                    router.showPlayer = true
                }
            } else {
                barButton("chevron.left", label: "뒤로") {
                    router.panelPane = .artwork
                }
            }

            Spacer(minLength: Spacing.s)
            Text(barTitle(pane))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: Spacing.s)

            // 제목이 가운데 오도록 왼쪽 버튼 폭만큼 비운다.
            Color.clear.frame(width: pane == .artwork ? 36 * 2 + Spacing.s : 36, height: 36)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func barTitle(_ pane: PlayerPane) -> String {
        switch pane {
        case .artwork: player.current?.album ?? ""
        case .lyrics: "가사"
        case .queue: "대기열"
        }
    }

    // MARK: 기본 화면: 커버 · 곡 정보 · 조작 (가사·대기열은 아래 아이콘으로)

    /// 스크롤 없이 한 화면에 다 들어가게: 남는 높이만큼 커버가 줄어든다.
    private var mainScroll: some View {
        VStack(spacing: Spacing.l) {
            ArtworkView(file: player.current?.artworkFile, cornerRadius: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(player.isPlaying ? 1 : 0.9)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                .animation(.artworkPause, value: player.isPlaying)
                .layoutPriority(-1)
                .padding(.top, Spacing.xs)

            PlayerControls(pane: Binding(get: { router.panelPane }, set: { router.panelPane = $0 }),
                           showTitle: true, showPaneButtons: false)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.l) {
                AirPlayButton().frame(width: 44, height: 44)
                Spacer()
                paneButton("quote.bubble", label: "가사") { router.panelPane = .lyrics }
                paneButton("list.bullet", label: "대기열") { router.panelPane = .queue }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.xl)
    }

    private func paneButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 가사·대기열 화면 아래 작은 조작 줄
    private var miniControls: some View {
        HStack(spacing: Spacing.m) {
            ArtworkView(file: player.current?.artworkFile, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").frame(width: 36, height: 36) }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").frame(width: 36, height: 36) }
        }
        .buttonStyle(.plain)
        .padding(Spacing.m)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding([.horizontal, .bottom], Spacing.m)
    }
}



