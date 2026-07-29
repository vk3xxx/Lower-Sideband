import Foundation

/// Wire protocol used by RNode firmware. RNode uses KISS framing rather than
/// the HDLC framing used by Reticulum's TCP server interface.
public enum RNodeKISS {
    public static let frameEnd: UInt8 = 0xC0
    public static let frameEscape: UInt8 = 0xDB
    public static let transposedEnd: UInt8 = 0xDC
    public static let transposedEscape: UInt8 = 0xDD

    public enum Command: UInt8, CaseIterable, Sendable {
        case data = 0x00
        case frequency = 0x01
        case bandwidth = 0x02
        case txPower = 0x03
        case spreadingFactor = 0x04
        case codingRate = 0x05
        case radioState = 0x06
        case radioLock = 0x07
        case detect = 0x08
        case implicit = 0x09
        case leave = 0x0A
        case shortTermAirtimeLock = 0x0B
        case longTermAirtimeLock = 0x0C
        case promiscuous = 0x0E
        case ready = 0x0F
        case selectInterface = 0x1F
        case receivedBytes = 0x21
        case transmittedBytes = 0x22
        case rssi = 0x23
        case snr = 0x24
        case channelMetrics = 0x25
        case physicalMetrics = 0x26
        case battery = 0x27
        case csma = 0x28
        case temperature = 0x29
        case blink = 0x30
        case random = 0x40
        case externalFramebuffer = 0x41
        case framebufferRead = 0x42
        case framebufferWrite = 0x43
        case framebufferReadLine = 0x44
        case displayIntensity = 0x45
        case bluetoothControl = 0x46
        case board = 0x47
        case platform = 0x48
        case mcu = 0x49
        case firmwareVersion = 0x50
        case romRead = 0x51
        case romWrite = 0x52
        case configurationSave = 0x53
        case configurationDelete = 0x54
        case reset = 0x55
        case deviceHash = 0x56
        case deviceSignature = 0x57
        case firmwareHash = 0x58
        case romUnlock = 0x59
        case hashes = 0x60
        case firmwareUpdate = 0x61
        case bluetoothPIN = 0x62
        case displayAddress = 0x63
        case displayBlank = 0x64
        case neopixelIntensity = 0x65
        case displayRead = 0x66
        case displayRotation = 0x67
        case displayRecondition = 0x68
        case displayInterfaceAccess = 0x69
        case wifiMode = 0x6A
        case wifiSSID = 0x6B
        case wifiPSK = 0x6C
        case configurationRead = 0x6D
        case wifiChannel = 0x6E
        case bluetoothUnpair = 0x70
        case interfaces = 0x71
        case log = 0x80
        case time = 0x81
        case muxChain = 0x82
        case muxDiscover = 0x83
        case wifiIP = 0x84
        case wifiNetmask = 0x85
        case error = 0x90
        case unknown = 0xFE
    }

    public static func frame(command: Command, payload: Data = Data()) -> Data {
        var result = Data([frameEnd, command.rawValue])
        for byte in payload {
            switch byte {
            case frameEnd: result.append(contentsOf: [frameEscape, transposedEnd])
            case frameEscape: result.append(contentsOf: [frameEscape, transposedEscape])
            default: result.append(byte)
            }
        }
        result.append(frameEnd)
        return result
    }
}

public struct RNodeKISSFrame: Equatable, Sendable {
    public let command: RNodeKISS.Command
    public let payload: Data
    public init(command: RNodeKISS.Command, payload: Data) {
        self.command = command
        self.payload = payload
    }
}

/// Incremental decoder that tolerates arbitrary BLE, serial and TCP chunking.
public struct RNodeKISSDecoder: Sendable {
    public var maximumFrameSize: Int
    private var inFrame = false
    private var escaped = false
    private var command: RNodeKISS.Command?
    private var payload = Data()

    public init(maximumFrameSize: Int = 4_096) {
        self.maximumFrameSize = maximumFrameSize
    }

