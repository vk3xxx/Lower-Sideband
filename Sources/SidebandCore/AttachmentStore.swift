import Foundation
import UniformTypeIdentifiers

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
        return Attachment(id: id, filename: originalName, mimeType: mimeType, byteCount: values.fileSize ?? 0, relativePath: storedName, state: .local)
    }

    public func save(data: Data, filename: String, mimeType: String?) throws -> Attachment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        let storedName = "\(id.uuidString)-\(safeName)"
        try data.write(to: directory.appending(path: storedName), options: .atomic)
        return Attachment(id: id, filename: safeName, mimeType: mimeType, byteCount: data.count, relativePath: storedName, state: .available, progress: 1)
    }

    public func url(for attachment: Attachment) -> URL { directory.appending(path: attachment.relativePath) }
    public func remove(_ attachment: Attachment) throws { try FileManager.default.removeItem(at: url(for: attachment)) }
}

public enum AttachmentStoreError: Error { case tooLarge }
