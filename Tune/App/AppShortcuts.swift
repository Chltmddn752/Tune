import AppIntents

/// Siri와 단축어 앱에 나오는 명령
struct TuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "\(.applicationName)에서 셔플 재생",
                "\(.applicationName) 보관함 셔플",
                "Shuffle my library in \(.applicationName)"
            ],
            shortTitle: "보관함 셔플",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayFavoritesIntent(),
            phrases: [
                "\(.applicationName)에서 좋아요 표시한 곡 재생",
                "\(.applicationName) 좋아하는 노래 틀어줘",
                "Play my favorites in \(.applicationName)"
            ],
            shortTitle: "좋아요 곡 재생",
            systemImageName: "star.fill"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: [
                "\(.applicationName) 재생",
                "\(.applicationName) 일시정지"
            ],
            shortTitle: "재생/일시정지",
            systemImageName: "playpause.fill"
        )
    }
}