    public mutating func consume(_ bytes: Data) -> [RNodeKISSFrame] {
        var frames: [RNodeKISSFrame] = []
        for byte in bytes {
            if byte == RNodeKISS.frameEnd {
                if inFrame, let command {
                    frames.append(RNodeKISSFrame(command: command, payload: payload))
                }
                inFrame = true
                escaped = false
                command = nil
                payload.removeAll(keepingCapacity: true)
                continue
            }
            guard inFrame else { continue }
            if command == nil {
                command = RNodeKISS.Command(rawValue: byte)
                if command == nil { inFrame = false }
                continue
            }
            if escaped {
                switch byte {
                case RNodeKISS.transposedEnd: payload.append(RNodeKISS.frameEnd)
                case RNodeKISS.transposedEscape: payload.append(RNodeKISS.frameEscape)
                default: payload.append(byte)
                }
                escaped = false
            } else if byte == RNodeKISS.frameEscape {
                escaped = true
            } else {
                payload.append(byte)
            }
            if payload.count > maximumFrameSize {
                inFrame = false
                escaped = false
                command = nil
                payload.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }
}

public enum RNodeTransportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case bluetoothLE
    case tcp
    case serial
    case simulated

    public var title: String {
        switch self {
        case .bluetoothLE: "Bluetooth LE"
        case .tcp: "Wi-Fi / TCP"
        case .serial: "USB serial"
        case .simulated: "Simulator"
        }
    }
}

public struct RNodeConfiguration: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: RNodeTransportKind
    /// BLE peripheral UUID or advertised name, TCP host, or serial device path.
    public var target: String
    public var tcpPort: UInt16
    public var frequency: UInt32
    public var bandwidth: UInt32
    public var txPower: UInt8
    public var spreadingFactor: UInt8
    public var codingRate: UInt8
    public var shortTermAirtimeLimit: Double?
    public var longTermAirtimeLimit: Double?
    public var enabled: Bool
    public var automaticallyReconnects: Bool
    /// Optional plain-text station identification, transmitted exactly like the
    /// reference RNode interface after normal traffic begins.
    public var beaconCallsign: String?
    public var beaconInterval: TimeInterval?
    /// Nil preserves settings written by older app versions.
    public var externalFramebufferEnabled: Bool?

    public init(
        id: UUID = UUID(), name: String = "RNode", transport: RNodeTransportKind = .bluetoothLE,
        target: String = "", tcpPort: UInt16 = 7_633, frequency: UInt32 = 915_000_000,
        bandwidth: UInt32 = 125_000, txPower: UInt8 = 7, spreadingFactor: UInt8 = 8,
        codingRate: UInt8 = 5, shortTermAirtimeLimit: Double? = 33,
        longTermAirtimeLimit: Double? = 1.5, enabled: Bool = true,
        automaticallyReconnects: Bool = true, beaconCallsign: String? = nil,
        beaconInterval: TimeInterval? = nil, externalFramebufferEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.target = target
        self.tcpPort = tcpPort
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.txPower = txPower
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.shortTermAirtimeLimit = shortTermAirtimeLimit
        self.longTermAirtimeLimit = longTermAirtimeLimit
        self.enabled = enabled
        self.automaticallyReconnects = automaticallyReconnects
        self.beaconCallsign = beaconCallsign
        self.beaconInterval = beaconInterval
        self.externalFramebufferEnabled = externalFramebufferEnabled
    }

    public func validated() throws -> Self {
        guard (137_000_000...3_000_000_000).contains(frequency) else { throw RNodeError.invalidFrequency }
        guard (7_800...1_625_000).contains(bandwidth) else { throw RNodeError.invalidBandwidth }
        guard txPower <= 37 else { throw RNodeError.invalidTransmitPower }
        guard (5...12).contains(spreadingFactor) else { throw RNodeError.invalidSpreadingFactor }
        guard (5...8).contains(codingRate) else { throw RNodeError.invalidCodingRate }
        for limit in [shortTermAirtimeLimit, longTermAirtimeLimit].compactMap({ $0 }) {
            guard (0...100).contains(limit) else { throw RNodeError.invalidAirtimeLimit }
        }
        if let callsign = beaconCallsign, !callsign.isEmpty {
            guard callsign.lengthOfBytes(using: .utf8) <= 32 else { throw RNodeError.invalidBeacon }
            guard let interval = beaconInterval, interval >= 30 else { throw RNodeError.invalidBeacon }
        }
        if transport != .bluetoothLE && transport != .simulated && target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RNodeError.missingTarget
        }
        return self
    }
}

public enum RNodeBatteryState: UInt8, Codable, Sendable {
    case unknown = 0, discharging = 1, charging = 2, charged = 3
}

