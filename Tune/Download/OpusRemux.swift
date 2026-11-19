import Foundation

/// 유튜브 뮤직 같은 확장이 내려 주는 WebM·Ogg 속 Opus 오디오는 iOS가 그대로 재생하지 못한다.
/// 소리는 다시 인코딩하지 않고, Opus 패킷만 iOS가 읽는 CAF 상자로 옮겨 담는다(음질 손실 없음).
enum OpusRemux {
    enum Container {
        case webm
        case ogg
    }

    enum RemuxError: LocalizedError {
        case notOpus
        case malformed(String)
        case unsupportedLayout(String)

        var errorDescription: String? {
            switch self {
            case .notOpus:
                return "WebM 안에 Opus 오디오가 없어서 재생할 수 있는 형식으로 바꾸지 못했어요."
            case .malformed(let detail):
                return "받은 파일이 깨져 있어서 바꾸지 못했어요. (\(detail))"
            case .unsupportedLayout(let detail):
                return "이 Opus 파일은 아직 바꿀 수 없어요. (\(detail))"
            }
        }
    }

    private struct Parsed {
        var head: [UInt8]
        var packets: [[UInt8]]
        /// Ogg 마지막 페이지의 그래뉼 위치. 끝에서 잘라 낼 프레임을 알 수 있다.
        var endGranule: Int64?
    }

