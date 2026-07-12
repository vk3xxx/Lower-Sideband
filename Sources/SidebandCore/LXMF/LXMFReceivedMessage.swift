import Foundation

public struct LXMFReceivedMessage: Sendable {
    public let destinationHash: Data
    public let sourceHash: Data
    public let signature: Data
    public let payload: Data
    public let messageID: Data
    public let timestamp: Double
    public let title: Data
    public let content: Data

    public init(packed: Data) throws {
        guard packed.count >= 96 else { throw ParseError.truncated }
        destinationHash = packed.subdata(in: 0..<16)
        sourceHash = packed.subdata(in: 16..<32)
        signature = packed.subdata(in: 32..<96)
        payload = Data(packed.dropFirst(96))
        messageID = ReticulumIdentity.fullHash(destinationHash + sourceHash + payload)
        guard case let .array(parts) = try MessagePackDecoder.decode(payload), parts.count >= 4,
              case let .double(ts) = parts[0], case let .binary(title) = parts[1], case let .binary(content) = parts[2] else { throw ParseError.invalidPayload }
        timestamp = ts; self.title = title; self.content = content
    }

    public func validate(with identity: ReticulumIdentity) -> Bool {
        let hashed = destinationHash + sourceHash + payload
        return identity.validate(signature: signature, message: hashed + messageID)
    }
    public enum ParseError: Error { case truncated, invalidPayload }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
