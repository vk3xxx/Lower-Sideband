import CryptoKit
import Ed25519
import Foundation

/// Reticulum interface operating modes, using the values defined by RNS.
public enum ReticulumInterfaceMode: UInt8, Codable, CaseIterable, Sendable {
    case full = 0x01
    case pointToPoint = 0x02
    case accessPoint = 0x03
    case roaming = 0x04
    case boundary = 0x05
    case gateway = 0x06
    case internalMode = 0x07

    public var title: String {
        switch self {
        case .full: "Full"
        case .pointToPoint: "Point-to-point"
        case .accessPoint: "Access point"
        case .roaming: "Roaming"
        case .boundary: "Boundary"
        case .gateway: "Gateway"
        case .internalMode: "Internal"
        }
    }
}

/// Reticulum IFAC authentication and obfuscation, wire-compatible with RNS.
public struct ReticulumIFAC: Equatable, Sendable {
    public static let salt = Data([
        0xad, 0xf5, 0x4d, 0x88, 0x2c, 0x9a, 0x9b, 0x80,
        0x77, 0x1e, 0xb4, 0x99, 0x5d, 0x70, 0x2d, 0x4a,
        0x3e, 0x73, 0x33, 0x91, 0xb2, 0xa0, 0xf5, 0x3f,
        0x41, 0x6d, 0x9f, 0x90, 0x7e, 0x55, 0xcf, 0xf8
    ])

    public let networkName: String?
    public let passphrase: String?
    public let size: Int
    public let key: Data
    private let signingSeed: Data

    public init(networkName: String? = nil, passphrase: String? = nil, size: Int = 16) throws {
        let name = networkName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name?.isEmpty == false || phrase?.isEmpty == false else { throw IFACError.missingCredentials }
        guard (1...64).contains(size) else { throw IFACError.invalidSize }

        var origin = Data()
        if let name, !name.isEmpty { origin.append(ReticulumIdentity.fullHash(Data(name.utf8))) }
        if let phrase, !phrase.isEmpty { origin.append(ReticulumIdentity.fullHash(Data(phrase.utf8))) }
        let originHash = ReticulumIdentity.fullHash(origin)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: originHash),
            salt: Self.salt,
            info: Data(),
            outputByteCount: 64
        ).withUnsafeBytes { Data($0) }

        self.networkName = name
        self.passphrase = phrase
        self.size = size
        key = derived
        signingSeed = Data(derived.suffix(32))
    }

    public func protect(_ rawPacket: Data) throws -> Data {
        guard rawPacket.count >= 2 else { throw IFACError.invalidPacket }
        let signature = try deterministicSignature(rawPacket)
        let ifac = Data(signature.suffix(size))
        let mask = Self.mask(deriveFrom: ifac, salt: key, count: rawPacket.count + size)
        var output = Data(capacity: rawPacket.count + size)
        output.append((rawPacket[0] ^ mask[0]) | 0x80)
        output.append(rawPacket[1] ^ mask[1])
        output.append(ifac)
        for index in 2..<rawPacket.count { output.append(rawPacket[index] ^ mask[index + size]) }
        return output
    }

    public func unprotect(_ protectedPacket: Data) throws -> Data {
        guard protectedPacket.count >= size + 2, protectedPacket[0] & 0x80 == 0x80 else {
            throw IFACError.invalidPacket
        }
        let ifac = protectedPacket.subdata(in: 2..<(2 + size))
        let mask = Self.mask(deriveFrom: ifac, salt: key, count: protectedPacket.count)
        var raw = Data(capacity: protectedPacket.count - size)
        raw.append((protectedPacket[0] ^ mask[0]) & 0x7F)
        raw.append(protectedPacket[1] ^ mask[1])
        if protectedPacket.count > size + 2 {
            for index in (size + 2)..<protectedPacket.count { raw.append(protectedPacket[index] ^ mask[index]) }
        }
        let expected = try deterministicSignature(raw).suffix(size)
        guard Data(expected).constantTimeEquals(ifac) else { throw IFACError.authenticationFailed }
        return raw
    }

    private static func mask(deriveFrom: Data, salt: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: deriveFrom),
            salt: salt,
            info: Data(),
            outputByteCount: count
        ).withUnsafeBytes { Data($0) }
    }

    private func deterministicSignature(_ message: Data) throws -> Data {
        let pair = KeyPair(seed: try Seed(bytes: Array(signingSeed)))
        return Data(pair.sign(Array(message)))
    }

    public enum IFACError: Error, Equatable {
        case missingCredentials, invalidSize, invalidPacket, authenticationFailed
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.networkName == rhs.networkName && lhs.passphrase == rhs.passphrase && lhs.size == rhs.size && lhs.key == rhs.key
    }
}

private extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for index in indices { difference |= self[index] ^ other[index] }
        return difference == 0
    }
}
