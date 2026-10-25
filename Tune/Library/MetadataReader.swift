import AVFoundation
import Foundation

struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var duration: Double = 0
    var artworkData: Data?
    var lyrics: String?

    mutating func fill(from other: TrackMetadata) {
        title = title ?? other.title
        artist = artist ?? other.artist
        album = album ?? other.album
        albumArtist = albumArtist ?? other.albumArtist
        trackNumber = trackNumber ?? other.trackNumber
        discNumber = discNumber ?? other.discNumber
        year = year ?? other.year
        genre = genre ?? other.genre
        if duration <= 0 { duration = other.duration }
        artworkData = artworkData ?? other.artworkData
        lyrics = lyrics ?? other.lyrics
    }
}

enum MetadataReader {
    /// 늘 재생되는 형식
    static let commonExtensions: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff", "caf"]
    /// 들어올 수 있는 형식 전부 (mp4 · Dolby(ec3/ac3/ac4) · opus 등은 가져올 때 이 기기에서 재생되는지 확인한다)
    static let audioExtensions: Set<String> = commonExtensions.union(["mp4", "m4b", "ec3", "eac3", "ac3", "ac4", "opus", "ogg", "oga", "mka"])

    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        guard playable else { return false }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return !audio.isEmpty
    }
    static let losslessExtensions: Set<String> = ["flac", "wav", "aif", "aiff"]

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    static func read(url: URL) async -> TrackMetadata {
        var meta = TrackMetadata()
        let ext = url.pathExtension.lowercased()

        // FLAC 태그는 AVFoundation이 못 읽는 경우가 많아서 직접 읽는다.
        if ext == "flac", let flac = FLACParser.parse(url: url) {
            meta = flac
        }

        let asset = AVURLAsset(url: url)
        if meta.duration <= 0, let duration = try? await asset.load(.duration), duration.seconds.isFinite {
            meta.duration = duration.seconds
        }

        guard let items = try? await asset.load(.metadata) else { return meta }
        var found = TrackMetadata()

        for item in items {
            let identifier = item.identifier
            let commonKey = item.commonKey
            let string = (try? await item.load(.stringValue)) ?? nil
            let data = (try? await item.load(.dataValue)) ?? nil

            switch commonKey {
            case .some(.commonKeyTitle): found.title = found.title ?? string?.cleaned
            case .some(.commonKeyArtist): found.artist = found.artist ?? string?.cleaned
            case .some(.commonKeyAlbumName): found.album = found.album ?? string?.cleaned
            case .some(.commonKeyArtwork): found.artworkData = found.artworkData ?? data
            case .some(.commonKeyCreationDate): found.year = found.year ?? string.flatMap(parseYear)
            default: break
            }

            switch identifier {
            case .some(.id3MetadataBand), .some(.iTunesMetadataAlbumArtist):
                found.albumArtist = found.albumArtist ?? string?.cleaned
            case .some(.id3MetadataTrackNumber):
                found.trackNumber = found.trackNumber ?? string.flatMap(parseNumberPair)
            case .some(.iTunesMetadataTrackNumber):
                found.trackNumber = found.trackNumber ?? data.flatMap(parseITunesPair)
            case .some(.id3MetadataPartOfASet):
                found.discNumber = found.discNumber ?? string.flatMap(parseNumberPair)
            case .some(.iTunesMetadataDiscNumber):
                found.discNumber = found.discNumber ?? data.flatMap(parseITunesPair)
            case .some(.id3MetadataYear), .some(.id3MetadataRecordingTime), .some(.iTunesMetadataReleaseDate):
                found.year = found.year ?? string.flatMap(parseYear)
            case .some(.id3MetadataContentType), .some(.iTunesMetadataUserGenre), .some(.quickTimeMetadataGenre):
                found.genre = found.genre ?? string.map(cleanGenre)
            case .some(.id3MetadataUnsynchronizedLyric), .some(.iTunesMetadataLyrics):
                found.lyrics = found.lyrics ?? string
            default:
                break
            }
        }

        meta.fill(from: found)
        return meta
    }

    static func parseNumberPair(_ value: String) -> Int? {
        Int(value.split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    static func parseITunesPair(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }

    static func parseYear(_ value: String) -> Int? {
        let digits = value.prefix(4)
        guard digits.count == 4, let year = Int(digits), year > 1800 else { return nil }
        return year
    }

    /// ID3 장르가 "(13)" 같은 숫자로 들어있는 경우는 버린다.
    static func cleanGenre(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("("), trimmed.hasSuffix(")") { return "" }
        return trimmed
    }
}

private extension String {
    var cleaned: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// FLAC 파일의 STREAMINFO, VORBIS_COMMENT, PICTURE 블록을 읽는다.
enum FLACParser {
    static func parse(url: URL) -> TrackMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var meta = TrackMetadata()
        var isLast = false
        var sampleRate = 0
        var totalSamples: UInt64 = 0

        while !isLast {
            guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else { break }
            let header = [UInt8](headerData)
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])

            if type == 4 || type == 6 || type == 0 {
                guard let blockData = try? handle.read(upToCount: length), blockData.count == length else { break }
                let block = [UInt8](blockData)
                switch type {
                case 0 where block.count >= 18:
                    sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12]) >> 4
                    totalSamples = UInt64(block[13] & 0x0F) << 32 | UInt64(block[14]) << 24
                        | UInt64(block[15]) << 16 | UInt64(block[16]) << 8 | UInt64(block[17])
                case 4:
                    parseVorbisComments(block, into: &meta)
                case 6:
                    if meta.artworkData == nil { meta.artworkData = parsePicture(block) }
                default:
                    break
                }
            } else {
                // 필요 없는 블록은 건너뛴다.
                guard let offset = try? handle.offset() else { break }
                try? handle.seek(toOffset: offset + UInt64(length))
            }
        }

        if sampleRate > 0 {
            meta.duration = Double(totalSamples) / Double(sampleRate)
        }
        return meta
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        guard index + 4 <= bytes.count else { return nil }
        let value = Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
        index += 4
        return value
    }

    private static func readUInt32BE(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        guard index + 4 <= bytes.count else { return nil }
        let value = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        index += 4
        return value
    }

    private static func parseVorbisComments(_ bytes: [UInt8], into meta: inout TrackMetadata) {
        var index = 0
        guard let vendorLength = readUInt32LE(bytes, &index) else { return }
        index += vendorLength
        guard let count = readUInt32LE(bytes, &index) else { return }

        for _ in 0..<count {
            guard let length = readUInt32LE(bytes, &index), index + length <= bytes.count else { return }
            let comment = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
            index += length
            guard let separator = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<separator].uppercased()
            let value = String(comment[comment.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "TITLE": meta.title = meta.title ?? value
            case "ARTIST": meta.artist = meta.artist ?? value
            case "ALBUM": meta.album = meta.album ?? value
            case "ALBUMARTIST", "ALBUM ARTIST": meta.albumArtist = meta.albumArtist ?? value
            case "TRACKNUMBER": meta.trackNumber = meta.trackNumber ?? MetadataReader.parseNumberPair(value)
            case "DISCNUMBER": meta.discNumber = meta.discNumber ?? MetadataReader.parseNumberPair(value)
            case "DATE", "YEAR": meta.year = meta.year ?? MetadataReader.parseYear(value)
            case "GENRE": meta.genre = meta.genre ?? value
            case "LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS": meta.lyrics = meta.lyrics ?? value
            default: break
            }
        }
    }

    private static func parsePicture(_ bytes: [UInt8]) -> Data? {
        var index = 4 // 사진 종류
        guard let mimeLength = readUInt32BE(bytes, &index) else { return nil }
        index += mimeLength
        guard let descriptionLength = readUInt32BE(bytes, &index) else { return nil }
        index += descriptionLength + 16 // 너비, 높이, 색 깊이, 색 수
        guard let dataLength = readUInt32BE(bytes, &index), index + dataLength <= bytes.count else { return nil }
        return Data(bytes[index..<(index + dataLength)])
    }
}
