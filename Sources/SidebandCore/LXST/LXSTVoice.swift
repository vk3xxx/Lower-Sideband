import Foundation

/// Python LXST-compatible telephony signalling and media framing.
public enum LXSTVoice {
    public static let destinationName = "lxst.telephony"
    public static let signallingField: UInt64 = 0x00
    public static let framesField: UInt64 = 0x01

    public enum Signal: UInt64, Sendable {
        case busy = 0x00
        case rejected = 0x01
        case calling = 0x02
        case available = 0x03
        case ringing = 0x04
        case connecting = 0x05
        case established = 0x06
    }

    public enum Codec: UInt8, Sendable {
        case raw = 0x00
        case opus = 0x01
        case codec2 = 0x02
    }

    public enum Profile: UInt64, CaseIterable, Codable, Sendable {
        case ultraLowBandwidth = 0x10
        case veryLowBandwidth = 0x20
        case lowBandwidth = 0x30
        case mediumQuality = 0x40
        case highQuality = 0x50
        case maximumQuality = 0x60
        case ultraLowLatency = 0x70
        case lowLatency = 0x80

        public var displayName: String {
            switch self {
            case .ultraLowBandwidth: "Ultra-low bandwidth"
            case .veryLowBandwidth: "Very-low bandwidth"
            case .lowBandwidth: "Low bandwidth"
            case .mediumQuality: "Medium quality"
            case .highQuality: "High quality"
            case .maximumQuality: "Maximum quality"
            case .ultraLowLatency: "Ultra-low latency"
            case .lowLatency: "Low latency"
            }
        }

        public var codec: Codec {
            switch self {
            case .ultraLowBandwidth, .veryLowBandwidth, .lowBandwidth: .codec2
            default: .opus
            }
        }

        public var frameDuration: TimeInterval {
            switch self {
            case .ultraLowBandwidth: 0.4
            case .veryLowBandwidth: 0.32
            case .lowBandwidth: 0.2
            case .ultraLowLatency: 0.01
            case .lowLatency: 0.02
            default: 0.06
            }
        }

        /// Swift currently provides the native Opus profiles. Codec2 profiles
        /// remain decodable for interoperability but require a Codec2 runtime.
        public var isLocallySupported: Bool { self == .mediumQuality }
    }

    public enum Event: Equatable, Sendable {
        case signals([UInt64])
        case frame(codec: Codec, payload: Data)
    }

    public static func destinationHash(for identity: ReticulumIdentity) -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash)
    }

    public static func signalling(_ signals: [UInt64]) -> Data {
        MessagePack.map([(signallingField, MessagePack.array(signals.map(MessagePack.unsigned)))])
    }

    public static func preferredProfile(_ profile: Profile) -> Data {
        // LXST uses 0xFF + profile as the signalling value.
        signalling([0xff + profile.rawValue])
    }

    public static func frame(codec: Codec, payload: Data) -> Data {
        MessagePack.map([(framesField, MessagePack.binary(Data([codec.rawValue]) + payload))])
    }

    public static func decode(_ data: Data) throws -> Event {
        guard case let .map(entries) = try MessagePackDecoder.decode(data), entries.count == 1,
              case let .unsigned(field) = entries[0].0 else { throw DecodeError.invalidEnvelope }
        switch (field, entries[0].1) {
        case (signallingField, .array(let values)):
            let signals = try values.map { value -> UInt64 in
                guard case let .unsigned(signal) = value else { throw DecodeError.invalidSignal }
                return signal
            }
            return .signals(signals)
        case (framesField, .binary(let frame)):
            guard let header = frame.first, let codec = Codec(rawValue: header) else { throw DecodeError.invalidFrame }
            return .frame(codec: codec, payload: Data(frame.dropFirst()))
        default:
            throw DecodeError.invalidEnvelope
        }
    }

    public enum DecodeError: Error { case invalidEnvelope, invalidSignal, invalidFrame }
}

/// A small bounded FIFO that absorbs normal packet-arrival jitter without allowing
/// call latency to grow indefinitely. After an underrun it deliberately buffers a
/// few frames again before resuming playback.
public struct LXSTJitterBuffer: Sendable {
    public let targetDepth: Int
    public let maximumDepth: Int
    public private(set) var droppedFrameCount = 0
    public private(set) var underrunCount = 0
    public private(set) var isPrimed = false
    private var frames: [Data] = []

    public init(targetDepth: Int = 3, maximumDepth: Int = 12) {
        self.targetDepth = max(1, targetDepth)
        self.maximumDepth = max(self.targetDepth, maximumDepth)
    }

    public var count: Int { frames.count }

    public mutating func enqueue(_ frame: Data) {
        guard !frame.isEmpty else { return }
        frames.append(frame)
        if frames.count > maximumDepth {
            frames.removeFirst(frames.count - maximumDepth)
            droppedFrameCount += 1
        }
    }

    public mutating func nextFrame() -> Data? {
        if !isPrimed {
            guard frames.count >= targetDepth else { return nil }
            isPrimed = true
        }
        guard !frames.isEmpty else {
            isPrimed = false
            underrunCount += 1
            return nil
        }
        return frames.removeFirst()
    }

    public mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        droppedFrameCount = 0
        underrunCount = 0
        isPrimed = false
    }
}

public enum VoiceCallState: String, Codable, Sendable {
    case idle, findingRoute, connecting, ringing, incoming, active, ending, failed
}

public enum VoiceCallDirection: String, Codable, Sendable { case incoming, outgoing }

public struct VoiceCall: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let direction: VoiceCallDirection
    public var state: VoiceCallState
    public var profile: LXSTVoice.Profile
    public let startedAt: Date
    public var connectedAt: Date?
    public var endedAt: Date?
    public var failureReason: String?

    public init(id: UUID = UUID(), conversationID: UUID, direction: VoiceCallDirection, state: VoiceCallState, profile: LXSTVoice.Profile = .mediumQuality, startedAt: Date = .now, connectedAt: Date? = nil, endedAt: Date? = nil, failureReason: String? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.direction = direction
        self.state = state
        self.profile = profile
        self.startedAt = startedAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.failureReason = failureReason
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
