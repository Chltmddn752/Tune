import SwiftUI

// MARK: - 다운로드 진행 링

struct DownloadProgressRing: View {
    var progress: Double
    var size: CGFloat = 26
    var showsPercent = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.tuneAccent.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.04, min(progress, 1)))
                .stroke(Color.tuneAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.35), value: progress)
            if showsPercent {
                Text("\(Int((progress * 100).rounded()))")
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 상태 칩

struct DownloadStatusChip: View {
    let status: DownloadStatus
    var detail: String? = nil

    private var symbol: String {
        switch status {
        case .queued: "clock"
        case .running: "arrow.down"
        case .completed: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark"
        }
    }

    private var text: String {
        if let detail, !detail.isEmpty { return detail }
        switch status {
        case .queued: return "대기 중"
        case .running: return "받는 중"
        case .completed: return "받음"
        case .failed: return "받지 못함"
        case .cancelled: return "취소됨"
        }
    }

    private var color: Color {
        switch status {
        case .failed: .red
        case .running, .completed: .tuneAccent
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.footnote)
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 다운로드 요청 중계

/// 행마다 시트를 띄우지 않고, 한 곳에서 받기 요청을 처리한다.
@MainActor
@Observable
final class DownloadCoordinator {
    struct MatchSheet: Identifiable {
        let id = UUID()
        var track: ProviderTrack
        var matches: [ProviderMatch]
    }

    var matchSheet: MatchSheet?
    var showSetupSheet = false
    var showSettingsSheet = false
    /// 정보 전용 확장에서 같은 곡을 찾는 중인 트랙 id
    var matchingTrackID: String?

    func requestDownload(
        track: ProviderTrack,
        store: ExtensionStore,
        downloads: DownloadManager,
        toasts: ToastCenter
    ) {
        guard let installed = store.installedExtension(id: track.providerID) else {
            showSetupSheet = true
            return
        }

        if installed.manifest.isDownloadProvider {
            let alreadyQueued = downloads.jobs.contains {
                $0.providerID == installed.id && $0.trackID == track.trackID && $0.isActive
            }
            downloads.enqueue(track: track, extension: installed)
            if alreadyQueued {
                toasts.show("이미 대기 중이에요.", symbol: "clock")
            } else {
                toasts.show("대기열에 넣었어요 · \(track.title)", symbol: "arrow.down.circle.fill")
            }
            return
        }

        guard matchingTrackID != track.id else { return }
        matchingTrackID = track.id
        Task { @MainActor in
            let found = await ProviderMatching.find(track: track, store: store)
            matchingTrackID = nil
            if found.isEmpty {
                if store.compatibleInstallableExtensions.isEmpty {
                    toasts.show("음원을 받으려면 확장이 필요해요", symbol: "exclamationmark.circle", actionTitle: "설치") {
                        self.showSetupSheet = true
                    }
                } else {
                    toasts.show("다른 확장에서 같은 곡을 찾지 못했어요", symbol: "exclamationmark.circle")
                }
                return
            }
            if found.count == 1, let match = found.first {
                let alreadyQueued = downloads.jobs.contains {
                    $0.providerID == match.installed.id && $0.trackID == match.track.trackID && $0.isActive
                }
                downloads.enqueue(track: match.track, extension: match.installed)
                toasts.show(
                    alreadyQueued ? "이미 대기 중이에요." : "대기열에 넣었어요 · \(track.title)",
                    symbol: alreadyQueued ? "clock" : "arrow.down.circle.fill"
                )
                return
            }
            matchSheet = MatchSheet(track: track, matches: found)
        }
    }
}

/// 한 곡을 받을 때 확장이 둘 이상이면 고르는 시트.
struct DownloadMatchSheet: View {
    let sheet: DownloadCoordinator.MatchSheet

    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadManager.self) private var downloads
    @Environment(ExtensionStore.self) private var store
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    HStack(spacing: Spacing.m) {
                        AsyncImage(url: sheet.track.coverURL.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: Radius.listArtwork)
                                .fill(Color(.tertiarySystemFill))
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(sheet.track.title)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(sheet.track.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text("어느 확장으로 받을까요?")
                        .font(.title3.weight(.semibold))

                    VStack(spacing: Spacing.m) {
                        ForEach(sheet.matches) { match in
                            Button {
                                enqueue(match)
                            } label: {
                                HStack(spacing: Spacing.m) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(match.installed.title)
                                            .font(.body.weight(.semibold))
                                        Text(qualityLabel(for: match.installed))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.tuneAccent)
                                }
                                .padding(Spacing.l)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .navigationTitle("받기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func qualityLabel(for installed: InstalledExtension) -> String {
        let id = store.defaultQuality(for: installed)
        let label = installed.manifest.qualityOptions.first { $0.id == id }?.label ?? "기본 음질"
        return "기본 음질 · \(label)"
    }

    private func enqueue(_ match: ProviderMatch) {
        downloads.enqueue(track: match.track, extension: match.installed)
        toasts.show("대기열에 넣었어요 · \(sheet.track.title)", symbol: "arrow.down.circle.fill")
        dismiss()
    }
}

// MARK: - 다운로드 버튼

/// 모든 화면에서 같은 동작을 하는 44×44 다운로드 버튼. 음질은 확장별 기본값을 쓴다.
struct DownloadButton: View {
    let track: ProviderTrack
    /// 행이 이미 계산해 둔 작업이 있으면 넘긴다.
    var job: DownloadJob? = nil

    @Environment(DownloadManager.self) private var downloads
    @Environment(ExtensionStore.self) private var store
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toast

    private var resolvedJob: DownloadJob? {
        job ?? downloads.jobs.first { $0.providerID == track.providerID && $0.trackID == track.trackID }
    }

    private var isMatching: Bool { coordinator.matchingTrackID == track.id }

    var body: some View {
        Button(action: act) {
            icon
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(hint)
        .contextMenu { menu }
    }

    @ViewBuilder private var icon: some View {
        if isMatching {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else if let job = resolvedJob {
            switch job.status {
            case .queued:
                Image(systemName: "clock")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            case .running:
                DownloadProgressRing(progress: job.progress, showsPercent: true)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.tuneAccent)
                    .contentTransition(.symbolEffect(.replace))
            case .failed, .cancelled:
                Image(systemName: "arrow.clockwise.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        } else if !store.installed.contains(where: { $0.id == track.providerID }) {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .offset(x: 2, y: 2)
                }
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(Color.tuneAccent)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var accessibilityTitle: String {
        if isMatching { return "받을 확장 찾는 중" }
        guard let job = resolvedJob else {
            if !store.installed.contains(where: { $0.id == track.providerID }) { return "받기, 확장 필요" }
            return "받기"
        }
        switch job.status {
        case .queued: return "받기, 대기 중"
        case .running: return "받는 중 \(Int((job.progress * 100).rounded()))퍼센트"
        case .completed: return "받음"
        case .failed, .cancelled: return "다시 받기"
        }
    }

    private var hint: String {
        "기본 음질로 받아요"
    }

    private func act() {
        if isMatching { return }
        guard let job = resolvedJob else {
            coordinator.requestDownload(track: track, store: store, downloads: downloads, toasts: toast)
            return
        }
        switch job.status {
        case .queued, .running, .completed:
            router.selectedTab = .downloads
        case .failed, .cancelled:
            downloads.retry(job.id)
            toast.show("다시 받기 시작했어요 · \(track.title)", symbol: "arrow.clockwise.circle")
        }
    }

    @ViewBuilder private var menu: some View {
        if let installed = store.installedExtension(id: track.providerID), installed.manifest.isDownloadProvider {
            if installed.manifest.qualityOptions.count > 1 {
                Menu {
                    ForEach(installed.manifest.qualityOptions) { quality in
                        Button {
                            downloads.enqueue(track: track, extension: installed, quality: quality.id)
                            toast.show("대기열에 넣었어요 · \(quality.label)", symbol: "arrow.down.circle.fill")
                        } label: {
                            Text(quality.label)
                        }
                    }
                } label: {
                    Label("다른 음질로 받기", systemImage: "slider.horizontal.3")
                }
            }
        }
        if let job = resolvedJob, job.isActive {
            Button(role: .destructive) {
                downloads.cancel(job.id)
            } label: {
                Label("대기열에서 빼기", systemImage: "minus.circle")
            }
        }
        if resolvedJob == nil {
            Button {
                coordinator.requestDownload(track: track, store: store, downloads: downloads, toasts: toast)
            } label: {
                Label("받기", systemImage: "arrow.down.circle")
            }
        }
    }
}
