import SwiftUI
import UniformTypeIdentifiers

/// 음원 확장이 없을 때 여는 시트. 스토어가 먼저 보이고, 레지스트리·파일 설치는 '고급'에 접어 둔다.
struct DownloadSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ExtensionStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(DownloadCoordinator.self) private var coordinator

    @State private var registryText = ""
    @State private var showAdvanced = false
    @State private var showFileImporter = false
    @State private var installingID: String?

    private var ready: Bool { store.compatibleInstallableExtensions.isEmpty == false }
    private var entries: [RegistryEntry] { store.registryEntries }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    header

                    if ready {
                        readyCard
                    } else {
                        steps
                        storeSection
                        advancedSection
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)
            }
            .background(Color(.systemBackground))
            .navigationTitle("음원 확장")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task {
                registryText = store.registryURL
                if store.registry == nil { await store.refreshRegistry() }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "sflx") ?? .data, .zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await store.installFromFile(url) }
                case .failure(let error):
                    store.installMessage = error.localizedDescription
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.tuneAccent)
            Text("음원을 받으려면 확장이 필요해요")
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("확장은 곡을 찾고 파일로 저장하는 작은 도구예요. 한 번만 설치하면 계속 써요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Label("준비됐어요", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.tuneAccent)
            Text("검색에서 곡을 찾아 ↓ 한 번만 누르면 받아요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                dismiss()
                router.openOnlineSearch()
            } label: {
                Text("곡 찾기")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.white)
                    .background(Color.tuneAccent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.xl)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            step(1, "음원 확장 설치")
            step(2, "필요하면 로그인")
            step(3, "곡 옆 ↓ 누르기")
        }
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: Spacing.m) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.tuneAccent, in: Circle())
            Text(title).font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var storeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("설치할 수 있는 확장").font(.headline)
                Spacer()
                if store.isLoadingRegistry {
                    ProgressView().controlSize(.small)
                }
            }

            if let error = store.registryError {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("확장 목록을 불러오지 못했어요")
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("다시 불러오기") {
                        Task { await store.refreshRegistry() }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            } else if entries.isEmpty {
                Text(store.isLoadingRegistry ? "확장 목록을 불러오는 중" : "설치할 수 있는 확장이 아직 없어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        extensionRow(entry)
                        if entry.id != entries.last?.id {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            }

            if let message = store.installMessage, !ready {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let first = entries.first(where: { store.installedExtension(id: $0.id) == nil }) {
                Button {
                    installingID = first.id
                    Task {
                        await store.install(first)
                        installingID = nil
                    }
                } label: {
                    Text(installingID == nil ? "확장 설치" : "설치하는 중")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.white)
                        .background(Color.tuneAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(installingID != nil)
            }

            Button("나중에") { dismiss() }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(.secondary)
        }
    }

    private func extensionRow(_ entry: RegistryEntry) -> some View {
        let installed = store.installedExtension(id: entry.id)
        return HStack(alignment: .center, spacing: Spacing.m) {
            AsyncImage(url: entry.iconURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Spacing.s)

            if installingID == entry.id || store.installingID == entry.id {
                ProgressView().controlSize(.small)
            } else if installed != nil {
                Text(store.isUpdateAvailable(entry) ? "업데이트" : "설치됨")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tuneAccent)
            } else {
                Button("설치") {
                    installingID = entry.id
                    Task {
                        await store.install(entry)
                        installingID = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.tuneAccent)
            }
        }
        .padding(Spacing.m)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Button {
                withAnimation(.smooth(duration: 0.28)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("고급")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    TextField("레지스트리 주소", text: $registryText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .padding(Spacing.m)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: Spacing.m) {
                        Button {
                            store.registryURL = registryText.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await store.refreshRegistry() }
                        } label: {
                            Label(store.isLoadingRegistry ? "불러오는 중" : "불러오기", systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote.weight(.medium))
                        }
                        .disabled(store.isLoadingRegistry)

                        Button {
                            showFileImporter = true
                        } label: {
                            Label("파일에서 설치", systemImage: "doc.badge.plus")
                                .font(.footnote.weight(.medium))
                        }
                    }
                    Text("확장은 기기 안에서만 실행돼요.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
