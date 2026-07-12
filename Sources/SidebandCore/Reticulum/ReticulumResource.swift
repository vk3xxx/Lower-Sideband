import Foundation

public struct ReticulumResourceManifest: Equatable, Sendable {
    public static let defaultSDU = 465
    public static let mapHashLength = 4
    public static let randomHashLength = 4

    public let size: Int
    public let sdu: Int
    public let resourceRandomHash: Data
    public let mapRandomHash: Data
    public let resourceHash: Data
    public let partHashes: [Data]

    public var partCount: Int { partHashes.count }

    public init(data: Data, sdu: Int = Self.defaultSDU, resourceRandomHash: Data, mapRandomHash: Data) throws {
        guard sdu > 0, resourceRandomHash.count == Self.randomHashLength, mapRandomHash.count == Self.randomHashLength else { throw ResourceError.invalidManifest }
        size = data.count
        self.sdu = sdu
        self.resourceRandomHash = resourceRandomHash
        self.mapRandomHash = mapRandomHash
        resourceHash = ReticulumIdentity.fullHash(data + resourceRandomHash)
        let parts = data.chunks(of: sdu)
        partHashes = parts.map { Data(ReticulumIdentity.fullHash($0 + mapRandomHash).prefix(Self.mapHashLength)) }
        guard Set(partHashes).count == partHashes.count else { throw ResourceError.mapHashCollision }
    }

    public func parts(from data: Data) throws -> [Data] {
        guard data.count == size, ReticulumIdentity.fullHash(data + resourceRandomHash) == resourceHash else { throw ResourceError.hashMismatch }
        return data.chunks(of: sdu)
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
        let hash = Data(ReticulumIdentity.fullHash(part + manifest.mapRandomHash).prefix(ReticulumResourceManifest.mapHashLength))
        guard hash == manifest.partHashes[index] else { throw ResourceError.hashMismatch }
        received[index] = part
    }

    public func assemble() throws -> Data {
        guard isComplete else { throw ResourceError.incomplete }
        var data = Data()
        for index in manifest.partHashes.indices { data.append(received[index]!) }
        guard data.count == manifest.size, ReticulumIdentity.fullHash(data + manifest.resourceRandomHash) == manifest.resourceHash else { throw ResourceError.hashMismatch }
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
