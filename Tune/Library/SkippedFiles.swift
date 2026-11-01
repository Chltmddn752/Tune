import Foundation

/// 중복이라 건너뛴 파일을 기억한다.
///
/// 경로·크기·수정 시각을 저장해 두고, 다음 스캔에서 같은 파일이면 메타데이터를 다시 읽지 않는다.
/// 파일이 바뀌면(크기나 수정 시각이 다르면) 기억을 지우고 다시 검사한다.
struct SkippedAudioFile: Codable, Identifiable, Hashable {
    var relativePath: String
    var signature: String
    var name: String
    /// "중복" | "읽지 못함"
    var reason: String
    var skippedAt: Date

    var id: String { relativePath }
}

enum SkippedFileStore {
    private static let defaultsKey = "skippedAudioFiles"

    static func all() -> [String: SkippedAudioFile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([String: SkippedAudioFile].self, from: data) else { return [:] }
        return saved
    }

    static func signature(for file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size)|\(Int(modified))"
    }

    /// 같은 파일을 이미 건너뛴 적이 있으면 그 기록을 돌려준다. 파일이 바뀌었으면 지운다.
    static func match(_ file: URL, relative: String) -> SkippedAudioFile? {
        var store = all()
        guard let saved = store[relative] else { return nil }
        guard saved.signature == signature(for: file) else {
            store.removeValue(forKey: relative)
            save(store)
            return nil
        }
        return saved
    }

    static func remember(_ file: URL, relative: String, reason: String) {
        var store = all()
        store[relative] = SkippedAudioFile(
            relativePath: relative,
            signature: signature(for: file),
            name: file.lastPathComponent,
            reason: reason,
            skippedAt: .now
        )
        // 오래된 기록은 500개까지만 남긴다.
        if store.count > 500 {
            let keep = store.values.sorted { $0.skippedAt > $1.skippedAt }.prefix(500)
            store = Dictionary(uniqueKeysWithValues: keep.map { ($0.relativePath, $0) })
        }
        save(store)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func save(_ store: [String: SkippedAudioFile]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
