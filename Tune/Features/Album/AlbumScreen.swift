import SwiftData
import SwiftUI

struct AlbumScreen: View {
    @Query private var albums: [Album]

    init(albumID: UUID) {
        _albums = Query(filter: #Predicate<Album> { $0.id == albumID })
    }

    var body: some View {
        if let album = albums.first {
            AlbumView(album: album)
        } else {
            ContentUnavailableView("앨범을 찾을 수 없어요", systemImage: "square.stack")
        }
    }
}

/// iOS 26.4 Apple Music 방식: 커버가 화면 너비를 채우고 아래로 대표색이 이어진다.
struct AlbumView: View {
    let album: Album

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var sameArtistAlbums: [Album]
    @State private var scrollOffset: CGFloat = 0

    init(album: Album) {
        self.album = album
        let artist = album.artistName
        let id = album.id
        _sameArtistAlbums = Query(filter: #Predicate<Album> { $0.artistName == artist && $0.id != id })
    }

    private var background: Color { Color(hex: album.colorHex, fallback: Color(.systemGray4)) }
    private var isLight: Bool { UIColor(hex: album.colorHex ?? "")?.isLight ?? false }
    private var textColor: Color { isLight ? .black : .white }

    var body: some View {
        Group {
            if sizeClass == .regular {
                regular
            } else {
                compact
            }
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(textColor)
        .tint(textColor)
        .toolbarColorScheme(isLight ? .light : .dark, for: .navigationBar)
        .navigationTitle(scrollOffset > 300 ? album.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { AlbumMenuItems(album: album) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("더 보기")
            }
        }
    }

    // MARK: 아이폰

    private var compact: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                info
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, -40)
                trackList
                    .padding(.top, Spacing.xl)
                footer
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, value in
            scrollOffset = value
        }
        .ignoresSafeArea(edges: .top)
    }

    /// 커버: 아래로 당기면 맨 위에 붙은 채로 커지고, 위로 스크롤하면 사진만 조금 느리게 올라간다.
    /// 사진은 머리말 칸 밖으로 절대 삐져나오지 않고, 아래쪽은 항상 배경색으로 녹아든다.
    private var header: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pull = max(-scrollOffset, 0)
            let scrolled = max(scrollOffset, 0)

