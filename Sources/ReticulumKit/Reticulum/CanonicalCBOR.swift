import Foundation

/// The deliberately small, bounded CBOR subset used by Reticulum Relay Chat.
///
/// Encoding follows RFC 8949 deterministic ordering. Indefinite-length values,
/// floating point numbers and tags are rejected so untrusted relay traffic
/// cannot trigger ambiguous decoding or unbounded allocations.
public indirect enum CanonicalCBORValue: Equatable, Sendable {
    case unsigned(UInt64)
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CanonicalCBORValue])
    case map([CanonicalCBORValue: CanonicalCBORValue])
    case bool(Bool)
    case null
}

extension CanonicalCBORValue: Hashable {}

public enum CanonicalCBOR {
    public struct Limits: Sendable {
        public var maximumDepth = 16
        public var maximumNodes = 4_096
        public var maximumCollectionCount = 1_024
        public var maximumScalarBytes = 1_048_576

        public init(
            maximumDepth: Int = 16,
            maximumNodes: Int = 4_096,
            maximumCollectionCount: Int = 1_024,
            maximumScalarBytes: Int = 1_048_576
        ) {
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
            self.maximumCollectionCount = maximumCollectionCount
            self.maximumScalarBytes = maximumScalarBytes
        }
    }

    public enum CodecError: Error, Equatable {
        case invalidValue
        case truncated
        case unsupported
        case limitExceeded
        case trailingData
        case nonCanonical
    }

    public static func encode(_ value: CanonicalCBORValue) throws -> Data {
        var output = Data()
        try append(value, to: &output, depth: 0)
        return output
    }

    public static func decode(_ data: Data, limits: Limits = .init()) throws -> CanonicalCBORValue {
        var cursor = 0
        var nodes = 0
        let value = try parse(data, cursor: &cursor, depth: 0, nodes: &nodes, limits: limits)
        guard cursor == data.count else { throw CodecError.trailingData }
        return value
    }

    private static func append(_ value: CanonicalCBORValue, to output: inout Data, depth: Int) throws {
        guard depth <= 32 else { throw CodecError.limitExceeded }
        switch value {
        case .unsigned(let integer):
            appendHeader(major: 0, value: integer, to: &output)
        case .negative(let integer):
            guard integer < 0 else { throw CodecError.invalidValue }
            appendHeader(major: 1, value: UInt64(bitPattern: ~integer), to: &output)
        case .bytes(let bytes):
            appendHeader(major: 2, value: UInt64(bytes.count), to: &output)
            output.append(bytes)
        case .text(let text):
            let bytes = Data(text.utf8)
            appendHeader(major: 3, value: UInt64(bytes.count), to: &output)
            output.append(bytes)
        case .array(let values):
            appendHeader(major: 4, value: UInt64(values.count), to: &output)
            for child in values { try append(child, to: &output, depth: depth + 1) }
        case .map(let values):
            let encoded = try values.map { (try encode($0.key), $0.value) }
                .sorted {
                    if $0.0.count != $1.0.count { return $0.0.count < $1.0.count }
                    return $0.0.lexicographicallyPrecedes($1.0)
                }
            appendHeader(major: 5, value: UInt64(encoded.count), to: &output)
            for (key, child) in encoded {
                output.append(key)
                try append(child, to: &output, depth: depth + 1)
            }
        case .bool(let value):
            output.append(value ? 0xf5 : 0xf4)
        case .null:
            output.append(0xf6)
        }
    }

    private static func appendHeader(major: UInt8, value: UInt64, to output: inout Data) {
        let prefix = major << 5
        if value < 24 {
            output.append(prefix | UInt8(value))
        } else if value <= UInt8.max {
            output.append(contentsOf: [prefix | 24, UInt8(value)])
        } else if value <= UInt16.max {
            output.append(prefix | 25)
            appendBigEndian(UInt16(value), to: &output)
        } else if value <= UInt32.max {
            output.append(prefix | 26)
            appendBigEndian(UInt32(value), to: &output)
        } else {
            output.append(prefix | 27)
            appendBigEndian(value, to: &output)
        }
    }

