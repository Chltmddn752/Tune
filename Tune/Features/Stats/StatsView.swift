import SwiftData
import SwiftUI

/// 통계 탭: 예전에 만든 Listening Stats 웹앱(홈 · 순위 · 패턴 · 발견 · Wrapped)을
/// 이 앱의 재생 기록(30초 이상 들은 곡)으로 계산해서 Apple 스타일 화면에 옮겼다.
enum StatsSection: String, CaseIterable, Identifiable {
    case overview = "요약", top = "순위", patterns = "패턴", discover = "발견", recap = "돌아보기"
    var id: String { rawValue }
}

/// 이름 → 보관함의 아티스트·앨범·곡 (사진·이동·재생용)
struct StatsLookup {
    var artists: [String: Artist] = [:]
    var albums: [String: Album] = [:]
    var tracks: [UUID: Track] = [:]

    func artist(named name: String) -> Artist? {
        let key = name.lowercased()
        if let artist = artists[key] { return artist }
        // "A, B", "A & B", "A feat. B"처럼 여러 명이면 첫 사람으로
        for separator in [", ", " & ", " feat. ", " ft. ", " featuring ", " x ", "; ", " / "] {
            if let first = key.components(separatedBy: separator).first, first != key, let artist = artists[first] {
                return artist
            }
        }
        return nil
    }
}

struct StatsView: View {
    @Query(sort: \PlayEvent.date) private var events: [PlayEvent]
    @Query private var albums: [Album]
    @Query private var artists: [Artist]
    @Query private var tracks: [Track]
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var library = StatsLibrary.empty
    @State private var section: StatsSection = .overview
    @State private var topKind: RankKind = .tracks
    @State private var topPeriod: StatsPeriod = .week

    private var signature: String {
        "\(events.count)-\(events.last?.date.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        let lookup = StatsLookup(
            artists: Dictionary(artists.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }),
            albums: Dictionary(albums.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }),
            tracks: Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        )

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: 4) {
                    M3TabHeader("통계")
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(StatsSection.allCases) { item in
                                M3FilterChip(title: item.rawValue, isSelected: section == item) {
                                    withAnimation(M3Motion.standard) { section = item }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }

                if library.isEmpty {
                    ContentUnavailableView("아직 기록이 없어요", systemImage: "chart.bar",
                                           description: Text("곡을 30초 이상 들으면 여기에 기록돼요."))
                        .padding(.top, 40)
                } else {
                    switch section {
                    case .overview:
                        M3RecapHero(library: library, lookup: lookup)
                        StatsOverview(library: library, lookup: lookup) { kind, period in
                            topKind = kind
                            topPeriod = period
                            withAnimation(.smooth) { section = .top }
                        }
                    case .top:
                        StatsTop(library: library, lookup: lookup, kind: $topKind, period: $topPeriod)
                    case .patterns:
                        StatsPatterns(library: library)
                    case .discover:
                        StatsDiscover(library: library, lookup: lookup)
                    case .recap:
                        StatsRecap(library: library, lookup: lookup)
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.screen(sizeClass))
            .padding(.top, Spacing.s)
            .padding(.bottom, 120)
        }
        .m3HidesNavOnScroll()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: signature, initial: true) {
            library = StatsLibrary(events: events)
        }
    }
}

// MARK: 공용 조각

