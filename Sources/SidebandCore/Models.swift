import Foundation

public enum SidebandMessageLimits {
    public static let maximumTextCharacters = 4_096
    public static let maximumAttachments = 8
    public static let maximumCombinedAttachmentBytes = 64 * 1024 * 1024
}

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var destinationHash: String
    public var displayName: String
    public var isTrusted: Bool
    public var isPinned: Bool
    public var isArchived: Bool
    public var isBlocked: Bool
    public var notificationsMuted: Bool
    public var unreadCount: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), destinationHash: String, displayName: String, isTrusted: Bool = false, isPinned: Bool = false, isArchived: Bool = false, isBlocked: Bool = false, notificationsMuted: Bool = false, unreadCount: Int = 0, updatedAt: Date = .now) {
        self.id = id
        self.destinationHash = destinationHash.lowercased()
        self.displayName = displayName
        self.isTrusted = isTrusted
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.isBlocked = isBlocked
        self.notificationsMuted = notificationsMuted
        self.unreadCount = unreadCount
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, destinationHash, displayName, isTrusted, isPinned, isArchived, isBlocked, notificationsMuted, unreadCount, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        destinationHash = try values.decode(String.self, forKey: .destinationHash)
        displayName = try values.decode(String.self, forKey: .displayName)
        isTrusted = try values.decodeIfPresent(Bool.self, forKey: .isTrusted) ?? false
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isBlocked = try values.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        notificationsMuted = try values.decodeIfPresent(Bool.self, forKey: .notificationsMuted) ?? false
        unreadCount = try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public enum Direction: String, Codable, Sendable { case incoming, outgoing }
    public enum DeliveryState: String, Codable, Sendable { case queued, sent, delivered, failed }

    public let id: UUID
    public let conversationID: UUID
    public var body: String
    public var timestamp: Date
    public var direction: Direction
    public var state: DeliveryState
    public var attachments: [Attachment]
    public var telemetry: SidebandTelemetry?

    public init(id: UUID = UUID(), conversationID: UUID, body: String, timestamp: Date = .now, direction: Direction, state: DeliveryState, attachments: [Attachment] = [], telemetry: SidebandTelemetry? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.body = body
        self.timestamp = timestamp
        self.direction = direction
        self.state = state
        self.attachments = attachments
        self.telemetry = telemetry
    }

    private enum CodingKeys: String, CodingKey { case id, conversationID, body, timestamp, direction, state, attachments, telemetry }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        conversationID = try values.decode(UUID.self, forKey: .conversationID)
        body = try values.decode(String.self, forKey: .body)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        direction = try values.decode(Direction.self, forKey: .direction)
        state = try values.decode(DeliveryState.self, forKey: .state)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        telemetry = try values.decodeIfPresent(SidebandTelemetry.self, forKey: .telemetry)
    }
}

public struct Attachment: Identifiable, Codable, Hashable, Sendable {
    public enum TransferState: String, Codable, Sendable { case local, queued, transferring, available, failed }
    public let id: UUID
    public var filename: String
    public var mimeType: String?
    public var byteCount: Int
    public var relativePath: String
    public var state: TransferState
    public var progress: Double
    public var contentHash: Data?

    public init(id: UUID = UUID(), filename: String, mimeType: String? = nil, byteCount: Int, relativePath: String, state: TransferState, progress: Double = 0, contentHash: Data? = nil) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.byteCount = byteCount; self.relativePath = relativePath; self.state = state; self.progress = progress; self.contentHash = contentHash
    }
    private enum CodingKeys: String, CodingKey { case id, filename, mimeType, byteCount, relativePath, state, progress, contentHash }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); filename = try values.decode(String.self, forKey: .filename)
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType); byteCount = try values.decode(Int.self, forKey: .byteCount)
        relativePath = try values.decode(String.self, forKey: .relativePath); state = try values.decode(TransferState.self, forKey: .state)
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        contentHash = try values.decodeIfPresent(Data.self, forKey: .contentHash)
    }
}

public struct AppSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var conversations: [Conversation]
    public var messages: [Message]
    public var discoveries: [DiscoveredDestination]
    public var drafts: [UUID: String]
    public init(schemaVersion: Int = Self.currentSchemaVersion, conversations: [Conversation] = [], messages: [Message] = [], discoveries: [DiscoveredDestination] = [], drafts: [UUID: String] = [:]) {
        self.schemaVersion = schemaVersion
        self.conversations = conversations
        self.messages = messages
        self.discoveries = discoveries
        self.drafts = drafts
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, conversations, messages, discoveries, drafts }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        conversations = try values.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        messages = try values.decodeIfPresent([Message].self, forKey: .messages) ?? []
        discoveries = try values.decodeIfPresent([DiscoveredDestination].self, forKey: .discoveries) ?? []
        drafts = try values.decodeIfPresent([UUID: String].self, forKey: .drafts) ?? [:]
    }
}

public enum SnapshotError: LocalizedError {
    case unsupportedVersion, invalidData

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This Sideband backup was created by a newer, unsupported app version."
        case .invalidData: "The Sideband backup contains invalid or inconsistent data."
        }
    }
}

public struct DiscoveredDestination: Identifiable, Codable, Hashable, Sendable {
    public var id: String { destinationHash }
    public let destinationHash: String
    public var hops: UInt8
    public var lastSeen: Date
    public var packetCount: Int
    public var isValidated: Bool
    public var publicKey: Data?
    public var appData: Data?
    public var ratchet: Data?
    public var announcedDisplayName: String? { appData.flatMap { LXMFAnnounceInfo(appData: $0)?.displayName } }

    public init(destinationHash: String, hops: UInt8, lastSeen: Date = .now, packetCount: Int = 1, isValidated: Bool = false, publicKey: Data? = nil, appData: Data? = nil, ratchet: Data? = nil) {
        self.destinationHash = destinationHash
        self.hops = hops
        self.lastSeen = lastSeen
        self.packetCount = packetCount
        self.isValidated = isValidated
        self.publicKey = publicKey
        self.appData = appData
        self.ratchet = ratchet
    }
}
