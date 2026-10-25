import Foundation

/// 통계 계산용으로 가볍게 옮겨 둔 재생 기록 하나.
/// (Listening Stats 웹앱의 scrobble 하나와 같은 역할)
struct Play {
    let date: Date
    let seconds: Double
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let artwork: String?

    /// 기기 시간대 기준 날짜 번호 (하루 = 1, 서머타임과 상관없이 하루씩 늘어난다)
    let day: Int
    /// 월요일 = 0 ... 일요일 = 6
    let weekday: Int
    let hour: Int
    /// 연 × 12 + (월 - 1)
    let month: Int

    let artistKey: String
    /// "A, B"처럼 여러 명이면 한 사람씩 (아티스트 순위·발견은 사람 단위로 센다)
    let artists: [(key: String, name: String)]
    let trackKey: String
    let albumKey: String

    init(_ event: PlayEvent, calendar: Calendar, artistNames: [String]? = nil) {
        date = event.date
        seconds = event.seconds
        trackID = event.trackID
        title = event.trackTitle
        artist = event.artistName
        album = event.albumTitle
        albumArtist = event.albumArtistName
        artwork = event.artworkFile

        let c = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: event.date)
        day = StatsCalendar.dayIndex(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
        weekday = ((c.weekday ?? 1) + 5) % 7
        hour = c.hour ?? 0
        month = (c.year ?? 2000) * 12 + (c.month ?? 1) - 1

        artistKey = event.artistName.lowercased()
        let names = artistNames ?? NameSplitter.artists(event.artistName)
        artists = (names.isEmpty ? [event.artistName] : names).map { ($0.libraryKey, $0.nfc) }
        trackKey = "\(event.artistName.libraryKey)\u{1F}\(event.trackTitle.libraryKey)"
        albumKey = Album.makeKey(title: event.albumTitle, artist: event.albumArtistName)
    }
}

/// 날짜 번호 ↔ 날짜 바꾸기
enum StatsCalendar {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 월요일부터 시작하는 기기 달력
    static var local: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    static func dayIndex(year: Int, month: Int, day: Int) -> Int {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }

    static func dayIndex(of date: Date, calendar: Calendar = local) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return dayIndex(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }

    static func date(ofDay index: Int, calendar: Calendar = local) -> Date {
        let u = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(index) * 86_400))
        return calendar.date(from: DateComponents(year: u.year, month: u.month, day: u.day)) ?? .now
    }

    /// 월요일 = 0
    static func weekday(ofDay index: Int) -> Int {
        // 1970-01-01은 목요일(3)
        ((index % 7) + 7 + 3) % 7
    }

    static func today(_ now: Date = .now) -> Int { dayIndex(of: now) }
}

/// 기록 전체. 오래된 순으로 정렬해 둔다.
struct StatsLibrary {
    let plays: [Play]

    static let empty = StatsLibrary(plays: [])

    init(plays: [Play]) { self.plays = plays }

    init(events: [PlayEvent]) {
        let calendar = StatsCalendar.local
        var cache: [String: [String]] = [:]
        plays = events.map { event in
            let names = cache[event.artistName] ?? NameSplitter.artists(event.artistName)
            cache[event.artistName] = names
            return Play(event, calendar: calendar, artistNames: names)
        }.sorted { $0.date < $1.date }
    }

    var isEmpty: Bool { plays.isEmpty }
    var firstDate: Date? { plays.first?.date }

    /// [start, end) 부분만 (이진 탐색)
    func slice(from start: Date?, to end: Date? = nil) -> ArraySlice<Play> {
        let lower = start.map(bound) ?? 0
        let upper = end.map(bound) ?? plays.count
        return plays[lower..<max(lower, upper)]
    }

