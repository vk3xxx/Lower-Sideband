import Foundation

/// Reticulum Channel framing and the wire-compatible RNSH message set.
public enum ReticulumChannel {
    public static let headerBytes = 6
    public static let maximumPayloadBytes = Int(UInt16.max)

    public struct Envelope: Equatable, Sendable {
        public var messageType: UInt16
        public var sequence: UInt16
        public var payload: Data

        public init(messageType: UInt16, sequence: UInt16, payload: Data) throws {
            guard payload.count <= maximumPayloadBytes else { throw ChannelError.payloadTooLarge }
            self.messageType = messageType
            self.sequence = sequence
            self.payload = payload
        }

        public var encoded: Data {
            var output = Data()
            output.appendUInt16(messageType)
            output.appendUInt16(sequence)
            output.appendUInt16(UInt16(payload.count))
            output.append(payload)
            return output
        }

        public static func decode(_ data: Data) throws -> Envelope {
            guard data.count >= headerBytes else { throw ChannelError.truncated }
            let type = data.readUInt16(at: 0)
            let sequence = data.readUInt16(at: 2)
            let length = Int(data.readUInt16(at: 4))
            guard data.count == headerBytes + length else { throw ChannelError.truncated }
            return try Envelope(messageType: type, sequence: sequence, payload: Data(data.dropFirst(headerBytes)))
        }
    }

    /// Bounded reordering/deduplication for reliable Channel delivery.
    public struct Receiver: Sendable {
        public private(set) var nextSequence: UInt16
        private var buffered: [UInt16: Envelope] = [:]
        private let maximumBuffered: Int

        public init(nextSequence: UInt16 = 0, maximumBuffered: Int = 64) {
            self.nextSequence = nextSequence
            self.maximumBuffered = max(1, maximumBuffered)
        }

        public mutating func ingest(_ envelope: Envelope) -> [Envelope] {
            if envelope.sequence == nextSequence {
                var ready = [envelope]
                nextSequence &+= 1
                while let following = buffered.removeValue(forKey: nextSequence) {
                    ready.append(following)
                    nextSequence &+= 1
                }
                return ready
            }
            let distance = envelope.sequence &- nextSequence
            guard distance > 0, distance <= UInt16(maximumBuffered), buffered.count < maximumBuffered else { return [] }
            buffered[envelope.sequence] = envelope
            return []
        }
    }

    public enum ChannelError: Error, Equatable { case truncated, payloadTooLarge, invalidMessage }
}

public enum ReticulumShellProtocol {
    public static let destinationName = "rnsh"
    public static let protocolVersion: UInt64 = 1
    private static let magic: UInt16 = 0xac00

    public enum MessageType: UInt16, Sendable {
        case noop = 0xac00
        case windowSize = 0xac02
        case execute = 0xac03
        case stream = 0xac04
        case version = 0xac05
        case error = 0xac06
        case commandExited = 0xac07
    }

    public enum StreamID: UInt16, Sendable { case stdin = 0, stdout = 1, stderr = 2 }

    public enum Message: Equatable, Sendable {
        case noop
        case windowSize(rows: UInt64, columns: UInt64, horizontalPixels: UInt64, verticalPixels: UInt64)
        case execute(arguments: [String], pipeStdin: Bool, pipeStdout: Bool, pipeStderr: Bool, terminal: String?, rows: UInt64, columns: UInt64, horizontalPixels: UInt64, verticalPixels: UInt64)
        case stream(id: StreamID, data: Data, eof: Bool, compressed: Bool)
        case version(software: String, protocolVersion: UInt64)
        case error(message: String, fatal: Bool)
        case commandExited(Int64)
    }

