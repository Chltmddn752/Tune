import Foundation
import SwiftData

/// 플레이리스트는 기기마다 따로 있는 보관함 DB에만 있어서, 곡 파일은 iCloud 폴더로 넘어가도 플레이리스트는 안 넘어갔다.
/// 그래서 연결한 폴더 안 "Tune 플레이리스트" 폴더에 플레이리스트를 .m3u8 파일로 써 두고,
/// 같은 폴더를 연결한 다른 기기가 그 파일을 읽어 똑같이 맞춘다.
///
/// - 파일 이름: "이름 (ID 앞 8자리).m3u8" — iCloud 자리표시 파일만 있어도 어떤 플레이리스트인지 알 수 있게.
/// - 곡 경로는 플레이리스트 파일 기준 상대 경로("../가수/곡.flac")라 다른 음악 앱에서도 열린다.
/// - 더 나중에 고친 쪽이 이긴다(#TUNE-UPDATED). 한쪽에서 지우면 다른 쪽에서도 지운다.
@MainActor
enum PlaylistSync {
    static let folderName = "Tune 플레이리스트"

    /// 이 기기가 파일과 맞춘 적 있는 플레이리스트 → 그 파일이 있던 연결 폴더 id
    private static let syncedKey = "playlistSync.synced"
    /// 파일에는 있지만 이 기기에 아직 곡이 없는 항목("순서\t경로"). 곡이 들어오면 채운다.
    private static let pendingKey = "playlistSync.pending"

    private struct Parsed {
        var id: UUID?
        var name: String
        var detail: String
        var updatedMs: Int64
        var paths: [String]
    }

    private struct RemoteFile {
        var url: URL
        var folderID: String
        var folderURL: URL
        var parsed: Parsed?
    }

    @MainActor private static var scheduled: Task<Void, Never>?

