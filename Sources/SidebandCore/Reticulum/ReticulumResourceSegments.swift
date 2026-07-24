import Foundation

public struct ReticulumPreparedResourceSegment: Sendable {
    public let index: Int
    public let totalSegments: Int
    public let originalHash: Data
    public let manifest: ReticulumResourceManifest
    public let parts: [Data]
    public let expectedProof: Data
    public let advertisement: ReticulumResourceAdvertisement
}

public enum ReticulumResourceSegmentPlanner {
    public static let maximumEfficientSize = 1_048_575

    public static func split(_ data: Data, maximumSegmentSize: Int = maximumEfficientSize) throws -> [Data] {
        guard maximumSegmentSize > 0 else { throw ResourceError.invalidManifest }
        if data.isEmpty { return [Data()] }
        return stride(from: 0, to: data.count, by: maximumSegmentSize).map { offset in
            data.subdata(in: offset..<min(offset + maximumSegmentSize, data.count))
        }
    }

    public static func prepare(data: Data, session: ReticulumLinkSession, hasMetadata: Bool, maximumSegmentSize: Int = maximumEfficientSize) throws -> [ReticulumPreparedResourceSegment] {
        let slices = try split(data, maximumSegmentSize: maximumSegmentSize)
        var prepared: [(manifest: ReticulumResourceManifest, parts: [Data], proof: Data)] = []
        for slice in slices {
            let encrypted = try session.encryptResourcePayload(slice)
            let randomHash = Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
            let manifest = try ReticulumResourceManifest(data: slice, transferData: encrypted, sdu: session.resourceSDU, randomHash: randomHash)
            prepared.append((manifest, try manifest.parts(from: encrypted), ReticulumIdentity.fullHash(slice + manifest.resourceHash)))
        }
        guard let originalHash = prepared.first?.manifest.resourceHash else { throw ResourceError.invalidManifest }
        return prepared.enumerated().map { offset, item in
            let index = offset + 1
            var flags: UInt8 = 0x01
            if hasMetadata { flags |= 0x20 }
            if prepared.count > 1 { flags |= 0x04 }
            let advertisement = ReticulumResourceAdvertisement(manifest: item.manifest, dataSize: data.count, originalHash: originalHash, segmentIndex: index, totalSegments: prepared.count, flags: flags)
            return ReticulumPreparedResourceSegment(index: index, totalSegments: prepared.count, originalHash: originalHash, manifest: item.manifest, parts: item.parts, expectedProof: item.proof, advertisement: advertisement)
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
