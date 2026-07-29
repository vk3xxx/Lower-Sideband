import ReticulumKit
import Foundation
import SQLite3

/// Read-only importer for the historical Python Sideband `sideband.db` schema.
/// The source file is never modified and no Python runtime is required.
public enum LegacySidebandSQLiteImporter {
    private static let maximumConversations = 100_000
    private static let maximumMessages = 1_000_000
    private static let maximumAnnounces = 50_000
    private static let maximumTelemetryRecords = 50_000

    public struct ConversationCandidate: Identifiable, Sendable, Equatable {
        public var id: String { destinationHash }
        public let destinationHash: String
        public let displayName: String
    }

    public struct Preview: Sendable, Equatable {
        public let sourceBytes: Int
        public let conversations: Int
        public let messages: Int
        public let announces: Int
        public let telemetryRecords: Int
        public let availableTables: [String]
        public let conversationCandidates: [ConversationCandidate]
    }

    public struct Selection: Sendable, Equatable {
        public var selectedDestinations: Set<String>?
        public var includesMessages: Bool
        public var includesTelemetry: Bool
        public var includesAnnounces: Bool

        public static let all = Selection(
            selectedDestinations: nil,
            includesMessages: true,
            includesTelemetry: true,
            includesAnnounces: true
        )

        public init(
            selectedDestinations: Set<String>?,
            includesMessages: Bool,
            includesTelemetry: Bool,
            includesAnnounces: Bool
        ) {
            self.selectedDestinations = selectedDestinations
            self.includesMessages = includesMessages
            self.includesTelemetry = includesTelemetry
            self.includesAnnounces = includesAnnounces
        }
    }

    public struct Report: Sendable {
        public let snapshot: AppSnapshot
        public let skippedMessages: Int
        public let skippedTelemetry: Int
        public let importedAnnounces: Int
        public let importedTelemetry: Int
        public let importedRichMessages: Int
        public let warnings: [String]
    }

    public enum ImportError: LocalizedError {
        case cannotOpen, unsupportedSchema, corruptRow
        public var errorDescription: String? {
            switch self {
            case .cannotOpen: "The legacy Sideband database could not be opened read-only."
            case .unsupportedSchema: "The file is not a supported Python Sideband SQLite database."
            case .corruptRow: "The legacy database contains a malformed required row."
            }
        }
    }

    public static func preview(from url: URL) throws -> Preview {
        let sourceBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try withDatabase(at: url) { database in
            let tables = tableNames(in: database)
            guard tables.contains("conv"), tables.contains("lxm") else { throw ImportError.unsupportedSchema }
            let conversationColumns = tableColumns("conv", in: database)
            let destinationExpression = expression(in: conversationColumns, aliases: ["dest_context", "destination_hash", "destination", "dest"])
            let nameExpression = expression(in: conversationColumns, aliases: ["name", "display_name"])
            var candidates: [ConversationCandidate] = []
            if destinationExpression != "NULL" {
                try rows("SELECT \(destinationExpression),\(nameExpression) FROM conv LIMIT \(maximumConversations)", in: database) { statement in
                    guard let destination = destinationHash(statement, 0) else { return }
                    let hash = destination.hex
                    let name = textOrBlobString(statement, 1)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    candidates.append(ConversationCandidate(
                        destinationHash: hash,
                        displayName: name?.isEmpty == false ? name! : "Imported \(hash.prefix(8))"
                    ))
                }
            }
            return Preview(
                sourceBytes: sourceBytes,
                conversations: countRows("conv", in: database),
                messages: countRows("lxm", in: database),
                announces: tables.contains("announce") ? countRows("announce", in: database) : 0,
                telemetryRecords: tables.contains("telemetry") ? countRows("telemetry", in: database) : 0,
                availableTables: tables.sorted(),
                conversationCandidates: candidates.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            )
        }
    }

    public static func load(from url: URL) throws -> Report {
        try withDatabase(at: url) { database in
            try load(from: database)
        }
    }

    public static func load(from url: URL, selection: Selection) throws -> Report {
        try filtered(load(from: url), selection: selection)
    }

