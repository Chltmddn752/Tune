import SwiftData
import SwiftUI

/// 다운로드 탭. 진행·대기·받은 음악·실패를 한 스크롤에서 보여 준다.
struct DownloadsScreen: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ExtensionStore.self) private var store
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query private var tracks: [Track]

    private enum Sort: String, CaseIterable, Identifiable {
        case recent = "최근", album = "앨범", artist = "아티스트"
        var id: String { rawValue }
    }

    private struct ReceivedGroup: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let jobs: [DownloadJob]
    }

    @State private var sort: Sort = .album
    @State private var showFailed = false
    @State private var confirmClear = false

    private var padding: CGFloat { Spacing.screen(sizeClass) }
    private var active: DownloadJob? { downloads.activeJob }
    private var queued: [DownloadJob] {
        downloads.jobs.filter { $0.status == .queued && $0.id != active?.id }
    }
    private var completed: [DownloadJob] {
        downloads.jobs.filter { $0.status == .completed }.sorted { $0.createdAt > $1.createdAt }
    }
    private var failed: [DownloadJob] {
        downloads.jobs.filter { $0.status == .failed || $0.status == .cancelled }.sorted { $0.createdAt > $1.createdAt }
    }
    private var activeCount: Int { downloads.jobs.filter(\.isActive).count }
    private var hasProvider: Bool { !store.compatibleInstallableExtensions.isEmpty }

    var body: some View {
        List {
            if !hasProvider {
                Section {
                    setupCard
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: padding, bottom: 8, trailing: padding))
                }
            } else if downloads.jobs.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "arrow.down.circle",
                        title: "아직 받은 음악이 없어요",
                        message: "검색에서 곡을 찾아 ↓ 한 번만 누르면 돼요.",
                        primaryTitle: "음악 찾기",
                        primarySymbol: "magnifyingglass",
                        primaryAction: { router.openOnlineSearch() },
                        secondaryTitle: "음원 확장 설정",
                        secondaryAction: { coordinator.showSettingsSheet = true }
                    )
                    .listRowSeparator(.hidden)
                }
            } else {
                if let active {
                    Section {
                        DownloadHeroCard(job: active, queuedCount: queued.count)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: padding, bottom: 8, trailing: padding))
                    } header: {
                        Text("지금 받는 중").textCase(nil)
                    }
                }

                if !queued.isEmpty {
                    Section {
                        ForEach(queued) { job in
                            DownloadQueueRow(job: job)
                                .listRowInsets(EdgeInsets(top: 2, leading: padding, bottom: 2, trailing: padding))
                        }
                    } header: {
                        Text("대기 중 \(queued.count)곡").textCase(nil)
                    }
                }

                if !completed.isEmpty {
                    Section {
                        ForEach(receivedGroups) { group in
                            if sort == .recent {
                                ForEach(group.jobs) { job in
                                    receivedRow(job)
                                }
                            } else {
                                groupHeader(group)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 10, leading: padding, bottom: 0, trailing: padding))
                                ForEach(group.jobs) { job in
                                    receivedRow(job)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("받은 음악")
                            Spacer()
                            Menu {
                                Picker("정렬", selection: $sort) {
                                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(sort == .recent ? "최근" : sort.rawValue)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.tuneAccent)
                                .textCase(nil)
                            }
                        }
                        .textCase(nil)
                    }
                }

                if !failed.isEmpty {
                    Section {
                        Button {
                            withAnimation(.smooth(duration: 0.28)) { showFailed.toggle() }
                        } label: {
                            HStack {
                                Label("받지 못한 곡 \(failed.count)", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showFailed ? 180 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: padding, bottom: 4, trailing: padding))

                        if showFailed {
                            ForEach(failed) { job in
                                DownloadFailedRow(job: job)
                                    .listRowInsets(EdgeInsets(top: 2, leading: padding, bottom: 2, trailing: padding))
                            }
                            Button(role: .destructive) {
                                for job in failed { downloads.remove(job.id) }
                            } label: {
                                Label("실패 항목 지우기", systemImage: "trash")
                                    .font(.footnote)
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: padding, bottom: 6, trailing: padding))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("다운로드")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("정렬", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button {
                        coordinator.showSettingsSheet = true
                    } label: {
                        Label("다운로드 설정", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("기록 지우기", systemImage: "trash")
                    }
                    .disabled(completed.isEmpty && failed.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("다운로드 더 보기")
            }
        }
        .confirmationDialog("완료·실패 기록을 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("기록 지우기", role: .destructive) { downloads.clearFinished() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이미 보관함에 들어간 음악 파일은 지우지 않아요.")
        }
    }

    // MARK: 확장 없음

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(Color.tuneAccent)
                Text("음원을 받으려면 확장이 필요해요")
                    .font(.title3.weight(.semibold))
            }
            Text("확장은 곡을 찾고 파일로 저장하는 작은 도구예요. 한 번만 설치하면 계속 써요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.m) {
                step(1, "음원 확장 설치")
                step(2, "필요하면 로그인")
                step(3, "곡 옆 ↓ 누르기")
            }

            Button {
                coordinator.showSetupSheet = true
            } label: {
                Text("확장 설치")
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

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: Spacing.m) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.tuneAccent, in: Circle())
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    // MARK: 받은 음악

    private var receivedGroups: [ReceivedGroup] {
        if sort == .recent {
            return [ReceivedGroup(id: "recent", title: "", subtitle: "", jobs: completed)]
        }
        var buckets: [String: [DownloadJob]] = [:]
        for job in completed {
            let key = sort == .album
                ? job.displayAlbum.libraryKey
                : NameSplitter.primaryArtist(job.displayArtist).libraryKey
            buckets[key, default: []].append(job)
        }
        return buckets.map { key, jobs in
            let title = sort == .album
                ? jobs[0].displayAlbum
                : NameSplitter.primaryArtist(jobs[0].displayArtist)
            let artists = Set(jobs.map { $0.albumArtist.isEmpty ? $0.displayArtist : $0.albumArtist }).filter { !$0.isEmpty }
            let subtitle = sort == .album
                ? [artists.count == 1 ? artists.first : (artists.count > 1 ? "여러 아티스트" : nil), "\(jobs.count)곡"]
                    .compactMap { $0 }.joined(separator: " · ")
                : "\(jobs.count)곡"
            let ordered = jobs.sorted {
                ($0.album, $0.title) < ($1.album, $1.title)
            }
            return ReceivedGroup(id: key, title: title, subtitle: subtitle, jobs: ordered)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func groupHeader(_ group: ReceivedGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(group.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func receivedRow(_ job: DownloadJob) -> some View {
        let track = libraryTrack(for: job)
        DownloadReceivedRow(job: job, track: track, showsAlbum: sort == .recent)
            .listRowInsets(EdgeInsets(top: 2, leading: padding, bottom: 2, trailing: padding))
            .contentShape(Rectangle())
            .onTapGesture {
                if let track { player.play([track]) }
            }
            .contextMenu {
                Button {
                    router.selectedTab = .library
                } label: {
                    Label("보관함에서 보기", systemImage: "square.stack")
                }
                if let track, let album = track.album {
                    Button {
                        router.selectedTab = .library
                        router.open(.album(album.id))
                    } label: {
                        Label("앨범으로 이동", systemImage: "square.stack.3d.up")
                    }
                }
                Button(role: .destructive) {
                    downloads.remove(job.id)
                } label: {
                    Label("기록에서 지우기", systemImage: "trash")
                }
            }
    }

    private func libraryTrack(for job: DownloadJob) -> Track? {
        guard let path = job.relativePath else { return nil }
        return tracks.first { $0.relativePath == path }
    }
}

// MARK: - 지금 받는 중

struct DownloadHeroCard: View {
    let job: DownloadJob
    var queuedCount: Int = 0

    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                DownloadArtwork(job: job, size: 64, radius: Radius.tile)

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(job.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(job.providerName) · \(job.quality)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.s)

                Button {
                    downloads.cancel(job.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("받기 취소")
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(max(job.progress, 0), 1))
                    .tint(Color.tuneAccent)
                HStack(spacing: Spacing.s) {
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.tuneTime)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    if queuedCount > 0 {
                        Text("대기 \(queuedCount)곡")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let error = job.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(Spacing.l)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

// MARK: - 대기

struct DownloadQueueRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: Spacing.m) {
            DownloadArtwork(job: job, size: 44, radius: Radius.listArtwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.body).lineLimit(1)
                Text(job.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            DownloadStatusChip(status: .queued)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                downloads.cancel(job.id)
            } label: {
                Label("취소", systemImage: "xmark")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                downloads.cancel(job.id)
            } label: {
                Label("대기열에서 빼기", systemImage: "minus.circle")
            }
        }
    }
}

// MARK: - 받은 음악

struct DownloadReceivedRow: View {
    let job: DownloadJob
    var track: Track?
    var showsAlbum = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            if let track {
                ArtworkView(file: track.artworkFile, cornerRadius: Radius.listArtwork)
                    .frame(width: 44, height: 44)
            } else {
                DownloadArtwork(job: job, size: 44, radius: Radius.listArtwork)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.body).lineLimit(1)
                Text(showsAlbum && !job.album.isEmpty ? "\(job.displayArtist) · \(job.displayAlbum)" : job.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if track != nil {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 54)
    }
}

// MARK: - 실패

struct DownloadFailedRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: Spacing.m) {
            DownloadArtwork(job: job, size: 44, radius: Radius.listArtwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.body).lineLimit(1)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Button("다시 받기") {
                downloads.retry(job.id)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.tuneAccent)
            .frame(minHeight: 44)
        }
        .frame(minHeight: 56)
        .contextMenu {
            Button {
                downloads.retry(job.id)
            } label: {
                Label("다시 받기", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                downloads.remove(job.id)
            } label: {
                Label("목록에서 지우기", systemImage: "trash")
            }
            if let error = job.error {
                Button {
                } label: {
                    Label(error, systemImage: "info.circle")
                }
                .disabled(true)
            }
        }
    }

    private var reason: String {
        if job.status == .cancelled { return "취소됨" }
        guard let error = job.error, !error.isEmpty else { return "받지 못했어요" }
        return error
    }
}

// MARK: - 커버

struct DownloadArtwork: View {
    let job: DownloadJob
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        AsyncImage(url: job.coverURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
