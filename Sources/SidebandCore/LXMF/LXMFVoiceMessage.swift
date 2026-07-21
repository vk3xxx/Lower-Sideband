import Foundation

/// Standard LXMF FIELD_AUDIO payload: `[audio_mode, encoded_audio_bytes]`.
public struct LXMFVoiceMessageAudio: Codable, Hashable, Sendable {
    public enum Mode: UInt8, Codable, CaseIterable, Sendable {
        case codec2_450PWB = 0x01, codec2_450 = 0x02, codec2_700C = 0x03
        case codec2_1200 = 0x04, codec2_1300 = 0x05, codec2_1400 = 0x06
        case codec2_1600 = 0x07, codec2_2400 = 0x08, codec2_3200 = 0x09
        case opusOgg = 0x10, opusLowBandwidth = 0x11, opusMediumBandwidth = 0x12
        case opusPTT = 0x13, opusRealtimeHalfDuplex = 0x14, opusRealtimeFullDuplex = 0x15
        case opusStandard = 0x16, opusHighQuality = 0x17, opusBroadcast = 0x18, opusLossless = 0x19
        case custom = 0xFF

        public var isCodec2: Bool { (0x01...0x09).contains(rawValue) }
        public var isOggOpus: Bool { self == .opusOgg }

        public var codec2Mode: Codec2Codec.Mode? {
            switch self {
            case .codec2_700C: .bitrate700C
            case .codec2_1200: .bitrate1200
            case .codec2_1300: .bitrate1300
            case .codec2_1400: .bitrate1400
            case .codec2_1600: .bitrate1600
            case .codec2_2400: .bitrate2400
            case .codec2_3200: .bitrate3200
            default: nil
            }
        }
    }

    public static let maximumEncodedBytes = 8 * 1_024 * 1_024
    public let mode: Mode
    public let encodedAudio: Data

    public init(mode: Mode, encodedAudio: Data) throws {
        guard !encodedAudio.isEmpty, encodedAudio.count <= Self.maximumEncodedBytes else { throw Error.invalidSize }
        if mode == .opusOgg, !OggOpusStream.isOggOpus(encodedAudio) { throw Error.invalidContainer }
        self.mode = mode
        self.encodedAudio = encodedAudio
    }

    public var encodedField: Data {
        MessagePack.array([MessagePack.unsigned(UInt64(mode.rawValue)), MessagePack.binary(encodedAudio)])
    }

    public init?(field: MessagePackValue?) {
        guard case let .array(parts)? = field, parts.count == 2,
              case let .unsigned(rawMode) = parts[0], let raw = UInt8(exactly: rawMode),
              let mode = Mode(rawValue: raw), case let .binary(audio) = parts[1],
              let value = try? Self(mode: mode, encodedAudio: audio) else { return nil }
        self = value
    }

    public enum Error: Swift.Error { case invalidSize, invalidContainer }
}

/// Minimal standards-compliant Ogg Opus muxer for native low-bitrate voice
/// messages. Opus granule positions always use the codec's 48 kHz clock.
public enum OggOpusStream {
    public static func isOggOpus(_ data: Data) -> Bool {
        data.starts(with: Data("OggS".utf8)) && data.range(of: Data("OpusHead".utf8)) != nil
    }

    public static func mux(packets: [Data], frameSamplesAt48k: UInt64, inputSampleRate: UInt32 = 12_000, serial: UInt32) -> Data {
        guard !packets.isEmpty else { return Data() }
        let head = Data("OpusHead".utf8) + Data([1, 1]) + littleEndian(UInt16(0)) + littleEndian(inputSampleRate) + littleEndian(UInt16(0)) + Data([0])
        let vendor = Data("Lower Sideband".utf8)
        let tags = Data("OpusTags".utf8) + littleEndian(UInt32(vendor.count)) + vendor + littleEndian(UInt32(0))
        var stream = page(packet: head, headerType: 0x02, granule: 0, serial: serial, sequence: 0)
        stream.append(page(packet: tags, headerType: 0x00, granule: 0, serial: serial, sequence: 1))
        var granule: UInt64 = 0
        for (offset, packetData) in packets.enumerated() {
            granule += frameSamplesAt48k
            let end: UInt8 = offset == packets.count - 1 ? 0x04 : 0x00
            stream.append(page(packet: packetData, headerType: end, granule: granule, serial: serial, sequence: UInt32(offset + 2)))
        }
        return stream
    }

    private static func page(packet: Data, headerType: UInt8, granule: UInt64, serial: UInt32, sequence: UInt32) -> Data {
        var lacing = Data(repeating: 255, count: packet.count / 255)
        lacing.append(UInt8(packet.count % 255))
        var page = Data("OggS".utf8) + Data([0, headerType]) + littleEndian(granule) + littleEndian(serial) + littleEndian(sequence)
        page.append(Data(repeating: 0, count: 4))
        page.append(UInt8(lacing.count)); page.append(lacing); page.append(packet)
        var checksum = crc(page).littleEndian
        withUnsafeBytes(of: &checksum) { page.replaceSubrange(22..<26, with: $0) }
        return page
    }

    public static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in data {
            value ^= UInt32(byte) << 24
            for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        }
        return value
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var encoded = value.littleEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var result = lhs; result.append(rhs); return result }
}
