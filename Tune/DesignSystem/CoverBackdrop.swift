import SwiftUI
import UIKit

/// 커버가 배경으로 녹아드는 화면(Apple Music 방식)에 쓰는 색 묶음.
/// 위쪽은 커버 맨 아래 띠의 색(왼쪽·가운데·오른쪽), 맨 아래는 대표색을 어둡게 한 색이다.
struct CoverBackdrop: Equatable {
    var leading: Color
    var center: Color
    var trailing: Color
    var bottom: Color
    /// 커버 맨 아래 띠 밝기로 정한다. 글자·버튼·구분선 색의 기준이다.
    var isLight: Bool
    /// 상태 표시줄·위 버튼 뒤에 놓이는 커버 윗부분이 밝은지.
    var topIsLight: Bool
    /// 좌우 명암이 크게 갈린 커버는 글자가 묻히지 않게 번지는 띠를 깔지 않는다.
    var showsStrip: Bool

    var textColor: Color { isLight ? .black : .white }

    /// 왼쪽 → 가운데 → 오른쪽 가로 그라데이션. `span`은 이 색들이 차지할 폭의 비율.
    func edgeStops(span: CGFloat = 1) -> [Gradient.Stop] {
        [
            .init(color: leading, location: 0),
            .init(color: center, location: span / 2),
            .init(color: trailing, location: span),
            .init(color: trailing, location: 1)
        ]
    }

    init(edge: ArtworkEdgeColors, representative: UIColor?, palette: [UIColor]) {
        let isLight = edge.isLight
        let zones = [edge.leading, edge.center, edge.trailing].map { Self.readable($0, isLight: isLight) }
        leading = Color(uiColor: zones[0] ?? edge.leading)
        center = Color(uiColor: zones[1] ?? edge.center)
        trailing = Color(uiColor: zones[2] ?? edge.trailing)
        bottom = Color(uiColor: Self.bottomColor(edge: edge, representative: representative,
                                                 palette: palette, isLight: isLight))
        self.isLight = isLight
        topIsLight = edge.top.luma > 0.55
        showsStrip = zones.allSatisfy { $0 == nil }
    }

    /// 글자색과 정반대인 구역만 글자가 읽히는 밝기로 옮긴다. 괜찮은 구역은 nil.
    private static func readable(_ color: UIColor, isLight: Bool) -> UIColor? {
        let luma = color.luma
        if isLight {
            return luma < 0.38 ? color.mixed(with: .white, by: (0.55 - luma) / (1 - luma)) : nil
        }
        return luma > 0.62 ? color.mixed(with: .black, by: 1 - 0.45 / luma) : nil
    }

    /// 글자색은 화면 전체에서 한 가지라서, 맨 아래 색도 커버 아래쪽과 같은 밝기 편에 머물게 한다.
    /// (라이트 앨범은 대표색을 살짝, 다크 앨범은 어두운 보조색과 섞어 더 어둡게)
    private static func bottomColor(edge: ArtworkEdgeColors, representative: UIColor?,
                                    palette: [UIColor], isLight: Bool) -> UIColor {
        let base = representative ?? edge.center
        if isLight {
            let dimmed = base.mixed(with: .black, by: 0.08)
            let floor: CGFloat = 0.62
            guard dimmed.luma < floor else { return dimmed }
            // 대표색이 어두우면 커버 아래쪽 색 쪽으로 끌어올려 색감을 잇는다.
            let target = edge.center.mixed(with: .black, by: 0.08)
            guard target.luma > dimmed.luma else { return target }
            return dimmed.mixed(with: target, by: min((floor - dimmed.luma) / (target.luma - dimmed.luma), 1))
        }
        let darkest = palette.min { $0.luma < $1.luma } ?? base
        let dimmed = base.mixed(with: .black, by: 0.5).mixed(with: darkest, by: 0.35)
        let ceiling: CGFloat = 0.2
        guard dimmed.luma > ceiling else { return dimmed }
        return dimmed.mixed(with: .black, by: 1 - ceiling / dimmed.luma)
    }
}

/// 커버 맨 아래 12% 띠의 왼쪽·가운데·오른쪽 평균색과 맨 위 띠의 평균색.
/// 모델에 필드를 더하면 보관함 마이그레이션이 필요해서, 커버 파일 이름(내용 해시)을 키로 UserDefaults에 둔다.
struct ArtworkEdgeColors {
    var leading: UIColor
    var center: UIColor
    var trailing: UIColor
    var top: UIColor

