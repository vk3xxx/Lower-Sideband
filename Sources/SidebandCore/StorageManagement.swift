import Foundation

public struct SidebandStoragePolicy: Codable, Equatable, Sendable {
    public var automaticCleanupEnabled: Bool
    public var messageRetentionDays: Int
    public var attachmentRetentionDays: Int
    public var maximumAttachmentStorageMB: Int

    public init(
        automaticCleanupEnabled: Bool = false,
        messageRetentionDays: Int = 0,
        attachmentRetentionDays: Int = 0,
        maximumAttachmentStorageMB: Int = 0
    ) {
        self.automaticCleanupEnabled = automaticCleanupEnabled
        self.messageRetentionDays = Self.normalizedDays(messageRetentionDays)
        self.attachmentRetentionDays = Self.normalizedDays(attachmentRetentionDays)
        self.maximumAttachmentStorageMB = Self.normalizedMegabytes(maximumAttachmentStorageMB)
    }

    public var normalized: Self {
        Self(
            automaticCleanupEnabled: automaticCleanupEnabled,
            messageRetentionDays: messageRetentionDays,
            attachmentRetentionDays: attachmentRetentionDays,
            maximumAttachmentStorageMB: maximumAttachmentStorageMB
        )
    }

    public static let retentionChoices = [0, 30, 90, 180, 365]
    public static let storageChoicesMB = [0, 250, 500, 1_000, 2_000]

    private static func normalizedDays(_ value: Int) -> Int {
        value == 0 ? 0 : min(3_650, max(7, value))
    }

    private static func normalizedMegabytes(_ value: Int) -> Int {
        value == 0 ? 0 : min(100_000, max(50, value))
    }
}

public struct SidebandStorageCleanupResult: Codable, Equatable, Sendable {
    public let messagesRemoved: Int
    public let attachmentsRemoved: Int
    public let attachmentBytesRemoved: Int
    public let orphanedFilesRemoved: Int
    public let performedAt: Date

    public init(
        messagesRemoved: Int,
        attachmentsRemoved: Int,
        attachmentBytesRemoved: Int,
        orphanedFilesRemoved: Int,
        performedAt: Date = .now
    ) {
        self.messagesRemoved = max(0, messagesRemoved)
        self.attachmentsRemoved = max(0, attachmentsRemoved)
        self.attachmentBytesRemoved = max(0, attachmentBytesRemoved)
        self.orphanedFilesRemoved = max(0, orphanedFilesRemoved)
        self.performedAt = performedAt
    }

    public var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachmentBytesRemoved), countStyle: .file)
        return "\(messagesRemoved) messages · \(attachmentsRemoved) attachments · \(size) freed"
    }
}
