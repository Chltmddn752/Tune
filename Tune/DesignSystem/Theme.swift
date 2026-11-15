import SwiftUI

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32

    /// 화면 양옆 여백: 아이폰 20pt, 아이패드 24pt
    static func screen(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 24 : 20
    }
}

/// Material 3 Expressive: 모서리를 크게 (SpatialFlow 기준)
enum Radius {
    static let listArtwork: CGFloat = 8
    static let card: CGFloat = 12
    static let playerArtwork: CGFloat = 16
    static let tile: CGFloat = 20
}

extension Font {
    /// 34pt bold — 탭 맨 위 큰 제목
    static let tuneLargeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    /// 34pt heavy — 아티스트 이름
    static let tuneArtistName = Font.system(.largeTitle, design: .rounded).weight(.heavy)
    /// 22pt bold — 섹션 제목, 앨범 제목
    static let tuneSection = Font.system(.title2, design: .rounded).weight(.semibold)
    /// 20pt semibold — 재생 화면 제목
    static let tunePlayerTitle = Font.system(.title3, design: .rounded).weight(.bold)
    /// 17pt — 곡 제목
    static let tuneBody = Font.body
    /// 15pt — 아티스트, 카드 제목
    static let tuneSubtitle = Font.subheadline
    /// 13pt — 카드 부제, 곡 수
    static let tuneCaption = Font.footnote
    /// 12pt semibold — 재생 시간
    static let tuneTime = Font.caption.weight(.semibold).monospacedDigit()
}

extension Animation {
    /// 재생 화면 열기·닫기 (0.3초, 튕김 없음)
    static let playerExpand = Animation.smooth(duration: 0.3, extraBounce: 0)
    /// 일시정지할 때 커버 축소 (0.4초, 살짝 튕김)
    static let artworkPause = Animation.smooth(duration: 0.4, extraBounce: 0.25)
    /// 슬라이더 누름 (0.3초, 튕김 30%)
    static let sliderPress = Animation.smooth(duration: 0.3, extraBounce: 0.3)
    /// 가사 줄 이동
    static let lyricsMove = Animation.interpolatingSpring(mass: 0.9, stiffness: 90, damping: 15)
    /// 가사 줄 크기 변화
    static let lyricsScale = Animation.interpolatingSpring(mass: 2, stiffness: 100, damping: 25)
    /// 아이패드 재생 패널
    static let panel = Animation.smooth(duration: 0.33)
    /// 배경색 바뀜
    static let backgroundFade = Animation.easeInOut(duration: 0.6)
}

enum Formatters {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "48분", "1시간 32분"
    static func longDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분" }
        return "\(max(minutes, 1))분"
    }

    static func listening(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분" }
        return "\(minutes)분"
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
