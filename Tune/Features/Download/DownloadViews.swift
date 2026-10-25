import SwiftData
import SwiftUI

// MARK: - 온라인 검색 결과 한 줄

struct ProviderResultRow: View {
    let track: ProviderTrack
    let installed: InstalledExtension
    let job: DownloadJob?
    var isSelecting = false
    var isSelected = false

    @Environment(DownloadManager.self) private var downloads
    @Environment(ExtensionStore.self) private var store

    var body: some View {
        HStack(spacing: Spacing.m) {
            AsyncImage(url: track.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: Radius.listArtwork)
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "알 수 없는 아티스트" : track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(installed.title)
                    if track.durationMs > 0 {
                        Text("·")
                        Text(Formatters.time(Double(track.durationMs) / 1000))
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: Spacing.s)
            state
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var state: some View {
        if isSelecting, job == nil {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.tuneAccent : Color.secondary)
                .accessibilityLabel(isSelected ? "선택됨" : "선택 안 됨")
        } else if let job {
            switch job.status {
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("대기열에 있음")
            case .running:
                ProgressView(value: job.progress)
                    .progressViewStyle(.circular)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("받는 중")
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.tuneAccent)
                    .accessibilityLabel("보관함에 있음")
            case .failed, .cancelled:
                Button {
                    downloads.retry(job.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("다시 받기")
            }
        } else {
            Menu {
                ForEach(installed.manifest.qualityOptions) { quality in
                    Button {
                        downloads.enqueue(track: track, extension: installed, quality: quality.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(quality.label)
                            if let description = quality.description {
                                Text(description)
                            }
                        }
                    }
                }
                if installed.manifest.qualityOptions.isEmpty {
                    Button("최고 음질로 받기") {
                        downloads.enqueue(track: track, extension: installed)
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Color.tuneAccent)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("다운로드")
        }
    }
}

// MARK: - 다운로드 목록

private enum DownloadGrouping: String, CaseIterable, Identifiable {
    case recent
    case album
    case artist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "최근"
        case .album: "앨범"
        case .artist: "아티스트"
        }
    }
}

private struct DownloadGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let jobs: [DownloadJob]
}

struct DownloadListView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player
    @Query private var tracks: [Track]

    @State private var showClearConfirm = false
    @State private var grouping: DownloadGrouping = .recent

