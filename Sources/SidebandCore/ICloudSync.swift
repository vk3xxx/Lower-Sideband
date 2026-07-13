import CloudKit
import Foundation

public enum ICloudSyncStatus: Equatable, Sendable {
    case disabled
    case checkingAccount
    case ready
    case syncing
    case synced(Date)
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .disabled: "Off"
        case .checkingAccount: "Checking iCloud account…"
        case .ready: "Ready"
        case .syncing: "Syncing…"
        case let .synced(date): "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case let .unavailable(reason): reason
        case let .failed(reason): "Sync failed: \(reason)"
        }
    }
}

public struct CloudSnapshotPayload: Sendable {
    public let data: Data
    public let modifiedAt: Date
    public let deviceID: String

    public init(data: Data, modifiedAt: Date, deviceID: String) {
        self.data = data
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }
}

public struct CloudAttachmentPayload: Sendable {
    public let id: UUID
    public let data: Data
    public let filename: String
    public let mimeType: String?
    public let contentHash: Data

    public init(id: UUID, data: Data, filename: String, mimeType: String?, contentHash: Data) {
        self.id = id
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.contentHash = contentHash
    }
}

public protocol CloudSnapshotSyncing: Sendable {
    func accountAvailable() async -> Bool
    func fetchSnapshot() async throws -> CloudSnapshotPayload?
    func saveSnapshot(_ payload: CloudSnapshotPayload) async throws
    func fetchAttachment(id: UUID) async throws -> CloudAttachmentPayload?
    func saveAttachment(_ payload: CloudAttachmentPayload) async throws
}

public actor CloudKitSnapshotSync: CloudSnapshotSyncing {
    public static let containerIdentifier = "iCloud.com.supes.MacSideband"
    private let containerIdentifier: String
    private let recordID = CKRecord.ID(recordName: "sideband-private-state-v1")

    public init(containerIdentifier: String = CloudKitSnapshotSync.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public func accountAvailable() async -> Bool {
        #if os(macOS)
        // The SwiftPM desktop package is not yet provisioned for iCloud. Avoid asking
        // CloudKit for a container from that unsigned bundle, which can terminate the app.
        guard Bundle.main.bundleIdentifier == "com.supes.MacSideband" else { return false }
        #endif
        let container = CKContainer(identifier: containerIdentifier)
        return (try? await container.accountStatus()) == .available
    }

    public func fetchSnapshot() async throws -> CloudSnapshotPayload? {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        let encrypted = record.encryptedValues["snapshot"] as? Data
            ?? (record.encryptedValues["snapshot"] as? NSData).map { Data(referencing: $0) }
        guard let encrypted else { return nil }
        return CloudSnapshotPayload(
            data: encrypted,
            modifiedAt: record["modifiedAt"] as? Date ?? record.modificationDate ?? .distantPast,
            deviceID: record["deviceID"] as? String ?? "unknown"
        )
    }

    public func saveSnapshot(_ payload: CloudSnapshotPayload) async throws {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "SidebandState", recordID: recordID) }
        record.encryptedValues["snapshot"] = payload.data as NSData
        record["modifiedAt"] = payload.modifiedAt as NSDate
        record["deviceID"] = payload.deviceID as NSString
        _ = try await database.save(record)
    }

    public func fetchAttachment(id: UUID) async throws -> CloudAttachmentPayload? {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let record: CKRecord
        do { record = try await database.record(for: attachmentRecordID(id)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        guard let asset = record.encryptedValues["file"] as? CKAsset,
              let fileURL = asset.fileURL,
              let filename = record.encryptedValues["filename"] as? String,
              let contentHash = record.encryptedValues["contentHash"] as? Data else { return nil }
        return CloudAttachmentPayload(
            id: id,
            data: try Data(contentsOf: fileURL),
            filename: filename,
            mimeType: record.encryptedValues["mimeType"] as? String,
            contentHash: contentHash
        )
    }

    public func saveAttachment(_ payload: CloudAttachmentPayload) async throws {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let recordID = attachmentRecordID(payload.id)
        let record: CKRecord
        do {
            let existing = try await database.record(for: recordID)
            if existing.encryptedValues["contentHash"] as? Data == payload.contentHash { return }
            record = existing
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "SidebandAttachment", recordID: recordID)
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "sideband-cloud-\(payload.id.uuidString)-\(UUID().uuidString)")
        try payload.data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        record.encryptedValues["file"] = CKAsset(fileURL: temporaryURL)
        record.encryptedValues["filename"] = payload.filename as NSString
        if let mimeType = payload.mimeType { record.encryptedValues["mimeType"] = mimeType as NSString }
        else { record.encryptedValues["mimeType"] = nil }
        record.encryptedValues["contentHash"] = payload.contentHash as NSData
        _ = try await database.save(record)
    }

    private func attachmentRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "attachment-\(id.uuidString.lowercased())")
    }
}

