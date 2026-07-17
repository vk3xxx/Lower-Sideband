import Foundation

public struct SidebandContactCollection: Codable, Sendable {
    public static let currentVersion = 1

    public struct Contact: Codable, Sendable {
        public var destinationHash: String
        public var displayName: String
        public var publicKey: Data?
        public var wasIdentityVerified: Bool
        public var contactNote: String?
        public var appearanceColor: Conversation.AppearanceColor?
        public var appearanceSymbol: Conversation.AppearanceSymbol?

        public init(destinationHash: String, displayName: String, publicKey: Data?, wasIdentityVerified: Bool, contactNote: String? = nil, appearanceColor: Conversation.AppearanceColor? = nil, appearanceSymbol: Conversation.AppearanceSymbol? = nil) {
            self.destinationHash = destinationHash
            self.displayName = displayName
            self.publicKey = publicKey
            self.wasIdentityVerified = wasIdentityVerified
            self.contactNote = contactNote
            self.appearanceColor = appearanceColor
            self.appearanceSymbol = appearanceSymbol
        }
    }

    public var version: Int
    public var exportedAt: Date
    public var contacts: [Contact]

    public init(version: Int = Self.currentVersion, exportedAt: Date = .now, contacts: [Contact]) {
        self.version = version
        self.exportedAt = exportedAt
        self.contacts = contacts
    }
}