    private static func parse(
        _ data: Data,
        cursor: inout Int,
        depth: Int,
        nodes: inout Int,
        limits: Limits
    ) throws -> CanonicalCBORValue {
        guard depth <= limits.maximumDepth, nodes < limits.maximumNodes, cursor < data.count else {
            throw cursor >= data.count ? CodecError.truncated : CodecError.limitExceeded
        }
        nodes += 1
        let initial = data[cursor]
        cursor += 1
        let major = initial >> 5
        let additional = initial & 0x1f
        if major == 7 {
            switch additional {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw CodecError.unsupported
            }
        }
        let length = try readLength(additional, from: data, cursor: &cursor)
        switch major {
        case 0: return .unsigned(length)
        case 1:
            guard length <= UInt64(Int64.max) else { throw CodecError.invalidValue }
            return .negative(-1 - Int64(length))
        case 2, 3:
            guard length <= UInt64(limits.maximumScalarBytes),
                  length <= UInt64(data.count - cursor) else {
                throw length > UInt64(limits.maximumScalarBytes) ? CodecError.limitExceeded : CodecError.truncated
            }
            let bytes = Data(data[cursor ..< cursor + Int(length)])
            cursor += Int(length)
            if major == 2 { return .bytes(bytes) }
            guard let text = String(data: bytes, encoding: .utf8) else { throw CodecError.invalidValue }
            return .text(text)
        case 4:
            guard length <= UInt64(limits.maximumCollectionCount) else { throw CodecError.limitExceeded }
            var values: [CanonicalCBORValue] = []
            values.reserveCapacity(Int(length))
            for _ in 0 ..< length {
                values.append(try parse(data, cursor: &cursor, depth: depth + 1, nodes: &nodes, limits: limits))
            }
            return .array(values)
        case 5:
            guard length <= UInt64(limits.maximumCollectionCount) else { throw CodecError.limitExceeded }
            var values: [CanonicalCBORValue: CanonicalCBORValue] = [:]
            var previousKey: Data?
            for _ in 0 ..< length {
                let keyStart = cursor
                let key = try parse(data, cursor: &cursor, depth: depth + 1, nodes: &nodes, limits: limits)
                let keyBytes = Data(data[keyStart ..< cursor])
                if let previousKey,
                   previousKey.count > keyBytes.count
                    || (previousKey.count == keyBytes.count && !previousKey.lexicographicallyPrecedes(keyBytes)) {
                    throw CodecError.nonCanonical
                }
                guard values[key] == nil else { throw CodecError.nonCanonical }
                previousKey = keyBytes
                values[key] = try parse(data, cursor: &cursor, depth: depth + 1, nodes: &nodes, limits: limits)
            }
            return .map(values)
        default:
            throw CodecError.unsupported
        }
    }

    private static func readLength(_ additional: UInt8, from data: Data, cursor: inout Int) throws -> UInt64 {
        switch additional {
        case 0 ... 23: return UInt64(additional)
        case 24:
            let value: UInt8 = try readBigEndian(from: data, cursor: &cursor)
            guard value >= 24 else { throw CodecError.nonCanonical }
            return UInt64(value)
        case 25:
            let value: UInt16 = try readBigEndian(from: data, cursor: &cursor)
            guard value > UInt8.max else { throw CodecError.nonCanonical }
            return UInt64(value)
        case 26:
            let value: UInt32 = try readBigEndian(from: data, cursor: &cursor)
            guard value > UInt16.max else { throw CodecError.nonCanonical }
            return UInt64(value)
        case 27:
            let value: UInt64 = try readBigEndian(from: data, cursor: &cursor)
            guard value > UInt32.max else { throw CodecError.nonCanonical }
            return value
        default:
            throw CodecError.unsupported
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { output.append(contentsOf: $0) }
    }

    private static func readBigEndian<T: FixedWidthInteger>(from data: Data, cursor: inout Int) throws -> T {
        let count = MemoryLayout<T>.size
        guard cursor + count <= data.count else { throw CodecError.truncated }
        var value: T = 0
        for byte in data[cursor ..< cursor + count] { value = (value << 8) | T(byte) }
        cursor += count
        return value
    }
}