    private func bound(_ date: Date) -> Int {
        var lo = 0, hi = plays.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if plays[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: 기간

enum StatsPeriod: String, CaseIterable, Identifiable {
    case week = "이번 주", month = "이번 달", year = "올해", all = "전체"
    var id: String { rawValue }

    /// 이번 주는 월요일 0시부터. 전체는 nil
    func start(now: Date = .now) -> Date? {
        let calendar = StatsCalendar.local
        switch self {
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return calendar.dateInterval(of: .month, for: now)?.start
        case .year: return calendar.dateInterval(of: .year, for: now)?.start
        case .all: return nil
        }
    }

    /// "이번 주에 42곡, 약 3시간 들었어요"의 앞부분
    var sentencePrefix: String {
        switch self {
        case .week: "이번 주에"
        case .month: "이번 달에"
        case .year: "올해"
        case .all: "지금까지"
        }
    }
}

// MARK: 순위

enum RankKind: String, CaseIterable, Identifiable {
    case tracks = "곡", albums = "앨범", artists = "아티스트"
    var id: String { rawValue }
}

struct RankItem: Identifiable {
    let key: String
    var title: String
    var subtitle: String
    var artwork: String?
    var trackID: UUID?
    var count: Int
    var seconds: Double
    var last: Date
    var id: String { key }
}

enum StatsMath {
    static func totalSeconds<S: Sequence>(_ plays: S) -> Double where S.Element == Play {
        plays.reduce(0) { $0 + $1.seconds }
    }

    /// 많이 들은 순. 횟수가 같으면 최근에 들은 쪽이 위
    static func rank<S: Sequence>(_ plays: S, by kind: RankKind, limit: Int = 50) -> [RankItem] where S.Element == Play {
        var table: [String: RankItem] = [:]
        if kind == .artists {
            for play in plays {
                for person in play.artists {
                    if var item = table[person.key] {
                        item.count += 1
                        item.seconds += play.seconds
                        item.last = play.date
                        item.title = person.name
                        table[person.key] = item
                    } else {
                        table[person.key] = RankItem(key: person.key, title: person.name, subtitle: "", artwork: play.artwork,
                                                     trackID: nil, count: 1, seconds: play.seconds, last: play.date)
                    }
                }
            }
            return Array(table.values.sorted { ($0.count, $0.last) > ($1.count, $1.last) }.prefix(limit))
        }
        for play in plays {
            let key: String
            switch kind {
            case .tracks: key = play.trackKey
            case .albums: key = play.albumKey
            case .artists: key = play.artistKey
            }
            if var item = table[key] {
                item.count += 1
                item.seconds += play.seconds
                item.last = play.date
                // 이름·커버는 가장 최근 기록 것을 쓴다.
                switch kind {
                case .tracks: item.title = play.title; item.subtitle = play.artist; item.trackID = play.trackID
                case .albums: item.title = play.album; item.subtitle = play.albumArtist
                case .artists: item.title = play.artist
                }
                if play.artwork != nil { item.artwork = play.artwork }
                table[key] = item
            } else {
                switch kind {
                case .tracks:
                    table[key] = RankItem(key: key, title: play.title, subtitle: play.artist, artwork: play.artwork,
                                          trackID: play.trackID, count: 1, seconds: play.seconds, last: play.date)
                case .albums:
                    table[key] = RankItem(key: key, title: play.album, subtitle: play.albumArtist, artwork: play.artwork,
                                          trackID: nil, count: 1, seconds: play.seconds, last: play.date)
                case .artists:
                    table[key] = RankItem(key: key, title: play.artist, subtitle: "", artwork: play.artwork,
                                          trackID: nil, count: 1, seconds: play.seconds, last: play.date)
                }
            }
        }
        return Array(table.values.sorted { ($0.count, $0.last) > ($1.count, $1.last) }.prefix(limit))
    }

    // MARK: 패턴

    static func dailyCounts<S: Sequence>(_ plays: S) -> [Int: Int] where S.Element == Play {
        var counts: [Int: Int] = [:]
        for play in plays { counts[play.day, default: 0] += 1 }
        return counts
    }

    /// [요일 7][시간 24] 청취 수 (월요일 = 0)
    static func weekdayHourMatrix<S: Sequence>(_ plays: S) -> [[Int]] where S.Element == Play {
        var matrix = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for play in plays { matrix[play.weekday][play.hour] += 1 }
        return matrix
    }

    /// 0이 아닌 값들의 사분위로 0~4단계 농도 (몇몇 큰 값에 나머지가 묻히지 않게)
    static func makeLevel(_ values: [Int]) -> (Int) -> Int {
        let nonzero = values.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return { _ in 0 } }
        func q(_ p: Double) -> Int { nonzero[min(nonzero.count - 1, Int(p * Double(nonzero.count)))] }
        let q1 = q(0.25), q2 = q(0.5), q3 = q(0.75)
        return { v in v <= 0 ? 0 : v <= q1 ? 1 : v <= q2 ? 2 : v <= q3 ? 3 : 4 }
    }

    struct DayRun { let days: Int; let start: Int; let end: Int }

    struct Streaks {
        var current: Int
        var listenedToday: Bool
        var longest: DayRun?
    }

    /// 연속으로 음악을 들은 날
    static func listeningStreaks(_ plays: [Play], today: Int = StatsCalendar.today()) -> Streaks {
        let days = Set(plays.map(\.day)).sorted()
        guard let first = days.first else { return Streaks(current: 0, listenedToday: false, longest: nil) }
        var longest = DayRun(days: 1, start: first, end: first)
        var runStart = first
        for i in days.indices.dropFirst() {
            if days[i] != days[i - 1] + 1 { runStart = days[i] }
            let length = days[i] - runStart + 1
            if length >= longest.days { longest = DayRun(days: length, start: runStart, end: days[i]) }
        }
        // 오늘 또는 어제까지 이어지고 있으면 "현재 연속"
        let set = Set(days)
        var cursor = set.contains(today) ? today : today - 1
        var current = 0
        while set.contains(cursor) {
            current += 1
            cursor -= 1
        }
        return Streaks(current: current, listenedToday: set.contains(today), longest: longest)
    }

    struct Repeat { let title: String; let artist: String; let count: Int; let date: Date }

    /// 한 곡을 중간에 다른 곡 없이 연달아 가장 많이 들은 기록
    static func longestRepeat(_ plays: [Play]) -> Repeat? {
        var best: Repeat?
        var run = 0
        var previous: String?
        var runStart = Date.distantPast
        for play in plays {
            if play.trackKey == previous {
                run += 1
            } else {
                run = 1
                previous = play.trackKey
                runStart = play.date
            }
            if run >= 2, run >= (best?.count ?? 0) {
                best = Repeat(title: play.title, artist: play.artist, count: run, date: runStart)
            }
        }
        return best
    }

    struct ArtistRun { let artist: String; let days: Int; let start: Int; let end: Int }

    /// 한 아티스트를 가장 여러 날 연속으로 들은 기록 (이틀 이상)
    static func longestArtistStreak(_ plays: [Play]) -> ArtistRun? {
        var byArtist: [String: (name: String, days: Set<Int>)] = [:]
        for play in plays {
            for person in play.artists {
                byArtist[person.key, default: (name: person.name, days: [])].days.insert(play.day)
                byArtist[person.key]?.name = person.name
            }
        }
        var best: ArtistRun?
        for (_, entry) in byArtist {
            let sorted = entry.days.sorted()
            guard var runStart = sorted.first else { continue }
            for i in sorted.indices {
                if i > 0, sorted[i] != sorted[i - 1] + 1 { runStart = sorted[i] }
                let length = sorted[i] - runStart + 1
                if best == nil || length > best!.days || (length == best!.days && sorted[i] > best!.end) {
                    best = ArtistRun(artist: entry.name, days: length, start: runStart, end: sorted[i])
                }
            }
        }
        return (best?.days ?? 0) >= 2 ? best : nil
    }

    // MARK: 발견

    struct Discovery: Identifiable {
        let key: String
        let artist: String
        let first: Date
        var count: Int
        var id: String { key }
    }

    /// 기록 전체에서 처음 들은 때가 [start, end) 안에 있는 아티스트
    static func newArtists(_ plays: [Play], start: Date, end: Date?) -> [Discovery] {
        func inRange(_ date: Date) -> Bool { date >= start && (end == nil || date < end!) }
        var first: [String: Discovery] = [:]
        var counts: [String: Int] = [:]
        for play in plays {
            for person in play.artists {
                if first[person.key] == nil {
                    first[person.key] = Discovery(key: person.key, artist: person.name, first: play.date, count: 0)
                }
                if inRange(play.date) { counts[person.key, default: 0] += 1 }
            }
        }
        return first.values
            .filter { inRange($0.first) }
            .map { var d = $0; d.count = counts[d.key] ?? 0; return d }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
    }

    struct MonthRanking: Identifiable {
        struct Entry { let key: String; var artist: String; var count: Int; var last: Date }
        let month: Int
        let total: Int
        let ranking: [Entry]
        var id: Int { month }
        var year: Int { month / 12 }
        var monthOfYear: Int { month % 12 + 1 }
    }

    /// 첫 기록이 있는 달부터 이번 달까지, 달마다 아티스트 순위 (빈 달 포함)
    static func monthlyTopArtists(_ plays: [Play], now: Date = .now, top: Int = 5) -> [MonthRanking] {
        guard let firstMonth = plays.first?.month else { return [] }
        var months: [Int: [String: MonthRanking.Entry]] = [:]
        for play in plays {
            for person in play.artists {
                if var entry = months[play.month]?[person.key] {
                    entry.count += 1
                    entry.artist = person.name
                    entry.last = play.date
                    months[play.month]![person.key] = entry
                } else {
                    months[play.month, default: [:]][person.key] =
                        .init(key: person.key, artist: person.name, count: 1, last: play.date)
                }
            }
        }
        let c = StatsCalendar.local.dateComponents([.year, .month], from: now)
        let lastMonth = max((c.year ?? 2000) * 12 + (c.month ?? 1) - 1, firstMonth)
        return (firstMonth...lastMonth).map { m in
            let artists = months[m].map { Array($0.values) } ?? []
            let ranking = artists.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
            return MonthRanking(month: m, total: artists.reduce(0) { $0 + $1.count }, ranking: Array(ranking.prefix(top)))
        }
    }

    struct ChartArtist: Identifiable { let key: String; var artist: String; var total: Int; var id: String { key } }

    /// 그래프에 그릴 아티스트: 어느 달이든 3위 안에 든 적 있는 아티스트를 많이 들은 순으로
    static func chartArtists(_ months: [MonthRanking], max: Int = 8) -> [ChartArtist] {
        var totals: [String: (artist: ChartArtist, top3: Bool)] = [:]
        for month in months {
            for (i, entry) in month.ranking.enumerated() {
                var item = totals[entry.key] ?? (artist: ChartArtist(key: entry.key, artist: entry.artist, total: 0), top3: false)
                item.artist.total += entry.count
                item.artist.artist = entry.artist
                if i < 3 { item.top3 = true }
                totals[entry.key] = item
            }
        }
        return Array(totals.values.filter(\.top3).map(\.artist).sorted { $0.total > $1.total }.prefix(max))
    }
}

// MARK: 돌아보기 (Wrapped)

enum RecapRange: String, CaseIterable, Identifiable {
    case thisMonth = "이번 달", lastMonth = "지난 달", thisYear = "올해", custom = "직접 고르기"
    var id: String { rawValue }
}

struct RecapPeriod: Equatable {
    let start: Date
    let end: Date
    let title: String
    let rangeText: String

    static func resolve(_ range: RecapRange, from: Date, to: Date, now: Date = .now) -> RecapPeriod? {
        let calendar = StatsCalendar.local
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let thisMonth = calendar.dateInterval(of: .month, for: now)!.start
        let c = calendar.dateComponents([.year, .month], from: now)

        let start: Date, end: Date, title: String
        switch range {
        case .thisMonth:
            start = thisMonth; end = tomorrow
            title = "\(c.year!)년 \(c.month!)월의 음악"
        case .lastMonth:
            start = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
            end = thisMonth
            let p = calendar.dateComponents([.year, .month], from: start)
            title = "\(p.year!)년 \(p.month!)월의 음악"
        case .thisYear:
            start = calendar.dateInterval(of: .year, for: now)!.start; end = tomorrow
            title = "\(c.year!)년의 음악"
        case .custom:
            start = calendar.startOfDay(for: from)
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
            title = "내가 고른 기간의 음악"
        }
        guard start < end else { return nil }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: end)!
        let rangeText = lastDay <= start
            ? StatsFormat.date(start, now: now)
            : "\(StatsFormat.date(start, now: now))부터 \(StatsFormat.date(lastDay, now: now))까지"
        return RecapPeriod(start: start, end: end, title: title, rangeText: rangeText)
    }
}

struct Recap {
    struct ArtistDetail { let count: Int; let share: Double; let seconds: Double; let days: Int; let tracks: [RankItem] }
    struct TrackDetail { let count: Int; let seconds: Double; let days: Int; let first: Date; let last: Date }

