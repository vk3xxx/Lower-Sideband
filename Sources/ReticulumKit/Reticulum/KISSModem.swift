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
        case txTail = 0x04, fullDuplex = 0x05, setHardware = 0x06, returnToHost = 0x0F
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
    public enum Framing: String, Codable, CaseIterable, Sendable { case kiss, hdlc }
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
        return self
    }

    public enum ValidationError: Error { case missingPath, unsupportedBaudRate, invalidPort, invalidIFACSize }
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
        if configuration.framing == .kiss { try? configureKISSModem() }
        await stateHandler(.ready)
    }

    public func stop() async {
        fileHandle?.readabilityHandler = nil
        try? fileHandle?.close()
        fileHandle = nil
        await stateHandler(.stopped)
    }

    public func send(rawPacket: Data) async throws {
        guard let fileHandle else { throw InterfaceError.notConnected }
        let raw = try ifac?.protect(rawPacket) ?? rawPacket
        let framed = configuration.framing == .kiss
            ? KISSModem.frame(port: configuration.port, payload: raw)
            : HDLC.frame(raw)
        try fileHandle.write(contentsOf: framed)
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
    }

    private func consume(_ bytes: Data) async {
        let frames: [Data]
        if configuration.framing == .kiss {
            frames = kissDecoder.consume(bytes).compactMap {
                $0.port == configuration.port && $0.command == .data ? $0.payload : nil
            }
        } else { frames = hdlcDecoder.consume(bytes) }
        for frame in frames {
            guard let raw = try? ifac?.unprotect(frame) ?? frame,
                  let packet = try? ReticulumPacket(raw: raw) else { continue }
            await packetHandler(packet)
        }
    }

    private static func serialSpeed(_ baud: Int) -> speed_t {
        switch baud {
        case 1_200: speed_t(B1200); case 2_400: speed_t(B2400); case 4_800: speed_t(B4800)
        case 9_600: speed_t(B9600); case 19_200: speed_t(B19200); case 38_400: speed_t(B38400)
        case 57_600: speed_t(B57600); case 230_400: speed_t(B230400)
        default: speed_t(B115200)
        }
    }

    public enum InterfaceError: Error { case notConnected }
}
#endif
