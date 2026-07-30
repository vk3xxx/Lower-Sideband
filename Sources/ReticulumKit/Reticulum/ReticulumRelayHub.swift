import Foundation

/// Deterministic, transport-independent RRC hub state. The application owns
/// Reticulum links and feeds authenticated peers into this router.
public struct ReticulumRelayHub: Sendable {
    public struct RoomPolicy: Equatable, Sendable {
        public var name: String
        public var topic: String
        public var accessKey: String?
        public var isModerated: Bool
        public var voicedIdentityHashes: Set<Data>

        public init(
            name: String,
            topic: String = "",
            accessKey: String? = nil,
            isModerated: Bool = false,
            voicedIdentityHashes: Set<Data> = []
        ) throws {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty,
                  normalized.utf8.count <= ReticulumRelayChatProtocol.maximumRoomBytes,
                  topic.utf8.count <= 512,
                  accessKey?.utf8.count ?? 0 <= 128,
                  voicedIdentityHashes.allSatisfy({ $0.count == 16 }) else {
                throw HubError.invalidConfiguration
            }
            self.name = normalized
            self.topic = topic
            self.accessKey = accessKey?.isEmpty == false ? accessKey : nil
            self.isModerated = isModerated
            self.voicedIdentityHashes = voicedIdentityHashes
        }
    }

    public struct Configuration: Equatable, Sendable {
        public var name: String
        public var greeting: String
        public var rooms: [RoomPolicy]
        public var bannedIdentityHashes: Set<Data>
        public var ratePerMinute: Int

        public init(
            name: String,
            greeting: String = "",
            rooms: [RoomPolicy],
            bannedIdentityHashes: Set<Data> = [],
            ratePerMinute: Int = ReticulumRelayChatProtocol.defaultRatePerMinute
        ) throws {
            guard !name.isEmpty, name.utf8.count <= 80, greeting.utf8.count <= 512,
                  !rooms.isEmpty, rooms.count <= 128,
                  Set(rooms.map(\.name)).count == rooms.count,
                  bannedIdentityHashes.allSatisfy({ $0.count == 16 }),
                  (1...10_000).contains(ratePerMinute) else {
                throw HubError.invalidConfiguration
            }
            self.name = name
            self.greeting = greeting
            self.rooms = rooms
            self.bannedIdentityHashes = bannedIdentityHashes
            self.ratePerMinute = ratePerMinute
        }
    }

    public struct Member: Equatable, Sendable {
        public let linkID: String
        public let identityHash: Data
        public var nickname: String
        public var rooms: Set<String>
        public let connectedAt: Date
    }

    public struct Outbound: Equatable, Sendable {
        public let linkID: String
        public let message: ReticulumRelayChatProtocol.Message
    }

    private struct Session: Sendable {
        var identityHash: Data?
        var nickname = ""
        var rooms: Set<String> = []
        var welcomed = false
        var tokens: Double
        var lastRefill: Date
        let connectedAt: Date
    }

    public private(set) var configuration: Configuration
    public let hubIdentityHash: Data
    private var sessions: [String: Session] = [:]

    public init(configuration: Configuration, hubIdentityHash: Data) throws {
        guard hubIdentityHash.count == 16 else { throw HubError.invalidConfiguration }
        self.configuration = configuration
        self.hubIdentityHash = hubIdentityHash
    }

    public mutating func update(configuration: Configuration) {
        self.configuration = configuration
        let permitted = Set(configuration.rooms.map(\.name))
        for key in sessions.keys {
            guard var session = sessions[key] else { continue }
            session.rooms.formIntersection(permitted)
            sessions[key] = session
        }
    }

    public mutating func connect(linkID: String, at date: Date = .now) {
        guard sessions[linkID] == nil else { return }
        sessions[linkID] = Session(
            tokens: Double(configuration.ratePerMinute),
            lastRefill: date,
            connectedAt: date
        )
    }

    public mutating func identify(linkID: String, identityHash: Data) throws {
        guard identityHash.count == 16, sessions[linkID] != nil else { throw HubError.unknownSession }
        guard !configuration.bannedIdentityHashes.contains(identityHash) else {
            sessions.removeValue(forKey: linkID)
            throw HubError.banned
        }
        sessions[linkID]?.identityHash = identityHash
    }