public extension AppSnapshot {
    /// Merges cloud state without importing device-specific routing discoveries.
    func mergingCloudSnapshot(_ remote: AppSnapshot) -> AppSnapshot {
        var canonicalByDestination: [String: Conversation] = [:]
        var conversationIDMap: [UUID: UUID] = [:]

        for conversation in remote.conversations {
            canonicalByDestination[conversation.destinationHash] = conversation
            conversationIDMap[conversation.id] = conversation.id
        }
        for local in conversations {
            if let remoteConversation = canonicalByDestination[local.destinationHash] {
                let canonicalID = remoteConversation.id
                conversationIDMap[local.id] = canonicalID
                conversationIDMap[remoteConversation.id] = canonicalID
                canonicalByDestination[local.destinationHash] = local.updatedAt >= remoteConversation.updatedAt
                    ? Conversation(
                        id: canonicalID, destinationHash: local.destinationHash, displayName: local.displayName,
                        isTrusted: local.isTrusted, isPinned: local.isPinned, isArchived: local.isArchived,
                        isBlocked: local.isBlocked, notificationsMuted: local.notificationsMuted,
                        unreadCount: local.unreadCount, updatedAt: local.updatedAt
                    )
                    : remoteConversation
            } else {
                canonicalByDestination[local.destinationHash] = local
                conversationIDMap[local.id] = local.id
            }
        }

        func remapped(_ message: Message) -> Message? {
            guard let conversationID = conversationIDMap[message.conversationID] else { return nil }
            return Message(
                id: message.id, conversationID: conversationID, body: message.body,
                timestamp: message.timestamp, direction: message.direction, state: message.state,
                attachments: message.attachments, telemetry: message.telemetry,
                outboxOwnerID: message.outboxOwnerID, outboxOwnerUpdatedAt: message.outboxOwnerUpdatedAt
            )
        }

        var messagesByID: [UUID: Message] = [:]
        for message in remote.messages.compactMap(remapped) { messagesByID[message.id] = message }
        for local in messages.compactMap(remapped) {
            guard let remoteMessage = messagesByID[local.id] else { messagesByID[local.id] = local; continue }
            let state = Self.furthestDeliveryState(local.state, remoteMessage.state)
            let preferred = local.timestamp >= remoteMessage.timestamp ? local : remoteMessage
            let ownerSource = (local.outboxOwnerUpdatedAt ?? .distantPast) >= (remoteMessage.outboxOwnerUpdatedAt ?? .distantPast)
                ? local : remoteMessage
            messagesByID[local.id] = Message(
                id: preferred.id, conversationID: preferred.conversationID, body: preferred.body,
                timestamp: preferred.timestamp, direction: preferred.direction, state: state,
                attachments: preferred.attachments.isEmpty ? (local.attachments.isEmpty ? remoteMessage.attachments : local.attachments) : preferred.attachments,
                telemetry: preferred.telemetry ?? local.telemetry ?? remoteMessage.telemetry,
                outboxOwnerID: ownerSource.outboxOwnerID, outboxOwnerUpdatedAt: ownerSource.outboxOwnerUpdatedAt
            )
        }

        var mergedDrafts: [UUID: String] = [:]
        for (id, draft) in remote.drafts {
            if let canonical = conversationIDMap[id], !draft.isEmpty { mergedDrafts[canonical] = draft }
        }
        for (id, draft) in drafts {
            if let canonical = conversationIDMap[id], !draft.isEmpty { mergedDrafts[canonical] = draft }
        }

        return AppSnapshot(
            schemaVersion: max(schemaVersion, remote.schemaVersion),
            conversations: canonicalByDestination.values.sorted { $0.updatedAt > $1.updatedAt },
            messages: messagesByID.values.sorted { $0.timestamp < $1.timestamp },
            discoveries: discoveries,
            drafts: mergedDrafts
        )
    }

    private static func furthestDeliveryState(_ lhs: Message.DeliveryState, _ rhs: Message.DeliveryState) -> Message.DeliveryState {
        func rank(_ state: Message.DeliveryState) -> Int {
            switch state { case .failed: 0; case .queued: 1; case .sent: 2; case .delivered: 3 }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}
