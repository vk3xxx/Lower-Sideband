import Foundation

public enum ReticulumAnnounceBuilder {
    public static func packet(identity: ReticulumIdentity, destinationName: String, appData: Data = Data(), randomHash: Data? = nil) throws -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        let destinationHash = ReticulumIdentity.truncatedHash(nameHash + identity.hash)
        let randomHash = randomHash ?? ReticulumIdentity.truncatedHash(Data(UUID().uuidString.utf8)).prefix(10)
        guard randomHash.count == 10 else { throw BuildError.invalidRandomHash }
        let signed = destinationHash + identity.publicKey + nameHash + randomHash + appData
        let announceData = identity.publicKey + nameHash + randomHash + (try identity.sign(signed)) + appData
        return Data([0x01, 0x00]) + destinationHash + Data([0x00]) + announceData
    }

    public static func lxmfAppData(displayName: String) -> Data {
        MessagePack.array([MessagePack.binary(Data(displayName.utf8)), MessagePack.null, MessagePack.array([Data([0x00])])])
    }
    public enum BuildError: Error { case invalidRandomHash }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
