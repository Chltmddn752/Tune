import Foundation
import SwiftData

/// 보관함 안의 중복과 "중복이라 건너뛴 디스크 파일"을 묶어서 보여 준다.
struct DuplicateEntry: Identifiable, Hashable, Sendable {
    var id: String
    var trackID: UUID?
    var diskRelativePath: String?
    var diskPath: String?
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var isLossless: Bool
    var fileFormat: String
    var fileSize: Int64
    var playCount: Int
    var addedAt: Date
    var pathLabel: String
    var artworkFile: String?
    var colorHex: String?
    var isOnDiskOnly: Bool
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var artist: String
    var entries: [DuplicateEntry]

    var recommendedEntryID: String? {
        DuplicateFinder.recommendedKeeper(in: self)?.id
    }
}

@MainActor
enum DuplicateFinder {
    /// 같은 곡으로 볼 기준. 제목 꼬리표·대소문자·문장부호를 무시하고, 첫 아티스트만 본다.
    nonisolated static func groupKey(_ entry: DuplicateEntry) -> String {
        let title = LibraryText.key(entry.title)
        let artist = LibraryText.key(NameSplitter.primaryArtist(entry.artist))
        let version = LibraryText.versionTag(entry.title) ?? ""
        return "\(title)|\(artist)|\(version)"
    }

    /// 보관함 곡과 건너뛴 디스크 파일을 값으로 복사한다(그룹 계산을 백그라운드에서 하기 위해).
    static func entries(context: ModelContext) -> [DuplicateEntry] {
        var result: [DuplicateEntry] = []
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        for track in tracks {
            result.append(DuplicateEntry(
                id: "track:\(track.id.uuidString)",
                trackID: track.id,
                diskRelativePath: nil,
                diskPath: track.fileURL.path,
                title: track.title,
                artist: track.artistName,
                album: track.albumTitle,
                duration: track.duration,
                isLossless: track.isLossless,
                fileFormat: track.fileFormat,
                fileSize: track.fileSize,
                playCount: track.playCount,
                addedAt: track.addedAt,
                pathLabel: track.relativePath.hasPrefix(LinkedFolders.prefix) ? "연결 폴더" : "Tune 폴더",
                artworkFile: track.artworkFile,
                colorHex: track.album?.colorHex,
                isOnDiskOnly: false
            ))
        }
        for skipped in SkippedFileStore.all().values where skipped.reason == "중복" {
            let path = LibraryPaths.url(forRelative: skipped.relativePath)
            let fileSize = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let title = skipped.title ?? path.deletingPathExtension().lastPathComponent
            result.append(DuplicateEntry(
                id: "disk:\(skipped.relativePath)",
                trackID: nil,
                diskRelativePath: skipped.relativePath,
                diskPath: path.path,
                title: title,
                artist: skipped.artist ?? "알 수 없는 아티스트",
                album: skipped.album ?? "앨범 없음",
                duration: skipped.duration ?? 0,
                isLossless: MetadataReader.losslessExtensions.contains(path.pathExtension.lowercased()),
                fileFormat: path.pathExtension.uppercased(),
                fileSize: fileSize,
                playCount: 0,
                addedAt: skipped.skippedAt,
                pathLabel: skipped.relativePath.hasPrefix(LinkedFolders.prefix) ? "연결 폴더" : "Tune 폴더",
                artworkFile: nil,
                colorHex: nil,
                isOnDiskOnly: true
            ))
        }
        return result
    }

