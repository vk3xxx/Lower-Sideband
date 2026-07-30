import Foundation
import Observation
import ReticulumKit

// MARK: - Nomad Network pages

public struct NomadPageAddress: Codable, Hashable, Sendable {
    public static let defaultPath = "/page/index.mu"

    public let destinationHash: String
    public let path: String
    public let query: [String: String]

    public init?(destinationHash: String, path: String = defaultPath, query: [String: String] = [:]) {
        let destination = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(destination) else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard normalizedPath.utf8.count <= 1_024, query.count <= 64,
              query.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4_096 }) else { return nil }
        self.destinationHash = destination
        self.path = normalizedPath
        self.query = query
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("nomadnet://") ? String(trimmed.dropFirst("nomadnet://".count)) : trimmed
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let destination = parts.first else { return nil }
        let pathAndQuery = parts.count > 1 ? "/" + parts[1] : Self.defaultPath
        let urlParts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(urlParts[0])
        var query: [String: String] = [:]
        if urlParts.count > 1 {
            for pair in urlParts[1].split(separator: "&") {
                let values = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = values.first?.removingPercentEncoding, !key.isEmpty else { continue }
                query[key] = values.count > 1 ? (values[1].removingPercentEncoding ?? String(values[1])) : ""
            }
        }
        self.init(destinationHash: String(destination), path: path, query: query)
    }

    public var string: String {
        let encoded = query.sorted(by: { $0.key < $1.key }).map {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&="))
            return "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
        }.joined(separator: "&")
        return "nomadnet://\(destinationHash)\(path)" + (encoded.isEmpty ? "" : "?\(encoded)")
    }
}

public struct NomadPageDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var address: NomadPageAddress?
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        address: NomadPageAddress? = nil,
        source: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.address = address
        self.source = String(source.prefix(1_048_576))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}

public struct NomadPageVisit: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let address: NomadPageAddress
    public let title: String
    public let visitedAt: Date

    public init(id: UUID = UUID(), address: NomadPageAddress, title: String, visitedAt: Date = .now) {
        self.id = id
        self.address = address
        self.title = String(title.prefix(160))
        self.visitedAt = visitedAt
    }
}

public enum MicronBlock: Identifiable, Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case separator
    case link(label: String, target: String)

    public var id: String {
        switch self {
        case .heading(let level, let text): "h\(level):\(text)"
        case .paragraph(let text): "p:\(text)"
        case .separator: "separator"
        case .link(let label, let target): "l:\(label):\(target)"
        }
    }
}

/// A deliberately bounded native parser for the common Micron page primitives.
/// Unknown formatting control sequences are stripped instead of executed.
public enum MicronParser {
    public static func parse(_ source: String) -> [MicronBlock] {
        var blocks: [MicronBlock] = []
        var paragraph: [String] = []
        func flush() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(sanitized(text))) }
            paragraph.removeAll(keepingCapacity: true)
        }
        for rawLine in source.prefix(1_048_576).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "===" { flush(); blocks.append(.separator); continue }
            if line.hasPrefix("#") {
                flush()
                let level = min(3, line.prefix(while: { $0 == "#" }).count)
                blocks.append(.heading(level: level, text: sanitized(line.dropFirst(level).trimmingCharacters(in: .whitespaces))))
                continue
            }
            if let link = parseLink(line) {
                flush(); blocks.append(link); continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func parseLink(_ line: String) -> MicronBlock? {
        // Common Micron links: `[Label`destination:/path`query]
        guard let labelStart = line.firstIndex(of: "["),
              let separator = line[labelStart...].firstIndex(of: "`"),
              let end = line[separator...].lastIndex(of: "]"),
              separator < end else { return nil }
        let label = sanitized(line[line.index(after: labelStart)..<separator])
        let target = String(line[line.index(after: separator)..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard !label.isEmpty, target.utf8.count <= 4_096 else { return nil }
        return .link(label: label, target: target)
    }

    private static func sanitized<S: StringProtocol>(_ value: S) -> String {
        var output = "", escaping = false
        for character in value {
            if escaping { output.append(character); escaping = false; continue }
            if character == "\\" { escaping = true; continue }
            if character == "`" { continue }
            output.append(character)
        }
        return String(output.prefix(16_384))
    }
}

// MARK: - Identities and telephone preferences

public struct SidebandIdentityProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let destinationHash: String
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), name: String, destinationHash: String, createdAt: Date = .now, lastUsedAt: Date = .now) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.destinationHash = destinationHash.lowercased()
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public enum SidebandRingtone: String, Codable, CaseIterable, Sendable, Identifiable {
    case soft, signal, beacon, classic, silent
    public var id: Self { self }
    public var title: String {
        switch self {
        case .soft: "Soft"
        case .signal: "Signal"
        case .beacon: "Beacon"
        case .classic: "Classic"
        case .silent: "Silent"
        }
    }
    public var systemSoundName: String? {
        switch self {
        case .soft: "default"
        case .signal: "default"
        case .beacon: "default"
        case .classic: "default"
        case .silent: nil
        }
    }
}

