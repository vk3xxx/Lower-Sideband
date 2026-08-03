import Foundation

/// Allocation-light lowercase hexadecimal encoding for Reticulum identifiers.
/// Packet and path processing uses this instead of Foundation format parsing,
/// which is disproportionately expensive during announce bursts.
public enum ReticulumHex {
    private static let digits = Array("0123456789abcdef".utf8)

    public static func encode<D: DataProtocol>(_ data: D) -> String {
        var encoded = [UInt8]()
        encoded.reserveCapacity(data.count * 2)
        for byte in data {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

public struct ReticulumPacket: Equatable, Sendable {
    public static let truncatedHashBytes = 16
    public static let minimumHeaderBytes = 19

    public enum HeaderType: UInt8, Sendable { case normal = 0, transport = 1 }
    public enum PacketType: UInt8, Sendable { case data = 0, announce = 1, linkRequest = 2, proof = 3 }
    public enum DestinationType: UInt8, Sendable { case single = 0, group = 1, plain = 2, link = 3 }

    public let headerType: HeaderType
    public let contextFlag: Bool
    public let transportType: UInt8
    public let destinationType: DestinationType
    public let packetType: PacketType
    public let hops: UInt8
    public let transportID: Data?
    public let destinationHash: Data
    public let context: UInt8
    public let data: Data
    public let raw: Data

    public init(raw: Data) throws {
        self.raw = raw
        guard raw.count >= Self.minimumHeaderBytes else { throw ParseError.tooShort }
        let flags = raw[raw.startIndex]
        guard let headerType = HeaderType(rawValue: (flags & 0x40) >> 6),
              let destinationType = DestinationType(rawValue: (flags & 0x0c) >> 2),
              let packetType = PacketType(rawValue: flags & 0x03) else { throw ParseError.invalidFlags }
        self.headerType = headerType
        contextFlag = flags & 0x20 != 0
        transportType = (flags & 0x10) >> 4
        self.destinationType = destinationType
        self.packetType = packetType
        hops = raw[raw.startIndex + 1]

        let hashLength = Self.truncatedHashBytes
        let base = raw.startIndex + 2
        if headerType == .transport {
            guard raw.count >= 2 + hashLength * 2 + 1 else { throw ParseError.tooShort }
            transportID = raw.subdata(in: base..<(base + hashLength))
            destinationHash = raw.subdata(in: (base + hashLength)..<(base + hashLength * 2))
            context = raw[base + hashLength * 2]
            data = raw.subdata(in: (base + hashLength * 2 + 1)..<raw.endIndex)
        } else {
            transportID = nil
            destinationHash = raw.subdata(in: base..<(base + hashLength))
            context = raw[base + hashLength]
            data = raw.subdata(in: (base + hashLength + 1)..<raw.endIndex)
        }
    }

    public var hashablePart: Data {
        var result = Data([raw[raw.startIndex] & 0x0f])
        if headerType == .transport { result.append(raw.subdata(in: (raw.startIndex + Self.truncatedHashBytes + 2)..<raw.endIndex)) }
        else { result.append(raw.subdata(in: (raw.startIndex + 2)..<raw.endIndex)) }
        return result
    }
    public var packetHash: Data { ReticulumIdentity.fullHash(hashablePart) }

    /// Adds the transport header required when forwarding a packet through a
    /// known Reticulum transport. The hashable packet content remains unchanged.
    public func routed(via transportID: Data) throws -> Data {
        guard headerType == .normal, transportID.count == Self.truncatedHashBytes else { throw RoutingError.invalidRoute }
        var routed = Data([raw[raw.startIndex] | 0x50, raw[raw.startIndex + 1]])
        routed.append(transportID)
        routed.append(raw.dropFirst(2))
        return routed
    }

    /// Prepares an endpoint-originated packet for the selected Reticulum path.
    ///
    /// A route with no announced next hop is directly attached and keeps its
    /// normal header. When a next-hop transport identity is present, the
    /// packet must be injected through it even if the destination is reported
    /// as one hop away. This is the upstream shared-instance/TCP-client rule:
    /// the gateway strips the transport header before forwarding to the peer.
    public func prepared(for path: ReticulumPath) throws -> Data {
        guard let nextHop = path.nextHop else { return raw }
        return try routed(via: nextHop)
    }

    public enum ParseError: Error { case tooShort, invalidFlags }
    public enum RoutingError: Error { case invalidRoute }
}
