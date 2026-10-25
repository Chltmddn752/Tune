import PhotosUI
import SwiftData
import SwiftUI

struct PlaylistsListView: View {
    @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @State private var showNewAlert = false
    @State private var newName = ""

    var body: some View {
        let ordered = playlists.filter(\.isPinned) + playlists.filter { !$0.isPinned }
        List {
            AutoMixShelf()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.l, bottom: Spacing.m, trailing: 0))
            Button {
                newName = ""
                showNewAlert = true
            } label: {
                HStack(spacing: Spacing.m) {
                    RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 56, height: 56)
                        .overlay { Image(systemName: "plus").font(.title2).foregroundStyle(Color.tuneAccent) }
                    Text("새 플레이리스트").foregroundStyle(Color.tuneAccent)
                }
            }
            ForEach(ordered) { playlist in
                NavigationLink(value: Route.playlist(playlist.id)) {
                    HStack(spacing: Spacing.m) {
                        PlaylistCover(playlist: playlist).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if playlist.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.tuneAccent) }
                                Text(playlist.name).lineLimit(1)
                            }
                            Text("곡 \(playlist.entries.count)개").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button {
                        playlist.isPinned.toggle()
                        try? modelContext.save()
                    } label: { Label(playlist.isPinned ? "고정 해제" : "맨 위에 고정", systemImage: playlist.isPinned ? "pin.slash" : "pin") }
                    Button(role: .destructive) {
                        modelContext.delete(playlist)
                        try? modelContext.save()
                    } label: { Label("삭제", systemImage: "trash") }
                }
            }
            .onDelete { offsets in
                for i in offsets { modelContext.delete(ordered[i]) }
                try? modelContext.save()
            }
        }
        .listStyle(.plain)
        .navigationTitle("플레이리스트")
        .alert("새 플레이리스트", isPresented: $showNewAlert) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                let playlist = Playlist(name: newName.trimmingCharacters(in: .whitespaces).isEmpty ? "새 플레이리스트" : newName)
                modelContext.insert(playlist)
                try? modelContext.save()
                router.open(.playlist(playlist.id))
            }
        }
    }
}

struct PlaylistScreen: View {
    @Query private var playlists: [Playlist]

    init(playlistID: UUID) {
        _playlists = Query(filter: #Predicate<Playlist> { $0.id == playlistID })
    }

    var body: some View {
        if let playlist = playlists.first {
            PlaylistView(playlist: playlist)
        } else {
            ContentUnavailableView("플레이리스트를 찾을 수 없어요", systemImage: "music.note.list")
        }
    }
}

struct PlaylistView: View {
    @Bindable var playlist: Playlist

    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var allTracks: [Track]
    @State private var isEditing = false
    @State private var showPicker = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var newName = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false

    private var tracks: [Track] {
        let byID = Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.sortedEntries.compactMap { byID[$0.trackID] }
    }

    var body: some View {
        let current = tracks
        Group {
            if sizeClass == .regular && !isEditing {
                wide(current)
            } else {
                list(current)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isEditing ? "완료" : "편집") { withAnimation { isEditing.toggle() } }
                Menu {
                    Button { newName = playlist.name; showRename = true } label: { Label("이름 바꾸기", systemImage: "pencil") }
                    Button { showPhotoPicker = true } label: { Label("커버 사진 바꾸기", systemImage: "photo") }
                    if playlist.coverFile != nil {
                        Button { playlist.coverFile = nil; try? modelContext.save() } label: { Label("커버 사진 지우기", systemImage: "photo.badge.minus") }
                    }
                    Button { player.playNext(current) } label: { Label("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button(role: .destructive) { showDelete = true } label: { Label("플레이리스트 삭제", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .sheet(isPresented: $showPicker) {
            TrackPickerSheet(playlist: playlist)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let name = ArtworkStore.save(data) {
                    playlist.coverFile = name
                    try? modelContext.save()
                }
                photoItem = nil
            }
        }
        .alert("이름 바꾸기", isPresented: $showRename) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("저장") {
                playlist.name = newName
                playlist.updatedAt = .now
                try? modelContext.save()
            }
        }
        .confirmationDialog("이 플레이리스트를 삭제할까요?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                modelContext.delete(playlist)
                try? modelContext.save()
                dismiss()
            }
        } message: {
            Text("곡 파일은 지워지지 않아요.")
        }
    }

    // MARK: 아이패드: Apple Music 방식

    private var backgroundColor: Color {
        Color(hex: tracks.first?.album?.colorHex, fallback: Color(.systemBackground))
    }