    /// 파일 앞부분으로 WebM/Ogg인지 본다. 다른 형식이면 nil.
    static func container(of url: URL) -> Container? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        let bytes = [UInt8](head)
        if bytes == [0x1A, 0x45, 0xDF, 0xA3] { return .webm }
        if bytes == Array("OggS".utf8) { return .ogg }
        return nil
    }

    /// WebM/Ogg Opus면 같은 폴더에 .caf로 바꿔 쓰고 그 경로를 돌려준다. 바꿀 필요가 없으면 nil.
    static func convertIfNeeded(_ url: URL) throws -> URL? {
        guard let kind = container(of: url) else { return nil }
        let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        let parsed: Parsed
        switch kind {
        case .webm: parsed = try parseWebM(bytes)
        case .ogg: parsed = try parseOgg(bytes)
        }
        let caf = try makeCAF(parsed)
        var output = url.deletingPathExtension().appendingPathExtension("caf")
        if output.standardizedFileURL == url.standardizedFileURL {
            output = url.deletingLastPathComponent().appendingPathComponent("remuxed-\(UUID().uuidString).caf")
        }
        try caf.write(to: output, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        return output
    }

    // MARK: - Opus

    /// Opus 패킷 하나가 담은 48kHz 프레임 수 (RFC 6716 TOC 바이트).
    static func frameCount(_ packet: [UInt8]) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let duration: Int
        if config < 12 {
            duration = [480, 960, 1920, 2880][config % 4]
        } else if config < 16 {
            duration = [480, 960][config % 2]
        } else {
            duration = [120, 240, 480, 960][config % 4]
        }
        let count: Int
        switch toc & 0x03 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return 0 }
            count = Int(packet[1] & 0x3F)
        }
        return count * duration
    }

    // MARK: - WebM (Matroska)

    private struct TrackEntry {
        var number: UInt64?
        var codec = ""
        var codecPrivate: [UInt8] = []
    }

    /// Segment, Tracks, TrackEntry, Audio, Cluster, BlockGroup — 안으로 들어가며 읽는 요소들.
    private static let masterIDs: Set<UInt64> = [0x1853_8067, 0x1654_AE6B, 0xAE, 0xE1, 0x1F43_B675, 0xA0]

    private static func vint(_ data: [UInt8], _ index: Int, strip: Bool = true) throws -> (value: UInt64, length: Int, unknown: Bool) {
        guard index < data.count else { throw RemuxError.malformed("EBML 길이") }
        let first = data[index]
        guard first != 0 else { throw RemuxError.malformed("EBML 길이") }
        var length = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            length += 1
            mask >>= 1
        }
        guard index + length <= data.count else { throw RemuxError.malformed("EBML 길이") }
        let lowBits = first & (mask &- 1)
        var value = UInt64(strip ? lowBits : first)
        var allOnes = lowBits == (mask &- 1)
        for offset in 1..<length {
            let byte = data[index + offset]
            value = (value << 8) | UInt64(byte)
            if byte != 0xFF { allOnes = false }
        }
        return (value, length, strip && allOnes)
    }

    private static func parseWebM(_ data: [UInt8]) throws -> Parsed {
        var index = 0
        var tracks: [TrackEntry] = []
        var opusTrack: TrackEntry?
        var packets: [[UInt8]] = []

        while index < data.count {
            guard let id = try? vint(data, index, strip: false),
                  let size = try? vint(data, index + id.length) else { break }
            index += id.length + size.length

            if masterIDs.contains(id.value) {
                if id.value == 0xAE { tracks.append(TrackEntry()) }
                continue
            }
            guard !size.unknown else { throw RemuxError.malformed("크기를 모르는 요소") }
            // 끝이 잘린 파일이면 거기까지 읽은 것만 쓴다.
            guard size.value <= UInt64(data.count - index) else { break }
            let end = index + Int(size.value)
            let body = Array(data[index..<end])
            index = end

            switch id.value {
            case 0xD7:
                if !tracks.isEmpty { tracks[tracks.count - 1].number = body.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            case 0x86:
                if !tracks.isEmpty { tracks[tracks.count - 1].codec = String(decoding: body, as: UTF8.self) }
            case 0x63A2:
                if !tracks.isEmpty { tracks[tracks.count - 1].codecPrivate = body }
            case 0xA3, 0xA1:
                if opusTrack == nil {
                    opusTrack = tracks.first { $0.codec == "A_OPUS" }
                    guard opusTrack != nil else { throw RemuxError.notOpus }
                }
                try appendBlock(body, track: opusTrack?.number ?? 1, to: &packets)
            default:
                break
            }
        }

        guard let opusTrack else { throw RemuxError.notOpus }
        return Parsed(head: opusTrack.codecPrivate, packets: packets, endGranule: nil)
    }

    private static func appendBlock(_ body: [UInt8], track: UInt64, to packets: inout [[UInt8]]) throws {
        let number = try vint(body, 0)
        guard number.value == track else { return }
        var cursor = number.length + 2  // 트랙 번호 + 16비트 타임코드
        guard cursor < body.count else { throw RemuxError.malformed("블록") }
        let flags = body[cursor]
        cursor += 1
        let lacing = (flags >> 1) & 0x03
        if lacing == 0 {
            packets.append(Array(body[cursor...]))
            return
        }

        guard cursor < body.count else { throw RemuxError.malformed("레이싱") }
        let count = Int(body[cursor]) + 1
        cursor += 1
        var sizes: [Int] = []
        switch lacing {
        case 1:  // Xiph
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard cursor < body.count else { throw RemuxError.malformed("레이싱") }
                    let byte = body[cursor]
                    cursor += 1
                    size += Int(byte)
                    if byte != 0xFF { break }
                }
                sizes.append(size)
            }
        case 3:  // EBML
            let first = try vint(body, cursor)
            cursor += first.length
            sizes.append(Int(first.value))
            if count > 2 {
                for _ in 0..<(count - 2) {
                    let raw = try vint(body, cursor)
                    cursor += raw.length
                    let bias = (Int64(1) << Int64(7 * raw.length - 1)) - 1
                    let next = Int64(sizes[sizes.count - 1]) + Int64(raw.value) - bias
                    guard next >= 0 else { throw RemuxError.malformed("레이싱") }
                    sizes.append(Int(next))
                }
            }
        default:  // 고정 크기
            let each = (body.count - cursor) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used = sizes.reduce(0, +)
        guard cursor + used <= body.count else { throw RemuxError.malformed("레이싱") }
        sizes.append(body.count - cursor - used)
        for size in sizes {
            packets.append(Array(body[cursor..<(cursor + size)]))
            cursor += size
        }
    }

    // MARK: - Ogg

    private static func parseOgg(_ data: [UInt8]) throws -> Parsed {
        var index = 0
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var lastGranule: Int64?

        while index + 27 <= data.count {
            guard Array(data[index..<(index + 4)]) == Array("OggS".utf8) else {
                throw RemuxError.malformed("Ogg 페이지")
            }
            var granule: Int64 = 0
            for offset in (0..<8).reversed() {
                granule = (granule << 8) | Int64(data[index + 6 + offset])
            }
            let segmentCount = Int(data[index + 26])
            guard index + 27 + segmentCount <= data.count else { break }
            let lacing = data[(index + 27)..<(index + 27 + segmentCount)]
            var cursor = index + 27 + segmentCount
            for segment in lacing {
                let size = Int(segment)
                guard cursor + size <= data.count else { break }
                current.append(contentsOf: data[cursor..<(cursor + size)])
                cursor += size
                if size < 255 {
                    packets.append(current)
                    current = []
                }
            }
            if granule >= 0 { lastGranule = granule }
            index = cursor
        }

        guard packets.count > 2, packets[0].starts(with: Array("OpusHead".utf8)) else { throw RemuxError.notOpus }
        // 0번은 OpusHead, 1번은 OpusTags, 그 뒤가 소리 패킷.
        return Parsed(head: packets[0], packets: Array(packets[2...]), endGranule: lastGranule)
    }

    // MARK: - CAF

    private static func makeCAF(_ parsed: Parsed) throws -> Data {
        let packets = parsed.packets.filter { !$0.isEmpty }
        guard let first = packets.first else { throw RemuxError.malformed("소리 패킷이 없음") }

        var channels: UInt32 = 2
        var preSkip: Int64 = 0
        if parsed.head.count >= 19, parsed.head.starts(with: Array("OpusHead".utf8)) {
            channels = UInt32(parsed.head[9])
            preSkip = Int64(parsed.head[10]) | (Int64(parsed.head[11]) << 8)
        }
        guard channels == 1 || channels == 2 else {
            throw RemuxError.unsupportedLayout("\(channels)채널")
        }

        // iOS Opus 디코더는 패킷당 프레임 수가 고정이어야 한다(보통 20ms = 960).
        let framesPerPacket = frameCount(first)
        guard framesPerPacket > 0, packets.allSatisfy({ frameCount($0) == framesPerPacket }) else {
            throw RemuxError.unsupportedLayout("패킷 길이가 섞여 있음")
        }

        let total = Int64(framesPerPacket) * Int64(packets.count)
        var valid = parsed.endGranule.map { $0 - preSkip } ?? (total - preSkip)
        valid = max(0, min(valid, total - preSkip))
        let remainder = total - preSkip - valid

        var out = Data()
        out.append(contentsOf: Array("caff".utf8))
        out.appendBE(UInt16(1))
        out.appendBE(UInt16(0))

        var desc = Data()
        desc.appendBE((48000.0 as Double).bitPattern)
        desc.append(contentsOf: Array("opus".utf8))
        desc.appendBE(UInt32(0))  // flags
        desc.appendBE(UInt32(0))  // bytes per packet (가변)
        desc.appendBE(UInt32(framesPerPacket))
        desc.appendBE(channels)
        desc.appendBE(UInt32(0))  // bits per channel
        out.appendChunk("desc", desc)

        var chan = Data()
        chan.appendBE(channels == 1 ? UInt32((100 << 16) | 1) : UInt32((101 << 16) | 2))
        chan.appendBE(UInt32(0))
        chan.appendBE(UInt32(0))
        out.appendChunk("chan", chan)

        var pakt = Data()
        pakt.appendBE(Int64(packets.count))
        pakt.appendBE(valid)
        pakt.appendBE(Int32(clamping: preSkip))
        pakt.appendBE(Int32(clamping: remainder))
        for packet in packets {
            pakt.appendVLQ(packet.count)
        }
        out.appendChunk("pakt", pakt)

        var audio = Data(count: 4)  // edit count
        audio.reserveCapacity(4 + packets.reduce(0) { $0 + $1.count })
        for packet in packets {
            audio.append(contentsOf: packet)
        }
        out.appendChunk("data", audio)
        return out
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        append(contentsOf: Array(type.utf8))
        appendBE(Int64(body.count))
        append(body)
    }

    mutating func appendVLQ(_ value: Int) {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            groups.append(UInt8(0x80 | (rest & 0x7F)))
            rest >>= 7
        }
        append(contentsOf: groups.reversed())
    }
}
