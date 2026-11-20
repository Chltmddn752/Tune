import Foundation

/// CAF 파일 태그. 유튜브 뮤직에서 받은 Opus를 CAF로 옮겨 담으니, 제목·아티스트·표지도 파일 안에 넣어야
/// 같은 폴더를 연결한 다른 기기에서 파일 이름 대신 제대로 보인다.
///
/// - 글자 태그: CAF 표준 'info' 청크(키\0값\0 …)
/// - 표지: 'uuid' 청크(아래 고정 UUID + 이미지 바이트). 다른 프로그램은 모르는 청크라 그냥 건너뛴다.
enum CAFTags {
    private static let artworkUUID: Data = withUnsafeBytes(
        of: UUID(uuidString: "6A0C2F3E-6E75-4E65-8F2B-7475E1E0A121")!.uuid
    ) { Data($0) }

    private struct Chunk {
        var type: String
        var body: Data
    }

    static func isCAF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return head == Data("caff".utf8)
    }

    // MARK: - 쓰기

    static func write(_ tags: MetadataWriter.Tags, to url: URL) throws {
        let file = try Data(contentsOf: url)
        guard let chunks = parse(file) else { throw CocoaError(.fileReadCorruptFile) }

        var info: [(String, String)] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            info.append((key, value.replacingOccurrences(of: "\0", with: "")))
        }
        add("title", tags.title)
        add("artist", tags.artist)
        add("album", tags.album)
        add("album artist", tags.albumArtist)
        add("genre", tags.genre)
        add("track number", tags.trackNumber.map { number in
            tags.trackTotal.map { "\(number)/\($0)" } ?? "\(number)"
        })
        add("disc number", tags.discNumber.map { number in
            tags.discTotal.map { "\(number)/\($0)" } ?? "\(number)"
        })
        add("year", tags.year.map(String.init))
        add("isrc", tags.isrc)

        var infoBody = Data()
        infoBody.appendBE(UInt32(info.count))
        for (key, value) in info {
            infoBody.append(Data(key.utf8))
            infoBody.append(0)
            infoBody.append(Data(value.utf8))
            infoBody.append(0)
        }

        var output = Data(file.prefix(8))
        var inserted = false
        for chunk in chunks {
            // 예전 태그 청크는 버리고 새로 넣는다.
            if chunk.type == "info" { continue }
            if chunk.type == "uuid", chunk.body.prefix(16) == artworkUUID { continue }
            if chunk.type == "data", !inserted {
                appendChunk("info", infoBody, to: &output)
                if let cover = tags.cover, !cover.isEmpty {
                    appendChunk("uuid", artworkUUID + cover, to: &output)
                }
                inserted = true
            }
            appendChunk(chunk.type, chunk.body, to: &output)
        }
        guard inserted else { throw CocoaError(.fileReadCorruptFile) }
        try output.write(to: url, options: .atomic)
    }

    // MARK: - 읽기

    static func read(_ url: URL) -> TrackMetadata? {
        guard isCAF(url), let file = try? Data(contentsOf: url, options: .mappedIfSafe),
              let chunks = parse(file) else { return nil }
        var meta = TrackMetadata()
        var found = false
        for chunk in chunks {
            if chunk.type == "info" {
                for (key, value) in parseInfo(chunk.body) {
                    found = true
                    switch key.lowercased() {
                    case "title": meta.title = value
                    case "artist": meta.artist = value
                    case "album": meta.album = value
                    case "album artist": meta.albumArtist = value
                    case "genre": meta.genre = value
                    case "track number": meta.trackNumber = Int(value.split(separator: "/").first ?? "")
                    case "disc number": meta.discNumber = Int(value.split(separator: "/").first ?? "")
                    case "year": meta.year = Int(value.prefix(4))
                    default: break
                    }
                }
            } else if chunk.type == "uuid", chunk.body.count > 16, chunk.body.prefix(16) == artworkUUID {
                meta.artworkData = Data(chunk.body.dropFirst(16))
                found = true
            }
        }
        return found ? meta : nil
    }

    // MARK: - 형식

    private static func parse(_ file: Data) -> [Chunk]? {
        let bytes = [UInt8](file)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("caff".utf8) else { return nil }
        var chunks: [Chunk] = []
        var index = 8
        while index + 12 <= bytes.count {
            let type = String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
            var size: Int64 = 0
            for offset in 0..<8 { size = (size << 8) | Int64(bytes[index + 4 + offset]) }
            let start = index + 12
            // 크기 -1은 "파일 끝까지"(마지막 data 청크에서만 쓰인다).
            let end = size < 0 ? bytes.count : start + Int(min(size, Int64(bytes.count - start)))
            chunks.append(Chunk(type: type, body: Data(bytes[start..<end])))
            index = end
        }
        return chunks
    }

    private static func parseInfo(_ body: Data) -> [(String, String)] {
        let bytes = [UInt8](body)
        guard bytes.count >= 4 else { return [] }
        let count = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        var strings: [String] = []
        var current: [UInt8] = []
        for byte in bytes.dropFirst(4) {
            if byte == 0 {
                strings.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(byte)
            }
        }
        var pairs: [(String, String)] = []
        var index = 0
        while index + 1 < strings.count, pairs.count < count {
            pairs.append((strings[index], strings[index + 1]))
            index += 2
        }
        return pairs
    }

    private static func appendChunk(_ type: String, _ body: Data, to output: inout Data) {
        output.append(Data(type.utf8))
        output.appendBE(Int64(body.count))
        output.append(body)
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
