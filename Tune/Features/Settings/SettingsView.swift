import UniformTypeIdentifiers
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LibraryImporter.self) private var importer
    @Environment(DownloadManager.self) private var downloads

    @AppStorage(SettingsKey.theme) private var theme: ThemeOption = .system
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .pink
    @AppStorage(SettingsKey.autoplay) private var autoplay = true
    @AppStorage(SettingsKey.onlineLyrics) private var onlineLyrics = true
    @AppStorage(SettingsKey.estimateWordTiming) private var estimateWordTiming = true
    @AppStorage(SettingsKey.lyricsBlur) private var lyricsBlur = true
    @AppStorage(SettingsKey.lyricsSize) private var lyricsSize: LyricsSize = .medium
    @AppStorage(SettingsKey.artistPhotos) private var artistPhotos = true
    @AppStorage(SettingsKey.recentSearches) private var recentSearches = ""
    @AppStorage(SettingsKey.appIcon) private var appIcon: AppIconOption = .pink

    @State private var musicSize: Int64 = 0
    @State private var artworkSize: Int64 = 0
    @State private var trackCount = 0
    @State private var showImporter = false
    /// 파일 고르는 창은 한 화면에 하나만 붙여야 열린다(두 개를 겹쳐 붙이면 안쪽 것은 무시된다).
    @State private var pickerMode: PickerMode = .music
    @State private var csvResult: CSVPlaylistResult?
    @State private var csvError: String?
    @State private var filler = MetadataFiller.shared
    @State private var tagger = LibraryTagger.shared

    private enum PickerMode { case music, folder, csv }
    @State private var confirmClearHistory = false
    @State private var confirmTagRewrite = false

    var body: some View {
        NavigationStack {
            Form {
                Section("모양") {
                    Picker("화면 모드", selection: $theme) {
                        ForEach(ThemeOption.allCases) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("포인트색")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: Spacing.m) {
                            ForEach(AccentOption.allCases) { option in
                                Button { accent = option } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if accent == option {
                                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.label)
                                .accessibilityAddTraits(accent == option ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("앱 아이콘")
                        HStack(spacing: Spacing.l) {
                            ForEach(AppIconOption.allCases) { option in
                                Button {
                                    appIcon = option
                                    UIApplication.shared.setAlternateIconName(option.iconName)
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(uiImage: UIImage(named: option.previewName) ?? UIImage())
                                            .resizable()
                                            .frame(width: 60, height: 60)
                                            .background(Color(.systemGray5))
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .strokeBorder(appIcon == option ? Color.tuneAccent : .clear, lineWidth: 3)
                                            }
                                        Text(option.label).font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(appIcon == option ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle("자동 재생", isOn: $autoplay)
                } header: {
                    Text("재생")
                } footer: {
                    Text("대기열이 끝나면 같은 아티스트나 장르의 곡을 이어서 틀어요.")
                }

                Section {
                    Toggle("인터넷에서 가사 찾기", isOn: $onlineLyrics)
                    Toggle("단어별 효과 어림잡기", isOn: $estimateWordTiming)
                    Toggle("가사 흐림 효과", isOn: $lyricsBlur)
                    Picker("가사 글자 크기", selection: $lyricsSize) {
                        ForEach(LyricsSize.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("가사")
                } footer: {
                    Text("가사는 곡 옆의 .lrc · .ttml 파일, 파일 안 가사, LRCLIB 순서로 찾아요. 단어별 시간이 없는 가사는 줄 길이를 글자 수로 나눠 효과를 어림잡아요.")
                }

                Section {
                    Button("음악 가져오기") {
                        pickerMode = .music
                        showImporter = true
                    }
                    OpenMusicFolderButton()
                    Button("파일 앱 폴더 다시 검사") {
                        Task {
                            await importer.scanDocuments(context: modelContext)
                            refreshSizes()
                        }
                    }
                    Toggle("아티스트 사진 받기", isOn: $artistPhotos)
                    LabeledContent("곡 수", value: "\(trackCount)곡")
                    LabeledContent("음악 용량", value: Formatters.fileSize(musicSize))
                    LabeledContent("커버 · 사진 용량", value: Formatters.fileSize(artworkSize))
                    Button("가사 저장분 지우기") {
                        try? modelContext.delete(model: LyricsCache.self)
                        try? modelContext.save()
                    }
                } header: {
                    Text("보관함")
                } footer: {
                    Text("파일 앱의 '나의 iPhone(iPad) > Tune' 폴더에 음악을 넣어도 앱을 열 때 자동으로 추가돼요.")
                }

                Section {
                    Button {
                        pickerMode = .csv
                        showImporter = true
                    } label: {
                        Label("CSV 플레이리스트 가져오기", systemImage: "tablecells")
                    }
                    NavigationLink {
                        WishlistView()
                    } label: {
                        Label("사고 싶은 곡", systemImage: "heart.text.square")
                    }
                    if tagger.isRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView(value: Double(tagger.done), total: Double(max(tagger.total, 1)))
                                Text("\(tagger.done)/\(tagger.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let title = tagger.currentTitle {
                                Text(title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Button("멈추기") { tagger.cancel() }
                                .font(.footnote)
                        }
                    } else {
                        Button {
                            confirmTagRewrite = true
                        } label: {
                            Label("파일 태그 한 번에 정리", systemImage: "tag")
                        }
                    }
                    if let message = tagger.lastResult {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if filler.isRunning {
                        HStack {
                            ProgressView(value: Double(filler.done), total: Double(max(filler.total, 1)))
                            Text("\(filler.done)/\(filler.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("멈추기") { filler.cancel() }.buttonStyle(.borderless)
                        }
                    } else {
                        Button {
                            filler.start(context: modelContext)
                        } label: {
                            Label("빠진 앨범 정보 채우기", systemImage: "wand.and.stars")
                        }
                    }
                    if let message = filler.lastResult {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("가져오기 · 정리")
                } footer: {
                    Text("CSV: Exportify·Soundiiz 같은 곳에서 내보낸 플레이리스트를 내 보관함 곡으로 다시 만들어요. 없는 곡은 '사고 싶은 곡'에 담을 수 있어요.\n빠진 앨범 정보: 연도·장르·커버가 없는 앨범을 Apple iTunes 검색으로 채워요(음악 파일은 그대로).\n파일 태그 정리: M4A·MP3·FLAC 파일에 Tune의 제목·아티스트·앨범·커버를 다시 써요. Opus·WebM 등은 건너뛰어요.")
                }

                Section {
                    NavigationLink {
                        DownloadListView()
                    } label: {
                        Label("다운로드", systemImage: "arrow.down.circle")
                    }
                    NavigationLink {
                        ExtensionStoreView()
                    } label: {
                        Label("다운로드 확장", systemImage: "puzzlepiece.extension")
                    }
                    if let active = downloads.activeJob {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(active.title) · \(active.statusText)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            ProgressView(value: active.progress)
                        }
                    }
                } header: {
                    Text("다운로드")
                } footer: {
                    Text("Mornye .sflx 확장을 설치하면 검색의 '온라인'에서 곡을 찾아 내려받을 수 있어요. 받은 파일은 Tune/다운로드 폴더에 저장되고 보관함에 자동으로 들어와요.")
                }

                LinkedFoldersSection {
                    pickerMode = .folder
                    showImporter = true
                }

                if !importer.unplayableFiles.isEmpty {
                    Section {
                        DisclosureGroup("재생할 수 없어 건너뛴 파일 \(importer.unplayableFiles.count)개") {
                            ForEach(Array(importer.unplayableFiles.enumerated()), id: \.offset) { _, name in
                                Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Button("목록 지우고 다시 검사") {
                            importer.clearUnplayable()
                            Task { await importer.scanDocuments(context: modelContext) }
                        }
                    } footer: {
                        Text("이 기기가 풀 수 없는 음성 형식(예: 일부 Dolby Atmos AC-4 파일)이에요. 같은 곡을 FLAC·ALAC·AAC로 받으면 들어와요.")
                    }
                }

                Section("기록") {
                    Button("최근 검색어 지우기") { recentSearches = "" }
                    Button("재생 기록 지우기", role: .destructive) { confirmClearHistory = true }
                }

                Section("정보") {
                    LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    LabeledContent("위젯 공유 폴더", value: AppGroup.isShared ? "연결됨" : "연결 안 됨")
                    if !AppGroup.isShared {
                        DisclosureGroup("확인한 그룹 ID") {
                            ForEach(AppGroup.candidates, id: \.self) { id in
                                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text("SideStore가 이 앱에 앱 그룹 권한을 넣지 못한 상태예요. SideStore에서 Tune을 지웠다가 다시 설치하면 대부분 해결돼요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("가사: LRCLIB (lrclib.net) · 아티스트 사진: Deezer API")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: pickerMode == .folder ? [.folder]
                    : (pickerMode == .csv ? [.commaSeparatedText, .tabSeparatedText, .plainText] : [.audio, .folder]),
                allowsMultipleSelection: pickerMode == .music
            ) { result in
                switch result {
                case .success(let urls) where pickerMode == .csv:
                    guard let url = urls.first else { return }
                    do {
                        csvResult = try CSVPlaylistImporter.importFile(url, context: modelContext)
                    } catch {
                        csvError = error.localizedDescription
                    }
                case .success(let urls):
                    if pickerMode == .folder {
                        if let url = urls.first {
                            Task {
                                await importer.linkFolder(url, context: modelContext)
                                refreshSizes()
                            }
                        }
                    } else {
                        Task {
                            await importer.importPicked(urls, context: modelContext)
                            refreshSizes()
                        }
                    }
                case .failure(let error):
                    importer.reportPickerError(error)
                }
            }
            .confirmationDialog("재생 기록을 모두 지울까요?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("지우기", role: .destructive) {
                    try? modelContext.delete(model: PlayEvent.self)
                    try? modelContext.save()
                }
            } message: {
                Text("통계와 '자주 듣는' 목록이 비워져요.")
            }
            .confirmationDialog("파일 태그를 다시 쓸까요?", isPresented: $confirmTagRewrite, titleVisibility: .visible) {
                Button("태그 정리 시작") {
                    tagger.start(context: modelContext)
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("보관함의 모든 곡 파일에 Tune 정보를 다시 써요. M4A·MP3·FLAC만 지원하고, 클라우드에만 있는 곡과 지원하지 않는 형식은 건너뛰어요.")
            }
            .onChange(of: tagger.isRunning) { _, running in
                if !running { refreshSizes() }
            }
            .task { refreshSizes() }
            .sheet(item: $csvResult) { result in
                CSVImportResultView(result: result)
            }
            .alert("CSV를 가져오지 못했어요", isPresented: Binding(get: { csvError != nil }, set: { if !$0 { csvError = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(csvError ?? "")
            }
        }
    }

    private func refreshSizes() {
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        trackCount = tracks.count
        musicSize = tracks.reduce(0) { $0 + $1.fileSize }
        artworkSize = ArtworkStore.directorySize()
    }
}


/// 설정 > 연결한 폴더: 고른 폴더에 파일이 생기면 보관함에 넣고, 없어지면 뺀다.
private struct LinkedFoldersSection: View {
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext
    var onAdd: () -> Void
    @State private var links = LinkedFolders.shared
    @State private var unlinkTarget: LinkedFolder?

    var body: some View {
        Section {
            ForEach(links.folders) { folder in
                HStack(spacing: Spacing.m) {
                    Image(systemName: links.isReachable(folder.id) ? "folder.fill" : "folder.badge.questionmark")
                        .foregroundStyle(links.isReachable(folder.id) ? Color.tuneAccent : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).lineLimit(1)
                        Text(links.isReachable(folder.id)
                             ? "\(importer.trackCount(inLinkedFolder: folder.id, context: modelContext))곡"
                             : "지금은 열 수 없어요 · 곡은 그대로 둬요")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions {
                    Button("연결 끊기", role: .destructive) { unlinkTarget = folder }
                }
                .contextMenu {
                    Button("연결 끊기", systemImage: "link.badge.minus", role: .destructive) { unlinkTarget = folder }
                }
            }
            Button(action: onAdd) {
                Label("폴더 연결하기", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("연결한 폴더")
        } footer: {
            Text("고른 폴더(안의 폴더 포함)에 음악 파일이 생기면 보관함에 자동으로 들어오고, 폴더에서 없어지면 보관함에서도 빠져요. 파일은 복사하지 않고 그 자리에서 재생해요. 연결을 끊으면 그 폴더 곡만 보관함에서 빠지고 파일은 그대로예요.")
        }
        .confirmationDialog("'\(unlinkTarget?.name ?? "")' 연결을 끊을까요?",
                            isPresented: Binding(get: { unlinkTarget != nil }, set: { if !$0 { unlinkTarget = nil } }),
                            titleVisibility: .visible) {
            Button("연결 끊기", role: .destructive) {
                if let target = unlinkTarget { importer.unlinkFolder(target.id, context: modelContext) }
                unlinkTarget = nil
            }
        } message: {
            Text("이 폴더에서 들어온 곡이 보관함에서 빠져요. 파일은 지워지지 않아요.")
        }
    }
}


/// CSV 가져오기 결과: 맞춘 곡 수, 없는 곡 목록, 사고 싶은 곡에 담기
private struct CSVImportResultView: View {
    let result: CSVPlaylistResult
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var wishedCount: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("보관함에서 찾은 곡", value: "\(result.matched.count)곡")
                    LabeledContent("보관함에 없는 곡", value: "\(result.missing.count)곡")
                    if result.playlistID != nil {
                        Label("'\(result.playlistName)' 플레이리스트를 만들었어요", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.tuneAccent)
                    }
                }
                if !result.missing.isEmpty {
                    Section {
                        if let wishedCount {
                            Label("사고 싶은 곡에 \(wishedCount)곡을 담았어요", systemImage: "heart.text.square.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                wishedCount = CSVPlaylistImporter.addMissingToWishlist(result, context: modelContext)
                            } label: {
                                Label("없는 곡을 모두 사고 싶은 곡에 담기", systemImage: "heart.text.square")
                            }
                        }
                    }
                    Section("보관함에 없는 곡") {
                        ForEach(result.missing, id: \.self) { row in
                            Menu {
                                let item = CatalogItem(id: row.title + row.artist, title: row.title, artist: row.artist, album: row.album)
                                ForEach(CatalogLookup.storeLinks(for: item)) { store in
                                    Button { openURL(store.url) } label: { Label(store.label, systemImage: store.symbol) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).foregroundStyle(.primary)
                                    Text(row.artist).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("CSV 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
    }
}
