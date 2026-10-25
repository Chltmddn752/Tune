import SwiftUI

/// 탭 바 위(또는 옆)에 떠 있는 미니 플레이어.
/// 아이패드에서는 Apple Music처럼 왼쪽에 조작 버튼, 가운데 곡 정보, 오른쪽에 가사·대기열 버튼을 둔다.
struct MiniPlayer: View {
    var onOpen: () -> Void

    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular && placement != .inline {
                wide
            } else {
                compact
            }
        }
        .sensoryFeedback(.selection, trigger: player.current?.uid)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("미니 플레이어")
    }

    // MARK: 아이폰

    private var compact: some View {
        let item = player.current
        let isInline = placement == .inline

        return HStack(spacing: Spacing.m) {
            ArtworkView(file: item?.artworkFile, cornerRadius: 6)
                .frame(width: isInline ? 28 : 36, height: isInline ? 28 : 36)

            VStack(alignment: .leading, spacing: 0) {
                Text(item?.title ?? "재생 중인 음악 없음")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !isInline, let artist = item?.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            playPauseButton(size: 36)
            if !isInline {
                iconButton("forward.fill", label: "다음 곡") { player.next() }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, isInline ? 8 : 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .gesture(swipeGesture)
        .contextMenu { contextItems }
    }

    // MARK: 아이패드

    private var wide: some View {
        let item = player.current

        return HStack(spacing: Spacing.l) {
            HStack(spacing: Spacing.xs) {
                iconButton("shuffle", label: "셔플", active: player.shuffle) { player.shuffle.toggle() }
                iconButton("backward.fill", label: "이전 곡") { player.previous() }
                playPauseButton(size: 40)
                iconButton("forward.fill", label: "다음 곡") { player.next() }
                iconButton(player.repeatMode.symbol, label: "반복", active: player.repeatMode != .off) {
                    player.repeatMode = player.repeatMode.next
                }
            }

            HStack(spacing: Spacing.m) {
                ArtworkView(file: item?.artworkFile, cornerRadius: 6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            HStack(spacing: Spacing.xs) {
                Menu { contextItems } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                }
                .accessibilityLabel("더 보기")
                iconButton("quote.bubble", label: "가사") { router.openPanel(.lyrics) }
                iconButton("list.bullet", label: "대기열") { router.openPanel(.queue) }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.l)
        .contextMenu { contextItems }
    }

    // MARK: 공통

    private func playPauseButton(size: CGFloat) -> some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(size > 36 ? .title2 : .title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
    }

    private func iconButton(_ systemImage: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(active ? Color.tuneAccent : Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    if dx < 0 { player.next() } else { player.previous() }
                } else if dy < -20 {
                    onOpen()
                }
            }
    }

    @ViewBuilder private var contextItems: some View {
        Button { onOpen() } label: { Label("재생 화면 열기", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button { player.toggleFavorite() } label: {
            Label(player.isCurrentFavorite ? "좋아요 취소" : "좋아요", systemImage: player.isCurrentFavorite ? "star.slash" : "star")
        }
    }
}
