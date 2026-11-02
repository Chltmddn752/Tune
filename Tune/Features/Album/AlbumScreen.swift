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
                .screenBackground(nil)
        }
    }
}

/// iOS 26.4 Apple Music 방식: 커버가 화면 너비를 채우고 아래쪽이 투명해지며 배경으로 녹아든다.
struct AlbumView: View {
    let album: Album

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.windowSize) private var windowSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Query private var sameArtistAlbums: [Album]
    /// 위로 당긴 거리. 곡 목록까지 다시 계산되지 않게 스크롤 위치 대신 필요한 값만 상태로 둔다.
    @State private var pull: CGFloat = 0
    @State private var showsNavigationTitle = false
    /// 상태 표시줄 뒤에 아직 커버 윗부분이 있는지.
    @State private var coverTopVisible = true

    init(album: Album) {
        self.album = album
        let artist = album.artistName
        let id = album.id
        _sameArtistAlbums = Query(filter: #Predicate<Album> { $0.artistName == artist && $0.id != id })
    }

    private var isLight: Bool { backdrop.isLight }
    private var textColor: Color { backdrop.textColor }
    private var backdrop: CoverBackdrop { album.coverBackdrop }
    /// 아이폰은 커버가 맨 위를 채우는 동안 커버 윗부분 밝기를 따른다.
    private var toolbarIsLight: Bool { sizeClass != .regular && coverTopVisible ? backdrop.topIsLight : isLight }

    var body: some View {
        Group {
            if sizeClass == .regular {
                regular
            } else {
                compact
            }
        }
        .screenBackground(
            ScreenBackgroundCenter.Info(
                colors: album.gradientColors,
                style: .vivid,
                isLight: isLight,
                backdrop: backdrop
            )
        )
        .foregroundStyle(textColor)
        .tint(textColor)
        .toolbarColorScheme(toolbarIsLight ? .light : .dark, for: .navigationBar)
        .navigationTitle(showsNavigationTitle ? album.title : "")
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
            // 배경 윗부분도 콘텐츠에 붙여 커버와 함께 스크롤한다(고정 배경 위로 커버만 올라가면 경계가 생긴다).
            .background(alignment: .top) {
                GeometryReader { proxy in
                    CoverBackdropView(
                        backdrop: backdrop,
                        artworkFile: album.artworkFile,
                        coverHeight: proxy.size.width,
                        fadeHeight: (windowSize.height > 1 ? windowSize.height : proxy.size.width * 2) * 0.4
                    )
                }
            }
        }
        // 투명도 줄이기에서는 위쪽 스크롤 효과가 불투명한 띠가 되어 커버 위에 경계를 만든다.
        .scrollEdgeEffectHidden(reduceTransparency && coverTopVisible, for: .top)
        // 콘텐츠 아래쪽 끝과 바운스 영역은 맨 아래 색으로 채운다.
        .background { backdrop.bottom.ignoresSafeArea() }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, value in
            trackScroll(value)
        }
        .ignoresSafeArea(edges: .top)
    }

    /// 값이 실제로 바뀔 때만 상태를 건드려서 스크롤 중에 화면 전체가 다시 그려지지 않게 한다.
    private func trackScroll(_ offset: CGFloat) {
        let newPull = max(-offset, 0)
        if newPull != pull { pull = newPull }
        let titleVisible = offset > 300
        if titleVisible != showsNavigationTitle { showsNavigationTitle = titleVisible }
        let topVisible = offset < 180
        if topVisible != coverTopVisible { coverTopVisible = topVisible }
    }

    /// 커버: 아래로 당기면 맨 위에 붙은 채로 커지고, 위로 스크롤하면 콘텐츠와 함께 올라간다.
    /// 아래쪽은 색을 덮지 않고 투명하게 지워서 뒤에 깔린 배경이 그대로 비친다.
    private var header: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ArtworkView(file: album.artworkFile, cornerRadius: 0, square: false,
                        colorHex: album.colorHex, title: album.title)
                .frame(width: width, height: width + pull)
                .coverFadeMask()
                // 당기는 만큼 위로 올려서 화면 맨 위에 붙어 있게 한다.
                .offset(y: -pull)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var info: some View {
        VStack(spacing: Spacing.s) {
            Group {
                Text(album.title)
                    .font(.tuneSection)
                    .multilineTextAlignment(.center)
                // "ROSÉ, F1 The Album"처럼 여러 이름이면 이름마다 따로 눌러 이동한다.
                ArtistLinksText(raw: album.artistName, font: .title3, color: textColor)
                    .opacity(0.8)
                HStack(spacing: Spacing.s) {
                    Text(metaLine)
                    if album.isLossless { LosslessBadge().foregroundStyle(textColor.opacity(0.7)) }
                }
                .font(.footnote)
                .opacity(0.7)
            }
            // 글자가 흐려지는 커버 위에 놓이므로 글자 뒤에만 아주 약한 그림자를 준다.
            .shadow(color: (isLight ? Color.white : .black).opacity(0.25), radius: 6)

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
                    subtitleArtistLinks: true,
                    meta: metaLine,
                    showsLossless: album.isLossless,
                    textColor: textColor,
                    onPlay: { player.play(tracks, context: .album(album.id)) },
                    onShuffle: { player.play(tracks, shuffled: true, context: .album(album.id)) },
                    addTracks: tracks
                ) {
                    ArtworkView(file: album.artworkFile, cornerRadius: Radius.playerArtwork,
                                colorHex: album.colorHex, title: album.title)
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
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, value in
            trackScroll(value)
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