    var body: some View {
        List {
            if let active = downloads.activeJob {
                Section("받는 중") {
                    ActiveDownloadCard(job: active)
                }
            }

            if downloads.jobs.count > 1 {
                Section("묶어 보기") {
                    Picker("묶어 보기", selection: $grouping) {
                        ForEach(DownloadGrouping.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            let queued = downloads.jobs.filter { $0.status == .queued }
            jobSections("대기열", jobs: queued, newestFirst: false, showsTrackArtwork: false)

            let finished = downloads.jobs.filter { $0.status == .completed }
            jobSections("완료", jobs: finished, newestFirst: true, showsTrackArtwork: true)

            let failed = downloads.jobs.filter { $0.status == .failed || $0.status == .cancelled }
            jobSections("받지 못한 곡", jobs: failed, newestFirst: true, showsTrackArtwork: false)

            Section {
                NavigationLink {
                    ExtensionStoreView()
                } label: {
                    Label("다운로드 확장 관리", systemImage: "puzzlepiece.extension")
                }
            } footer: {
                if downloads.jobs.isEmpty {
                    Text("검색 화면의 '온라인'에서 곡을 찾아 내려받을 수 있어요. 먼저 확장 스토어에서 음원 확장을 설치하세요.")
                } else {
                    Text("받은 파일은 파일 앱의 Tune/다운로드 폴더에 저장되고 보관함에 자동으로 들어와요.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("다운로드")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        downloads.startNext()
                    } label: {
                        Label("대기열 시작", systemImage: "play.fill")
                    }
                    .disabled(downloads.activeJobID != nil || !downloads.jobs.contains { $0.status == .queued })
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("완료·실패 항목 지우기", systemImage: "trash")
                    }
                    .disabled(downloads.jobs.allSatisfy(\.isActive))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("완료·실패 항목을 지울까요?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("지우기", role: .destructive) { downloads.clearFinished() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이미 보관함에 들어간 음악 파일은 지우지 않아요.")
        }
    }

    @ViewBuilder
    private func jobSections(
        _ title: String,
        jobs: [DownloadJob],
        newestFirst: Bool,
        showsTrackArtwork: Bool
    ) -> some View {
        let groups = grouped(jobs, newestFirst: newestFirst)
        if !jobs.isEmpty {
            ForEach(groups) { group in
                Section {
                    ForEach(group.jobs) { job in
                        DownloadJobRow(job: job, track: showsTrackArtwork ? track(for: job) : nil)
                    }
                } header: {
                    groupHeader(title: title, group: group)
                }
            }
        }
    }

    @ViewBuilder
    private func groupHeader(title: String, group: DownloadGroup) -> some View {
        if grouping == .recent {
            Text("\(title) \(group.jobs.count)곡")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.title).textCase(nil)
                    Spacer()
                    Text("\(group.jobs.count)곡")
                        .font(.caption)
                        .fontWeight(.regular)
                        .textCase(nil)
                }
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .fontWeight(.regular)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func grouped(_ jobs: [DownloadJob], newestFirst: Bool) -> [DownloadGroup] {
        let sorted = jobs.sorted {
            newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
        switch grouping {
        case .recent:
            return [DownloadGroup(id: "all", title: "", subtitle: nil, jobs: sorted)]
        case .album:
            let buckets = Dictionary(grouping: sorted) { $0.displayAlbum.libraryKey }
            return buckets.map { key, jobs in
                DownloadGroup(
                    id: key,
                    title: jobs[0].displayAlbum,
                    subtitle: albumSubtitle(for: jobs),
                    jobs: jobs
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            let buckets = Dictionary(grouping: sorted) { NameSplitter.primaryArtist($0.displayArtist).libraryKey }
            return buckets.map { key, jobs in
                DownloadGroup(
                    id: key,
                    title: NameSplitter.primaryArtist(jobs[0].displayArtist),
                    subtitle: nil,
                    jobs: jobs
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private func albumArtist(for job: DownloadJob) -> String {
        job.albumArtist.isEmpty ? job.displayArtist : job.albumArtist
    }

    private func albumSubtitle(for jobs: [DownloadJob]) -> String? {
        let artists = Set(jobs.map(albumArtist(for:)).filter { !$0.isEmpty })
        if artists.count == 1 { return artists.first }
        return artists.isEmpty ? nil : "여러 아티스트"
    }

    private func track(for job: DownloadJob) -> Track? {
        guard let path = job.relativePath else { return nil }
        return tracks.first { $0.relativePath == path }
    }
}

private struct ActiveDownloadCard: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                AsyncImage(url: job.coverURL.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: Radius.listArtwork)
                        .fill(Color(.tertiarySystemFill))
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(job.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(job.providerName) · \(job.quality)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: Spacing.s)
                Text(job.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: job.progress)
                .tint(Color.tuneAccent)
            HStack {
                Text(job.error ?? "내려받는 중이에요")
                    .font(.caption)
                    .foregroundStyle(job.error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer()
                Button("취소", role: .destructive) { downloads.cancel(job.id) }
                    .font(.subheadline)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

private struct DownloadJobRow: View {
    let job: DownloadJob
    var track: Track?

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player

    private var artworkURL: URL? {
        job.coverURL.flatMap(URL.init(string:))
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            Group {
                if let track {
                    ArtworkView(file: track.artworkFile, cornerRadius: Radius.listArtwork)
                } else {
                    AsyncImage(url: artworkURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: Radius.listArtwork)
                            .fill(Color(.tertiarySystemFill))
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.body).lineLimit(1)
                Text(job.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let error = job.error, job.status != .completed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let warning = job.tagWarning, job.status == .completed {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Spacing.s)

            if job.status == .completed {
                if track != nil {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(Color.tuneAccent)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.tuneAccent)
                        .accessibilityLabel("완료")
                }
            } else if job.status == .queued {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("대기 중")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let track { player.play([track]) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                downloads.remove(job.id)
            } label: {
                Label("목록에서 빼기", systemImage: "trash")
            }
            if job.status == .queued {
                Button {
                    downloads.cancel(job.id)
                } label: {
                    Label("취소", systemImage: "xmark")
                }
                .tint(.orange)
            }
            if job.status == .failed || job.status == .cancelled {
                Button {
                    downloads.retry(job.id)
                } label: {
                    Label("다시 받기", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if let track {
                Button {
                    player.play([track])
                } label: {
                    Label("재생", systemImage: "play.fill")
                }
            }
            if job.status == .failed || job.status == .cancelled {
                Button {
                    downloads.retry(job.id)
                } label: {
                    Label("다시 받기", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                downloads.remove(job.id)
            } label: {
                Label("목록에서 빼기", systemImage: "trash")
            }
        }
    }
}
