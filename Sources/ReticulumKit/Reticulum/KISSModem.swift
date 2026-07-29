import Foundation
#if os(macOS)
import Darwin
#endif

/// Generic amateur packet-radio KISS framing. Unlike the RNode command set,
/// the upper nibble is a modem port and the lower nibble is a KISS command.
public enum KISSModem {
    public static let frameEnd: UInt8 = 0xC0
    public static let frameEscape: UInt8 = 0xDB
    public static let transposedEnd: UInt8 = 0xDC
    public static let transposedEscape: UInt8 = 0xDD

    public enum Command: UInt8, Codable, Sendable {
        case data = 0x00, txDelay = 0x01, persistence = 0x02, slotTime = 0x03
        case txTail = 0x04, fullDuplex = 0x05, setHardware = 0x06, ready = 0x0F
    }

    public static func frame(port: UInt8 = 0, command: Command = .data, payload: Data = Data()) -> Data {
        precondition(port < 16)
        var framed = Data([frameEnd, (port << 4) | command.rawValue])
        for byte in payload {
            switch byte {
            case frameEnd: framed.append(contentsOf: [frameEscape, transposedEnd])
            case frameEscape: framed.append(contentsOf: [frameEscape, transposedEscape])
            default: framed.append(byte)
            }
        }
        framed.append(frameEnd)
        return framed
    }
}

public struct KISSModemFrame: Equatable, Sendable {
    public let port: UInt8
    public let command: KISSModem.Command
    public let payload: Data
}

public struct KISSModemDecoder: Sendable {
    public var maximumFrameSize: Int
    private var inFrame = false
    private var escaped = false
    private var commandByte: UInt8?
    private var payload = Data()

    public init(maximumFrameSize: Int = 65_535) { self.maximumFrameSize = maximumFrameSize }

    public mutating func consume(_ bytes: Data) -> [KISSModemFrame] {
        var result: [KISSModemFrame] = []
        for byte in bytes {
            if byte == KISSModem.frameEnd {
                if inFrame, let commandByte,
                   let command = KISSModem.Command(rawValue: commandByte & 0x0F) {
                    result.append(.init(port: commandByte >> 4, command: command, payload: payload))
                }
                inFrame = true; escaped = false; commandByte = nil; payload.removeAll(keepingCapacity: true)
                continue
            }
            guard inFrame else { continue }
            if commandByte == nil { commandByte = byte; continue }
            if escaped {
                if byte == KISSModem.transposedEnd { payload.append(KISSModem.frameEnd) }
                else if byte == KISSModem.transposedEscape { payload.append(KISSModem.frameEscape) }
                else { payload.append(byte) }
                escaped = false
            } else if byte == KISSModem.frameEscape { escaped = true }
            else { payload.append(byte) }
            if payload.count > maximumFrameSize {
                inFrame = false; escaped = false; commandByte = nil; payload.removeAll(keepingCapacity: true)
            }
        }
        return result
    }
}

public struct KISSModemConfiguration: Codable, Equatable, Identifiable, Sendable {
    public enum Framing: String, Codable, CaseIterable, Sendable { case kiss, ax25Kiss, hdlc }
    public var id = UUID()
    public var name = "KISS modem"
    public var serialPath = ""
    public var baudRate = 115_200
    public var port: UInt8 = 0
    public var txDelay: UInt8 = 50
    public var persistence: UInt8 = 63
    public var slotTime: UInt8 = 10
    public var txTail: UInt8 = 30
    public var fullDuplex = false
    public var flowControl = false
    public var flowControlTimeout: TimeInterval = 5
    public var callsign = ""
    public var ssid: UInt8 = 0
    public var destinationCallsign = "APZRNS"
    public var destinationSSID: UInt8 = 0
    public var beaconCallsign: String?
    public var beaconInterval: TimeInterval?
    public var framing: Framing = .kiss
    public var interfaceMode: ReticulumInterfaceMode = .full
    public var ifacNetworkName: String?
    public var ifacPassphrase: String?
    public var ifacSize = 8
    public var enabled = true

    public init() {}

