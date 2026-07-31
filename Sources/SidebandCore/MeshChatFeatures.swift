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

// MARK: - Encrypted cross-device application-service continuity

public struct NomadBookmarkContinuityPreference: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(address.destinationHash):\(address.path)" }
    public let address: NomadPageAddress
    public let isBookmarked: Bool
    public let updatedAt: Date

    public init(address: NomadPageAddress, isBookmarked: Bool, updatedAt: Date = .now) {
        self.address = NomadPageAddress(destinationHash: address.destinationHash, path: address.path, query: [:])!
        self.isBookmarked = isBookmarked
        self.updatedAt = updatedAt
    }
}

public struct RelayRoomContinuityPreference: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(hubDestinationHash):\(room)" }
    public let hubDestinationHash: String
    public let room: String
    public let nickname: String
    public let isJoined: Bool
    public let updatedAt: Date

    public init(hubDestinationHash: String, room: String, nickname: String, isJoined: Bool, updatedAt: Date = .now) {
        self.hubDestinationHash = hubDestinationHash.lowercased()
        self.room = String(room.prefix(ReticulumRelayChatProtocol.maximumRoomBytes))
        self.nickname = String(nickname.prefix(ReticulumRelayChatProtocol.maximumNicknameBytes))
        self.isJoined = isJoined
        self.updatedAt = updatedAt
    }
}

public struct RelayRoomFavoritePreference: Codable, Hashable, Sendable, Identifiable {
    public let roomID: String
    public let isFavorite: Bool
    public let updatedAt: Date
    public var id: String { roomID }

    public init(roomID: String, isFavorite: Bool, updatedAt: Date = .now) {
        self.roomID = String(roomID.prefix(256))
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt
    }
}

public struct ServiceDirectoryFavoritePreference: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(destinationHash)" }
    public let destinationHash: String
    public let kind: ReticulumApplicationServiceKind
    public let name: String
    public let isFavorite: Bool
    public let updatedAt: Date

    public init(
        destinationHash: String,
        kind: ReticulumApplicationServiceKind,
        name: String,
        isFavorite: Bool,
        updatedAt: Date = .now
    ) {
        self.destinationHash = destinationHash.lowercased()
        self.kind = kind
        self.name = String(name.prefix(160))
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt
    }
}

public struct ApplicationServiceContinuitySnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var nomadBookmarks: [NomadBookmarkContinuityPreference]
    public var nomadHistory: [NomadPageVisit]
    public var nomadHistoryClearedAt: Date?
    public var relayMemberships: [RelayRoomContinuityPreference]
    public var relayFavorites: [RelayRoomFavoritePreference]
    public var serviceFavorites: [ServiceDirectoryFavoritePreference]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        nomadBookmarks: [NomadBookmarkContinuityPreference] = [],
        nomadHistory: [NomadPageVisit] = [],
        nomadHistoryClearedAt: Date? = nil,
        relayMemberships: [RelayRoomContinuityPreference] = [],
        relayFavorites: [RelayRoomFavoritePreference] = [],
        serviceFavorites: [ServiceDirectoryFavoritePreference] = []
    ) {
        self.schemaVersion = schemaVersion
        self.nomadBookmarks = Array(nomadBookmarks.prefix(250))
        self.nomadHistory = Array(nomadHistory.prefix(250))
        self.nomadHistoryClearedAt = nomadHistoryClearedAt
        self.relayMemberships = Array(relayMemberships.prefix(512))
        self.relayFavorites = Array(relayFavorites.prefix(512))
        self.serviceFavorites = Array(serviceFavorites.prefix(2_000))
    }
}

