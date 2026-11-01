import SwiftUI
import UIKit

/// 앨범 커버에서 뽑은 색 여러 개로 화면 배경을 부드럽게 채운다.
///
/// `.vivid`는 Apple Music 앨범 화면처럼 위는 아트 색, 아래로 갈수록 어두워진다.
/// `.soft`는 아래로 갈수록 시스템 배경색으로 녹아들어 목록 글자를 그대로 쓸 수 있다.
struct ArtworkGradientBackground: View {
    enum Style { case vivid, soft }

    let colors: [Color]
    var style: Style = .vivid
    var isLight = false
    /// 스크롤에 맞춰 배경을 조금만 움직인다(패럴랙스).
    var parallax: CGFloat = 0

    private var resolved: [Color] {
        let base = colors.isEmpty ? [Color(.systemGray4)] : Array(colors.prefix(4))
        return (0..<9).map { base[$0 % base.count] }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mesh
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(1.3)
                    .offset(y: -min(max(parallax, 0), 320) * 0.1)

                switch style {
                case .vivid:
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.28), location: 0.55),
                            .init(color: .black.opacity(isLight ? 0.18 : 0.55), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                case .soft:
                    LinearGradient(
                        stops: [
                            .init(color: Color(.systemBackground).opacity(0), location: 0),
                            .init(color: Color(.systemBackground).opacity(0.55), location: 0.55),
                            .init(color: Color(.systemBackground), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var mesh: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
                SIMD2(0, 0.5), SIMD2(0.5, 0.5), SIMD2(1, 0.5),
                SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)
            ],
            colors: resolved
        )
    }
}

extension Album {
    /// 커버에서 뽑아 둔 팔레트. 예전 앨범은 대표색 하나만 있어도 그 색으로 채운다.
    var gradientColors: [Color] {
        var colors = PaletteCodec.decode(paletteHex)
        if colors.isEmpty, let colorHex {
            colors = [Color(hex: colorHex)]
        }
        return Array(colors.prefix(4))
    }

    var gradientUIColors: [UIColor] {
        (paletteHex ?? colorHex ?? "")
            .split(separator: ",")
            .compactMap { UIColor(hex: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// 팔레트 평균 밝기로 글자색을 고른다.
    var gradientIsLight: Bool {
        let colors = gradientUIColors
        guard !colors.isEmpty else { return false }
        let total = colors.reduce(0.0) { sum, color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return sum + (0.299 * r + 0.587 * g + 0.114 * b)
        }
        return total / Double(colors.count) > 0.68
    }

    var gradientTextColor: Color { gradientIsLight ? .black : .white }
}
