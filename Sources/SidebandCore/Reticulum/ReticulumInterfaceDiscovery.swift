import CryptoKit
import Foundation

/// A cryptographically validated, on-network Reticulum interface announce.
public struct DiscoveredReticulumInterface: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: UInt16
    public let transportID: Data
    public let networkID: Data
    public let hops: UInt8
    public let stampValue: Int
    public let firstSeen: Date
    public var lastSeen: Date

    public init(name: String, host: String, port: UInt16, transportID: Data, networkID: Data, hops: UInt8, stampValue: Int, firstSeen: Date = .now, lastSeen: Date = .now) {
        self.name = name
        self.host = host
        self.port = port
        self.transportID = transportID
        self.networkID = networkID
        self.hops = hops
        self.stampValue = stampValue
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        id = ReticulumIdentity.fullHash(transportID + Data(name.utf8)).hex
    }
}

public enum ReticulumInterfaceDiscovery {
    public static let destinationNameHash = Data(ReticulumIdentity.fullHash(Data("rnstransport.discovery.interface".utf8)).prefix(10))
    public static let minimumStampValue = 14
    public static let stampSize = 32
    public static let workblockExpandRounds = 20

    private enum Field: UInt64 {
        case interfaceType = 0x00, transport = 0x01, reachableOn = 0x02
        case latitude = 0x03, longitude = 0x04, height = 0x05, port = 0x06
        case name = 0xff, transportID = 0xfe
    }

    public static func decode(_ announce: ReticulumAnnounce, hops: UInt8, now: Date = .now) -> DiscoveredReticulumInterface? {
        guard announce.validate(), announce.nameHash == destinationNameHash else { return nil }
        return decode(appData: announce.appData, networkID: announce.identityHash, hops: hops, now: now)
    }

    public static func decode(appData: Data, networkID: Data, hops: UInt8, now: Date = .now) -> DiscoveredReticulumInterface? {
        guard networkID.count == 16, appData.count > stampSize + 1 else { return nil }
        let flags = appData[appData.startIndex]
        guard flags & 0b0000_0010 == 0 else { return nil } // Encrypted discovery requires a configured network identity.
        let payload = Data(appData.dropFirst())
        let packed = Data(payload.dropLast(stampSize))
        let stamp = Data(payload.suffix(stampSize))
        guard let stampValue = validateStamp(packed: packed, stamp: stamp), stampValue >= minimumStampValue else { return nil }
        guard case let .map(entries)? = try? MessagePackDecoder.decode(packed) else { return nil }
        var fields: [UInt64: MessagePackValue] = [:]
        for (key, value) in entries {
            if case let .unsigned(number) = key { fields[number] = value }
        }

        guard let type = string(fields[Field.interfaceType.rawValue]),
              type == "BackboneInterface" || type == "TCPServerInterface",
              case .bool(true)? = fields[Field.transport.rawValue],
              let transportID = binary(fields[Field.transportID.rawValue]), transportID.count == 16,
              let host = string(fields[Field.reachableOn.rawValue]), validHost(host),
              let portValue = unsigned(fields[Field.port.rawValue]),
              let port = UInt16(exactly: portValue), port > 0
        else { return nil }

        let advertisedName = string(fields[Field.name.rawValue])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = advertisedName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "Discovered (type)"
        return DiscoveredReticulumInterface(
            name: name,
            host: host,
            port: port,
            transportID: transportID,
            networkID: networkID,
            hops: hops,
            stampValue: stampValue,
            firstSeen: now,
            lastSeen: now
        )
    }

    public static func validateStamp(packed: Data, stamp: Data) -> Int? {
        guard stamp.count == stampSize else { return nil }
        let material = ReticulumIdentity.fullHash(packed)
        var workblock = Data(capacity: workblockExpandRounds * 256)
        for round in 0..<workblockExpandRounds {
            let salt = ReticulumIdentity.fullHash(material + MessagePack.unsigned(UInt64(round)))
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: material),
                salt: salt,
                info: Data(),
                outputByteCount: 256
            )
            workblock.append(key.withUnsafeBytes { Data($0) })
        }
        let result = ReticulumIdentity.fullHash(workblock + stamp)
        var value = 0
        for byte in result {
            if byte == 0 { value += 8 }
            else { return value + byte.leadingZeroBitCount }
        }
        return value
    }

    /// Discovery announces are received from an untrusted global network. The
    /// signature authenticates the announcing identity, not its operator, so
    /// automatic public-mode connections must not be redirected to local or
    /// special-use addresses.
    public static func isSafeAutomaticPublicHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard validHost(normalized), normalized != "localhost", !normalized.hasSuffix(".local") else { return false }
        if normalized.contains(":") {
            guard !normalized.contains("%") else { return false }
            return normalized.first == "2" || normalized.first == "3" // IPv6 global unicast 2000::/3
        }
        let parts = normalized.split(separator: ".")
        let octets = parts.compactMap { UInt8($0) }
        if parts.count == 4, octets.count == 4 {
            let first = octets[0], second = octets[1]
            return first != 0 && first != 10 && first != 127 && first < 224
                && !(first == 100 && (64...127).contains(second))
                && !(first == 169 && second == 254)
                && !(first == 172 && (16...31).contains(second))
                && !(first == 192 && second == 168)
        }
        return true
    }

    private static func string(_ value: MessagePackValue?) -> String? {
        switch value {
        case let .string(string): string
        case let .binary(data): String(data: data, encoding: .utf8)
        default: nil
        }
    }

    private static func binary(_ value: MessagePackValue?) -> Data? {
        if case let .binary(data) = value { return data }
        return nil
    }

    private static func unsigned(_ value: MessagePackValue?) -> UInt64? {
        switch value {
        case let .unsigned(number): number
        case let .signed(number) where number >= 0: UInt64(number)
        default: nil
        }
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, host == host.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        guard !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "/" || $0 == "@" }) else { return false }
        return host.contains(":") || host.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var result = lhs; result.append(rhs); return result }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
