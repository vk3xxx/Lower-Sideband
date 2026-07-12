import Foundation
import UniformTypeIdentifiers
import CryptoKit

public actor AttachmentStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func importFile(from source: URL, preferredName: String? = nil) throws -> Attachment {
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        guard (sourceValues.fileSize ?? 0) <= ReticulumResourceLimits.maximumAttachmentBytes else { throw AttachmentStoreError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let originalName = preferredName ?? source.lastPathComponent
        let storedName = "\(id.uuidString)-\(originalName)"
        let destination = directory.appending(path: storedName)
        try FileManager.default.copyItem(at: source, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey])
        let mimeType = values.typeIdentifier.flatMap { UTType($0)?.preferredMIMEType }
        let data = try Data(contentsOf: destination)
        return Attachment(id: id, filename: originalName, mimeType: mimeType, byteCount: values.fileSize ?? 0, relativePath: storedName, state: .local, contentHash: Data(SHA256.hash(data: data)))
    }

    public func save(data: Data, filename: String, mimeType: String?) throws -> Attachment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        let storedName = "\(id.uuidString)-\(safeName)"
        try data.write(to: directory.appending(path: storedName), options: .atomic)
        return Attachment(id: id, filename: safeName, mimeType: mimeType, byteCount: data.count, relativePath: storedName, state: .available, progress: 1, contentHash: Data(SHA256.hash(data: data)))
    }

    public func url(for attachment: Attachment) -> URL { directory.appending(path: attachment.relativePath) }
    public func read(_ attachment: Attachment) throws -> Data {
        let data = try Data(contentsOf: url(for: attachment))
        guard data.count == attachment.byteCount else { throw AttachmentStoreError.integrityMismatch }
        if let expected = attachment.contentHash, Data(SHA256.hash(data: data)) != expected { throw AttachmentStoreError.integrityMismatch }
        return data
    }
    public func remove(_ attachment: Attachment) throws { try FileManager.default.removeItem(at: url(for: attachment)) }
}

public enum AttachmentStoreError: Error { case tooLarge, integrityMismatch }