    private var wideTextColor: Color {
        guard let hex = tracks.first?.album?.colorHex, let color = UIColor(hex: hex) else { return .primary }
        return color.isLight ? .black : .white
    }

    private func wide(_ current: [Track]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                CollectionHeaderWide(
                    title: playlist.name,
                    subtitle: "플레이리스트",
                    meta: "곡 \(current.count)개 · \(Formatters.longDuration(current.reduce(0) { $0 + $1.duration }))",
                    detail: playlist.detail,
                    textColor: wideTextColor,
                    onPlay: { player.play(current, context: .playlist(playlist.id)) },
                    onShuffle: { player.play(current, shuffled: true, context: .playlist(playlist.id)) }
                ) {
                    PlaylistCover(playlist: playlist)
                }

                VStack(spacing: 0) {
                    ForEach(Array(current.enumerated()), id: \.element.id) { index, track in
                        WideTrackRow(track: track, leading: .artwork, textColor: wideTextColor) {
                            player.play(current, startAt: index, context: .playlist(playlist.id))
                        }
                    }
                    Button { showPicker = true } label: {
                        Label("곡 추가", systemImage: "plus.circle.fill")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(wideTextColor)
                }
            }
            .padding(.horizontal, Spacing.xxxl)
            .padding(.top, Spacing.l)
            .padding(.bottom, 120)
        }
        .background(backgroundColor.ignoresSafeArea())
        .toolbarColorScheme(wideTextColor == .black ? .light : .dark, for: .navigationBar)
    }

    // MARK: 아이폰 · 편집 모드

    private func list(_ current: [Track]) -> some View {
        List {
            Section {
                VStack(spacing: Spacing.m) {
                    PlaylistCover(playlist: playlist)
                        .frame(width: sizeClass == .regular ? 300 : 240)
                        .shadow(color: .black.opacity(0.15), radius: 14, y: 8)
                    Text(playlist.name).font(.tuneSection).multilineTextAlignment(.center)
                    if !playlist.detail.isEmpty {
                        Text(playlist.detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Text("곡 \(current.count)개 · \(Formatters.longDuration(current.reduce(0) { $0 + $1.duration }))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !current.isEmpty {
                        PlayShuffleButtons {
                            player.play(current, context: .playlist(playlist.id))
                        } onShuffle: {
                            player.play(current, shuffled: true, context: .playlist(playlist.id))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .padding(.vertical, Spacing.m)
            }

            Section {
                ForEach(current) { track in
                    TrackRow(track: track, queue: current, context: .playlist(playlist.id))
                }
                .onMove(perform: move)
                .onDelete(perform: remove)

                Button {
                    showPicker = true
                } label: {
                    Label("곡 추가", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.tuneAccent)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    }

    private func move(from source: IndexSet, to destination: Int) {
        var entries = playlist.sortedEntries
        entries.move(fromOffsets: source, toOffset: destination)
        for (i, entry) in entries.enumerated() { entry.order = i }
        playlist.updatedAt = .now
        try? modelContext.save()
    }

    private func remove(at offsets: IndexSet) {
        let entries = playlist.sortedEntries
        for i in offsets where entries.indices.contains(i) { modelContext.delete(entries[i]) }
        playlist.updatedAt = .now
        try? modelContext.save()
    }
}

/// 보관함에서 곡을 골라 플레이리스트에 넣는 창
struct TrackPickerSheet: View {
    let playlist: Playlist
    @Query(sort: \Track.title) private var tracks: [Track]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered) { track in
                Button {
                    if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
                } label: {
                    HStack(spacing: Spacing.m) {
                        ArtworkView(file: track.artworkFile, cornerRadius: Radius.listArtwork).frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(track.title).lineLimit(1)
                            Text(track.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected.contains(track.id) ? Color.tuneAccent : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "보관함에서 찾기")
            .navigationTitle("곡 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가 (\(selected.count))") { add() }.disabled(selected.isEmpty)
                }
            }
        }
    }

    private var filtered: [Track] {
        guard !query.isEmpty else { return tracks }
        return tracks.filter { SearchMatcher.matches(query, $0.title) || SearchMatcher.matches(query, $0.artistName) || SearchMatcher.matches(query, $0.albumTitle) }
    }

    private func add() {
        var order = (playlist.entries.map(\.order).max() ?? -1) + 1
        for track in tracks where selected.contains(track.id) {
            let entry = PlaylistEntry(order: order, trackID: track.id)
            modelContext.insert(entry)
            entry.playlist = playlist
            order += 1
        }
        playlist.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}
