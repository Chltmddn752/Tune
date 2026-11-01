import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 다운로드 기본값과 저장 위치를 정하는 시트.
struct DownloadSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ExtensionStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @State private var settings = DownloadSettings.shared
    @State private var links = LinkedFolders.shared

    // 위치는 "이 위치 사용"을 눌렀을 때만 적용한다(기존 파일을 옮길지 물어보기 위해).
    @State private var draftUseLinked = false
    @State private var draftSubfolder = "다운로드"
    @State private var draftLinkedID: String?
    @State private var showFolderPicker = false
    @State private var pickerError: String?
    @State private var moveTargets: [Track] = []
    @State private var showMoveDialog = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    if store.installed.isEmpty {
                        Text("설치한 확장이 없어요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.installed) { installed in
                            qualityPicker(for: installed)
                        }
                    }
                } header: {
                    Text("기본 음질")
                } footer: {
                    Text("검색 결과에서 ↓를 누르면 이 음질로 받아요. 다른 음질은 길게 눌러 고를 수 있어요.")
                }

                Section {
                    Picker("저장 위치", selection: $draftUseLinked) {
                        Text("Tune 폴더").tag(false)
                        Text("다른 폴더").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if draftUseLinked {
                        if links.folders.isEmpty {
                            Text("연결한 폴더가 없어요. 파일 앱에서 폴더를 골라 주세요.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("폴더", selection: Binding(
                                get: { draftLinkedID ?? "" },
                                set: { draftLinkedID = $0.isEmpty ? nil : $0 }
                            )) {
                                Text("고르기").tag("")
                                ForEach(links.folders) { folder in
                                    Text(folder.name).tag(folder.id)
                                }
                            }
                        }
                        Button {
                            showFolderPicker = true
                        } label: {
                            Label("파일 앱에서 폴더 고르기", systemImage: "folder.badge.plus")
                        }
                        if draftLinkedID == nil {
                            Text("폴더를 고르기 전에는 Tune 폴더에 받아요.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("하위 폴더 이름", text: $draftSubfolder)
                            .textInputAutocapitalization(.never)
                    }

                    Button("이 위치 사용") { applyLocation() }
                        .disabled(!locationChanged)

                    LabeledContent("지금 저장 위치", value: settings.displayPath)
                } header: {
                    Text("저장 위치")
                } footer: {
                    Text("고른 폴더에 접근할 수 없게 되면 다운로드를 멈추지 않고 Tune 폴더에 받은 뒤 알려 드려요. 보안을 위해 확장은 스테이징 폴더까지만 쓰고, 최종 위치로 옮기는 건 앱이 해요.")
                }

                Section {
                    Picker("폴더 구조", selection: $settings.structure) {
                        ForEach(DownloadFolderStructure.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("파일 이름", selection: $settings.fileNamePattern) {
                        ForEach(DownloadFileNamePattern.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("폴더 · 이름")
                } footer: {
                    Text("새로 받는 파일에 적용돼요. 같은 이름이 있으면 (2)를 붙여요.")
                }

                Section {
                    NavigationLink {
                        ExtensionStoreView()
                    } label: {
                        Label("음원 확장 관리", systemImage: "puzzlepiece.extension")
                    }
                    OpenMusicFolderButton()
                }
            }
            .navigationTitle("다운로드 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .onAppear(perform: loadDrafts)
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        let folder = try LinkedFolders.shared.add(url)
                        draftLinkedID = folder.id
                        draftUseLinked = true
                    } catch {
                        pickerError = error.localizedDescription
                    }
                case .failure(let error):
                    pickerError = error.localizedDescription
                }
            }
            .alert("폴더를 연결하지 못했어요", isPresented: Binding(
                get: { pickerError != nil }, set: { if !$0 { pickerError = nil } }
            )) {
                Button("확인", role: .cancel) { pickerError = nil }
            } message: {
                Text(pickerError ?? "")
            }
            .confirmationDialog("기존에 받은 파일도 새 위치로 옮길까요?",
                                isPresented: $showMoveDialog, titleVisibility: .visible) {
                Button("옮기기") {
                    let targets = moveTargets
                    moveTargets = []
                    Task { await DownloadRelocator.move(targets, context: modelContext) }
                }
                Button("그대로 두기", role: .cancel) { moveTargets = [] }
            } message: {
                Text("파일 \(moveTargets.count)개를 새 위치로 옮기고 보관함 경로를 갱신해요. 재생 기록·플레이리스트·가사 설정은 그대로 유지돼요.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var locationChanged: Bool {
        if draftUseLinked != settings.useLinkedFolder { return true }
        if draftUseLinked { return draftLinkedID != settings.linkedFolderID }
        return draftSubfolder != settings.tuneSubfolder
    }

    private func loadDrafts() {
        draftUseLinked = settings.useLinkedFolder
        draftSubfolder = settings.tuneSubfolder
        draftLinkedID = settings.linkedFolderID
    }

    private func applyLocation() {
        let oldBase = settings.baseURL
        settings.useLinkedFolder = draftUseLinked
        settings.tuneSubfolder = draftSubfolder
        settings.linkedFolderID = draftLinkedID
        let newBase = settings.baseURL
        guard oldBase.standardizedFileURL.path != newBase.standardizedFileURL.path else { return }
        // 옮길 대상은 예전 다운로드 폴더 안의 곡만. 연결 폴더에서는 다운로드 기록이 있는 곡만 고른다.
        let targets = DownloadRelocator.downloadedTracks(under: oldBase, context: modelContext)
        guard !targets.isEmpty else { return }
        moveTargets = targets
        showMoveDialog = true
    }

    @ViewBuilder private func qualityPicker(for installed: InstalledExtension) -> some View {
        if installed.manifest.qualityOptions.isEmpty {
            LabeledContent(installed.title, value: "확장 기본값")
        } else {
            Picker(installed.title, selection: Binding(
                get: { store.defaultQuality(for: installed) },
                set: { store.setDefaultQuality($0, for: installed) }
            )) {
                ForEach(installed.manifest.qualityOptions) { quality in
                    Text(quality.label).tag(quality.id)
                }
            }
        }
    }
}
