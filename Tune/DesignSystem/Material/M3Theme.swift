import Observation
import SwiftUI
import UIKit

// Material 3 Expressive 디자인 토큰.
// SpatialFlow(안드로이드)의 Theme.kt · PlayerUiComponents.kt 공식을 그대로 옮겼다.
// 색은 전부 "씨앗색 하나 → HSL로 밝기·채도를 고정" 방식으로 만든다.

// MARK: - HSL

struct HSL {
    var h: CGFloat // 0...360
    var s: CGFloat // 0...1
    var l: CGFloat // 0...1

    init(h: CGFloat, s: CGFloat, l: CGFloat) {
        self.h = h
        self.s = s
        self.l = l
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            color.getWhite(&white, alpha: &a)
            r = white; g = white; b = white
        }
        r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1)
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let lightness = (maxV + minV) / 2
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        if delta > 0.00001 {
            saturation = lightness > 0.5 ? delta / (2 - maxV - minV) : delta / (maxV + minV)
            if maxV == r {
                hue = (g - b) / delta + (g < b ? 6 : 0)
            } else if maxV == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue *= 60
        }
        self.h = hue
        self.s = saturation
        self.l = lightness
    }

    var uiColor: UIColor {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let sat = min(max(s, 0), 1)
        let lig = min(max(l, 0), 1)
        if sat < 0.00001 { return UIColor(red: lig, green: lig, blue: lig, alpha: 1) }
        let q = lig < 0.5 ? lig * (1 + sat) : lig + sat - lig * sat
        let p = 2 * lig - q
        func channel(_ t0: CGFloat) -> CGFloat {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return UIColor(red: channel(hue + 1.0 / 3), green: channel(hue), blue: channel(hue - 1.0 / 3), alpha: 1)
    }

    var color: Color { Color(uiColor: uiColor) }

    static func make(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> UIColor {
        HSL(h: h, s: s, l: l).uiColor
    }
}

private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    min(max(value, low), high)
}

// MARK: - 앱 전체 색 (Material You 방식)

/// 씨앗색으로 라이트·다크 두 벌의 M3 색 체계를 만든다.
struct M3Scheme {
    struct Tones {
        var background: UIColor
        var surface: UIColor
        var surfaceContainerLowest: UIColor
        var surfaceContainerLow: UIColor
        var surfaceContainer: UIColor
        var surfaceContainerHigh: UIColor
        var surfaceContainerHighest: UIColor
        var surfaceVariant: UIColor
        var onSurface: UIColor
        var onSurfaceVariant: UIColor
        var primary: UIColor
        var onPrimary: UIColor
        var primaryContainer: UIColor
        var onPrimaryContainer: UIColor
        var secondary: UIColor
        var secondaryContainer: UIColor
        var onSecondaryContainer: UIColor
        var tertiary: UIColor
        var tertiaryContainer: UIColor
        var onTertiaryContainer: UIColor
        var outline: UIColor
        var outlineVariant: UIColor
        var inverseSurface: UIColor
        var inverseOnSurface: UIColor
        var inversePrimary: UIColor
        var error: UIColor
        var errorContainer: UIColor
        var onErrorContainer: UIColor
    }

    var dark: Tones
    var light: Tones

