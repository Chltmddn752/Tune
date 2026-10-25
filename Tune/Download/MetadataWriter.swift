import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// 다운로드한 파일에 제목·아티스트·앨범·커버를 직접 써 넣는다.
/// Tune 보관함 정보뿐 아니라 파일 자체를 읽는 다른 플레이어에서도 보이게 하는 것이 목적이다.
enum MetadataWriter {
    struct Tags {
        var title = ""
        var artist = ""
        var album = ""
        var albumArtist = ""
        var trackNumber: Int?
        var trackTotal: Int?
        var discNumber: Int?
        var discTotal: Int?
        var year: Int?
        var genre = ""
        var isrc = ""
        var cover: Data?

        var hasContent: Bool {
            !title.isEmpty || !artist.isEmpty || !album.isEmpty || !albumArtist.isEmpty
                || !genre.isEmpty || !isrc.isEmpty || trackNumber != nil || discNumber != nil
                || year != nil || cover != nil
        }
    }

    enum Outcome {
        case written
        case skipped
        case unsupported(format: String)
        case failed(String)

        var warning: String? {
            switch self {
            case .written, .skipped:
                nil
            case .unsupported(let format):
                "\(format) 파일은 태그를 직접 쓰지 못했어요."
            case .failed(let message):
                "태그를 쓰지 못했어요: \(message)"
            }
        }
    }

    static func write(_ tags: Tags, to url: URL) async -> Outcome {
        guard tags.hasContent else { return .skipped }
        guard let kind = AudioFileKind.detect(url) else {
            let ext = url.pathExtension.uppercased()
            return .unsupported(format: ext.isEmpty ? "이" : ext)
        }
        switch kind {
        case .mp4:
            return await writeMP4(tags, to: url)
        case .flac:
            return await Task.detached(priority: .utility) {
                writeFLAC(tags, to: url)
            }.value
        case .mp3:
            return await Task.detached(priority: .utility) {
                writeMP3(tags, to: url)
            }.value
        }
    }

    // MARK: - MP4 / M4A

    private static func writeMP4(_ tags: Tags, to url: URL) async -> Outcome {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return .failed("이 파일은 다시 저장할 수 없어요.")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tune-tag-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: temp)

        export.metadata = await metadataItems(for: tags, preserving: asset)
        export.shouldOptimizeForNetworkUse = true