    private static func filtered(_ report: Report, selection: Selection) throws -> Report {
        let selectedDestinations = selection.selectedDestinations
        let conversations = report.snapshot.conversations.filter {
            selectedDestinations?.contains($0.destinationHash) ?? true
        }
        let conversationIDs = Set(conversations.map(\.id))
        let messages = selection.includesMessages ? report.snapshot.messages.filter { message in
            guard conversationIDs.contains(message.conversationID) else { return false }
            return selection.includesTelemetry || message.telemetry == nil
        } : []
        let importedTelemetry = messages.count { $0.telemetry != nil }
        let discoveries = selection.includesAnnounces ? report.snapshot.discoveries : []
        return Report(
            snapshot: AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries),
            skippedMessages: report.skippedMessages,
            skippedTelemetry: report.skippedTelemetry,
            importedAnnounces: discoveries.count,
            importedTelemetry: importedTelemetry,
            importedRichMessages: messages.count {
                $0.telemetry != nil || !$0.telemetryStream.isEmpty || $0.voiceAudio != nil ||
                $0.renderer != .plain || $0.replyTo != nil || $0.reactionTo != nil ||
                $0.commentTo != nil || $0.continuationOf != nil || !$0.commands.isEmpty
            },
            warnings: report.warnings
        )
    }

    private static func load(from database: OpaquePointer) throws -> Report {
        guard hasTable("conv", in: database), hasTable("lxm", in: database) else { throw ImportError.unsupportedSchema }
        let conversationColumns = tableColumns("conv", in: database)
        let destinationExpression = expression(in: conversationColumns, aliases: ["dest_context", "destination_hash", "destination", "dest"])
        guard destinationExpression != "NULL" else { throw ImportError.unsupportedSchema }
        let lastTXExpression = expression(in: conversationColumns, aliases: ["last_tx", "last_sent", "last_activity"], fallback: "0")
        let lastRXExpression = expression(in: conversationColumns, aliases: ["last_rx", "last_received", "last_activity"], fallback: "0")
        let unreadExpression = expression(in: conversationColumns, aliases: ["unread", "unread_count"], fallback: "0")
        let trustExpression = expression(in: conversationColumns, aliases: ["trust", "trusted"], fallback: "0")
        let nameExpression = expression(in: conversationColumns, aliases: ["name", "display_name"])
        let dataExpression = expression(in: conversationColumns, aliases: ["data", "metadata", "options"])

        var conversations: [Conversation] = []
        var conversationByDestination: [Data: Conversation] = [:]
        let conversationSQL = "SELECT \(destinationExpression),\(lastTXExpression),\(lastRXExpression),\(unreadExpression),\(trustExpression),\(nameExpression),\(dataExpression) FROM conv LIMIT \(maximumConversations)"
        try rows(conversationSQL, in: database) { statement in
            guard let destination = destinationHash(statement, 0) else { throw ImportError.corruptRow }
            let hash = destination.hex
            let name = textOrBlobString(statement, 5)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastTX = sqlite3_column_double(statement, 1)
            let lastRX = sqlite3_column_double(statement, 2)
            let updated = Date(timeIntervalSince1970: max(lastTX, lastRX, 0))
            let options = conversationOptions(blob(statement, 6))
            let conversation = Conversation(
                destinationHash: hash,
                displayName: (name?.isEmpty == false ? name! : "Imported \(hash.prefix(8))"),
                isTrusted: sqlite3_column_int(statement, 4) != 0,
                isPinned: options.isPinned,
                isArchived: options.isArchived,
                isBlocked: options.isBlocked,
                notificationsMuted: options.notificationsMuted,
                notificationPreviewEnabled: options.notificationPreviewEnabled,
                telemetrySharingEnabled: options.telemetrySharing,
                pluginCommandsEnabled: options.allowRequests,
                contactNote: options.contactNote,
                tags: options.tags,
                appearanceColor: options.color,
                appearanceSymbol: options.symbol,
                deliveryPreference: options.deliveryPreference,
                unreadCount: max(0, Int(sqlite3_column_int64(statement, 3))),
                updatedAt: updated
            )
            conversations.append(conversation)
            conversationByDestination[destination] = conversation
        }

        var messages: [Message] = []
        var skipped = 0
        var importedRichMessages = 0
        var warnings: [String] = []
        let messageColumns = tableColumns("lxm", in: database)
        let messageHashExpression = expression(in: messageColumns, aliases: ["lxm_hash", "message_hash", "hash"])
        let messageDestinationExpression = expression(in: messageColumns, aliases: ["dest", "destination", "destination_hash"])
        let messageSourceExpression = expression(in: messageColumns, aliases: ["source", "source_hash"])
        guard messageDestinationExpression != "NULL", messageSourceExpression != "NULL" else { throw ImportError.unsupportedSchema }
        let titleExpression = expression(in: messageColumns, aliases: ["title", "subject"])
        let txExpression = expression(in: messageColumns, aliases: ["tx_ts", "sent_at", "timestamp"], fallback: "0")
        let rxExpression = expression(in: messageColumns, aliases: ["rx_ts", "received_at", "timestamp"], fallback: "0")
        let stateExpression = expression(in: messageColumns, aliases: ["state", "delivery_state"], fallback: "0")
        let packedExpression = expression(in: messageColumns, aliases: ["data", "packed", "content", "body"])
        let messageSQL = "SELECT \(messageHashExpression),\(messageDestinationExpression),\(messageSourceExpression),\(titleExpression),\(txExpression),\(rxExpression),\(stateExpression),\(packedExpression) FROM lxm LIMIT \(maximumMessages)"
        try rows(messageSQL, in: database) { statement in
            guard let destination = destinationHash(statement, 1), let source = destinationHash(statement, 2) else { skipped += 1; return }
            let peer = conversationByDestination[destination] ?? conversationByDestination[source]
            guard let peer else { skipped += 1; return }
            let packed = blob(statement, 7) ?? Data()
            let decoded = try? LXMFReceivedMessage(packed: packed)
            let title = decoded?.title ?? blob(statement, 3) ?? Data()
            let content = decoded?.content ?? packed
            let titleText = String(data: title, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let contentText = String(data: content, encoding: .utf8) ?? "[Legacy binary message]"
            let body = titleText.isEmpty ? contentText : "\(titleText)\n\(contentText)"
            let tx = sqlite3_column_double(statement, 4)
            let rx = sqlite3_column_double(statement, 5)
            let incoming = conversationByDestination[source] != nil
            let timestamp = decoded.map { Date(timeIntervalSince1970: $0.timestamp) } ?? Date(timeIntervalSince1970: max(tx, rx, 0))
            let oldState = sqlite3_column_int(statement, 6)
            let state: Message.DeliveryState = incoming ? .delivered : (oldState >= 0x04 ? .delivered : .sent)
            let telemetry = decoded?.binaryField(0x02).flatMap { try? SidebandTelemetry(packed: $0) }
            let telemetryStream = SidebandTelemetryStreamEntry.decode(decoded?.fields[0x03])
            let voiceAudio = LXMFVoiceMessageAudio(field: decoded?.fields[0x07])
            let renderer = decoded?.unsignedField(0x0F)
                .flatMap { UInt8(exactly: $0) }
                .flatMap(Message.Renderer.init(rawValue:)) ?? .plain
            let replyTo = decoded?.binaryField(0x30).flatMap { $0.count == 32 ? $0 : nil }
            let replyQuote = decoded?.binaryField(0x31)
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.prefix(SidebandMessageLimits.maximumReplyQuoteCharacters)) }
            let reactionTarget = decoded?.binaryMapField(0x40, key: 0x00).flatMap { $0.count == 32 ? $0 : nil }
            let reactionContent = decoded?.binaryMapField(0x40, key: 0x01)
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.prefix(SidebandMessageLimits.maximumReactionCharacters)) }
            let commentTo = decoded?.binaryMapField(0x41, key: 0x00).flatMap { $0.count == 32 ? $0 : nil }
            let continuationOf = decoded?.binaryMapField(0x42, key: 0x00).flatMap { $0.count == 32 ? $0 : nil }
            let commands = LXMFCommand.decode(decoded?.fields[0x09])
            if telemetry != nil || !telemetryStream.isEmpty || voiceAudio != nil || renderer != .plain ||
                replyTo != nil || reactionTarget != nil || commentTo != nil || continuationOf != nil || !commands.isEmpty {
                importedRichMessages += 1
            }
            messages.append(Message(
                conversationID: peer.id, body: String(body.prefix(SidebandMessageLimits.maximumTextCharacters)),
                timestamp: timestamp, direction: incoming ? .incoming : .outgoing, state: state,
                telemetry: telemetry,
                telemetryStream: telemetryStream,
                voiceAudio: voiceAudio,
                renderer: renderer,
                lxmfID: decoded?.messageID ?? messageID(statement, 0),
                replyTo: replyTo,
                replyQuote: replyQuote,
                reactionTo: reactionTarget,
                reactionContent: reactionContent,
                commentTo: commentTo,
                continuationOf: continuationOf,
                commands: commands
            ))
        }

        var discoveries: [DiscoveredDestination] = []
        if hasTable("announce", in: database) {
            try rows("SELECT received,source,data,dest_type FROM announce ORDER BY received DESC LIMIT \(maximumAnnounces)", in: database) { statement in
                guard let source = blob(statement, 1), source.count == 16 else { return }
                let destinationType = textOrBlobString(statement, 3) ?? "lxmf.delivery"
                guard destinationType == "lxmf.delivery" else { return }
                discoveries.append(DiscoveredDestination(
                    destinationHash: source.hex,
                    hops: 0,
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    isValidated: false,
                    appData: blob(statement, 2)
                ))
            }
        }

        var importedTelemetry = 0
        var skippedTelemetry = 0
        if hasTable("telemetry", in: database) {
            try rows("SELECT dest_context,ts,data FROM telemetry ORDER BY ts LIMIT \(maximumTelemetryRecords)", in: database) { statement in
                guard let destination = blob(statement, 0),
                      let conversation = conversationByDestination[destination],
                      let packed = blob(statement, 2),
                      let telemetry = try? SidebandTelemetry(packed: packed) else {
                    skippedTelemetry += 1
                    return
                }
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                var identityMaterial = destination
                withUnsafeBytes(of: timestamp.timeIntervalSince1970.bitPattern.bigEndian) {
                    identityMaterial.append(contentsOf: $0)
                }
                identityMaterial.append(packed)
                messages.append(Message(
                    conversationID: conversation.id,
                    body: "Imported telemetry",
                    timestamp: timestamp,
                    direction: .incoming,
                    state: .delivered,
                    telemetry: telemetry,
                    lxmfID: ReticulumIdentity.fullHash(identityMaterial)
                ))
                importedTelemetry += 1
            }
        }
        if skipped > 0 { warnings.append("Skipped \(skipped) message rows without a matching conversation.") }
        if skippedTelemetry > 0 { warnings.append("Skipped \(skippedTelemetry) malformed or unmatched telemetry records.") }
        if !discoveries.isEmpty { warnings.append("Imported announces are unverified until seen and validated again on Reticulum.") }
        if countRows("conv", in: database) > maximumConversations { warnings.append("Conversation import was limited to \(maximumConversations) records.") }
        if countRows("lxm", in: database) > maximumMessages { warnings.append("Message import was limited to \(maximumMessages) records.") }
        if hasTable("announce", in: database), countRows("announce", in: database) > maximumAnnounces { warnings.append("Announce import was limited to \(maximumAnnounces) records.") }
        if hasTable("telemetry", in: database), countRows("telemetry", in: database) > maximumTelemetryRecords { warnings.append("Telemetry import was limited to \(maximumTelemetryRecords) records.") }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        messages.sort { $0.timestamp < $1.timestamp }
        return Report(
            snapshot: AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries),
            skippedMessages: skipped,
            skippedTelemetry: skippedTelemetry,
            importedAnnounces: discoveries.count,
            importedTelemetry: importedTelemetry,
            importedRichMessages: importedRichMessages,
            warnings: warnings
        )
    }

    private static func withDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ImportError.cannotOpen
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func hasTable(_ name: String, in database: OpaquePointer) -> Bool {
        var found = false
        try? rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)' LIMIT 1", in: database) { _ in found = true }
        return found
    }

    private static func tableNames(in database: OpaquePointer) -> [String] {
        var names: [String] = []
        try? rows("SELECT name FROM sqlite_master WHERE type='table'", in: database) { statement in
            if let name = textOrBlobString(statement, 0) { names.append(name) }
        }
        return names
    }

    private static func tableColumns(_ table: String, in database: OpaquePointer) -> Set<String> {
        var columns: Set<String> = []
        try? rows("PRAGMA table_info(\(table))", in: database) { statement in
            if let name = textOrBlobString(statement, 1) { columns.insert(name) }
        }
        return columns
    }

    private static func countRows(_ table: String, in database: OpaquePointer) -> Int {
        var count = 0
        try? rows("SELECT COUNT(*) FROM \(table)", in: database) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    private struct ConversationOptions {
        var telemetrySharing = false
        var allowRequests = false
        var isPinned = false
        var isArchived = false
        var isBlocked = false
        var notificationsMuted = false
        var notificationPreviewEnabled: Bool?
        var contactNote = ""
        var tags: [String] = []
        var deliveryPreference: Conversation.DeliveryPreference = .automatic
        var color: Conversation.AppearanceColor = .blue
        var symbol: Conversation.AppearanceSymbol = .person
    }

    private static func conversationOptions(_ data: Data?) -> ConversationOptions {
        guard let data, case let .map(entries)? = try? MessagePackDecoder.decode(data) else { return ConversationOptions() }
        var options = ConversationOptions()
        for (key, value) in entries {
            guard case let .string(name) = key else { continue }
            if name == "telemetry", case let .bool(enabled) = value { options.telemetrySharing = enabled }
            if name == "allow_requests", case let .bool(enabled) = value { options.allowRequests = enabled }
            if name == "pinned", case let .bool(enabled) = value { options.isPinned = enabled }
            if name == "archived", case let .bool(enabled) = value { options.isArchived = enabled }
            if name == "blocked", case let .bool(enabled) = value { options.isBlocked = enabled }
            if ["muted", "notifications_muted"].contains(name), case let .bool(enabled) = value { options.notificationsMuted = enabled }
            if name == "notification_preview", case let .bool(enabled) = value { options.notificationPreviewEnabled = enabled }
            if ["note", "contact_note"].contains(name), let note = value.stringValue { options.contactNote = String(note.prefix(512)) }
            if name == "tags", case let .array(values) = value {
                options.tags = Array(values.compactMap(\.stringValue).prefix(8)).map { String($0.prefix(32)) }
            }
            if ["propagation", "propagation_preferred"].contains(name), case .bool(true) = value {
                options.deliveryPreference = .propagationPreferred
            }
            if name == "is_object", case .bool(true) = value { options.symbol = .antenna }
            if name == "ptt_enabled", case .bool(true) = value { options.symbol = .radio }
            if name == "appearance_color", let color = value.stringValue.flatMap(Conversation.AppearanceColor.init(rawValue:)) {
                options.color = color
            }
            if name == "appearance_symbol", let symbol = value.stringValue.flatMap(Conversation.AppearanceSymbol.init(rawValue:)) {
                options.symbol = symbol
            }
            if name == "appearance", case let .array(parts) = value, let first = parts.first,
               case let .string(icon) = first {
                if icon.localizedCaseInsensitiveContains("car") { options.symbol = .vehicle }
                else if icon.localizedCaseInsensitiveContains("home") { options.symbol = .home }
                else if icon.localizedCaseInsensitiveContains("star") { options.symbol = .favorite }
            }
        }
        return options
    }

    private static func expression(in columns: Set<String>, aliases: [String], fallback: String = "NULL") -> String {
        aliases.first(where: columns.contains) ?? fallback
    }

    private static func destinationHash(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let value = blob(statement, column) else { return nil }
        if value.count == 16 { return value }
        guard value.count == 32, let string = String(data: value, encoding: .utf8) else { return nil }
        return Data(hex: string)
    }

    private static func messageID(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let value = blob(statement, column) else { return nil }
        if value.count == 32 { return value }
        guard value.count == 64, let string = String(data: value, encoding: .utf8) else { return nil }
        return Data(hex: string)
    }

    private static func rows(_ sql: String, in database: OpaquePointer, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ImportError.unsupportedSchema }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(statement)
            case SQLITE_DONE: return
            default: throw ImportError.corruptRow
            }
        }
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= 64 * 1_024 * 1_024 else { return nil }
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func textOrBlobString(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        if sqlite3_column_type(statement, column) == SQLITE_BLOB {
            return blob(statement, column).flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var value = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            value.append(byte)
            index = next
        }
        self = value
    }
}

private extension MessagePackValue {
    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .binary(let value): String(data: value, encoding: .utf8)
        default: nil
        }
    }
}
