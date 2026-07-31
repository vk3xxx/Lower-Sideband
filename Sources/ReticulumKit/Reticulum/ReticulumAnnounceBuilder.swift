import Foundation

/// Supplies strictly increasing Reticulum announce timebases for each local
/// destination. Reticulum transports only replace an existing route when the
/// new announce has a later whole-second timebase. Without this coordinator,
/// disconnecting and reconnecting within one second can leave a gateway
/// forwarding to the socket that was just closed.
public actor ReticulumAnnounceEmissionClock {
    public static let shared = ReticulumAnnounceEmissionClock()

    private var lastEmissionSecond: [Data: UInt64] = [:]

    public init() {}

    public func packet(
        identity: ReticulumIdentity,
        destinationName: String,
        appData: Data = Data(),
        ratchet: Data? = nil,
        emittedAt: Date = .now,
        context: UInt8 = 0x00
    ) throws -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        let destinationHash = ReticulumIdentity.truncatedHash(nameHash + identity.hash)
        let wallClockSecond = UInt64(max(0, emittedAt.timeIntervalSince1970.rounded(.down))) & 0xFF_FFFF_FFFF
        let emissionSecond = max(wallClockSecond, (lastEmissionSecond[destinationHash] ?? 0) + 1)
        lastEmissionSecond[destinationHash] = emissionSecond
        return try ReticulumAnnounceBuilder.packet(
            identity: identity,
            destinationName: destinationName,
            appData: appData,
            randomHash: ReticulumAnnounceBuilder.announceRandomHash(emissionSecond: emissionSecond),
            ratchet: ratchet,
            context: context
        )
    }
}

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
        let seconds = UInt64(max(0, emittedAt.timeIntervalSince1970.rounded(.down))) & 0xFF_FFFF_FFFF
        return announceRandomHash(emissionSecond: seconds)
    }

    static func announceRandomHash(emissionSecond seconds: UInt64) -> Data {
        var result = Data(ReticulumIdentity.fullHash(Data(UUID().uuidString.utf8)).prefix(5))
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
