import UniformTypeIdentifiers
import SwiftData
import SwiftUI

/// 설정 탭 (SpatialFlow 방식): 첫 화면은 카테고리 목록, 누르면 붙은 카드 묶음으로 된 세부 화면.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LibraryImporter.self) private var importer
    @Environment(DownloadManager.self) private var downloads
    @Environment(ExtensionStore.self) private var extensionStore
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ActivityCenter.self) private var activities
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    @AppStorage(SettingsKey.theme) private var theme: ThemeOption = .system
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .pink
    @AppStorage(SettingsKey.autoplay) private var autoplay = true
    @AppStorage(SettingsKey.onlineLyrics) private var onlineLyrics = true
    @AppStorage(SettingsKey.musixmatchLyrics) private var musixmatchLyrics = true
    @State private var lyricsRefetchScope: LyricsRefetch.Scope?
    @AppStorage(SettingsKey.estimateWordTiming) private var estimateWordTiming = true
    @AppStorage(SettingsKey.lyricsBlur) private var lyricsBlur = true
    @AppStorage(SettingsKey.lyricsSize) private var lyricsSize: LyricsSize = .medium
    @AppStorage(SettingsKey.lyricsOffset) private var lyricsOffset = 0.0
    @AppStorage(SettingsKey.lyricsLatencyCompensation) private var lyricsLatencyCompensation = false
    @AppStorage(SettingsKey.artistPhotos) private var artistPhotos = true
    @AppStorage(SettingsKey.progressToasts) private var progressToasts = true
    @AppStorage(SettingsKey.recentSearches) private var recentSearches = ""
    @AppStorage(SettingsKey.appIcon) private var appIcon: AppIconOption = .pink
    @AppStorage(M3SettingsKey.dynamicColors) private var dynamicColors = true
    @AppStorage(M3SettingsKey.amoled) private var amoled = false
    @AppStorage(M3SettingsKey.hideNavLabels) private var hideNavLabels = false
    @AppStorage(M3SettingsKey.dynamicNavStyle) private var dynamicNavStyle = false
    @AppStorage(M3SettingsKey.userName) private var userName = ""

    @State private var musicSize: Int64 = 0
    @State private var artworkSize: Int64 = 0
    @State private var trackCount = 0
    @State private var duplicateGroupCount = 0
    @State private var showImporter = false
    /// 파일 고르는 창은 한 화면에 하나만 붙여야 열린다(두 개를 겹쳐 붙이면 안쪽 것은 무시된다).
    @State private var pickerMode: PickerMode = .music
    @State private var csvResult: CSVPlaylistResult?
    @State private var csvError: String?
    @State private var filler = MetadataFiller.shared
    @State private var tagger = LibraryTagger.shared
    @State private var downloadSettings = DownloadSettings.shared

    private enum PickerMode { case music, folder, csv }
    @State private var confirmClearHistory = false
    @State private var confirmTagRewrite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                M3TabHeader("설정")
                    .padding(.top, Spacing.s)
                    .padding(.bottom, Spacing.m)

                M3Group(outer: 32) {
                    category("모양", "테마, 동적 색, 앱 아이콘, 하단바", "paintpalette") { appearancePage }
                    category("재생", "자동 재생, 수면 타이머", "play.circle") { playbackPage }
                    category("가사", "온라인 가사, 단어 효과, 싱크 보정", "quote.bubble") { lyricsPage }
                    category("보관함", "음악 가져오기, 연결한 폴더, 저장 공간", "square.stack") { libraryPage }
                    category("가져오기 · 정리", "CSV 플레이리스트, 중복, 태그 정리", "wand.and.stars") { tidyPage }
                    category("다운로드", "음원 확장, 기본 음질, 저장 위치", "arrow.down.circle") { downloadPage }
                    category("알림 · 기록", "진행 안내, 검색어·재생 기록", "bell") { historyPage }
                    category("정보", "버전, 위젯 연결, 가사 싱크 진단", "info.circle") { aboutPage }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .m3HidesNavOnScroll()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            refreshSizes()
            duplicateGroupCount = await DuplicateFinder.groupCount(context: modelContext)
        }
    }

    private func category<Page: View>(_ title: String, _ subtitle: String, _ systemImage: String,
                                      @ViewBuilder page: @escaping () -> Page) -> some View {
        NavigationLink {
            page()
        } label: {
            M3CategoryRow(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    /// 세부 화면 공통 틀
    private func page<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }

    private func actionRow(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
                           role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            M3Row(title: title, subtitle: subtitle, systemImage: systemImage) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.m3OnSurfaceVariant.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }

    private func linkRow<Destination: View>(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
                                            badge: String? = nil,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            M3Row(title: title, subtitle: subtitle, systemImage: systemImage) {
                HStack(spacing: 6) {
                    if let badge {
                        Text(badge)
                            .font(.m3LabelLarge.weight(.semibold))
                            .foregroundStyle(Color.m3Primary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.m3OnSurfaceVariant.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func valueRow(_ title: String, value: String, systemImage: String? = nil) -> some View {
        M3Row(title: title, systemImage: systemImage) {
            Text(value)
                .font(.m3BodyMedium)
                .foregroundStyle(Color.m3OnSurfaceVariant)
                .multilineTextAlignment(.trailing)
        }
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            M3Row(title, subtitle: subtitle, systemImage: systemImage)
        }
        .toggleStyle(M3ToggleStyle())
    }

    private func chipPicker<Item: Hashable & Identifiable>(_ items: [Item], selection: Binding<Item>,
                                                           label: @escaping (Item) -> String) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    M3FilterChip(title: label(item), isSelected: selection.wrappedValue == item) {
                        selection.wrappedValue = item
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: 모양

    private var appearancePage: some View {
        page("모양") {
            M3SectionTitle(title: "테마")
            M3Group {
                VStack(alignment: .leading, spacing: 12) {
                    M3Row("화면 모드", systemImage: "circle.lefthalf.filled")
                    chipPicker(ThemeOption.allCases, selection: $theme) { $0.label }
                }
                toggleRow("동적 색", subtitle: "지금 재생 중인 곡의 커버에서 앱 색을 뽑아요",
                          systemImage: "drop.halffull", isOn: $dynamicColors)
                toggleRow("완전한 검정 배경", subtitle: "다크 모드에서 배경을 순수한 검정으로 (OLED 절전)",
                          systemImage: "moon.circle", isOn: $amoled)
                VStack(alignment: .leading, spacing: 12) {
                    M3Row("포인트색", subtitle: dynamicColors ? "재생 중이 아닐 때 쓰는 색이에요" : nil, systemImage: "paintbrush")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: Spacing.m) {
                        ForEach(AccentOption.allCases) { option in
                            Button { accent = option } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if accent == option {
                                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        Circle().strokeBorder(Color.m3OnSurface.opacity(accent == option ? 0.6 : 0), lineWidth: 2)
                                            .padding(-4)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.label)
                            .accessibilityAddTraits(accent == option ? .isSelected : [])
                        }
                    }
                }
            }

            M3SectionTitle(title: "앱 아이콘")
            M3Group {
                // 아이콘이 많아져서 한 줄에 다 들어가지 않으면 칸을 내려 보여 준다.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Spacing.l)], spacing: Spacing.l) {
                    ForEach(AppIconOption.allCases) { option in
                        Button {
                            appIcon = option
                            UIApplication.shared.setAlternateIconName(option.iconName)
                        } label: {
                            VStack(spacing: 6) {
                                Image(uiImage: UIImage(named: option.previewName) ?? UIImage())
                                    .resizable()
                                    .frame(width: 60, height: 60)
                                    .background(Color.m3SurfaceContainerHighest)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(appIcon == option ? Color.m3Primary : .clear, lineWidth: 3)
                                            .padding(-4)
                                    }
                                Text(option.label)
                                    .font(.m3LabelMedium)
                                    .foregroundStyle(appIcon == option ? Color.m3Primary : Color.m3OnSurfaceVariant)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(appIcon == option ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            M3SectionTitle(title: "하단바")
            M3Group {
                toggleRow("하단바 글자 숨기기", subtitle: "아래 내비게이션 바에서 글자를 빼요",
                          systemImage: "textformat.size.smaller", isOn: $hideNavLabels)
                toggleRow("동적 하단바", subtitle: "낮은 높이에 굵고 큰 아이콘",
                          systemImage: "rectangle.bottomthird.inset.filled", isOn: $dynamicNavStyle)
            }

            M3SectionTitle(title: "홈")
            M3Group {
                VStack(alignment: .leading, spacing: 10) {
                    M3Row("인사말 이름", subtitle: "홈 맨 위 \"좋은 저녁이에요\" 아래에 크게 보여요", systemImage: "person.crop.circle")
                    TextField("리스너", text: $userName)
                        .font(.m3BodyLarge)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(Color.m3SurfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .submitLabel(.done)
                }
            }
        }
    }

    // MARK: 재생

    private var playbackPage: some View {
        page("재생") {
            M3SectionTitle(title: "재생")
            M3Group {
                toggleRow("자동 재생", subtitle: "대기열이 끝나면 같은 아티스트나 장르의 곡을 이어서 틀어요",
                          systemImage: "infinity", isOn: $autoplay)
            }
            M3SectionTitle(title: "수면 타이머")
            M3Group {
                M3Row(title: sleepStatus, subtitle: "재생 화면의 '수면 타이머' 칩이나 대기열 아래 버튼으로도 켤 수 있어요",
                      systemImage: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz") {
                    if player.isSleepTimerActive {
                        Button("끄기") { player.cancelSleepTimer() }
                            .font(.m3LabelLarge.weight(.bold))
                            .foregroundStyle(Color.m3Primary)
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                            M3FilterChip(title: "\(minutes)분", isSelected: false) {
                                player.setSleepTimer(minutes: minutes)
                            }
                        }
                        M3FilterChip(title: "이 곡이 끝나면", isSelected: player.sleepAtTrackEnd) {
                            player.setSleepAtTrackEnd()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var sleepStatus: String {
        if let end = player.sleepTimerEnd {
            let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
            return "\(minutes)분 뒤에 멈춰요"
        }
        return player.sleepAtTrackEnd ? "이 곡이 끝나면 멈춰요" : "꺼짐"
    }

    // MARK: 가사

    private var lyricsPage: some View {
        page("가사") {
            M3SectionTitle(title: "가사")
            M3Group {
                toggleRow("인터넷에서 가사 찾기", subtitle: "곡 길이가 맞는 시간 맞춘 가사를 받아요",
                          systemImage: "globe", isOn: $onlineLyrics)
                toggleRow("Musixmatch에서 먼저 찾기", subtitle: "Spotify·Apple Music과 같은 가사, 단어 싱크가 있으면 그걸로. 없으면 LRCLIB",
                          systemImage: "music.quarternote.3", isOn: $musixmatchLyrics)
                toggleRow("단어별 효과 어림잡기", subtitle: "단어 시간이 없는 가사도 글자 수로 나눠 노래방처럼 칠해요",
                          systemImage: "character.cursor.ibeam", isOn: $estimateWordTiming)
                toggleRow("가사 흐림 효과", subtitle: "지금 줄에서 멀수록 흐리게", systemImage: "aqi.medium", isOn: $lyricsBlur)
                VStack(alignment: .leading, spacing: 12) {
                    M3Row("가사 글자 크기", systemImage: "textformat.size")
                    chipPicker(LyricsSize.allCases, selection: $lyricsSize) { $0.label }
                }
            }
            M3SectionTitle(title: "싱크 보정")
            M3Group {
                VStack(alignment: .leading, spacing: 8) {
                    M3Row(title: "전체 가사 보정", systemImage: "timer") {
                        Text(String(format: "%+.2f초", lyricsOffset))
                            .font(.m3BodyMedium.monospacedDigit())
                            .foregroundStyle(Color.m3Primary)
                    }
                    HStack(spacing: Spacing.s) {
                        Text("-1초").font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant)
                        Slider(value: $lyricsOffset, in: -1...1, step: 0.05)
                        Text("+1초").font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant)
                    }
                }
                toggleRow("블루투스 출력 지연 보정", systemImage: "airpods", isOn: $lyricsLatencyCompensation)
            }
            M3Footnote(text: "가사는 곡 옆의 .lrc · .ttml 파일, 저장해 둔 가사, 파일 안 가사, 인터넷(Musixmatch → LRCLIB) 순서로 찾아요. 가사가 조금 늦으면 '전체 가사 보정'을 +쪽으로 올려 보세요. 가사 화면에서 지금 부르는 줄을 누르면 그 줄에 맞춰 곡별로 보정해요.")

            M3SectionTitle(title: "받아 둔 가사 바꾸기")
            M3Group {
                ForEach(LyricsRefetch.Scope.allCases) { scope in
                    actionRow(scope.title, subtitle: scope == .all ? "곡 옆 가사 파일이 있는 곡은 빼요" : nil,
                              systemImage: scope == .all ? "arrow.triangle.2.circlepath" : "quote.bubble") {
                        lyricsRefetchScope = scope
                    }
                }
            }
            M3Footnote(text: "Musixmatch에서 곡 길이가 맞는 가사를 다시 받아 바꿔요. 시간 맞춘 가사를 시간 없는 가사로 바꾸지는 않아요. 앨범·플레이리스트의 ⋯ 메뉴나 곡을 길게 눌러 일부만 바꿀 수도 있어요. 곡이 많으면 오래 걸리고, 진행 상황은 알림에서 볼 수 있어요.")
            .confirmationDialog(
                lyricsRefetchConfirmTitle,
                isPresented: Binding(get: { lyricsRefetchScope != nil }, set: { if !$0 { lyricsRefetchScope = nil } }),
                titleVisibility: .visible
            ) {
                if let scope = lyricsRefetchScope {
                    Button("바꾸기") {
                        let tracks = LyricsRefetch.tracks(for: scope, context: modelContext)
                        if tracks.isEmpty {
                            toasts.show("바꿀 곡이 없어요")
                        } else if !LyricsRefetch.run(tracks, title: "가사 바꾸기", context: modelContext) {
                            toasts.show("이미 가사를 바꾸는 중이에요")
                        }
                    }
                }
                Button("취소", role: .cancel) {}
            }
        }
    }

    private var lyricsRefetchConfirmTitle: String {
        guard let scope = lyricsRefetchScope else { return "" }
        let count = LyricsRefetch.tracks(for: scope, context: modelContext).count
        return "\(count)곡의 가사를 Musixmatch 가사로 바꿀까요?"
    }

    // MARK: 보관함

    private var libraryPage: some View {
        page("보관함") {
            M3SectionTitle(title: "음악")
            M3Group {
                actionRow("음악 가져오기", subtitle: "파일 앱에서 음악 파일이나 폴더를 골라요", systemImage: "square.and.arrow.down") {
                    pickerMode = .music
                    showImporter = true
                }
                OpenMusicFolderButton()
                    .font(.m3BodyLarge)
                actionRow("파일 앱 폴더 다시 검사", systemImage: "arrow.clockwise") {
                    Task {
                        await importer.scanDocuments(context: modelContext)
                        refreshSizes()
                    }
                }
            }
            M3Footnote(text: "파일 앱의 '나의 iPhone(iPad) > Tune' 폴더에 음악을 넣어도 앱을 열 때 자동으로 추가돼요.")

            M3SectionTitle(title: "연결한 폴더")
            LinkedFoldersSection {
                pickerMode = .folder
                showImporter = true
            }

            M3SectionTitle(title: "아티스트 사진")
            M3Group {
                toggleRow("아티스트 사진 받기", subtitle: "Deezer에서 아티스트 사진을 받아요",
                          systemImage: "person.crop.circle", isOn: $artistPhotos)
                actionRow("아티스트 사진 모두 다시 받기", systemImage: "person.crop.circle.badge.arrow.clockwise") {
                    Task { await ArtistImageService.refreshAll(context: modelContext) }
                }
            }

            M3SectionTitle(title: "저장 공간")
            M3Group {
                valueRow("곡 수", value: "\(trackCount)곡", systemImage: "music.note")
                valueRow("음악 용량", value: Formatters.fileSize(musicSize), systemImage: "internaldrive")
                valueRow("커버 · 사진 용량", value: Formatters.fileSize(artworkSize), systemImage: "photo")
                actionRow("가사 저장분 지우기", systemImage: "trash") {
                    try? modelContext.delete(model: LyricsCache.self)
                    try? modelContext.save()
                }
            }

            if !importer.unplayableFiles.isEmpty {
                M3SectionTitle(title: "재생할 수 없어 건너뛴 파일 \(importer.unplayableFiles.count)개")
                M3Group {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(importer.unplayableFiles.enumerated()), id: \.offset) { _, name in
                            Text(name).font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant).lineLimit(2)
                        }
                    }
                    actionRow("목록 지우고 다시 검사", systemImage: "arrow.clockwise") {
                        importer.clearUnplayable()
                        Task { await importer.scanDocuments(context: modelContext) }
                    }
                }
                M3Footnote(text: "이 기기가 풀 수 없는 음성 형식(예: 일부 Dolby Atmos AC-4 파일)이에요. 같은 곡을 FLAC·ALAC·AAC로 받으면 들어와요.")
            }

            if !importer.skippedDuplicateFiles.isEmpty {
                M3SectionTitle(title: "중복이라 건너뛴 파일 \(importer.skippedDuplicateFiles.count)개")
                M3Group {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(importer.skippedDuplicateFiles) { skipped in
                            Text(skipped.name).font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant).lineLimit(2)
                        }
                    }
                    actionRow("목록 지우고 다시 검사", systemImage: "arrow.clockwise") {
                        importer.clearSkippedFiles()
                        Task { await importer.scanDocuments(context: modelContext) }
                    }
                }
                M3Footnote(text: "이미 보관함에 있는 곡과 제목·아티스트·길이가 같아 건너뛴 파일이에요.")
            }

            if !importer.unreadableFiles.isEmpty {
                M3SectionTitle(title: "읽지 못한 파일 \(importer.unreadableFiles.count)개")
                M3Group {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(importer.unreadableFiles) { skipped in
                            Text(skipped.name).font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant).lineLimit(2)
                        }
                    }
                    actionRow("목록 지우고 다시 검사", systemImage: "arrow.clockwise") {
                        importer.clearSkippedFiles()
                        Task { await importer.scanDocuments(context: modelContext) }
                    }
                }
                M3Footnote(text: "15초 안에 정보를 읽지 못해 건너뛴 파일이에요(클라우드에서 받는 중이거나 파일이 깨진 경우).")
            }
        }
        .modifier(PickerHost(showImporter: $showImporter, mode: pickerMode == .folder ? .folder : (pickerMode == .csv ? .csv : .music),
                             onResult: handlePicked))
        .task { refreshSizes() }
    }

    // MARK: 가져오기 · 정리

    private var tidyPage: some View {
        page("가져오기 · 정리") {
            M3SectionTitle(title: "가져오기")
            M3Group {
                actionRow("CSV 플레이리스트 가져오기", subtitle: "Exportify·Soundiiz에서 내보낸 목록을 내 곡으로 다시 만들어요",
                          systemImage: "tablecells") {
                    pickerMode = .csv
                    showImporter = true
                }
                linkRow("사고 싶은 곡", systemImage: "heart.text.square") { WishlistView() }
            }

            M3SectionTitle(title: "정리")
            M3Group {
                linkRow("아티스트 이름 정리 후보", systemImage: "text.badge.checkmark") { ArtistNameCleanupView() }
                linkRow("중복된 음악", systemImage: "square.on.square",
                        badge: duplicateGroupCount > 0 ? "\(duplicateGroupCount)그룹" : nil) { DuplicatesView() }
                if tagger.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView(value: Double(tagger.done), total: Double(max(tagger.total, 1)))
                            Text("\(tagger.done)/\(tagger.total)")
                                .font(.m3BodySmall.monospacedDigit())
                                .foregroundStyle(Color.m3OnSurfaceVariant)
                        }
                        if let title = tagger.currentTitle {
                            Text(title).font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant).lineLimit(1)
                        }
                        Button("멈추기") { tagger.cancel() }
                            .font(.m3LabelLarge.weight(.bold))
                    }
                } else {
                    actionRow("파일 태그 한 번에 정리", subtitle: "M4A·MP3·FLAC 파일에 Tune의 정보를 다시 써요", systemImage: "tag") {
                        confirmTagRewrite = true
                    }
                }
                if let message = tagger.lastResult {
                    Text(message).font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant)
                }
                if filler.isRunning {
                    HStack {
                        ProgressView(value: Double(filler.done), total: Double(max(filler.total, 1)))
                        Text("\(filler.done)/\(filler.total)").font(.m3BodySmall.monospacedDigit()).foregroundStyle(Color.m3OnSurfaceVariant)
                        Button("멈추기") { filler.cancel() }.buttonStyle(.borderless)
                    }
                } else {
                    actionRow("빠진 앨범 정보 채우기", subtitle: "연도·장르·커버가 없는 앨범을 iTunes 검색으로 채워요",
                              systemImage: "wand.and.stars") {
                        filler.start(context: modelContext)
                    }
                }
                if let message = filler.lastResult {
                    Text(message).font(.m3BodySmall).foregroundStyle(Color.m3OnSurfaceVariant)
                }
            }
            M3Footnote(text: "CSV: 없는 곡은 '사고 싶은 곡'에 담을 수 있어요. 파일 태그 정리는 Opus·WebM 등은 건너뛰어요.")
        }
        .modifier(PickerHost(showImporter: $showImporter, mode: pickerMode == .folder ? .folder : (pickerMode == .csv ? .csv : .music),
                             onResult: handlePicked))
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
        .sheet(item: $csvResult) { result in
            CSVImportResultView(result: result)
        }
        .alert("CSV를 가져오지 못했어요", isPresented: Binding(get: { csvError != nil }, set: { if !$0 { csvError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(csvError ?? "")
        }
        .task { duplicateGroupCount = await DuplicateFinder.groupCount(context: modelContext) }
    }

    // MARK: 다운로드

    private var downloadPage: some View {
        page("다운로드") {
            M3SectionTitle(title: "설치한 음원 확장")
            M3Group {
                if extensionStore.installed.isEmpty {
                    Text("설치한 음원 확장이 없어요.")
                        .font(.m3BodyMedium)
                        .foregroundStyle(Color.m3OnSurfaceVariant)
                } else {
                    ForEach(extensionStore.installed) { installed in
                        valueRow(installed.title, value: qualitySummary(for: installed), systemImage: "puzzlepiece")
                    }
                }
            }
            M3SectionTitle(title: "설정")
            M3Group {
                actionRow("기본 음질 · 저장 위치", systemImage: "slider.horizontal.3") {
                    coordinator.showSettingsSheet = true
                }
                linkRow("음원 확장 관리", systemImage: "puzzlepiece.extension") { ExtensionStoreView() }
                actionRow("다운로드 목록 보기", systemImage: "arrow.down.circle") {
                    router.openDownloads()
                }
                actionRow("받기 기록 지우기", systemImage: "trash") { downloads.clearFinished() }
                    .disabled(downloads.jobs.isEmpty)
            }
            M3Footnote(text: "받은 파일은 \(downloadSettings.displayPath)에 저장되고 보관함에 자동으로 들어와요.")
        }
    }

    // MARK: 알림 · 기록

    private var historyPage: some View {
        page("알림 · 기록") {
            M3SectionTitle(title: "알림")
            M3Group {
                linkRow("진행 중인 작업", systemImage: "hourglass",
                        badge: activities.hasRunning ? "\(activities.running.count)개 진행 중" : nil) { ActivityView() }
                toggleRow("진행 상황 안내 보기", subtitle: "꺼도 작업은 계속되고, 진행 중인 작업 화면에 기록이 남아요",
                          systemImage: "bell.badge", isOn: $progressToasts)
            }
            M3SectionTitle(title: "기록")
            M3Group {
                actionRow("최근 검색어 지우기", systemImage: "magnifyingglass") { recentSearches = "" }
                actionRow("재생 기록 지우기", subtitle: "통계와 '자주 듣는' 목록이 비워져요", systemImage: "clock.arrow.circlepath",
                          role: .destructive) {
                    confirmClearHistory = true
                }
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
    }

    // MARK: 정보

    private var aboutPage: some View {
        page("정보") {
            VStack(spacing: 10) {
                Image(uiImage: UIImage(named: appIcon.previewName) ?? UIImage())
                    .resizable()
                    .frame(width: 88, height: 88)
                    .background(Color.m3SurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                Text("Tune")
                    .font(.m3(28, .bold))
                    .foregroundStyle(Color.m3OnSurface)
                Text("버전 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                    .font(.m3BodyMedium)
                    .foregroundStyle(Color.m3OnSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            M3Group {
                valueRow("위젯 공유 폴더", value: AppGroup.isShared ? "연결됨" : "연결 안 됨", systemImage: "square.grid.2x2")
                if !AppGroup.isShared {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(AppGroup.candidates, id: \.self) { id in
                            Text(id).font(.caption.monospaced()).foregroundStyle(Color.m3OnSurfaceVariant).textSelection(.enabled)
                        }
                        Text("SideStore가 이 앱에 앱 그룹 권한을 넣지 못한 상태예요. SideStore에서 Tune을 지웠다가 다시 설치하면 대부분 해결돼요.")
                            .font(.m3BodySmall)
                            .foregroundStyle(Color.m3OnSurfaceVariant)
                    }
                }
                valueRow("가사", value: "LRCLIB (lrclib.net)", systemImage: "quote.bubble")
                valueRow("아티스트 사진", value: "Deezer API", systemImage: "person.crop.square")
                valueRow("디자인", value: "SpatialFlow의 Material 3 Expressive", systemImage: "paintpalette")
            }

            M3SectionTitle(title: "가사 싱크 진단")
            M3Group {
                valueRow("출력 경로", value: player.outputRouteDescription())
                valueRow("출력 지연", value: String(format: "%.0fms", player.outputLatency * 1000))
                valueRow("지연 보정", value: lyricsLatencyCompensation ? "켜짐" : "꺼짐")
                valueRow("전체 보정", value: String(format: "%+.2f초", lyricsOffset))
            }
        }
    }

    // MARK: 파일 고르기 결과

    private func handlePicked(_ result: Result<[URL], Error>) {
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

    private func qualitySummary(for installed: InstalledExtension) -> String {
        let id = extensionStore.defaultQuality(for: installed)
        return installed.manifest.qualityOptions.first { $0.id == id }?.label ?? "확장 기본값"
    }

    private func refreshSizes() {
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        trackCount = tracks.count
        musicSize = tracks.reduce(0) { $0 + $1.fileSize }
        artworkSize = ArtworkStore.directorySize()
    }
}

/// 파일 고르는 창 (세부 화면마다 붙인다: 가려진 화면에서는 창이 뜨지 않기 때문)
private struct PickerHost: ViewModifier {
    enum Mode { case music, folder, csv }
    @Binding var showImporter: Bool
    let mode: Mode
    let onResult: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: mode == .folder ? [.folder]
                : (mode == .csv ? [.commaSeparatedText, .tabSeparatedText, .plainText] : [.audio, .folder]),
            allowsMultipleSelection: mode == .music
        ) { result in
            onResult(result)
        }
    }
}

/// 설정 > 보관함 > 연결한 폴더: 고른 폴더에 파일이 생기면 보관함에 넣고, 없어지면 뺀다.
private struct LinkedFoldersSection: View {
    @Environment(LibraryImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext
    var onAdd: () -> Void
    @State private var links = LinkedFolders.shared
    @State private var unlinkTarget: LinkedFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            M3Group {
                ForEach(links.folders) { folder in
                    M3Row(title: folder.name,
                          subtitle: links.isReachable(folder.id)
                            ? "\(importer.trackCount(inLinkedFolder: folder.id, context: modelContext))곡"
                            : "지금은 열 수 없어요 · 곡은 그대로 둬요",
                          systemImage: links.isReachable(folder.id) ? "folder.fill" : "folder.badge.questionmark") {
                        Button {
                            unlinkTarget = folder
                        } label: {
                            Image(systemName: "link.badge.minus")
                                .foregroundStyle(Color.m3Error)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("연결 끊기")
                    }
                    .contextMenu {
                        Button("연결 끊기", systemImage: "link.badge.minus", role: .destructive) { unlinkTarget = folder }
                    }
                }
                Button(action: onAdd) {
                    M3Row("폴더 연결하기", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }
            M3Footnote(text: "고른 폴더에 음악 파일이 생기면 보관함에 자동으로 들어오고, 폴더에서 없어지면 보관함에서도 빠져요. 파일은 복사하지 않고 그 자리에서 재생해요.")
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
