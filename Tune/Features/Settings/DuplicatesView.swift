import SwiftData
import SwiftUI

/// 설정 > 보관함 > 중복된 음악. 보관함 곡과 "중복이라 건너뛴" 디스크 파일을 함께 보여 준다.
struct DuplicatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var groups: [DuplicateGroup] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var showDeleteDialog = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("중복을 찾는 중")
            } else if groups.isEmpty {
                ContentUnavailableView("중복된 음악이 없어요", systemImage: "square.on.square",
                                       description: Text("제목·아티스트가 같고 길이가 2초 이내인 곡과, 중복이라 건너뛴 파일이 여기에 모여요."))
            } else {
                list
            }
        }
        .navigationTitle("중복된 음악")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selected = Set(groups.flatMap { group in
                            group.entries.filter { $0.id != group.recommendedEntryID }.map(\.id)
                        })
                    } label: {
                        Label("추천대로 모두 선택", systemImage: "checkmark.circle")
                    }
                    Button("선택 해제") { selected = [] }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !groups.isEmpty {
                GlassActionBar {
                    Text("\(selected.count)개 선택")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showDeleteDialog = true
                    } label: {
                        Text("정리하기")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .confirmationDialog("선택한 \(selected.count)개를 정리할까요?",
                            isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button("파일까지 삭제", role: .destructive) { performDelete(files: true) }
            Button("보관함에서만 빼기") { performDelete(files: false) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("연결 폴더의 파일은 원본이 지워져요. 남기는 곡으로 재생 기록·플레이리스트·좋아요·가사 설정을 옮겨요.")
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            Section {
                ForEach(groups) { group in
                    groupSection(group)
                }
            } footer: {
                Text("무손실 · 큰 파일 · 재생 횟수 순으로 남길 것을 추천해 미리 선택해 두었어요. '보관함에 없음'은 보관함에 들어오지 않고 디스크에만 남아 있는 중복 파일이에요.")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup) -> some View {
        Section {
            ForEach(group.entries) { entry in
                entryRow(entry, group: group)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.subheadline.weight(.semibold))
                Text(group.artist).font(.caption).foregroundStyle(.secondary)
            }
            .textCase(nil)
        }
    }

    private func entryRow(_ entry: DuplicateEntry, group: DuplicateGroup) -> some View {
        let isSelected = selected.contains(entry.id)
        let recommended = group.recommendedEntryID == entry.id
        return HStack(spacing: Spacing.m) {
            Button {
                toggle(entry.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.tuneAccent : Color.secondary)
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "선택 해제" : "선택")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            ArtworkView(file: entry.artworkFile, cornerRadius: Radius.listArtwork,
                        colorHex: entry.colorHex, title: entry.album)
                .frame(width: 44, height: 44)

            Button {
                preview(entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title).font(.tuneBody).lineLimit(1)
                        if recommended {
                            Text("추천").font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.tuneAccent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.tuneAccent)
                        }
                    }
                    Text("\(entry.artist) · \(entry.album)").font(.tuneCaption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(Formatters.time(entry.duration)).monospacedDigit()
                        Text(entry.fileFormat)
                        if entry.isLossless { Text("무손실") }
                        Text(Formatters.fileSize(entry.fileSize))
                        Text(entry.isOnDiskOnly ? "보관함에 없음" : entry.pathLabel)
                        if entry.playCount > 0 { Text("\(entry.playCount)회") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func preview(_ entry: DuplicateEntry) {
        if let trackID = entry.trackID {
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackID })
            descriptor.fetchLimit = 1
            if let track = (try? modelContext.fetch(descriptor))?.first {
                player.play([track])
            }
        } else if let diskPath = entry.diskPath {
            let item = QueueItem(previewFile: URL(fileURLWithPath: diskPath), title: entry.title,
                                 artist: entry.artist, album: entry.album,
                                 artworkFile: entry.artworkFile, duration: entry.duration)
            player.play(items: [item])
        }
    }

    private func performDelete(files: Bool) {
        let count = DuplicateFinder.delete(groups, selection: selected, deleteFiles: files, context: modelContext)
        ActivityCenter.shared.record("\(count)곡을 정리했어요", symbol: "square.on.square")
        selected = []
        Task { await load() }
    }

    private func load() async {
        isLoading = true
        let entries = DuplicateFinder.entries(context: modelContext)
        let computed = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.groups(from: entries)
        }.value
        groups = computed
        selected = Set(computed.flatMap { group in
            group.entries.filter { $0.id != group.recommendedEntryID }.map(\.id)
        })
        isLoading = false
    }
}