public struct RNodeMetrics: Codable, Equatable, Sendable {
    public var frequency: UInt32?
    public var bandwidth: UInt32?
    public var txPower: UInt8?
    public var spreadingFactor: UInt8?
    public var codingRate: UInt8?
    public var radioEnabled: Bool?
    public var radioLocked: Bool?
    public var shortTermAirtimeLimit: Double?
    public var longTermAirtimeLimit: Double?
    public var firmwareMajor: UInt8?
    public var firmwareMinor: UInt8?
    public var platform: UInt8?
    public var mcu: UInt8?
    public var board: UInt8?
    public var externalFramebufferEnabled: Bool?
    public var deviceHash: Data?
    public var firmwareHash: Data?
    public var receivedBytes: UInt32?
    public var transmittedBytes: UInt32?
    public var rssi: Int?
    public var snr: Double?
    public var signalQuality: Double?
    public var airtimeShort: Double?
    public var airtimeLong: Double?
    public var channelLoadShort: Double?
    public var channelLoadLong: Double?
    public var noiseFloor: Int?
    public var interference: Int?
    public var symbolTimeMilliseconds: Double?
    public var symbolRate: UInt16?
    public var preambleSymbols: UInt16?
    public var preambleTimeMilliseconds: UInt16?
    public var csmaSlotTimeMilliseconds: UInt16?
    public var csmaDIFSMilliseconds: UInt16?
    public var csmaContentionWindowBand: UInt8?
    public var csmaContentionWindowMinimum: UInt8?
    public var csmaContentionWindowMaximum: UInt8?
    public var randomByte: UInt8?
    public var batteryState: RNodeBatteryState
    public var batteryPercent: UInt8?
    public var temperature: Int?
    public var lastUpdatedAt: Date?

    public init() { batteryState = .unknown }
}

public enum RNodeEvent: Equatable, Sendable {
    case packet(Data)
    case detected
    case ready(Bool)
    case metrics(RNodeMetrics)
    case framebuffer(Data)
    case display(Data)
    case rom(Data)
    case hardwareError(UInt8, String)
}

public enum RNodeError: LocalizedError, Equatable, Sendable {
    case invalidFrequency, invalidBandwidth, invalidTransmitPower, invalidSpreadingFactor
    case invalidCodingRate, invalidAirtimeLimit, missingTarget, notConnected
    case invalidBeacon, invalidFramebuffer
    case detectionTimedOut, incompatibleFirmware(UInt8, UInt8), configurationMismatch
    case transport(String), hardware(UInt8, String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrequency: "RNode frequency must be between 137 MHz and 3 GHz."
        case .invalidBandwidth: "RNode bandwidth must be between 7.8 kHz and 1.625 MHz."
        case .invalidTransmitPower: "RNode transmit power must be between 0 and 37 dBm."
        case .invalidSpreadingFactor: "RNode spreading factor must be between 5 and 12."
        case .invalidCodingRate: "RNode coding rate must be between 5 and 8."
        case .invalidAirtimeLimit: "RNode airtime limits must be between 0 and 100 percent."
        case .invalidBeacon: "RNode station ID must be at most 32 UTF-8 bytes and use an interval of at least 30 seconds."
        case .invalidFramebuffer: "RNode framebuffer data must contain 512 bytes (64×64 monochrome pixels)."
        case .missingTarget: "Choose an RNode device, host, or serial port."
        case .notConnected: "The RNode is not connected."
        case .detectionTimedOut: "The connected device did not identify itself as an RNode."
        case .incompatibleFirmware(let major, let minor): "RNode firmware \(major).\(minor) is older than the required 1.52."
        case .configurationMismatch: "The RNode did not accept the requested radio configuration."
        case .transport(let reason): reason
        case .hardware(_, let reason): reason
        }
    }
}

/// Stateful interpreter for RNode command replies and radio telemetry.
public struct RNodeProtocolEngine: Sendable {
    public static let detectRequest: UInt8 = 0x73
    public static let detectResponse: UInt8 = 0x46
    public static let minimumFirmware = (major: UInt8(1), minor: UInt8(52))
    public static let rssiOffset = 157
    public private(set) var metrics = RNodeMetrics()
    private var decoder = RNodeKISSDecoder()

    public init() {}

    public static func firmwareIsSupported(major: UInt8, minor: UInt8) -> Bool {
        major > minimumFirmware.major || (major == minimumFirmware.major && minor >= minimumFirmware.minor)
    }

    public mutating func consume(_ bytes: Data) -> [RNodeEvent] {
        decoder.consume(bytes).flatMap { interpret($0) }
    }

    public func detectionCommands() -> Data {
        RNodeKISS.frame(command: .detect, payload: Data([Self.detectRequest]))
        + RNodeKISS.frame(command: .firmwareVersion, payload: Data([0]))
        + RNodeKISS.frame(command: .platform, payload: Data([0]))
        + RNodeKISS.frame(command: .mcu, payload: Data([0]))
        + RNodeKISS.frame(command: .board, payload: Data([0]))
        + RNodeKISS.frame(command: .deviceHash, payload: Data([1]))
        + RNodeKISS.frame(command: .hashes, payload: Data([2]))
    }

