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

/// 사진이 위를 채우고 왼쪽 아래에 큰 이름 (Spotify 방식 헤더)
struct ArtistView: View {
    let artist: Artist

    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var allTracks: [Track]
    @State private var scrollOffset: CGFloat = 0
    @State private var showAllPopular = false

    init(artist: Artist) {
        self.artist = artist
        let name = artist.name
        _allTracks = Query(filter: #Predicate<Track> { $0.artistName.contains(name) || $0.albumArtistName == name })
    }

    private var headerHeight: CGFloat { sizeClass == .regular ? 340 : 390 }

    /// "A, B"처럼 여러 명이 적힌 곡도 이름 단위로 맞춰 본다("A"가 "AB"에 걸리지 않게).
    private var related: [Track] {
        allTracks.filter {
            NameSplitter.contains($0.artistName, artist: artist.name) || NameSplitter.contains($0.albumArtistName, artist: artist.name)
        }
    }

    private func isMain(_ track: Track) -> Bool {
        NameSplitter.primaryArtist(track.artistName).lowercased() == artist.key
            || NameSplitter.contains(track.albumArtistName, artist: artist.name)
    }

    private var ownAlbums: [Album] {
        let albums = Set(related.filter { NameSplitter.contains($0.albumArtistName, artist: artist.name) }.compactMap(\.album))
        return albums.sorted { ($0.year ?? 0, $0.addedAt) > ($1.year ?? 0, $1.addedAt) }
    }

    private var fullAlbums: [Album] { ownAlbums.filter { !$0.isSingleOrEP } }
    private var singles: [Album] { ownAlbums.filter(\.isSingleOrEP) }

    private var popular: [Track] {
        related.filter(isMain)
            .sorted { ($0.playCount, $0.lastPlayedAt ?? .distantPast) > ($1.playCount, $1.lastPlayedAt ?? .distantPast) }
    }

    private var featured: [Track] {
        related.filter { !isMain($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header

                if !popular.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack {
                            Text("인기 곡").font(.tuneSection)
                            Spacer()
                            if popular.count > 5 {
                                Button(showAllPopular ? "접기" : "모두 보기") { withAnimation { showAllPopular.toggle() } }
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        ForEach(Array(popular.prefix(showAllPopular ? 50 : 5).enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: Spacing.s) {
                                Text("\(index + 1)")
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                TrackRow(track: track, queue: popular, context: .artist(artist.id))
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.screen(sizeClass))
                }

                albumShelf("앨범", fullAlbums)
                albumShelf("싱글 및 EP", singles)

                if !featured.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("참여한 곡").font(.tuneSection)
                        ForEach(featured.prefix(10)) { TrackRow(track: $0, queue: featured) }
                    }
                    .padding(.horizontal, Spacing.screen(sizeClass))
                }
            }
            .padding(.bottom, 120)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, value in
            scrollOffset = value
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(scrollOffset > headerHeight - 100 ? artist.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { player.playNext(popular) } label: { Label("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button {
                        artist.imageFile = nil
                        artist.imageFetchedAt = nil
                        Task { await ArtistImageService.fetchIfNeeded(artist, context: modelContext) }
                    } label: { Label("사진 다시 받기", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .task {
            await ArtistImageService.fetchIfNeeded(artist, context: modelContext)
        }
    }

    private var header: some View {
        GeometryReader { proxy in
            let pull = max(-scrollOffset, 0)
            let scrolled = max(scrollOffset, 0)
            ZStack(alignment: .bottomLeading) {
                Group {
                    if artist.imageFile != nil {
                        ArtworkView(file: artist.imageFile, cornerRadius: 0, square: false)
                    } else {
                        // 사진이 없으면 대표 앨범 커버를 흐리게
                        ArtworkView(file: ownAlbums.first?.artworkFile ?? popular.first?.artworkFile, cornerRadius: 0, square: false)
                            .blur(radius: 30)
                    }
                }
                .frame(width: proxy.size.width, height: headerHeight + pull)
                // 위로 스크롤할 때 사진만 칸 안에서 덜 움직인다(넘치는 부분은 잘림).
                .offset(y: min(scrolled, headerHeight) * 0.4)

                // 이름이 잘 보이게 어둡게 + 맨 아래는 화면 배경색으로 녹아들게
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
                    Button {
                        player.play(popular, context: .artist(artist.id))
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.tuneAccent, in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    .accessibilityLabel("재생")
                    Button {
                        player.play(popular, shuffled: true, context: .artist(artist.id))
                    } label: {
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
            // 사진·이름이 머리말 칸 밖으로 삐져나오지 않게 자르고, 당기면 화면 맨 위에 붙어 커진다.
            .frame(width: proxy.size.width, height: headerHeight + pull, alignment: .bottom)
            .clipped()
            .offset(y: -pull)
        }
        .frame(height: headerHeight)
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