public struct SidebandTelephonePreferences: Codable, Equatable, Sendable {
    public var ringtone: SidebandRingtone
    public var voicemailEnabled: Bool
    public var voicemailGreeting: String
    public var ringTimeoutSeconds: Int

    public init(
        ringtone: SidebandRingtone = .soft,
        voicemailEnabled: Bool = false,
        voicemailGreeting: String = "I cannot answer this encrypted call. Please leave a voice message.",
        ringTimeoutSeconds: Int = 30
    ) {
        self.ringtone = ringtone
        self.voicemailEnabled = voicemailEnabled
        self.voicemailGreeting = String(voicemailGreeting.prefix(512))
        self.ringTimeoutSeconds = min(90, max(10, ringTimeoutSeconds))
    }
}

// MARK: - Relay chat, remote shell and remote tools

public struct RelayChatRoom: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(hubDestinationHash):\(name)" }
    public let hubDestinationHash: String
    public var name: String
    public var nickname: String
    public var joinedAt: Date
    public var members: [String]

    public init(hubDestinationHash: String, name: String, nickname: String, joinedAt: Date = .now, members: [String] = []) {
        self.hubDestinationHash = hubDestinationHash.lowercased()
        self.name = String(name.prefix(ReticulumRelayChatProtocol.maximumRoomBytes))
        self.nickname = String(nickname.prefix(ReticulumRelayChatProtocol.maximumNicknameBytes))
        self.joinedAt = joinedAt
        self.members = Array(members.prefix(1_000))
    }
}

public struct RelayChatTranscriptEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let roomID: String
    public let source: String
    public let nickname: String?
    public let body: String
    public let kind: UInt64
    public let sentAt: Date
    public let isOutgoing: Bool

    public init(message: ReticulumRelayChatProtocol.Message, hubDestinationHash: String, isOutgoing: Bool) {
        id = message.messageID.map { String(format: "%02x", $0) }.joined()
        roomID = "\(hubDestinationHash.lowercased()):\(message.room ?? "")"
        source = message.source.map { String(format: "%02x", $0) }.joined()
        nickname = message.nickname
        if case .text(let text) = message.body { body = text } else { body = "" }
        kind = message.type.rawValue
        sentAt = Date(timeIntervalSince1970: Double(message.timestampMilliseconds) / 1_000)
        self.isOutgoing = isOutgoing
    }
}

public struct RemoteShellSessionRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let destinationHash: String
    public var title: String
    public var state: String
    public var transcript: String
    public var nextSequence: UInt16
    public var updatedAt: Date

    public init(id: UUID = UUID(), destinationHash: String, title: String = "Remote Shell", state: String = "Disconnected", transcript: String = "", nextSequence: UInt16 = 0, updatedAt: Date = .now) {
        self.id = id; self.destinationHash = destinationHash.lowercased()
        self.title = String(title.prefix(80)); self.state = state
        self.transcript = String(transcript.suffix(1_048_576)); self.nextSequence = nextSequence; self.updatedAt = updatedAt
    }
}

