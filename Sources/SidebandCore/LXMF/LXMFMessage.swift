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
    public let stamp: Data?

    public init(destinationHash: Data, sourceHash: Data, sourceIdentity: ReticulumIdentity, timestamp: Double = Date().timeIntervalSince1970, title: Data = Data(), content: Data, fields: [UInt64: Data] = [:], encodedFields: [UInt64: Data] = [:], stamp: Data? = nil) throws {
        guard destinationHash.count == 16, sourceHash.count == 16 else { throw MessageError.invalidDestination }
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.fields = fields
        if let stamp, stamp.count != LXMFStamp.stampSize && stamp.count != LXMFStamp.ticketSize { throw MessageError.invalidStamp }
        self.stamp = stamp
        let unsignedPayload = MessagePack.lxmfPayload(timestamp: timestamp, title: title, content: content, fields: fields, encodedFields: encodedFields)
        payload = MessagePack.lxmfPayload(timestamp: timestamp, title: title, content: content, fields: fields, encodedFields: encodedFields, stamp: stamp)
        let hashedPart = destinationHash + sourceHash + unsignedPayload
        messageID = ReticulumIdentity.fullHash(hashedPart)
        signature = try sourceIdentity.sign(hashedPart + messageID)
        packed = destinationHash + sourceHash + signature + payload
    }

    public func validate(with sourceIdentity: ReticulumIdentity) -> Bool {
        let unsignedPayload = MessagePack.lxmfPayload(timestamp: timestamp, title: title, content: content, fields: fields)
        let hashedPart = destinationHash + sourceHash + unsignedPayload
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

    /// Returns the Python LXMF-compatible paper representation: destination
    /// hash followed by the encrypted signed message, encoded as an unpadded
    /// URL-safe Base64 `lxm://` URI.
    public func paperURI(recipientIdentity: ReticulumIdentity, ephemeralPrivateKey: Data? = nil, iv: Data? = nil, ratchet: Data? = nil) throws -> String {
        let encrypted = try recipientIdentity.encrypt(Data(packed.dropFirst(16)), ephemeralPrivateKey: ephemeralPrivateKey, iv: iv, ratchet: ratchet)
        return try LXMURI.encode(destinationHash + encrypted)
    }
    public enum MessageError: Error { case invalidDestination, invalidStamp }
}

public enum LXMURI {
    public static let scheme = "lxm"
    public static let maximumURICharacters = 2_953
    public static let maximumPackedBytes = ((maximumURICharacters - 6) * 6) / 8

    public static func encode(_ paperPacked: Data) throws -> String {
        guard !paperPacked.isEmpty, paperPacked.count <= maximumPackedBytes else { throw Error.messageTooLarge }
        let encoded = paperPacked.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let uri = "\(scheme)://\(encoded)"
        guard uri.count <= maximumURICharacters else { throw Error.messageTooLarge }
        return uri
    }

    public static func decode(_ uri: String) throws -> Data {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumURICharacters,
              trimmed.lowercased().hasPrefix("\(scheme)://") else { throw Error.invalidURI }
        let encoded = String(trimmed.dropFirst(scheme.count + 3))
        guard !encoded.isEmpty,
              encoded.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw Error.invalidURI }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= maximumPackedBytes else { throw Error.invalidURI }
        return data
    }

    public enum Error: LocalizedError {
        case invalidURI, messageTooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidURI: "The LXM paper-message link is invalid."
            case .messageTooLarge: "This message is too large for an LXMF paper QR code."
            }
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
