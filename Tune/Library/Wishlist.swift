import Foundation
import SwiftData

/// 사고 싶은 곡 (보관함에 아직 없는 곡을 적어 두는 목록)
/// 같은 곡이 보관함에 들어오면 앱이 알아서 목록에서 지운다.
@Model
final class WishItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    var album: String
    var artworkURL: String?
    var storeURL: String?
    var sourceURL: String?
    var addedAt: Date

    init(title: String, artist: String, album: String = "", artworkURL: String? = nil,
         storeURL: String? = nil, sourceURL: String? = nil) {
        self.id = UUID()
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.storeURL = storeURL
        self.sourceURL = sourceURL
        self.addedAt = .now
    }

    convenience init(_ item: CatalogItem) {
        self.init(title: item.title, artist: item.artist, album: item.album,
                  artworkURL: item.artworkURL?.absoluteString, storeURL: item.storeURL?.absoluteString,
                  sourceURL: item.sourceURL?.absoluteString)
    }

    var catalogItem: CatalogItem {
        CatalogItem(id: id.uuidString, title: title, artist: artist, album: album,
                    artworkURL: artworkURL.flatMap(URL.init(string:)), storeURL: storeURL.flatMap(URL.init(string:)),
                    sourceURL: sourceURL.flatMap(URL.init(string:)))
    }
}

/// 제목·가수로 내 보관함에서 같은 곡 찾기 (괄호 속 부제·feat.·대소문자 차이는 무시)
@MainActor
enum LibraryMatcher {
    static func normalize(_ text: String) -> String {
        var s = text.nfc.lowercased()
        // (feat. …), [Remastered], - Remastered 2011 같은 꼬리표 제거
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*(remaster|version|edit|mix|live).*$"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        return s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// 같은 곡으로 보이는 보관함의 곡
    static func match(title: String, artist: String, in tracks: [Track]) -> Track? {
        let wantTitle = normalize(title)
        guard !wantTitle.isEmpty else { return nil }
        let wantArtists = Set(NameSplitter.artists(artist).map(normalize))
        let sameTitle = tracks.filter { normalize($0.title) == wantTitle }
        if wantArtists.isEmpty { return sameTitle.first }
        return sameTitle.first { track in
            let have = Set((NameSplitter.artists(track.artistName) + NameSplitter.artists(track.albumArtistName)).map(normalize))
            return !have.isDisjoint(with: wantArtists)
        }
    }

    /// 보관함에 들어온 곡은 사고 싶은 곡 목록에서 지운다.
    static func pruneWishlist(context: ModelContext) {
        let wishes = (try? context.fetch(FetchDescriptor<WishItem>())) ?? []
        guard !wishes.isEmpty else { return }
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var removed = false
        for wish in wishes where match(title: wish.title, artist: wish.artist, in: tracks) != nil {
            context.delete(wish)
            removed = true
        }
        if removed { try? context.save() }
    }
}