public struct RemoteToolRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let destinationHash: String
    public let command: String
    public var state: String
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int?
    public let createdAt: Date

    public init(id: UUID = UUID(), destinationHash: String, command: String, state: String = "Queued", stdout: Data = Data(), stderr: Data = Data(), exitCode: Int? = nil, createdAt: Date = .now) {
        self.id = id; self.destinationHash = destinationHash.lowercased(); self.command = String(command.prefix(32_768))
        self.state = state; self.stdout = Data(stdout.prefix(16 * 1_048_576)); self.stderr = Data(stderr.prefix(16 * 1_048_576))
        self.exitCode = exitCode; self.createdAt = createdAt
    }
}

public struct HostedRelayRoom: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var topic: String
    public var accessKey: String?
    public var isModerated: Bool
    public var voicedIdentityHashes: Set<String>

    public init(
        name: String,
        topic: String = "",
        accessKey: String? = nil,
        isModerated: Bool = false,
        voicedIdentityHashes: Set<String> = []
    ) {
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(ReticulumRelayChatProtocol.maximumRoomBytes))
        self.topic = String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        let normalizedKey = accessKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKey = normalizedKey?.isEmpty == false ? String(normalizedKey!.prefix(128)) : nil
        self.isModerated = isModerated
        self.voicedIdentityHashes = Set(voicedIdentityHashes.filter(DestinationHash.isValid).prefix(2_048))
    }
}

public struct HostedRelayHubConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var name: String
    public var greeting: String
    public var announceIntervalSeconds: Int
    public var rooms: [HostedRelayRoom]
    public var bannedIdentityHashes: Set<String>

    public init(
        enabled: Bool = false,
        name: String = "Lower Sideband Relay",
        greeting: String = "Welcome to Lower Sideband Relay Chat",
        announceIntervalSeconds: Int = 900,
        rooms: [HostedRelayRoom] = [HostedRelayRoom(name: "general")],
        bannedIdentityHashes: Set<String> = []
    ) {
        self.enabled = enabled
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.greeting = String(greeting.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.announceIntervalSeconds = min(86_400, max(60, announceIntervalSeconds))
        self.rooms = Array(rooms.filter { !$0.name.isEmpty }.prefix(128))
        self.bannedIdentityHashes = Set(bannedIdentityHashes.filter(DestinationHash.isValid).prefix(2_048))
    }
}

public struct HostedRelayMember: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(linkID):\(room)" }
    public let linkID: String
    public let identityHash: String
    public let nickname: String
    public let room: String
    public let connectedAt: Date
}

public enum RemoteFileTransferDirection: String, Codable, Sendable { case sending, receiving }

public struct RemoteFileTransferRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let destinationHash: String
    public var remotePath: String
    public var attachment: Attachment?
    public let direction: RemoteFileTransferDirection
    public var state: String
    public var progress: Double
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        destinationHash: String,
        remotePath: String,
        attachment: Attachment? = nil,
        direction: RemoteFileTransferDirection,
        state: String = "Queued",
        progress: Double = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.destinationHash = destinationHash.lowercased()
        self.remotePath = String(remotePath.prefix(4_096))
        self.attachment = attachment
        self.direction = direction
        self.state = String(state.prefix(160))
        self.progress = min(1, max(0, progress))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RemoteFileShare: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var remotePath: String
    public var attachment: Attachment
    public var allowedIdentityHashes: Set<String>

    public init(id: UUID = UUID(), remotePath: String, attachment: Attachment, allowedIdentityHashes: Set<String> = []) {
        self.id = id
        self.remotePath = String(remotePath.prefix(4_096))
        self.attachment = attachment
        self.allowedIdentityHashes = Set(allowedIdentityHashes.filter(DestinationHash.isValid).prefix(2_048))
    }
}

