import Foundation
import UniformTypeIdentifiers
import CryptoKit

public actor AttachmentStore {
    public let directory: URL
    private let localDataCipher = LocalDataCipher()
    private let materializedDirectory: URL

    public init(directory: URL) {
        self.directory = directory
        materializedDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SidebandAttachmentPreviews", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    public func importFile(from source: URL, preferredName: String? = nil) throws -> Attachment {
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey])
        guard (sourceValues.fileSize ?? 0) <= ReticulumResourceLimits.maximumAttachmentBytes else { throw AttachmentStoreError.tooLarge }
        let data = try Data(contentsOf: source)
        guard data.count <= ReticulumResourceLimits.maximumAttachmentBytes else { throw AttachmentStoreError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let originalName = preferredName ?? source.lastPathComponent
        let safeName = try safeFilename(originalName)
        let storedName = "\(id.uuidString)-\(safeName)"
        let destination = directory.appending(path: storedName)
        try encrypted(data, for: id).write(to: destination, options: .atomic)
        let mimeType = normalizedMIMEType(sourceValues.typeIdentifier.flatMap { UTType($0)?.preferredMIMEType }, filename: safeName)
        return Attachment(id: id, filename: safeName, mimeType: mimeType, byteCount: data.count, relativePath: storedName, state: .local, contentHash: Data(SHA256.hash(data: data)))
    }

    public func save(data: Data, filename: String, mimeType: String?) throws -> Attachment {
        guard data.count <= ReticulumResourceLimits.maximumAttachmentBytes else { throw AttachmentStoreError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let safeName = try safeFilename(filename)
        let storedName = "\(id.uuidString)-\(safeName)"
        try encrypted(data, for: id).write(to: directory.appending(path: storedName), options: .atomic)
        return Attachment(id: id, filename: safeName, mimeType: normalizedMIMEType(mimeType, filename: safeName), byteCount: data.count, relativePath: storedName, state: .available, progress: 1, contentHash: Data(SHA256.hash(data: data)))
    }

    public func restoreCloudAttachment(_ payload: CloudAttachmentPayload) throws -> Attachment {
        guard payload.data.count <= ReticulumResourceLimits.maximumAttachmentBytes,
              Data(SHA256.hash(data: payload.data)) == payload.contentHash else { throw AttachmentStoreError.integrityMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = try safeFilename(payload.filename)
        let storedName = "\(payload.id.uuidString)-\(safeName)"
        try encrypted(payload.data, for: payload.id).write(to: directory.appending(path: storedName), options: .atomic)
        return Attachment(
            id: payload.id, filename: safeName, mimeType: normalizedMIMEType(payload.mimeType, filename: safeName), byteCount: payload.data.count,
            relativePath: storedName, state: .available, progress: 1, contentHash: payload.contentHash
        )
    }

    public func url(for attachment: Attachment) -> URL {
        directory.appending(path: URL(fileURLWithPath: attachment.relativePath).lastPathComponent)
    }
    public func read(_ attachment: Attachment) throws -> Data {
        let storedURL = url(for: attachment)
        let storedData = try Data(contentsOf: storedURL)
        let wasEncrypted = localDataCipher.isEncrypted(storedData)
        let data: Data
        do {
            data = try localDataCipher.open(storedData, context: encryptionContext(for: attachment.id))
        } catch {
            throw AttachmentStoreError.integrityMismatch
        }
        guard data.count == attachment.byteCount else { throw AttachmentStoreError.integrityMismatch }
        if let expected = attachment.contentHash, Data(SHA256.hash(data: data)) != expected { throw AttachmentStoreError.integrityMismatch }
        if !wasEncrypted {
            try encrypted(data, for: attachment.id).write(to: storedURL, options: .atomic)
        }
        return data
    }

    public func materializedURL(for attachment: Attachment) throws -> URL {
        let data = try read(attachment)
        try FileManager.default.createDirectory(at: materializedDirectory, withIntermediateDirectories: true)
        let result = materializedDirectory.appending(path: materializedName(for: attachment))
#if os(iOS)
        try data.write(to: result, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: result, options: .atomic)
#endif
        return result
    }

    public func removeMaterializedFile(for attachment: Attachment) {
        try? FileManager.default.removeItem(at: materializedDirectory.appending(path: materializedName(for: attachment)))
    }

    public func removeAllMaterializedFiles() {
        try? FileManager.default.removeItem(at: materializedDirectory)
    }

    public func remove(_ attachment: Attachment) throws {
        removeMaterializedFile(for: attachment)
        try FileManager.default.removeItem(at: url(for: attachment))
    }

    public func removeOrphans(referencedRelativePaths: Set<String>) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let referencedNames = Set(referencedRelativePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        for file in files where !referencedNames.contains(file.lastPathComponent) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: file)
            removedCount += 1
        }
        return removedCount
    }

    public func storageReport(for attachments: [Attachment]) -> AttachmentStorageReport {
        let referencedNames = Set(attachments.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent })
        var storedBytes = 0
        var orphanBytes = 0
        var orphanCount = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for file in files {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = max(0, values.fileSize ?? 0)
                storedBytes += size
                if !referencedNames.contains(file.lastPathComponent) { orphanCount += 1; orphanBytes += size }
            }
        }
        var missing = 0
        var corrupt = 0
        for attachment in attachments {
            guard FileManager.default.fileExists(atPath: url(for: attachment).path) else { missing += 1; continue }
            if (try? read(attachment)) == nil { corrupt += 1 }
        }
        return AttachmentStorageReport(
            attachmentCount: attachments.count,
            logicalBytes: attachments.reduce(0) { $0 + max(0, $1.byteCount) },
            storedBytes: storedBytes,
            missingCount: missing,
            corruptCount: corrupt,
            orphanCount: orphanCount,
            orphanBytes: orphanBytes
        )
    }

    private func encrypted(_ data: Data, for id: UUID) throws -> Data {
        try localDataCipher.seal(data, context: encryptionContext(for: id))
    }

    private func encryptionContext(for id: UUID) -> String {
        "attachment-v1:\(id.uuidString.lowercased())"
    }

    private func materializedName(for attachment: Attachment) -> String {
        "\(attachment.id.uuidString)-\(URL(fileURLWithPath: attachment.filename).lastPathComponent)"
    }

    private func safeFilename(_ filename: String) throws -> String {
        let leaf = URL(fileURLWithPath: filename).lastPathComponent
            .components(separatedBy: .controlCharacters).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { throw AttachmentStoreError.invalidFilename }
        return String(leaf.prefix(180))
    }

    private func normalizedMIMEType(_ mimeType: String?, filename: String) -> String? {
        if let value = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           value.count <= 127, value.split(separator: "/", omittingEmptySubsequences: false).count == 2,
           !value.contains(where: { $0.isWhitespace || $0.isNewline }) { return value }
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        return fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
}

public struct AttachmentStorageReport: Sendable, Equatable {
    public let attachmentCount: Int
    public let logicalBytes: Int
    public let storedBytes: Int
    public let missingCount: Int
    public let corruptCount: Int
    public let orphanCount: Int
    public let orphanBytes: Int

    public var isHealthy: Bool { missingCount == 0 && corruptCount == 0 && orphanCount == 0 }
}

public enum AttachmentStoreError: LocalizedError {
    case tooLarge, integrityMismatch, invalidFilename

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The file exceeds the maximum attachment size."
        case .integrityMismatch: "The attachment failed its integrity check."
        case .invalidFilename: "The attachment filename is invalid."
        }
    }
}
