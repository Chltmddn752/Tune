import Foundation

/// 명령줄 도구에서는 CAF 태그(앱이 유튜브 뮤직 곡에 넣는 것)를 읽지 않는다. MetadataReader가 부르는 자리만 채운다.
enum CAFTags {
    static func read(_ url: URL) -> TrackMetadata? { nil }
}
