import ReticulumKit
import Foundation
import SQLite3

/// Read-only importer for the historical Python Sideband `sideband.db` schema.
/// The source file is never modified and no Python runtime is required.
public enum LegacySidebandSQLiteImporter {
    public struct Report: Sendable {
        public let snapshot: AppSnapshot
        public let skippedMessages: Int
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

    public static func load(from url: URL) throws -> Report {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ImportError.cannotOpen
        }
        defer { sqlite3_close(database) }
        guard hasTable("conv", in: database), hasTable("lxm", in: database) else { throw ImportError.unsupportedSchema }

        var conversations: [Conversation] = []
        var conversationByDestination: [Data: Conversation] = [:]
        try rows("SELECT dest_context,last_tx,last_rx,unread,trust,name FROM conv", in: database) { statement in
            guard let destination = blob(statement, 0), destination.count == 16 else { throw ImportError.corruptRow }
            let hash = destination.hex
            let nameData = blob(statement, 5) ?? Data()
            let name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastTX = sqlite3_column_double(statement, 1)
            let lastRX = sqlite3_column_double(statement, 2)
            let updated = Date(timeIntervalSince1970: max(lastTX, lastRX, 0))
            let conversation = Conversation(
                destinationHash: hash,
                displayName: (name?.isEmpty == false ? name! : "Imported \(hash.prefix(8))"),
                isTrusted: sqlite3_column_int(statement, 4) != 0,
                unreadCount: sqlite3_column_int(statement, 3) != 0 ? 1 : 0,
                updatedAt: updated
            )
            conversations.append(conversation)
            conversationByDestination[destination] = conversation
        }

        var messages: [Message] = []
        var skipped = 0
        var warnings: [String] = []
        try rows("SELECT lxm_hash,dest,source,title,tx_ts,rx_ts,state,data FROM lxm ORDER BY MAX(tx_ts,rx_ts)", in: database) { statement in
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
        if skipped > 0 { warnings.append("Skipped \(skipped) message rows without a matching conversation.") }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        messages.sort { $0.timestamp < $1.timestamp }
        return Report(snapshot: AppSnapshot(conversations: conversations, messages: messages), skippedMessages: skipped, warnings: warnings)
    }

    private static func hasTable(_ name: String, in database: OpaquePointer) -> Bool {
        var found = false
        try? rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)' LIMIT 1", in: database) { _ in found = true }
        return found
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
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
