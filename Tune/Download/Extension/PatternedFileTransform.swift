import CommonCrypto
import Foundation

/// Deezer가 쓰는 `file.transformPatternedBlocks` 구현.
/// 2KB 세그먼트 중 일부만 Blowfish-CBC(패딩 없음)로 풀고, 각 세그먼트마다 IV를 다시 쓴다.
enum PatternedFileTransform {
    private struct Options {
        var operation = "decrypt"
        var algorithm = ""
        var mode = "cbc"
        var key = Data()
        var iv = Data()
        var segmentSize = 2048
        var transformEvery = 1
        var transformOffset = 0
        var transformPartial = false
        var bufferSize = 1 << 20
    }

    private enum TransformError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let value): value
            }
        }
    }

    static func run(
        input: URL,
        output: URL,
        optionsJSON: String,
        progress: (Int64, Int64) -> Void,
        cancelled: () -> Bool
    ) -> [String: Any] {
        do {
            guard input.standardizedFileURL != output.standardizedFileURL else {
                throw TransformError.message("input and output paths must be different")
            }
            let options = try parse(optionsJSON)
            guard let algorithm = cipherAlgorithm(options.algorithm) else {
                throw TransformError.message("unsupported block cipher algorithm: \(options.algorithm)")
            }
            let blockSize = algorithm == CCAlgorithm(kCCAlgorithmBlowfish) ? kCCBlockSizeBlowfish : kCCBlockSizeAES128
            guard options.mode == "cbc" || options.mode == "ctr" else {
                throw TransformError.message("unsupported block cipher mode: \(options.mode)")
            }
            guard options.iv.count == blockSize else {
                throw TransformError.message("iv must be \(blockSize) bytes for \(options.algorithm)")
            }
            guard !options.key.isEmpty else {
                throw TransformError.message("key is required")
            }
            var key = options.key
            if algorithm == CCAlgorithm(kCCAlgorithmBlowfish) {
                guard key.count <= 56 else { throw TransformError.message("blowfish key is too long") }
                // RustCrypto/Go allow 1–56 bytes; CommonCrypto's Blowfish path
                // is happiest at four or more, so repeat short keys exactly once.
                if key.count < 4 {
                    let original = key
                    while key.count < 4 { key.append(contentsOf: original) }
                }
            } else {
                guard [16, 24, 32].contains(key.count) else {
                    throw TransformError.message("aes key must be 16, 24, or 32 bytes")
                }
            }
            if options.mode == "cbc" && options.segmentSize % blockSize != 0 {
                throw TransformError.message("segmentSize must be a multiple of \(blockSize) bytes for CBC")
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
            let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard total >= 0 else { throw TransformError.message("invalid input size") }

            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            guard let source = try? FileHandle(forReadingFrom: input),
                  let destination = try? FileHandle(forWritingTo: output) else {
                throw TransformError.message("failed to open transform files")
            }
            defer { try? source.close() }
            defer { try? destination.close() }

            let segmentSize = options.segmentSize
            let bufferSize = max(segmentSize, (options.bufferSize / segmentSize) * segmentSize)
            var processed: Int64 = 0
            var segmentIndex = 0
            var transformed = 0

            while processed < total {
                if cancelled() { throw TransformError.message("cancelled") }
                let wanted = Int(min(Int64(bufferSize), total - processed))
                var chunk = Data()
                while chunk.count < wanted {
                    let part = try source.read(upToCount: wanted - chunk.count) ?? Data()
                    if part.isEmpty { break }
                    chunk.append(part)
                }
                if chunk.isEmpty { break }

                var bytes = [UInt8](chunk)
                var offset = 0
                while offset < bytes.count {
                    if cancelled() { throw TransformError.message("cancelled") }
                    let length = min(segmentSize, bytes.count - offset)
                    let selected = segmentIndex % options.transformEvery == options.transformOffset
                    let canTransform = length == segmentSize || options.transformPartial
                    if selected && canTransform {
                        if options.mode == "cbc" && length % blockSize != 0 {
                            throw TransformError.message("selected segment \(segmentIndex) is not a multiple of \(blockSize) bytes")
                        }
                        var segment = Array(bytes[offset..<(offset + length)])
                        guard transform(
                            &segment,
                            key: key,
                            iv: options.iv,
                            algorithm: algorithm,
                            mode: options.mode,
                            decrypt: options.operation == "decrypt"
                        ) else {
                            throw TransformError.message("block cipher transform failed at segment \(segmentIndex)")
                        }
                        bytes.replaceSubrange(offset..<(offset + length), with: segment)
                        transformed += 1
                    }
                    offset += length
                    segmentIndex += 1
                }

                try destination.write(contentsOf: Data(bytes))
                processed += Int64(bytes.count)
                progress(processed, total)
            }
            try destination.synchronize()
            return [
                "success": true,
                "path": output.path,
                "bytes_processed": processed,
                "segments_processed": segmentIndex,
                "segments_transformed": transformed,
            ]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    // MARK: - Options

    private static func parse(_ json: String) throws -> Options {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw TransformError.message("options must be a JSON object")
        }

        func text(_ key: String, _ fallback: String = "") -> String {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
            return fallback
        }
        func boolean(_ key: String, _ fallback: Bool) -> Bool {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.boolValue }
            if let value = object[key] as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
            return fallback
        }
        func bytes(_ key: String, encodingKey: String) throws -> Data {
            guard let raw = object[key] as? String, !raw.isEmpty else {
                throw TransformError.message("\(key) is required")
            }
            let encoding = text(encodingKey, "utf8")
            switch encoding {
            case "hex":
                let values = raw.filter { !$0.isWhitespace }
                guard values.count % 2 == 0 else { throw TransformError.message("invalid hex \(key)") }
                var result = Data()
                var index = values.startIndex
                while index < values.endIndex {
                    let next = values.index(index, offsetBy: 2)
                    guard let byte = UInt8(values[index..<next], radix: 16) else {
                        throw TransformError.message("invalid hex \(key)")
                    }
                    result.append(byte)
                    index = next
                }
                return result
            case "base64", "base64url":
                var value = raw
                if encoding == "base64url" {
                    value = value.replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/")
                }
                guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters) else {
                    throw TransformError.message("invalid base64 \(key)")
                }
                return data
            default:
                return Data(raw.utf8)
            }
        }

        let operation = text("operation", "decrypt")
        guard operation == "decrypt" || operation == "encrypt" else {
            throw TransformError.message("operation must be decrypt or encrypt")
        }
        let padding = text("padding", "")
        guard padding.isEmpty || padding == "none" else {
            throw TransformError.message("patterned file transforms only support padding: none")
        }
        var options = Options()
        options.operation = operation
        options.algorithm = text("algorithm")
        options.mode = text("mode", "cbc")
        options.key = try bytes("key", encodingKey: "keyEncoding")
        options.iv = try bytes("iv", encodingKey: "ivEncoding")
        options.segmentSize = max(1, integer("segmentSize", 0))
        options.transformEvery = max(1, integer("transformEvery", 1))
        options.transformOffset = max(0, integer("transformOffset", 0))
        options.transformPartial = boolean("transformPartial", false)
        let requestedBuffer = max(options.segmentSize, integer("bufferSize", 1 << 20))
        options.bufferSize = min(requestedBuffer, 16 << 20)
        guard options.transformOffset < options.transformEvery else {
            throw TransformError.message("transformOffset must be less than transformEvery")
        }
        return options
    }

    // MARK: - Ciphers

    private static func cipherAlgorithm(_ name: String) -> CCAlgorithm? {
        switch name {
        case "blowfish": CCAlgorithm(kCCAlgorithmBlowfish)
        case "aes", "aes128", "aes192", "aes256": CCAlgorithm(kCCAlgorithmAES)
        default: nil
        }
    }

    private static func transform(
        _ data: inout [UInt8],
        key: Data,
        iv: Data,
        algorithm: CCAlgorithm,
        mode: String,
        decrypt: Bool
    ) -> Bool {
        guard !data.isEmpty else { return true }
        if mode == "cbc" {
            guard let output = cbc(data, key: key, iv: iv, algorithm: algorithm, decrypt: decrypt) else {
                return false
            }
            data = output
            return true
        }
        guard let stream = counterStream(count: data.count, iv: iv, key: key, algorithm: algorithm) else {
            return false
        }
        for index in data.indices {
            data[index] ^= stream[index]
        }
        return true
    }

    private static func cbc(
        _ data: [UInt8],
        key: Data,
        iv: Data,
        algorithm: CCAlgorithm,
        decrypt: Bool
    ) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                        algorithm,
                        0,
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        input.baseAddress,
                        data.count,
                        &output,
                        output.count,
                        &moved
                    )
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(output.prefix(moved))
    }

    private static func ecb(
        _ data: [UInt8],
        key: Data,
        algorithm: CCAlgorithm,
        decrypt: Bool
    ) -> [UInt8]? {
        guard !data.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                    algorithm,
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    input.baseAddress,
                    data.count,
                    &output,
                    output.count,
                    &moved
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(output.prefix(moved))
    }

    private static func counterStream(
        count: Int,
        iv: Data,
        key: Data,
        algorithm: CCAlgorithm
    ) -> [UInt8]? {
        let blockSize = algorithm == CCAlgorithm(kCCAlgorithmBlowfish) ? kCCBlockSizeBlowfish : kCCBlockSizeAES128
        var counter = [UInt8](iv)
        var counters = [UInt8]()
        counters.reserveCapacity(((count + blockSize - 1) / blockSize) * blockSize)
        while counters.count < count {
            counters.append(contentsOf: counter)
            for index in counter.indices.reversed() {
                counter[index] = counter[index] &+ 1
                if counter[index] != 0 { break }
            }
        }
        guard let stream = ecb(counters, key: key, algorithm: algorithm, decrypt: false) else {
            return nil
        }
        return Array(stream.prefix(count))
    }
}