    let plays: Int
    let seconds: Double
    let dailyAverage: Double
    let days: Int
    let activeDays: Int
    let topDay: (date: Date, count: Int)?
    let peak: (weekday: Int, hour: Int, count: Int)?
    let topArtists: [RankItem]
    let topTracks: [RankItem]
    let artistDetails: [String: ArtistDetail]
    let trackDetails: [String: TrackDetail]
    let newArtistCount: Int
    let newArtistTop: [StatsMath.Discovery]

    init?(library: StatsLibrary, period: RecapPeriod, now: Date = .now) {
        let list = Array(library.slice(from: period.start, to: period.end))
        guard !list.isEmpty else { return nil }

        plays = list.count
        seconds = StatsMath.totalSeconds(list)
        let effectiveEnd = min(period.end, now)
        days = max(1, Int(ceil(effectiveEnd.timeIntervalSince(period.start) / 86_400)))
        dailyAverage = seconds / Double(days)

        let perDay = StatsMath.dailyCounts(list)
        activeDays = perDay.count
        topDay = perDay.max { ($0.value, -$0.key) < ($1.value, -$1.key) }
            .map { (date: StatsCalendar.date(ofDay: $0.key), count: $0.value) }

        var slots: [Int: Int] = [:]
        for play in list { slots[play.weekday * 24 + play.hour, default: 0] += 1 }
        peak = slots.max { ($0.value, -$0.key) < ($1.value, -$1.key) }
            .map { (weekday: $0.key / 24, hour: $0.key % 24, count: $0.value) }

        let discovered = StatsMath.newArtists(library.plays, start: period.start, end: period.end)
        newArtistCount = discovered.count
        newArtistTop = Array(discovered.prefix(3))

        topArtists = StatsMath.rank(list, by: .artists, limit: 5)
        topTracks = StatsMath.rank(list, by: .tracks, limit: 5)

        var artistDetails: [String: ArtistDetail] = [:]
        for artist in topArtists {
            let sub = list.filter { $0.artists.contains { $0.key == artist.key } }
            artistDetails[artist.key] = ArtistDetail(
                count: sub.count,
                share: Double(sub.count) / Double(list.count),
                seconds: StatsMath.totalSeconds(sub),
                days: Set(sub.map(\.day)).count,
                tracks: StatsMath.rank(sub, by: .tracks, limit: 3)
            )
        }
        self.artistDetails = artistDetails

        var trackDetails: [String: TrackDetail] = [:]
        for track in topTracks {
            let sub = list.filter { $0.trackKey == track.key }
            guard let first = sub.first, let last = sub.last else { continue }
            trackDetails[track.key] = TrackDetail(count: sub.count, seconds: StatsMath.totalSeconds(sub),
                                                  days: Set(sub.map(\.day)).count, first: first.date, last: last.date)
        }
        self.trackDetails = trackDetails
    }
}

// MARK: 표시 형식

enum StatsFormat {
    static let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ko_KR")
        return f
    }()