    public func configurationCommands(_ configuration: RNodeConfiguration) -> Data {
        var result = Data()
        result += command(.frequency, uint32: configuration.frequency)
        result += command(.bandwidth, uint32: configuration.bandwidth)
        result += RNodeKISS.frame(command: .txPower, payload: Data([configuration.txPower]))
        result += RNodeKISS.frame(command: .spreadingFactor, payload: Data([configuration.spreadingFactor]))
        result += RNodeKISS.frame(command: .codingRate, payload: Data([configuration.codingRate]))
        if let limit = configuration.shortTermAirtimeLimit { result += airtimeCommand(.shortTermAirtimeLock, limit) }
        if let limit = configuration.longTermAirtimeLimit { result += airtimeCommand(.longTermAirtimeLock, limit) }
        result += RNodeKISS.frame(command: .radioState, payload: Data([1]))
        if let enabled = configuration.externalFramebufferEnabled {
            result += externalFramebufferCommand(enabled: enabled)
        }
        return result
    }

    public func packetFrame(_ packet: Data) throws -> Data {
        guard packet.count <= 508 else { throw RNodeError.transport("Reticulum packet exceeds the RNode 508-byte hardware MTU.") }
        return RNodeKISS.frame(command: .data, payload: packet)
    }

    public func leaveCommand() -> Data { RNodeKISS.frame(command: .leave, payload: Data([0xFF])) }
    public func readyQueryCommand() -> Data { RNodeKISS.frame(command: .ready, payload: Data([0x01])) }
    public func blinkCommand() -> Data { RNodeKISS.frame(command: .blink, payload: Data([0x01])) }
    public func resetCommand() -> Data { RNodeKISS.frame(command: .reset, payload: Data([0xF8])) }
    public func firmwareUpdateCommand() -> Data { RNodeKISS.frame(command: .firmwareUpdate, payload: Data([0x01])) }
    public func framebufferReadCommand() -> Data { RNodeKISS.frame(command: .framebufferRead, payload: Data([0x01])) }
    public func displayReadCommand() -> Data { RNodeKISS.frame(command: .displayRead, payload: Data([0x01])) }
    public func romReadCommand() -> Data { RNodeKISS.frame(command: .romRead, payload: Data([0x01])) }
    public func externalFramebufferCommand(enabled: Bool) -> Data {
        RNodeKISS.frame(command: .externalFramebuffer, payload: Data([enabled ? 1 : 0]))
    }
    public func framebufferWriteCommands(_ framebuffer: Data) throws -> Data {
        guard framebuffer.count == 512 else { throw RNodeError.invalidFramebuffer }
        var commands = Data()
        for line in 0..<64 {
            commands += RNodeKISS.frame(command: .framebufferWrite, payload: Data([UInt8(line)]) + framebuffer.subdata(in: line * 8..<(line + 1) * 8))
        }
        return commands
    }

    public func configurationMatches(_ configuration: RNodeConfiguration) -> Bool {
        guard let frequency = metrics.frequency, abs(Int64(frequency) - Int64(configuration.frequency)) <= 100,
              metrics.bandwidth == configuration.bandwidth,
              metrics.txPower == configuration.txPower,
              metrics.spreadingFactor == configuration.spreadingFactor,
              metrics.codingRate == configuration.codingRate,
              metrics.radioEnabled == true else { return false }
        return true
    }

