import Foundation

public enum ReticulumAnnounceBuilder {
    public static func packet(
        identity: ReticulumIdentity,
        destinationName: String,
        appData: Data = Data(),
        randomHash: Data? = nil,
        ratchet: Data? = nil,
        emittedAt: Date = .now,
        context: UInt8 = 0x00
    ) throws -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        let destinationHash = ReticulumIdentity.truncatedHash(nameHash + identity.hash)
        // Reticulum announce nonces are not ten unconstrained random bytes.
        // The first five bytes prevent collisions and the final five bytes are
        // the big-endian Unix emission time used by transports to decide which
        // route is newer. Omitting that timebase makes fresh direct announces
        // look randomly older than stale multi-hop paths.
        let randomHash = randomHash ?? announceRandomHash(emittedAt: emittedAt)
        guard randomHash.count == 10 else { throw BuildError.invalidRandomHash }
        if let ratchet, ratchet.count != ReticulumAnnounce.ratchetLength { throw BuildError.invalidRatchet }
        let ratchetData = ratchet ?? Data()
        let signed = destinationHash + identity.publicKey + nameHash + randomHash + ratchetData + appData
        let announceData = identity.publicKey + nameHash + randomHash + ratchetData + (try identity.sign(signed)) + appData
        let flags: UInt8 = 0x01 | (ratchet == nil ? 0 : 0x20)
        return Data([flags, 0x00]) + destinationHash + Data([context]) + announceData
    }

    static func announceRandomHash(emittedAt: Date) -> Data {
        var result = Data(ReticulumIdentity.fullHash(Data(UUID().uuidString.utf8)).prefix(5))
        let seconds = UInt64(max(0, emittedAt.timeIntervalSince1970.rounded(.down))) & 0xFF_FFFF_FFFF
        for shift in stride(from: 32, through: 0, by: -8) {
            result.append(UInt8((seconds >> UInt64(shift)) & 0xFF))
        }
        return result
    }

    public static func lxmfAppData(displayName: String) -> Data {
        MessagePack.array([MessagePack.binary(Data(displayName.utf8)), MessagePack.null, MessagePack.array([Data([0x00])])])
    }
    public enum BuildError: Error { case invalidRandomHash, invalidRatchet }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
