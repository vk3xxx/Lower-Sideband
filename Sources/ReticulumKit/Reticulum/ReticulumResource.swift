import Foundation

public struct ReticulumResourceManifest: Equatable, Sendable {
    /// Stock Reticulum resource payload capacity at the default 500-byte MTU:
    /// MTU - maximum header (35) - minimum IFAC (1).
    public static let defaultSDU = 464
    public static let mapHashLength = 4
    public static let randomHashLength = 4

    public let size: Int
    public let dataSize: Int
    public let sdu: Int
    public let randomHash: Data
    public let resourceHash: Data
    public let partHashes: [Data]
    public let partCount: Int

    public init(data: Data, sdu: Int = Self.defaultSDU, randomHash: Data) throws {
        try self.init(data: data, transferData: data, sdu: sdu, randomHash: randomHash)
    }

    public init(data: Data, transferData: Data, sdu: Int = Self.defaultSDU, randomHash: Data) throws {
        guard sdu > 0, randomHash.count == Self.randomHashLength else { throw ResourceError.invalidManifest }
        size = transferData.count
        dataSize = data.count
        self.sdu = sdu
        self.randomHash = randomHash
        resourceHash = ReticulumIdentity.fullHash(data + randomHash)
        let parts = transferData.chunks(of: sdu)
        partHashes = parts.map { Data(ReticulumIdentity.fullHash($0 + randomHash).prefix(Self.mapHashLength)) }
        partCount = partHashes.count
        guard Set(partHashes).count == partHashes.count else { throw ResourceError.mapHashCollision }
    }

    public init(advertisement: ReticulumResourceAdvertisement, sdu: Int = Self.defaultSDU) throws {
        guard ReticulumResourceLimits.accepts(
                  dataSize: advertisement.dataSize,
                  transferSize: advertisement.transferSize,
                  partCount: advertisement.partCount,
                  segments: advertisement.totalSegments,
                  segmentIndex: advertisement.segmentIndex,
                  advertisedPartHashCount: advertisement.partHashes.count,
                  sdu: sdu
              ) else { throw ResourceError.invalidManifest }
        size = advertisement.transferSize; dataSize = advertisement.dataSize; self.sdu = sdu
        randomHash = advertisement.mapRandomHash; resourceHash = advertisement.resourceHash; partHashes = advertisement.partHashes; partCount = advertisement.partCount
    }

    public func parts(from transferData: Data) throws -> [Data] {
        guard transferData.count == size else { throw ResourceError.hashMismatch }
        let parts = transferData.chunks(of: sdu)
        guard parts.map({ Data(ReticulumIdentity.fullHash($0 + randomHash).prefix(Self.mapHashLength)) }) == partHashes else { throw ResourceError.hashMismatch }
        return parts
    }

    public func validate(data: Data) -> Bool {
        data.count == dataSize && validateHash(data: data)
    }

    public func validateHash(data: Data) -> Bool {
        ReticulumIdentity.fullHash(data + randomHash) == resourceHash
    }
}

public struct ReticulumResourceReceiver: Sendable {
    public let manifest: ReticulumResourceManifest
    private var received: [Int: Data] = [:]
    private var knownPartHashes: [Data?]

    public init(manifest: ReticulumResourceManifest) {
        self.manifest = manifest
        knownPartHashes = Array(repeating: nil, count: manifest.partCount)
        for (index, hash) in manifest.partHashes.enumerated() { knownPartHashes[index] = hash }
    }
    public var receivedPartCount: Int { received.count }
    public var progress: Double { manifest.partCount == 0 ? 1 : Double(received.count) / Double(manifest.partCount) }
    public var isComplete: Bool { received.count == manifest.partCount }
    public var missingPartIndices: [Int] { knownPartHashes.indices.filter { knownPartHashes[$0] != nil && received[$0] == nil } }
    public var knownHashCount: Int { knownPartHashes.compactMap { $0 }.count }
    public var needsMoreHashMap: Bool { knownHashCount < manifest.partCount }
    public func expectedHash(at index: Int) -> Data? { knownPartHashes.indices.contains(index) ? knownPartHashes[index] : nil }

    public mutating func applyHashMap(segment: Int, hashes: [Data]) throws {
        guard segment >= 0,
              segment <= manifest.partCount / ReticulumResourceAdvertisement.hashMapMaximumEntries else {
            throw ResourceError.invalidManifest
        }
        let start = segment * ReticulumResourceAdvertisement.hashMapMaximumEntries
        guard start < manifest.partCount,
              hashes.count <= manifest.partCount - start,
              hashes.allSatisfy({ $0.count == ReticulumResourceManifest.mapHashLength }) else {
            throw ResourceError.invalidManifest
        }
        for (offset, hash) in hashes.enumerated() {
            let index = start + offset
            if let existing = knownPartHashes[index], existing != hash { throw ResourceError.hashMismatch }
            knownPartHashes[index] = hash
        }
    }

    public func nextRequest(window: Int = 4) throws -> ReticulumResourceRequest {
        let hashes = missingPartIndices.prefix(window).compactMap { knownPartHashes[$0] }
        let wantsMore = hashes.isEmpty && needsMoreHashMap
        let lastKnown = wantsMore ? knownPartHashes.compactMap { $0 }.last : nil
        return try ReticulumResourceRequest(resourceHash: manifest.resourceHash, requestedPartHashes: hashes, wantsMoreHashMap: wantsMore, lastKnownMapHash: lastKnown)
    }

    public mutating func accept(part: Data, at index: Int) throws {
        guard knownPartHashes.indices.contains(index), let expected = knownPartHashes[index] else { throw ResourceError.invalidPartIndex }
        let hash = Data(ReticulumIdentity.fullHash(part + manifest.randomHash).prefix(ReticulumResourceManifest.mapHashLength))
        guard hash == expected else { throw ResourceError.hashMismatch }
        received[index] = part
    }

    public func assemble() throws -> Data {
        guard isComplete else { throw ResourceError.incomplete }
        var data = Data()
        for index in 0..<manifest.partCount { data.append(received[index]!) }
        guard data.count == manifest.size else { throw ResourceError.hashMismatch }
        return data
    }
}

public enum ResourceError: Error { case invalidManifest, invalidPartIndex, hashMismatch, mapHashCollision, incomplete }

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
    func chunks(of size: Int) -> [Data] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { offset in subdata(in: offset..<Swift.min(offset + size, count)) }
    }
}
