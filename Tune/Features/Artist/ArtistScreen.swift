import SwiftData
import SwiftUI

struct ArtistScreen: View {
    @Query private var artists: [Artist]

    init(artistID: UUID) {
        _artists = Query(filter: #Predicate<Artist> { $0.id == artistID })
    }

    var body: some View {
        if let artist = artists.first {
            ArtistView(artist: artist)
        } else {
            ContentUnavailableView("아티스트를 찾을 수 없어요", systemImage: "music.mic")
        }
    }
}

/// 스크롤 위치를 헤더만 관찰하게 분리한 상태.
/// (부모 body가 매 프레임 다시 계산되면 곡 목록 필터·정렬까지 같이 돌아 30fps로 떨어졌다)
@MainActor
@Observable
private final class ArtistScrollState {
    var offset: CGFloat = 0
}

private struct ArtistSections {
    var related: [Track] = []
    var popular: [Track] = []
    var ownAlbums: [Album] = []
    var featured: [Track] = []
    var fullAlbums: [Album] = []
    var singles: [Album] = []
}

/// 사진이 위를 채우고 왼쪽 아래에 큰 이름 (Spotify 방식 헤더)
struct ArtistView: View {
    let artist: Artist

    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var allTracks: [Track]
    @State private var scroll = ArtistScrollState()
    @State private var isHeaderCollapsed = false
    @State private var showAllPopular = false
    @State private var showPhotoPicker = false
    @State private var sections = ArtistSections()

