import Foundation

public indirect enum MessagePackValue: Equatable, Sendable {
    case null, bool(Bool), unsigned(UInt64), signed(Int64), double(Double), binary(Data), string(String)
    case array([MessagePackValue])
    case map([(MessagePackValue, MessagePackValue)])
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.unsigned(a), .unsigned(b)): a == b
        case let (.signed(a), .signed(b)): a == b
        case let (.double(a), .double(b)): a == b
        case let (.binary(a), .binary(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.map(a), .map(b)): a.elementsEqual(b, by: { $0.0 == $1.0 && $0.1 == $1.1 })
        default: false
        }
    }
}

public enum MessagePackDecoder {
    public struct Limits: Sendable {
        public var maximumDepth: Int
        public var maximumCollectionCount: Int
        public var maximumNodeCount: Int
        public var maximumScalarBytes: Int

        public init(maximumDepth: Int = 32, maximumCollectionCount: Int = 4_096, maximumNodeCount: Int = 16_384, maximumScalarBytes: Int = 1_048_576) {
            self.maximumDepth = maximumDepth
            self.maximumCollectionCount = maximumCollectionCount
            self.maximumNodeCount = maximumNodeCount
            self.maximumScalarBytes = maximumScalarBytes
        }

        public static let network = Limits()
    }

    public static func decode(_ data: Data) throws -> MessagePackValue { try decode(data, limits: .network) }

    public static func decode(_ data: Data, limits: Limits) throws -> MessagePackValue {
        guard limits.maximumDepth > 0, limits.maximumCollectionCount >= 0,
              limits.maximumNodeCount > 0, limits.maximumScalarBytes >= 0,
              data.count <= limits.maximumScalarBytes else { throw DecodeError.limitExceeded }
        var parser = Parser(data: data, limits: limits)
        let value = try parser.parse(depth: 0)
        guard parser.cursor == data.count else { throw DecodeError.trailingData }
        return value
    }

    private struct Parser {
        let data: Data
        let limits: Limits
        var cursor = 0
        var nodeCount = 0

        mutating func parse(depth: Int) throws -> MessagePackValue {
            guard depth <= limits.maximumDepth, nodeCount < limits.maximumNodeCount else { throw DecodeError.limitExceeded }
            nodeCount += 1
            guard cursor < data.count else { throw DecodeError.truncated }
            let marker = data[cursor]
            cursor += 1
            if marker <= 0x7f { return .unsigned(UInt64(marker)) }
            if marker >= 0xe0 { return .signed(Int64(Int8(bitPattern: marker))) }
            if marker & 0xf0 == 0x90 { return .array(try parseArray(count: Int(marker & 0x0f), depth: depth)) }
            if marker & 0xf0 == 0x80 { return .map(try parseMap(count: Int(marker & 0x0f), depth: depth)) }
            if marker & 0xe0 == 0xa0 { return try decodedString(Int(marker & 0x1f)) }
            switch marker {
            case 0xc0: return .null
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)
            case 0xc4: return .binary(try take(scalarCount(try readUInt(1))))
            case 0xc5: return .binary(try take(scalarCount(try readUInt(2))))
            case 0xc6: return .binary(try take(scalarCount(try readUInt(4))))
            case 0xcb: return .double(Double(bitPattern: try readUInt(8)))
            case 0xcc: return .unsigned(try readUInt(1))
            case 0xcd: return .unsigned(try readUInt(2))
            case 0xce: return .unsigned(try readUInt(4))
            case 0xcf: return .unsigned(try readUInt(8))
            case 0xd0: return .signed(Int64(Int8(bitPattern: UInt8(try readUInt(1)))))
            case 0xd1: return .signed(Int64(Int16(bitPattern: UInt16(try readUInt(2)))))
            case 0xd2: return .signed(Int64(Int32(bitPattern: UInt32(try readUInt(4)))))
            case 0xd3: return .signed(Int64(bitPattern: try readUInt(8)))
            case 0xd9: return try decodedString(scalarCount(try readUInt(1)))
            case 0xda: return try decodedString(scalarCount(try readUInt(2)))
            case 0xdb: return try decodedString(scalarCount(try readUInt(4)))
            case 0xdc: return .array(try parseArray(count: collectionCount(try readUInt(2)), depth: depth))
            case 0xdd: return .array(try parseArray(count: collectionCount(try readUInt(4)), depth: depth))
            case 0xde: return .map(try parseMap(count: collectionCount(try readUInt(2)), depth: depth))
            case 0xdf: return .map(try parseMap(count: collectionCount(try readUInt(4)), depth: depth))
            default: throw DecodeError.unsupported(marker)
            }
        }

        mutating func parseArray(count: Int, depth: Int) throws -> [MessagePackValue] {
            guard count <= limits.maximumCollectionCount, count <= limits.maximumNodeCount - nodeCount,
                  count <= data.count - cursor else { throw DecodeError.limitExceeded }
            var values: [MessagePackValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try parse(depth: depth + 1)) }
            return values
        }

        mutating func parseMap(count: Int, depth: Int) throws -> [(MessagePackValue, MessagePackValue)] {
            guard count <= limits.maximumCollectionCount, count <= (limits.maximumNodeCount - nodeCount) / 2,
                  count <= (data.count - cursor) / 2 else { throw DecodeError.limitExceeded }
            var entries: [(MessagePackValue, MessagePackValue)] = []
            entries.reserveCapacity(count)
            for _ in 0..<count { entries.append((try parse(depth: depth + 1), try parse(depth: depth + 1))) }
            return entries
        }

        func collectionCount(_ value: UInt64) throws -> Int {
            guard value <= UInt64(limits.maximumCollectionCount), let count = Int(exactly: value) else { throw DecodeError.limitExceeded }
            return count
        }

        func scalarCount(_ value: UInt64) throws -> Int {
            guard value <= UInt64(limits.maximumScalarBytes), let count = Int(exactly: value) else { throw DecodeError.limitExceeded }
            return count
        }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= limits.maximumScalarBytes, cursor <= data.count,
                  count <= data.count - cursor else { throw DecodeError.truncated }
            defer { cursor += count }
            return data.subdata(in: cursor..<(cursor + count))
        }

        mutating func decodedString(_ count: Int) throws -> MessagePackValue {
            let bytes = try take(count)
            guard let value = String(data: bytes, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
            return .string(value)
        }

        mutating func readUInt(_ count: Int) throws -> UInt64 {
            try take(count).reduce(0) { ($0 << 8) | UInt64($1) }
        }
    }

    public enum DecodeError: Error { case truncated, trailingData, invalidUTF8, unsupported(UInt8), limitExceeded }
}
