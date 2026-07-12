import Foundation

public enum ReticulumProof {
    /// Builds an explicit proof for a packet received by a SINGLE destination.
    public static func packet(for receivedPacket: ReticulumPacket, identity: ReticulumIdentity) throws -> Data {
        let hash = receivedPacket.packetHash
        let proofData = hash + (try identity.sign(hash))
        return Data([0x03, 0x00]) + hash.prefix(ReticulumPacket.truncatedHashBytes) + Data([0x00]) + proofData
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var value = lhs
        value.append(rhs)
        return value
    }
}
