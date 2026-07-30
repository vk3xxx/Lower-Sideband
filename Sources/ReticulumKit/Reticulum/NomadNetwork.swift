import Foundation

/// Reticulum link-request framing used by Nomad Network page nodes.
public struct ReticulumPathRequestEnvelope: Equatable, Sendable {
    public let path: String
    public let data: MessagePackValue
    public let timestamp: Double

    public init(path: String, data: MessagePackValue = .null, timestamp: Double = Date.now.timeIntervalSince1970) throws {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 1_024, timestamp.isFinite else {
            throw RequestError.invalidRequest
        }
        self.path = path
        self.data = data
        self.timestamp = timestamp
    }

    public var encoded: Data {
        MessagePack.array([
            MessagePack.double(timestamp),
            MessagePack.binary(ReticulumIdentity.truncatedHash(Data(path.utf8))),
            MessagePack.encode(data)
        ])
    }

    public var requestID: Data { ReticulumIdentity.truncatedHash(encoded) }

    public static func decodeResponse(_ encoded: Data, expectedRequestID: Data) throws -> Data {
        guard expectedRequestID.count == 16,
              case let .array(values) = try MessagePackDecoder.decode(
                encoded,
                limits: .init(maximumDepth: 16, maximumCollectionCount: 4_096, maximumNodeCount: 8_192, maximumScalarBytes: 1_048_576)
              ),
              values.count == 2,
              values[0] == .binary(expectedRequestID) else { throw RequestError.invalidResponse }
        switch values[1] {
        case .binary(let value): return value
        case .string(let value): return Data(value.utf8)
        default: throw RequestError.invalidResponse
        }
    }

    public enum RequestError: Error { case invalidRequest, invalidResponse }
}

public enum NomadNetworkProtocol {
    public static let destinationName = "nomadnetwork.node"
    public static let indexPath = "/page/index.mu"
    public static let maximumPageBytes = 1_048_576

    public static func destinationHash(for identity: ReticulumIdentity) -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash)
    }

    public static func pageRequest(path: String, query: [String: String], timestamp: Double = Date.now.timeIntervalSince1970) throws -> ReticulumPathRequestEnvelope {
        guard query.count <= 64 else { throw ReticulumPathRequestEnvelope.RequestError.invalidRequest }
        let values: [(MessagePackValue, MessagePackValue)] = try query.sorted(by: { $0.key < $1.key }).map {
            guard $0.key.utf8.count <= 128, $0.value.utf8.count <= 4_096 else {
                throw ReticulumPathRequestEnvelope.RequestError.invalidRequest
            }
            return (.string("var_\($0.key)"), .string($0.value))
        }
        return try ReticulumPathRequestEnvelope(path: path, data: .map(values), timestamp: timestamp)
    }
}
