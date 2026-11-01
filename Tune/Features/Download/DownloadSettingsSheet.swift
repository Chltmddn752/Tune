import SwiftUI

/// 다운로드 기본값과 저장 위치를 정하는 시트.
struct DownloadSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ExtensionStore.self) private var store

    var body: some View {
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
                    LabeledContent("저장 위치", value: "Tune/다운로드")
                    OpenMusicFolderButton()
                } footer: {
                    Text("받은 파일은 보관함에 자동으로 들어와요.")
                }

                Section {
                    NavigationLink {
                        ExtensionStoreView()
                    } label: {
                        Label("음원 확장 관리", systemImage: "puzzlepiece.extension")
                    }
                }
            }
            .navigationTitle("다운로드 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
