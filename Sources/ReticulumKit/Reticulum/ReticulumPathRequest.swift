import Foundation

public enum ReticulumPathRequest {
    public static let destinationHash: Data = {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("rnstransport.path.request".utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash)
    }()

    public static func packet(targetHash: Data, tag: Data? = nil) throws -> Data {
        guard targetHash.count == 16 else { throw PathError.invalidTarget }
        let requestTag = tag ?? ReticulumIdentity.truncatedHash(randomData(count: 16))
        guard requestTag.count == 16 else { throw PathError.invalidTag }
        // HEADER_1 | BROADCAST | PLAIN | DATA, hops=0, context=NONE.
        return Data([0x08, 0x00]) + destinationHash + Data([0x00]) + targetHash + requestTag
    }

    /// Decodes the destination and anti-replay tag from a Reticulum path
    /// request. Transport-originated requests can insert a 16-byte requesting
    /// transport ID between these values, so the tag is always read from the
    /// final 16 bytes.
    public static func decode(_ packet: ReticulumPacket) -> (targetHash: Data, tag: Data)? {
        guard packet.packetType == .data,
              packet.destinationType == .plain,
              packet.destinationHash == destinationHash,
              packet.data.count >= 32
        else { return nil }
        return (
            targetHash: Data(packet.data.prefix(ReticulumPacket.truncatedHashBytes)),
            tag: Data(packet.data.suffix(ReticulumPacket.truncatedHashBytes))
        )
    }

    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }
    public enum PathError: Error { case invalidTarget, invalidTag }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