    init(artist: Artist) {
        self.artist = artist
        let name = artist.name
        _allTracks = Query(filter: #Predicate<Track> { $0.artistName.contains(name) || $0.albumArtistName.contains(name) })
    }

    private var headerHeight: CGFloat { sizeClass == .regular ? 340 : 390 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                ArtistHeader(
                    artist: artist,
                    headerHeight: headerHeight,
                    fallbackArtwork: sections.ownAlbums.first?.artworkFile ?? sections.popular.first?.artworkFile,
                    scroll: scroll,
                    onPlay: { player.play(sections.popular, context: .artist(artist.id)) },
                    onShuffle: { player.play(sections.popular, shuffled: true, context: .artist(artist.id)) }
                )

                if !sections.popular.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack {
                            Text("인기 곡").font(.tuneSection)
                            Spacer()
                            if sections.popular.count > 5 {
                                Button(showAllPopular ? "접기" : "모두 보기") { withAnimation { showAllPopular.toggle() } }
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        ForEach(Array(sections.popular.prefix(showAllPopular ? 50 : 5).enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: Spacing.s) {
                                Text("\(index + 1)")
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                TrackRow(track: track, queue: sections.popular, context: .artist(artist.id))
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.screen(sizeClass))
                }

                albumShelf("앨범", sections.fullAlbums)
                albumShelf("싱글 및 EP", sections.singles)

                if !sections.featured.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("참여한 곡").font(.tuneSection)
                        ForEach(sections.featured.prefix(10)) { TrackRow(track: $0, queue: sections.featured) }
                    }
                    .padding(.horizontal, Spacing.screen(sizeClass))
                }
            }
            .padding(.bottom, 120)
        }
        .background {
            ArtworkGradientBackground(colors: sections.ownAlbums.first?.gradientColors ?? [], style: .soft,
                                      parallax: scroll.offset)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, value in
            scroll.offset = value
            // 제목 표시는 기준을 넘을 때 한 번만 바뀐다(값이 바뀔 때만 상태 갱신).
            let collapsed = value > headerHeight - 100
            if collapsed != isHeaderCollapsed { isHeaderCollapsed = collapsed }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(isHeaderCollapsed ? artist.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { player.playNext(sections.popular) } label: { Label("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { showPhotoPicker = true } label: { Label("사진 바꾸기", systemImage: "photo") }
                    Button {
                        Task { await ArtistImageService.fetchIfNeeded(artist, context: modelContext, force: true) }
                    } label: { Label("사진 다시 받기", systemImage: "arrow.clockwise") }
                    if artist.imageFile != nil {
                        Button(role: .destructive) {
                            ArtistImageService.removePhoto(from: artist, context: modelContext)
                        } label: { Label("사진 지우기", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .task {
            recompute()
            await ArtistImageService.fetchIfNeeded(artist, context: modelContext)
        }
        .onChange(of: allTracks.count) { _, _ in recompute() }
        .sheet(isPresented: $showPhotoPicker) {
            ArtistPhotoPicker(artist: artist)
        }
    }

    /// 필터·정렬은 곡 목록이 바뀔 때만 한 번 계산한다.
    private func recompute() {
        let related = allTracks.filter {
            NameSplitter.contains($0.artistName, artist: artist.name)
                || NameSplitter.contains($0.albumArtistName, artist: artist.name)
        }
        let ownAlbums = Set(related.filter {
            NameSplitter.contains($0.albumArtistName, artist: artist.name)
        }.compactMap(\.album)).sorted { ($0.year ?? 0, $0.addedAt) > ($1.year ?? 0, $1.addedAt) }
        let popular = related.filter(isMain)
            .sorted { ($0.playCount, $0.lastPlayedAt ?? .distantPast) > ($1.playCount, $1.lastPlayedAt ?? .distantPast) }
        sections = ArtistSections(
            related: related,
            popular: popular,
            ownAlbums: ownAlbums,
            featured: related.filter { !isMain($0) },
            fullAlbums: ownAlbums.filter { !$0.isSingleOrEP },
            singles: ownAlbums.filter(\.isSingleOrEP)
        )
    }

    private func isMain(_ track: Track) -> Bool {
        NameSplitter.primaryArtist(track.artistName).libraryKey == artist.key
            || NameSplitter.contains(track.albumArtistName, artist: artist.name)
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(title).font(.tuneSection)
                    .padding(.horizontal, Spacing.screen(sizeClass))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Spacing.l) {
                        ForEach(albums) { AlbumCard(album: $0, width: sizeClass == .regular ? 180 : 150) }
                    }
                    .padding(.horizontal, Spacing.screen(sizeClass))
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// 헤더만 스크롤 위치를 읽는다. 흐린 배경은 미리 만들어 캐시하고 스크롤 중에는 오프셋만 준다.
private struct ArtistHeader: View {
    let artist: Artist
    let headerHeight: CGFloat
    let fallbackArtwork: String?
    let scroll: ArtistScrollState
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var blurredBackdrop: UIImage?

    var body: some View {
        GeometryReader { proxy in
            let pull = max(-scroll.offset, 0)
            let scrolled = max(scroll.offset, 0)
            ZStack(alignment: .bottomLeading) {
                Group {
                    if artist.imageFile != nil {
                        ArtworkView(file: artist.imageFile, cornerRadius: 0, square: false)
                    } else if let blurredBackdrop {
                        Image(uiImage: blurredBackdrop)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ArtworkView(file: fallbackArtwork, cornerRadius: 0, square: false)
                    }
                }
                .frame(width: proxy.size.width, height: headerHeight + pull)
                // 위로 스크롤할 때 사진만 칸 안에서 덜 움직인다(넘치는 부분은 잘림).
                .offset(y: min(scrolled, headerHeight) * 0.4)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.45), location: 0.8),
                        .init(color: Color(.systemBackground), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                HStack(alignment: .bottom) {
                    Text(artist.name)
                        .font(.tuneArtistName)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.3), radius: 8)
                    Spacer()
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.tuneAccent, in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    .accessibilityLabel("재생")
                    Button(action: onShuffle) {
                        Image(systemName: "shuffle")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular, in: Circle())
                    }
                    .accessibilityLabel("셔플")
                }
                .padding(.horizontal, Spacing.screen(sizeClass))
                .padding(.bottom, Spacing.xl)
            }
            .frame(width: proxy.size.width, height: headerHeight + pull, alignment: .bottom)
            .clipped()
            .offset(y: -pull)
        }
        .frame(height: headerHeight)
        .task(id: fallbackArtwork) {
            guard artist.imageFile == nil, let fallbackArtwork else { return }
            blurredBackdrop = await Task.detached(priority: .userInitiated) {
                ArtworkStore.blurred(fallbackArtwork, radius: 20)
            }.value
        }
    }
}