public extension ApplicationServiceContinuitySnapshot {
    func merging(_ other: ApplicationServiceContinuitySnapshot) -> ApplicationServiceContinuitySnapshot {
        func latest<Value: Identifiable>(
            _ values: [Value],
            timestamp: (Value) -> Date
        ) -> [Value] where Value.ID == String {
            var byID: [String: Value] = [:]
            for value in values where timestamp(value) >= timestamp(byID[value.id] ?? value) {
                byID[value.id] = value
            }
            return Array(byID.values)
        }
        let bookmarks = latest(nomadBookmarks + other.nomadBookmarks, timestamp: \.updatedAt)
            .sorted { $0.updatedAt > $1.updatedAt }
        let memberships = latest(relayMemberships + other.relayMemberships, timestamp: \.updatedAt)
            .sorted { $0.updatedAt > $1.updatedAt }
        let relayPreference = latest(relayFavorites + other.relayFavorites, timestamp: \.updatedAt)
            .sorted { $0.updatedAt > $1.updatedAt }
        let services = latest(serviceFavorites + other.serviceFavorites, timestamp: \.updatedAt)
            .sorted { $0.updatedAt > $1.updatedAt }
        var historyByLocation: [String: NomadPageVisit] = [:]
        let clearedAt = [nomadHistoryClearedAt, other.nomadHistoryClearedAt].compactMap { $0 }.max()
        for visit in nomadHistory + other.nomadHistory where visit.visitedAt > (clearedAt ?? .distantPast) {
            let safeAddress = NomadPageAddress(
                destinationHash: visit.address.destinationHash,
                path: visit.address.path,
                query: [:]
            )!
            let safe = NomadPageVisit(id: visit.id, address: safeAddress, title: visit.title, visitedAt: visit.visitedAt)
            let key = "\(safeAddress.destinationHash):\(safeAddress.path)"
            if safe.visitedAt > (historyByLocation[key]?.visitedAt ?? .distantPast) { historyByLocation[key] = safe }
        }
        return ApplicationServiceContinuitySnapshot(
            schemaVersion: max(schemaVersion, other.schemaVersion),
            nomadBookmarks: Array(bookmarks.prefix(250)),
            nomadHistory: Array(historyByLocation.values.sorted { $0.visitedAt > $1.visitedAt }.prefix(250)),
            nomadHistoryClearedAt: clearedAt,
            relayMemberships: Array(memberships.prefix(512)),
            relayFavorites: Array(relayPreference.prefix(512)),
            serviceFavorites: Array(services.prefix(2_000))
        )
    }
}

public enum MicronBlock: Identifiable, Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case separator
    case link(label: String, target: String)
    case submission(label: String, target: String, fields: [String])
    case input(MicronInputField)

    public var id: String {
        switch self {
        case .heading(let level, let text): "h\(level):\(text)"
        case .paragraph(let text): "p:\(text)"
        case .separator: "separator"
        case .link(let label, let target): "l:\(label):\(target)"
        case .submission(let label, let target, let fields): "s:\(label):\(target):\(fields.joined(separator: "|"))"
        case .input(let field): "i:\(field.id)"
        }
    }
}