    static func number(_ n: Int) -> String { numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// "45분", "3시간 12분", "120시간"
    static func duration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes)분" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 100 || minutes == 0 { return "\(number(hours))시간" }
        return "\(hours)시간 \(minutes)분"
    }

    /// "9월 3일" (올해가 아니면 "2025년 9월 3일")
    static func date(_ date: Date, now: Date = .now) -> String {
        let calendar = StatsCalendar.local
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = "\(c.month!)월 \(c.day!)일"
        return c.year == calendar.component(.year, from: now) ? md : "\(c.year!)년 \(md)"
    }

    static func day(_ index: Int) -> String { date(StatsCalendar.date(ofDay: index)) }

    static func dayRange(_ start: Int, _ end: Int) -> String {
        start == end ? day(start) : "\(day(start))부터 \(day(end))까지"
    }

    /// 0 → "오전 12시", 13 → "오후 1시"
    static func hour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(hour < 12 ? "오전" : "오후") \(h)시"
    }

    /// "방금", "5분 전", "3시간 전", "2일 전", "9월 3일"
    static func ago(_ date: Date, now: Date = .now) -> String {
        let diff = max(0, Int(now.timeIntervalSince(date)))
        if diff < 60 { return "방금" }
        if diff < 3600 { return "\(diff / 60)분 전" }
        if diff < 86_400 { return "\(diff / 3600)시간 전" }
        if diff < 7 * 86_400 { return "\(diff / 86_400)일 전" }
        return self.date(date, now: now)
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}
