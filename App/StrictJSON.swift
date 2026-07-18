import Foundation

indirect enum StrictJSONValue: Equatable, Sendable {
    case object([String: StrictJSONValue])
    case array([StrictJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

enum StrictJSONDocument {
    static func parse(_ data: Data, limits: StrictJSONLimits) throws -> StrictJSONValue {
        guard !data.isEmpty else { throw ManifestVerificationError.emptyManifest }
        if data.starts(with: [0xef, 0xbb, 0xbf]) {
            throw ManifestVerificationError.utf8BOMNotAllowed
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ManifestVerificationError.invalidUTF8
        }
        var parser = Parser(bytes: [UInt8](data), limits: limits)
        return try parser.parseDocument()
    }
}

private struct Parser {
    let bytes: [UInt8]
    let limits: StrictJSONLimits
    var index = 0
    var valueCount = 0

    mutating func parseDocument() throws -> StrictJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0, path: "$")
        skipWhitespace()
        guard index == bytes.count else {
            throw ManifestVerificationError.malformedJSON(path: "$")
        }
        return value
    }

    private mutating func parseValue(depth: Int, path: String) throws -> StrictJSONValue {
        guard depth <= limits.maximumNestingDepth else {
            throw ManifestVerificationError.JSONLimitExceeded(path: path)
        }
        valueCount += 1
        guard valueCount <= limits.maximumTotalValues, index < bytes.count else {
            if valueCount > limits.maximumTotalValues {
                throw ManifestVerificationError.JSONLimitExceeded(path: path)
            }
            throw ManifestVerificationError.malformedJSON(path: path)
        }
        switch bytes[index] {
        case 0x7b: return try parseObject(depth: depth, path: path)
        case 0x5b: return try parseArray(depth: depth, path: path)
        case 0x22: return .string(try parseString(path: path))
        case 0x74:
            try consumeLiteral("true", path: path)
            return .boolean(true)
        case 0x66:
            try consumeLiteral("false", path: path)
            return .boolean(false)
        case 0x6e:
            try consumeLiteral("null", path: path)
            return .null
        case 0x2d, 0x30...0x39:
            return .number(try parseNumber(path: path))
        default:
            throw ManifestVerificationError.malformedJSON(path: path)
        }
    }

    private mutating func parseObject(depth: Int, path: String) throws -> StrictJSONValue {
        index += 1
        skipWhitespace()
        var object: [String: StrictJSONValue] = [:]
        if consume(0x7d) { return .object(object) }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            let key = try parseString(path: path)
            let keyPath = path + "." + safePathComponent(key)
            guard object[key] == nil else {
                throw ManifestVerificationError.duplicateJSONKey(path: keyPath)
            }
            skipWhitespace()
            guard consume(0x3a) else {
                throw ManifestVerificationError.malformedJSON(path: keyPath)
            }
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1, path: keyPath)
            guard object.count <= limits.maximumObjectMembers else {
                throw ManifestVerificationError.JSONLimitExceeded(path: path)
            }
            skipWhitespace()
            if consume(0x7d) { break }
            guard consume(0x2c) else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            skipWhitespace()
        }
        return .object(object)
    }

    private mutating func parseArray(depth: Int, path: String) throws -> StrictJSONValue {
        index += 1
        skipWhitespace()
        var array: [StrictJSONValue] = []
        if consume(0x5d) { return .array(array) }
        while true {
            guard array.count < limits.maximumArrayElements else {
                throw ManifestVerificationError.JSONLimitExceeded(path: path)
            }
            let elementPath = "\(path)[\(array.count)]"
            array.append(try parseValue(depth: depth + 1, path: elementPath))
            skipWhitespace()
            if consume(0x5d) { break }
            guard consume(0x2c) else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            skipWhitespace()
        }
        return .array(array)
    }

    private mutating func parseString(path: String) throws -> String {
        guard consume(0x22) else {
            throw ManifestVerificationError.malformedJSON(path: path)
        }
        var output = ""
        var segmentStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 || byte == 0x5c {
                try appendUTF8Segment(segmentStart..<index, to: &output, path: path)
                if byte == 0x22 {
                    index += 1
                    guard output.utf8.count <= limits.maximumStringBytes else {
                        throw ManifestVerificationError.JSONLimitExceeded(path: path)
                    }
                    return output
                }
                index += 1
                guard index < bytes.count else {
                    throw ManifestVerificationError.malformedJSON(path: path)
                }
                switch bytes[index] {
                case 0x22: output.append("\"")
                case 0x5c: output.append("\\")
                case 0x2f: output.append("/")
                case 0x62: output.append("\u{08}")
                case 0x66: output.append("\u{0c}")
                case 0x6e: output.append("\n")
                case 0x72: output.append("\r")
                case 0x74: output.append("\t")
                case 0x75:
                    index += 1
                    let first = try parseHexQuad(path: path)
                    if (0xd800...0xdbff).contains(first) {
                        guard index + 1 < bytes.count,
                              bytes[index] == 0x5c, bytes[index + 1] == 0x75 else {
                            throw ManifestVerificationError.malformedJSON(path: path)
                        }
                        index += 2
                        let second = try parseHexQuad(path: path)
                        guard (0xdc00...0xdfff).contains(second) else {
                            throw ManifestVerificationError.malformedJSON(path: path)
                        }
                        let scalarValue = 0x10000 +
                            ((UInt32(first) - 0xd800) << 10) + (UInt32(second) - 0xdc00)
                        guard let scalar = UnicodeScalar(scalarValue) else {
                            throw ManifestVerificationError.malformedJSON(path: path)
                        }
                        output.unicodeScalars.append(scalar)
                        segmentStart = index
                        continue
                    }
                    guard !(0xdc00...0xdfff).contains(first),
                          let scalar = UnicodeScalar(UInt32(first)) else {
                        throw ManifestVerificationError.malformedJSON(path: path)
                    }
                    output.unicodeScalars.append(scalar)
                    segmentStart = index
                    continue
                default:
                    throw ManifestVerificationError.malformedJSON(path: path)
                }
                index += 1
                segmentStart = index
            } else {
                guard byte >= 0x20 else {
                    throw ManifestVerificationError.malformedJSON(path: path)
                }
                index += 1
            }
            guard output.utf8.count + (index - segmentStart) <= limits.maximumStringBytes else {
                throw ManifestVerificationError.JSONLimitExceeded(path: path)
            }
        }
        throw ManifestVerificationError.malformedJSON(path: path)
    }

    private mutating func parseHexQuad(path: String) throws -> UInt16 {
        guard index + 4 <= bytes.count else {
            throw ManifestVerificationError.malformedJSON(path: path)
        }
        var result: UInt16 = 0
        for _ in 0..<4 {
            guard let value = hexValue(bytes[index]) else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            result = result << 4 | UInt16(value)
            index += 1
        }
        return result
    }

    private func appendUTF8Segment(_ range: Range<Int>, to output: inout String,
                                   path: String) throws {
        guard !range.isEmpty else { return }
        guard let segment = String(bytes: bytes[range], encoding: .utf8) else {
            throw ManifestVerificationError.invalidUTF8
        }
        output.append(segment)
    }

    private mutating func parseNumber(path: String) throws -> String {
        let start = index
        if consume(0x2d), index == bytes.count {
            throw ManifestVerificationError.malformedJSON(path: path)
        }
        if consume(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if consume(0x2e) {
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                throw ManifestVerificationError.malformedJSON(path: path)
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consumeLiteral(_ literal: String, path: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ManifestVerificationError.malformedJSON(path: path)
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09 ||
                bytes[index] == 0x0a || bytes[index] == 0x0d {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private func safePathComponent(_ value: String) -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                    ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              }) else { return "<field>" }
        return value
    }
}
