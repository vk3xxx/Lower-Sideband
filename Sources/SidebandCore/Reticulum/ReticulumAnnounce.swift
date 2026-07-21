import Foundation

public struct ReticulumAnnounce: Equatable, Sendable {
    public static let publicKeyLength = 64
    public static let nameHashLength = 10
    public static let randomHashLength = 10
    public static let ratchetLength = 32
    public static let signatureLength = 64
    public let destinationHash: Data
    public let publicKey: Data
    public let nameHash: Data
    public let randomHash: Data
    public let ratchet: Data?
    public let signature: Data
    public let appData: Data
    public let identityHash: Data

    /// Five-byte Reticulum announce emission timebase used for route freshness.
    public var emissionTimebase: UInt64 {
        randomHash.suffix(5).reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    public init(packet: ReticulumPacket) throws {
        guard packet.packetType == .announce else { throw ValidationError.notAnnounce }
        let ratchetBytes = packet.contextFlag ? Self.ratchetLength : 0
        let fixedLength = Self.publicKeyLength + Self.nameHashLength + Self.randomHashLength + ratchetBytes + Self.signatureLength
        guard packet.data.count >= fixedLength else { throw ValidationError.malformed }
        var cursor = 0
        func take(_ count: Int) -> Data {
            defer { cursor += count }
            return packet.data.subdata(in: cursor..<(cursor + count))
        }
        destinationHash = packet.destinationHash
        publicKey = take(Self.publicKeyLength)
        nameHash = take(Self.nameHashLength)
        randomHash = take(Self.randomHashLength)
        ratchet = packet.contextFlag ? take(Self.ratchetLength) : nil
        signature = take(Self.signatureLength)
        appData = packet.data.subdata(in: cursor..<packet.data.endIndex)
        identityHash = ReticulumIdentity.truncatedHash(publicKey)
    }

    public func validate() -> Bool {
        guard let identity = try? ReticulumIdentity(publicKey: publicKey) else { return false }
        var signedData = destinationHash + publicKey + nameHash + randomHash
        if let ratchet { signedData.append(ratchet) }
        signedData.append(appData)
        guard identity.validate(signature: signature, message: signedData) else { return false }
        return destinationHash == ReticulumIdentity.truncatedHash(nameHash + identityHash)
    }
    public enum ValidationError: Error { case notAnnounce, malformed }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
