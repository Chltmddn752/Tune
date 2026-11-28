import Foundation

/// 쿨타임을 공유하는 명령어 묶음.
/// ✏️ 쿨타임(base)이 실제와 다르면 여기 숫자만 고치면 돼. (단위: 초)
enum CooldownKey: String, CaseIterable {
    case hunt, adventure, training, work, farm, quest
    case daily, weekly, vote, lootbox
    case dungeon   // dungeon·miniboss 공유
    case arena, horse, duel, guildRaid

    var title: String {
        switch self {
        case .hunt: return "hunt"
        case .adventure: return "adv"
        case .training: return "training"
        case .work: return "작업"
        case .farm: return "farm"
        case .quest: return "quest"
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .vote: return "vote"
        case .lootbox: return "lootbox 구매"
        case .dungeon: return "dungeon/miniboss"
        case .arena: return "arena"
        case .horse: return "horse"
        case .duel: return "duel"
        case .guildRaid: return "guild raid"
        }
    }

    var base: TimeInterval {
        switch self {
        case .hunt: return 60
        case .adventure: return 3600
        case .training: return 15 * 60
        case .work: return 5 * 60
        case .farm: return 10 * 60
        case .quest: return 6 * 3600
        case .daily: return 23 * 3600 + 50 * 60
        case .weekly: return 7 * 24 * 3600
        case .vote: return 12 * 3600
        case .lootbox: return 3 * 3600
        case .dungeon: return 12 * 3600
        case .arena: return 24 * 3600
        case .horse: return 24 * 3600
        case .duel: return 2 * 3600
        case .guildRaid: return 2 * 3600
        }
    }

    /// 도네이터 쿨타임 감소가 적용되는지 (대략적인 값)
    var affectedByDonor: Bool {
        switch self {
        case .daily, .weekly, .vote, .guildRaid: return false
        default: return true
        }
    }
}

/// 키보드에 표시될 명령어 버튼 하나.
struct Cmd: Hashable {
    let label: String     // 버튼에 보이는 글자
    let text: String      // 입력창에 들어가는 글자
    let cd: CooldownKey?  // 누르면 시작되는 쿨타임 (없으면 nil)
    let minArea: Int      // 이 지역부터 추천

    init(_ label: String, _ text: String, cd: CooldownKey? = nil, area: Int = 1) {
        self.label = label
        self.text = text
        self.cd = cd
        self.minArea = area
    }
}

struct CommandGroup {
    let title: String
    let items: [Cmd]
}

/// ✏️ 명령어를 추가하거나 바꾸고 싶으면 이 목록만 고치면 돼.
enum Commands {
    // 자주 쓰는 명령어
    static let hunt = Cmd("hunt", "rpg hunt", cd: .hunt)
    static let huntT = Cmd("hunt t", "rpg hunt t", cd: .hunt)
    static let heal = Cmd("heal", "rpg heal")
    static let huntH = Cmd("hunt h", "rpg hunt h", cd: .hunt, area: 13)
    static let adv = Cmd("adv", "rpg adv", cd: .adventure)
    static let advH = Cmd("adv h", "rpg adv h", cd: .adventure, area: 14)
    static let training = Cmd("training", "rpg tr", cd: .training, area: 2)
    static let farm = Cmd("farm", "rpg farm", cd: .farm, area: 4)
    static let quest = Cmd("quest", "rpg quest", cd: .quest)
    static let daily = Cmd("daily", "rpg daily", cd: .daily)
    static let weekly = Cmd("weekly", "rpg weekly", cd: .weekly)
    static let vote = Cmd("vote", "rpg vote", cd: .vote)
    static let buyLootbox = Cmd("lootbox 구매", "rpg buy ", cd: .lootbox)
    static let dungeon = Cmd("dungeon", "rpg dungeon ", cd: .dungeon)
    static let miniboss = Cmd("miniboss", "rpg miniboss ", cd: .dungeon)
    static let arena = Cmd("arena", "rpg arena ", cd: .arena)
    static let horseBreed = Cmd("horse breed", "rpg horse breed ", cd: .horse)
    static let duel = Cmd("duel", "rpg duel ", cd: .duel)
    static let guildRaid = Cmd("guild raid", "rpg guild raid", cd: .guildRaid, area: 4)
    static let guildUpgrade = Cmd("guild upgrade", "rpg guild upgrade", cd: .guildRaid, area: 4)

