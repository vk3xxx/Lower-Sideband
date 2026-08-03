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

/// Serial, bounded validation cache for announces received over redundant
/// interfaces. The same signed packet is often delivered by several public
/// gateways; validating it once preserves route diversity without repeating
/// Curve25519/Ed25519 work on the application's main actor.
public actor ReticulumAnnounceValidator {
    public struct Statistics: Equatable, Sendable {
        public let validations: Int
        public let cacheHits: Int
        public let cachedEntries: Int
    }

    private enum Result: Sendable {
        case valid(ReticulumAnnounce)
        case invalid
    }

    private let maximumEntries: Int
    private var cache: [Data: Result] = [:]
    private var insertionOrder: [Data] = []
    private var evictionIndex = 0
    private var validationCount = 0
    private var cacheHitCount = 0

    public init(maximumEntries: Int = 2_048) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func validatedAnnounce(for packet: ReticulumPacket) -> ReticulumAnnounce? {
        let key = packet.hashablePart
        if let cached = cache[key] {
            cacheHitCount += 1
            if case .valid(let announce) = cached { return announce }
            return nil
        }

        validationCount += 1
        let result: Result
        if let announce = try? ReticulumAnnounce(packet: packet), announce.validate() {
            result = .valid(announce)
        } else {
            result = .invalid
        }
        cache[key] = result
        insertionOrder.append(key)
        while cache.count > maximumEntries, evictionIndex < insertionOrder.count {
            cache.removeValue(forKey: insertionOrder[evictionIndex])
            evictionIndex += 1
        }
        // Compact in batches so sustained announce traffic never turns cache
        // eviction into repeated O(n) array shifts.
        if evictionIndex >= 1_024, evictionIndex * 2 >= insertionOrder.count {
            insertionOrder.removeFirst(evictionIndex)
            evictionIndex = 0
        }
        if case .valid(let announce) = result { return announce }
        return nil
    }

    public func statistics() -> Statistics {
        Statistics(validations: validationCount, cacheHits: cacheHitCount, cachedEntries: cache.count)
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
