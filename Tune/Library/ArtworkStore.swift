import CryptoKit
import SwiftUI
import UIKit

/// 커버 이미지를 공유 폴더에 저장하고 불러온다. 위젯도 같은 파일을 읽는다.
enum ArtworkStore {
    private static let cache = NSCache<NSString, UIImage>()

    static func save(_ data: Data, maxPixel: CGFloat = 1200) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest.prefix(24)).jpg"
        let url = AppGroup.artworkDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            let resized = image.resized(maxPixel: maxPixel)
            try? resized.jpegData(compressionQuality: 0.88)?.write(to: url, options: .atomic)
        }
        return name
    }

    static func save(image: UIImage, name: String) -> String? {
        let url = AppGroup.artworkDirectory.appendingPathComponent(name)
        guard let data = image.resized(maxPixel: 1200).jpegData(compressionQuality: 0.88) else { return nil }
        try? data.write(to: url, options: .atomic)
        cache.removeObject(forKey: name as NSString)
        return name
    }

    static func url(_ name: String?) -> URL? {
        guard let name else { return nil }
        return AppGroup.artworkDirectory.appendingPathComponent(name)
    }

    static func image(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = url(name), let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func directorySize() -> Int64 {
        FileManager.default.sizeOfDirectory(AppGroup.artworkDirectory)
    }
}

extension UIImage {
    func resized(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height) * scale
        guard longest > maxPixel else { return self }
        let ratio = maxPixel / longest
        let target = CGSize(width: size.width * scale * ratio, height: size.height * scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

extension FileManager {
    func sizeOfDirectory(_ url: URL) -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// 커버에서 대표색을 뽑는다. 24×24로 줄인 뒤 k-평균으로 색을 묶는다.
enum ColorExtractor {
    static func palette(from image: UIImage, count: Int = 4) -> [UIColor] {
        let side = 24
        guard let cgImage = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }

        var points: [SIMD3<Double>] = []
        points.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            points.append(SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255)
        }
        guard !points.isEmpty else { return [] }

        let k = min(count, points.count)
        var centers = (0..<k).map { points[($0 * points.count) / k] }
        var assignments = [Int](repeating: 0, count: points.count)

        for _ in 0..<10 {
            for (i, point) in points.enumerated() {
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (j, center) in centers.enumerated() {
                    let d = point - center
                    let distance = (d * d).sum()
                    if distance < bestDistance { bestDistance = distance; best = j }
                }
                assignments[i] = best
            }
            for j in 0..<k {
                let members = points.indices.filter { assignments[$0] == j }.map { points[$0] }
                if !members.isEmpty {
                    centers[j] = members.reduce(SIMD3<Double>(repeating: 0), +) / Double(members.count)
                }
            }
        }

        let sizes = (0..<k).map { j in assignments.filter { $0 == j }.count }
        return (0..<k)
            .sorted { sizes[$0] > sizes[$1] }
            .map { UIColor(red: centers[$0].x, green: centers[$0].y, blue: centers[$0].z, alpha: 1) }
    }

    /// 배경으로 쓰기 좋게 너무 어둡거나 너무 흐린 색을 보정한다.
    static func backgroundColor(from palette: [UIColor]) -> UIColor {
        guard let base = palette.first else { return .darkGray }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        brightness = min(max(brightness, 0.22), 0.88)
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((int >> 16) & 0xFF) / 255,
            green: CGFloat((int >> 8) & 0xFF) / 255,
            blue: CGFloat(int & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// 밝은 배경이면 true (글자를 검정으로).
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62
    }
}

extension Color {
    init(hex: String?, fallback: Color = Color(.systemGray4)) {
        if let hex, let ui = UIColor(hex: hex) {
            self.init(uiColor: ui)
        } else {
            self = fallback
        }
    }
}

enum PaletteCodec {
    static func encode(_ colors: [UIColor]) -> String {
        colors.map(\.hexString).joined(separator: ",")
    }

    static func decode(_ value: String?) -> [Color] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap { UIColor(hex: String($0)) }.map { Color(uiColor: $0) }
    }
}