    public func validated() throws -> Self {
        guard !serialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.missingPath }
        guard [1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600, 115_200, 230_400].contains(baudRate) else {
            throw ValidationError.unsupportedBaudRate
        }
        guard port < 16 else { throw ValidationError.invalidPort }
        guard (1...64).contains(ifacSize) else { throw ValidationError.invalidIFACSize }
        guard flowControlTimeout > 0, flowControlTimeout <= 60 else { throw ValidationError.invalidFlowControlTimeout }
        if framing == .ax25Kiss {
            guard AX25UIFrame.isValidCallsign(callsign), ssid < 16,
                  AX25UIFrame.isValidCallsign(destinationCallsign), destinationSSID < 16 else {
                throw ValidationError.invalidAX25Address
            }
        }
        if let beaconCallsign, !beaconCallsign.isEmpty {
            guard AX25UIFrame.isValidCallsign(beaconCallsign),
                  let beaconInterval, beaconInterval >= 60 else { throw ValidationError.invalidBeacon }
        }
        return self
    }

    public enum ValidationError: Error {
        case missingPath, unsupportedBaudRate, invalidPort, invalidIFACSize
        case invalidFlowControlTimeout, invalidAX25Address, invalidBeacon
    }
}

/// AX.25 UI-frame envelope used by Reticulum's AX25KISSInterface. FCS is
/// intentionally omitted because KISS TNCs add and verify it on-air.
public enum AX25UIFrame {
    public static let headerSize = 16
    public static let controlUI: UInt8 = 0x03
    public static let pidNoLayer3: UInt8 = 0xF0

    public static func isValidCallsign(_ value: String) -> Bool {
        let ascii = value.uppercased().utf8
        return (3...6).contains(ascii.count) && ascii.allSatisfy {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        }
    }

    public static func encode(
        payload: Data,
        sourceCallsign: String,
        sourceSSID: UInt8,
        destinationCallsign: String = "APZRNS",
        destinationSSID: UInt8 = 0
    ) throws -> Data {
        guard isValidCallsign(sourceCallsign), isValidCallsign(destinationCallsign),
              sourceSSID < 16, destinationSSID < 16 else { throw Error.invalidAddress }
        return try address(destinationCallsign, ssid: destinationSSID, final: false)
            + address(sourceCallsign, ssid: sourceSSID, final: true)
            + Data([controlUI, pidNoLayer3]) + payload
    }

    public static func decode(_ frame: Data) throws -> Data {
        guard frame.count > headerSize, frame[14] == controlUI, frame[15] == pidNoLayer3,
              frame[6] & 0x01 == 0, frame[13] & 0x01 == 1 else { throw Error.invalidFrame }
        return Data(frame.dropFirst(headerSize))
    }

    private static func address(_ callsign: String, ssid: UInt8, final: Bool) throws -> Data {
        guard isValidCallsign(callsign), ssid < 16 else { throw Error.invalidAddress }
        let padded = callsign.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)
        return Data(padded.utf8.map { $0 << 1 }) + Data([0x60 | (ssid << 1) | (final ? 1 : 0)])
    }
    public enum Error: Swift.Error { case invalidAddress, invalidFrame }
}

