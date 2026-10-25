import Charts
import SwiftUI

// MARK: 요약 (웹앱의 홈)

struct StatsOverview: View {
    let library: StatsLibrary
    let lookup: StatsLookup
    var showRanking: (RankKind, StatsPeriod) -> Void

    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let now = Date.now
        let calendar = StatsCalendar.local
        let weekStart = StatsPeriod.week.start(now: now) ?? now
        let week = library.slice(from: weekStart)
        let weekSeconds = StatsMath.totalSeconds(week)
        // 지난주 같은 시점까지와 비교
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        let lastWeek = library.slice(from: lastWeekStart, to: calendar.date(byAdding: .day, value: -7, to: now))
        let lastWeekSeconds = StatsMath.totalSeconds(lastWeek)
        let change: Int? = lastWeekSeconds > 60 ? Int(((weekSeconds - lastWeekSeconds) / lastWeekSeconds * 100).rounded()) : nil
        let allSeconds = StatsMath.totalSeconds(library.plays)
        let topArtists = StatsMath.rank(week, by: .artists, limit: 5)

        VStack(alignment: .leading, spacing: Spacing.xxl) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)],
                      spacing: Spacing.m) {
                StatsCard(title: "이번 주", value: StatsFormat.duration(weekSeconds)) {
                    Text("\(StatsFormat.number(week.count))곡 재생").foregroundStyle(.secondary)
                    if let change {
                        Text(change >= 0 ? "지난주보다 \(change)% 더" : "지난주보다 \(-change)% 덜")
                            .foregroundStyle(change >= 0 ? Color.tuneAccent : Color.secondary)
                    }
                }
                StatsCard(title: "전체", value: StatsFormat.duration(allSeconds)) {
                    Text("\(StatsFormat.number(library.plays.count))곡 재생").foregroundStyle(.secondary)
                    if let first = library.firstDate {
                        Text("\(StatsFormat.date(first))부터 기록").foregroundStyle(.secondary)
                    }
                }
            }

            weekChart(week: Array(week), weekStart: weekStart, now: now)

            VStack(alignment: .leading, spacing: Spacing.m) {
                StatsSectionTitle("이번 주 많이 들은 아티스트")
                if topArtists.isEmpty {
                    StatsEmptyNote(text: "이번 주에는 아직 들은 기록이 없어요.")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 5),
                              alignment: .leading, spacing: Spacing.m) {
                        ForEach(Array(topArtists.enumerated()), id: \.element.id) { index, item in
                            artistCell(index: index, item: item)
                        }
                    }
                }
                Button {
                    showRanking(.artists, .week)
                } label: {
                    Text("전체 순위 보기")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Color.tuneAccent)
            }

            recentPlays
        }
    }

    private func artistCell(index: Int, item: RankItem) -> some View {
        let content = VStack(spacing: 6) {
            StatsArtistAvatar(name: item.title, lookup: lookup)
                .overlay(alignment: .topLeading) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(index == 0 ? Color.tuneAccent : Color.black.opacity(0.55), in: Circle())
                }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(StatsFormat.number(item.count))회")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        return Group {
            if let artist = lookup.artist(named: item.title) {
                NavigationLink(value: Route.artist(artist.id)) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private struct DayBar: Identifiable {
        let index: Int
        let minutes: Double
        var id: Int { index }
    }

    private func weekChart(week: [Play], weekStart: Date, now: Date) -> some View {
        let startDay = StatsCalendar.dayIndex(of: weekStart)
        var minutes = Array(repeating: 0.0, count: 7)
        for play in week where (0..<7).contains(play.day - startDay) {
            minutes[play.day - startDay] += play.seconds / 60
        }
        let todayIndex = min(max(StatsCalendar.today(now) - startDay, 0), 6)
        let bars = (0..<7).map { DayBar(index: $0, minutes: minutes[$0]) }

        return VStack(alignment: .leading, spacing: Spacing.m) {
            StatsSectionTitle("이번 주 청취 시간")
            StatsPanel {
                Chart(bars) { bar in
                    BarMark(
                        x: .value("요일", StatsFormat.weekdays[bar.index]),
                        y: .value("분", bar.minutes),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(bar.index == todayIndex ? Color.tuneAccent : Color.tuneAccent.opacity(0.45))
                    .cornerRadius(5)
                }
                .chartXScale(domain: StatsFormat.weekdays)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel { if let m = value.as(Double.self) { Text("\(Int(m))분") } }
                    }
                }
                .frame(height: 170)
                Text("하루 평균 \(StatsFormat.duration(minutes.reduce(0, +) * 60 / Double(todayIndex + 1)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentPlays: some View {
        let recent = Array(library.plays.suffix(10).reversed())
        return VStack(alignment: .leading, spacing: Spacing.s) {
            StatsSectionTitle("최근 재생")
            ForEach(Array(recent.enumerated()), id: \.offset) { _, play in
                Button {
                    if let track = lookup.tracks[play.trackID] { player.play([track]) }
                } label: {
                    HStack(spacing: Spacing.m) {
                        ArtworkView(file: play.artwork, cornerRadius: Radius.listArtwork)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(play.title).font(.body).lineLimit(1)
                            Text(play.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: Spacing.s)
                        Text(StatsFormat.ago(play.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: 순위

struct StatsTop: View {
    let library: StatsLibrary
    let lookup: StatsLookup
    @Binding var kind: RankKind
    @Binding var period: StatsPeriod

    @State private var limit = 50

    var body: some View {
        let list = library.slice(from: period.start())
        let items = StatsMath.rank(list, by: kind, limit: limit)
        let queue = kind == .tracks ? items.compactMap { $0.trackID.flatMap { lookup.tracks[$0] } } : []

        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                StatsChips(options: RankKind.allCases, selection: $kind) { $0.rawValue }
                StatsChips(options: StatsPeriod.allCases, selection: $period) { $0.rawValue }
            }

            if list.isEmpty {
                StatsEmptyNote(text: "\(period.rawValue)에는 들은 기록이 없어요.")
            } else {
                Text("\(period.sentencePrefix) \(StatsFormat.number(list.count))곡, 약 \(StatsFormat.duration(StatsMath.totalSeconds(list))) 들었어요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        StatsRankRow(rank: index + 1, item: item, kind: kind, lookup: lookup, queue: queue)
                        if index < items.count - 1 {
                            Divider().padding(.leading, 24 + Spacing.m + 48 + Spacing.m)
                        }
                    }
                }

                if items.count >= limit {
                    Button("더 보기") { limit += 50 }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: kind) { limit = 50 }
        .onChange(of: period) { limit = 50 }
    }
}

// MARK: 패턴

struct StatsPatterns: View {
    let library: StatsLibrary
    @State private var period: StatsPeriod = .all

    var body: some View {
        let streaks = StatsMath.listeningStreaks(library.plays)
        let repeatRecord = StatsMath.longestRepeat(library.plays)
        let artistStreak = StatsMath.longestArtistStreak(library.plays)
        let currentNote = streaks.current == 0
            ? "오늘 들으면 새로 시작돼요"
            : (streaks.listenedToday ? "오늘까지 이어지고 있어요" : "오늘 들으면 이어져요")

        VStack(alignment: .leading, spacing: Spacing.xxl) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                StatsSectionTitle("1년 청취 기록")
                StatsPanel {
                    YearHeatmap(counts: StatsMath.dailyCounts(library.plays))
                }
            }

            VStack(alignment: .leading, spacing: Spacing.m) {
                StatsSectionTitle("요일과 시간대")
                StatsChips(options: StatsPeriod.allCases, selection: $period) { $0.rawValue }
                StatsPanel {
                    WeekHourHeatmap(matrix: StatsMath.weekdayHourMatrix(library.slice(from: period.start())))
                }
            }

            VStack(alignment: .leading, spacing: Spacing.m) {
                StatsSectionTitle("연속 기록")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)],
                          spacing: Spacing.m) {
                    StatsCard(title: "현재 연속 청취", value: "\(StatsFormat.number(streaks.current))일") {
                        Text(currentNote).foregroundStyle(.secondary)
                    }
                    StatsCard(title: "최장 연속 청취", value: streaks.longest.map { "\(StatsFormat.number($0.days))일" } ?? "-") {
                        Text(streaks.longest.map { StatsFormat.dayRange($0.start, $0.end) } ?? "아직 기록이 없어요")
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.8)
                    }
                    StatsCard(title: "한 곡 반복 재생", value: repeatRecord.map { "\(StatsFormat.number($0.count))번" } ?? "-") {
                        if let repeatRecord {
                            Text(repeatRecord.title)
                            Text(repeatRecord.artist).foregroundStyle(.secondary)
                        } else {
                            Text("같은 곡을 연달아 들은 기록이 없어요").foregroundStyle(.secondary)
                        }
                    }
                    StatsCard(title: "한 아티스트 연속", value: artistStreak.map { "\(StatsFormat.number($0.days))일" } ?? "-") {
                        if let artistStreak {
                            Text(artistStreak.artist)
                            Text(StatsFormat.dayRange(artistStreak.start, artistStreak.end))
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.8)
                        } else {
                            Text("이틀 넘게 이어 들은 아티스트가 없어요").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: 발견

enum DiscoverRange: String, CaseIterable, Identifiable {
    case thisMonth = "이번 달", lastMonth = "지난 달"
    var id: String { rawValue }

    func range(now: Date = .now) -> (start: Date, end: Date?) {
        let calendar = StatsCalendar.local
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        switch self {
        case .thisMonth: return (thisMonth, nil)
        case .lastMonth: return (calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth, thisMonth)
        }
    }
}

struct StatsDiscover: View {
    let library: StatsLibrary
    let lookup: StatsLookup
    @State private var range: DiscoverRange = .thisMonth

    private let maxNew = 30

    var body: some View {
        let bounds = range.range()
        let discoveries = StatsMath.newArtists(library.plays, start: bounds.start, end: bounds.end)
        let months = StatsMath.monthlyTopArtists(library.plays)
        let activeMonths = months.filter { $0.total > 0 }.count

        VStack(alignment: .leading, spacing: Spacing.xxl) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                StatsSectionTitle("새로 발견한 아티스트",
                                  subtitle: library.firstDate.map { "기록이 시작된 \(StatsFormat.date($0)) 이후 처음 들은 아티스트예요" })
                StatsChips(options: DiscoverRange.allCases, selection: $range) { $0.rawValue }

                if discoveries.isEmpty {
                    StatsEmptyNote(text: "\(range.rawValue)에 처음 들은 아티스트가 없어요.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(discoveries.prefix(maxNew)) { discovery in
                            discoveryRow(discovery)
                        }
                    }
                    if discoveries.count > maxNew {
                        Text("\(range.rawValue)에 처음 들은 아티스트는 모두 \(StatsFormat.number(discoveries.count))명이에요. 많이 들은 \(maxNew)명만 보여줘요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.m) {
                StatsSectionTitle("월별 최애 변천사")
                if activeMonths >= 2 {
                    StatsPanel {
                        FavoritesChart(months: Array(months.suffix(12)))
                    }
                } else {
                    Text("두 달 넘게 기록이 쌓이면 순위 변화 그래프가 나와요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(months.reversed().prefix(24))) { month in
                        monthRow(month)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func discoveryRow(_ discovery: StatsMath.Discovery) -> some View {
        let row = HStack(spacing: Spacing.m) {
            StatsArtistAvatar(name: discovery.artist, lookup: lookup)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.artist).font(.body).lineLimit(1)
                Text("\(StatsFormat.date(discovery.first))에 처음 들음")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            Text("\(StatsFormat.number(discovery.count))회")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())

        if let artist = lookup.artist(named: discovery.artist) {
            NavigationLink(value: Route.artist(artist.id)) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private func monthRow(_ month: StatsMath.MonthRanking) -> some View {
        HStack(spacing: Spacing.m) {
            Text("\(String(month.year))년 \(month.monthOfYear)월")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            if let top = month.ranking.first {
                StatsArtistAvatar(name: top.artist, lookup: lookup)
                    .frame(width: 36, height: 36)
                Text(top.artist).font(.body).lineLimit(1)
                Spacer(minLength: Spacing.s)
                Text("\(StatsFormat.number(top.count))회")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("기록 없음").font(.subheadline).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .frame(minHeight: 44)
    }
}

/// 월별 아티스트 순위 변화 (최근 12개월). 고른 아티스트만 포인트 색, 나머지는 회색
struct FavoritesChart: View {
    let months: [StatsMath.MonthRanking]
    @State private var selected: String?

    private struct Point: Identifiable {
        let id = UUID()
        let artist: String
        let series: String
        let x: Double
        let rank: Int
    }

    var body: some View {
        let artists = StatsMath.chartArtists(months)
        let current = selected.flatMap { key in artists.contains { $0.key == key } ? key : nil } ?? artists.first?.key
        // 고른 아티스트의 선이 맨 위에 그려지도록 마지막에 둔다.
        let ordered = artists.filter { $0.key != current } + artists.filter { $0.key == current }
        let points = makePoints(ordered)

        VStack(alignment: .leading, spacing: Spacing.m) {
            Chart(points) { point in
                let active = point.artist == current
                LineMark(x: .value("달", point.x), y: .value("순위", Double(6 - point.rank)),
                         series: .value("선", point.series))
                    .foregroundStyle(active ? Color.tuneAccent : Color.gray.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: active ? 3 : 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("달", point.x), y: .value("순위", Double(6 - point.rank)))
                    .foregroundStyle(active ? Color.tuneAccent : Color.gray.opacity(0.45))
                    .symbolSize(active ? 46 : 20)
            }
            .chartXScale(domain: -0.4...(Double(max(months.count - 1, 1)) + 0.4))
            .chartYScale(domain: 0.5...5.5)
            .chartYAxis {
                AxisMarks(position: .leading, values: [1.0, 2.0, 3.0, 4.0, 5.0]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let y = value.as(Double.self) { Text("\(6 - Int(y))위") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 0.0, to: Double(months.count), by: 2))) { value in
                    AxisValueLabel {
                        if let x = value.as(Double.self), months.indices.contains(Int(x)) {
                            Text(label(Int(x)))
                        }
                    }
                }
            }
            .frame(height: 220)
            .accessibilityLabel("월별 아티스트 순위 변화 그래프")

            ScrollView(.horizontal) {
                HStack(spacing: Spacing.s) {
                    ForEach(artists) { artist in
                        FilterChip(title: artist.artist, isSelected: artist.key == current) {
                            withAnimation(.smooth(duration: 0.25)) { selected = artist.key }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func label(_ index: Int) -> String {
        let month = months[index]
        let thisYear = StatsCalendar.local.component(.year, from: .now)
        return month.monthOfYear == 1 || (index == 0 && month.year != thisYear)
            ? "\(String(month.year % 100))년 \(month.monthOfYear)월"
            : "\(month.monthOfYear)월"
    }

    /// 순위 밖으로 나간 달에서는 선을 끊는다.
    private func makePoints(_ artists: [StatsMath.ChartArtist]) -> [Point] {
        var points: [Point] = []
        for artist in artists {
            var segment = 0
            var previous: Int?
            for (i, month) in months.enumerated() {
                guard let rank = month.ranking.firstIndex(where: { $0.key == artist.key }) else { continue }
                if previous != i - 1 { segment += 1 }
                points.append(Point(artist: artist.key, series: "\(artist.key)#\(segment)", x: Double(i), rank: rank + 1))
                previous = i
            }
        }
        return points
    }
}

// MARK: 돌아보기 (웹앱의 Wrapped)

struct StatsRecap: View {
    let library: StatsLibrary
    let lookup: StatsLookup

    @State private var range: RecapRange = .thisMonth
    @State private var from: Date?
    @State private var to = Date.now
    @State private var artistPick: String?
    @State private var openTrack: String?

    var body: some View {
        let fromValue = from ?? library.firstDate ?? .now
        let period = RecapPeriod.resolve(range, from: fromValue, to: to)
        let recap = period.flatMap { Recap(library: library, period: $0) }

        VStack(alignment: .leading, spacing: Spacing.xl) {
            StatsSectionTitle("돌아보기", subtitle: "기간을 고르면 그동안 들은 음악을 한 장으로 정리해줘요.")
            StatsChips(options: RecapRange.allCases, selection: $range) { $0.rawValue }

            if range == .custom {
                StatsPanel {
                    DatePicker("시작일", selection: Binding(get: { fromValue }, set: { from = $0 }),
                               in: (library.firstDate ?? .distantPast)...Date.now, displayedComponents: .date)
                    Divider()
                    DatePicker("종료일", selection: $to,
                               in: (library.firstDate ?? .distantPast)...Date.now, displayedComponents: .date)
                }
            }

            if let period {
                if let recap {
                    content(recap, period: period)
                        .id(period.start)
                } else {
                    StatsEmptyNote(text: "\(period.rangeText)에는 들은 기록이 없어요. 다른 기간을 골라보세요.")
                }
            } else {
                StatsEmptyNote(text: "시작일이 종료일보다 늦어요. 날짜를 다시 골라주세요.")
            }
        }
    }

    @ViewBuilder
    private func content(_ recap: Recap, period: RecapPeriod) -> some View {
        // 표지 색은 가장 많이 들은 곡의 앨범 색
        let heroColor = recap.topTracks.first?.trackID.flatMap { lookup.tracks[$0]?.album?.colorHex }

        VStack(alignment: .leading, spacing: Spacing.xl) {
            // 표지
            VStack(alignment: .leading, spacing: 6) {
                Text("Tune")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(period.title)
                    .font(.title.weight(.heavy))
                    .foregroundStyle(.white)
                Text(period.rangeText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: Spacing.l)
                Text("이 기간에 \(StatsFormat.number(recap.plays))곡을 들었어요.")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .padding(Spacing.xl)
            .background {
                LinearGradient(colors: [Color(hex: heroColor, fallback: Color.tuneAccent), Color.tuneAccent.opacity(0.75)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Color.black.opacity(0.18))
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)],
                      spacing: Spacing.m) {
                StatsCard(title: "들은 시간", value: StatsFormat.duration(recap.seconds)) {
                    Text("하루 평균 \(StatsFormat.duration(recap.dailyAverage))").foregroundStyle(.secondary)
                }
                StatsCard(title: "재생", value: "\(StatsFormat.number(recap.plays))곡") {
                    Text("\(StatsFormat.number(recap.days))일 중 \(StatsFormat.number(recap.activeDays))일 들음")
                        .foregroundStyle(.secondary)
                }
            }

            StatsPanel {
                if let topDay = recap.topDay {
                    highlight("calendar", "가장 많이 들은 날",
                              "\(StatsFormat.date(topDay.date)), \(StatsFormat.number(topDay.count))곡")
                }
                if let peak = recap.peak {
                    Divider()
                    highlight("clock", "자주 듣는 때",
                              "\(StatsFormat.weekdays[peak.weekday])요일 \(StatsFormat.hour(peak.hour))대")
                }
                Divider()
                highlight("sparkles", "새로 발견한 아티스트",
                          recap.newArtistCount == 0
                              ? "없어요"
                              : "\(StatsFormat.number(recap.newArtistCount))명 · \(recap.newArtistTop.map(\.artist).joined(separator: ", "))")
            }

            artistsSection(recap)
            tracksSection(recap)
        }
    }

    private func highlight(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.tuneAccent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func artistsSection(_ recap: Recap) -> some View {
        // 기록이 바뀌어 고른 아티스트가 목록에 없으면 1위를 보여준다.
        let selectedKey = recap.artistDetails[artistPick ?? ""] != nil ? artistPick : recap.topArtists.first?.key
        let selected = recap.topArtists.first { $0.key == selectedKey }
        let detail = selectedKey.flatMap { recap.artistDetails[$0] }

        VStack(alignment: .leading, spacing: Spacing.m) {
            StatsSectionTitle("많이 들은 아티스트", subtitle: "눌러서 자세히")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 5),
                      alignment: .leading, spacing: Spacing.m) {
                ForEach(recap.topArtists) { artist in
                    let isSelected = artist.key == selectedKey
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { artistPick = artist.key }
                    } label: {
                        VStack(spacing: 6) {
                            StatsArtistAvatar(name: artist.title, lookup: lookup)
                                .padding(3)
                                .overlay(Circle().strokeBorder(isSelected ? Color.tuneAccent : .clear, lineWidth: 2.5))
                            Text(artist.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text("\(StatsFormat.number(artist.count))회").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            if let selected, let detail {
                StatsPanel {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selected.title).font(.headline).lineLimit(1)
                        Spacer()
                        Text("전체 재생의 \(StatsFormat.percent(detail.share))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: detail.share)
                        .tint(Color.tuneAccent)
                    Text("\(StatsFormat.number(detail.count))회, 약 \(StatsFormat.duration(detail.seconds)) 들었고 \(StatsFormat.number(detail.days))일에 걸쳐 들었어요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: Spacing.m) {
                                Text("\(index + 1)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                                Text(track.title).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text("\(StatsFormat.number(track.count))회").font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .id(selectedKey)
                .transition(.opacity)
            }
        }
    }

    private func tracksSection(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            StatsSectionTitle("많이 들은 곡", subtitle: "눌러서 펼치기")
            VStack(spacing: 0) {
                ForEach(Array(recap.topTracks.enumerated()), id: \.element.id) { index, track in
                    let open = openTrack == track.key
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.smooth(duration: 0.3)) { openTrack = open ? nil : track.key }
                        } label: {
                            HStack(spacing: Spacing.m) {
                                Text("\(index + 1)")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(index < 3 ? Color.tuneAccent : Color.secondary)
                                    .frame(minWidth: 24)
                                ArtworkView(file: track.artwork, cornerRadius: Radius.listArtwork)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).font(.body).lineLimit(1)
                                    Text(track.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: Spacing.s)
                                Text("\(StatsFormat.number(track.count))회")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(open ? 180 : 0))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(open ? "접기" : "펼치기")

                        if open, let detail = recap.trackDetails[track.key] {
                            Text(trackSentence(detail))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24 + Spacing.m)
                                .padding(.vertical, Spacing.s)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .clipped()
                }
            }
        }
    }

    private func trackSentence(_ d: Recap.TrackDetail) -> String {
        let time = "약 \(StatsFormat.duration(d.seconds)) 들었어요."
        if d.days > 1 {
            return "\(time) \(StatsFormat.number(d.days))일에 걸쳐 들었고 \(StatsFormat.date(d.first))에 처음, \(StatsFormat.date(d.last))에 마지막으로 들었어요."
        }
        return "\(time) \(StatsFormat.date(d.last))에 들었어요."
    }
}
