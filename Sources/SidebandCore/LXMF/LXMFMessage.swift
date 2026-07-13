import Foundation

public struct LXMFMessage: Sendable {
    public let destinationHash: Data
    public let sourceHash: Data
    public let timestamp: Double
    public let title: Data
    public let content: Data
    public let fields: [UInt64: Data]
    public let payload: Data
    public let messageID: Data
    public let signature: Data
    public let packed: Data

    public init(destinationHash: Data, sourceHash: Data, sourceIdentity: ReticulumIdentity, timestamp: Double = Date().timeIntervalSince1970, title: Data = Data(), content: Data, fields: [UInt64: Data] = [:]) throws {
        guard destinationHash.count == 16, sourceHash.count == 16 else { throw MessageError.invalidDestination }
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.fields = fields
        payload = MessagePack.lxmfPayload(timestamp: timestamp, title: title, content: content, fields: fields)
        let hashedPart = destinationHash + sourceHash + payload
        messageID = ReticulumIdentity.fullHash(hashedPart)
        signature = try sourceIdentity.sign(hashedPart + messageID)
        packed = destinationHash + sourceHash + signature + payload
    }

    public func validate(with sourceIdentity: ReticulumIdentity) -> Bool {
        let hashedPart = destinationHash + sourceHash + payload
        return ReticulumIdentity.fullHash(hashedPart) == messageID && sourceIdentity.validate(signature: signature, message: hashedPart + messageID)
    }

    public func propagatedEnvelope(recipientIdentity: ReticulumIdentity, timestamp: Double = Date().timeIntervalSince1970, ephemeralPrivateKey: Data? = nil, iv: Data? = nil, ratchet: Data? = nil) throws -> Data {
        let encrypted = try recipientIdentity.encrypt(Data(packed.dropFirst(16)), ephemeralPrivateKey: ephemeralPrivateKey, iv: iv, ratchet: ratchet)
        let lxmfData = destinationHash + encrypted
        return MessagePack.array([MessagePack.double(timestamp), MessagePack.array([MessagePack.binary(lxmfData)])])
    }

    public func opportunisticPacket(recipientIdentity: ReticulumIdentity, ephemeralPrivateKey: Data? = nil, iv: Data? = nil, ratchet: Data? = nil) throws -> Data {
        let encrypted = try recipientIdentity.encrypt(Data(packed.dropFirst(16)), ephemeralPrivateKey: ephemeralPrivateKey, iv: iv, ratchet: ratchet)
        return Data([0x00, 0x00]) + destinationHash + Data([0x00]) + encrypted
    }
    public enum MessageError: Error { case invalidDestination }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
