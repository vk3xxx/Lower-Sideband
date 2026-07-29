import Foundation

public struct ReticulumResourceRequest: Equatable, Sendable {
    public static let maximumRequestedParts = 128
    public let resourceHash: Data
    public let requestedPartHashes: [Data]
    public let wantsMoreHashMap: Bool
    public let lastKnownMapHash: Data?

    public init(resourceHash: Data, requestedPartHashes: [Data], wantsMoreHashMap: Bool = false, lastKnownMapHash: Data? = nil) throws {
        guard resourceHash.count == 32, requestedPartHashes.count <= Self.maximumRequestedParts,
              requestedPartHashes.allSatisfy({ $0.count == ReticulumResourceManifest.mapHashLength }),
              (!wantsMoreHashMap || lastKnownMapHash?.count == ReticulumResourceManifest.mapHashLength) else { throw ResourceError.invalidManifest }
        self.resourceHash = resourceHash; self.requestedPartHashes = requestedPartHashes
        self.wantsMoreHashMap = wantsMoreHashMap; self.lastKnownMapHash = lastKnownMapHash
    }

    public init(manifest: ReticulumResourceManifest, missingIndices: [Int], window: Int = 4) throws {
        let requested = missingIndices.prefix(window).map { manifest.partHashes[$0] }
        let knownCount = min(manifest.partHashes.count, ReticulumResourceAdvertisement.hashMapMaximumEntries)
        let exhausted = missingIndices.contains { $0 >= knownCount }
        try self.init(resourceHash: manifest.resourceHash, requestedPartHashes: requested, wantsMoreHashMap: exhausted, lastKnownMapHash: exhausted ? manifest.partHashes.prefix(knownCount).last : nil)
    }

    public func encode() -> Data {
        var output = Data([wantsMoreHashMap ? 0xff : 0x00])
        if wantsMoreHashMap, let lastKnownMapHash { output.append(lastKnownMapHash) }
        output.append(resourceHash)
        for hash in requestedPartHashes { output.append(hash) }
        return output
    }

    public init(encoded: Data) throws {
        guard let marker = encoded.first, marker == 0x00 || marker == 0xff else { throw ResourceError.invalidManifest }
        wantsMoreHashMap = marker == 0xff
        let padding = wantsMoreHashMap ? 5 : 1
        guard encoded.count >= padding + 32, (encoded.count - padding - 32).isMultiple(of: 4) else { throw ResourceError.invalidManifest }
        lastKnownMapHash = wantsMoreHashMap ? encoded.subdata(in: 1..<5) : nil
        resourceHash = encoded.subdata(in: padding..<(padding + 32))
        let requestedCount = (encoded.count - padding - 32) / 4
        guard requestedCount <= Self.maximumRequestedParts else { throw ResourceError.invalidManifest }
        requestedPartHashes = stride(from: padding + 32, to: encoded.count, by: 4).map { encoded.subdata(in: $0..<($0 + 4)) }
    }
}
