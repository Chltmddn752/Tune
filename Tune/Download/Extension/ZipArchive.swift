import Foundation
import zlib

/// Mornye 확장 패키지(.sflx / .mornye-ext)는 ZIP이다.
/// iOS에는 내장 해제 API가 없어서 ZIP 중앙 디렉터리만 읽고 zlib로 푼다.
enum ZipArchive {
    enum ZipError: LocalizedError {
        case invalidArchive
        case unsupported(String)
        case corruptEntry(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive: "확장 패키지(ZIP)를 읽을 수 없어요."
            case .unsupported(let name): "지원하지 않는 ZIP 형식이에요: \(name)"
            case .corruptEntry(let name): "확장 패키지 안의 \(name) 파일이 손상됐어요."
            }
        }
    }

    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    static func extract(data: Data, to destination: URL) throws {
        let entries = try readEntries(data)
        guard !entries.isEmpty else { throw ZipError.invalidArchive }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        for entry in entries {
            let name = entry.name.replacingOccurrences(of: "\\", with: "/")
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !name.hasPrefix("/") else {
                throw ZipError.unsupported(entry.name)
            }
            let target = destination.appendingPathComponent(parts.joined(separator: "/"))
            guard target.standardizedFileURL.path.hasPrefix(root) else {
                throw ZipError.unsupported(entry.name)
            }
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let payload = try payload(for: entry, in: data)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: target, options: .atomic)
        }
    }

    private static func readEntries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { throw ZipError.invalidArchive }

        // End of central directory: 마지막 64KB 안에서 찾는다.
        let searchStart = max(0, bytes.count - 65_557)
        var eocd = -1
        var index = bytes.count - 22
        while index >= searchStart {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4b, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalidArchive }

        let count = Int(readUInt16(bytes, eocd + 10))
        let directoryOffset = Int(readUInt32(bytes, eocd + 16))
        guard count > 0, directoryOffset > 0, directoryOffset < bytes.count else { throw ZipError.invalidArchive }

        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4b,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                throw ZipError.invalidArchive
            }
            let method = readUInt16(bytes, cursor + 10)
            let compressed = Int(readUInt32(bytes, cursor + 20))
            let uncompressed = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.invalidArchive }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF {
                throw ZipError.unsupported(name)
            }
            entries.append(Entry(name: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func payload(for entry: Entry, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let local = entry.localHeaderOffset
        guard local + 30 <= bytes.count,
              bytes[local] == 0x50, bytes[local + 1] == 0x4b,
              bytes[local + 2] == 0x03, bytes[local + 3] == 0x04 else {
            throw ZipError.corruptEntry(entry.name)
        }
        let nameLength = Int(readUInt16(bytes, local + 26))
        let extraLength = Int(readUInt16(bytes, local + 28))
        let start = local + 30 + nameLength + extraLength
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= bytes.count else {
            throw ZipError.corruptEntry(entry.name)
        }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else { throw ZipError.corruptEntry(entry.name) }
            return compressed
        case 8:
            return try inflateRaw(compressed, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupported("\(entry.name) (method \(entry.method))")
        }
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        var stream = z_stream()
        let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ZipError.corruptEntry(name) }
        defer { inflateEnd(&stream) }

        let result: Int32 = data.withUnsafeBytes { raw in
            output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expectedSize)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw ZipError.corruptEntry(name) }
        let written = Int(stream.total_out)
        guard written == expectedSize else { throw ZipError.corruptEntry(name) }
        return Data(output.prefix(written))
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
