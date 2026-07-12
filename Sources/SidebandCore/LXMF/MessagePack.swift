import Foundation

public enum MessagePack {
    public static func array(_ values: [Data]) -> Data {
        precondition(values.count < 16)
        return Data([0x90 | UInt8(values.count)]) + values.reduce(into: Data()) { $0.append($1) }
    }

    public static func double(_ value: Double) -> Data {
        var output = Data([0xcb])
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
        return output
    }

    public static let null = Data([0xc0])
    public static func map(_ entries: [(String, Data)]) -> Data {
        precondition(entries.count < 16)
        var output = Data([0x80 | UInt8(entries.count)])
        for (key, value) in entries { output.append(string(key)); output.append(value) }
        return output
    }
    public static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        precondition(bytes.count < 32)
        return Data([0xa0 | UInt8(bytes.count)]) + bytes
    }
    public static func unsigned(_ value: UInt64) -> Data {
        if value <= 0x7f { return Data([UInt8(value)]) }
        if value <= 0xff { return Data([0xcc, UInt8(value)]) }
        if value <= 0xffff { return Data([0xcd, UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
        if value <= 0xffff_ffff { return Data([0xce, UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
        var big = value.bigEndian
        return Data([0xcf]) + withUnsafeBytes(of: &big) { Data($0) }
    }
    public static func lxmfPayload(timestamp: Double, title: Data, content: Data) -> Data {
        var output = Data([0x94])
        output.append(0xcb)
        var bits = timestamp.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
        output.append(binary(title))
        output.append(binary(content))
        output.append(0x80) // empty fields map
        return output
    }

    public static func binary(_ data: Data) -> Data {
        if data.count <= 0xff { return Data([0xc4, UInt8(data.count)]) + data }
        if data.count <= 0xffff {
            return Data([0xc5, UInt8((data.count >> 8) & 0xff), UInt8(data.count & 0xff)]) + data
        }
        return Data([0xc6, UInt8((data.count >> 24) & 0xff), UInt8((data.count >> 16) & 0xff), UInt8((data.count >> 8) & 0xff), UInt8(data.count & 0xff)]) + data
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
