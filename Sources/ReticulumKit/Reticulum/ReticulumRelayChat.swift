import Foundation

public enum ReticulumRelayChatProtocol {
    public static let version: UInt64 = 1
    public static let destinationName = "rrc.hub"
    public static let maximumNicknameBytes = 32
    public static let maximumRoomBytes = 64
    public static let maximumMessageBytes = 350
    public static let maximumRooms = 32
    public static let defaultRatePerMinute = 240

    public enum MessageType: UInt64, Codable, Sendable {
        case hello = 1, welcome = 2
        case join = 10, joined = 11, part = 12, parted = 13
        case message = 20, notice = 21, action = 22
        case ping = 30, pong = 31, error = 40, resourceEnvelope = 50
    }

    public struct Message: Equatable, Sendable {
        public var type: MessageType
        public var messageID: Data
        public var timestampMilliseconds: UInt64
        public var source: Data
        public var room: String?
        public var body: CanonicalCBORValue?
        public var nickname: String?

        public init(
            type: MessageType,
            messageID: Data = Data((0 ..< 8).map { _ in UInt8.random(in: .min ... .max) }),
            timestampMilliseconds: UInt64 = UInt64(Date.now.timeIntervalSince1970 * 1_000),
            source: Data,
            room: String? = nil,
            body: CanonicalCBORValue? = nil,
            nickname: String? = nil
        ) throws {
            guard messageID.count == 8, !source.isEmpty, source.count <= 64 else { throw ProtocolError.invalidMessage }
            if let room { try Self.validate(room, maximumBytes: maximumRoomBytes) }
            if let nickname { try Self.validate(nickname, maximumBytes: maximumNicknameBytes) }
            if case .text(let text) = body { try Self.validate(text, maximumBytes: maximumMessageBytes) }
            self.type = type
            self.messageID = messageID
            self.timestampMilliseconds = timestampMilliseconds
            self.source = source
            self.room = room
            self.body = body
            self.nickname = nickname
        }

        public var encoded: Data {
            get throws {
                var map: [CanonicalCBORValue: CanonicalCBORValue] = [
                    .unsigned(0): .unsigned(version),
                    .unsigned(1): .unsigned(type.rawValue),
                    .unsigned(2): .bytes(messageID),
                    .unsigned(3): .unsigned(timestampMilliseconds),
                    .unsigned(4): .bytes(source)
                ]
                if let room { map[.unsigned(5)] = .text(room) }
                if let body { map[.unsigned(6)] = body }
                if let nickname { map[.unsigned(7)] = .text(nickname) }
                return try CanonicalCBOR.encode(.map(map))
            }
        }

        public static func decode(_ data: Data) throws -> Message {
            guard data.count <= 65_536,
                  case let .map(map) = try CanonicalCBOR.decode(data),
                  map[.unsigned(0)] == .unsigned(version),
                  case let .unsigned(rawType) = map[.unsigned(1)],
                  let type = MessageType(rawValue: rawType),
                  case let .bytes(messageID) = map[.unsigned(2)],
                  case let .unsigned(timestamp) = map[.unsigned(3)],
                  case let .bytes(source) = map[.unsigned(4)] else {
                throw ProtocolError.invalidMessage
            }
            let room = map[.unsigned(5)].flatMap { if case .text(let value) = $0 { value } else { nil } }
            let nickname = map[.unsigned(7)].flatMap { if case .text(let value) = $0 { value } else { nil } }
            return try Message(
                type: type,
                messageID: messageID,
                timestampMilliseconds: timestamp,
                source: source,
                room: room,
                body: map[.unsigned(6)],
                nickname: nickname
            )
        }

        private static func validate(_ value: String, maximumBytes: Int) throws {
            guard !value.isEmpty, value.utf8.count <= maximumBytes,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ProtocolError.invalidMessage
            }
        }
    }

    public struct ResourceEnvelope: Equatable, Sendable {
        public var resourceID: Data
        public var kind: String
        public var size: UInt64
        public var sha256: Data
        public var encoding: String

        public var body: CanonicalCBORValue {
            .map([
                .unsigned(0): .bytes(resourceID),
                .unsigned(1): .text(kind),
                .unsigned(2): .unsigned(size),
                .unsigned(3): .bytes(sha256),
                .unsigned(4): .text(encoding)
            ])
        }
    }

    public static func destinationHash(for identity: ReticulumIdentity) -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash)
    }

    public static func helloBody(client: String, clientVersion: String, capabilities: [UInt64]) throws -> CanonicalCBORValue {
        guard !client.isEmpty, client.utf8.count <= 64, clientVersion.utf8.count <= 32 else {
            throw ProtocolError.invalidMessage
        }
        return .map([
            .unsigned(0): .text(client),
            .unsigned(1): .text(clientVersion),
            .unsigned(2): .array(capabilities.sorted().map(CanonicalCBORValue.unsigned))
        ])
    }

    public static func mentions(in text: String, nickname: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: nickname)
        return text.range(of: "(?i)(^|[^\\p{L}\\p{N}_])@\(escaped)(?=$|[^\\p{L}\\p{N}_])", options: .regularExpression) != nil
    }

    public enum ProtocolError: Error, Equatable { case invalidMessage }
}