    // 작업 명령어 4계열 (낮은 단계 → 높은 단계). 모두 쿨타임 공유.
    static let workLines: [[Cmd]] = [
        [Cmd("chop", "rpg chop", cd: .work, area: 1),
         Cmd("axe", "rpg axe", cd: .work, area: 3),
         Cmd("bowsaw", "rpg bowsaw", cd: .work, area: 6),
         Cmd("chainsaw", "rpg chainsaw", cd: .work, area: 9)],
        [Cmd("fish", "rpg fish", cd: .work, area: 1),
         Cmd("net", "rpg net", cd: .work, area: 3),
         Cmd("boat", "rpg boat", cd: .work, area: 6),
         Cmd("bigboat", "rpg bigboat", cd: .work, area: 9)],
        [Cmd("pickup", "rpg pickup", cd: .work, area: 3),
         Cmd("ladder", "rpg ladder", cd: .work, area: 4),
         Cmd("tractor", "rpg tractor", cd: .work, area: 8),
         Cmd("greenhouse", "rpg greenhouse", cd: .work, area: 11)],
        [Cmd("mine", "rpg mine", cd: .work, area: 5),
         Cmd("pickaxe", "rpg pickaxe", cd: .work, area: 6),
         Cmd("drill", "rpg drill", cd: .work, area: 10),
         Cmd("dynamite", "rpg dynamite", cd: .work, area: 12)],
    ]

    static let groups: [CommandGroup] = [
        CommandGroup(title: "⚔️ 기본", items: [
            hunt, adv, training, heal,
            Cmd("cd", "rpg cd"), Cmd("rd", "rpg rd"),
            Cmd("profile", "rpg p"), Cmd("inventory", "rpg i"),
            quest, daily, weekly, vote,
            Cmd("물약 구매", "rpg buy life potion "),
            huntH, advH, huntT,
        ]),
        CommandGroup(title: "🪓 작업", items: workLines.flatMap { $0 } + [farm]),
        CommandGroup(title: "🎒 아이템", items: [
            Cmd("lootbox", "rpg lb"), Cmd("open", "rpg open "), buyLootbox,
            Cmd("craft", "rpg craft "), Cmd("dismantle", "rpg dismantle "),
            Cmd("trade", "rpg trade"), Cmd("shop", "rpg shop"),
            Cmd("buy", "rpg buy "), Cmd("sell", "rpg sell "),
            Cmd("enchant 검", "rpg enchant sword"), Cmd("enchant 갑옷", "rpg enchant armor"),
            Cmd("refine 검", "rpg refine sword"), Cmd("refine 갑옷", "rpg refine armor"),
        ]),
        CommandGroup(title: "👥 파티", items: [
            dungeon, miniboss, arena, duel,
            Cmd("horse", "rpg horse"), horseBreed,
            Cmd("guild", "rpg guild"), guildRaid, guildUpgrade,
            Cmd("pets", "rpg pets"), Cmd("professions", "rpg pr"),
            Cmd("time travel", "rpg time travel"),
        ]),
        CommandGroup(title: "🎉 이벤트", items: [
            // 랜덤 이벤트 응답 단어. 이벤트 문구가 바뀌면 여기만 고치면 돼.
            Cmd("catch", "catch"), Cmd("chop", "chop"), Cmd("fish", "fish"),
            Cmd("summon", "summon"), Cmd("join", "join"),
            Cmd("time to fight", "time to fight"),
            Cmd("events", "rpg events"),
        ]),
    ]

    /// ⭐ 추천 탭 후보 (우선순위 순서). 내 area에서 쓸 수 있고 숨기지 않은 것만 남김.
    static func recommendations(area: Int,
                                huntTogether: Bool,
                                hidden: Set<CooldownKey>,
                                healFirst: Bool) -> [Cmd] {
        var list: [Cmd] = []
        if healFirst { list.append(heal) }
        list += [huntTogether ? huntT : hunt, adv, training]
        // 작업 계열마다 지금 area에서 가장 높은 단계 하나씩
        for line in workLines {
            if let best = line.last(where: { $0.minArea <= area }) {
                list.append(best)
            }
        }
        list += [farm, quest, daily, weekly, vote, buyLootbox,
                 horseBreed, arena, dungeon, miniboss, duel, guildRaid]
        return list.filter { cmd in
            guard cmd.minArea <= area else { return false }
            if let cd = cmd.cd, hidden.contains(cd) { return false }
            return true
        }
    }
}