    init(seed: UIColor, amoled: Bool) {
        let base = HSL(seed)
        let mono = base.s < 0.06
        let h = base.h
        let s = mono ? 0 : base.s
        let primarySat = mono ? 0 : max(s, 0.5)
        let primaryContainerSat = mono ? 0 : max(s, 0.4)
        let secondarySat = mono ? 0 : clamp(s * 0.5, 0.2, 0.35)
        let secondaryContainerSat = mono ? 0 : clamp(s * 0.5, 0.15, 0.30)
        let tertiarySat = mono ? 0 : clamp(s * 0.6, 0.3, 0.5)
        let tertiaryContainerSat = mono ? 0 : clamp(s * 0.6, 0.25, 0.45)
        let th = (h + 60).truncatingRemainder(dividingBy: 360)

        let darkBg = min(s * 0.15, 0.1)
        var dark = Tones(
            background: HSL.make(h, darkBg, 0.04),
            surface: HSL.make(h, darkBg, 0.06),
            surfaceContainerLowest: HSL.make(h, darkBg, 0.02),
            surfaceContainerLow: HSL.make(h, darkBg, 0.08),
            surfaceContainer: HSL.make(h, darkBg, 0.12),
            surfaceContainerHigh: HSL.make(h, darkBg, 0.16),
            surfaceContainerHighest: HSL.make(h, darkBg, 0.22),
            surfaceVariant: HSL.make(h, darkBg, 0.28),
            onSurface: HSL.make(h, darkBg, 0.90),
            onSurfaceVariant: HSL.make(h, darkBg, 0.80),
            primary: HSL.make(h, primarySat, 0.75),
            onPrimary: HSL.make(h, primarySat, 0.20),
            primaryContainer: HSL.make(h, primaryContainerSat, 0.25),
            onPrimaryContainer: HSL.make(h, primaryContainerSat, 0.90),
            secondary: HSL.make(h, secondarySat, 0.70),
            secondaryContainer: HSL.make(h, secondaryContainerSat, 0.20),
            onSecondaryContainer: HSL.make(h, secondaryContainerSat, 0.85),
            tertiary: HSL.make(th, tertiarySat, 0.70),
            tertiaryContainer: HSL.make(th, tertiaryContainerSat, 0.20),
            onTertiaryContainer: HSL.make(th, tertiaryContainerSat, 0.85),
            outline: HSL.make(h, darkBg, 0.60),
            outlineVariant: HSL.make(h, darkBg, 0.30),
            inverseSurface: HSL.make(h, darkBg, 0.90),
            inverseOnSurface: HSL.make(h, darkBg, 0.12),
            inversePrimary: HSL.make(h, primarySat, 0.40),
            error: HSL.make(0, 0.6, 0.65),
            errorContainer: HSL.make(0, 0.6, 0.25),
            onErrorContainer: HSL.make(0, 0.6, 0.90)
        )
        if amoled {
            dark.background = .black
            dark.surface = .black
            dark.surfaceContainerLowest = .black
            dark.surfaceContainerLow = .black
            dark.surfaceContainer = UIColor(white: 0.05, alpha: 1)
            dark.surfaceContainerHigh = UIColor(white: 0.08, alpha: 1)
            dark.surfaceContainerHighest = UIColor(white: 0.12, alpha: 1)
        }

        let lightBg = min(s * 0.15, 0.15)
        let light = Tones(
            background: HSL.make(h, lightBg, 0.98),
            surface: HSL.make(h, lightBg, 0.98),
            surfaceContainerLowest: HSL.make(h, lightBg, 1.0),
            surfaceContainerLow: HSL.make(h, lightBg, 0.96),
            surfaceContainer: HSL.make(h, lightBg, 0.94),
            surfaceContainerHigh: HSL.make(h, lightBg, 0.90),
            surfaceContainerHighest: HSL.make(h, lightBg, 0.86),
            surfaceVariant: HSL.make(h, lightBg, 0.80),
            onSurface: HSL.make(h, lightBg, 0.10),
            onSurfaceVariant: HSL.make(h, lightBg, 0.30),
            primary: HSL.make(h, primarySat, 0.40),
            onPrimary: HSL.make(h, primarySat, 0.95),
            primaryContainer: HSL.make(h, primaryContainerSat, 0.85),
            onPrimaryContainer: HSL.make(h, primaryContainerSat, 0.10),
            secondary: HSL.make(h, secondarySat, 0.45),
            secondaryContainer: HSL.make(h, secondaryContainerSat, 0.85),
            onSecondaryContainer: HSL.make(h, secondaryContainerSat, 0.10),
            tertiary: HSL.make(th, tertiarySat, 0.45),
            tertiaryContainer: HSL.make(th, tertiaryContainerSat, 0.85),
            onTertiaryContainer: HSL.make(th, tertiaryContainerSat, 0.10),
            outline: HSL.make(h, lightBg, 0.50),
            outlineVariant: HSL.make(h, lightBg, 0.80),
            inverseSurface: HSL.make(h, lightBg, 0.20),
            inverseOnSurface: HSL.make(h, lightBg, 0.95),
            inversePrimary: HSL.make(h, primarySat, 0.80),
            error: HSL.make(0, 0.6, 0.45),
            errorContainer: HSL.make(0, 0.6, 0.85),
            onErrorContainer: HSL.make(0, 0.6, 0.10)
        )
        self.dark = dark
        self.light = light
    }
}

/// 지금 쓰는 씨앗색. 앱 어디서든 `Color.m3…`로 읽으면 이 값을 관찰하므로 씨앗색이 바뀌면 화면이 따라 바뀐다.
@Observable
final class M3ThemeStore {
    static let shared = M3ThemeStore()

