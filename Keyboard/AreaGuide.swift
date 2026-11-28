import Foundation

/// 지역별 요약 공략 (EPIC RPG 위키 정리).
/// Epic RPG Guide 봇의 $a1~$a15 지역 가이드를 키보드 안에서 바로 보는 용도.
struct AreaTip {
    let area: Int
    let unlocks: String
    let tips: [String]
}

enum AreaGuide {
    static let tips: [AreaTip] = [
        AreaTip(area: 1, unlocks: "hunt, adventure, chop, fish", tips: [
            "상점에서 Basic Armor(200) → Basic Sword(150) 순서로 사기 (방어가 더 중요)",
            "chop으로 나무를 모아 Wooden Sword(나무 15 + EPIC log 1)와 Fish Armor 제작",
            "레벨 5가 되면 상점에서 던전 열쇠를 사고 팀원과 D1 드래곤 잡기",
            "HP 낮으면 바로 heal. 죽으면 레벨 1 하락 (물약 25코인)",
        ]),
        AreaTip(area: 2, unlocks: "enchant, training, area", tips: [
            "training: 15분마다 안전하게 XP를 얻는 명령어",
            "enchant로 검·갑옷 강화. 결과는 랜덤이고 기존 인챈트를 덮어씀",
        ]),
        AreaTip(area: 3, unlocks: "axe, net, pickup", tips: [
            "이 지역은 교환비가 좋아서 재료를 전부 물고기로 바꿔두는 게 추천",
            "사과·바나나가 나오기 시작함",
        ]),
        AreaTip(area: 4, unlocks: "ladder, farm, guild", tips: [
            "A3에서 바꿔둔 물고기를 다시 나무로 바꾸면 나무가 약 2배",
            "guild 해금: 2시간마다 raid 또는 upgrade",
        ]),
        AreaTip(area: 5, unlocks: "mine, cook, multidice", tips: [
            "'파밍 지역': 여기서 나무→사과로 바꿔 많이 모아두기 (첫 회차 사과 16,000개 이상)",
            "추천 작업 명령어: axe (가끔 SUPER·EPIC log가 나와서 ladder보다 평균 이득)",
            "wolf·zombie·unicorn 드랍도 30개씩 모아두기",
        ]),
        AreaTip(area: 6, unlocks: "bowsaw, boat, pickaxe", tips: [
            "A5에서 모은 사과를 전부 나무로 교환 → 나무가 크게 늘어남",
            "사과는 A8에서 가치가 떨어지니 팔지 말고 나무로 바꾸기",
            "Coin Armor 제작. 이 지역은 빨리 넘어가기",
        ]),
        AreaTip(area: 7, unlocks: "refine, big arena", tips: [
            "남은 사과는 A8 가기 전에 전부 나무로",
            "D7 권장 스탯: ATK 257 / DEF 234 / LIFE 295",
        ]),
        AreaTip(area: 8, unlocks: "tractor", tips: [
            "사과 교환 가치가 떨어지는 지역 (A7까지 바꿔뒀어야 함)",
        ]),
        AreaTip(area: 9, unlocks: "chainsaw, bigboat", tips: [
            "ULTRA log가 나오기 시작함 (EDGY Sword 재료)",
        ]),
        AreaTip(area: 10, unlocks: "drill", tips: [
            "D10 입장에는 EDGY Armor와 EDGY Sword가 둘 다 필요 (EDGY Sword = 나무 1000 + ULTRA log 1)",
            "남은 바나나는 분해, 사과는 나무로",
            "작업: 코인 3천만 미만이면 drill, 이상이면 chainsaw",
            "D10은 파트너와 역할을 나눠 하는 스크립트형 던전",
        ]),
        AreaTip(area: 11, unlocks: "time travel, forge, greenhouse", tips: [
            "첫 타임트래블 전: 전부 분해하고 재료를 나무로 교환",
            "EPIC log를 500~1000개씩 제작→분해 반복해 Crafter 100 만들기",
            "TT 후 목표: 레벨 70, ULTRA-EDGY Sword 단조, HYPER 이상 인챈트",
        ]),
        AreaTip(area: 12, unlocks: "dynamite, pets, ultraining", tips: [
            "TT 이후로는 각 지역 던전에 타임트래블 횟수 조건이 붙음",
            "TT2부터 training 성공 시 4% 확률로 펫 등장",
        ]),
        AreaTip(area: 13, unlocks: "transmute, hunt hardmode", tips: [
            "hunt h: 보상이 크지만 피해도 큼",
        ]),
        AreaTip(area: 14, unlocks: "adventure hardmode", tips: [
            "D14: TT 10회 이상 + OMEGA 갑옷 + D14 열쇠(T6 이상 말이면 생략)",
        ]),
        AreaTip(area: 15, unlocks: "transcend", tips: [
            "D15: ULTRA-OMEGA 장비 + 종류별 T5 이상 펫 3마리 필요",
            "이후 SUPER time travel로 엔드게임 진입",
        ]),
    ]

    static func tip(for area: Int) -> AreaTip? {
        tips.last(where: { $0.area <= area })
    }

    static let general: [String] = [
        "교환비는 내 '최대 area'에 따라 달라짐 → 지역 이동 전에 rpg trade 확인",
        "4티어 이상 말이 있으면 죽어도 레벨이 안 떨어짐",
        "매크로·외부 현금거래·버그 악용은 정지 사유",
    ]
}