public struct RemoteCopyConfiguration: Codable, Hashable, Sendable {
    public var receiverEnabled: Bool
    public var fetchEnabled: Bool
    public var allowedIdentityHashes: Set<String>

    public init(receiverEnabled: Bool = false, fetchEnabled: Bool = false, allowedIdentityHashes: Set<String> = []) {
        self.receiverEnabled = receiverEnabled
        self.fetchEnabled = fetchEnabled
        self.allowedIdentityHashes = Set(allowedIdentityHashes.filter(DestinationHash.isValid).prefix(2_048))
    }
}

public struct NomadHostedPage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var title: String
    public var source: String
    public var isPublished: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), path: String, title: String, source: String, isPublished: Bool = true, updatedAt: Date = .now) {
        self.id = id
        self.path = String(path.prefix(1_024))
        self.title = String(title.prefix(160))
        self.source = String(source.prefix(NomadNetworkProtocol.maximumPageBytes))
        self.isPublished = isPublished
        self.updatedAt = updatedAt
    }
}

public struct NomadHostedFile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var attachment: Attachment
    public var isPublished: Bool

    public init(id: UUID = UUID(), path: String, attachment: Attachment, isPublished: Bool = true) {
        self.id = id
        self.path = String(path.prefix(1_024))
        self.attachment = attachment
        self.isPublished = isPublished
    }
}

public struct NomadServerConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var name: String
    public var announceIntervalSeconds: Int

    public init(enabled: Bool = false, name: String = "Lower Sideband", announceIntervalSeconds: Int = 900) {
        self.enabled = enabled
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.announceIntervalSeconds = min(86_400, max(60, announceIntervalSeconds))
    }
}

@MainActor @Observable
public final class MeshChatFeatureStore {
    public private(set) var pages: [NomadPageDocument] = []
    public private(set) var bookmarks: [NomadPageAddress] = []
    public private(set) var history: [NomadPageVisit] = []
    public private(set) var telephone = SidebandTelephonePreferences()
    public private(set) var relayRooms: [RelayChatRoom] = []
    public private(set) var relayTranscript: [RelayChatTranscriptEntry] = []
    public private(set) var shellSessions: [RemoteShellSessionRecord] = []
    public private(set) var remoteToolRuns: [RemoteToolRun] = []
    public private(set) var relayHub = HostedRelayHubConfiguration()
    public private(set) var remoteCopy = RemoteCopyConfiguration()
    public private(set) var remoteFileTransfers: [RemoteFileTransferRecord] = []
    public private(set) var remoteFileShares: [RemoteFileShare] = []
    public private(set) var nomadServer = NomadServerConfiguration()
    public private(set) var hostedNomadPages: [NomadHostedPage] = []
    public private(set) var hostedNomadFiles: [NomadHostedFile] = []

    private struct Payload: Codable {
        var pages: [NomadPageDocument]
        var bookmarks: [NomadPageAddress]
        var history: [NomadPageVisit]
        var telephone: SidebandTelephonePreferences
        var relayRooms: [RelayChatRoom]?
        var relayTranscript: [RelayChatTranscriptEntry]?
        var shellSessions: [RemoteShellSessionRecord]?
        var remoteToolRuns: [RemoteToolRun]?
        var relayHub: HostedRelayHubConfiguration?
        var remoteCopy: RemoteCopyConfiguration?
        var remoteFileTransfers: [RemoteFileTransferRecord]?
        var remoteFileShares: [RemoteFileShare]?
        var nomadServer: NomadServerConfiguration?
        var hostedNomadPages: [NomadHostedPage]?
        var hostedNomadFiles: [NomadHostedFile]?
    }

    private let cipher: LocalDataCipher
    private let defaults: UserDefaults
    private let storageKey = "meshChatApplicationFeatures.v1"
    private let cipherContext = "meshchat-application-features-v1"

    init(cipher: LocalDataCipher, defaults: UserDefaults = .standard) {
        self.cipher = cipher
        self.defaults = defaults
        load()
    }

