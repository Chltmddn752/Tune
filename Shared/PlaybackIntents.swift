import AppIntents
import Foundation

enum PlaybackCommand: Sendable {
    case toggle
    case next
    case previous
    case shuffleLibrary
    case playFavorites
    case playAlbum(String)
    case toggleFavorite
    case play
    case pause
}

/// 위젯·제어 센터·Siri 버튼이 눌리면 앱 프로세스에서 실행된다. 앱이 시작할 때 handler를 연결한다.
@MainActor
enum PlaybackCommandRouter {
    static var handler: ((PlaybackCommand) -> Void)?
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "재생/일시정지"
    static var description = IntentDescription("Tune에서 재생하거나 일시정지합니다.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.toggle)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "다음 곡"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "이전 곡"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.previous)
        return .result()
    }
}

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "보관함 셔플"
    static var description = IntentDescription("보관함의 모든 곡을 섞어서 재생합니다.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.shuffleLibrary)
        return .result()
    }
}

struct PlayFavoritesIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "좋아요 표시한 곡 재생"
    static var description = IntentDescription("좋아요 표시한 곡을 섞어서 재생합니다.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.playFavorites)
        return .result()
    }
}

struct ToggleFavoriteIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "좋아요"
    static var description = IntentDescription("재생 중인 곡에 좋아요를 표시하거나 취소합니다.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.toggleFavorite)
        return .result()
    }
}

/// 제어 센터 재생 토글용: 켜면 재생, 끄면 일시정지
struct SetPlayingIntent: SetValueIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "재생 상태 바꾸기"
    static var isDiscoverable = false

    @Parameter(title: "재생")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(value ? .play : .pause)
        return .result()
    }
}

/// 큰 위젯의 최근 앨범 버튼용 (단축어 앱에는 안 보임)
struct PlayAlbumIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "앨범 재생"
    static var isDiscoverable = false

    @Parameter(title: "앨범 ID")
    var albumID: String

    init() {}

    init(albumID: String) {
        self.albumID = albumID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandRouter.handler?(.playAlbum(albumID))
        return .result()
    }
}
