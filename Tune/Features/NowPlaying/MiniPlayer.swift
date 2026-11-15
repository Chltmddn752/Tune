import SwiftUI

/// 아이패드에서 재생 패널을 닫았을 때 아래에 뜨는 알약 미니 플레이어 (Material 3).
/// 아이폰은 M3PlayerSheet가 미니 플레이어와 전체 화면을 함께 맡는다.
struct MiniPlayer: View {
    var onOpen: () -> Void

    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        let colors = player.m3Colors
        let item = player.current

        HStack(spacing: 0) {
            ZStack {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let duration = max(player.duration, 1)
                    let now = player.isPlaying ? player.currentTime() : player.elapsed
                    M3WavyProgressRing(progress: min(max(now / duration, 0), 1), isPlaying: player.isPlaying,
                                       color: colors.accent)
                }
                .frame(width: 58, height: 58)
                ArtworkView(file: item?.artworkFile, circle: true, title: item?.album)
                    .frame(width: 44, height: 44)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(item?.title ?? "재생 중인 음악 없음")
                    .font(.m3(14, .bold))
                    .lineLimit(1)
                Text(item?.artist ?? "")
                    .font(.m3(12))
                    .foregroundStyle(colors.contentSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            HStack(spacing: 2) {
                icon("shuffle", label: "셔플", active: player.shuffle) { player.shuffle.toggle() }
                icon("backward.fill", label: "이전 곡") { player.previous() }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                icon("forward.fill", label: "다음 곡") { player.next() }
                icon(player.repeatMode.symbol, label: "반복", active: player.repeatMode != .off) {
                    player.repeatMode = player.repeatMode.next
                }
                icon("quote.bubble", label: "가사") { router.openPanel(.lyrics) }
                icon("list.bullet", label: "대기열") { router.openPanel(.queue) }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 80)
        .background(colors.background, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .sensoryFeedback(.selection, trigger: player.current?.uid)
        .contextMenu {
            Button { onOpen() } label: { Label("재생 화면 열기", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { player.toggleFavorite() } label: {
                Label(player.isCurrentFavorite ? "좋아요 취소" : "좋아요", systemImage: player.isCurrentFavorite ? "heart.slash" : "heart")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("미니 플레이어")
    }

    private func icon(_ systemImage: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? player.m3Colors.accent : Color.white)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