    public func savePage(_ page: NomadPageDocument) {
        if let index = pages.firstIndex(where: { $0.id == page.id }) { pages[index] = page }
        else { pages.insert(page, at: 0) }
        pages = Array(pages.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
        persist()
    }

    public func deletePage(_ id: UUID) {
        pages.removeAll { $0.id == id }
        persist()
    }

    public func archivePage(_ id: UUID, archived: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].isArchived = archived
        pages[index].updatedAt = .now
        persist()
    }

    public func recordVisit(address: NomadPageAddress, title: String, source: String) {
        let page = NomadPageDocument(
            title: title.isEmpty ? address.path : title,
            address: address,
            source: source,
            isArchived: false
        )
        savePage(page)
        history.removeAll { $0.address == address }
        history.insert(NomadPageVisit(address: address, title: page.title), at: 0)
        history = Array(history.prefix(250))
        persist()
    }

    public func toggleBookmark(_ address: NomadPageAddress) {
        if let index = bookmarks.firstIndex(of: address) { bookmarks.remove(at: index) }
        else { bookmarks.insert(address, at: 0) }
        bookmarks = Array(bookmarks.prefix(250))
        persist()
    }

    public func clearHistory() { history.removeAll(); persist() }

    public func updateTelephone(_ preferences: SidebandTelephonePreferences) {
        telephone = SidebandTelephonePreferences(
            ringtone: preferences.ringtone,
            voicemailEnabled: preferences.voicemailEnabled,
            voicemailGreeting: preferences.voicemailGreeting,
            ringTimeoutSeconds: preferences.ringTimeoutSeconds
        )
        persist()
    }

    public func upsertRelayRoom(_ room: RelayChatRoom) {
        if let index = relayRooms.firstIndex(where: { $0.id == room.id }) { relayRooms[index] = room }
        else { relayRooms.insert(room, at: 0) }
        relayRooms = Array(relayRooms.prefix(128)); persist()
    }

    public func removeRelayRoom(_ id: String) { relayRooms.removeAll { $0.id == id }; persist() }

    public func recordRelayMessage(_ message: ReticulumRelayChatProtocol.Message, hubDestinationHash: String, outgoing: Bool) {
        let entry = RelayChatTranscriptEntry(message: message, hubDestinationHash: hubDestinationHash, isOutgoing: outgoing)
        guard !relayTranscript.contains(where: { $0.id == entry.id }) else { return }
        relayTranscript.append(entry)
        relayTranscript = Array(relayTranscript.suffix(10_000)); persist()
    }

    public func upsertShellSession(_ session: RemoteShellSessionRecord) {
        if let index = shellSessions.firstIndex(where: { $0.id == session.id }) { shellSessions[index] = session }
        else { shellSessions.insert(session, at: 0) }
        shellSessions = Array(shellSessions.prefix(32)); persist()
    }

    public func upsertRemoteToolRun(_ run: RemoteToolRun) {
        if let index = remoteToolRuns.firstIndex(where: { $0.id == run.id }) { remoteToolRuns[index] = run }
        else { remoteToolRuns.insert(run, at: 0) }
        remoteToolRuns = Array(remoteToolRuns.prefix(250)); persist()
    }

    public func updateRelayHub(_ configuration: HostedRelayHubConfiguration) {
        relayHub = HostedRelayHubConfiguration(
            enabled: configuration.enabled,
            name: configuration.name,
            greeting: configuration.greeting,
            announceIntervalSeconds: configuration.announceIntervalSeconds,
            rooms: configuration.rooms,
            bannedIdentityHashes: configuration.bannedIdentityHashes
        )
        persist()
    }

    public func updateRemoteCopy(_ configuration: RemoteCopyConfiguration) {
        remoteCopy = RemoteCopyConfiguration(
            receiverEnabled: configuration.receiverEnabled,
            fetchEnabled: configuration.fetchEnabled,
            allowedIdentityHashes: configuration.allowedIdentityHashes
        )
        persist()
    }

