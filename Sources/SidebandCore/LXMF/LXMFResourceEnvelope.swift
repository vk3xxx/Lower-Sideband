import Foundation

public struct LXMFResourceEnvelope: Equatable, Sendable {
    public let filename: String
    public let mimeType: String?
    public let messageBody: String
    public let sourceHash: Data
    public let groupID: UUID
    public let fileData: Data
    public let signature: Data

    public init(filename: String, mimeType: String?, messageBody: String, sourceHash: Data, groupID: UUID = UUID(), fileData: Data, signingIdentity: ReticulumIdentity) throws {
        guard sourceHash.count == 16 else { throw EnvelopeError.invalidSource }
        self.filename = filename; self.mimeType = mimeType; self.messageBody = messageBody; self.sourceHash = sourceHash; self.groupID = groupID; self.fileData = fileData
        signature = try signingIdentity.sign(Self.signedPayload(filename: filename, mimeType: mimeType, messageBody: messageBody, sourceHash: sourceHash, groupID: groupID, fileData: fileData))
    }

    public func encode() throws -> Data {
        let metadata = MessagePack.map([
            ("n", MessagePack.binary(Data(filename.utf8))),
            ("m", mimeType.map { MessagePack.binary(Data($0.utf8)) } ?? MessagePack.null),
            ("b", MessagePack.binary(Data(messageBody.utf8))),
            ("s", MessagePack.binary(sourceHash)),
            ("g", MessagePack.binary(groupID.data)),
            ("v", MessagePack.binary(signature))
        ])
        guard metadata.count <= 0xff_ffff else { throw EnvelopeError.metadataTooLarge }
        return Data([UInt8(metadata.count >> 16), UInt8((metadata.count >> 8) & 0xff), UInt8(metadata.count & 0xff)]) + metadata + fileData
    }

    public init(encoded: Data) throws {
        guard encoded.count >= 3 else { throw EnvelopeError.truncated }
        let length = Int(encoded[0]) << 16 | Int(encoded[1]) << 8 | Int(encoded[2])
        guard encoded.count >= 3 + length, case let .map(entries) = try MessagePackDecoder.decode(encoded.subdata(in: 3..<(3 + length))) else { throw EnvelopeError.truncated }
        func value(_ key: String) -> MessagePackValue? { entries.first { $0.0 == .string(key) }?.1 }
        func binary(_ key: String) -> Data? { if case let .binary(data)? = value(key) { data } else { nil } }
        guard let nameData = binary("n"), let filename = String(data: nameData, encoding: .utf8),
              let bodyData = binary("b"), let messageBody = String(data: bodyData, encoding: .utf8),
              let sourceHash = binary("s"), sourceHash.count == 16,
              let groupData = binary("g"), let groupID = UUID(data: groupData),
              let signature = binary("v"), signature.count == 64 else { throw EnvelopeError.invalidMetadata }
        self.filename = filename; self.messageBody = messageBody; self.sourceHash = sourceHash; self.groupID = groupID; self.signature = signature
        if let mimeData = binary("m") { mimeType = String(data: mimeData, encoding: .utf8) } else { mimeType = nil }
        fileData = encoded.subdata(in: (3 + length)..<encoded.count)
    }

    public func validate(with identity: ReticulumIdentity) -> Bool {
        identity.validate(signature: signature, message: Self.signedPayload(filename: filename, mimeType: mimeType, messageBody: messageBody, sourceHash: sourceHash, groupID: groupID, fileData: fileData))
    }

    private static func signedPayload(filename: String, mimeType: String?, messageBody: String, sourceHash: Data, groupID: UUID, fileData: Data) -> Data {
        MessagePack.array([
            MessagePack.binary(Data(filename.utf8)), mimeType.map { MessagePack.binary(Data($0.utf8)) } ?? MessagePack.null,
            MessagePack.binary(Data(messageBody.utf8)), MessagePack.binary(sourceHash), MessagePack.binary(groupID.data),
            MessagePack.binary(ReticulumIdentity.fullHash(fileData))
        ])
    }

    public enum EnvelopeError: Error { case invalidSource, metadataTooLarge, truncated, invalidMetadata }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}

private extension UUID {
    var data: Data { var value = uuid; return withUnsafeBytes(of: &value) { Data($0) } }
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        self.init(uuid: value)
    }
}
