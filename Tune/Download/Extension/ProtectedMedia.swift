import CommonCrypto
import Foundation

enum ProtectedMediaError: LocalizedError {
    case malformed(String)
    case missingKey
    case unsupportedScheme(String)
    case unsupportedCodec(String)
    case missingInfo(String)
    case invalidFrames

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            "내려받은 파일의 구조를 읽지 못했어요. (\(detail))"
        case .missingKey:
            "암호화된 음원인데 복호화 키가 없어요. 확장을 다시 설치해 주세요."
        case .unsupportedScheme(let scheme):
            "이 확장은 \(scheme) 방식으로 암호화해요. Tune은 CENC(AES-CTR)만 풀 수 있어요."
        case .unsupportedCodec(let codec):
            "이 음원은 \(codec) 형식이라 Tune에서 풀 수 없어요. 확장 설정에서 FLAC 음질을 골라 주세요."
        case .missingInfo(let detail):
            "암호화 정보가 빠져 있어요. (\(detail))"
        case .invalidFrames:
            "암호를 풀었지만 음원이 깨졌어요. 키가 맞지 않거나 지원하지 않는 형식이에요."
        }
    }
}

/// 확장이 내려준 ISO-BMFF(MP4/MOV) 파일을 살펴보고, 암호화된 FLAC 트랙이면
/// 키로 풀어서 보통 `.flac` 파일로 다시 쓴다.
///
/// Amazon Music 확장은 음원을 CENC(AES-CTR)로 암호화한 MOV 안에 FLAC 프레임으로
/// 담아 준다. ffmpeg의 `-decryption_key`가 하는 일과 같다. Tune에는 ffmpeg이 없으니
/// 필요한 부분(샘플 테이블 + senc IV + AES-CTR)만 직접 처리한다.
enum ProtectedMedia {
    /// 파일을 재생 가능한 형식으로 바꾼다. 바꿀 필요가 없으면 nil.
    static func normalize(fileAt url: URL, decryptionKey: String?) throws -> URL? {
        guard try looksLikeISOBaseMedia(url) else { return nil }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let parser = Parser(bytes: bytes)
        guard bytes.count >= 16, parser.isISOBaseMedia else { return nil }
        let top = try parser.boxes(from: 0, to: bytes.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { return nil }

        let track = try audioTrack(in: moov, parser: parser)
        let codec = track.codec.lowercased()
        let isFLAC = codec == "flac"
        guard track.isEncrypted || isFLAC else { return nil }

        if track.isEncrypted {
            guard let scheme = track.scheme?.lowercased(), scheme == "cenc" else {
                throw ProtectedMediaError.unsupportedScheme(track.scheme ?? "알 수 없는")
            }
        }
        guard isFLAC else {
            throw ProtectedMediaError.unsupportedCodec(track.codec.uppercased())
        }

        var key: [UInt8] = []
        if track.isEncrypted {
            guard let raw = decryptionKey, let parsed = keyBytes(raw) else {
                throw ProtectedMediaError.missingKey
            }
            key = parsed
        }

        let samples = try collectSamples(parser: parser, track: track, top: top)
        guard !samples.isEmpty else { throw ProtectedMediaError.missingInfo("샘플 없음") }
        guard let streamInfo = track.flacMetadata else {
            throw ProtectedMediaError.missingInfo("FLAC STREAMINFO 없음")
        }

        let output = try outputURL(for: url)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else {
            throw ProtectedMediaError.malformed("출력 파일을 열지 못함")
        }
        do {
            try handle.write(contentsOf: Data("fLaC".utf8))
            try handle.write(contentsOf: Data(streamInfo))
            var frames = 0
            for sample in samples {
                let range = sample.offset..<(sample.offset + sample.size)
                guard sample.offset >= 0, range.upperBound <= bytes.count else {
                    throw ProtectedMediaError.malformed("샘플 위치가 파일 범위를 벗어남")
                }
                var payload = [UInt8](bytes[range])
                if track.isEncrypted {
                    guard let iv = sample.iv, !iv.isEmpty else {
                        throw ProtectedMediaError.missingInfo("샘플 IV 없음")
                    }
                    payload = try AESCTR.decrypt(payload, key: key, iv: iv, subsamples: sample.subsamples)
                }
                // FLAC 프레임은 항상 0xFFF8–0xFFFB로 시작한다.
                if payload.count >= 2, payload[0] == 0xFF, payload[1] & 0xFC == 0xF8 {
                    frames += 1
                }
                try handle.write(contentsOf: Data(payload))
            }
            guard frames == samples.count else { throw ProtectedMediaError.invalidFrames }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // MARK: - Track

    private struct Track {
        var codec: String
        var isEncrypted: Bool
        var scheme: String?
        var ivSize: Int
        var constantIV: [UInt8]?
        var flacMetadata: [UInt8]?
        var stbl: Box?
    }

    private static func audioTrack(in moov: Box, parser: Parser) throws -> Track {
        for trak in try parser.children(of: moov, type: "trak") {
            guard let mdia = try parser.child(of: trak, type: "mdia"),
                  let hdlr = try parser.child(of: mdia, type: "hdlr"),
                  parser.fourcc(hdlr.payloadStart + 8) == "soun",
                  let minf = try parser.child(of: mdia, type: "minf"),
                  let stbl = try parser.child(of: minf, type: "stbl"),
                  let stsd = try parser.child(of: stbl, type: "stsd") else { continue }
            let entries = try parser.boxes(from: stsd.payloadStart + 8, to: stsd.end)
            guard let entry = entries.first else { continue }
            let entryChildren = try parser.boxes(from: entry.payloadStart + 28, to: entry.end)
            var codec = entry.type
            var encrypted = false
            var scheme: String?
            var ivSize = 0
            var constantIV: [UInt8]?
            var flacMetadata: [UInt8]?

            if let dfla = entryChildren.first(where: { $0.type == "dfLa" }) {
                flacMetadata = Array(parser.bytes[dfla.payloadStart + 4..<dfla.end])
            }
            if codec == "enca" || codec == "encv" {
                encrypted = true
                if let sinf = entryChildren.first(where: { $0.type == "sinf" }) {
                    let sinfChildren = try parser.boxes(from: sinf.payloadStart, to: sinf.end)
                    if let frma = sinfChildren.first(where: { $0.type == "frma" }) {
                        codec = parser.fourcc(frma.payloadStart)
                    }
                    if let schm = sinfChildren.first(where: { $0.type == "schm" }) {
                        scheme = parser.fourcc(schm.payloadStart + 4)
                    }
                    if let schi = sinfChildren.first(where: { $0.type == "schi" }),
                       let tenc = try parser.child(of: schi, type: "tenc") {
                        let info = try parseTenc(tenc, parser: parser)
                        ivSize = info.ivSize
                        constantIV = info.constantIV
                    }
                }
            }
            return Track(
                codec: codec,
                isEncrypted: encrypted,
                scheme: scheme,
                ivSize: ivSize,
                constantIV: constantIV,
                flacMetadata: flacMetadata,
                stbl: stbl
            )
        }
        throw ProtectedMediaError.missingInfo("오디오 트랙 없음")
    }

    private static func parseTenc(_ box: Box, parser: Parser) throws -> (ivSize: Int, constantIV: [UInt8]?) {
        let version = parser.u8(box.payloadStart)
        // version 0: reserved(1) + isProtected + ivSize + KID
        // version 1: reserved(1) + crypt/skip(1) + isProtected + ivSize + KID
        // ffmpeg는 version 0에서도 예약 바이트를 두 개 쓴다. 실제 파일이 섞여 있어서
        // 두 모양을 모두 시도하고, ivSize가 말이 되는 쪽을 고른다.
        let headerTrailing = version == 0 ? [1, 2] : [2, 3]
        var fallback: (ivSize: Int, constantIV: [UInt8]?)?
        for trailing in headerTrailing {
            var cursor = box.payloadStart + 4 + trailing
            guard cursor + 18 <= box.end else { continue }
            let isProtected = parser.u8(cursor)
            let ivSize = Int(parser.u8(cursor + 1))
            cursor += 2 + 16
            var constantIV: [UInt8]?
            if isProtected == 1 && ivSize == 0, cursor < box.end {
                let length = Int(parser.u8(cursor))
                if cursor + 1 + length <= box.end, length > 0 {
                    constantIV = Array(parser.bytes[(cursor + 1)..<(cursor + 1 + length)])
                }
            }
            guard isProtected <= 1, [0, 8, 16].contains(ivSize) else { continue }
            if isProtected == 1 { return (ivSize, constantIV) }
            if fallback == nil { fallback = (ivSize, constantIV) }
        }
        if let fallback { return fallback }
        throw ProtectedMediaError.missingInfo("tenc 해석 실패")
    }

    // MARK: - Samples

    private struct Sample {
        var offset: Int
        var size: Int
        var iv: [UInt8]?
        var subsamples: [(Int, Int)] = []
    }

    private static func collectSamples(parser: Parser, track: Track, top: [Box]) throws -> [Sample] {
        var samples: [Sample] = []
        let fragmented = top.contains { $0.type == "moof" }
        if !fragmented, let stbl = track.stbl, try parser.child(of: stbl, type: "stsz") != nil {
            samples = try classicSamples(parser: parser, stbl: stbl, track: track)
        } else {
            samples = try fragmentedSamples(parser: parser, top: top, track: track)
        }
        if track.isEncrypted, track.ivSize == 0, let constantIV = track.constantIV {
            for index in samples.indices where samples[index].iv == nil {
                samples[index].iv = constantIV
            }
        }
        return samples
    }

    private static func classicSamples(parser: Parser, stbl: Box, track: Track) throws -> [Sample] {
        guard let stsz = try parser.child(of: stbl, type: "stsz") else {
            throw ProtectedMediaError.missingInfo("stsz 없음")
        }
        let fixedSize = Int(parser.u32(stsz.payloadStart + 4))
        let count = Int(parser.u32(stsz.payloadStart + 8))
        var sizes: [Int] = []
        if fixedSize > 0 {
            sizes = Array(repeating: fixedSize, count: count)
        } else {
            let start = stsz.payloadStart + 12
            guard start + count * 4 <= stsz.end else { throw ProtectedMediaError.malformed("stsz 크기") }
            sizes = (0..<count).map { Int(parser.u32(start + $0 * 4)) }
        }

        let chunkOffsets: [Int]
        if let stco = try parser.child(of: stbl, type: "stco") {
            let entries = Int(parser.u32(stco.payloadStart + 4))
            let start = stco.payloadStart + 8
            guard start + entries * 4 <= stco.end else { throw ProtectedMediaError.malformed("stco 크기") }
            chunkOffsets = (0..<entries).map { Int(parser.u32(start + $0 * 4)) }
        } else if let co64 = try parser.child(of: stbl, type: "co64") {
            let entries = Int(parser.u32(co64.payloadStart + 4))
            let start = co64.payloadStart + 8
            guard start + entries * 8 <= co64.end else { throw ProtectedMediaError.malformed("co64 크기") }
            chunkOffsets = (0..<entries).map { Int(parser.u64(start + $0 * 8)) }
        } else {
            throw ProtectedMediaError.missingInfo("청크 위치 없음")
        }

        guard let stsc = try parser.child(of: stbl, type: "stsc") else {
            throw ProtectedMediaError.missingInfo("stsc 없음")
        }
        let entryCount = Int(parser.u32(stsc.payloadStart + 4))
        var runs: [(firstChunk: Int, samplesPerChunk: Int)] = []
        for index in 0..<entryCount {
            let base = stsc.payloadStart + 8 + index * 12
            guard base + 12 <= stsc.end else { throw ProtectedMediaError.malformed("stsc 크기") }
            runs.append((Int(parser.u32(base)), Int(parser.u32(base + 4))))
        }

        let encryption = try sampleEncryption(parser: parser, box: try parser.child(of: stbl, type: "senc"), track: track, expected: sizes.count, saiz: try parser.child(of: stbl, type: "saiz"))
        var samples: [Sample] = []
        samples.reserveCapacity(sizes.count)
        var sampleIndex = 0
        for (chunkIndex, chunkOffset) in chunkOffsets.enumerated() {
            let perChunk = samplesPerChunk(chunk: chunkIndex + 1, runs: runs)
            var offset = chunkOffset
            for _ in 0..<perChunk {
                guard sampleIndex < sizes.count else { break }
                let size = sizes[sampleIndex]
                samples.append(Sample(
                    offset: offset,
                    size: size,
                    iv: encryption.ivs[sampleIndex],
                    subsamples: encryption.subsamples[sampleIndex]
                ))
                offset += size
                sampleIndex += 1
            }
            if sampleIndex >= sizes.count { break }
        }
        return samples
    }

    private static func samplesPerChunk(chunk: Int, runs: [(firstChunk: Int, samplesPerChunk: Int)]) -> Int {
        var value = runs.first?.samplesPerChunk ?? 0
        for run in runs where run.firstChunk <= chunk {
            value = run.samplesPerChunk
        }
        return value
    }

    private static func fragmentedSamples(parser: Parser, top: [Box], track: Track) throws -> [Sample] {
        var samples: [Sample] = []
        for moof in top where moof.type == "moof" {
            for traf in try parser.children(of: moof, type: "traf") {
                guard let trun = try parser.child(of: traf, type: "trun") else { continue }
                var base = moof.start
                var defaultSize = 0
                if let tfhd = try parser.child(of: traf, type: "tfhd") {
                    let flags = parser.u32(tfhd.payloadStart) & 0xFF_FFFF
                    var cursor = tfhd.payloadStart + 8
                    if flags & 0x1 != 0, cursor + 8 <= tfhd.end {
                        base = Int(parser.u64(cursor))
                        cursor += 8
                    }
                    if flags & 0x2 != 0 { cursor += 4 }
                    if flags & 0x8 != 0 { cursor += 4 }
                    if flags & 0x10 != 0 {
                        defaultSize = Int(parser.u32(cursor))
                        cursor += 4
                    }
                }
                let trunFlags = parser.u32(trun.payloadStart) & 0xFF_FFFF
                let count = Int(parser.u32(trun.payloadStart + 4))
                var cursor = trun.payloadStart + 8
                var dataOffset = 0
                if trunFlags & 0x1 != 0, cursor + 4 <= trun.end {
                    dataOffset = Int(Int32(bitPattern: parser.u32(cursor)))
                    cursor += 4
                }
                if trunFlags & 0x4 != 0 { cursor += 4 }
                let perSampleDuration = trunFlags & 0x100 != 0
                let perSampleSize = trunFlags & 0x200 != 0
                let perSampleFlags = trunFlags & 0x400 != 0
                let perSampleCTS = trunFlags & 0x800 != 0
                let encryption = try sampleEncryption(
                    parser: parser,
                    box: try parser.child(of: traf, type: "senc"),
                    track: track,
                    expected: count,
                    saiz: try parser.child(of: traf, type: "saiz")
                )
                var offset = base + dataOffset
                for index in 0..<count {
                    var size = defaultSize
                    if perSampleDuration { cursor += 4 }
                    if perSampleSize {
                        guard cursor + 4 <= trun.end else { throw ProtectedMediaError.malformed("trun 크기") }
                        size = Int(parser.u32(cursor))
                        cursor += 4
                    }
                    if perSampleFlags { cursor += 4 }
                    if perSampleCTS { cursor += 4 }
                    samples.append(Sample(
                        offset: offset,
                        size: size,
                        iv: index < encryption.ivs.count ? encryption.ivs[index] : nil,
                        subsamples: index < encryption.subsamples.count ? encryption.subsamples[index] : []
                    ))
                    offset += size
                }
            }
        }
        return samples
    }

    private static func sampleEncryption(
        parser: Parser,
        box: Box?,
        track: Track,
        expected: Int,
        saiz: Box?
    ) throws -> (ivs: [[UInt8]?], subsamples: [[(Int, Int)]]) {
        var ivs = [[UInt8]?](repeating: nil, count: expected)
        var subsamples = [[(Int, Int)]](repeating: [], count: expected)
        guard track.isEncrypted else { return (ivs, subsamples) }
        guard track.ivSize > 0 else { return (ivs, subsamples) }
        guard let box else {
            throw ProtectedMediaError.missingInfo("senc 없음")
        }
        let flags = parser.u32(box.payloadStart) & 0xFF_FFFF
        let count = Int(parser.u32(box.payloadStart + 4))
        var cursor = box.payloadStart + 8
        let saizDefault = saiz.map { Int(parser.u8($0.payloadStart + 4)) } ?? 0
        let usesSubsamples = flags & 0x2 != 0 || saizDefault > track.ivSize
        for index in 0..<count {
            guard cursor + track.ivSize <= box.end else {
                throw ProtectedMediaError.malformed("senc IV 크기")
            }
            let iv = Array(parser.bytes[cursor..<(cursor + track.ivSize)])
            cursor += track.ivSize
            if index < expected { ivs[index] = iv }
            if usesSubsamples, cursor + 2 <= box.end {
                let parts = Int(parser.u16(cursor))
                cursor += 2
                var list: [(Int, Int)] = []
                for _ in 0..<parts {
                    guard cursor + 6 <= box.end else { throw ProtectedMediaError.malformed("senc 서브샘플") }
                    let clear = Int(parser.u16(cursor))
                    let protected = Int(parser.u32(cursor + 2))
                    cursor += 6
                    list.append((clear, protected))
                }
                if index < expected { subsamples[index] = list }
            }
        }
        return (ivs, subsamples)
    }

    // MARK: - Output

    private static func looksLikeISOBaseMedia(_ url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 12))
        guard head.count >= 8 else { return false }
        let type = String(bytes: head[4..<8], encoding: .isoLatin1) ?? ""
        return ["ftyp", "styp", "moov", "moof"].contains(type)
    }

    private static func outputURL(for input: URL) throws -> URL {
        var candidate = input.deletingPathExtension().appendingPathExtension("flac")
        if candidate.standardizedFileURL == input.standardizedFileURL {
            candidate = input.deletingPathExtension().appendingPathExtension("decoded.flac")
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            try? FileManager.default.removeItem(at: candidate)
        }
        return candidate
    }

    static func keyBytes(_ raw: String) -> [UInt8]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("0x") { text = String(text.dropFirst(2)) }
        let filtered = text.filter { !$0.isWhitespace }
        if filtered.count.isMultiple(of: 2),
           filtered.count >= 32,
           filtered.allSatisfy({ $0.isHexDigit }) {
            var result: [UInt8] = []
            var index = filtered.startIndex
            while index < filtered.endIndex {
                let next = filtered.index(index, offsetBy: 2)
                guard let byte = UInt8(filtered[index..<next], radix: 16) else { return nil }
                result.append(byte)
                index = next
            }
            return result
        }
        if let data = Data(base64Encoded: filtered), !data.isEmpty {
            return [UInt8](data)
        }
        return nil
    }
}