    private mutating func interpret(_ frame: RNodeKISSFrame) -> [RNodeEvent] {
        let p = frame.payload
        var events: [RNodeEvent] = []
        switch frame.command {
        case .data: events.append(.packet(p))
        case .detect where p.first == Self.detectResponse: events.append(.detected)
        case .frequency: metrics.frequency = uint32(p)
        case .bandwidth: metrics.bandwidth = uint32(p)
        case .txPower: metrics.txPower = p.first
        case .spreadingFactor: metrics.spreadingFactor = p.first
        case .codingRate: metrics.codingRate = p.first
        case .radioState: metrics.radioEnabled = p.first.map { $0 != 0 }
        case .radioLock: metrics.radioLocked = p.first.map { $0 != 0 }
        case .shortTermAirtimeLock where p.count >= 2:
            metrics.shortTermAirtimeLimit = Double(uint16(p, 0)) / 100
        case .longTermAirtimeLock where p.count >= 2:
            metrics.longTermAirtimeLimit = Double(uint16(p, 0)) / 100
        case .firmwareVersion where p.count >= 2:
            metrics.firmwareMajor = p[0]; metrics.firmwareMinor = p[1]
        case .platform: metrics.platform = p.first
        case .mcu: metrics.mcu = p.first
        case .board: metrics.board = p.first
        case .externalFramebuffer: metrics.externalFramebufferEnabled = p.first.map { $0 != 0 }
        case .deviceHash: metrics.deviceHash = p
        case .firmwareHash: metrics.firmwareHash = p
        case .receivedBytes: metrics.receivedBytes = uint32(p)
        case .transmittedBytes: metrics.transmittedBytes = uint32(p)
        case .rssi where !p.isEmpty: metrics.rssi = Int(p[0]) - Self.rssiOffset
        case .snr where !p.isEmpty:
            let snr = Double(Int8(bitPattern: p[0])) * 0.25
            metrics.snr = snr
            let sf = Int(metrics.spreadingFactor ?? 7)
            let minimum = -9.0 - Double(sf - 7) * 2.0
            metrics.signalQuality = min(100, max(0, ((snr - minimum) / (6 - minimum)) * 100))
        case .channelMetrics where p.count >= 11:
            metrics.airtimeShort = Double(uint16(p, 0)) / 100
            metrics.airtimeLong = Double(uint16(p, 2)) / 100
            metrics.channelLoadShort = Double(uint16(p, 4)) / 100
            metrics.channelLoadLong = Double(uint16(p, 6)) / 100
            metrics.rssi = Int(p[8]) - Self.rssiOffset
            metrics.noiseFloor = Int(p[9]) - Self.rssiOffset
            metrics.interference = p[10] == 0xFF ? nil : Int(p[10]) - Self.rssiOffset
        case .physicalMetrics where p.count >= 12:
            metrics.symbolTimeMilliseconds = Double(uint16(p, 0)) / 1_000
            metrics.symbolRate = uint16(p, 2)
            metrics.preambleSymbols = uint16(p, 4)
            metrics.preambleTimeMilliseconds = uint16(p, 6)
            metrics.csmaSlotTimeMilliseconds = uint16(p, 8)
            metrics.csmaDIFSMilliseconds = uint16(p, 10)
        case .csma where p.count >= 3:
            metrics.csmaContentionWindowBand = p[0]
            metrics.csmaContentionWindowMinimum = p[1]
            metrics.csmaContentionWindowMaximum = p[2]
        case .battery where p.count >= 2:
            metrics.batteryState = RNodeBatteryState(rawValue: p[0]) ?? .unknown
            metrics.batteryPercent = min(100, p[1])
        case .temperature where !p.isEmpty:
            let value = Int(p[0]) - 120
            metrics.temperature = (-30...90).contains(value) ? value : nil
        case .random where !p.isEmpty: metrics.randomByte = p[0]
        case .framebufferRead where p.count == 512: events.append(.framebuffer(p))
        case .displayRead where p.count == 1024: events.append(.display(p))
        case .romRead where !p.isEmpty: events.append(.rom(p))
        case .ready: events.append(.ready(p.first == 0x01))
        case .error where !p.isEmpty:
            events.append(.hardwareError(p[0], hardwareErrorDescription(p[0])))
        default: break
        }
        if frame.command != .data && frame.command != .detect && frame.command != .ready && frame.command != .error && frame.command != .framebufferRead && frame.command != .displayRead && frame.command != .romRead {
            metrics.lastUpdatedAt = .now
            events.append(.metrics(metrics))
        }
        return events
    }

    private func command(_ command: RNodeKISS.Command, uint32 value: UInt32) -> Data {
        RNodeKISS.frame(command: command, payload: Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]))
    }

    private func airtimeCommand(_ command: RNodeKISS.Command, _ limit: Double) -> Data {
        let value = UInt16((limit * 100).rounded())
        return RNodeKISS.frame(command: command, payload: Data([UInt8(value >> 8), UInt8(value & 0xFF)]))
    }

    private func uint32(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private func hardwareErrorDescription(_ code: UInt8) -> String {
        switch code {
        case 0x01: "RNode radio initialisation failed."
        case 0x02: "RNode transmission failed."
        case 0x03: "RNode EEPROM is locked."
        case 0x04: "RNode transmit queue is full."
        case 0x05: "RNode has insufficient memory."
        case 0x06: "RNode modem communication timed out."
        default: "RNode reported hardware error 0x\(String(code, radix: 16))."
        }
    }
}
