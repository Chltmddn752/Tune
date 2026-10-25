import SwiftUI

/// 아이패드 앨범·플레이리스트 머리말 (Apple Music 방식)
/// 왼쪽에 커버, 오른쪽에 제목 · 아티스트 · 정보, 아래쪽에 [셔플] [재생] [+] 버튼
struct CollectionHeaderWide<Artwork: View>: View {
    let title: String
    let subtitle: String
    var subtitleRoute: Route? = nil
    var meta: String = ""
    var detail: String = ""
    var showsLossless = false
    var textColor: Color = .primary
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var addTracks: [Track] = []
    @ViewBuilder let artwork: () -> Artwork

    /// 재생 패널을 열면 폭이 좁아지므로, 폭에 맞춰 커버 크기·버튼 모양을 줄인다(화면 밖으로 밀려나지 않게).
    @State private var width: CGFloat = 900

    private var artworkSize: CGFloat { width < 560 ? 160 : (width < 720 ? 200 : 260) }
    private var compactButtons: Bool { width < 640 }

    var body: some View {
        HStack(alignment: .bottom, spacing: width < 720 ? Spacing.xl : Spacing.xxxl) {
            artwork()
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)

            VStack(alignment: .leading, spacing: Spacing.s) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                Group {
                    if let subtitleRoute {
                        NavigationLink(value: subtitleRoute) { Text(subtitle) }
                            .buttonStyle(.plain)
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.title2)
                .opacity(0.85)

                if !meta.isEmpty || showsLossless {
                    HStack(spacing: Spacing.s) {
                        if !meta.isEmpty { Text(meta) }
                        if showsLossless { LosslessBadge().foregroundStyle(textColor.opacity(0.7)) }
                    }
                    .font(.subheadline)
                    .opacity(0.7)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .opacity(0.75)
                        .lineLimit(3)
                }

                HStack(spacing: Spacing.m) {
                    Button(action: onShuffle) {
                        Image(systemName: "shuffle")
                            .font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("셔플")

                    Button(action: onPlay) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            if !compactButtons {
                                Text("재생")
                            }
                        }
                        .font(.title3.weight(.semibold))
                        .fixedSize()
                        .foregroundStyle(textColor == .white ? Color.black : Color.white)
                        .frame(width: compactButtons ? 52 : nil, height: 52)
                        .padding(.horizontal, compactButtons ? 0 : 28)
                        .background(textColor, in: Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("재생")

                    if !addTracks.isEmpty {
                        Menu {
                            AddToPlaylistMenu(tracks: addTracks)
                        } label: {
                            Image(systemName: "plus")
                                .font(.title3.weight(.semibold))
                                .frame(width: 52, height: 52)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("플레이리스트에 추가")
                    }
                }
                .padding(.top, Spacing.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: artworkSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .foregroundStyle(textColor)
    }
}

/// 아이패드 곡 목록 한 줄: 번호(또는 커버) · 제목 · 아티스트 · 길이 · …
struct WideTrackRow: View {
    enum Leading {
        case number(Int)
        case artwork
    }

    let track: Track
    var leading: Leading = .artwork
    var showArtist = true
    var textColor: Color = .primary
    let action: () -> Void

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let isCurrent = player.current?.trackID == track.id

        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: Spacing.l) {
                    switch leading {
                    case .number(let number):
                        ZStack {
                            if isCurrent {
                                PlayingBars(isAnimating: player.isPlaying, color: textColor)
                            } else {
                                Text("\(number)").font(.body.monospacedDigit()).opacity(0.55)
                            }
                        }
                        .frame(width: 32)
                    case .artwork:
                        ArtworkView(file: track.artworkFile, cornerRadius: Radius.listArtwork)
                            .frame(width: 44, height: 44)
                            .overlay {
                                if isCurrent {
                                    RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous).fill(.black.opacity(0.35))
                                    PlayingBars(isAnimating: player.isPlaying, color: .white)
                                }
                            }
                    }

                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.body.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                        if track.isFavorite {
                            Image(systemName: "star.fill").font(.caption2).opacity(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(showArtist ? track.artistName : "")
                        .font(.body)
                        .opacity(0.6)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(Formatters.time(track.duration))
                        .font(.body.monospacedDigit())
                        .opacity(0.6)
                        .frame(width: 56, alignment: .trailing)

                    Menu { TrackMenuItems(track: track) } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .opacity(0.8)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { TrackMenuItems(track: track) }

            Divider()
                .overlay(textColor.opacity(0.12))
                .padding(.leading, leadingInset)
        }
        .foregroundStyle(textColor)
    }

    private var leadingInset: CGFloat {
        switch leading {
        case .number: 48
        case .artwork: 60
        }
    }
}