    public static func destinationHash(for identity: ReticulumIdentity) -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash)
    }

    public static func envelope(for message: Message, sequence: UInt16) throws -> ReticulumChannel.Envelope {
        try .init(messageType: messageType(for: message).rawValue, sequence: sequence, payload: encodePayload(message))
    }

    public static func decode(_ envelope: ReticulumChannel.Envelope) throws -> Message {
        guard envelope.messageType & 0xff00 == magic,
              let type = MessageType(rawValue: envelope.messageType) else { throw ReticulumChannel.ChannelError.invalidMessage }
        let decoded = try? MessagePackDecoder.decode(
            envelope.payload,
            limits: .init(maximumDepth: 12, maximumCollectionCount: 256, maximumNodeCount: 1_024, maximumScalarBytes: 65_535)
        )
        switch type {
        case .noop:
            guard envelope.payload.isEmpty else { throw ReticulumChannel.ChannelError.invalidMessage }
            return .noop
        case .windowSize:
            guard case let .array(values) = decoded, values.count == 4,
                  let rows = values[0].unsignedValue, let columns = values[1].unsignedValue,
                  let hpix = values[2].unsignedValue, let vpix = values[3].unsignedValue else {
                throw ReticulumChannel.ChannelError.invalidMessage
            }
            return .windowSize(rows: rows, columns: columns, horizontalPixels: hpix, verticalPixels: vpix)
        case .execute:
            guard case let .array(values) = decoded, values.count == 10,
                  case let .array(rawArguments) = values[0],
                  rawArguments.count <= 128,
                  let arguments = rawArguments.strings,
                  case let .bool(pipeIn) = values[1], case let .bool(pipeOut) = values[2], case let .bool(pipeErr) = values[3],
                  let rows = values[6].unsignedValue, let columns = values[7].unsignedValue,
                  let hpix = values[8].unsignedValue, let vpix = values[9].unsignedValue else {
                throw ReticulumChannel.ChannelError.invalidMessage
            }
            let terminal = values[5].stringOrNil
            return .execute(arguments: arguments, pipeStdin: pipeIn, pipeStdout: pipeOut, pipeStderr: pipeErr, terminal: terminal, rows: rows, columns: columns, horizontalPixels: hpix, verticalPixels: vpix)
        case .stream:
            guard envelope.payload.count >= 2 else { throw ReticulumChannel.ChannelError.invalidMessage }
            let header = envelope.payload.readUInt16(at: 0)
            guard let stream = StreamID(rawValue: header & 0x3fff) else { throw ReticulumChannel.ChannelError.invalidMessage }
            return .stream(id: stream, data: Data(envelope.payload.dropFirst(2)), eof: header & 0x8000 != 0, compressed: header & 0x4000 != 0)
        case .version:
            guard case let .array(values) = decoded, values.count == 2,
                  case let .string(software) = values[0], let version = values[1].unsignedValue else {
                throw ReticulumChannel.ChannelError.invalidMessage
            }
            return .version(software: software, protocolVersion: version)
        case .error:
            guard case let .array(values) = decoded, values.count == 3,
                  case let .string(message) = values[0], case let .bool(fatal) = values[1] else {
                throw ReticulumChannel.ChannelError.invalidMessage
            }
            return .error(message: message, fatal: fatal)
        case .commandExited:
            guard let value = decoded?.signedValue else { throw ReticulumChannel.ChannelError.invalidMessage }
            return .commandExited(value)
        }
    }

    private static func messageType(for message: Message) -> MessageType {
        switch message {
        case .noop: .noop
        case .windowSize: .windowSize
        case .execute: .execute
        case .stream: .stream
        case .version: .version
        case .error: .error
        case .commandExited: .commandExited
        }
    }

    private static func encodePayload(_ message: Message) throws -> Data {
        switch message {
        case .noop: return Data()
        case let .windowSize(rows, columns, hpix, vpix):
            return MessagePack.array([rows, columns, hpix, vpix].map(MessagePack.unsigned))
        case let .execute(arguments, pipeIn, pipeOut, pipeErr, terminal, rows, columns, hpix, vpix):
            guard arguments.count <= 128, arguments.allSatisfy({ $0.utf8.count <= 4_096 }) else {
                throw ReticulumChannel.ChannelError.invalidMessage
            }
            return MessagePack.array([
                MessagePack.array(arguments.map(MessagePack.string)),
                MessagePack.bool(pipeIn), MessagePack.bool(pipeOut), MessagePack.bool(pipeErr),
                MessagePack.null, terminal.map(MessagePack.string) ?? MessagePack.null,
                MessagePack.unsigned(rows), MessagePack.unsigned(columns),
                MessagePack.unsigned(hpix), MessagePack.unsigned(vpix)
            ])
        case let .stream(id, data, eof, compressed):
            guard data.count <= ReticulumChannel.maximumPayloadBytes - 2 else { throw ReticulumChannel.ChannelError.payloadTooLarge }
            var header = id.rawValue
            if eof { header |= 0x8000 }
            if compressed { header |= 0x4000 }
            var output = Data()
            output.appendUInt16(header)
            output.append(data)
            return output
        case let .version(software, version):
            return MessagePack.array([MessagePack.string(software), MessagePack.unsigned(version)])
        case let .error(message, fatal):
            return MessagePack.array([MessagePack.string(message), MessagePack.bool(fatal), MessagePack.null])
        case .commandExited(let code):
            return MessagePack.signed(code)
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(truncatingIfNeeded: value))
    }
    func readUInt16(at offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
}

private extension MessagePackValue {
    var unsignedValue: UInt64? {
        switch self { case .unsigned(let value): value; case .signed(let value) where value >= 0: UInt64(value); default: nil }
    }
    var signedValue: Int64? {
        switch self {
        case .signed(let value): value
        case .unsigned(let value) where value <= UInt64(Int64.max): Int64(value)
        default: nil
        }
    }
    var stringOrNil: String? { if case .string(let value) = self { value } else { nil } }
}

private extension Array where Element == MessagePackValue {
    var strings: [String]? {
        var result: [String] = []
        for value in self {
            guard case let .string(text) = value else { return nil }
            result.append(text)
        }
        return result
    }
}
