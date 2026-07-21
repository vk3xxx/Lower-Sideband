import CryptoKit
import Foundation

/// Native implementation of LXMF's proof-of-work stamps and trusted-peer tickets.
public enum LXMFStamp {
    public static let stampSize = 32
    public static let ticketSize = 16
    public static let ticketValue = 0x100
    public static let messageExpansionRounds = 3_000
    public static let propagationExpansionRounds = 1_000

    public struct Result: Sendable, Equatable {
        public let stamp: Data
        public let value: Int
        public let attempts: UInt64
    }

    public static func workblock(material: Data, rounds: Int = messageExpansionRounds) -> Data {
        guard rounds > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(rounds * 256)
        for round in 0..<rounds {
            let roundData = MessagePack.unsigned(UInt64(round))
            let salt = ReticulumIdentity.fullHash(material + roundData)
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: material), salt: salt,
                info: Data(), outputByteCount: 256
            )
            key.withUnsafeBytes { result.append(contentsOf: $0) }
        }
        return result
    }

    public static func value(of stamp: Data, workblock: Data) -> Int? {
        guard stamp.count == stampSize else { return nil }
        let digest = ReticulumIdentity.fullHash(workblock + stamp)
        var value = 0
        for byte in digest {
            if byte == 0 { value += 8; continue }
            value += byte.leadingZeroBitCount
            break
        }
        return value
    }

    public static func validate(_ stamp: Data, cost: Int, workblock: Data) -> Bool {
        guard (0...255).contains(cost), let value = value(of: stamp, workblock: workblock) else { return false }
        return value >= cost
    }

    public static func generate(
        for material: Data, cost: Int, expansionRounds: Int = messageExpansionRounds,
        maximumAttempts: UInt64 = 20_000_000
    ) async throws -> Result {
        guard (0...255).contains(cost), maximumAttempts > 0 else { throw StampError.invalidCost }
        let block = workblock(material: material, rounds: expansionRounds)
        if cost == 0 {
            let stamp = Data(repeating: 0, count: stampSize)
            return Result(stamp: stamp, value: value(of: stamp, workblock: block) ?? 0, attempts: 1)
        }
        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let stamp = randomStamp()
            if let stampValue = value(of: stamp, workblock: block), stampValue >= cost {
                return Result(stamp: stamp, value: stampValue, attempts: attempt)
            }
            if attempt.isMultiple(of: 2_048) { await Task.yield() }
        }
        throw StampError.attemptLimitReached
    }

    public static func ticketStamp(ticket: Data, messageID: Data) throws -> Data {
        guard ticket.count == ticketSize, messageID.count == 32 else { throw StampError.invalidTicket }
        return ReticulumIdentity.truncatedHash(ticket + messageID)
    }

    public static func validateTicketStamp(_ stamp: Data, tickets: [Data], messageID: Data) -> Bool {
        tickets.contains { (try? ticketStamp(ticket: $0, messageID: messageID)) == stamp }
    }

    private static func randomStamp() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<stampSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public enum StampError: LocalizedError {
        case invalidCost, invalidTicket, attemptLimitReached
        public var errorDescription: String? {
            switch self {
            case .invalidCost: "The LXMF stamp cost is invalid."
            case .invalidTicket: "The LXMF delivery ticket is invalid."
            case .attemptLimitReached: "The LXMF stamp attempt limit was reached."
            }
        }
    }
}

public struct LXMFDeliveryTicket: Codable, Hashable, Sendable {
    public let destinationHash: Data
    public let value: Data
    public let issuedAt: Date
    public let expiresAt: Date

    public init(destinationHash: Data, value: Data, issuedAt: Date = .now, expiresAt: Date? = nil) throws {
        guard destinationHash.count == 16, value.count == LXMFStamp.ticketSize else { throw LXMFStamp.StampError.invalidTicket }
        self.destinationHash = destinationHash
        self.value = value
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(21 * 24 * 60 * 60)
    }

    public var isValid: Bool { expiresAt > .now }
    public var shouldRenew: Bool { expiresAt.timeIntervalSinceNow < 7 * 24 * 60 * 60 }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
