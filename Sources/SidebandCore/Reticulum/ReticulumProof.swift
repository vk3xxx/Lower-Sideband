import Foundation

public enum ReticulumProof {
    /// Builds an explicit proof for a packet received by a SINGLE destination.
    public static func packet(for receivedPacket: ReticulumPacket, identity: ReticulumIdentity) throws -> Data {
        let hash = receivedPacket.packetHash
        let proofData = hash + (try identity.sign(hash))
        return Data([0x03, 0x00]) + hash.prefix(ReticulumPacket.truncatedHashBytes) + Data([0x00]) + proofData
    }

    /// Validates either Reticulum's default implicit proof (signature only) or
    /// its explicit proof (full packet hash and signature).
    public static func validates(_ proofPacket: ReticulumPacket, packetHash: Data, identity: ReticulumIdentity) -> Bool {
        guard proofPacket.packetType == .proof,
              proofPacket.destinationHash == packetHash.prefix(ReticulumPacket.truncatedHashBytes) else { return false }
        switch proofPacket.data.count {
        case 64:
            return identity.validate(signature: proofPacket.data, message: packetHash)
        case 96:
            guard proofPacket.data.prefix(32) == packetHash else { return false }
            return identity.validate(signature: Data(proofPacket.data.suffix(64)), message: packetHash)
        default:
            return false
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var value = lhs
        value.append(rhs)
        return value
    }
}