#if os(macOS)
/// A native serial Reticulum interface for conventional KISS TNCs and raw
/// HDLC serial adapters. It never shells out to Python or external utilities.
public actor ReticulumSerialPacketInterface {
    public enum State: Equatable, Sendable { case stopped, connecting, ready, failed(String) }

    private let configuration: KISSModemConfiguration
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void
    private var fileHandle: FileHandle?
    private var kissDecoder = KISSModemDecoder()
    private var hdlcDecoder = HDLCDecoder()
    private let ifac: ReticulumIFAC?
    private var outboundQueue: [Data] = []
    private var interfaceReady = true
    private var flowControlTimeoutTask: Task<Void, Never>?
    private var beaconTask: Task<Void, Never>?
    private var lastNonBeaconTransmission: Date?

    public init(
        configuration: KISSModemConfiguration,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) throws {
        self.configuration = try configuration.validated()
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
        if configuration.ifacNetworkName?.isEmpty == false || configuration.ifacPassphrase?.isEmpty == false {
            ifac = try ReticulumIFAC(
                networkName: configuration.ifacNetworkName,
                passphrase: configuration.ifacPassphrase,
                size: configuration.ifacSize
            )
        } else { ifac = nil }
    }

    public func start() async {
        guard fileHandle == nil else { return }
        await stateHandler(.connecting)
        let descriptor = Darwin.open(configuration.serialPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { await stateHandler(.failed(String(cString: strerror(errno)))); return }
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            Darwin.close(descriptor); await stateHandler(.failed("Could not inspect the serial port.")); return
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        let speed = Self.serialSpeed(configuration.baudRate)
        cfsetispeed(&options, speed); cfsetospeed(&options, speed)
        guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            Darwin.close(descriptor); await stateHandler(.failed("Could not configure the serial port.")); return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        fileHandle = handle
        handle.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { await self?.consume(bytes) }
        }
        if configuration.framing != .hdlc { try? configureKISSModem() }
        startBeaconLifecycle()
        await stateHandler(.ready)
    }

    public func stop() async {
        fileHandle?.readabilityHandler = nil
        try? fileHandle?.close()
        fileHandle = nil
        flowControlTimeoutTask?.cancel(); flowControlTimeoutTask = nil
        beaconTask?.cancel(); beaconTask = nil
        outboundQueue.removeAll(); interfaceReady = true
        await stateHandler(.stopped)
    }

    public func send(rawPacket: Data) async throws {
        guard fileHandle != nil else { throw InterfaceError.notConnected }
        let raw = try ifac?.protect(rawPacket) ?? rawPacket
        let payload = configuration.framing == .ax25Kiss
            ? try AX25UIFrame.encode(
                payload: raw,
                sourceCallsign: configuration.callsign,
                sourceSSID: configuration.ssid,
                destinationCallsign: configuration.destinationCallsign,
                destinationSSID: configuration.destinationSSID
            )
            : raw
        let framed = configuration.framing == .hdlc
            ? HDLC.frame(payload)
            : KISSModem.frame(port: configuration.port, payload: payload)
        if configuration.flowControl, !interfaceReady {
            guard outboundQueue.count < 256 else { throw InterfaceError.queueFull }
            outboundQueue.append(framed)
            return
        }
        try write(framed, isBeacon: false)
    }

    private func configureKISSModem() throws {
        guard let fileHandle else { return }
        let commands: [(KISSModem.Command, UInt8)] = [
            (.txDelay, configuration.txDelay), (.persistence, configuration.persistence),
            (.slotTime, configuration.slotTime), (.txTail, configuration.txTail),
            (.fullDuplex, configuration.fullDuplex ? 1 : 0)
        ]
        for (command, value) in commands {
            try fileHandle.write(contentsOf: KISSModem.frame(port: configuration.port, command: command, payload: Data([value])))
        }
        try fileHandle.write(contentsOf: KISSModem.frame(port: configuration.port, command: .ready, payload: Data([configuration.flowControl ? 1 : 0])))
    }

    private func consume(_ bytes: Data) async {
        let frames: [Data]
        if configuration.framing != .hdlc {
            frames = kissDecoder.consume(bytes).compactMap { frame in
                guard frame.port == configuration.port else { return nil }
                if frame.command == .ready {
                    releaseFlowControl()
                    return nil
                }
                guard frame.command == .data else { return nil }
                if configuration.framing == .ax25Kiss { return try? AX25UIFrame.decode(frame.payload) }
                return frame.payload
            }
        } else { frames = hdlcDecoder.consume(bytes) }
        for frame in frames {
            guard let raw = try? ifac?.unprotect(frame) ?? frame,
                  let packet = try? ReticulumPacket(raw: raw) else { continue }
            await packetHandler(packet)
        }
    }

    private func write(_ frame: Data, isBeacon: Bool) throws {
        guard let fileHandle else { throw InterfaceError.notConnected }
        try fileHandle.write(contentsOf: frame)
        if !isBeacon { lastNonBeaconTransmission = .now }
        guard configuration.flowControl else { return }
        interfaceReady = false
        flowControlTimeoutTask?.cancel()
        let timeout = configuration.flowControlTimeout
        flowControlTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.releaseFlowControl()
        }
    }

    private func releaseFlowControl() {
        flowControlTimeoutTask?.cancel(); flowControlTimeoutTask = nil
        interfaceReady = true
        guard !outboundQueue.isEmpty else { return }
        let next = outboundQueue.removeFirst()
        try? write(next, isBeacon: false)
    }

    private func startBeaconLifecycle() {
        guard let callsign = configuration.beaconCallsign,
              let interval = configuration.beaconInterval else { return }
        beaconTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.sendBeaconIfIdle(callsign: callsign, interval: interval)
            }
        }
    }

    private func sendBeaconIfIdle(callsign: String, interval: TimeInterval) {
        guard lastNonBeaconTransmission.map({ Date.now.timeIntervalSince($0) >= interval }) == true else { return }
        var data = Data(callsign.utf8)
        while data.count < 15 { data.append(0) }
        let frame = KISSModem.frame(port: configuration.port, payload: data)
        try? write(frame, isBeacon: true)
    }

    private static func serialSpeed(_ baud: Int) -> speed_t {
        switch baud {
        case 1_200: speed_t(B1200); case 2_400: speed_t(B2400); case 4_800: speed_t(B4800)
        case 9_600: speed_t(B9600); case 19_200: speed_t(B19200); case 38_400: speed_t(B38400)
        case 57_600: speed_t(B57600); case 230_400: speed_t(B230400)
        default: speed_t(B115200)
        }
    }

    public enum InterfaceError: Error { case notConnected, queueFull }
}
#endif

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