        do {
            try await export.export(to: temp, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return .failed(error.localizedDescription)
        }

        do {
            guard FileManager.default.fileExists(atPath: temp.path),
                  (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0 > 0 else {
                try? FileManager.default.removeItem(at: temp)
                return .failed("태그를 쓴 파일이 비어 있어요.")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return .written
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return .failed(error.localizedDescription)
        }
    }

    private static func metadataItems(for tags: Tags, preserving asset: AVURLAsset) async -> [AVMetadataItem] {
        var items = newMetadataItems(for: tags)
        guard let existing = try? await asset.load(.metadata) else { return items }
        for item in existing {
            guard !isOverwritten(item, tags: tags) else { continue }
            if let key = item.key as? String, key.contains("iTunSMPB") { continue }
            guard let value = try? await item.load(.value) else { continue }
            let copy = AVMutableMetadataItem()
            copy.keySpace = item.keySpace
            copy.key = item.key
            copy.value = value
            if let dataType = item.dataType { copy.dataType = dataType }
            if let attributes = try? await item.load(.extraAttributes) { copy.extraAttributes = attributes }
            items.append(copy)
        }
        return items
    }

    private static func isOverwritten(_ item: AVMetadataItem, tags: Tags) -> Bool {
        var commonKeys: [AVMetadataKey] = []
        if !tags.title.isEmpty { commonKeys.append(.commonKeyTitle) }
        if !tags.artist.isEmpty { commonKeys.append(.commonKeyArtist) }
        if !tags.album.isEmpty { commonKeys.append(.commonKeyAlbumName) }
        if tags.year != nil { commonKeys.append(.commonKeyCreationDate) }
        if tags.cover != nil { commonKeys.append(.commonKeyArtwork) }
        if let common = item.commonKey, commonKeys.contains(where: { common == $0 }) {
            return true
        }

        guard item.keySpace == .iTunes, let key = item.key else { return false }
        var keys: [AVMetadataKey] = []
        if !tags.title.isEmpty { keys.append(.iTunesMetadataKeySongName) }
        if !tags.artist.isEmpty { keys.append(.iTunesMetadataKeyArtist) }
        if !tags.album.isEmpty { keys.append(.iTunesMetadataKeyAlbum) }
        if !tags.albumArtist.isEmpty { keys.append(.iTunesMetadataKeyAlbumArtist) }
        if !tags.genre.isEmpty { keys.append(.iTunesMetadataKeyUserGenre) }
        if tags.year != nil { keys.append(.iTunesMetadataKeyReleaseDate) }
        if let number = tags.trackNumber, number > 0 { keys.append(.iTunesMetadataKeyTrackNumber) }
        if let number = tags.discNumber, number > 0 { keys.append(.iTunesMetadataKeyDiscNumber) }
        if tags.cover != nil { keys.append(.iTunesMetadataKeyCoverArt) }
        return keys.contains { key.isEqual($0) }
    }

    private static func newMetadataItems(for tags: Tags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func text(_ key: AVMetadataKey, _ value: String) {
            guard !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = key as NSString
            item.value = value as NSString
            items.append(item)
        }

        text(.iTunesMetadataKeySongName, tags.title)
        text(.iTunesMetadataKeyArtist, tags.artist)
        text(.iTunesMetadataKeyAlbum, tags.album)
        text(.iTunesMetadataKeyAlbumArtist, tags.albumArtist)
        text(.iTunesMetadataKeyUserGenre, tags.genre)
        text(.iTunesMetadataKeyReleaseDate, tags.year.map(String.init) ?? "")

        // MP4의 trkn/disk는 문자열이 아니라 2바이트 숫자 쌍이다.
        if let number = tags.trackNumber, number > 0 {
            var value = Data([0, 0])
            value.appendBE16(UInt16(clamping: number))
            value.appendBE16(UInt16(clamping: max(0, tags.trackTotal ?? 0)))
            value.append(contentsOf: [0, 0])
            items.append(binaryItem(.iTunesMetadataKeyTrackNumber, data: value))
        }
        if let number = tags.discNumber, number > 0 {
            var value = Data([0, 0])
            value.appendBE16(UInt16(clamping: number))
            value.appendBE16(UInt16(clamping: max(0, tags.discTotal ?? 0)))
            items.append(binaryItem(.iTunesMetadataKeyDiscNumber, data: value))
        }

        if let cover = tags.cover, let info = ImageInfo(cover), let dataType = info.avDataType {
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = AVMetadataKey.iTunesMetadataKeyCoverArt as NSString
            item.value = cover as NSData
            item.dataType = dataType
            items.append(item)
        }
        return items
    }

    private static func binaryItem(_ key: AVMetadataKey, data: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .iTunes
        item.key = key as NSString
        item.value = data as NSData
        return item
    }

    private static func numberText(_ number: Int?, total: Int?) -> String {
        guard let number, number > 0 else { return "" }
        guard let total, total > number else { return "\(number)" }
        return "\(number)/\(total)"
    }

    // MARK: - FLAC

    private static func writeFLAC(_ tags: Tags, to url: URL) -> Outcome {
        guard let data = try? Data(contentsOf: url), data.count > 8, data.starts(with: Data("fLaC".utf8)) else {
            return .failed("FLAC 파일을 읽지 못했어요.")
        }

        var offset = 4
        var blocks: [(type: UInt8, data: Data)] = []
        var sawLast = false
        while offset + 4 <= data.count {
            let header = data[offset]
            let type = header & 0x7F
            let length = (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8)
                | Int(data[offset + 3])
            guard offset + 4 + length <= data.count else {
                return .failed("FLAC 메타데이터가 잘렸어요.")
            }
            blocks.append((type, data.subdata(in: (offset + 4)..<(offset + 4 + length))))
            offset += 4 + length
            if header & 0x80 != 0 {
                sawLast = true
                break
            }
        }
        guard sawLast, blocks.first?.type == 0 else {
            return .failed("FLAC 구조를 알아보지 못했어요.")
        }

        var updated = blocks.filter { block in
            if block.type == 4 { return false }
            if block.type == 6, tags.cover != nil { return false }
            return true
        }
        let existingComments = blocks.first(where: { $0.type == 4 })
            .map { vorbisFields(from: $0.data) } ?? []
        updated.insert((4, vorbisCommentBlock(tags, preserving: existingComments)), at: 1)
        if let cover = tags.cover, let info = ImageInfo(cover) {
            updated.insert((6, pictureBlock(cover, info: info)), at: min(2, updated.count))
        }

        var output = Data("fLaC".utf8)
        output.reserveCapacity(data.count + 4096)
        for (index, block) in updated.enumerated() {
            guard block.data.count <= 0xFFFFFF else {
                return .failed("태그가 너무 커요.")
            }
            let lastFlag: UInt8 = index == updated.count - 1 ? 0x80 : 0
            output.append(lastFlag | (block.type & 0x7F))
            output.append(UInt8((block.data.count >> 16) & 0xFF))
            output.append(UInt8((block.data.count >> 8) & 0xFF))
            output.append(UInt8(block.data.count & 0xFF))
            output.append(block.data)
        }
        output.append(data.subdata(in: offset..<data.count))

        do {
            try output.write(to: url, options: .atomic)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func vorbisCommentBlock(_ tags: Tags, preserving existing: [String]) -> Data {
        let vendor = Data("Tune".utf8)
        let newFields = vorbisFields(tags)
        let newKeys = Set(newFields.compactMap { field -> String? in
            guard let separator = field.firstIndex(of: "=") else { return nil }
            return String(field[..<separator]).uppercased()
        })
        let preserved = existing.filter { field in
            guard let separator = field.firstIndex(of: "=") else { return true }
            return !newKeys.contains(String(field[..<separator]).uppercased())
        }
        let fields = preserved + newFields
        var block = Data()
        block.appendLE(UInt32(vendor.count))
        block.append(vendor)
        block.appendLE(UInt32(fields.count))
        for field in fields {
            let bytes = Data(field.utf8)
            block.appendLE(UInt32(bytes.count))
            block.append(bytes)
        }
        return block
    }

    private static func vorbisFields(from block: Data) -> [String] {
        let bytes = [UInt8](block)
        var index = 0
        guard let vendorLength = readUInt32LE(bytes, &index),
              index + vendorLength <= bytes.count else { return [] }
        index += vendorLength
        guard let count = readUInt32LE(bytes, &index) else { return [] }
        var fields: [String] = []
        for _ in 0..<count {
            guard let length = readUInt32LE(bytes, &index), index + length <= bytes.count else { break }
            fields.append(String(decoding: bytes[index..<(index + length)], as: UTF8.self))
            index += length
        }
        return fields
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        guard index + 4 <= bytes.count else { return nil }
        let value = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
        index += 4
        return value
    }

    private static func vorbisFields(_ tags: Tags) -> [String] {
        var fields: [String] = []
        func add(_ key: String, _ value: String) {
            guard !value.isEmpty else { return }
            fields.append("\(key)=\(value)")
        }
        add("TITLE", tags.title)
        add("ARTIST", tags.artist)
        add("ALBUM", tags.album)
        add("ALBUMARTIST", tags.albumArtist)
        if let number = tags.trackNumber, number > 0 {
            add("TRACKNUMBER", String(number))
        }
        if let total = tags.trackTotal, total > 0 {
            add("TRACKTOTAL", String(total))
        }
        if let number = tags.discNumber, number > 0 {
            add("DISCNUMBER", String(number))
        }
        if let total = tags.discTotal, total > 0 {
            add("DISCTOTAL", String(total))
        }
        if let year = tags.year, year > 0 {
            add("DATE", String(year))
        }
        add("GENRE", tags.genre)
        add("ISRC", tags.isrc)
        return fields
    }

    private static func pictureBlock(_ cover: Data, info: ImageInfo) -> Data {
        let mime = Data(info.mime.utf8)
        var block = Data()
        block.appendBE(3) // front cover
        block.appendBE(UInt32(mime.count))
        block.append(mime)
        block.appendBE(0) // empty description
        block.appendBE(UInt32(max(0, info.width)))
        block.appendBE(UInt32(max(0, info.height)))
        block.appendBE(UInt32(max(0, info.depth)))
        block.appendBE(0) // indexed colors
        block.appendBE(UInt32(cover.count))
        block.append(cover)
        return block
    }

    // MARK: - MP3

    private static func writeMP3(_ tags: Tags, to url: URL) -> Outcome {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .failed("MP3 파일을 읽지 못했어요.")
        }
        guard let audioRange = mp3AudioRange(in: data), audioRange.lowerBound < audioRange.upperBound else {
            return .failed("MP3 오디오 구간을 찾지 못했어요.")
        }

        var frames = Data()
        func textFrame(_ identifier: String, _ value: String) {
            guard !value.isEmpty, identifier.utf8.count == 4 else { return }
            var body = Data([3]) // UTF-8
            body.append(Data(value.utf8))
            frames.append(id3Frame(identifier, body: body))
        }

        textFrame("TIT2", tags.title)
        textFrame("TPE1", tags.artist)
        textFrame("TALB", tags.album)
        textFrame("TPE2", tags.albumArtist)
        textFrame("TRCK", numberText(tags.trackNumber, total: tags.trackTotal))
        textFrame("TPOS", numberText(tags.discNumber, total: tags.discTotal))
        textFrame("TDRC", tags.year.map(String.init) ?? "")
        textFrame("TCON", tags.genre)
        textFrame("TSRC", tags.isrc)
        if let cover = tags.cover, let info = ImageInfo(cover) {
            var body = Data([3])
            body.append(Data(info.mime.utf8))
            body.append(0)
            body.append(3) // front cover
            body.append(0) // empty description
            body.append(cover)
            frames.append(id3Frame("APIC", body: body))
        }
        guard !frames.isEmpty else { return .skipped }

        var output = Data("ID3".utf8)
        output.append(contentsOf: [4, 0, 0]) // ID3v2.4, no flags
        output.appendSynchsafe(frames.count)
        output.append(frames)
        output.append(data.subdata(in: audioRange))

        do {
            try output.write(to: url, options: .atomic)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func mp3AudioRange(in data: Data) -> Range<Int>? {
        var start = 0
        while data.count >= start + 10, data[start..<start + 3] == Data("ID3".utf8) {
            let size = synchsafe(data, at: start + 6)
            var length = 10 + size
            if data[start + 5] & 0x10 != 0 { length += 10 } // footer
            guard length > 0, start + length <= data.count else { return nil }
            start += length
        }

        var end = data.count
        if end - start >= 128, data[(end - 128)..<(end - 125)] == Data("TAG".utf8) {
            end -= 128
        }
        return start..<end
    }

    private static func id3Frame(_ identifier: String, body: Data) -> Data {
        var frame = Data(identifier.utf8)
        frame.appendSynchsafe(body.count)
        frame.append(contentsOf: [0, 0])
        frame.append(body)
        return frame
    }

    private static func synchsafe(_ data: Data, at offset: Int) -> Int {
        (Int(data[offset] & 0x7F) << 21)
            | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7)
            | Int(data[offset + 3] & 0x7F)
    }

    // MARK: - File kind

    private enum AudioFileKind {
        case mp4
        case flac
        case mp3

        static func detect(_ url: URL) -> AudioFileKind? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 12), head.count >= 4 else { return nil }
            if head.starts(with: Data("fLaC".utf8)) { return .flac }
            if head.starts(with: Data("ID3".utf8)) { return .mp3 }
            if head.count >= 8, head[4..<8] == Data("ftyp".utf8) { return .mp4 }
            if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return .mp3 }
            return nil
        }
    }

    // MARK: - Cover info

    private struct ImageInfo {
        let mime: String
        let avDataType: String?
        let width: Int
        let height: Int
        let depth: Int

        init?(_ data: Data) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let type = CGImageSourceGetType(source) as String?
            switch type {
            case "public.jpeg":
                mime = "image/jpeg"
                avDataType = kCMMetadataBaseDataType_JPEG as String
            case "public.png":
                mime = "image/png"
                avDataType = kCMMetadataBaseDataType_PNG as String
            case "com.compuserve.gif":
                mime = "image/gif"
                avDataType = kCMMetadataBaseDataType_GIF as String
            default:
                return nil
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            depth = properties?[kCGImagePropertyDepth] as? Int ?? 24
        }
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendSynchsafe(_ value: Int) {
        append(UInt8((value >> 21) & 0x7F))
        append(UInt8((value >> 14) & 0x7F))
        append(UInt8((value >> 7) & 0x7F))
        append(UInt8(value & 0x7F))
    }
}