    public func upsertRemoteFileTransfer(_ transfer: RemoteFileTransferRecord) {
        if let index = remoteFileTransfers.firstIndex(where: { $0.id == transfer.id }) { remoteFileTransfers[index] = transfer }
        else { remoteFileTransfers.insert(transfer, at: 0) }
        remoteFileTransfers = Array(remoteFileTransfers.prefix(500))
        persist()
    }

    public func addRemoteFileShare(_ share: RemoteFileShare) {
        remoteFileShares.removeAll { $0.id == share.id || $0.remotePath == share.remotePath }
        remoteFileShares.insert(share, at: 0)
        remoteFileShares = Array(remoteFileShares.prefix(250))
        persist()
    }

    public func removeRemoteFileShare(_ id: UUID) {
        remoteFileShares.removeAll { $0.id == id }
        persist()
    }

    public func updateNomadServer(_ configuration: NomadServerConfiguration) {
        nomadServer = NomadServerConfiguration(
            enabled: configuration.enabled,
            name: configuration.name,
            announceIntervalSeconds: configuration.announceIntervalSeconds
        )
        persist()
    }

    public func upsertHostedNomadPage(_ page: NomadHostedPage) {
        if let index = hostedNomadPages.firstIndex(where: { $0.id == page.id }) { hostedNomadPages[index] = page }
        else { hostedNomadPages.insert(page, at: 0) }
        hostedNomadPages = Array(hostedNomadPages.prefix(500))
        persist()
    }

    public func removeHostedNomadPage(_ id: UUID) {
        hostedNomadPages.removeAll { $0.id == id }
        persist()
    }

    public func addHostedNomadFile(_ file: NomadHostedFile) {
        hostedNomadFiles.removeAll { $0.id == file.id || $0.path == file.path }
        hostedNomadFiles.insert(file, at: 0)
        hostedNomadFiles = Array(hostedNomadFiles.prefix(250))
        persist()
    }

    public func removeHostedNomadFile(_ id: UUID) {
        hostedNomadFiles.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let encrypted = defaults.data(forKey: storageKey),
              let data = try? cipher.open(encrypted, context: cipherContext),
              let payload = try? decoder.decode(Payload.self, from: data) else { return }
        pages = Array(payload.pages.prefix(500))
        bookmarks = Array(payload.bookmarks.prefix(250))
        history = Array(payload.history.prefix(250))
        telephone = payload.telephone
        relayRooms = Array((payload.relayRooms ?? []).prefix(128))
        relayTranscript = Array((payload.relayTranscript ?? []).suffix(10_000))
        shellSessions = Array((payload.shellSessions ?? []).prefix(32))
        remoteToolRuns = Array((payload.remoteToolRuns ?? []).prefix(250))
        relayHub = payload.relayHub ?? HostedRelayHubConfiguration()
        remoteCopy = payload.remoteCopy ?? RemoteCopyConfiguration()
        remoteFileTransfers = Array((payload.remoteFileTransfers ?? []).prefix(500))
        remoteFileShares = Array((payload.remoteFileShares ?? []).prefix(250))
        nomadServer = payload.nomadServer ?? NomadServerConfiguration()
        hostedNomadPages = Array((payload.hostedNomadPages ?? []).prefix(500))
        hostedNomadFiles = Array((payload.hostedNomadFiles ?? []).prefix(250))
    }

    private func persist() {
        let payload = Payload(
            pages: pages, bookmarks: bookmarks, history: history, telephone: telephone,
            relayRooms: relayRooms, relayTranscript: relayTranscript,
            shellSessions: shellSessions, remoteToolRuns: remoteToolRuns,
            relayHub: relayHub, remoteCopy: remoteCopy,
            remoteFileTransfers: remoteFileTransfers, remoteFileShares: remoteFileShares,
            nomadServer: nomadServer, hostedNomadPages: hostedNomadPages,
            hostedNomadFiles: hostedNomadFiles
        )
        guard let data = try? encoder.encode(payload),
              let encrypted = try? cipher.seal(data, context: cipherContext) else { return }
        defaults.set(encrypted, forKey: storageKey)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