    /// 띠의 밝기. 제목이 놓이는 가운데에 더 무게를 준다.
    var luma: CGFloat { (leading.luma + center.luma * 2 + trailing.luma) / 4 }
    var isLight: Bool { luma > 0.55 }
    var colors: [Color] { [leading, center, trailing].map { Color(uiColor: $0) } }

    private final class Box {
        let value: ArtworkEdgeColors
        init(_ value: ArtworkEdgeColors) { self.value = value }
    }

    private static let bandRatio: CGFloat = 0.12
    private static let defaultsPrefix = "artworkEdgeColors."
    private static let memory = NSCache<NSString, Box>()

    /// 저장해 둔 값이 있으면 그대로 쓰고, 없으면 한 번만 계산해서 저장한다.
    static func colors(for file: String?) -> ArtworkEdgeColors? {
        guard let file else { return nil }
        if let box = memory.object(forKey: file as NSString) { return box.value }
        if let stored = UserDefaults.standard.string(forKey: defaultsPrefix + file),
           let value = ArtworkEdgeColors(encoded: stored) {
            memory.setObject(Box(value), forKey: file as NSString)
            return value
        }
        guard let image = ArtworkStore.thumbnail(file, maxPixel: 256),
              let value = extract(from: image) else { return nil }
        UserDefaults.standard.set(value.encoded, forKey: defaultsPrefix + file)
        memory.setObject(Box(value), forKey: file as NSString)
        return value
    }

    /// 같은 이름으로 그림을 덮어쓸 때(직접 고른 아티스트 사진) 저장해 둔 색을 지운다.
    static func forget(_ file: String) {
        memory.removeObject(forKey: file as NSString)
        UserDefaults.standard.removeObject(forKey: defaultsPrefix + file)
    }

    /// 커버 없는 앨범처럼 한 가지 색으로 채울 때.
    init(solid color: UIColor) {
        leading = color
        center = color
        trailing = color
        top = color
    }

    init(leading: UIColor, center: UIColor, trailing: UIColor, top: UIColor) {
        self.leading = leading
        self.center = center
        self.trailing = trailing
        self.top = top
    }

    private var encoded: String {
        [leading, center, trailing, top].map(\.hexString).joined(separator: ",")
    }

    private init?(encoded: String) {
        let colors = encoded.split(separator: ",").compactMap { UIColor(hex: String($0)) }
        guard colors.count == 4 else { return nil }
        self.init(leading: colors[0], center: colors[1], trailing: colors[2], top: colors[3])
    }

    static func extract(from image: UIImage) -> ArtworkEdgeColors? {
        guard let bottom = image.band(ratio: bandRatio, atBottom: true),
              let top = image.band(ratio: bandRatio, atBottom: false),
              let zones = averages(of: bottom, zones: 3),
              let topColor = averages(of: top, zones: 1)?.first else { return nil }
        return ArtworkEdgeColors(leading: zones[0], center: zones[1], trailing: zones[2], top: topColor)
    }

    /// 띠를 가로로 나눠 구역마다 평균색을 낸다.
    private static func averages(of band: CGImage, zones: Int) -> [UIColor]? {
        let width = band.width, height = band.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(band, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width >= zones else { return nil }

        var sums = [SIMD3<Double>](repeating: .zero, count: zones)
        var counts = [Double](repeating: 0, count: zones)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let zone = x * zones / width
                sums[zone] += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                counts[zone] += 1
            }
        }
        return zip(sums, counts).map { sum, count in
            let average = sum / (count * 255)
            return UIColor(red: average.x, green: average.y, blue: average.z, alpha: 1)
        }
    }
}

extension UIImage {
    /// 이미지 맨 위나 맨 아래 띠를 잘라 낸다.
    func band(ratio: CGFloat, atBottom: Bool) -> CGImage? {
        guard let cgImage else { return nil }
        let height = max(Int((CGFloat(cgImage.height) * ratio).rounded()), 1)
        return cgImage.cropping(to: CGRect(x: 0, y: atBottom ? cgImage.height - height : 0,
                                           width: cgImage.width, height: height))
    }
}