    private(set) var scheme = M3Scheme(seed: UIColor(red: 0.98, green: 0.18, blue: 0.34, alpha: 1), amoled: false)
    @ObservationIgnored private var lastKey = ""

    /// 씨앗색이나 AMOLED 설정이 바뀌었을 때만 다시 만든다.
    func update(seed: UIColor, amoled: Bool) {
        let hsl = HSL(seed)
        let key = String(format: "%.0f-%.2f-%.2f-%d", hsl.h, hsl.s, hsl.l, amoled ? 1 : 0)
        guard key != lastKey else { return }
        lastKey = key
        scheme = M3Scheme(seed: seed, amoled: amoled)
    }

    func color(_ pick: @escaping (M3Scheme.Tones) -> UIColor) -> Color {
        let scheme = scheme
        return Color(uiColor: UIColor { traits in
            pick(traits.userInterfaceStyle == .dark ? scheme.dark : scheme.light)
        })
    }
}

extension Color {
    private static func m3(_ pick: @escaping (M3Scheme.Tones) -> UIColor) -> Color {
        M3ThemeStore.shared.color(pick)
    }

    static var m3Background: Color { m3 { $0.background } }
    static var m3Surface: Color { m3 { $0.surface } }
    static var m3SurfaceContainerLowest: Color { m3 { $0.surfaceContainerLowest } }
    static var m3SurfaceContainerLow: Color { m3 { $0.surfaceContainerLow } }
    static var m3SurfaceContainer: Color { m3 { $0.surfaceContainer } }
    static var m3SurfaceContainerHigh: Color { m3 { $0.surfaceContainerHigh } }
    static var m3SurfaceContainerHighest: Color { m3 { $0.surfaceContainerHighest } }
    static var m3SurfaceVariant: Color { m3 { $0.surfaceVariant } }
    static var m3OnSurface: Color { m3 { $0.onSurface } }
    static var m3OnSurfaceVariant: Color { m3 { $0.onSurfaceVariant } }
    static var m3Primary: Color { m3 { $0.primary } }
    static var m3OnPrimary: Color { m3 { $0.onPrimary } }
    static var m3PrimaryContainer: Color { m3 { $0.primaryContainer } }
    static var m3OnPrimaryContainer: Color { m3 { $0.onPrimaryContainer } }
    static var m3Secondary: Color { m3 { $0.secondary } }
    static var m3SecondaryContainer: Color { m3 { $0.secondaryContainer } }
    static var m3OnSecondaryContainer: Color { m3 { $0.onSecondaryContainer } }
    static var m3Tertiary: Color { m3 { $0.tertiary } }
    static var m3TertiaryContainer: Color { m3 { $0.tertiaryContainer } }
    static var m3OnTertiaryContainer: Color { m3 { $0.onTertiaryContainer } }
    static var m3Outline: Color { m3 { $0.outline } }
    static var m3OutlineVariant: Color { m3 { $0.outlineVariant } }
    static var m3InverseSurface: Color { m3 { $0.inverseSurface } }
    static var m3InverseOnSurface: Color { m3 { $0.inverseOnSurface } }
    static var m3InversePrimary: Color { m3 { $0.inversePrimary } }
    static var m3Error: Color { m3 { $0.error } }
    static var m3ErrorContainer: Color { m3 { $0.errorContainer } }
    static var m3OnErrorContainer: Color { m3 { $0.onErrorContainer } }
}

// MARK: - 재생 화면 색 (앨범색에서 바로 뽑는다)

/// SpatialFlow의 deriveArtworkSurfaceColor. 재생 화면은 항상 어두운 판(흰 글자)으로 그린다.
struct M3PlayerColors: Equatable {
    var background: Color
    var lyricsBackground: Color
    var trayBackground: Color
    var trayInactive: Color
    var trayActive: Color
    var trayActiveContent: Color
    var accent: Color
    /// 재생 버튼 위 아이콘색
    var onAccent: Color
    let content = Color.white
    let contentSecondary = Color.white.opacity(0.6)
    /// 칩·버튼 바탕 (글자색 8%)
    let chip = Color.white.opacity(0.08)

