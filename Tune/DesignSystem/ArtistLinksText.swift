import SwiftData
import SwiftUI

/// "ROSÉ, F1 The Album"처럼 한 칸에 여러 가수가 적힌 문자열을 이름마다 따로 누를 수 있게 보여 준다.
///
/// 한 줄 안에서 이름별로 링크를 만들기 위해 `Text` + `AttributedString.link`를 쓰고,
/// 링크는 `tune://artist/<보관함 키>`로 열어 탭할 때만 아티스트를 찾는다.
/// (행마다 아티스트 전체를 @Query로 관찰하면 목록이 무거워진다)
struct ArtistLinksText: View {
    let raw: String
    var font: Font = .body
    var color: Color = .primary
    var lineLimit: Int? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(color)
            .tint(color)
            .lineLimit(lineLimit)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "tune", url.host == "artist" else { return .systemAction }
                let key = url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? ""
                openArtist(key: key)
                // 보관함에 없는 이름이어도 링크를 열지 않고 조용히 넘어간다.
                return .handled
            })
            .accessibilityHint("가수 이름을 누르면 그 가수 페이지로 이동해요")
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var cursor = raw.startIndex
        for name in NameSplitter.artists(raw) {
            guard let range = raw.range(of: name, options: [.caseInsensitive, .diacriticInsensitive],
                                        range: cursor..<raw.endIndex) else { continue }
            if cursor < range.lowerBound {
                result += AttributedString(String(raw[cursor..<range.lowerBound]))
            }
            var piece = AttributedString(String(raw[range]))
            if let encoded = name.libraryKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "tune://artist/\(encoded)") {
                piece.link = url
            }
            result += piece
            cursor = range.upperBound
        }
        if cursor < raw.endIndex {
            result += AttributedString(String(raw[cursor..<raw.endIndex]))
        }
        return result
    }

    private func openArtist(key: String) {
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let artist = (try? modelContext.fetch(descriptor))?.first {
            router.open(.artist(artist.id))
        }
    }
}
