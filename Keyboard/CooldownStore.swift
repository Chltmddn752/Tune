import Foundation
import UserNotifications

/// 키보드 버튼을 누른 시각을 기준으로 쿨타임을 재는 저장소.
/// 키보드 확장 자체의 UserDefaults에만 저장.
final class CooldownStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private let readyKey = "cooldown.readyAt"
    private let statsKey = "stats.daily"

    // MARK: 설정

    @Published var area: Int { didSet { defaults.set(area, forKey: "area") } }
    /// EPIC RPG 도네이터 쿨타임 감소 % (0, 10, 20, 35)
    @Published var donorPercent: Int { didSet { defaults.set(donorPercent, forKey: "donorPercent") } }
    /// 이벤트 쿨타임 감소 % (Navi의 multiplier 설정과 같은 역할)
    @Published var eventPercent: Int { didSet { defaults.set(eventPercent, forKey: "eventPercent") } }
    /// hunt 대신 hunt together(rpg hunt t) 추천
    @Published var huntTogether: Bool { didSet { defaults.set(huntTogether, forKey: "huntTogether") } }
    /// adventure 뒤에 heal 추천 (Navi의 heal warning)
    @Published var healWarning: Bool { didSet { defaults.set(healWarning, forKey: "healWarning") } }
    /// 준비되면 알림 (실험적, 전체 접근 허용 필요)
    @Published var notify: Bool {
        didSet {
            defaults.set(notify, forKey: "notify")
            if !notify { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
        }
    }
    /// 추천 탭에서 숨길 쿨타임 (Navi의 reminder on/off)
    @Published var hidden: Set<CooldownKey> {
        didSet { defaults.set(hidden.map(\.rawValue), forKey: "hidden") }
    }

    // MARK: 상태

    @Published private(set) var readyAt: [CooldownKey: Date] = [:]
    @Published private(set) var healPinnedUntil: Date?
    /// 날짜("yyyy-MM-dd") → 명령어 → 횟수
    @Published private(set) var stats: [String: [String: Int]] = [:]

    private var lastStart: (key: CooldownKey, previous: Date?, at: Date)?

    init() {
        let savedArea = defaults.integer(forKey: "area")
        area = savedArea == 0 ? 1 : savedArea
        donorPercent = defaults.integer(forKey: "donorPercent")
        eventPercent = defaults.integer(forKey: "eventPercent")
        huntTogether = defaults.bool(forKey: "huntTogether")
        healWarning = defaults.object(forKey: "healWarning") as? Bool ?? true
        notify = defaults.bool(forKey: "notify")
        hidden = Set((defaults.stringArray(forKey: "hidden") ?? []).compactMap(CooldownKey.init(rawValue:)))

        if let raw = defaults.dictionary(forKey: readyKey) as? [String: Double] {
            for (k, v) in raw {
                if let key = CooldownKey(rawValue: k) {
                    readyAt[key] = Date(timeIntervalSince1970: v)
                }
            }
        }
        stats = defaults.dictionary(forKey: statsKey) as? [String: [String: Int]] ?? [:]
    }

    // MARK: 쿨타임

    func duration(_ key: CooldownKey) -> TimeInterval {
        guard key.affectedByDonor else { return key.base }
        let donor = 1 - Double(donorPercent) / 100
        let event = 1 - Double(eventPercent) / 100
        return key.base * donor * event
    }

    func remaining(_ key: CooldownKey, now: Date) -> TimeInterval {
        guard let date = readyAt[key] else { return 0 }
        return max(0, date.timeIntervalSince(now))
    }

    func isReady(_ key: CooldownKey, now: Date) -> Bool {
        remaining(key, now: now) <= 0
    }

    func isHealPinned(now: Date) -> Bool {
        guard healWarning, let until = healPinnedUntil else { return false }
        return until > now
    }

    /// 명령어 버튼을 눌렀을 때 호출
    func didTap(_ cmd: Cmd) {
        record(cmd.label)

        if cmd.text == "rpg heal" { healPinnedUntil = nil }

        guard let key = cmd.cd else { return }
        let now = Date()
        lastStart = (key, readyAt[key], now)
        let ready = now.addingTimeInterval(duration(key))
        readyAt[key] = ready
        save()
        scheduleNotification(key, at: ready)

        // adventure 뒤에는 2분 동안 heal을 맨 앞에 추천
        if key == .adventure { healPinnedUntil = now.addingTimeInterval(120) }
    }

    /// 30초 안에 '전체 지움'을 누르면 방금 시작한 쿨타임을 취소
    func undoLastIfRecent() {
        guard let last = lastStart, Date().timeIntervalSince(last.at) < 30 else { return }
        readyAt[last.key] = last.previous
        if last.key == .adventure { healPinnedUntil = nil }
        lastStart = nil
        save()
        cancelNotification(last.key)
        if let prev = last.previous, prev > Date() { scheduleNotification(last.key, at: prev) }
    }

    /// 타이머가 실제와 다를 때 '준비됨'으로 바꾸기
    func markReady(_ key: CooldownKey) {
        readyAt[key] = nil
        save()
        cancelNotification(key)
    }

    func resetAll() {
        readyAt = [:]
        lastStart = nil
        healPinnedUntil = nil
        save()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func toggleHidden(_ key: CooldownKey) {
        if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
    }

    private func save() {
        var raw: [String: Double] = [:]
        for (k, v) in readyAt { raw[k.rawValue] = v.timeIntervalSince1970 }
        defaults.set(raw, forKey: readyKey)
    }

    // MARK: 알림 (실험적)

    private func scheduleNotification(_ key: CooldownKey, at date: Date) {
        guard notify, !hidden.contains(key) else { return }
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(key.title) 준비됨"
        content.body = "EPIC RPG \(key.title) 쿨타임이 끝났어"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "cd.\(key.rawValue)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func cancelNotification(_ key: CooldownKey) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["cd.\(key.rawValue)"])
    }

    // MARK: 통계 (Navi의 /stats 같은 사용 기록)

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func record(_ label: String) {
        let today = Self.dayKey(Date())
        var day = stats[today] ?? [:]
        day[label, default: 0] += 1
        stats[today] = day

        // 최근 7일만 보관
        let keep = Set((0..<7).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date()).map(Self.dayKey)
        })
        stats = stats.filter { keep.contains($0.key) }
        defaults.set(stats, forKey: statsKey)
    }

    func todayStats() -> [(String, Int)] {
        (stats[Self.dayKey(Date())] ?? [:]).sorted { $0.value > $1.value }
    }

    func weekStats() -> [(String, Int)] {
        var total: [String: Int] = [:]
        for day in stats.values {
            for (k, v) in day { total[k, default: 0] += v }
        }
        return total.sorted { $0.value > $1.value }
    }

    func clearStats() {
        stats = [:]
        defaults.set(stats, forKey: statsKey)
    }
}

enum TimeText {
    static func short(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return "\(d)일 \(h)시간" }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