    /// 제목·아티스트가 같고 길이 차이가 2초 이내인 것끼리 묶는다. 길이가 0이면 0끼리만.
    nonisolated static func groups(from entries: [DuplicateEntry]) -> [DuplicateGroup] {
        let byKey = Dictionary(grouping: entries, by: groupKey)
        var result: [DuplicateGroup] = []
        for (key, list) in byKey {
            let sorted = list.sorted { $0.duration < $1.duration }
            var clusters: [[DuplicateEntry]] = []
            for entry in sorted {
                if let last = clusters.indices.last {
                    let first = clusters[last].first?.duration ?? 0
                    let close = (first > 0 && entry.duration > 0 && abs(entry.duration - first) <= 2)
                        || (first <= 0 && entry.duration <= 0)
                    if close {
                        clusters[last].append(entry)
                        continue
                    }
                }
                clusters.append([entry])
            }
            for cluster in clusters where cluster.count >= 2 {
                let title = cluster.first(where: { !$0.isOnDiskOnly })?.title ?? cluster[0].title
                let artist = cluster.first(where: { !$0.isOnDiskOnly })?.artist ?? cluster[0].artist
                result.append(DuplicateGroup(id: key + "|\(Int(cluster[0].duration))", title: title,
                                             artist: artist, entries: cluster))
            }
        }
        return result.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 설정 화면 배지에 쓸 그룹 수. 그룹 계산은 백그라운드에서 한다.
    static func groupCount(context: ModelContext) async -> Int {
        let entries = entries(context: context)
        return await Task.detached(priority: .userInitiated) { groups(from: entries).count }.value
    }

    /// 남길 것을 고른다: 무손실 > 큰 파일 > 재생 횟수. 보관함 곡을 우선해 기록을 합칠 곳을 남긴다.
    nonisolated static func recommendedKeeper(in group: DuplicateGroup) -> DuplicateEntry? {
        group.entries.max { score($0) < score($1) }
    }

    nonisolated private static func score(_ entry: DuplicateEntry) -> Double {
        var value = 0.0
        if entry.isLossless { value += 1_000_000 }
        value += Double(entry.fileSize) / 1_000_000
        value += Double(min(entry.playCount, 500)) * 10
        if !entry.isOnDiskOnly { value += 5_000 }
        return value
    }

    /// 선택한 항목을 지우고, 남기는 곡으로 재생 기록·플레이리스트·가사 설정을 옮긴다.
    /// - Parameter deleteFiles: true면 파일까지 지운다. false면 보관함에서만 뺀다(디스크 파일은 그대로).
    @discardableResult
    static func delete(_ groups: [DuplicateGroup], selection: Set<String>,
                       deleteFiles: Bool, context: ModelContext) -> Int {
        var removedTracks = Set<UUID>()
        var removed = 0

        for group in groups {
            guard group.entries.contains(where: { selection.contains($0.id) }) else { continue }
            let keeper = group.entries.first { !selection.contains($0.id) }
                ?? recommendedKeeper(in: group)
            guard let keeper else { continue }
            let keeperTrack = keeper.trackID.flatMap { fetchTrack($0, context: context) }

            for entry in group.entries where entry.id != keeper.id && selection.contains(entry.id) {
                if let trackID = entry.trackID, let track = fetchTrack(trackID, context: context) {
                    merge(track, into: keeperTrack, context: context)
                    let album = track.album
                    let albumBecomesEmpty = album.map { $0.tracks.count <= 1 } ?? false
                    if deleteFiles { try? FileManager.default.removeItem(at: track.fileURL) }
                    context.delete(track)
                    if albumBecomesEmpty, let album { context.delete(album) }
                    removedTracks.insert(trackID)
                    removed += 1
                } else if let diskRelativePath = entry.diskRelativePath {
                    // 디스크에만 있는 파일은 "보관함에서만 빼기"에서는 건드리지 않는다.
                    if deleteFiles {
                        if let path = entry.diskPath { try? FileManager.default.removeItem(atPath: path) }
                        SkippedFileStore.forget(relative: diskRelativePath)
                        removed += 1
                    }
                }
            }
        }

        try? context.save()
        PlayerEngine.shared.removeTracks(removedTracks)
        return removed
    }

    private static func merge(_ removed: Track, into keeper: Track?, context: ModelContext) {
        guard let keeper, keeper.id != removed.id else { return }
        keeper.playCount += removed.playCount
        keeper.isFavorite = keeper.isFavorite || removed.isFavorite
        if let date = removed.lastPlayedAt, date > (keeper.lastPlayedAt ?? .distantPast) {
            keeper.lastPlayedAt = date
        }

        let removedID = removed.id
        let entries = (try? context.fetch(FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate { $0.trackID == removedID }
        ))) ?? []
        for entry in entries {
            if let playlist = entry.playlist, playlist.entries.contains(where: { $0.trackID == keeper.id }) {
                context.delete(entry)
            } else {
                entry.trackID = keeper.id
            }
        }

        let events = (try? context.fetch(FetchDescriptor<PlayEvent>(
            predicate: #Predicate { $0.trackID == removedID }
        ))) ?? []
        for event in events { event.trackID = keeper.id }

        let keeperID = keeper.id
        if let removedLyrics = fetchLyrics(removedID, context: context) {
            if fetchLyrics(keeperID, context: context) == nil {
                removedLyrics.trackID = keeperID
            } else {
                context.delete(removedLyrics)
            }
        }
    }

    private static func fetchTrack(_ id: UUID, context: ModelContext) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchLyrics(_ id: UUID, context: ModelContext) -> LyricsCache? {
        var descriptor = FetchDescriptor<LyricsCache>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
