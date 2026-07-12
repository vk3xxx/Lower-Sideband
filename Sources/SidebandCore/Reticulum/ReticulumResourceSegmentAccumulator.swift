import Foundation

public struct ReticulumResourceSegmentAccumulator: Sendable {
    public let originalHash: Data
    public let totalSegments: Int
    public let totalDataSize: Int
    private var segments: [Int: Data] = [:]

    public init(originalHash: Data, totalSegments: Int, totalDataSize: Int) throws {
        guard originalHash.count == 32, totalSegments > 1, totalDataSize >= 0 else { throw ResourceError.invalidManifest }
        self.originalHash = originalHash; self.totalSegments = totalSegments; self.totalDataSize = totalDataSize
    }
    public var receivedSegments: Int { segments.count }
    public var progress: Double { Double(segments.count) / Double(totalSegments) }
    public var isComplete: Bool { segments.count == totalSegments }

    public mutating func accept(_ data: Data, segmentIndex: Int, originalHash: Data, totalSegments: Int) throws {
        guard originalHash == self.originalHash, totalSegments == self.totalSegments, (1...totalSegments).contains(segmentIndex) else { throw ResourceError.invalidManifest }
        if let existing = segments[segmentIndex], existing != data { throw ResourceError.hashMismatch }
        segments[segmentIndex] = data
    }

    public func assemble() throws -> Data {
        guard isComplete else { throw ResourceError.incomplete }
        var data = Data()
        for index in 1...totalSegments { data.append(segments[index]!) }
        guard data.count == totalDataSize else { throw ResourceError.hashMismatch }
        return data
    }
}
