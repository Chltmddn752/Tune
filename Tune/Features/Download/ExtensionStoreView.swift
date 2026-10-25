import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ExtensionStoreView: View {
    @Environment(ExtensionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var registryText = ""
    @State private var showFileImporter = false
    @State private var pendingRemoval: InstalledExtension?

    var body: some View {
        List {
            if let message = store.installMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.contains("설치했어요") || message.contains("삭제했어요") ? Color.secondary : Color.red)
                }
            }

            Section {
                TextField("레지스트리 주소", text: $registryText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                Button {
                    store.registryURL = registryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await store.refreshRegistry() }
                } label: {
                    if store.isLoadingRegistry {
                        HStack { ProgressView(); Text("불러오는 중") }
                    } else {
                        Label("레지스트리 불러오기", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(store.isLoadingRegistry)
                Button {
                    showFileImporter = true
                } label: {
                    Label("파일에서 .sflx 설치", systemImage: "doc.badge.plus")
                }
            } header: {
                Text("확장 스토어")
            } footer: {
                Text("Mornye 확장(.sflx)을 그대로 설치해요. 확장은 JavaScriptCore에서 기기 안에서만 실행되고, 음원 파일은 보관함 폴더에 저장돼요.")
            }

            if let error = store.registryError {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            let entries = store.registryEntries
            if !entries.isEmpty {
                Section("받을 수 있는 확장 \(entries.count)개") {
                    ForEach(entries) { entry in
                        RegistryExtensionRow(entry: entry)
                    }
                }
            } else if !store.isLoadingRegistry && store.registryError == nil {
                Section {
                    Text("레지스트리에서 확장을 불러오면 여기에 보여요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.installed.isEmpty {
                    Text("설치한 확장이 없어요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.installed) { item in
                        NavigationLink {
                            ExtensionSettingsView(extensionID: item.id)
                        } label: {
                            InstalledExtensionRow(installed: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingRemoval = item
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("설치한 확장")
            } footer: {
                Text("확장마다 기본 음질과 설정을 따로 저장해요. 음원 이용 조건은 각 확장과 서비스 정책을 따라 주세요.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("다운로드 확장")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") { dismiss() }
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
        .alert("확장을 삭제할까요?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { item in
            Button("삭제", role: .destructive) {
                store.remove(item.id)
                pendingRemoval = nil
            }
            Button("취소", role: .cancel) { pendingRemoval = nil }
        } message: { item in
            Text("\(item.title)의 설정과 저장된 로그인이 함께 지워져요.")
        }
    }
}

private struct RegistryExtensionRow: View {
    let entry: RegistryEntry
    @Environment(ExtensionStore.self) private var store

    private var installed: InstalledExtension? { store.installedExtension(id: entry.id) }
    private var isInstalling: Bool { store.installingID == entry.id }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                    if installed != nil {
                        Text(store.isUpdateAvailable(entry) ? "업데이트" : "설치됨")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tuneAccent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.tuneAccent)
                    }
                }
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text("v\(entry.version)")
                    if let category = entry.category, !category.isEmpty {
                        Text("·")
                        Text(category)
                    }
                    if let minVersion = entry.minAppVersion, !minVersion.isEmpty {
                        Text("·")
                        Text("앱 \(minVersion)+")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Spacing.s)

            if isInstalling {
                ProgressView()
                    .frame(width: 44, height: 32)
            } else if let installed, !store.isUpdateAvailable(entry) {
                Image(systemName: installed.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(installed.enabled ? Color.tuneAccent : .secondary)
                    .frame(width: 44, height: 32)
                    .accessibilityLabel("설치됨")
            } else {
                Button(installed == nil ? "설치" : "업데이트") {
                    Task { await store.install(entry) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.tuneAccent)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct InstalledExtensionRow: View {
    let installed: InstalledExtension
    @Environment(ExtensionStore.self) private var store

    var body: some View {
        HStack(spacing: Spacing.m) {
            AsyncImage(url: installed.iconURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(installed.title).font(.body).lineLimit(1)
                Text("v\(installed.manifest.version) · \(typeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let blocked = installed.blockedReason {
                    Text(blocked).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else if !installed.enabled {
                    Text("사용 안 함").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Spacing.s)

            if installed.isCompatible && installed.enabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.tuneAccent)
                    .accessibilityHidden(true)
            }
        }
    }

    private var typeLabel: String {
        var labels: [String] = []
        if installed.manifest.isDownloadProvider { labels.append("다운로드") }
        if installed.manifest.isMetadataProvider { labels.append("정보") }
        if installed.manifest.isLyricsProvider { labels.append("가사") }
        return labels.isEmpty ? "확장" : labels.joined(separator: " · ")
    }
}

struct ExtensionSettingsView: View {
    let extensionID: String

    @Environment(ExtensionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var actionMessage: String?
    @State private var runningAction = false
    @State private var sessionAuthenticated = false
    @State private var sessionExpiresAt = ""
    @State private var sessionBusy = false
    @State private var sessionError: String?

    private var installed: InstalledExtension? { store.installedExtension(id: extensionID) }

    var body: some View {
        Form {
            if let installed {
                Section {
                    Toggle("사용", isOn: Binding(
                        get: { installed.enabled },
                        set: { store.setEnabled($0, for: extensionID) }
                    ))
                    LabeledContent("버전", value: installed.manifest.version)
                    LabeledContent("종류", value: installed.manifest.type.joined(separator: ", "))
                    if let blocked = installed.blockedReason {
                        Text(blocked).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("확장")
                } footer: {
                    Text(installed.manifest.description)
                }

                if installed.manifest.signedSession != nil {
                    signedSessionSection(installed)
                }

                if !installed.manifest.qualityOptions.isEmpty {
                    Section {
                        Picker("기본 음질", selection: Binding(
                            get: { store.defaultQuality(for: installed) },
                            set: { store.setDefaultQuality($0, for: installed) }
                        )) {
                            ForEach(installed.manifest.qualityOptions) { quality in
                                Text(quality.label).tag(quality.id)
                            }
                        }
                    } header: {
                        Text("음질")
                    } footer: {
                        if let selected = installed.manifest.qualityOptions.first(where: {
                            $0.id == store.defaultQuality(for: installed)
                        }), let description = selected.description {
                            Text(description)
                        } else {
                            Text("다운로드할 때 이 음질을 먼저 써요.")
                        }
                    }
                }

                if !installed.manifest.settings.isEmpty {
                    Section {
                        ForEach(installed.manifest.settings) { setting in
                            settingRow(setting, installed: installed)
                        }
                    } header: {
                        Text("확장 설정")
                    } footer: {
                        if let actionMessage {
                            Text(actionMessage)
                        } else {
                            Text("확장이 요구하는 설정이에요. 비밀 값은 기기 안에만 저장돼요.")
                        }
                    }
                }

                Section {
                    LabeledContent("보관함 폴더", value: "Tune/다운로드")
                    LabeledContent("출처", value: installed.registryURL ?? "직접 설치")
                } footer: {
                    Text("내려받은 곡은 보관함에 자동으로 추가되고, 파일 앱에서도 볼 수 있어요.")
                }

                Section {
                    Button("확장 삭제", role: .destructive) {
                        store.remove(extensionID)
                        dismiss()
                    }
                }
            } else {
                ContentUnavailableView("확장을 찾을 수 없어요", systemImage: "puzzlepiece.extension")
            }
        }
        .navigationTitle(installed?.title ?? "확장")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: extensionID) {
            if let installed { refreshSessionStatus(installed) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .signedSessionAuthenticated)) { note in
            guard let installed, note.object as? String == installed.id else { return }
            refreshSessionStatus(installed)
        }
    }

    @ViewBuilder
    private func signedSessionSection(_ installed: InstalledExtension) -> some View {
        Section {
            HStack {
                Text("서비스 인증")
                Spacer()
                Text(sessionAuthenticated ? "인증됨" : "인증 필요")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(sessionAuthenticated ? Color.tuneAccent : .secondary)
            }
            if sessionAuthenticated, !sessionExpiresAt.isEmpty {
                Text("만료 \(sessionExpiresAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sessionAuthenticated {
                Button("인증 다시 하기") {
                    beginVerification(installed, force: true)
                }
                .disabled(sessionBusy)
                Button("로그아웃", role: .destructive) {
                    clearSession(installed)
                }
                .disabled(sessionBusy)
            } else {
                Button {
                    beginVerification(installed, force: false)
                } label: {
                    HStack {
                        Text("인증하기")
                        Spacer()
                        if sessionBusy { ProgressView() }
                    }
                }
                .disabled(sessionBusy)
            }
            if let sessionError {
                Text(sessionError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("서비스 인증")
        } footer: {
            Text("Tidal·Qobuz·Deezer·Amazon Music처럼 Mornye 서명 세션이 필요한 확장은 서비스 인증을 한 번 마쳐야 다운로드할 수 있어요. 인증은 Safari 창에서 진행되고, 끝나면 앱으로 돌아와요.")
        }
    }

    private func refreshSessionStatus(_ installed: InstalledExtension) {
        guard let config = installed.manifest.signedSession else { return }
        let id = installed.id
        let root = store.directory(for: installed)
        Task.detached(priority: .utility) {
            let status = SignedSessionManager.shared.status(extensionID: id, config: config, root: root)
            await MainActor.run {
                sessionAuthenticated = status["authenticated"] as? Bool ?? false
                sessionExpiresAt = status["expires_at"] as? String ?? ""
            }
        }
    }

    private func beginVerification(_ installed: InstalledExtension, force: Bool) {
        guard let config = installed.manifest.signedSession else { return }
        let id = installed.id
        let root = store.directory(for: installed)
        sessionBusy = true
        sessionError = nil
        Task {
            if force {
                _ = await Task.detached(priority: .userInitiated) {
                    SignedSessionManager.shared.clear(extensionID: id, config: config, root: root)
                }.value
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    return .success(try SignedSessionManager.shared.verificationURL(
                        extensionID: id,
                        config: config,
                        root: root
                    ))
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                sessionBusy = false
                switch result {
                case .success(let url):
                    if url.isEmpty {
                        refreshSessionStatus(installed)
                    } else {
                        ExtensionVerificationCenter.shared.request(extensionID: id, authURL: url)
                    }
                case .failure(let error):
                    sessionError = error.localizedDescription
                }
            }
        }
    }

    private func clearSession(_ installed: InstalledExtension) {
        guard let config = installed.manifest.signedSession else { return }
        let id = installed.id
        let root = store.directory(for: installed)
        sessionBusy = true
        sessionError = nil
        Task {
            _ = await Task.detached(priority: .userInitiated) {
                SignedSessionManager.shared.clear(extensionID: id, config: config, root: root)
            }.value
            await MainActor.run {
                sessionBusy = false
                sessionAuthenticated = false
                sessionExpiresAt = ""
                refreshSessionStatus(installed)
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: ExtensionManifest.Setting, installed: InstalledExtension) -> some View {
        if setting.type == "button" {
            Button {
                guard let action = setting.action, !action.isEmpty else { return }
                runningAction = true
                actionMessage = nil
                Task {
                    let message = await store.performAction(action, for: installed)
                    actionMessage = message
                    runningAction = false
                }
            } label: {
                HStack {
                    Text(setting.label)
                    Spacer()
                    if runningAction { ProgressView() }
                }
            }
            .disabled(runningAction)
            if let description = setting.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        } else if setting.type == "select", let options = setting.options, !options.isEmpty {
            Picker(setting.label, selection: stringBinding(setting, installed: installed)) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        } else if setting.type == "bool" || setting.type == "boolean" || setting.type == "toggle" {
            Toggle(setting.label, isOn: boolBinding(setting, installed: installed))
        } else if setting.secret == true {
            SecureField(setting.label, text: stringBinding(setting, installed: installed))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else if setting.type == "number" || setting.type == "int" || setting.type == "integer" {
            TextField(setting.label, text: stringBinding(setting, installed: installed))
                .keyboardType(.decimalPad)
        } else {
            TextField(setting.label, text: stringBinding(setting, installed: installed))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        if let description = setting.description, setting.type != "button" {
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stringBinding(_ setting: ExtensionManifest.Setting, installed: InstalledExtension) -> Binding<String> {
        Binding(
            get: { store.settingValue(setting.key, for: installed)?.stringValue ?? "" },
            set: { value in
                if setting.type == "number" || setting.type == "int" || setting.type == "integer",
                   let number = Double(value) {
                    store.setSetting(setting.key, value: .number(number), for: installed)
                } else {
                    store.setSetting(setting.key, value: .string(value), for: installed)
                }
            }
        )
    }

    private func boolBinding(_ setting: ExtensionManifest.Setting, installed: InstalledExtension) -> Binding<Bool> {
        Binding(
            get: { store.settingValue(setting.key, for: installed)?.boolValue ?? false },
            set: { store.setSetting(setting.key, value: .bool($0), for: installed) }
        )
    }
}
