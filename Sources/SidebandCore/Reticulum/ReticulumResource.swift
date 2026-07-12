import Foundation

public struct ReticulumResourceManifest: Equatable, Sendable {
    public static let defaultSDU = 465
    public static let mapHashLength = 4
    public static let randomHashLength = 4

    public let size: Int
    public let dataSize: Int
    public let sdu: Int
    public let randomHash: Data
    public let resourceHash: Data
    public let partHashes: [Data]

    public var partCount: Int { partHashes.count }

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
        guard Set(partHashes).count == partHashes.count else { throw ResourceError.mapHashCollision }
    }

    public init(advertisement: ReticulumResourceAdvertisement, sdu: Int = Self.defaultSDU) throws {
        guard advertisement.partCount == advertisement.partHashes.count, advertisement.transferSize >= 0, advertisement.dataSize >= 0 else { throw ResourceError.invalidManifest }
        size = advertisement.transferSize; dataSize = advertisement.dataSize; self.sdu = sdu
        randomHash = advertisement.mapRandomHash; resourceHash = advertisement.resourceHash; partHashes = advertisement.partHashes
    }

    public func parts(from transferData: Data) throws -> [Data] {
        guard transferData.count == size else { throw ResourceError.hashMismatch }
        let parts = transferData.chunks(of: sdu)
        guard parts.map({ Data(ReticulumIdentity.fullHash($0 + randomHash).prefix(Self.mapHashLength)) }) == partHashes else { throw ResourceError.hashMismatch }
        return parts
    }

    public func validate(data: Data) -> Bool {
        data.count == dataSize && ReticulumIdentity.fullHash(data + randomHash) == resourceHash
    }
}

public struct ReticulumResourceReceiver: Sendable {
    public let manifest: ReticulumResourceManifest
    private var received: [Int: Data] = [:]

    public init(manifest: ReticulumResourceManifest) { self.manifest = manifest }
    public var receivedPartCount: Int { received.count }
    public var progress: Double { manifest.partCount == 0 ? 1 : Double(received.count) / Double(manifest.partCount) }
    public var isComplete: Bool { received.count == manifest.partCount }
    public var missingPartIndices: [Int] { manifest.partHashes.indices.filter { received[$0] == nil } }

    public mutating func accept(part: Data, at index: Int) throws {
        guard manifest.partHashes.indices.contains(index) else { throw ResourceError.invalidPartIndex }
        let hash = Data(ReticulumIdentity.fullHash(part + manifest.randomHash).prefix(ReticulumResourceManifest.mapHashLength))
        guard hash == manifest.partHashes[index] else { throw ResourceError.hashMismatch }
        received[index] = part
    }

    public func assemble() throws -> Data {
        guard isComplete else { throw ResourceError.incomplete }
        var data = Data()
        for index in manifest.partHashes.indices { data.append(received[index]!) }
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
