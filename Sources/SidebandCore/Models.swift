import Foundation

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var destinationHash: String
    public var displayName: String
    public var isTrusted: Bool
    public var unreadCount: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), destinationHash: String, displayName: String, isTrusted: Bool = false, unreadCount: Int = 0, updatedAt: Date = .now) {
        self.id = id
        self.destinationHash = destinationHash.lowercased()
        self.displayName = displayName
        self.isTrusted = isTrusted
        self.unreadCount = unreadCount
        self.updatedAt = updatedAt
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

    public init(id: UUID = UUID(), conversationID: UUID, body: String, timestamp: Date = .now, direction: Direction, state: DeliveryState) {
        self.id = id
        self.conversationID = conversationID
        self.body = body
        self.timestamp = timestamp
        self.direction = direction
        self.state = state
    }
}

public struct AppSnapshot: Codable, Sendable {
    public var conversations: [Conversation]
    public var messages: [Message]
    public var discoveries: [DiscoveredDestination]
    public init(conversations: [Conversation] = [], messages: [Message] = [], discoveries: [DiscoveredDestination] = []) {
        self.conversations = conversations
        self.messages = messages
        self.discoveries = discoveries
    }

    private enum CodingKeys: String, CodingKey { case conversations, messages, discoveries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try values.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        messages = try values.decodeIfPresent([Message].self, forKey: .messages) ?? []
        discoveries = try values.decodeIfPresent([DiscoveredDestination].self, forKey: .discoveries) ?? []
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
