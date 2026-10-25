import SwiftUI

enum SettingsKey {
    static let theme = "theme"
    static let accent = "accent"
    static let autoplay = "autoplay"
    static let resumeOnHeadphones = "resumeOnHeadphones"
    static let onlineLyrics = "onlineLyrics"
    static let estimateWordTiming = "estimateWordTiming"
    static let lyricsBlur = "lyricsBlur"
    static let lyricsSize = "lyricsSize"
    static let artistPhotos = "artistPhotos"
    static let recentSearches = "recentSearches"
    static let songSort = "songSort"
    static let albumSort = "albumSort"
    static let albumGrid = "albumGrid"
    static let playlistSort = "playlistSort"
    static let libraryMenu = "libraryMenu"
    static let appIcon = "appIcon"
}

enum ThemeOption: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentOption: String, CaseIterable, Identifiable {
    case pink, red, orange, yellow, green, mint, blue, purple
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pink: "핑크"
        case .red: "빨강"
        case .orange: "주황"
        case .yellow: "노랑"
        case .green: "초록"
        case .mint: "민트"
        case .blue: "파랑"
        case .purple: "보라"
        }
    }

    var color: Color {
        switch self {
        case .pink: Color(red: 0.98, green: 0.18, blue: 0.34)
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .blue: .blue
        case .purple: .purple
        }
    }
}

enum LyricsSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "작게"
        case .medium: "보통"
        case .large: "크게"
        }
    }

    var points: CGFloat {
        switch self {
        case .small: 24
        case .medium: 28
        case .large: 34
        }
    }
}

enum AppIconOption: String, CaseIterable, Identifiable {
    case pink, dark, light
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pink: "핑크"
        case .dark: "다크"
        case .light: "화이트"
        }
    }

    /// setAlternateIconName에 넘길 이름 (기본 아이콘은 nil)
    var iconName: String? {
        switch self {
        case .pink: nil
        case .dark: "AppIconDark"
        case .light: "AppIconLight"
        }
    }

    /// 설정 화면 미리보기용 이미지 (Assets의 IconPreview…)
    var previewName: String {
        switch self {
        case .pink: "IconPreviewPink"
        case .dark: "IconPreviewDark"
        case .light: "IconPreviewLight"
        }
    }
}

extension Color {
    /// 설정한 포인트색. LiveContainer 안에서는 앱의 기본 포인트색(AccentColor)이 무시돼서 직접 읽는다.
    static var tuneAccent: Color {
        (AccentOption(rawValue: UserDefaults.standard.string(forKey: SettingsKey.accent) ?? "") ?? .pink).color
    }
}
