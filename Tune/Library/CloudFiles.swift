import Foundation

/// iCloud Drive · Google Drive 같은 클라우드 폴더의 파일 다루기.
///
/// iCloud는 기기 공간을 아끼려고 받아 둔 파일을 지우고 ".곡이름.flac.icloud" 같은 숨은 자리표시 파일만 남길 수 있다.
/// 그 상태를 "파일이 없어졌다"로 보면 보관함에서 곡이 사라지므로, 자리표시 파일도 "있는 곡"으로 본다.
/// 재생하거나 정보를 읽기 전에는 받아질 때까지 기다린다.
enum CloudFiles {
    private static let suffix = ".icloud"

    /// ".Song.flac.icloud" → "Song.flac"
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count + 1 else { return nil }
        return String(name.dropFirst().dropLast(suffix.count))
    }

    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + suffix)
    }

    /// 기기에 받아져 있거나, 클라우드에만 있는 곡
    static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// 지금 바로 열 수 있게 기기에 받아져 있는지
    static func isDownloaded(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus {
            return status == .current || status == .downloaded
        }
        return true
    }

    /// 앱 폴더 밖(연결한 폴더) 파일인지
    static func isExternal(_ url: URL) -> Bool {
        !url.standardizedFileURL.path.hasPrefix(LibraryPaths.documents.standardizedFileURL.path)
    }

    /// 받기 시작만 한다 (기다리지 않음)
    static func startDownloading(_ url: URL) {
        guard isExternal(url), !isDownloaded(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// 받아질 때까지 기다린다. iCloud는 받기 요청 + 확인, Google Drive 같은 파일 제공 앱은 조정된 읽기로 받게 한다.
    @discardableResult
    static func ensureDownloaded(_ url: URL, timeout: Double = 90) async -> Bool {
        guard isExternal(url) else { return true }
        if FileManager.default.fileExists(atPath: url.path), isDownloaded(url) {
            // 파일 제공 앱(Google Drive 등)은 내용 없이 자리만 있는 파일일 수 있어서, 한 번 조정된 읽기를 거친다.
            await coordinatedRead(url)
            return true
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        await coordinatedRead(url)
        let start = Date()
        while !isDownloaded(url), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(300))
        }
        return isDownloaded(url)
    }

    private static func coordinatedRead(_ url: URL) async {
        await Task.detached(priority: .userInitiated) {
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { _ in }
        }.value
    }
}
