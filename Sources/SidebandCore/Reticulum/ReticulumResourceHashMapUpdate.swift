import Foundation

public struct ReticulumResourceHashMapUpdate: Equatable, Sendable {
    public let resourceHash: Data
    public let segment: Int
    public let partHashes: [Data]

    public init(resourceHash: Data, segment: Int, partHashes: [Data]) throws {
        guard resourceHash.count == 32, segment >= 0, partHashes.allSatisfy({ $0.count == 4 }) else { throw ResourceError.invalidManifest }
        self.resourceHash = resourceHash; self.segment = segment; self.partHashes = partHashes
    }

    public func encode() -> Data {
        resourceHash + MessagePack.array([MessagePack.unsigned(UInt64(segment)), MessagePack.binary(partHashes.reduce(into: Data()) { $0.append($1) })])
    }

    public init(encoded: Data) throws {
        guard encoded.count > 32, case let .array(values) = try MessagePackDecoder.decode(Data(encoded.dropFirst(32))), values.count == 2,
              case let .unsigned(segmentValue) = values[0], let segment = Int(exactly: segmentValue),
              case let .binary(map) = values[1], map.count.isMultiple(of: 4) else { throw ResourceError.invalidManifest }
        resourceHash = Data(encoded.prefix(32)); self.segment = segment
        partHashes = stride(from: 0, to: map.count, by: 4).map { map.subdata(in: $0..<($0 + 4)) }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