    init(seed: Color) {
        let ui = UIColor(seed)
        let hsl = HSL(ui)
        let mono = hsl.s < 0.06
        func surface(_ l: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Color {
            HSL(h: hsl.h, s: mono ? 0 : clamp(hsl.s, low, high), l: l).color
        }
        background = surface(0.155, 0.32, 0.54)
        lyricsBackground = surface(0.145, 0.32, 0.54)
        trayBackground = surface(0.24, 0.30, 0.60)
        trayInactive = surface(0.33, 0.24, 0.55)
        if hsl.s < 0.08 {
            trayActive = Color(white: 0.91)
            trayActiveContent = Color(red: 0.11, green: 0.106, blue: 0.12)
            accent = .white
        } else {
            let active = HSL(h: hsl.h, s: max(hsl.s, 0.45), l: 0.62)
            trayActive = active.color
            trayActiveContent = active.uiColor.m3Luminance > 0.5 ? Color(red: 0.11, green: 0.106, blue: 0.12) : .white
            // 너무 어두운 대표색은 재생 버튼에서 묻히니 밝기를 올린다.
            accent = HSL(h: hsl.h, s: max(hsl.s, 0.45), l: clamp(hsl.l, 0.55, 0.78)).color
        }
        onAccent = Color(red: 0.11, green: 0.106, blue: 0.12)
    }
}

extension UIColor {
    /// 상대 휘도 (0 어두움 … 1 밝음)
    var m3Luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

// MARK: - 모양

enum M3Shape {
    /// 붙어 있는 카드 묶음: 첫 칸은 위만, 마지막 칸은 아래만 크게 둥글다.
    static func segment(index: Int, count: Int, outer: CGFloat = 28, inner: CGFloat = 4) -> UnevenRoundedRectangle {
        let top: CGFloat = index == 0 ? outer : inner
        let bottom: CGFloat = index == count - 1 ? outer : inner
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
    }

    /// 세그먼트 카드 사이 간격 (M3 SegmentedGap)
    static let segmentGap: CGFloat = 2
}

// MARK: - 모션 (Compose 스프링 → SwiftUI)
// Compose stiffness k, dampingRatio ζ → SwiftUI response = 2π/√k, dampingFraction = ζ

enum M3Motion {
    static func spring(stiffness: Double, damping: Double) -> Animation {
        .spring(response: 2 * .pi / stiffness.squareRoot(), dampingFraction: damping)
    }

    /// 재생 시트 펼침·접힘 (0.85 / 400)
    static let sheet = spring(stiffness: 400, damping: 0.85)
    /// 하단바 숨김·표시 (0.85 / 200)
    static let navBar = spring(stiffness: 200, damping: 0.85)
    /// 탭 전환 (0.82 / 400)
    static let tab = spring(stiffness: 400, damping: 0.82)
    /// 대기열 서랍 (0.85 / 300)
    static let drawer = spring(stiffness: 300, damping: 0.85)
    /// 가사 모드로 아트워크 이동 (0.86 / 420)
    static let lyricsArtwork = spring(stiffness: 420, damping: 0.86)
    /// 누르면 모서리가 줄어드는 버튼 (0.5 / 1500)
    static let press = spring(stiffness: 1500, damping: 0.5)
    /// 물결 진폭 (0.5 / 200)
    static let bouncy = spring(stiffness: 200, damping: 0.5)
    /// 기본 (1.0 / 400)
    static let standard = spring(stiffness: 400, damping: 1)
}

// MARK: - 글꼴

/// Google Sans Flex 대신 시스템 둥근 글꼴(SF Rounded)을 쓴다.
extension Font {
    static func m3(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let m3DisplaySmall = Font.m3(36)
    static let m3HeadlineLarge = Font.m3(32)
    static let m3HeadlineMedium = Font.m3(28, .semibold)
    static let m3HeadlineSmall = Font.m3(24)
    static let m3TitleLarge = Font.m3(22, .bold)
    static let m3TitleMedium = Font.m3(16, .medium)
    static let m3TitleSmall = Font.m3(14, .medium)
    static let m3BodyLarge = Font.m3(16)
    static let m3BodyMedium = Font.m3(14)
    static let m3BodySmall = Font.m3(12)
    static let m3LabelLarge = Font.m3(14, .medium)
    static let m3LabelMedium = Font.m3(12, .medium)
    static let m3LabelSmall = Font.m3(11, .medium)
}

// MARK: - 설정 키

enum M3SettingsKey {
    /// 앨범 커버색으로 앱 전체 색 바꾸기
    static let dynamicColors = "m3DynamicColors"
    /// 다크 모드에서 완전한 검정 배경
    static let amoled = "m3Amoled"
    /// 하단바 글자 숨기기
    static let hideNavLabels = "m3HideNavLabels"
    /// 하단바를 낮고 굵게
    static let dynamicNavStyle = "m3DynamicNavStyle"
    /// 홈 인사말에 쓸 이름
    static let userName = "m3UserName"
}
