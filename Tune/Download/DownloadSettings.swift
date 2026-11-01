import Foundation
import Observation
import SwiftData

enum DownloadFolderStructure: String, Codable, CaseIterable, Identifiable {
    case flat, artistAlbum, artist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: "한 폴더에 모두"
        case .artistAlbum: "아티스트/앨범"
        case .artist: "아티스트"
        }
    }
}

enum DownloadFileNamePattern: String, Codable, CaseIterable, Identifiable {
    case artistTitle, numberTitle, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .artistTitle: "{아티스트} - {제목}"
        case .numberTitle: "{트랙번호} {제목}"
        case .title: "{제목}"
        }
    }
}

/// 다운로드한 파일을 어디에 어떤 구조·이름으로 둘지 정한다.
@MainActor
@Observable
final class DownloadSettings {
    static let shared = DownloadSettings()

    private struct Stored: Codable {
        var useLinkedFolder = false
        var tuneSubfolder = "다운로드"
        var linkedFolderID: String?
        var structure: DownloadFolderStructure = .flat
        var fileNamePattern: DownloadFileNamePattern = .artistTitle
    }

    private static let key = "downloadLocationSettings"

    var useLinkedFolder: Bool { didSet { save() } }
    var tuneSubfolder: String { didSet { save() } }
    var linkedFolderID: String? { didSet { save() } }
    var structure: DownloadFolderStructure { didSet { save() } }
    var fileNamePattern: DownloadFileNamePattern { didSet { save() } }

    private init() {
        let stored = Self.load()
        useLinkedFolder = stored.useLinkedFolder
        tuneSubfolder = stored.tuneSubfolder
        linkedFolderID = stored.linkedFolderID
        structure = stored.structure
        fileNamePattern = stored.fileNamePattern
    }

    // MARK: - 위치

    var tuneFolder: URL {
        let name = DownloadManager.safeFilename(tuneSubfolder.isEmpty ? "다운로드" : tuneSubfolder)
        let url = LibraryPaths.documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var linkedFolder: URL? {
        guard useLinkedFolder, let linkedFolderID, LinkedFolders.shared.isReachable(linkedFolderID) else { return nil }
        return LinkedFolders.shared.url(for: linkedFolderID)
    }

    /// 지금 실제로 저장할 폴더. 연결 폴더를 못 열면 Tune 폴더로 대신 받는다.
    var baseURL: URL { linkedFolder ?? tuneFolder }

    var isUsingFallback: Bool { useLinkedFolder && linkedFolder == nil }

    var displayPath: String {
        if useLinkedFolder {
            if let folder = LinkedFolders.shared.folders.first(where: { $0.id == linkedFolderID }) {
                return folder.name + (linkedFolder == nil ? " (열 수 없어 Tune 폴더)" : "")
            }
            return "연결 폴더 없음"
        }
        return "Tune/" + (tuneSubfolder.isEmpty ? "다운로드" : tuneSubfolder)
    }

    // MARK: - 파일 자리

    struct Placement {
        var artist: String
        var album: String
        var title: String
        var trackNumber: Int?
        var fileExtension: String
    }

    /// 같은 이름이 있으면 (2), (3)을 붙인 다음 빈 자리를 돌려준다. 폴더도 만든다.
    func destination(for placement: Placement) -> URL {
        let directory = directory(for: placement)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = placement.fileExtension.isEmpty ? "m4a" : placement.fileExtension.lowercased()
        let base = filename(for: placement)
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// 보관함으로 옮길 때 쓰는 폴더 구조.
    private func directory(for placement: Placement) -> URL {
        var url = baseURL
        switch structure {
        case .flat:
            break
        case .artist:
            url.appendPathComponent(DownloadManager.safeFilename(placement.artist), isDirectory: true)
        case .artistAlbum:
            url.appendPathComponent(DownloadManager.safeFilename(placement.artist), isDirectory: true)
            url.appendPathComponent(DownloadManager.safeFilename(placement.album), isDirectory: true)
        }
        return url
    }

    private func filename(for placement: Placement) -> String {
        let title = DownloadManager.safeFilename(placement.title)
        switch fileNamePattern {
        case .artistTitle:
            return DownloadManager.safeFilename("\(placement.artist) - \(title)")
        case .numberTitle:
            if let number = placement.trackNumber, number > 0 {
                return DownloadManager.safeFilename(String(format: "%02d %@", number, title))
            }
            return title
        case .title:
            return title
        }
    }

    // MARK: - 저장

    private func save() {
        let stored = Stored(
            useLinkedFolder: useLinkedFolder, tuneSubfolder: tuneSubfolder,
            linkedFolderID: linkedFolderID, structure: structure, fileNamePattern: fileNamePattern
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func load() -> Stored {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }
}

/// 저장 위치를 바꿀 때 기존에 받은 파일을 새 위치로 옮긴다.
@MainActor
enum DownloadRelocator {
    /// 예전 다운로드 폴더 아래에 있는 보관함 곡.
    static func downloadedTracks(under base: URL, context: ModelContext) -> [Track] {
        let prefix = base.standardizedFileURL.path + "/"
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        // 다운로드 기록이 있는 곡은 어디에 있든 옮긴다.
        let known = Set(DownloadManager.shared.jobs.compactMap(\.relativePath))
        // Tune 폴더 안의 다운로드 폴더라면 그 안의 곡은 전부 다운로드한 곡으로 본다.
        let insideDocuments = base.standardizedFileURL.path
            .hasPrefix(LibraryPaths.documents.standardizedFileURL.path + "/")
        return tracks.filter { track in
            guard track.fileURL.standardizedFileURL.path.hasPrefix(prefix) else { return false }
            return known.contains(track.relativePath) || insideDocuments
        }
    }

    static func move(_ tracks: [Track], context: ModelContext) async {
        guard !tracks.isEmpty else { return }
        let settings = DownloadSettings.shared
        let activityID = ActivityCenter.shared.begin(
            title: "다운로드 위치 옮기기", symbol: "folder", total: tracks.count
        )
        var moved = 0
        var failed: [String] = []
        for (index, track) in tracks.enumerated() {
            guard !Task.isCancelled else { break }
            ActivityCenter.shared.update(activityID, completed: index, total: tracks.count, detail: track.title)
            let source = track.fileURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                failed.append(track.title)
                continue
            }
            let destination = settings.destination(for: DownloadSettings.Placement(
                artist: track.artistName,
                album: track.albumTitle,
                title: track.title,
                trackNumber: track.trackNumber,
                fileExtension: source.pathExtension
            ))
            if source.standardizedFileURL == destination.standardizedFileURL { continue }
            do {
                let directory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                } catch {
                    // 외장·클라우드 폴더로 옮길 때는 복사 후 지운다.
                    try FileManager.default.copyItem(at: source, to: destination)
                    try FileManager.default.removeItem(at: source)
                }
                track.relativePath = LibraryPaths.relativePath(for: destination)
                moved += 1
            } catch {
                failed.append(track.title)
            }
        }
        try? context.save()
        let message = failed.isEmpty
            ? "\(moved)곡을 새 위치로 옮겼어요"
            : "\(moved)곡을 옮겼어요 · \(failed.count)곡 실패(\(failed.prefix(3).joined(separator: ", ")))"
        ActivityCenter.shared.finish(activityID, message: message)
    }
}
