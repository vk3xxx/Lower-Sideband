import Foundation

public enum ConversationSmartCollection: String, CaseIterable, Identifiable, Sendable {
    case all, unread, pinned, attachments, voice, telemetry, failed, muted, archived
    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: "All conversations"
        case .unread: "Unread"
        case .pinned: "Pinned"
        case .attachments: "With files"
        case .voice: "With voice"
        case .telemetry: "With telemetry"
        case .failed: "Delivery attention"
        case .muted: "Muted"
        case .archived: "Archived"
        }
    }
}

public enum ConversationBulkAction: Sendable {
    case pin, unpin, archive, unarchive, mute, unmute, markRead, markUnread
}

public enum ConversationOrganisation {
    public static func matches(
        _ conversation: Conversation,
        collection: ConversationSmartCollection,
        messages: [Message],
        tag: String? = nil
    ) -> Bool {
        if let tag, !tag.isEmpty,
           !conversation.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            return false
        }
        return switch collection {
        case .all: true
        case .unread: conversation.unreadCount > 0
        case .pinned: conversation.isPinned
        case .attachments: messages.contains { $0.conversationID == conversation.id && !$0.attachments.isEmpty }
        case .voice: messages.contains { $0.conversationID == conversation.id && $0.voiceAudio != nil }
        case .telemetry: messages.contains { $0.conversationID == conversation.id && $0.telemetry != nil }
        case .failed: messages.contains { $0.conversationID == conversation.id && $0.direction == .outgoing && $0.state == .failed }
        case .muted: conversation.notificationsMuted
        case .archived: conversation.isArchived
        }
    }
}
