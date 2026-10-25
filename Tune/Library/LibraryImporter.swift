import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
@Observable
final class LibraryImporter {
    var isWorking = false
    var done = 0
    var total = 0
    var lastResult: String?

    /// 파일 앱에서 고른 파일·폴더를 앱 안으로 복사해서 추가한다.
    func importPicked(_ urls: [URL], context: ModelContext) async {
        var files: [URL] = []
        var found = 0
        var failed = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let audio = audioFiles(in: url)
            found += audio.count
            for file in audio {
                if let copied = copyIntoLibrary(file) { files.append(copied) } else { failed += 1 }
            }
        }
        if found == 0 {
            lastResult = "음악 파일을 찾지 못했어요 (mp3 · m4a · flac · wav · aiff)"
            return
        }
        if files.isEmpty {
            lastResult = "파일을 복사하지 못했어요 (\(failed)개). 파일 앱 폴더에 직접 넣어 보세요."
            return
        }
        await add(files, context: context)
        if failed > 0, let result = lastResult {
            lastResult = result + " · \(failed)개는 복사 실패"
        }
    }

    func reportPickerError(_ error: Error) {
        lastResult = "파일을 열 수 없어요: \(error.localizedDescription)"
    }

    /// 파일 앱의 "나의 iPhone > Tune" 폴더에 직접 넣은 파일을 찾아 추가한다.
    /// 폴더와 보관함을 맞춘다: 새 파일은 추가하고, 폴더에서 빠진 파일은 보관함에서도 뺀다.
    func scanDocuments(context: ModelContext) async {
        guard !isWorking else { return }
        removeMissing(context: context)
        let known = Set(((try? context.fetch(FetchDescriptor<Track>())) ?? []).map(\.relativePath))
        // Tune 폴더 + 연결한 폴더들
        var all = audioFiles(in: LibraryPaths.documents)
        for linked in LinkedFolders.shared.reachable { all += audioFiles(in: linked.url) }
        let files = all.filter { !known.contains(LibraryPaths.relativePath(for: $0)) }
        guard !files.isEmpty else { return }
        await add(files, context: context, announce: false)
    }

    /// 파일이 없어진 곡을 보관함·플레이리스트·대기열에서 뺀다. 재생 기록(통계)은 남긴다.
    @discardableResult
    func removeMissing(context: ModelContext) -> Int {
        let fm = FileManager.default
        // 음악 폴더 자체를 못 읽는 순간에는 아무것도 지우지 않는다(보관함이 통째로 날아가는 것 방지).
        guard fm.isReadableFile(atPath: LibraryPaths.documents.path) else { return 0 }

        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let links = LinkedFolders.shared
        let missing = tracks.filter { track in
            if let id = LinkedFolders.folderID(of: track.relativePath) {
                // 연결을 끊은 폴더의 곡은 뺀다. 폴더를 잠깐 못 읽는 중이면(외장·클라우드) 건드리지 않는다.
                guard links.isLinked(id) else { return true }
                guard links.isReachable(id) else { return false }
            }
            return !CloudFiles.exists(track.fileURL)
        }
        guard !missing.isEmpty else { return 0 }

        let ids = Set(missing.map(\.id))
        let albums = Set(missing.compactMap(\.album))
        let artists = Set(missing.compactMap(\.artist) + missing.compactMap { $0.album?.artist })
        let emptyAlbums = albums.filter { $0.tracks.allSatisfy { ids.contains($0.id) } }
        let emptyAlbumIDs = Set(emptyAlbums.map(\.id))
        let emptyArtists = artists.filter { artist in
            artist.tracks.allSatisfy { ids.contains($0.id) } && artist.albums.allSatisfy { emptyAlbumIDs.contains($0.id) }
        }

        let entries = (try? context.fetch(FetchDescriptor<PlaylistEntry>())) ?? []
        for entry in entries where ids.contains(entry.trackID) { context.delete(entry) }
        let lyrics = (try? context.fetch(FetchDescriptor<LyricsCache>())) ?? []
        for cache in lyrics where ids.contains(cache.trackID) { context.delete(cache) }
        for track in missing { context.delete(track) }
        for album in emptyAlbums { context.delete(album) }
        for artist in emptyArtists { context.delete(artist) }
        try? context.save()

        PlayerEngine.shared.removeTracks(ids)
        lastResult = "폴더에서 빠진 \(missing.count)곡을 보관함에서 뺐어요"
        return missing.count
    }

    // MARK: - 폴더 감시 (앱을 켜 둔 동안)

    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    // MARK: - 재생할 수 없는 파일

    /// 재생할 수 없어 건너뛴 파일 (설정에서 보여 준다)
    var unplayableFiles: [String] = UserDefaults.standard.stringArray(forKey: "unplayableFileNames") ?? []

    private func unplayableKey(_ file: URL, relative: String) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(relative)|\(size)"
    }

    private func isKnownUnplayable(_ file: URL, relative: String) -> Bool {
        let keys = UserDefaults.standard.stringArray(forKey: "unplayableFileKeys") ?? []
        return keys.contains(unplayableKey(file, relative: relative))
    }

    func markUnplayable(_ file: URL, relative: String) {
        var keys = UserDefaults.standard.stringArray(forKey: "unplayableFileKeys") ?? []
        keys.append(unplayableKey(file, relative: relative))
        UserDefaults.standard.set(Array(keys.suffix(500)), forKey: "unplayableFileKeys")
        unplayableFiles = Array((unplayableFiles + [file.lastPathComponent]).suffix(200))
        UserDefaults.standard.set(unplayableFiles, forKey: "unplayableFileNames")
    }

    func clearUnplayable() {
        UserDefaults.standard.removeObject(forKey: "unplayableFileKeys")
        UserDefaults.standard.removeObject(forKey: "unplayableFileNames")
        unplayableFiles = []
    }

    // MARK: - 정보가 덜 읽힌 곡 다시 읽기

    /// 클라우드에서 덜 받은 채로 들어와 "알 수 없는 앨범"이 된 곡을, 파일이 받아진 뒤 다시 읽어 제자리에 넣는다.
    func refreshIncompleteTracks(context: ModelContext) async {
        let unknown = "알 수 없는 앨범"
        let tracks = ((try? context.fetch(FetchDescriptor<Track>())) ?? []).filter { $0.albumTitle == unknown }
        guard !tracks.isEmpty else { return }
        var fixed = 0
        for track in tracks {
            let url = track.fileURL
            guard CloudFiles.isDownloaded(url) else { continue }
            let meta = await MetadataReader.read(url: url)
            guard let albumTitle = meta.album, !albumTitle.isEmpty else { continue }
            let artist = meta.artist ?? track.artistName
            track.title = meta.title ?? track.title
            track.artistName = artist
            track.albumTitle = albumTitle
            track.albumArtistName = meta.albumArtist ?? NameSplitter.primaryArtist(artist)
            track.trackNumber = meta.trackNumber ?? track.trackNumber
            track.discNumber = meta.discNumber ?? track.discNumber
            track.year = meta.year ?? track.year
            if let genre = meta.genre { track.genre = genre }
            if track.duration <= 0 { track.duration = meta.duration }
            var artwork = track.artworkFile
            if let data = meta.artworkData { artwork = ArtworkStore.save(data) ?? artwork }
            track.artworkFile = artwork
            let old = track.album
            let album = findOrCreateAlbum(title: albumTitle, artist: track.albumArtistName, meta: meta,
                                          artworkFile: artwork, context: context)
            track.album = album
            if album.artist == nil {
                album.artist = findOrCreateArtist(name: NameSplitter.primaryArtist(track.albumArtistName), context: context)
            }
            if let old, old.id != album.id, old.tracks.allSatisfy({ $0.id == track.id }) { context.delete(old) }
            fixed += 1
        }
        if fixed > 0 {
            try? context.save()
            lastResult = "\(fixed)곡의 앨범 정보를 다시 읽었어요"
        }
    }

    // MARK: - 연결한 폴더

    /// 파일 앱에서 고른 폴더를 연결하고 안의 음악을 바로 보관함에 넣는다.
    func linkFolder(_ url: URL, context: ModelContext) async {
        do {
            let folder = try LinkedFolders.shared.add(url)
            guard let base = LinkedFolders.shared.url(for: folder.id) else { return }
            let files = audioFiles(in: base)
            if files.isEmpty {
                lastResult = "'\(folder.name)' 폴더를 연결했어요. 음악 파일이 생기면 자동으로 들어와요"
            } else {
                await add(files, context: context, announce: true)
            }
            startWatching(context: context)
        } catch {
            lastResult = error.localizedDescription
        }
    }

    /// 연결을 끊으면 그 폴더에서 들어온 곡은 보관함에서 빠진다(파일은 그대로).
    func unlinkFolder(_ id: String, context: ModelContext) {
        LinkedFolders.shared.remove(id)
        removeMissing(context: context)
        startWatching(context: context)
    }

    /// 연결 폴더별 곡 수
    func trackCount(inLinkedFolder id: String, context: ModelContext) -> Int {
        let prefix = LinkedFolders.prefix + id + "/"
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        return tracks.filter { $0.relativePath.hasPrefix(prefix) }.count
    }

    /// 음악 폴더와 그 안의 폴더들을 지켜보다가, 파일이 들어오거나 빠지면 1초 뒤에 보관함을 맞춘다.
    func startWatching(context: ModelContext) {
        stopWatching()
        let roots = [LibraryPaths.documents] + LinkedFolders.shared.reachable.map(\.url)
        var folders: [URL] = []
        for root in roots {
            folders.append(root)
            if let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(url) }
                    if folders.count > 400 { break }
                }
            }
        }
        // 다른 앱·클라우드 폴더는 바뀌어도 알림이 안 올 수 있어서, 연결한 폴더가 있으면 20초마다 한 번씩도 확인한다.
        if !LinkedFolders.shared.folders.isEmpty {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, let self else { return }
                    await self.scanDocuments(context: context)
                }
            }
        }
        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleSync(context: context) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }

    private func scheduleSync(context: ModelContext) {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.scanDocuments(context: context)
            // 새 폴더가 생겼을 수 있어서 감시 대상을 다시 잡는다.
            self.startWatching(context: context)
        }
    }

    private func add(_ files: [URL], context: ModelContext, announce: Bool = true) async {
        guard !files.isEmpty else {
            if announce { lastResult = "가져올 음악 파일이 없어요" }
            return
        }
        isWorking = true
        done = 0
        total = files.count
        var added = 0
        var skipped = 0

        let existing = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var keys = Set(existing.map(\.dedupeKey))
        var paths = Set(existing.map(\.relativePath))

        for file in files {
            let relative = LibraryPaths.relativePath(for: file)
            if paths.contains(relative) { skipped += 1; done += 1; continue }
            // 클라우드 폴더의 곡은 받아진 다음에 정보를 읽는다.
            if CloudFiles.isExternal(file) { await CloudFiles.ensureDownloaded(file) }
            let meta = await MetadataReader.read(url: file)

            let title = (meta.title ?? file.deletingPathExtension().lastPathComponent).nfc
            let artist = (meta.artist ?? "알 수 없는 아티스트").nfc
            let key = Self.dedupeKey(title: title, artist: artist, duration: meta.duration)
            if keys.contains(key) {
                skipped += 1
                done += 1
                // 중복이고 우리가 복사해 온 파일이면 지운다.
                if file.path.hasPrefix(LibraryPaths.importedFolder.path) { try? FileManager.default.removeItem(at: file) }
                continue
            }
            insertTrack(file: file, relative: relative, meta: meta, title: title, artist: artist, key: key, context: context)
            keys.insert(key)
            paths.insert(relative)
            added += 1
            done += 1
            if added % 20 == 0 { try? context.save() }
        }

        try? context.save()
        isWorking = false
        if announce || added > 0 {
            lastResult = skipped > 0 ? "\(added)곡을 추가했어요 (중복 \(skipped)곡 건너뜀)" : "\(added)곡을 추가했어요"
        }
    }

    private func insertTrack(file: URL, relative: String, meta: TrackMetadata, title: String, artist: String,
                             key: String, context: ModelContext) {
        let albumTitle = (meta.album ?? "알 수 없는 앨범").nfc
        // 앨범 가수 태그가 없으면 곡 가수 중 첫 사람으로 묶는다(피처링 곡이 다른 앨범으로 갈라지지 않게).
        let albumArtist = (meta.albumArtist ?? NameSplitter.primaryArtist(artist)).nfc
        let ext = file.pathExtension.lowercased()

        var artworkFile: String?
        if let data = meta.artworkData {
            artworkFile = ArtworkStore.save(data)
        } else if let folderCover = folderArtwork(near: file) {
            artworkFile = ArtworkStore.save(folderCover)
        }

        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let isLossless = MetadataReader.losslessExtensions.contains(ext) || (ext == "m4a" && looksLikeALAC(file))

        let track = Track(
            title: title, artistName: artist, albumTitle: albumTitle, albumArtistName: albumArtist,
            trackNumber: meta.trackNumber ?? 0, discNumber: meta.discNumber ?? 1, year: meta.year,
            genre: meta.genre ?? "", duration: meta.duration, relativePath: relative,
            fileFormat: ext.uppercased(), isLossless: isLossless, fileSize: size,
            artworkFile: artworkFile, embeddedLyrics: meta.lyrics, dedupeKey: key
        )
        context.insert(track)

        let album = findOrCreateAlbum(title: albumTitle, artist: albumArtist, meta: meta, artworkFile: artworkFile, context: context)
        track.album = album
        // "A, B" · "A; B"처럼 여러 명이면 나눠서 각자 아티스트로 만들고, 곡은 첫 번째 사람에게 붙인다.
        let names = NameSplitter.artists(artist)
        track.artist = findOrCreateArtist(name: names.first ?? artist, context: context)
        for other in names.dropFirst() { _ = findOrCreateArtist(name: other, context: context) }
        if album.artist == nil {
            let albumNames = NameSplitter.artists(albumArtist)
            album.artist = findOrCreateArtist(name: albumNames.first ?? albumArtist, context: context)
            for other in albumNames.dropFirst() { _ = findOrCreateArtist(name: other, context: context) }
        }
    }

    private func findOrCreateAlbum(title: String, artist: String, meta: TrackMetadata, artworkFile: String?,
                                   context: ModelContext) -> Album {
        let key = Album.makeKey(title: title, artist: artist)
        var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let album = try? context.fetch(descriptor).first {
            if album.artworkFile == nil, let artworkFile { applyArtwork(artworkFile, to: album) }
            if album.year == nil { album.year = meta.year }
            if album.genre.isEmpty { album.genre = meta.genre ?? "" }
            return album
        }
        let album = Album(key: key, title: title, artistName: artist, year: meta.year, genre: meta.genre ?? "", artworkFile: nil)
        context.insert(album)
        if let artworkFile { applyArtwork(artworkFile, to: album) }
        return album
    }

    private func applyArtwork(_ file: String, to album: Album) {
        album.artworkFile = file
        if let image = ArtworkStore.image(file) {
            let palette = ColorExtractor.palette(from: image, count: 5)
            album.paletteHex = PaletteCodec.encode(palette)
            album.colorHex = ColorExtractor.backgroundColor(from: palette).hexString
        }
    }

    private func findOrCreateArtist(name: String, context: ModelContext) -> Artist {
        let key = name.libraryKey
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let artist = try? context.fetch(descriptor).first { return artist }
        let artist = Artist(key: key, name: name.nfc)
        context.insert(artist)
        return artist
    }

    // MARK: - 파일

    private func audioFiles(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return MetadataReader.isAudio(url) ? [url] : [] }
        // 숨은 파일은 건너뛰되, iCloud가 남긴 자리표시 파일(".곡.flac.icloud")은 원래 이름의 곡으로 센다.
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []
        ) else { return [] }
        var result: [URL] = []
        var seen = Set<String>()
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            if name.hasPrefix(".") {
                if let real = CloudFiles.realName(ofPlaceholder: name) {
                    let realURL = file.deletingLastPathComponent().appendingPathComponent(real)
                    if MetadataReader.isAudio(realURL), seen.insert(realURL.path).inserted { result.append(realURL) }
                } else if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if MetadataReader.isAudio(file), seen.insert(file.path).inserted { result.append(file) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func copyIntoLibrary(_ file: URL) -> URL? {
        // 이미 앱 폴더 안에 있으면 복사하지 않는다.
        if file.standardizedFileURL.path.hasPrefix(LibraryPaths.documents.standardizedFileURL.path) { return file }
        var destination = LibraryPaths.importedFolder.appendingPathComponent(file.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = file.deletingPathExtension().lastPathComponent
            destination = LibraryPaths.importedFolder.appendingPathComponent("\(name) \(counter).\(file.pathExtension)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: file, to: destination)
            // 같은 이름의 가사 파일도 같이 가져온다.
            for ext in ["lrc", "ttml"] {
                let lyric = file.deletingPathExtension().appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: lyric.path) {
                    try? FileManager.default.copyItem(at: lyric, to: destination.deletingPathExtension().appendingPathExtension(ext))
                }
            }
            return destination
        } catch {
            return nil
        }
    }

    private func folderArtwork(near file: URL) -> Data? {
        let folder = file.deletingLastPathComponent()
        for name in ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "Cover.jpg", "Folder.jpg", "front.jpg"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { return data }
        }
        return nil
    }

    private func looksLikeALAC(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return head.range(of: Data("alac".utf8)) != nil
    }

    static func dedupeKey(title: String, artist: String, duration: Double) -> String {
        "\(title.libraryKey)|\(artist.libraryKey)|\(Int(duration.rounded()))"
    }

    // MARK: - 삭제

    func delete(_ track: Track, context: ModelContext) {
        try? FileManager.default.removeItem(at: track.fileURL)
        let album = track.album
        let trackID = track.id
        let albumBecomesEmpty = album.map { $0.tracks.allSatisfy { $0.id == trackID } } ?? false
        context.delete(track)
        if let album, albumBecomesEmpty {
            context.delete(album)
        }
        try? context.save()
    }

    func delete(_ album: Album, context: ModelContext) {
        for track in album.tracks {
            try? FileManager.default.removeItem(at: track.fileURL)
            context.delete(track)
        }
        context.delete(album)
        try? context.save()
    }
}
