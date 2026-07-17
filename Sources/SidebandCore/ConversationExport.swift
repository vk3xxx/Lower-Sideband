import Foundation

public struct SidebandConversationExport: Codable, Sendable {
    public static let currentVersion = 2

    public struct Contact: Codable, Sendable {
        public var displayName: String
        public var destinationHash: String
        public var trusted: Bool
        public var identityFingerprint: String?
        public var identityVerifiedAt: Date?
    }

    public struct ExportedAttachment: Codable, Sendable {
        public var filename: String
        public var mimeType: String?
        public var byteCount: Int
        public var contentHash: Data?
        public var state: Attachment.TransferState?
    }

    public struct ExportedMessage: Codable, Sendable {
        public var id: UUID
        public var lxmfID: Data?
        public var timestamp: Date
        public var direction: Message.Direction
        public var state: Message.DeliveryState
        public var body: String
        public var renderer: Message.Renderer
        public var replyTo: Data?
        public var replyQuote: String?
        public var reactionTo: Data?
        public var reactionContent: String?
        public var commentTo: Data?
        public var continuationOf: Data?
        public var commands: [LXMFCommand]?
        public var telemetry: SidebandTelemetry?
        public var attachments: [ExportedAttachment]
        public var deliveryAttemptCount: Int?
        public var lastDeliveryAttemptAt: Date?
        public var lastDeliveryMode: Message.DeliveryMode?
        public var lastDeliveryFailure: String?
    }

    public var version: Int
    public var exportedAt: Date
    public var contact: Contact
    public var messages: [ExportedMessage]

    public init(exportedAt: Date = .now, conversation: Conversation, fingerprint: String?, messages: [Message]) {
        version = Self.currentVersion
        self.exportedAt = exportedAt
        contact = Contact(
            displayName: conversation.displayName,
            destinationHash: conversation.destinationHash,
            trusted: conversation.isTrusted,
            identityFingerprint: fingerprint,
            identityVerifiedAt: conversation.identityVerifiedAt
        )
        self.messages = messages.sorted(by: { $0.timestamp < $1.timestamp }).map { message in
            ExportedMessage(
                id: message.id,
                lxmfID: message.lxmfID,
                timestamp: message.timestamp,
                direction: message.direction,
                state: message.state,
                body: message.body,
                renderer: message.renderer,
                replyTo: message.replyTo,
                replyQuote: message.replyQuote,
                reactionTo: message.reactionTo,
                reactionContent: message.reactionContent,
                commentTo: message.commentTo,
                continuationOf: message.continuationOf,
                commands: message.commands.isEmpty ? nil : message.commands,
                telemetry: message.telemetry,
                attachments: message.attachments.map {
                    ExportedAttachment(filename: $0.filename, mimeType: $0.mimeType, byteCount: $0.byteCount, contentHash: $0.contentHash, state: $0.state)
                },
                deliveryAttemptCount: message.deliveryAttemptCount,
                lastDeliveryAttemptAt: message.lastDeliveryAttemptAt,
                lastDeliveryMode: message.lastDeliveryMode,
                lastDeliveryFailure: message.lastDeliveryFailure
            )
        }
    }
}