// MARK: - AES-CTR

private enum AESCTR {
    static func decrypt(_ bytes: [UInt8], key: [UInt8], iv: [UInt8], subsamples: [(Int, Int)]) throws -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }
        guard [16, 24, 32].contains(key.count) else {
            throw ProtectedMediaError.malformed("AES 키 길이")
        }
        var counter = iv
        if counter.count < 16 {
            counter += [UInt8](repeating: 0, count: 16 - counter.count)
        }
        guard counter.count == 16 else { throw ProtectedMediaError.malformed("AES IV 길이") }

        var output = bytes
        var stream: CCCryptorRef?
        let status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt),
            CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            counter,
            key,
            key.count,
            nil,
            0,
            0,
            CCModeOptions(kCCModeOptionCTR_BE),
            &stream
        )
        guard status == kCCSuccess, let stream else {
            throw ProtectedMediaError.malformed("AES-CTR 초기화 실패")
        }
        defer { CCCryptorRelease(stream) }

        func apply(_ range: Range<Int>) throws {
            guard !range.isEmpty else { return }
            let input = Array(bytes[range])
            var buffer = [UInt8](repeating: 0, count: input.count)
            var moved = 0
            let result = input.withUnsafeBytes { inputBytes in
                buffer.withUnsafeMutableBytes { outputBytes in
                    CCCryptorUpdate(
                        stream,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        &moved
                    )
                }
            }
            guard result == kCCSuccess, moved == input.count else {
                throw ProtectedMediaError.malformed("AES-CTR 복호화 실패")
            }
            output.replaceSubrange(range, with: buffer)
        }

        if subsamples.isEmpty {
            try apply(bytes.indices)
        } else {
            var cursor = 0
            for (clear, protected) in subsamples {
                cursor += clear
                let end = min(cursor + protected, bytes.count)
                guard cursor < end else { break }
                try apply(cursor..<end)
                cursor = end
            }
        }
        return output
    }
}

