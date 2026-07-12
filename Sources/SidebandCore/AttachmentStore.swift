import Foundation
import UniformTypeIdentifiers

public actor AttachmentStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func importFile(from source: URL, preferredName: String? = nil) throws -> Attachment {
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

    public func url(for attachment: Attachment) -> URL { directory.appending(path: attachment.relativePath) }
    public func remove(_ attachment: Attachment) throws { try FileManager.default.removeItem(at: url(for: attachment)) }
}