public struct MicronInputField: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case text, secure, checkbox, radio }

    public var id: String { "\(kind.rawValue):\(name):\(value)" }
    public let kind: Kind
    public let name: String
    public let width: Int
    public let value: String
    public let label: String
    public let initialValue: String
    public let isInitiallySelected: Bool

    public init(
        kind: Kind,
        name: String,
        width: Int = 24,
        value: String = "",
        label: String = "",
        initialValue: String = "",
        isInitiallySelected: Bool = false
    ) {
        self.kind = kind
        self.name = String(name.prefix(128))
        self.width = min(256, max(1, width))
        self.value = String(value.prefix(4_096))
        self.label = String(label.prefix(512))
        self.initialValue = String(initialValue.prefix(4_096))
        self.isInitiallySelected = isInitiallySelected
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
            if let input = parseInput(line) {
                flush(); blocks.append(.input(input)); continue
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
        // Common Micron links: `[Label`destination:/path`field|field=value]
        guard let labelStart = line.firstIndex(of: "["),
              let separator = line[labelStart...].firstIndex(of: "`"),
              let end = line[separator...].lastIndex(of: "]"),
              separator < end else { return nil }
        let label = sanitized(line[line.index(after: labelStart)..<separator])
        let components = line[line.index(after: separator)..<end].split(
            separator: "`",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let target = String(components[0])
        guard !label.isEmpty, target.utf8.count <= 4_096 else { return nil }
        if components.count > 1 {
            let fields = components[1].split(separator: "|", omittingEmptySubsequences: true).map(String.init)
            guard fields.count <= 64, fields.allSatisfy({ $0.utf8.count <= 4_224 }) else { return nil }
            return .submission(label: label, target: target, fields: fields)
        }
        return .link(label: label, target: target)
    }

    private static func parseInput(_ line: String) -> MicronInputField? {
        guard let start = line.firstIndex(of: "<"),
              let separator = line[start...].firstIndex(of: "`"),
              let end = line[separator...].firstIndex(of: ">"),
              separator < end else { return nil }
        let specification = String(line[line.index(after: start)..<separator])
        let fieldData = sanitized(line[line.index(after: separator)..<end])
        let components = specification.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= 4 else { return nil }
        var flags = components.count > 1 ? components[0] : ""
        let name = components.count > 1 ? components[1] : components[0]
        guard !name.isEmpty, name.utf8.count <= 128 else { return nil }
        let kind: MicronInputField.Kind
        if flags.contains("^") { kind = .radio; flags.removeAll { $0 == "^" } }
        else if flags.contains("?") { kind = .checkbox; flags.removeAll { $0 == "?" } }
        else if flags.contains("!") { kind = .secure; flags.removeAll { $0 == "!" } }
        else { kind = .text }
        let width = Int(flags) ?? 24
        let value = components.count > 2 ? components[2] : ""
        let selected = components.count > 3 && components[3] == "*"
        return MicronInputField(
            kind: kind,
            name: name,
            width: width,
            value: kind == .checkbox || kind == .radio ? (value.isEmpty ? fieldData : value) : "",
            label: kind == .checkbox || kind == .radio ? fieldData : name,
            initialValue: kind == .text || kind == .secure ? fieldData : "",
            isInitiallySelected: selected
        )
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

public struct RelayRoomCommunityState: Codable, Hashable, Sendable {
    public let roomID: String
    public var isFavorite: Bool
    public var unreadCount: Int
    public var mentionCount: Int
    public var lastReadAt: Date?

    public init(
        roomID: String,
        isFavorite: Bool = false,
        unreadCount: Int = 0,
        mentionCount: Int = 0,
        lastReadAt: Date? = nil
    ) {
        self.roomID = String(roomID.prefix(256))
        self.isFavorite = isFavorite
        self.unreadCount = min(100_000, max(0, unreadCount))
        self.mentionCount = min(self.unreadCount, max(0, mentionCount))
        self.lastReadAt = lastReadAt
    }
}

public struct RelayRoomInvitation: Codable, Hashable, Sendable {
    public let hubDestinationHash: String
    public let room: String
    public let accessKey: String?

    public init?(hubDestinationHash: String, room: String, accessKey: String? = nil) {
        let hub = hubDestinationHash.lowercased()
        let normalizedRoom = room.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
        guard DestinationHash.isValid(hub), !normalizedRoom.isEmpty,
              normalizedRoom.utf8.count <= ReticulumRelayChatProtocol.maximumRoomBytes else { return nil }
        self.hubDestinationHash = hub
        self.room = normalizedRoom
        let normalizedKey = accessKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKey = normalizedKey?.isEmpty == false ? String(normalizedKey!.prefix(128)) : nil
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("rrc://"),
              let components = URLComponents(string: trimmed),
              let hub = components.host else { return nil }
        let room = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/#"))
        let key = components.queryItems?.first(where: { $0.name == "key" })?.value
        self.init(hubDestinationHash: hub, room: room, accessKey: key)
    }

    public var string: String {
        var components = URLComponents()
        components.scheme = "rrc"
        components.host = hubDestinationHash
        components.path = "/\(room)"
        if let accessKey { components.queryItems = [URLQueryItem(name: "key", value: accessKey)] }
        return components.string ?? "rrc://\(hubDestinationHash)/\(room)"
    }
}

public enum ReticulumApplicationServiceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case nomad
    case relay
    case shell
    case execution
    case copy

    public var id: Self { self }
    public var title: String {
        switch self {
        case .nomad: "Nomad page node"
        case .relay: "Relay chat hub"
        case .shell: "Remote shell"
        case .execution: "Remote execution"
        case .copy: "File transfer"
        }
    }
    public var destinationName: String {
        switch self {
        case .nomad: NomadNetworkProtocol.destinationName
        case .relay: ReticulumRelayChatProtocol.destinationName
        case .shell: ReticulumShellProtocol.destinationName
        case .execution: ReticulumRemoteExecutionProtocol.destinationName
        case .copy: ReticulumCopyProtocol.destinationName
        }
    }
    public var systemImage: String {
        switch self {
        case .nomad: "doc.richtext"
        case .relay: "person.3"
        case .shell: "terminal"
        case .execution: "play.rectangle"
        case .copy: "folder.badge.gearshape"
        }
    }
}

public struct ReticulumApplicationService: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(destinationHash)" }
    public let destinationHash: String
    public let kind: ReticulumApplicationServiceKind
    public var name: String
    public var detail: String
    public var hops: UInt8
    public var lastSeen: Date
    public var isValidated: Bool
    public var isFavorite: Bool
    public var lastCheckedAt: Date?
    public var lastUsedAt: Date?
    public var routeLatencyMilliseconds: Int?
    public var isReachable: Bool

    public init(
        destinationHash: String,
        kind: ReticulumApplicationServiceKind,
        name: String = "",
        detail: String = "",
        hops: UInt8,
        lastSeen: Date = .now,
        isValidated: Bool,
        isFavorite: Bool = false,
        lastCheckedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        routeLatencyMilliseconds: Int? = nil,
        isReachable: Bool = true
    ) {
        self.destinationHash = destinationHash.lowercased()
        self.kind = kind
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.detail = String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.hops = hops
        self.lastSeen = lastSeen
        self.isValidated = isValidated
        self.isFavorite = isFavorite
        self.lastCheckedAt = lastCheckedAt
        self.lastUsedAt = lastUsedAt
        self.routeLatencyMilliseconds = routeLatencyMilliseconds.map { min(120_000, max(0, $0)) }
        self.isReachable = isReachable
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
    public private(set) var relayRoomStates: [String: RelayRoomCommunityState] = [:]
    public private(set) var serviceDirectory: [ReticulumApplicationService] = []
    public private(set) var shellSessions: [RemoteShellSessionRecord] = []
    public private(set) var remoteToolRuns: [RemoteToolRun] = []
    public private(set) var relayHub = HostedRelayHubConfiguration()
    public private(set) var remoteCopy = RemoteCopyConfiguration()
    public private(set) var remoteFileTransfers: [RemoteFileTransferRecord] = []
    public private(set) var remoteFileShares: [RemoteFileShare] = []
    public private(set) var nomadServer = NomadServerConfiguration()
    public private(set) var hostedNomadPages: [NomadHostedPage] = []
    public private(set) var hostedNomadFiles: [NomadHostedFile] = []
    public private(set) var serviceAuthorizations: [ApplicationServiceAuthorization] = []
    public private(set) var acceptanceReports: [ApplicationServiceAcceptanceReport] = []

    private struct Payload: Codable {
        var pages: [NomadPageDocument]
        var bookmarks: [NomadPageAddress]
        var history: [NomadPageVisit]
        var telephone: SidebandTelephonePreferences
        var relayRooms: [RelayChatRoom]?
        var relayTranscript: [RelayChatTranscriptEntry]?
        var relayRoomStates: [String: RelayRoomCommunityState]?
        var serviceDirectory: [ReticulumApplicationService]?
        var shellSessions: [RemoteShellSessionRecord]?
        var remoteToolRuns: [RemoteToolRun]?
        var relayHub: HostedRelayHubConfiguration?
        var remoteCopy: RemoteCopyConfiguration?
        var remoteFileTransfers: [RemoteFileTransferRecord]?
        var remoteFileShares: [RemoteFileShare]?
        var nomadServer: NomadServerConfiguration?
        var hostedNomadPages: [NomadHostedPage]?
        var hostedNomadFiles: [NomadHostedFile]?
        var serviceAuthorizations: [ApplicationServiceAuthorization]?
        var acceptanceReports: [ApplicationServiceAcceptanceReport]?
        var nomadHistoryClearedAt: Date?
        var continuityClocks: [String: Date]?
        var nomadBookmarkTombstones: [String: NomadBookmarkContinuityPreference]?
        var relayMembershipTombstones: [String: RelayRoomContinuityPreference]?
        var relayFavoriteTombstones: [String: RelayRoomFavoritePreference]?
        var serviceFavoriteTombstones: [String: ServiceDirectoryFavoritePreference]?
    }

    private let cipher: LocalDataCipher
    private let defaults: UserDefaults
    private let onContinuityChange: (@MainActor () -> Void)?
    private let storageKey = "meshChatApplicationFeatures.v1"
    private let cipherContext = "meshchat-application-features-v1"
    private var continuityClocks: [String: Date] = [:]
    private var nomadHistoryClearedAt: Date?
    private var nomadBookmarkTombstones: [String: NomadBookmarkContinuityPreference] = [:]
    private var relayMembershipTombstones: [String: RelayRoomContinuityPreference] = [:]
    private var relayFavoriteTombstones: [String: RelayRoomFavoritePreference] = [:]
    private var serviceFavoriteTombstones: [String: ServiceDirectoryFavoritePreference] = [:]

    init(
        cipher: LocalDataCipher,
        defaults: UserDefaults = .standard,
        onContinuityChange: (@MainActor () -> Void)? = nil
    ) {
        self.cipher = cipher
        self.defaults = defaults
        self.onContinuityChange = onContinuityChange
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
        continuityChanged()
    }

    public func toggleBookmark(_ address: NomadPageAddress) {
        let safeAddress = Self.continuityAddress(address)
        let key = "bookmark:\(safeAddress.destinationHash):\(safeAddress.path)"
        let isRemoving: Bool
        if let index = bookmarks.firstIndex(where: { Self.continuityAddress($0) == safeAddress }) {
            bookmarks.remove(at: index)
            isRemoving = true
        } else {
            bookmarks.insert(safeAddress, at: 0)
            isRemoving = false
        }
        let preference = NomadBookmarkContinuityPreference(address: safeAddress, isBookmarked: !isRemoving)
        continuityClocks[key] = preference.updatedAt
        if isRemoving { nomadBookmarkTombstones[preference.id] = preference }
        else { nomadBookmarkTombstones.removeValue(forKey: preference.id) }
        bookmarks = Array(bookmarks.prefix(250))
        persist()
        continuityChanged()
    }

    public func clearHistory() {
        history.removeAll()
        nomadHistoryClearedAt = .now
        persist()
        continuityChanged()
    }

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
        relayRooms = Array(relayRooms.prefix(128))
        continuityClocks["room:\(room.id)"] = .now
        relayMembershipTombstones.removeValue(forKey: room.id)
        persist()
        continuityChanged()
    }

    public func removeRelayRoom(_ id: String) {
        guard let room = relayRooms.first(where: { $0.id == id }) else { return }
        let preference = RelayRoomContinuityPreference(
            hubDestinationHash: room.hubDestinationHash,
            room: room.name,
            nickname: room.nickname,
            isJoined: false
        )
        relayRooms.removeAll { $0.id == id }
        relayMembershipTombstones[id] = preference
        continuityClocks["room:\(id)"] = preference.updatedAt
        persist()
        continuityChanged()
    }

    public func recordRelayMessage(_ message: ReticulumRelayChatProtocol.Message, hubDestinationHash: String, outgoing: Bool) {
        let entry = RelayChatTranscriptEntry(message: message, hubDestinationHash: hubDestinationHash, isOutgoing: outgoing)
        guard !relayTranscript.contains(where: { $0.id == entry.id }) else { return }
        relayTranscript.append(entry)
        relayTranscript = Array(relayTranscript.suffix(10_000))
        if !outgoing, let room = relayRooms.first(where: { $0.id == entry.roomID }) {
            var state = relayRoomStates[entry.roomID] ?? RelayRoomCommunityState(roomID: entry.roomID)
            state.unreadCount = min(100_000, state.unreadCount + 1)
            if ReticulumRelayChatProtocol.mentions(in: entry.body, nickname: room.nickname) {
                state.mentionCount = min(state.unreadCount, state.mentionCount + 1)
            }
            relayRoomStates[entry.roomID] = state
        }
        persist()
    }

    public func setRelayRoomFavorite(_ roomID: String, favorite: Bool) {
        var state = relayRoomStates[roomID] ?? RelayRoomCommunityState(roomID: roomID)
        state.isFavorite = favorite
        relayRoomStates[roomID] = state
        let preference = RelayRoomFavoritePreference(roomID: roomID, isFavorite: favorite)
        continuityClocks["relay-favorite:\(roomID)"] = preference.updatedAt
        if favorite { relayFavoriteTombstones.removeValue(forKey: roomID) }
        else { relayFavoriteTombstones[roomID] = preference }
        persist()
        continuityChanged()
    }

    public func markRelayRoomRead(_ roomID: String) {
        var state = relayRoomStates[roomID] ?? RelayRoomCommunityState(roomID: roomID)
        state.unreadCount = 0
        state.mentionCount = 0
        state.lastReadAt = .now
        relayRoomStates[roomID] = state
        persist()
    }

    public func observeService(_ service: ReticulumApplicationService) {
        if let index = serviceDirectory.firstIndex(where: { $0.id == service.id }) {
            let favorite = serviceDirectory[index].isFavorite
            let lastCheckedAt = serviceDirectory[index].lastCheckedAt
            let lastUsedAt = serviceDirectory[index].lastUsedAt
            let latency = serviceDirectory[index].routeLatencyMilliseconds
            serviceDirectory[index] = service
            serviceDirectory[index].isFavorite = favorite
            serviceDirectory[index].lastCheckedAt = lastCheckedAt
            serviceDirectory[index].lastUsedAt = lastUsedAt
            serviceDirectory[index].routeLatencyMilliseconds = latency
        } else {
            serviceDirectory.append(service)
        }
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        serviceDirectory = Array(
            serviceDirectory
                .filter { $0.isFavorite || $0.lastSeen >= cutoff }
                .sorted {
                    if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                    return $0.lastSeen > $1.lastSeen
                }
                .prefix(2_000)
        )
        persist()
    }

    public func setServiceFavorite(_ id: String, favorite: Bool) {
        guard let index = serviceDirectory.firstIndex(where: { $0.id == id }) else { return }
        serviceDirectory[index].isFavorite = favorite
        let service = serviceDirectory[index]
        let preference = ServiceDirectoryFavoritePreference(
            destinationHash: service.destinationHash,
            kind: service.kind,
            name: service.name,
            isFavorite: favorite
        )
        continuityClocks["service-favorite:\(id)"] = preference.updatedAt
        if favorite { serviceFavoriteTombstones.removeValue(forKey: id) }
        else { serviceFavoriteTombstones[id] = preference }
        persist()
        continuityChanged()
    }

    public func continuitySnapshot() -> ApplicationServiceContinuitySnapshot {
        let safeBookmarks = bookmarks.map { address in
            let safe = Self.continuityAddress(address)
            return NomadBookmarkContinuityPreference(
                address: safe,
                isBookmarked: true,
                updatedAt: continuityClocks["bookmark:\(safe.destinationHash):\(safe.path)"] ?? .distantPast
            )
        } + nomadBookmarkTombstones.values
        let safeHistory = history.map {
            NomadPageVisit(id: $0.id, address: Self.continuityAddress($0.address), title: $0.title, visitedAt: $0.visitedAt)
        }
        let memberships = relayRooms.map { room in
            RelayRoomContinuityPreference(
                hubDestinationHash: room.hubDestinationHash,
                room: room.name,
                nickname: room.nickname,
                isJoined: true,
                updatedAt: continuityClocks["room:\(room.id)"] ?? room.joinedAt
            )
        } + relayMembershipTombstones.values
        let favorites = relayRoomStates.compactMap { roomID, state -> RelayRoomFavoritePreference? in
            guard state.isFavorite else { return nil }
            return RelayRoomFavoritePreference(
                roomID: roomID,
                isFavorite: true,
                updatedAt: continuityClocks["relay-favorite:\(roomID)"] ?? state.lastReadAt ?? .distantPast
            )
        } + relayFavoriteTombstones.values
        let servicePreferences = serviceDirectory.compactMap { service -> ServiceDirectoryFavoritePreference? in
            guard service.isFavorite else { return nil }
            return ServiceDirectoryFavoritePreference(
                destinationHash: service.destinationHash,
                kind: service.kind,
                name: service.name,
                isFavorite: true,
                updatedAt: continuityClocks["service-favorite:\(service.id)"] ?? service.lastUsedAt ?? service.lastSeen
            )
        } + serviceFavoriteTombstones.values
        return ApplicationServiceContinuitySnapshot(
            nomadBookmarks: safeBookmarks,
            nomadHistory: safeHistory,
            nomadHistoryClearedAt: nomadHistoryClearedAt,
            relayMemberships: memberships.sorted { $0.updatedAt > $1.updatedAt },
            relayFavorites: favorites.sorted { $0.updatedAt > $1.updatedAt },
            serviceFavorites: servicePreferences.sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    public func mergeContinuity(_ incoming: ApplicationServiceContinuitySnapshot) {
        guard incoming.schemaVersion <= ApplicationServiceContinuitySnapshot.currentSchemaVersion else { return }
        for preference in incoming.nomadBookmarks {
            let address = Self.continuityAddress(preference.address)
            let key = "bookmark:\(address.destinationHash):\(address.path)"
            guard preference.updatedAt > (continuityClocks[key] ?? .distantPast) else { continue }
            continuityClocks[key] = preference.updatedAt
            if preference.isBookmarked {
                if !bookmarks.contains(where: { Self.continuityAddress($0) == address }) { bookmarks.append(address) }
                nomadBookmarkTombstones.removeValue(forKey: preference.id)
            } else {
                bookmarks.removeAll { Self.continuityAddress($0) == address }
                nomadBookmarkTombstones[preference.id] = preference
            }
        }
        bookmarks = Array(bookmarks.prefix(250))
        let clearedAt = [nomadHistoryClearedAt, incoming.nomadHistoryClearedAt].compactMap { $0 }.max()
        nomadHistoryClearedAt = clearedAt
        var visitsByLocation: [String: NomadPageVisit] = [:]
        for visit in history + incoming.nomadHistory where visit.visitedAt > (clearedAt ?? .distantPast) {
            let address = Self.continuityAddress(visit.address)
            let key = "\(address.destinationHash):\(address.path)"
            let safe = NomadPageVisit(id: visit.id, address: address, title: visit.title, visitedAt: visit.visitedAt)
            if safe.visitedAt > (visitsByLocation[key]?.visitedAt ?? .distantPast) { visitsByLocation[key] = safe }
        }
        history = Array(visitsByLocation.values.sorted { $0.visitedAt > $1.visitedAt }.prefix(250))

        for preference in incoming.relayMemberships {
            guard DestinationHash.isValid(preference.hubDestinationHash), !preference.room.isEmpty else { continue }
            let key = "room:\(preference.id)"
            guard preference.updatedAt > (continuityClocks[key] ?? .distantPast) else { continue }
            continuityClocks[key] = preference.updatedAt
            if preference.isJoined {
                upsertRelayRoomWithoutContinuitySignal(
                    RelayChatRoom(
                        hubDestinationHash: preference.hubDestinationHash,
                        name: preference.room,
                        nickname: preference.nickname,
                        joinedAt: preference.updatedAt
                    )
                )
                relayMembershipTombstones.removeValue(forKey: preference.id)
            } else {
                relayRooms.removeAll { $0.id == preference.id }
                relayMembershipTombstones[preference.id] = preference
            }
        }
        for preference in incoming.relayFavorites {
            let key = "relay-favorite:\(preference.roomID)"
            guard preference.updatedAt > (continuityClocks[key] ?? .distantPast) else { continue }
            continuityClocks[key] = preference.updatedAt
            var state = relayRoomStates[preference.roomID] ?? RelayRoomCommunityState(roomID: preference.roomID)
            state.isFavorite = preference.isFavorite
            relayRoomStates[preference.roomID] = state
            if preference.isFavorite { relayFavoriteTombstones.removeValue(forKey: preference.roomID) }
            else { relayFavoriteTombstones[preference.roomID] = preference }
        }
        for preference in incoming.serviceFavorites {
            guard DestinationHash.isValid(preference.destinationHash) else { continue }
            let key = "service-favorite:\(preference.id)"
            guard preference.updatedAt > (continuityClocks[key] ?? .distantPast) else { continue }
            continuityClocks[key] = preference.updatedAt
            if let index = serviceDirectory.firstIndex(where: { $0.id == preference.id }) {
                serviceDirectory[index].isFavorite = preference.isFavorite
            } else if preference.isFavorite {
                serviceDirectory.append(
                    ReticulumApplicationService(
                        destinationHash: preference.destinationHash,
                        kind: preference.kind,
                        name: preference.name,
                        hops: 0,
                        lastSeen: preference.updatedAt,
                        isValidated: false,
                        isFavorite: true,
                        isReachable: false
                    )
                )
            }
            if preference.isFavorite { serviceFavoriteTombstones.removeValue(forKey: preference.id) }
            else { serviceFavoriteTombstones[preference.id] = preference }
        }
        persist()
    }

    public func markServiceUsed(_ id: String) {
        guard let index = serviceDirectory.firstIndex(where: { $0.id == id }) else { return }
        serviceDirectory[index].lastUsedAt = .now
        persist()
    }

    public func updateServiceHealth(
        _ id: String,
        reachable: Bool,
        latencyMilliseconds: Int?,
        checkedAt: Date = .now
    ) {
        guard let index = serviceDirectory.firstIndex(where: { $0.id == id }) else { return }
        serviceDirectory[index].isReachable = reachable
        serviceDirectory[index].routeLatencyMilliseconds = latencyMilliseconds.map { min(120_000, max(0, $0)) }
        serviceDirectory[index].lastCheckedAt = checkedAt
        persist()
    }

    public func isAuthorized(_ permission: ApplicationServicePermission, destinationHash: String) -> Bool {
        serviceAuthorizations.first {
            $0.destinationHash == destinationHash.lowercased()
        }?.permissions.contains(permission) == true
    }

    public func setAuthorization(
        _ permission: ApplicationServicePermission,
        destinationHash: String,
        allowed: Bool
    ) {
        let destination = destinationHash.lowercased()
        guard DestinationHash.isValid(destination) else { return }
        var authorization = serviceAuthorizations.first { $0.destinationHash == destination }
            ?? ApplicationServiceAuthorization(destinationHash: destination, permissions: [])
        if allowed { authorization.permissions.insert(permission) }
        else { authorization.permissions.remove(permission) }
        authorization.updatedAt = .now
        serviceAuthorizations.removeAll { $0.destinationHash == destination }
        if !authorization.permissions.isEmpty { serviceAuthorizations.append(authorization) }
        persist()
    }

    public func revokeAuthorizations(destinationHash: String) {
        serviceAuthorizations.removeAll { $0.destinationHash == destinationHash.lowercased() }
        persist()
    }

    public func recordAcceptanceReport(_ report: ApplicationServiceAcceptanceReport) {
        acceptanceReports.insert(report, at: 0)
        acceptanceReports = Array(acceptanceReports.prefix(100))
        persist()
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
        relayRoomStates = payload.relayRoomStates ?? [:]
        serviceDirectory = Array((payload.serviceDirectory ?? []).prefix(2_000))
        shellSessions = Array((payload.shellSessions ?? []).prefix(32))
        remoteToolRuns = Array((payload.remoteToolRuns ?? []).prefix(250))
        relayHub = payload.relayHub ?? HostedRelayHubConfiguration()
        remoteCopy = payload.remoteCopy ?? RemoteCopyConfiguration()
        remoteFileTransfers = Array((payload.remoteFileTransfers ?? []).prefix(500))
        remoteFileShares = Array((payload.remoteFileShares ?? []).prefix(250))
        nomadServer = payload.nomadServer ?? NomadServerConfiguration()
        hostedNomadPages = Array((payload.hostedNomadPages ?? []).prefix(500))
        hostedNomadFiles = Array((payload.hostedNomadFiles ?? []).prefix(250))
        serviceAuthorizations = Array((payload.serviceAuthorizations ?? []).prefix(2_000))
        acceptanceReports = Array((payload.acceptanceReports ?? []).prefix(100))
        nomadHistoryClearedAt = payload.nomadHistoryClearedAt
        continuityClocks = payload.continuityClocks ?? [:]
        nomadBookmarkTombstones = payload.nomadBookmarkTombstones ?? [:]
        relayMembershipTombstones = payload.relayMembershipTombstones ?? [:]
        relayFavoriteTombstones = payload.relayFavoriteTombstones ?? [:]
        serviceFavoriteTombstones = payload.serviceFavoriteTombstones ?? [:]
    }

    private func persist() {
        let payload = Payload(
            pages: pages, bookmarks: bookmarks, history: history, telephone: telephone,
            relayRooms: relayRooms, relayTranscript: relayTranscript,
            relayRoomStates: relayRoomStates, serviceDirectory: serviceDirectory,
            shellSessions: shellSessions, remoteToolRuns: remoteToolRuns,
            relayHub: relayHub, remoteCopy: remoteCopy,
            remoteFileTransfers: remoteFileTransfers, remoteFileShares: remoteFileShares,
            nomadServer: nomadServer, hostedNomadPages: hostedNomadPages,
            hostedNomadFiles: hostedNomadFiles,
            serviceAuthorizations: serviceAuthorizations,
            acceptanceReports: acceptanceReports,
            nomadHistoryClearedAt: nomadHistoryClearedAt,
            continuityClocks: continuityClocks,
            nomadBookmarkTombstones: nomadBookmarkTombstones,
            relayMembershipTombstones: relayMembershipTombstones,
            relayFavoriteTombstones: relayFavoriteTombstones,
            serviceFavoriteTombstones: serviceFavoriteTombstones
        )
        guard let data = try? encoder.encode(payload),
              let encrypted = try? cipher.seal(data, context: cipherContext) else { return }
        defaults.set(encrypted, forKey: storageKey)
    }

    private func continuityChanged() {
        onContinuityChange?()
    }

    private func upsertRelayRoomWithoutContinuitySignal(_ room: RelayChatRoom) {
        if let index = relayRooms.firstIndex(where: { $0.id == room.id }) { relayRooms[index] = room }
        else { relayRooms.insert(room, at: 0) }
        relayRooms = Array(relayRooms.prefix(128))
    }

    private static func continuityAddress(_ address: NomadPageAddress) -> NomadPageAddress {
        NomadPageAddress(destinationHash: address.destinationHash, path: address.path, query: [:])!
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