// MARK: - ISO-BMFF

private struct Box {
    let type: String
    let start: Int
    let size: Int
    let headerSize: Int

    var payloadStart: Int { start + headerSize }
    var end: Int { start + size }
}

private struct Parser {
    let bytes: Data

    var isISOBaseMedia: Bool {
        guard bytes.count >= 8 else { return false }
        let type = fourcc(4)
        return ["ftyp", "styp", "moov", "moof", "free", "skip", "wide", "mdat"].contains(type)
    }

    func u8(_ offset: Int) -> UInt8 {
        guard offset >= 0, offset < bytes.count else { return 0 }
        return bytes[offset]
    }

    func u16(_ offset: Int) -> UInt16 {
        UInt16(u8(offset)) << 8 | UInt16(u8(offset + 1))
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u8(offset)) << 24 | UInt32(u8(offset + 1)) << 16 | UInt32(u8(offset + 2)) << 8 | UInt32(u8(offset + 3))
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) << 32 | UInt64(u32(offset + 4))
    }

    func fourcc(_ offset: Int) -> String {
        guard offset >= 0, offset + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .isoLatin1) ?? ""
    }

    func boxes(from start: Int, to end: Int) throws -> [Box] {
        var result: [Box] = []
        var cursor = start
        let limit = min(end, bytes.count)
        while cursor + 8 <= limit {
            var size = Int(u32(cursor))
            let type = fourcc(cursor + 4)
            var header = 8
            if size == 1 {
                guard cursor + 16 <= limit else { break }
                let extended = u64(cursor + 8)
                guard extended <= UInt64(Int.max) else { throw ProtectedMediaError.malformed("박스 크기") }
                size = Int(extended)
                header = 16
            } else if size == 0 {
                size = limit - cursor
            }
            guard size >= header, cursor + size <= limit else {
                throw ProtectedMediaError.malformed("\(type) 박스 크기")
            }
            result.append(Box(type: type, start: cursor, size: size, headerSize: header))
            cursor += size
        }
        return result
    }

    func children(of box: Box, type: String) throws -> [Box] {
        try boxes(from: box.payloadStart, to: box.end).filter { $0.type == type }
    }

    func child(of box: Box, type: String) throws -> Box? {
        try boxes(from: box.payloadStart, to: box.end).first { $0.type == type }
    }
}