    /// 여러 번 불려도 잠깐 모았다가 한 번만 맞춘다(다운로드가 연달아 끝날 때 등).
    static func scheduleSync(context: ModelContext, delay: Double = 2) {
        scheduled?.cancel()
        scheduled = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            sync(context: context)
        }
    }

    static func sync(context: ModelContext) {
        let folders = LinkedFolders.shared.reachable
        guard !folders.isEmpty else { return }

        // 1. 연결 폴더들의 플레이리스트 파일 읽기
        var remote: [String: RemoteFile] = [:]
        var listedFolders: Set<String> = []
        let fileManager = FileManager.default
        for (folder, root) in folders {
            let directory = root.appendingPathComponent(folderName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else {
                listedFolders.insert(folder.id)
                continue
            }
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            listedFolders.insert(folder.id)
            for name in names {
                var realName = name
                var isPlaceholder = false
                if name.hasPrefix(".") {
                    guard let real = CloudFiles.realName(ofPlaceholder: name) else { continue }
                    realName = real
                    isPlaceholder = true
                }
                guard realName.lowercased().hasSuffix(".m3u8"), let tag = idTag(inFileName: realName) else { continue }
                let url = directory.appendingPathComponent(realName)
                var file = RemoteFile(url: url, folderID: folder.id, folderURL: root, parsed: nil)
                if isPlaceholder || !CloudFiles.isDownloaded(url) {
                    // 아직 iCloud에서 안 받아졌다. 받기만 걸어 두고, 다음에 맞춘다.
                    CloudFiles.startDownloading(url)
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    file.parsed = parse(text)
                }
                remote[tag] = file
            }
        }

        // 2. 이 기기 보관함과 비교
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var byPath: [String: Track] = [:]
        var byID: [UUID: Track] = [:]
        for track in tracks {
            byPath[normalized(track.relativePath)] = track
            byID[track.id] = track
        }
        var synced = UserDefaults.standard.dictionary(forKey: syncedKey) as? [String: String] ?? [:]
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String]] ?? [:]
        var handled: Set<String> = []
        var changed = false

        for playlist in playlists {
            let key = playlist.id.uuidString
            let tag = idTag(playlist.id)
            let localMs = milliseconds(playlist.updatedAt)

            if let file = remote[tag] {
                handled.insert(tag)
                synced[key] = file.folderID
                guard let parsed = file.parsed else { continue }
                if parsed.updatedMs > localMs {
                    apply(parsed, to: playlist, folderID: file.folderID, byPath: byPath, byID: byID,
                          pending: &pending, context: context)
                    changed = true
                } else if parsed.updatedMs < localMs {
                    write(playlist, folderURL: file.folderURL, folderID: file.folderID, replacing: file.url,
                          byID: byID, pending: pending[key] ?? [])
                } else if fillPending(playlist, folderID: file.folderID, byPath: byPath, pending: &pending, context: context) {
                    changed = true
                }
            } else if let folderID = synced[key] {
                // 맞춘 적이 있는데 파일이 없어졌다 → 다른 기기에서 지웠다.
                // 그 폴더를 지금 제대로 읽었을 때만 지운다(폴더를 잠깐 못 읽는 중이면 그대로 둔다).
                guard listedFolders.contains(folderID) else { continue }
                context.delete(playlist)
                synced[key] = nil
                pending[key] = nil
                changed = true
            } else if let target = exportFolder(for: playlist, byID: byID) {
                // 처음 보는 이 기기 플레이리스트 → 파일로 써서 다른 기기에 알린다.
                write(playlist, folderURL: target.url, folderID: target.id, replacing: nil,
                      byID: byID, pending: pending[key] ?? [])
                synced[key] = target.id
            }
        }

        // 3. 이 기기에 없는 파일
        let localKeys = Set(playlists.map(\.id.uuidString))
        for (tag, file) in remote where !handled.contains(tag) {
            if let key = synced.keys.first(where: { $0.hasPrefix(tag) }), !localKeys.contains(key) {
                // 이 기기에서 지운 플레이리스트 → 파일도 지운다.
                try? fileManager.removeItem(at: file.url)
                try? fileManager.removeItem(at: CloudFiles.placeholderURL(for: file.url))
                try? fileManager.removeItem(at: coverURL(for: file.url))
                synced[key] = nil
                pending[key] = nil
                continue
            }
            // 다른 기기에서 만든 플레이리스트 → 새로 만든다.
            guard let parsed = file.parsed, let id = parsed.id else { continue }
            let playlist = Playlist(name: parsed.name, detail: parsed.detail)
            playlist.id = id
            let cover = coverURL(for: file.url)
            if CloudFiles.isDownloaded(cover), let data = try? Data(contentsOf: cover) {
                playlist.coverFile = ArtworkStore.save(data)
            } else {
                CloudFiles.startDownloading(cover)
            }
            context.insert(playlist)
            apply(parsed, to: playlist, folderID: file.folderID, byPath: byPath, byID: byID,
                  pending: &pending, context: context)
            synced[id.uuidString] = file.folderID
            changed = true
        }

        // 지운 플레이리스트의 기록 정리
        for key in synced.keys where !localKeys.contains(key) {
            if !remote.keys.contains(where: { key.hasPrefix($0) }) { synced[key] = nil }
        }
        for key in pending.keys where synced[key] == nil { pending[key] = nil }

        UserDefaults.standard.set(synced, forKey: syncedKey)
        UserDefaults.standard.set(pending, forKey: pendingKey)
        if changed { try? context.save() }
    }

    // MARK: - 파일 → 보관함

    private static func apply(_ parsed: Parsed, to playlist: Playlist, folderID: String,
                              byPath: [String: Track], byID: [UUID: Track],
                              pending: inout [String: [String]], context: ModelContext) {
        let prefix = LinkedFolders.prefix + folderID + "/"
        if !parsed.name.isEmpty { playlist.name = parsed.name }
        playlist.detail = parsed.detail

        // 이 연결 폴더 밖 곡(이 기기에만 있는 곡)은 파일에 못 적으니 지우지 않고 뒤에 남긴다.
        var localOnly: [PlaylistEntry] = []
        for entry in playlist.sortedEntries {
            if let track = byID[entry.trackID], !track.relativePath.hasPrefix(prefix) {
                localOnly.append(entry)
            } else {
                context.delete(entry)
            }
        }

        var unresolved: [String] = []
        for (index, path) in parsed.paths.enumerated() {
            if let track = byPath[normalized(prefix + path)] {
                let entry = PlaylistEntry(order: index, trackID: track.id)
                context.insert(entry)
                entry.playlist = playlist
            } else {
                unresolved.append("\(index)\t\(path)")
            }
        }
        for (offset, entry) in localOnly.enumerated() {
            entry.order = parsed.paths.count + offset
        }
        pending[playlist.id.uuidString] = unresolved.isEmpty ? nil : unresolved
        playlist.updatedAt = Date(timeIntervalSince1970: Double(parsed.updatedMs) / 1000)
    }

    /// 파일엔 있는데 곡이 아직 없던 항목 중, 이제 들어온 곡을 채운다. 수정 시각은 건드리지 않는다.
    private static func fillPending(_ playlist: Playlist, folderID: String, byPath: [String: Track],
                                    pending: inout [String: [String]], context: ModelContext) -> Bool {
        let key = playlist.id.uuidString
        guard let items = pending[key], !items.isEmpty else { return false }
        let prefix = LinkedFolders.prefix + folderID + "/"
        var still: [String] = []
        var filled = false
        for item in items {
            let parts = item.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let order = Int(parts[0]) else { continue }
            if let track = byPath[normalized(prefix + parts[1])] {
                let entry = PlaylistEntry(order: order, trackID: track.id)
                context.insert(entry)
                entry.playlist = playlist
                filled = true
            } else {
                still.append(item)
            }
        }
        pending[key] = still.isEmpty ? nil : still
        return filled
    }

    // MARK: - 보관함 → 파일

    /// 곡이 가장 많이 들어 있는 연결 폴더에 쓴다. 곡이 없으면 다운로드 저장 폴더에.
    private static func exportFolder(for playlist: Playlist, byID: [UUID: Track]) -> (id: String, url: URL)? {
        var counts: [String: Int] = [:]
        for entry in playlist.entries {
            guard let track = byID[entry.trackID], let id = LinkedFolders.folderID(of: track.relativePath) else { continue }
            counts[id, default: 0] += 1
        }
        if let best = counts.max(by: { $0.value < $1.value })?.key,
           let url = LinkedFolders.shared.url(for: best), LinkedFolders.shared.isReachable(best) {
            return (best, url)
        }
        // 이 기기에만 있는 곡으로 된 플레이리스트는 넘기지 않는다(다른 기기에선 빈 플레이리스트가 되니까).
        guard playlist.entries.isEmpty else { return nil }
        let settings = DownloadSettings.shared
        guard let id = settings.linkedFolderID, let url = settings.linkedFolder else { return nil }
        return (id, url)
    }

    private static func write(_ playlist: Playlist, folderURL: URL, folderID: String, replacing old: URL?,
                              byID: [UUID: Track], pending: [String]) {
        let prefix = LinkedFolders.prefix + folderID + "/"
        var lines: [(order: Int, index: Int, path: String)] = []
        for entry in playlist.sortedEntries {
            guard let track = byID[entry.trackID], track.relativePath.hasPrefix(prefix) else { continue }
            lines.append((entry.order, lines.count, String(track.relativePath.dropFirst(prefix.count))))
        }
        // 이 기기에 아직 없는 곡도 지우지 않고 그대로 적어 둔다.
        for item in pending {
            let parts = item.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let order = Int(parts[0]) else { continue }
            lines.append((order, lines.count, parts[1]))
        }
        lines.sort { ($0.order, $0.index) < ($1.order, $1.index) }

        var text = "#EXTM3U\n"
        text += "#PLAYLIST:\(oneLine(playlist.name))\n"
        text += "#TUNE-ID:\(playlist.id.uuidString)\n"
        text += "#TUNE-UPDATED:\(milliseconds(playlist.updatedAt))\n"
        if !playlist.detail.isEmpty { text += "#TUNE-DETAIL:\(oneLine(playlist.detail))\n" }
        for line in lines { text += "../\(line.path)\n" }

        let directory = folderURL.appendingPathComponent(folderName, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: playlist))
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }

        if let old, old.standardizedFileURL != url.standardizedFileURL {
            // 이름을 바꿨으면 예전 파일은 지운다.
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: CloudFiles.placeholderURL(for: old))
            let oldCover = coverURL(for: old)
            if fileManager.fileExists(atPath: oldCover.path) {
                try? fileManager.moveItem(at: oldCover, to: coverURL(for: url))
            }
        }
        let cover = coverURL(for: url)
        if !CloudFiles.exists(cover), let source = ArtworkStore.url(playlist.coverFile),
           let data = try? Data(contentsOf: source) {
            try? data.write(to: cover, options: .atomic)
        }
    }

    // MARK: - 형식

    private static func parse(_ text: String) -> Parsed {
        var parsed = Parsed(id: nil, name: "", detail: "", updatedMs: 0, paths: [])
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                if let value = value(of: "#PLAYLIST:", in: line) { parsed.name = value }
                else if let value = value(of: "#TUNE-ID:", in: line) { parsed.id = UUID(uuidString: value) }
                else if let value = value(of: "#TUNE-UPDATED:", in: line) { parsed.updatedMs = Int64(value) ?? 0 }
                else if let value = value(of: "#TUNE-DETAIL:", in: line) { parsed.detail = value }
                continue
            }
            // 플레이리스트 파일 기준 경로 → 연결 폴더 기준 경로
            if line.hasPrefix("../") {
                parsed.paths.append(String(line.dropFirst(3)))
            } else if !line.hasPrefix("/"), !line.contains("://") {
                parsed.paths.append(folderName + "/" + line)
            }
        }
        return parsed
    }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func fileName(for playlist: Playlist) -> String {
        "\(DownloadManager.safeFilename(playlist.name)) (\(idTag(playlist.id))).m3u8"
    }

    private static func coverURL(for playlistFile: URL) -> URL {
        playlistFile.deletingPathExtension().appendingPathExtension("jpg")
    }

    private static func idTag(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// "이름 (1A2B3C4D).m3u8" → "1A2B3C4D"
    private static func idTag(inFileName name: String) -> String? {
        let base = name.dropLast(".m3u8".count)
        guard base.hasSuffix(")"), let open = base.lastIndex(of: "(") else { return nil }
        let tag = base[base.index(after: open)..<base.index(before: base.endIndex)]
        guard tag.count == 8, tag.allSatisfy({ $0.isHexDigit }) else { return nil }
        return tag.uppercased()
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
