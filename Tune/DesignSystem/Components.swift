import SwiftData
import SwiftUI

// MARK: - 커버

struct ArtworkView: View {
    let file: String?
    var cornerRadius: CGFloat = Radius.card
    var circle = false
    /// false면 정사각형으로 맞추지 않고 주어진 칸을 꽉 채운다.
    var square = true

    var body: some View {
        // 빈 칸을 먼저 잡고 그 위에 그림을 꽉 채워 얹는다(넘치는 부분은 잘림).
        Color.clear
            .aspectRatio(square ? 1 : nil, contentMode: .fit)
            .frame(maxWidth: square ? nil : .infinity, maxHeight: square ? nil : .infinity)
            .overlay { content }
            .clipped()
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .overlay {
            if circle {
                Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let image = ArtworkStore.image(file) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(Color(.systemGray5))
                Image(systemName: circle ? "music.mic" : "music.note")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color(.systemGray2))
                    .minimumScaleFactor(0.3)
                    .padding(12)
            }
        }
    }
}

/// 아티스트 사진. 없으면 이름 첫 글자가 적힌 원.
struct ArtistImage: View {
    let artist: Artist

    var body: some View {
        if artist.imageFile != nil {
            ArtworkView(file: artist.imageFile, circle: true)
        } else {
            Circle()
                .fill(Color(.systemGray5))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(String(artist.name.prefix(1)))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.2)
                        .foregroundStyle(Color(.systemGray))
                        .padding(8)
                }
        }
    }
}

// MARK: - 재생 중 표시

struct PlayingBars: View {
    var isAnimating: Bool
    var color: Color = .tuneAccent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let height = isAnimating ? 0.35 + 0.65 * abs(sin(t * (3.2 + Double(i) * 1.3) + Double(i))) : 0.35
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 14 * height)
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
        }
    }
}

// MARK: - 곡 한 줄

struct TrackRow: View {
    let track: Track
    var number: Int? = nil
    var showArtwork = true
    var showArtist = true
    var queue: [Track] = []
    var context: PlaybackContext = .none

    @Environment(PlayerEngine.self) private var player

    private var isCurrent: Bool { player.current?.trackID == track.id }

