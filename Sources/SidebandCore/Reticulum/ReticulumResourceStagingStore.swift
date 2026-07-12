import Foundation

public actor ReticulumResourceStagingStore {
    private struct Transfer { let totalSegments: Int; let totalSize: Int; var received: Set<Int> = [] }
    public let directory: URL
    private var transfers: [String: Transfer] = [:]

    public init(directory: URL) { self.directory = directory }

    public func stage(data: Data, originalHash: Data, segmentIndex: Int, totalSegments: Int, totalSize: Int) throws -> Double {
        guard originalHash.count == 32, (1...totalSegments).contains(segmentIndex), totalSize >= 0 else { throw ResourceError.invalidManifest }
        let key = originalHash.hex
        var transfer = transfers[key] ?? Transfer(totalSegments: totalSegments, totalSize: totalSize)
        guard transfer.totalSegments == totalSegments, transfer.totalSize == totalSize else { throw ResourceError.invalidManifest }
        let folder = directory.appending(path: key, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "\(segmentIndex).part"), options: .atomic)
        transfer.received.insert(segmentIndex); transfers[key] = transfer
        return Double(transfer.received.count) / Double(totalSegments)
    }

    public func isComplete(originalHash: Data) -> Bool {
        guard let transfer = transfers[originalHash.hex] else { return false }
        return transfer.received.count == transfer.totalSegments
    }

    public func assemble(originalHash: Data) throws -> Data {
        let key = originalHash.hex
        guard let transfer = transfers[key], transfer.received.count == transfer.totalSegments else { throw ResourceError.incomplete }
        let folder = directory.appending(path: key, directoryHint: .isDirectory)
        var data = Data()
        for index in 1...transfer.totalSegments { data.append(try Data(contentsOf: folder.appending(path: "\(index).part"))) }
        guard data.count == transfer.totalSize else { throw ResourceError.hashMismatch }
        try? FileManager.default.removeItem(at: folder); transfers.removeValue(forKey: key)
        return data
    }
}

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