            ZStack(alignment: .bottom) {
                ArtworkView(file: album.artworkFile, cornerRadius: 0, square: false)
                    .frame(width: width, height: width + pull)
                    // 위로 스크롤할 때 사진이 칸 안에서 덜 움직여서 깊이감이 생긴다(넘치는 부분은 잘림).
                    .offset(y: min(scrolled, width) * 0.4)

                LinearGradient(
                    stops: [
                        .init(color: background.opacity(0), location: 0),
                        .init(color: background.opacity(0.55), location: 0.55),
                        .init(color: background, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: width * 0.5)
            }
            .frame(width: width, height: width + pull, alignment: .bottom)
            .clipped()
            // 당기는 만큼 위로 올려서 화면 맨 위에 붙어 있게 한다.
            .offset(y: -pull)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var info: some View {
        VStack(spacing: Spacing.s) {
            Text(album.title)
                .font(.tuneSection)
                .multilineTextAlignment(.center)
            NavigationLink(value: album.artist.map { Route.artist($0.id) } ?? Route.artists) {
                Text(album.artistName)
                    .font(.title3)
                    .opacity(0.8)
            }
            .buttonStyle(.plain)
            HStack(spacing: Spacing.s) {
                Text(metaLine)
                if album.isLossless { LosslessBadge().foregroundStyle(textColor.opacity(0.7)) }
            }
            .font(.footnote)
            .opacity(0.7)

            PlayShuffleButtons(tint: textColor, background: AnyShapeStyle(textColor.opacity(0.15))) {
                player.play(album.sortedTracks, context: .album(album.id))
            } onShuffle: {
                player.play(album.sortedTracks, shuffled: true, context: .album(album.id))
            }
            .padding(.top, Spacing.s)
        }
    }

    private var metaLine: String {
        [album.genre.isEmpty ? nil : album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    private var trackList: some View {
        let tracks = album.sortedTracks
        let multiDisc = Set(tracks.map(\.discNumber)).count > 1
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if multiDisc, index == 0 || tracks[index - 1].discNumber != track.discNumber {
                    Text("디스크 \(track.discNumber)")
                        .font(.headline)
                        .padding(.top, index == 0 ? 0 : Spacing.l)
                        .padding(.bottom, Spacing.xs)
                }
                AlbumTrackRow(track: track, number: track.trackNumber > 0 ? track.trackNumber : index + 1,
                              showArtist: track.artistName != album.artistName, textColor: textColor) {
                    player.play(tracks, startAt: index, context: .album(album.id))
                }
                if index < tracks.count - 1 {
                    Divider().overlay(textColor.opacity(0.15)).padding(.leading, 40)
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            Text("곡 \(album.tracks.count)개, \(Formatters.longDuration(album.totalDuration))")
                .font(.footnote)
                .opacity(0.7)
                .padding(.horizontal, Spacing.xl)

            if !sameArtistAlbums.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("\(album.artistName)의 다른 앨범")
                        .font(.tuneSection)
                        .padding(.horizontal, Spacing.xl)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Spacing.l) {
                            ForEach(sameArtistAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }) { AlbumCard(album: $0, width: 150) }
                        }
                        .padding(.horizontal, Spacing.xl)
                    }
                    .scrollIndicators(.hidden)
                    .foregroundStyle(textColor)
                    .environment(\.colorScheme, isLight ? .light : .dark)
                }
            }
        }
        .padding(.top, Spacing.xl)
        .padding(.bottom, 120)
    }

    // MARK: 아이패드: Apple Music처럼 왼쪽 커버 + 오른쪽 정보, 아래 넓은 곡 목록

    private var regular: some View {
        let tracks = album.sortedTracks
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                CollectionHeaderWide(
                    title: album.title,
                    subtitle: album.artistName,
                    subtitleRoute: album.artist.map { Route.artist($0.id) },
                    meta: metaLine,
                    showsLossless: album.isLossless,
                    textColor: textColor,
                    onPlay: { player.play(tracks, context: .album(album.id)) },
                    onShuffle: { player.play(tracks, shuffled: true, context: .album(album.id)) },
                    addTracks: tracks
                ) {
                    ArtworkView(file: album.artworkFile, cornerRadius: Radius.playerArtwork)
                }

                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        WideTrackRow(
                            track: track,
                            leading: .number(track.trackNumber > 0 ? track.trackNumber : index + 1),
                            showArtist: track.artistName != album.artistName,
                            textColor: textColor
                        ) {
                            player.play(tracks, startAt: index, context: .album(album.id))
                        }
                    }
                }

                footer.padding(.horizontal, -Spacing.xl)
            }
            .padding(.horizontal, Spacing.xxxl)
            .padding(.top, Spacing.l)
        }
    }
}

private struct AlbumTrackRow: View {
    let track: Track
    let number: Int
    let showArtist: Bool
    let textColor: Color
    let action: () -> Void

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let isCurrent = player.current?.trackID == track.id
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                ZStack {
                    if isCurrent {
                        PlayingBars(isAnimating: player.isPlaying, color: textColor)
                    } else {
                        Text("\(number)").font(.body.monospacedDigit()).opacity(0.6)
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    if showArtist {
                        Text(track.artistName).font(.subheadline).opacity(0.65).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if track.isFavorite { Image(systemName: "star.fill").font(.caption).opacity(0.8) }
                Menu { TrackMenuItems(track: track) } label: {
                    Image(systemName: "ellipsis").frame(width: 32, height: 44).contentShape(Rectangle())
                }
                .opacity(0.7)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenuItems(track: track) }
    }
}