    var body: some View {
        Button {
            if let start = queue.firstIndex(where: { $0.id == track.id }) {
                player.play(queue, startAt: start, context: context)
            } else {
                player.play([track], context: context)
            }
        } label: {
            HStack(spacing: Spacing.m) {
                if let number {
                    ZStack {
                        if isCurrent {
                            PlayingBars(isAnimating: player.isPlaying)
                        } else {
                            Text(number > 0 ? "\(number)" : "")
                                .font(.tuneSubtitle.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24)
                }
                if showArtwork {
                    ArtworkView(file: track.artworkFile, cornerRadius: Radius.listArtwork)
                        .frame(width: 44, height: 44)
                        .overlay {
                            if isCurrent && number == nil {
                                RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous)
                                    .fill(.black.opacity(0.35))
                                PlayingBars(isAnimating: player.isPlaying, color: .white)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.tuneBody)
                        .foregroundStyle(isCurrent ? Color.tuneAccent : Color.primary)
                        .lineLimit(1)
                    if showArtist {
                        HStack(spacing: 4) {
                            if track.isLossless {
                                Image(systemName: "waveform")
                                    .font(.caption2)
                                    .accessibilityLabel("무손실")
                            }
                            Text(track.artistName)
                                .lineLimit(1)
                        }
                        .font(.tuneSubtitle)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if track.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Color.tuneAccent)
                }
                Menu {
                    TrackMenuItems(track: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("더 보기")
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            TrackMenuItems(track: track)
        } preview: {
            ArtworkView(file: track.artworkFile, cornerRadius: Radius.playerArtwork)
                .frame(width: 280, height: 280)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext([track]) } label: {
                Label("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(Color.tuneAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { player.playLater([track]) } label: {
                Label("나중에 재생", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(.orange)
        }
    }
}

/// 곡 … 메뉴와 길게 누르기 메뉴의 공통 항목
struct TrackMenuItems: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirm = false

    var body: some View {
        Section {
            Button { player.playNext([track]) } label: {
                Label("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { player.playLater([track]) } label: {
                Label("나중에 재생", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        Section {
            AddToPlaylistMenu(tracks: [track])
            Button {
                track.isFavorite.toggle()
                try? modelContext.save()
            } label: {
                Label(track.isFavorite ? "좋아요 취소" : "좋아요", systemImage: track.isFavorite ? "star.slash" : "star")
            }
        }
        Section {
            if let album = track.album {
                Button { router.showPlayer = false; router.open(.album(album.id)) } label: {
                    Label("앨범으로 이동", systemImage: "square.stack")
                }
            }
            // 가수가 여러 명이면 누구로 갈지 하위 메뉴에서 고른다(보관함 조회는 하위 메뉴를 열 때만).
            if NameSplitter.artists(track.artistName).count > 1 {
                Menu {
                    ArtistChoiceButtons(track: track)
                } label: {
                    Label("아티스트로 이동", systemImage: "music.mic")
                }
            } else if let artist = track.artist {
                Button { router.showPlayer = false; router.open(.artist(artist.id)) } label: {
                    Label("아티스트로 이동", systemImage: "music.mic")
                }
            }
            Button { router.showPlayer = false; router.open(.mix("track:\(track.id.uuidString)")) } label: {
                Label("이 곡으로 믹스 만들기", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        Section {
            Button(role: .destructive) {
                importer.delete(track, context: modelContext)
            } label: {
                Label("보관함에서 삭제", systemImage: "trash")
            }
        }
    }
}

struct AddToPlaylistMenu: View {
    let tracks: [Track]
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]
    @Environment(\.modelContext) private var modelContext
    @State private var newName = ""

    var body: some View {
        Menu {
            Button {
                let playlist = Playlist(name: "새 플레이리스트 \(playlists.count + 1)")
                modelContext.insert(playlist)
                add(to: playlist)
            } label: {
                Label("새 플레이리스트", systemImage: "plus")
            }
            Divider()
            ForEach(playlists) { playlist in
                Button(playlist.name) { add(to: playlist) }
            }
        } label: {
            Label("플레이리스트에 추가", systemImage: "text.badge.plus")
        }
    }

    private func add(to playlist: Playlist) {
        var order = (playlist.entries.map(\.order).max() ?? -1) + 1
        for track in tracks {
            let entry = PlaylistEntry(order: order, trackID: track.id)
            modelContext.insert(entry)
            entry.playlist = playlist
            order += 1
        }
        playlist.updatedAt = .now
        try? modelContext.save()
    }
}

// MARK: - 카드

struct AlbumCard: View {
    let album: Album
    var width: CGFloat? = nil

    var body: some View {
        NavigationLink(value: Route.album(album.id)) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(file: album.artworkFile, cornerRadius: Radius.card)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title)
                        .font(.tuneSubtitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.artistName)
                        .font(.tuneCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { AlbumMenuItems(album: album) }
    }
}

struct AlbumMenuItems: View {
    let album: Album
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button { player.play(album.sortedTracks, context: .album(album.id)) } label: { Label("재생", systemImage: "play") }
        Button { player.play(album.sortedTracks, shuffled: true, context: .album(album.id)) } label: { Label("셔플", systemImage: "shuffle") }
        Button { player.playNext(album.sortedTracks) } label: { Label("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.playLater(album.sortedTracks) } label: { Label("나중에 재생", systemImage: "text.line.last.and.arrowtriangle.forward") }
        AddToPlaylistMenu(tracks: album.sortedTracks)
        Button {
            album.isPinned.toggle()
            try? modelContext.save()
        } label: {
            Label(album.isPinned ? "고정 해제" : "맨 위에 고정", systemImage: album.isPinned ? "pin.slash" : "pin")
        }
        Button(role: .destructive) { importer.delete(album, context: modelContext) } label: {
            Label("앨범 삭제", systemImage: "trash")
        }
    }
}

struct ArtistCircle: View {
    let artist: Artist
    var width: CGFloat = 120
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationLink(value: Route.artist(artist.id)) {
            VStack(spacing: 6) {
                ArtistImage(artist: artist)
                    .frame(width: width, height: width)
                Text(artist.name)
                    .font(.tuneSubtitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .task { await ArtistImageService.fetchIfNeeded(artist, context: modelContext) }
    }
}

/// 플레이리스트 커버: 직접 고른 사진, 아니면 앞 4곡 커버 2×2
struct PlaylistCover: View {
    let playlist: Playlist
    @Query private var tracks: [Track]

    init(playlist: Playlist) {
        self.playlist = playlist
        let ids = playlist.sortedEntries.prefix(12).map(\.trackID)
        _tracks = Query(filter: #Predicate<Track> { ids.contains($0.id) })
    }

    var body: some View {
        if playlist.coverFile != nil {
            ArtworkView(file: playlist.coverFile, cornerRadius: Radius.card)
        } else {
            let files = uniqueArtwork()
            if files.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { ArtworkView(file: files[0], cornerRadius: 0); ArtworkView(file: files[1], cornerRadius: 0) }
                    GridRow { ArtworkView(file: files[2], cornerRadius: 0); ArtworkView(file: files[3], cornerRadius: 0) }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            } else if let first = files.first {
                ArtworkView(file: first, cornerRadius: Radius.card)
            } else {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [Color.tuneAccent.opacity(0.8), Color.tuneAccent.opacity(0.4)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
    }

    private func uniqueArtwork() -> [String] {
        let order = playlist.sortedEntries.map(\.trackID)
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [String] = []
        for id in order {
            if let file = byID[id]?.artworkFile, !seen.contains(file) {
                seen.insert(file)
                result.append(file)
            }
        }
        return result
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var width: CGFloat? = nil

    var body: some View {
        NavigationLink(value: Route.playlist(playlist.id)) {
            VStack(alignment: .leading, spacing: 6) {
                PlaylistCover(playlist: playlist)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(.tuneSubtitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("곡 \(playlist.entries.count)개")
                        .font(.tuneCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 버튼 · 제목

/// Apple Music 방식의 [재생] [셔플] 캡슐 버튼 두 개
struct PlayShuffleButtons: View {
    var tint: Color = .tuneAccent
    var background: AnyShapeStyle = AnyShapeStyle(Color(.secondarySystemFill))
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button(action: onPlay) {
                Label("재생", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            Button(action: onShuffle) {
                Label("셔플", systemImage: "shuffle")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
        .buttonStyle(CapsuleFillStyle(background: background))
    }
}

struct CapsuleFillStyle: ButtonStyle {
    var background: AnyShapeStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

struct SectionHeader<Destination: Hashable>: View {
    let title: String
    var destination: Destination?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: 4) {
                        Text(title).font(.tuneSection).foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.tuneSection)
            }
            Spacer()
        }
    }
}

extension SectionHeader where Destination == Route {
    init(_ title: String, destination: Route? = nil) {
        self.title = title
        self.destination = destination
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? AnyShapeStyle(Color.tuneAccent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

struct LosslessBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform")
            Text("무손실")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
        .foregroundStyle(.secondary)
    }
}

struct EmptyLibraryView: View {
    @State private var showImporter = false
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ContentUnavailableView {
            Label("아직 음악이 없어요", systemImage: "music.note")
        } description: {
            Text("파일 앱에서 음악 파일이나 폴더를 가져오거나,\n파일 앱의 '나의 iPhone > Tune' 폴더에 넣어 주세요.")
        } actions: {
            Button("음악 가져오기") { showImporter = true }
                .buttonStyle(.borderedProminent)
            OpenMusicFolderButton()
        }
        .musicImporter(isPresented: $showImporter)
    }
}

extension View {
    /// 파일 앱에서 음악 파일·폴더를 고르는 창
    func musicImporter(isPresented: Binding<Bool>) -> some View {
        modifier(MusicImporterModifier(isPresented: isPresented))
    }
}

private struct MusicImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.audio, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await importer.importPicked(urls, context: modelContext) }
            case .failure(let error):
                importer.reportPickerError(error)
            }
        }
    }
}

/// 파일 앱에서 이 앱의 음악 폴더를 바로 연다. 여기에 넣은 파일은 앱을 열 때 자동으로 추가된다.
struct OpenMusicFolderButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("파일 앱에서 음악 폴더 열기") {
            // 폴더가 비어 있으면 파일 앱에 안 보일 수 있어서 안내 파일을 하나 둔다.
            let guide = LibraryPaths.documents.appendingPathComponent("여기에 음악을 넣으세요.txt")
            if !FileManager.default.fileExists(atPath: guide.path) {
                try? "이 폴더에 mp3 · m4a · flac · wav 파일이나 폴더를 넣고 Tune을 다시 열면 보관함에 추가돼요.".write(to: guide, atomically: true, encoding: .utf8)
            }
            if let url = URL(string: "shareddocuments://" + LibraryPaths.documents.path) {
                openURL(url)
            }
        }
    }
}


/// "아티스트로 이동" 하위 메뉴: 곡에 적힌 가수마다 버튼 하나
private struct ArtistChoiceButtons: View {
    let track: Track
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ForEach(ArtistLookup.artists(for: track, context: modelContext)) { artist in
            Button(artist.name) {
                router.showPlayer = false
                router.open(.artist(artist.id))
            }
        }
    }
}