    public mutating func disconnect(linkID: String) -> [Outbound] {
        guard let session = sessions.removeValue(forKey: linkID), let peer = session.identityHash else { return [] }
        return session.rooms.flatMap { room in
            fanout(
                excluding: linkID,
                room: room,
                message: try? ReticulumRelayChatProtocol.Message(
                    type: .parted,
                    source: hubIdentityHash,
                    room: room,
                    body: .array([.bytes(peer)]),
                    nickname: session.nickname.isEmpty ? nil : session.nickname
                )
            )
        }
    }

    public var members: [Member] {
        sessions.compactMap { linkID, session in
            guard let identityHash = session.identityHash else { return nil }
            return Member(
                linkID: linkID,
                identityHash: identityHash,
                nickname: session.nickname,
                rooms: session.rooms,
                connectedAt: session.connectedAt
            )
        }.sorted { $0.connectedAt < $1.connectedAt }
    }

    public mutating func receive(
        _ message: ReticulumRelayChatProtocol.Message,
        on linkID: String,
        at date: Date = .now
    ) -> [Outbound] {
        guard var session = sessions[linkID] else { return [] }
        if message.type == .ping {
            return single(
                linkID,
                type: .pong,
                body: message.body
            )
        }
        guard let peer = session.identityHash else { return error(linkID, "identity required") }
        guard !configuration.bannedIdentityHashes.contains(peer) else {
            sessions.removeValue(forKey: linkID)
            return error(linkID, "banned")
        }
        if message.type == .hello {
            session.nickname = normalizedNickname(message.nickname) ?? session.nickname
            session.welcomed = true
            sessions[linkID] = session
            var output = single(linkID, type: .welcome, body: welcomeBody)
            if !configuration.greeting.isEmpty {
                output += single(linkID, type: .notice, body: .text(configuration.greeting))
            }
            return output
        }
        guard session.welcomed else { return error(linkID, "HELLO required") }
        guard consumeToken(&session, at: date) else {
            sessions[linkID] = session
            return error(linkID, "rate limited")
        }
        sessions[linkID] = session
        switch message.type {
        case .join:
            return join(message, linkID: linkID, peer: peer)
        case .part:
            return part(message, linkID: linkID, peer: peer)
        case .message, .notice, .action:
            return relay(message, linkID: linkID, peer: peer)
        default:
            return []
        }
    }

    private mutating func join(
        _ message: ReticulumRelayChatProtocol.Message,
        linkID: String,
        peer: Data
    ) -> [Outbound] {
        guard let roomName = message.room?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let room = configuration.rooms.first(where: { $0.name == roomName }),
              var session = sessions[linkID] else {
            return error(linkID, "no such room")
        }
        if let key = room.accessKey {
            guard case .text(let supplied) = message.body, constantTimeEqual(supplied, key) else {
                return error(linkID, "bad key (+k)", room: roomName)
            }
        }
        guard session.rooms.count < ReticulumRelayChatProtocol.maximumRooms else {
            return error(linkID, "too many rooms", room: roomName)
        }
        session.nickname = normalizedNickname(message.nickname) ?? session.nickname
        let alreadyJoined = session.rooms.contains(roomName)
        session.rooms.insert(roomName)
        sessions[linkID] = session

        var output: [Outbound] = []
        if !alreadyJoined {
            let joined = try? ReticulumRelayChatProtocol.Message(
                type: .joined,
                source: hubIdentityHash,
                room: roomName,
                body: .array([.bytes(peer)]),
                nickname: session.nickname.isEmpty ? nil : session.nickname
            )
            output += fanout(excluding: linkID, room: roomName, message: joined)
        }
        let memberHashes = sessions.values.compactMap { candidate -> CanonicalCBORValue? in
            guard candidate.rooms.contains(roomName), let identity = candidate.identityHash else { return nil }
            return .bytes(identity)
        }
        if let response = try? ReticulumRelayChatProtocol.Message(
            type: .joined,
            source: hubIdentityHash,
            room: roomName,
            body: .array(memberHashes)
        ) {
            output.append(Outbound(linkID: linkID, message: response))
        }
        let description = "room \(roomName): registered; topic=\(room.topic.isEmpty ? "(none)" : room.topic)"
        output += single(linkID, type: .notice, room: roomName, body: .text(description))
        return output
    }

