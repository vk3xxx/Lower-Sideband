import ReticulumKit
import CCodec2
import Foundation

/// Native binding to the official Codec2 1.2.0 runtime embedded for Apple
/// platforms. Codec2 operates on signed, mono 8 kHz PCM samples.
public final class Codec2Codec: @unchecked Sendable {
    public enum Mode: Int32, CaseIterable, Codable, Sendable {
        case bitrate3200 = 0
        case bitrate2400 = 1
        case bitrate1600 = 2
        case bitrate1400 = 3
        case bitrate1300 = 4
        case bitrate1200 = 5
        case bitrate700C = 8

        public var bitsPerSecond: Int {
            switch self {
            case .bitrate3200: 3_200
            case .bitrate2400: 2_400
            case .bitrate1600: 1_600
            case .bitrate1400: 1_400
            case .bitrate1300: 1_300
            case .bitrate1200: 1_200
            case .bitrate700C: 700
            }
        }
    }

    public enum CodecError: Error, Equatable {
        case unavailable
        case incorrectSampleCount(expected: Int, actual: Int)
        case incorrectPayloadSize(expected: Int, actual: Int)
    }

    public static let sampleRate = 8_000
    public let mode: Mode
    public let samplesPerFrame: Int
    public let bitsPerFrame: Int
    public let bytesPerFrame: Int
    private let state: OpaquePointer
    private let lock = NSLock()

    public init(mode: Mode) throws {
        guard let state = codec2_create(mode.rawValue) else { throw CodecError.unavailable }
        self.state = state
        self.mode = mode
        samplesPerFrame = Int(codec2_samples_per_frame(state))
        bitsPerFrame = Int(codec2_bits_per_frame(state))
        bytesPerFrame = Int(codec2_bytes_per_frame(state))
    }

    deinit { codec2_destroy(state) }

    public func encode(_ samples: [Int16]) throws -> Data {
        guard samples.count == samplesPerFrame else {
            throw CodecError.incorrectSampleCount(expected: samplesPerFrame, actual: samples.count)
        }
        return lock.withLock {
            var input = samples
            var output = [UInt8](repeating: 0, count: bytesPerFrame)
            codec2_encode(state, &output, &input)
            return Data(output)
        }
    }

    public func decode(_ payload: Data) throws -> [Int16] {
        guard payload.count == bytesPerFrame else {
            throw CodecError.incorrectPayloadSize(expected: bytesPerFrame, actual: payload.count)
        }
        return lock.withLock {
            var input = [UInt8](payload)
            var output = [Int16](repeating: 0, count: samplesPerFrame)
            codec2_decode(state, &output, &input)
            return output
        }
    }
}

public extension LXSTVoice.Profile {
    var codec2Mode: Codec2Codec.Mode? {
        switch self {
        case .ultraLowBandwidth: .bitrate700C
        case .veryLowBandwidth: .bitrate1200
        case .lowBandwidth: .bitrate2400
        default: nil
        }
    }
}