extension UIColor {
    var luma: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    func mixed(with other: UIColor, by amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = min(max(amount, 0), 1)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}

extension Album {
    /// 커버 맨 아래 색과 대표색으로 만든 배경 색 묶음.
    var coverBackdrop: CoverBackdrop {
        let representative = colorHex.flatMap { UIColor(hex: $0) }
        let edge = ArtworkEdgeColors.colors(for: artworkFile)
            // 커버 없는 앨범은 ArtworkView의 자리 표시 색과 같은 색으로 잇는다.
            ?? ArtworkEdgeColors(solid: representative ?? UIColor(ArtworkPalette.color(for: title)))
        return CoverBackdrop(edge: edge, representative: representative, palette: gradientUIColors)
    }
}

/// 위는 불투명하고 아래로 갈수록 투명해지는 마스크. 시작·끝 지점이 눈에 띄지 않게 smoothstep으로 나눈다.
enum SmoothFade {
    private static let steps = 6

    private static func eased(_ index: Int) -> (t: CGFloat, value: CGFloat) {
        let t = CGFloat(index) / CGFloat(steps + 1)
        return (t, t * t * (3 - 2 * t))
    }

    static func stops(from start: CGFloat, to end: CGFloat) -> [Gradient.Stop] {
        (0...(steps + 1)).map { index in
            let (t, value) = eased(index)
            return .init(color: .black.opacity(1 - value), location: start + (end - start) * t)
        }
    }

    static func mask(from start: CGFloat, to end: CGFloat) -> LinearGradient {
        LinearGradient(stops: stops(from: start, to: end), startPoint: .top, endPoint: .bottom)
    }

    /// 위쪽도 서서히 나타나고 아래쪽으로 사라지는 마스크. 끝이 어디에서도 선으로 보이지 않는다.
    static func band(fadeIn: ClosedRange<CGFloat>, fadeOut: ClosedRange<CGFloat>) -> LinearGradient {
        let appearing: [Gradient.Stop] = (0...(steps + 1)).map { index in
            let (t, value) = eased(index)
            return .init(color: .black.opacity(value),
                         location: fadeIn.lowerBound + (fadeIn.upperBound - fadeIn.lowerBound) * t)
        }
        return LinearGradient(stops: appearing + stops(from: fadeOut.lowerBound, to: fadeOut.upperBound),
                              startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// 커버 높이의 55%까지 불투명, 맨 아래에서 완전히 투명. 덮지 않고 지워서 뒤 배경이 그대로 비친다.
    func coverFadeMask() -> some View {
        mask { SmoothFade.mask(from: 0.55, to: 1) }
    }
}

/// 커버 뒤에서 시작해 아래로 이어지는 배경. 콘텐츠의 `.background(alignment: .top)`에 붙여 함께 스크롤한다.
struct CoverBackdropView: View {
    let backdrop: CoverBackdrop
    let artworkFile: String?
    let coverHeight: CGFloat
    /// 커버 아래쪽 색이 맨 아래 색으로 바뀌는 길이.
    let fadeHeight: CGFloat

    /// 위로 당겨 커버가 늘어나도 빈틈이 없게 커버 위로 넉넉히 깐다.
    private let overscan: CGFloat = 2000
    @State private var strip: UIImage?

    var body: some View {
        let total = overscan + coverHeight + fadeHeight
        ZStack(alignment: .top) {
            LinearGradient(stops: backdrop.edgeStops(), startPoint: .leading, endPoint: .trailing)
                .mask { SmoothFade.mask(from: (overscan + coverHeight) / total, to: 1) }
                .frame(height: total)

            if let strip, backdrop.showsStrip {
                // 위쪽 끝은 커버의 불투명한 부분 뒤에서 서서히 나타나서, 당겨서 커버가 늘어나도 띠의 경계가 보이지 않는다.
                let top = coverHeight * 0.55
                let height = coverHeight * 0.45 + coverHeight * 0.6
                Image(uiImage: strip)
                    .resizable()
                    .frame(height: height)
                    .mask {
                        SmoothFade.band(fadeIn: 0...(coverHeight * 0.3 / height),
                                        fadeOut: (coverHeight * 0.45 / height)...1)
                    }
                    .offset(y: overscan + top)
                    .transition(.opacity)
            }
        }
        .frame(height: total, alignment: .top)
        .offset(y: -overscan)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: artworkFile) { await loadStrip() }
    }

    private func loadStrip() async {
        guard let artworkFile else {
            strip = nil
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            ArtworkStore.edgeStrip(artworkFile)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { strip = loaded }
    }
}