    private mutating func part(
        _ message: ReticulumRelayChatProtocol.Message,
        linkID: String,
        peer: Data
    ) -> [Outbound] {
        guard let room = message.room?.lowercased(), var session = sessions[linkID],
              session.rooms.remove(room) != nil else {
            return error(linkID, "not in room", room: message.room)
        }
        sessions[linkID] = session
        let parted = try? ReticulumRelayChatProtocol.Message(
            type: .parted,
            source: hubIdentityHash,
            room: room,
            body: .array([.bytes(peer)]),
            nickname: session.nickname.isEmpty ? nil : session.nickname
        )
        var output = fanout(excluding: nil, room: room, message: parted)
        if output.isEmpty, let parted { output = [Outbound(linkID: linkID, message: parted)] }
        return output
    }

    private mutating func relay(
        _ message: ReticulumRelayChatProtocol.Message,
        linkID: String,
        peer: Data
    ) -> [Outbound] {
        guard let roomName = message.room?.lowercased(),
              let policy = configuration.rooms.first(where: { $0.name == roomName }),
              let session = sessions[linkID],
              session.rooms.contains(roomName) else {
            return error(linkID, "not in room", room: message.room)
        }
        if policy.isModerated && !policy.voicedIdentityHashes.contains(peer) {
            return error(linkID, "room is moderated (+m)", room: roomName)
        }
        guard let forwarded = try? ReticulumRelayChatProtocol.Message(
            type: message.type,
            messageID: message.messageID,
            timestampMilliseconds: message.timestampMilliseconds,
            source: peer,
            room: roomName,
            body: message.body,
            nickname: session.nickname.isEmpty ? message.nickname : session.nickname
        ) else { return error(linkID, "invalid message", room: roomName) }
        return fanout(excluding: nil, room: roomName, message: forwarded)
    }

    private var welcomeBody: CanonicalCBORValue {
        .map([
            .unsigned(0): .text(configuration.name),
            .unsigned(1): .text("1"),
            .unsigned(2): .map([.unsigned(1): .bool(true)]),
            .unsigned(3): .map([
                .unsigned(0): .unsigned(UInt64(ReticulumRelayChatProtocol.maximumNicknameBytes)),
                .unsigned(1): .unsigned(UInt64(ReticulumRelayChatProtocol.maximumRoomBytes)),
                .unsigned(2): .unsigned(UInt64(ReticulumRelayChatProtocol.maximumMessageBytes)),
                .unsigned(3): .unsigned(UInt64(ReticulumRelayChatProtocol.maximumRooms)),
                .unsigned(4): .unsigned(UInt64(configuration.ratePerMinute))
            ])
        ])
    }

    private func fanout(
        excluding excludedLinkID: String?,
        room: String,
        message: ReticulumRelayChatProtocol.Message?
    ) -> [Outbound] {
        guard let message else { return [] }
        return sessions.compactMap { linkID, session in
            guard linkID != excludedLinkID, session.rooms.contains(room) else { return nil }
            return Outbound(linkID: linkID, message: message)
        }
    }

    private func single(
        _ linkID: String,
        type: ReticulumRelayChatProtocol.MessageType,
        room: String? = nil,
        body: CanonicalCBORValue? = nil
    ) -> [Outbound] {
        guard let message = try? ReticulumRelayChatProtocol.Message(
            type: type,
            source: hubIdentityHash,
            room: room,
            body: body
        ) else { return [] }
        return [Outbound(linkID: linkID, message: message)]
    }

    private func error(_ linkID: String, _ text: String, room: String? = nil) -> [Outbound] {
        single(linkID, type: .error, room: room, body: .text(text))
    }

    private func normalizedNickname(_ nickname: String?) -> String? {
        guard let nickname else { return nil }
        let normalized = nickname.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(ReticulumRelayChatProtocol.maximumNicknameBytes))
    }

    private func consumeToken(_ session: inout Session, at date: Date) -> Bool {
        let capacity = Double(configuration.ratePerMinute)
        let elapsed = max(0, date.timeIntervalSince(session.lastRefill))
        session.tokens = min(capacity, session.tokens + elapsed * capacity / 60)
        session.lastRefill = date
        guard session.tokens >= 1 else { return false }
        session.tokens -= 1
        return true
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    public enum HubError: Error, Equatable {
        case invalidConfiguration, unknownSession, banned
    }
}
