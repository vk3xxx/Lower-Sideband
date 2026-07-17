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
    public let fields: [UInt64: MessagePackValue]

    public init(packed: Data) throws {
        guard packed.count >= 96 else { throw ParseError.truncated }
        destinationHash = packed.subdata(in: 0..<16)
        sourceHash = packed.subdata(in: 16..<32)
        signature = packed.subdata(in: 32..<96)
        payload = Data(packed.dropFirst(96))
        messageID = ReticulumIdentity.fullHash(destinationHash + sourceHash + payload)
        guard case let .array(parts) = try MessagePackDecoder.decode(payload), parts.count >= 4,
              case let .double(ts) = parts[0], case let .binary(title) = parts[1], case let .binary(content) = parts[2],
              case let .map(fieldEntries) = parts[3] else { throw ParseError.invalidPayload }
        timestamp = ts; self.title = title; self.content = content
        var decodedFields: [UInt64: MessagePackValue] = [:]
        for (key, value) in fieldEntries {
            guard case let .unsigned(fieldID) = key, decodedFields[fieldID] == nil else { continue }
            decodedFields[fieldID] = value
        }
        fields = decodedFields
    }

    public func validate(with identity: ReticulumIdentity) -> Bool {
        let hashed = destinationHash + sourceHash + payload
        return identity.validate(signature: signature, message: hashed + messageID)
    }
    public func binaryField(_ fieldID: UInt64) -> Data? {
        guard case let .binary(data) = fields[fieldID] else { return nil }
        return data
    }
    public func unsignedField(_ fieldID: UInt64) -> UInt64? {
        guard case let .unsigned(value) = fields[fieldID] else { return nil }
        return value
    }
    public func binaryMapField(_ fieldID: UInt64, key requestedKey: UInt64) -> Data? {
        guard case let .map(entries) = fields[fieldID] else { return nil }
        for (key, value) in entries {
            guard case let .unsigned(keyValue) = key, keyValue == requestedKey,
                  case let .binary(data) = value else { continue }
            return data
        }
        return nil
    }
    public enum ParseError: Error { case truncated, invalidPayload }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
