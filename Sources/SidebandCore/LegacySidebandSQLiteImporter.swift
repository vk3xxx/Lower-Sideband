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

    public struct Preview: Sendable, Equatable {
        public let sourceBytes: Int
        public let conversations: Int
        public let messages: Int
        public let announces: Int
        public let telemetryRecords: Int
        public let availableTables: [String]
    }

    public struct Report: Sendable {
        public let snapshot: AppSnapshot
        public let skippedMessages: Int
        public let skippedTelemetry: Int
        public let importedAnnounces: Int
        public let importedTelemetry: Int
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
            return Preview(
                sourceBytes: sourceBytes,
                conversations: countRows("conv", in: database),
                messages: countRows("lxm", in: database),
                announces: tables.contains("announce") ? countRows("announce", in: database) : 0,
                telemetryRecords: tables.contains("telemetry") ? countRows("telemetry", in: database) : 0,
                availableTables: tables.sorted()
            )
        }
    }

    public static func load(from url: URL) throws -> Report {
        try withDatabase(at: url) { database in
            try load(from: database)
        }
    }

    private static func load(from database: OpaquePointer) throws -> Report {
        guard hasTable("conv", in: database), hasTable("lxm", in: database) else { throw ImportError.unsupportedSchema }
        let conversationColumns = tableColumns("conv", in: database)
        let dataExpression = conversationColumns.contains("data") ? "data" : "NULL"
        let nameExpression = conversationColumns.contains("name") ? "name" : "NULL"
        let trustExpression = conversationColumns.contains("trust") ? "trust" : "0"
        let unreadExpression = conversationColumns.contains("unread") ? "unread" : "0"

        var conversations: [Conversation] = []
        var conversationByDestination: [Data: Conversation] = [:]
        try rows("SELECT dest_context,last_tx,last_rx,\(unreadExpression),\(trustExpression),\(nameExpression),\(dataExpression) FROM conv LIMIT \(maximumConversations)", in: database) { statement in
            guard let destination = blob(statement, 0), destination.count == 16 else { throw ImportError.corruptRow }
            let hash = destination.hex
            let nameData = blob(statement, 5) ?? Data()
            let name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastTX = sqlite3_column_double(statement, 1)
            let lastRX = sqlite3_column_double(statement, 2)
            let updated = Date(timeIntervalSince1970: max(lastTX, lastRX, 0))
            let options = conversationOptions(blob(statement, 6))
            let conversation = Conversation(
                destinationHash: hash,
                displayName: (name?.isEmpty == false ? name! : "Imported \(hash.prefix(8))"),
                isTrusted: sqlite3_column_int(statement, 4) != 0,
                telemetrySharingEnabled: options.telemetrySharing,
                pluginCommandsEnabled: options.allowRequests,
                appearanceColor: options.color,
                appearanceSymbol: options.symbol,
                unreadCount: sqlite3_column_int(statement, 3) != 0 ? 1 : 0,
                updatedAt: updated
            )
            conversations.append(conversation)
            conversationByDestination[destination] = conversation
        }

        var messages: [Message] = []
        var skipped = 0
        var warnings: [String] = []
        try rows("SELECT lxm_hash,dest,source,title,tx_ts,rx_ts,state,data FROM lxm ORDER BY MAX(tx_ts,rx_ts) LIMIT \(maximumMessages)", in: database) { statement in
            guard let destination = blob(statement, 1), let source = blob(statement, 2) else { skipped += 1; return }
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
            messages.append(Message(
                conversationID: peer.id, body: String(body.prefix(SidebandMessageLimits.maximumTextCharacters)),
                timestamp: timestamp, direction: incoming ? .incoming : .outgoing, state: state,
                lxmfID: decoded?.messageID ?? blob(statement, 0)
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
            if name == "is_object", case .bool(true) = value { options.symbol = .antenna }
            if name == "ptt_enabled", case .bool(true) = value { options.symbol = .radio }
            if name == "appearance", case let .array(parts) = value, let first = parts.first,
               case let .string(icon) = first {
                if icon.localizedCaseInsensitiveContains("car") { options.symbol = .vehicle }
                else if icon.localizedCaseInsensitiveContains("home") { options.symbol = .home }
                else if icon.localizedCaseInsensitiveContains("star") { options.symbol = .favorite }
            }
        }
        return options
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
}
