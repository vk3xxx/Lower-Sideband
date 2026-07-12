import Foundation

public struct ReticulumResourceAdvertisement: Equatable, Sendable {
    public static let hashMapMaximumEntries = 82
    public let transferSize: Int
    public let dataSize: Int
    public let partCount: Int
    public let resourceHash: Data
    public let mapRandomHash: Data
    public let originalHash: Data
    public let segmentIndex: Int
    public let totalSegments: Int
    public let requestID: Data?
    public let flags: UInt8
    public let partHashes: [Data]

    public init(manifest: ReticulumResourceManifest, dataSize: Int? = nil, originalHash: Data? = nil, segmentIndex: Int = 1, totalSegments: Int = 1, requestID: Data? = nil, flags: UInt8 = 0x01) {
        transferSize = manifest.size; self.dataSize = dataSize ?? manifest.dataSize; partCount = manifest.partCount
        resourceHash = manifest.resourceHash; mapRandomHash = manifest.mapRandomHash; self.originalHash = originalHash ?? manifest.resourceHash
        self.segmentIndex = segmentIndex; self.totalSegments = totalSegments; self.requestID = requestID; self.flags = flags; partHashes = manifest.partHashes
    }

    public func encode(hashMapSegment: Int = 0) -> Data {
        let start = hashMapSegment * Self.hashMapMaximumEntries
        let end = min(start + Self.hashMapMaximumEntries, partHashes.count)
        let map = start < end ? partHashes[start..<end].reduce(into: Data()) { $0.append($1) } : Data()
        return MessagePack.map([
            ("t", MessagePack.unsigned(UInt64(transferSize))), ("d", MessagePack.unsigned(UInt64(dataSize))),
            ("n", MessagePack.unsigned(UInt64(partCount))), ("h", MessagePack.binary(resourceHash)),
            ("r", MessagePack.binary(mapRandomHash)), ("o", MessagePack.binary(originalHash)),
            ("i", MessagePack.unsigned(UInt64(segmentIndex))), ("l", MessagePack.unsigned(UInt64(totalSegments))),
            ("q", requestID.map(MessagePack.binary) ?? MessagePack.null), ("f", MessagePack.unsigned(UInt64(flags))),
            ("m", MessagePack.binary(map))
        ])
    }

    public init(encoded: Data) throws {
        guard case let .map(entries) = try MessagePackDecoder.decode(encoded) else { throw ResourceError.invalidManifest }
        func value(_ key: String) -> MessagePackValue? { entries.first { $0.0 == .string(key) }?.1 }
        func integer(_ key: String) -> Int? { if case let .unsigned(v)? = value(key) { Int(exactly: v) } else { nil } }
        func binary(_ key: String) -> Data? { if case let .binary(v)? = value(key) { v } else { nil } }
        guard let transferSize = integer("t"), let dataSize = integer("d"), let partCount = integer("n"),
              let resourceHash = binary("h"), let mapRandomHash = binary("r"), let originalHash = binary("o"),
              let segmentIndex = integer("i"), let totalSegments = integer("l"), let flagsValue = integer("f"), let flags = UInt8(exactly: flagsValue), let map = binary("m"),
              resourceHash.count == 32, mapRandomHash.count == 4, originalHash.count == 32, map.count.isMultiple(of: 4) else { throw ResourceError.invalidManifest }
        self.transferSize = transferSize; self.dataSize = dataSize; self.partCount = partCount; self.resourceHash = resourceHash
        self.mapRandomHash = mapRandomHash; self.originalHash = originalHash; self.segmentIndex = segmentIndex; self.totalSegments = totalSegments
        if case let .binary(id)? = value("q") { requestID = id } else { requestID = nil }
        self.flags = flags
        partHashes = stride(from: 0, to: map.count, by: 4).map { map.subdata(in: $0..<($0 + 4)) }
    }
}
