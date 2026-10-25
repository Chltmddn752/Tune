import Foundation
import SwiftData
import UIKit

/// 태그가 빠진 앨범(연도 · 장르 · 커버)을 Apple iTunes Search API로 채운다.
/// 음악 파일은 건드리지 않고 Tune 보관함 정보만 고친다. Apple 권장 속도(분당 약 20회)를 지키려고 천천히 묻는다.
@MainActor
@Observable
final class MetadataFiller {
    static let shared = MetadataFiller()

    var isRunning = false
    var done = 0
    var total = 0
    var lastResult: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    func candidates(context: ModelContext) -> [Album] {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        return albums.filter { $0.artworkFile == nil || $0.year == nil || $0.genre.isEmpty }
            .filter { $0.title != "알 수 없는 앨범" }
    }

    func start(context: ModelContext) {
        guard !isRunning else { return }
        let albums = candidates(context: context)
        guard !albums.isEmpty else {
            lastResult = "채울 앨범이 없어요. 모든 앨범에 연도·장르·커버가 있어요."
            return
        }
        isRunning = true
        done = 0
        total = albums.count
        lastResult = nil
        task = Task { [weak self] in
            var filled = 0
            for album in albums {
                guard let self, !Task.isCancelled else { break }
                if await self.fill(album) { filled += 1 }
                self.done += 1
                try? context.save()
                try? await Task.sleep(for: .seconds(3))
            }
            self?.isRunning = false
            self?.lastResult = "앨범 \(albums.count)개 중 \(filled)개의 정보를 채웠어요."
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
        lastResult = "중간에 멈췄어요 (\(done)/\(total))."
    }

    /// 앨범 하나: 제목·가수가 맞는 결과가 있을 때만 빈 칸을 채운다(이미 있는 값은 그대로).
    private func fill(_ album: Album) async -> Bool {
        let artist = NameSplitter.primaryArtist(album.artistName)
        guard let results = try? await CatalogLookup.search("\(artist) \(album.title)", entity: "album", limit: 10) else {
            return false
        }
        let wantTitle = LibraryMatcher.normalize(album.title)
        let wantArtist = LibraryMatcher.normalize(artist)
        guard let best = results.first(where: {
            LibraryMatcher.normalize($0.title) == wantTitle && LibraryMatcher.normalize($0.artist).contains(wantArtist)
        }) else { return false }

        var changed = false
        if album.year == nil, let year = best.releaseYear {
            album.year = year
            for track in album.tracks where track.year == nil { track.year = year }
            changed = true
        }
        if album.genre.isEmpty, let genre = best.genre, !genre.isEmpty {
            album.genre = genre
            for track in album.tracks where track.genre.isEmpty { track.genre = genre }
            changed = true
        }
        var downloaded: Data?
        if album.artworkFile == nil, let url = best.artworkURL {
            let response = try? await URLSession.shared.data(from: url)
            downloaded = response?.0
        }
        if let downloaded, let file = ArtworkStore.save(downloaded) {
            album.artworkFile = file
            for track in album.tracks where track.artworkFile == nil { track.artworkFile = file }
            if let image = ArtworkStore.image(file) {
                let palette = ColorExtractor.palette(from: image, count: 5)
                album.paletteHex = PaletteCodec.encode(palette)
                album.colorHex = ColorExtractor.backgroundColor(from: palette).hexString
            }
            changed = true
        }
        return changed
    }
}
