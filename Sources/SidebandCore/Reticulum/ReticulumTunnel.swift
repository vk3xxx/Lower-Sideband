import Foundation

public enum ReticulumTunnelSynthesis {
    public static let destinationHash: Data = {
        let name = Data("rnstransport.tunnel.synthesize".utf8)
        return ReticulumIdentity.truncatedHash(Data(ReticulumIdentity.fullHash(name).prefix(10)))
    }()

    public static func packet(identity: ReticulumIdentity, interfaceHash: Data, randomHash: Data? = nil) throws -> Data {
        guard interfaceHash.count == 32 else { throw TunnelError.invalidInterfaceHash }
        let randomHash = randomHash ?? ReticulumIdentity.truncatedHash(randomData(count: 16))
        guard randomHash.count == 16 else { throw TunnelError.invalidRandomHash }
        let signedData = identity.publicKey + interfaceHash + randomHash
        let data = signedData + (try identity.sign(signedData))
        return Data([0x08, 0x00]) + destinationHash + Data([0x00]) + data
    }

    private static func randomData(count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }) }
    public enum TunnelError: Error { case invalidInterfaceHash, invalidRandomHash }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
