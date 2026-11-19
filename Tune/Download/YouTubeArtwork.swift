import UIKit

/// 유튜브 영상 썸네일(i.ytimg.com)을 앨범 표지로 쓸 때 다듬는다.
/// hqdefault는 4:3 안에 16:9 영상이 들어가 위아래가 검은 띠라서, 영상 부분의 가운데 정사각형만 남긴다.
enum YouTubeArtwork {
    /// i.ytimg.com/vi/<영상 ID>/… 주소면 영상 ID
    static func videoID(in url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("ytimg.com") else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(where: { $0 == "vi" || $0 == "vi_webp" }),
              index + 1 < parts.count else { return nil }
        let id = parts[index + 1]
        return id.isEmpty ? nil : id
    }

    /// 더 큰 썸네일부터 차례로 시도한다. maxresdefault(1280×720)는 검은 띠가 없다.
    static func candidates(for url: URL) -> [URL] {
        guard let id = videoID(in: url) else { return [url] }
        var list = ["maxresdefault.jpg", "sddefault.jpg", "hqdefault.jpg"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(id)/\($0)")
        }
        if !list.contains(url) { list.append(url) }
        return list
    }

    /// 영상 부분만 남기고 가운데 정사각형으로 자른다. 실패하면 nil.
    /// 표지가 어두우면 어두운 가장자리를 찾아 자르는 방식은 그림까지 먹어서, 썸네일 비율로 자른다.
    static func squareCover(from data: Data) -> Data? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width >= 64, height >= 64 else { return nil }

        // hqdefault(480×360)·sddefault(640×480)는 4:3 안 가운데 16:9 띠가 실제 영상이다.
        var video = CGRect(x: 0, y: 0, width: width, height: height)
        if abs(width / height - 4.0 / 3.0) < 0.05 {
            let videoHeight = (width * 9 / 16).rounded()
            video = CGRect(x: 0, y: ((height - videoHeight) / 2).rounded(.down), width: width, height: videoHeight)
        }
        // 앨범 표지 영상은 보통 가운데에 꽉 찬 정사각형이라 양옆 여백도 같이 떨어진다.
        let side = min(video.width, video.height)
        let square = CGRect(
            x: (video.minX + (video.width - side) / 2).rounded(.down),
            y: (video.minY + (video.height - side) / 2).rounded(.down),
            width: side,
            height: side
        )
        guard let cropped = cgImage.cropping(to: square) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.92)
    }
}