/// 숫자 카드 (제목 · 큰 숫자 · 설명 줄)
struct StatsCard<Footer: View>: View {
    let title: String
    let value: String
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 2) { footer }
                .font(.footnote)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(Spacing.l)
        .background(Color.m3SurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 둥근 회색 상자 안에 넣는 묶음
struct StatsPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.l)
            .background(Color.m3SurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 기록이 없을 때 회색 상자 안 한 줄
struct StatsEmptyNote: View {
    let text: String
    var body: some View {
        StatsPanel {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// 가로로 넘기는 칩 줄
struct StatsChips<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                ForEach(options) { option in
                    FilterChip(title: label(option), isSelected: selection == option) {
                        withAnimation(.smooth(duration: 0.25)) { selection = option }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

struct StatsSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.tuneSection)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// 아티스트 동그란 사진 (보관함에 없으면 첫 글자)
struct StatsArtistAvatar: View {
    let name: String
    let lookup: StatsLookup

    var body: some View {
        if let artist = lookup.artist(named: name) {
            ArtistImage(artist: artist)
        } else {
            Circle()
                .fill(Color(.systemGray5))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(String(name.prefix(1)))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.2)
                        .padding(8)
                        .foregroundStyle(Color(.systemGray))
                }
        }
    }
}

/// 순위 한 줄 (곡은 누르면 재생, 앨범·아티스트는 누르면 그 화면으로)
struct StatsRankRow: View {
    let rank: Int?
    let item: RankItem
    let kind: RankKind
    let lookup: StatsLookup
    var queue: [Track] = []
    var showTime = true

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        switch kind {
        case .tracks:
            Button { play() } label: { row }
                .buttonStyle(.plain)
                .contextMenu {
                    if let track = item.trackID.flatMap({ lookup.tracks[$0] }) {
                        TrackMenuItems(track: track)
                    }
                }
        case .albums:
            if let album = lookup.albums[item.key] {
                NavigationLink(value: Route.album(album.id)) { row }.buttonStyle(.plain)
            } else {
                row
            }
        case .artists:
            if let artist = lookup.artist(named: item.title) {
                NavigationLink(value: Route.artist(artist.id)) { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
    }

    private var row: some View {
        HStack(spacing: Spacing.m) {
            if let rank {
                Text("\(rank)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(rank <= 3 ? Color.tuneAccent : Color.secondary)
                    .frame(minWidth: 24)
            }
            Group {
                if kind == .artists {
                    StatsArtistAvatar(name: item.title, lookup: lookup)
                } else {
                    ArtworkView(file: item.artwork, cornerRadius: Radius.listArtwork)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.tuneAccent : Color.primary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(StatsFormat.number(item.count))회")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if showTime {
                    Text(StatsFormat.duration(item.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var isCurrent: Bool {
        kind == .tracks && item.trackID != nil && player.current?.trackID == item.trackID
    }

    private func play() {
        guard let id = item.trackID, let track = lookup.tracks[id] else { return }
        if let start = queue.firstIndex(where: { $0.id == id }) {
            player.play(queue, startAt: start)
        } else {
            player.play([track])
        }
    }
}


// MARK: - SpatialFlow 'Your Flow Highlights' 머리 카드

/// 요약 맨 위: 총 감상 시간 · 가장 많이 듣는 시간대 · 1위 곡 (SpatialFlow Recap)
struct M3RecapHero: View {
    let library: StatsLibrary
    let lookup: StatsLookup

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let plays = library.plays
        let minutes = Int(StatsMath.totalSeconds(plays) / 60)
        let mood = Self.mood(for: plays)
        let top = StatsMath.rank(plays, by: .tracks, limit: 1).first

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("나의 흐름 하이라이트")
                    .font(.m3(11, .bold))
                    .tracking(1)
                    .foregroundStyle(Color.m3Primary)
                Text("나만의 감상 돌아보기")
                    .font(.m3(26, .bold))
                    .foregroundStyle(Color.m3OnSurface)
                Text("지금까지 Tune에서 들은 음악을 한눈에 모았어요.")
                    .font(.m3BodyMedium)
                    .foregroundStyle(Color.m3OnSurfaceVariant)
            }

            HStack(alignment: .top, spacing: 12) {
                statCard(symbol: "headphones",
                         value: minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분",
                         caption: "총 감상 시간",
                         fill: .m3SecondaryContainer, ink: .m3OnSecondaryContainer)
                statCard(symbol: mood.symbol, value: mood.title, caption: mood.caption,
                         fill: .m3TertiaryContainer, ink: .m3OnTertiaryContainer)
            }
            .fixedSize(horizontal: false, vertical: true)

            if let top {
                topTrack(top)
            }
        }
        .padding(20)
        .background {
            LinearGradient(colors: [Color.m3PrimaryContainer.opacity(0.7), Color.m3SurfaceContainerLow],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private func statCard(symbol: String, value: String, caption: String, fill: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20))
            Text(value)
                .font(.m3(20, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.m3BodySmall)
                .opacity(0.8)
                .lineLimit(3)
        }
        .foregroundStyle(ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func topTrack(_ item: RankItem) -> some View {
        Button {
            if let id = item.trackID, let track = lookup.tracks[id] {
                player.play([track])
            }
        } label: {
            HStack(spacing: 16) {
                ArtworkView(file: item.artwork, cornerRadius: 16, title: item.title)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("나의 1위 곡")
                        .font(.m3(10, .bold))
                        .foregroundStyle(Color.m3OnPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.m3Primary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(item.title)
                        .font(.m3(20, .bold))
                        .foregroundStyle(Color.m3OnPrimaryContainer)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.m3BodyMedium)
                        .foregroundStyle(Color.m3OnPrimaryContainer.opacity(0.8))
                        .lineLimit(1)
                    Text("\(item.count)번 들었어요")
                        .font(.m3LabelMedium.weight(.bold))
                        .foregroundStyle(Color.m3Primary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color.m3PrimaryContainer, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private struct Mood {
        var title: String
        var caption: String
        var symbol: String
    }

    /// 가장 많이 들은 시간대로 고른 '흐름' 이름
    private static func mood(for plays: [Play]) -> Mood {
        var counts = [Int](repeating: 0, count: 24)
        for play in plays where (0..<24).contains(play.hour) { counts[play.hour] += 1 }
        let peak = counts.indices.max { counts[$0] < counts[$1] } ?? 12
        switch peak {
        case 5...11: return Mood(title: "아침의 불꽃", caption: "아침 음악으로 하루를 여는 편이에요.", symbol: "sun.horizon.fill")
        case 12...16: return Mood(title: "오후의 그루브", caption: "한낮의 리듬으로 집중을 이어가요.", symbol: "sun.max.fill")
        case 17...21: return Mood(title: "저녁의 하모니", caption: "노을 같은 곡으로 하루를 마무리해요.", symbol: "sunset.fill")
        default: return Mood(title: "한밤의 신비", caption: "깊은 밤에 진짜 음악 흐름이 깨어나요.", symbol: "moon.stars.fill")
        }
    }
}
