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
    public static func decode(_ data: Data) throws -> MessagePackValue {
        var cursor = 0; let value = try parse(data, cursor: &cursor)
        guard cursor == data.count else { throw DecodeError.trailingData }; return value
    }
    private static func parse(_ data: Data, cursor: inout Int) throws -> MessagePackValue {
        guard cursor < data.count else { throw DecodeError.truncated }
        let marker = data[cursor]; cursor += 1
        if marker <= 0x7f { return .unsigned(UInt64(marker)) }
        if marker >= 0xe0 { return .signed(Int64(Int8(bitPattern: marker))) }
        if marker & 0xf0 == 0x90 { return .array(try (0..<Int(marker & 0x0f)).map { _ in try parse(data, cursor: &cursor) }) }
        if marker & 0xf0 == 0x80 { return .map(try (0..<Int(marker & 0x0f)).map { _ in (try parse(data, cursor: &cursor), try parse(data, cursor: &cursor)) }) }
        if marker & 0xe0 == 0xa0 { let bytes = try take(Int(marker & 0x1f), data, cursor: &cursor); guard let value = String(data: bytes, encoding: .utf8) else { throw DecodeError.invalidUTF8 }; return .string(value) }
        switch marker {
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return .binary(try take(Int(try readUInt(1, data, cursor: &cursor)), data, cursor: &cursor))
        case 0xc5: return .binary(try take(Int(try readUInt(2, data, cursor: &cursor)), data, cursor: &cursor))
        case 0xc6: return .binary(try take(Int(try readUInt(4, data, cursor: &cursor)), data, cursor: &cursor))
        case 0xcb: return .double(Double(bitPattern: try readUInt(8, data, cursor: &cursor)))
        case 0xcc: return .unsigned(try readUInt(1, data, cursor: &cursor))
        case 0xcd: return .unsigned(try readUInt(2, data, cursor: &cursor))
        case 0xce: return .unsigned(try readUInt(4, data, cursor: &cursor))
        case 0xcf: return .unsigned(try readUInt(8, data, cursor: &cursor))
        case 0xd0: return .signed(Int64(Int8(bitPattern: UInt8(try readUInt(1, data, cursor: &cursor)))))
        case 0xd1: return .signed(Int64(Int16(bitPattern: UInt16(try readUInt(2, data, cursor: &cursor)))))
        case 0xd2: return .signed(Int64(Int32(bitPattern: UInt32(try readUInt(4, data, cursor: &cursor)))))
        case 0xd3: return .signed(Int64(bitPattern: try readUInt(8, data, cursor: &cursor)))
        case 0xd9: return try decodedString(Int(try readUInt(1, data, cursor: &cursor)), data, cursor: &cursor)
        case 0xda: return try decodedString(Int(try readUInt(2, data, cursor: &cursor)), data, cursor: &cursor)
        case 0xdb: return try decodedString(Int(try readUInt(4, data, cursor: &cursor)), data, cursor: &cursor)
        case 0xdc: return .array(try (0..<Int(try readUInt(2, data, cursor: &cursor))).map { _ in try parse(data, cursor: &cursor) })
        case 0xdd: return .array(try (0..<Int(try readUInt(4, data, cursor: &cursor))).map { _ in try parse(data, cursor: &cursor) })
        case 0xde: return .map(try (0..<Int(try readUInt(2, data, cursor: &cursor))).map { _ in (try parse(data, cursor: &cursor), try parse(data, cursor: &cursor)) })
        case 0xdf: return .map(try (0..<Int(try readUInt(4, data, cursor: &cursor))).map { _ in (try parse(data, cursor: &cursor), try parse(data, cursor: &cursor)) })
        default: throw DecodeError.unsupported(marker)
        }
    }
    private static func take(_ count: Int, _ data: Data, cursor: inout Int) throws -> Data { guard cursor + count <= data.count else { throw DecodeError.truncated }; defer { cursor += count }; return data.subdata(in: cursor..<(cursor + count)) }
    private static func decodedString(_ count: Int, _ data: Data, cursor: inout Int) throws -> MessagePackValue {
        let bytes = try take(count, data, cursor: &cursor)
        guard let value = String(data: bytes, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
        return .string(value)
    }
    private static func readUInt(_ count: Int, _ data: Data, cursor: inout Int) throws -> UInt64 { try take(count, data, cursor: &cursor).reduce(0) { ($0 << 8) | UInt64($1) } }
    public enum DecodeError: Error { case truncated, trailingData, invalidUTF8, unsupported(UInt8) }
}
