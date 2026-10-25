import Foundation

/// 앱과 위젯이 함께 쓰는 공유 폴더.
/// SideStore가 다시 서명할 때 그룹 ID가 바뀔 수 있어서 Info.plist의 ALTAppGroups 값을 먼저 읽는다.
enum AppGroup {
    static let defaultID = "group.com.chltmddn752.tune"

    /// 실제로 쓸 수 있는 그룹 ID.
    /// SideStore는 다시 서명할 때 그룹 ID 뒤에 팀 ID 등을 붙여 바꾸는데, Info.plist가 그대로일 때가 있다.
    /// 그래서 ① 서명 파일(embedded.mobileprovision)에 실제로 들어간 그룹 ② ALTAppGroups ③ 기본값 순서로
    /// 열어 보고, 공유 폴더가 실제로 열리는 첫 번째 것을 쓴다(앱과 위젯이 같은 규칙으로 같은 그룹을 고른다).
    static let identifier: String = {
        for candidate in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
            return candidate
        }
        return candidates.first ?? defaultID
    }()

    /// 확인해 본 그룹 ID 후보 (설정 화면에 진단용으로 보여 준다)
    static var candidates: [String] {
        var list: [String] = provisionedGroups()
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            list += groups.filter { !$0.isEmpty }
        }
        list.append(defaultID)
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// 서명 파일 안의 권한 목록에서 그룹 ID를 읽는다.
    private static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return [] }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        // 와일드카드("group.*")는 쓸 수 없으니 뺀다.
        return groups.filter { !$0.contains("*") }
    }

    /// 공유 폴더를 못 쓰면 앱 자체 폴더로 대신한다(위젯만 비게 됨).
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// 공유 폴더를 못 쓰던 때 앱 자체 폴더에 저장한 커버·사진을 공유 폴더로 옮긴다.
    /// (공유 폴더가 새로 열리면 커버가 전부 안 보이던 문제)
    static func migrateFallbackIfNeeded() {
        guard isShared else { return }
        let fm = FileManager.default
        let fallbackRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // 앱 자체 폴더 + 예전에 쓰던 다른 그룹 폴더들
        var oldRoots = [fallbackRoot]
        for candidate in candidates where candidate != identifier {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: candidate) { oldRoots.append(url) }
        }
        let destination = artworkDirectory
        for root in oldRoots {
            let oldArtwork = root.appendingPathComponent("Artwork", isDirectory: true)
            guard oldArtwork.standardizedFileURL != destination.standardizedFileURL,
                  let files = try? fm.contentsOfDirectory(at: oldArtwork, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: file)
                } else if (try? fm.moveItem(at: file, to: target)) == nil {
                    try? fm.copyItem(at: file, to: target)
                }
            }
        }
        let oldState = fallbackRoot.appendingPathComponent("now-playing.json")
        if fm.fileExists(atPath: oldState.path), !fm.fileExists(atPath: stateURL.path) {
            try? fm.moveItem(at: oldState, to: stateURL)
        }
    }

    static var isShared: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }

    static var artworkDirectory: URL {
        let url = containerURL.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var stateURL: URL {
        containerURL.appendingPathComponent("now-playing.json")
    }
}
