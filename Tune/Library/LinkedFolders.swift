import Foundation
import Observation

/// 사용자가 파일 앱에서 고른 "연결한 폴더".
/// 파일을 앱 안으로 복사하지 않고 그 자리에서 재생한다. 폴더에 파일이 생기면 보관함에 넣고, 없어지면 뺀다.
///
/// 곡 경로는 "@link/<폴더 id>/<폴더 안 경로>"로 저장해서, 앱을 다시 켜도 북마크로 같은 폴더를 찾아간다.
struct LinkedFolder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bookmark: Data
}

@Observable
final class LinkedFolders {
    static let shared = LinkedFolders()
    static let prefix = "@link/"

    private(set) var folders: [LinkedFolder] = []
    /// 북마크를 풀어서 접근을 열어 둔 폴더 주소 (앱이 켜져 있는 동안 계속 열어 둔다)
    @ObservationIgnored private var resolved: [String: URL] = [:]
    @ObservationIgnored private let defaultsKey = "linkedFolders"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([LinkedFolder].self, from: data) {
            folders = saved
        }
        for folder in folders { resolve(folder) }
    }

    // MARK: 찾기

    func url(for id: String) -> URL? {
        if let url = resolved[id] { return url }
        guard let folder = folders.first(where: { $0.id == id }) else { return nil }
        return resolve(folder)
    }

    /// 지금 그 폴더를 읽을 수 있는지 (못 읽을 때는 곡을 지우지 않는다)
    func isReachable(_ id: String) -> Bool {
        guard let url = url(for: id) else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    func isLinked(_ id: String) -> Bool { folders.contains { $0.id == id } }

    /// 읽을 수 있는 연결 폴더들
    var reachable: [(folder: LinkedFolder, url: URL)] {
        folders.compactMap { folder in
            guard let url = url(for: folder.id), FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return (folder, url)
        }
    }

    /// 연결 폴더 안 파일이면 "@link/id/경로"
    func relativePath(for file: URL) -> String? {
        let path = file.standardizedFileURL.path
        for (id, base) in resolved {
            let basePath = base.standardizedFileURL.path
            if path.hasPrefix(basePath + "/") {
                return Self.prefix + id + "/" + String(path.dropFirst(basePath.count + 1))
            }
        }
        return nil
    }

    static func folderID(of relativePath: String) -> String? {
        guard relativePath.hasPrefix(prefix) else { return nil }
        return relativePath.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    func fileURL(forRelative relativePath: String) -> URL? {
        guard relativePath.hasPrefix(Self.prefix) else { return nil }
        let parts = relativePath.dropFirst(Self.prefix.count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let base = url(for: String(parts[0])) else { return nil }
        return base.appendingPathComponent(String(parts[1]))
    }

    // MARK: 연결 · 해제

    enum LinkError: LocalizedError {
        case insideApp, alreadyLinked, noAccess

        var errorDescription: String? {
            switch self {
            case .insideApp: "Tune 폴더 안의 폴더는 이미 자동으로 들어와요."
            case .alreadyLinked: "이미 연결한 폴더예요."
            case .noAccess: "이 폴더에 접근할 수 없어요. 다른 위치의 폴더를 골라 보세요."
            }
        }
    }

    @discardableResult
    func add(_ url: URL) throws -> LinkedFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        let path = url.standardizedFileURL.path
        if path.hasPrefix(LibraryPaths.documents.standardizedFileURL.path) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw LinkError.insideApp
        }
        if resolved.values.contains(where: { $0.standardizedFileURL.path == path }) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw LinkError.alreadyLinked
        }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw LinkError.noAccess
        }
        let folder = LinkedFolder(id: String(UUID().uuidString.prefix(8)), name: url.lastPathComponent, bookmark: bookmark)
        folders.append(folder)
        // 고를 때 열린 접근을 그대로 계속 쓴다.
        resolved[folder.id] = url
        save()
        return folder
    }

    func remove(_ id: String) {
        if let url = resolved.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        folders.removeAll { $0.id == id }
        save()
    }

    // MARK: 내부

    @discardableResult
    private func resolve(_ folder: LinkedFolder) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        resolved[folder.id] = url
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark = fresh
            save()
        }
        return url
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
