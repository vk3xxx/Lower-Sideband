import Foundation

public enum RNodeRadioType: UInt8, Codable, CaseIterable, Sendable {
    case sx127x = 0x00
    case sx1276 = 0x01
    case sx1278 = 0x02
    case sx126x = 0x10
    case sx1262 = 0x11
    case sx128x = 0x20
    case sx1280 = 0x21

    public var family: String {
        switch self {
        case .sx126x, .sx1262: "SX126X"
        case .sx127x, .sx1276, .sx1278: "SX127X"
        case .sx128x, .sx1280: "SX128X"
        }
    }
}

public struct RNodeVirtualPortConfiguration: Codable, Hashable, Identifiable, Sendable {
    public var id: UInt8 { virtualPort }
    public var virtualPort: UInt8
    public var name: String
    public var radio: RNodeConfiguration
    public var flowControl: Bool
    public var outgoing: Bool

    public init(
        virtualPort: UInt8,
        name: String,
        radio: RNodeConfiguration,
        flowControl: Bool = false,
        outgoing: Bool = true
    ) {
        self.virtualPort = virtualPort
        self.name = name
        self.radio = radio
        self.flowControl = flowControl
        self.outgoing = outgoing
    }

    public func validated() throws -> Self {
        guard virtualPort < RNodeMultiConfiguration.maximumVirtualPorts,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RNodeMultiError.invalidVirtualPort
        }
        _ = try radio.validated()
        return self
    }
}

public struct RNodeMultiConfiguration: Codable, Hashable, Sendable {
    public static let maximumVirtualPorts: UInt8 = 12

    public var name: String
    public var transport: RNodeTransportKind
    public var target: String
    public var tcpPort: UInt16
    public var automaticallyReconnects: Bool
    public var ports: [RNodeVirtualPortConfiguration]

    public init(
        name: String = "RNode Multi",
        transport: RNodeTransportKind = .serial,
        target: String,
        tcpPort: UInt16 = 7_633,
        automaticallyReconnects: Bool = true,
        ports: [RNodeVirtualPortConfiguration]
    ) {
        self.name = name
        self.transport = transport
        self.target = target
        self.tcpPort = tcpPort
        self.automaticallyReconnects = automaticallyReconnects
        self.ports = ports
    }

    public func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ports.isEmpty,
              ports.count <= Int(Self.maximumVirtualPorts),
              Set(ports.map(\.virtualPort)).count == ports.count else {
            throw RNodeMultiError.invalidConfiguration
        }
        if transport != .bluetoothLE && transport != .simulated &&
            target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RNodeError.missingTarget
        }
        for port in ports { _ = try port.validated() }
        return self
    }
}

public enum RNodeMultiError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidVirtualPort
    case unavailableVirtualPort(UInt8)
    case notReady

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Configure between one and twelve uniquely numbered RNode virtual ports."
        case .invalidVirtualPort: "The RNode virtual port configuration is invalid."
        case let .unavailableVirtualPort(port): "Virtual port \(port) is not reported by this RNode."
        case .notReady: "The RNode multi-interface is not ready."
        }
    }
}

public struct RNodeRawKISSFrame: Equatable, Sendable {
    public let command: UInt8
    public let payload: Data
}

/// Raw-command KISS decoder used by RNodeMulti. Several virtual-port data
/// command bytes intentionally overlap normal RNode control commands, so the
/// single-radio command enum cannot represent them without losing information.
public struct RNodeRawKISSDecoder: Sendable {
    public var maximumFrameSize: Int
    private var inFrame = false
    private var escaped = false
    private var command: UInt8?
    private var payload = Data()

    public init(maximumFrameSize: Int = 4_096) {
        self.maximumFrameSize = maximumFrameSize
    }

    public mutating func consume(_ bytes: Data) -> [RNodeRawKISSFrame] {
        var frames: [RNodeRawKISSFrame] = []
        for byte in bytes {
            if byte == RNodeKISS.frameEnd {
                if inFrame, let command {
                    frames.append(.init(command: command, payload: payload))
                }
                inFrame = true
                escaped = false
                command = nil
                payload.removeAll(keepingCapacity: true)
            } else if inFrame, command == nil {
                command = byte
            } else if inFrame {
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
        }
        return frames
    }
}

public enum RNodeMultiEvent: Equatable, Sendable {
    case packet(port: UInt8, data: Data)
    case detected
    case ready(port: UInt8)
    case interfaces([UInt8: RNodeRadioType])
    case metrics(port: UInt8, RNodeMetrics)
    case hardwareError(UInt8, String)
}

/// Protocol engine for the official RNodeMulti virtual-port extension.
public struct RNodeMultiProtocolEngine: Sendable {
    public static let dataCommands: [UInt8] = [
        0x00, 0x10, 0x20, 0x70, 0x75, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0
    ]

    public private(set) var selectedPort: UInt8 = 0
    public private(set) var interfaceTypes: [UInt8: RNodeRadioType] = [:]
    public private(set) var metrics: [UInt8: RNodeMetrics] = [:]
    private var decoder = RNodeRawKISSDecoder()
    private var portEngines: [UInt8: RNodeProtocolEngine] = [:]
    private var hasExplicitSelection = false

    public init() {}

    public func detectionCommands() -> Data {
        let engine = RNodeProtocolEngine()
        return engine.detectionCommands() + RNodeKISS.frame(command: .interfaces, payload: Data([0]))
    }

    public func configurationCommands(_ port: RNodeVirtualPortConfiguration) -> Data {
        let engine = RNodeProtocolEngine()
        var decoder = RNodeKISSDecoder()
        let frames = decoder.consume(engine.configurationCommands(port.radio))
        return frames.reduce(into: Data()) { output, frame in
            output += RNodeKISS.frame(command: .selectInterface, payload: Data([port.virtualPort]))
            output += RNodeKISS.frame(command: frame.command, payload: frame.payload)
        }
    }

    public func packetFrame(_ packet: Data, port: UInt8) throws -> Data {
        guard port < RNodeMultiConfiguration.maximumVirtualPorts else {
            throw RNodeMultiError.invalidVirtualPort
        }
        guard packet.count <= 508 else { throw RNodeError.transport("RNode packets cannot exceed 508 bytes.") }
        return RNodeKISS.frame(command: .selectInterface, payload: Data([port]))
            + RNodeKISS.frame(command: .data, payload: packet)
    }

    public mutating func consume(_ bytes: Data) -> [RNodeMultiEvent] {
        var events: [RNodeMultiEvent] = []
        for frame in decoder.consume(bytes) {
            events.append(contentsOf: interpret(frame))
        }
        return events
    }

    private mutating func interpret(_ frame: RNodeRawKISSFrame) -> [RNodeMultiEvent] {
        if frame.command == RNodeKISS.Command.selectInterface.rawValue,
           let port = frame.payload.first,
           port < RNodeMultiConfiguration.maximumVirtualPorts {
            selectedPort = port
            hasExplicitSelection = true
            return []
        }
        if frame.command == RNodeKISS.Command.interfaces.rawValue, frame.payload.count >= 2 {
            let port = frame.payload[0]
            if let type = RNodeRadioType(rawValue: frame.payload[1]),
               port < RNodeMultiConfiguration.maximumVirtualPorts {
                interfaceTypes[port] = type
                return [.interfaces(interfaceTypes)]
            }
            return []
        }
        if let explicitPort = Self.dataCommands.firstIndex(of: frame.command).flatMap(UInt8.init(exactly:)) {
            // Firmware normally emits SELECT_INTERFACE immediately before
            // DATA. Prefer it, while accepting command-addressed data from
            // firmware revisions that encode the port directly.
            let port = hasExplicitSelection ? selectedPort : explicitPort
            selectedPort = port
            hasExplicitSelection = false
            return [.packet(port: port, data: frame.payload)]
        }

        guard let command = RNodeKISS.Command(rawValue: frame.command) else { return [] }
        var engine = portEngines[selectedPort] ?? RNodeProtocolEngine()
        let events = engine.consume(RNodeKISS.frame(command: command, payload: frame.payload))
        portEngines[selectedPort] = engine
        metrics[selectedPort] = engine.metrics
        return events.flatMap { event -> [RNodeMultiEvent] in
            switch event {
            case .packet(let data): [.packet(port: selectedPort, data: data)]
            case .detected: [.detected]
            case .ready: [.ready(port: selectedPort)]
            case .metrics(let value): [.metrics(port: selectedPort, value)]
            case .hardwareError(let code, let reason): [.hardwareError(code, reason)]
            case .framebuffer, .display, .rom: []
            }
        }
    }
}

public actor RNodeMultiInterface {
    public enum State: Equatable, Sendable {
        case stopped, connecting, detecting, configuring, ready, failed(String)
    }

    public struct Snapshot: Equatable, Sendable {
        public let state: State
        public let availablePorts: [UInt8: RNodeRadioType]
        public let readyPorts: Set<UInt8>
        public let queuedPackets: [UInt8: Int]
        public let metrics: [UInt8: RNodeMetrics]
    }

    public typealias TransportFactory = @Sendable (RNodeMultiConfiguration) throws -> any RNodeByteTransport

    private let configuration: RNodeMultiConfiguration
    private let transportFactory: TransportFactory
    private let packetHandler: @Sendable (UInt8, Data) async -> Void
    private let snapshotHandler: @Sendable (Snapshot) async -> Void
    private var transport: (any RNodeByteTransport)?
    private var engine = RNodeMultiProtocolEngine()
    private var state: State = .stopped
    private var readyPorts: Set<UInt8> = []
    private var queues: [UInt8: [Data]] = [:]
    private var generation = UUID()

    public init(
        configuration: RNodeMultiConfiguration,
        transportFactory: @escaping TransportFactory = RNodeMultiInterface.defaultTransport,
        packetHandler: @escaping @Sendable (UInt8, Data) async -> Void,
        snapshotHandler: @escaping @Sendable (Snapshot) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.packetHandler = packetHandler
        self.snapshotHandler = snapshotHandler
    }

    public func start() async {
        guard transport == nil else { return }
        do {
            let validated = try configuration.validated()
            generation = UUID()
            let token = generation
            let transport = try transportFactory(validated)
            self.transport = transport
            state = .connecting
            await publish()
            await transport.start(
                receive: { [weak self] bytes in await self?.receive(bytes, generation: token) },
                state: { [weak self] state in await self?.transportState(state, generation: token) }
            )
        } catch {
            state = .failed(error.localizedDescription)
            await publish()
        }
    }

    public func stop() async {
        generation = UUID()
        await transport?.stop()
        transport = nil
        engine = RNodeMultiProtocolEngine()
        readyPorts.removeAll()
        queues.removeAll()
        state = .stopped
        await publish()
    }

    public func send(_ packet: Data, on virtualPort: UInt8) async throws {
        guard state == .ready, configuration.ports.contains(where: { $0.virtualPort == virtualPort && $0.outgoing }) else {
            throw RNodeMultiError.notReady
        }
        guard readyPorts.contains(virtualPort) else {
            queues[virtualPort, default: []].append(packet)
            await publish()
            return
        }
        try await transmit(packet, on: virtualPort)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            state: state,
            availablePorts: engine.interfaceTypes,
            readyPorts: readyPorts,
            queuedPackets: queues.mapValues(\.count),
            metrics: engine.metrics
        )
    }

    private func transportState(_ transportState: RNodeByteTransportState, generation token: UUID) async {
        guard generation == token else { return }
        switch transportState {
        case .ready:
            state = .detecting
            await publish()
            do { try await transport?.write(engine.detectionCommands()) }
            catch { await fail(error) }
        case .connecting, .searching:
            state = .connecting
            await publish()
        case let .failed(reason):
            await fail(RNodeError.transport(reason))
        case .stopped:
            if state != .stopped { await fail(RNodeError.notConnected) }
        }
    }

    private func receive(_ bytes: Data, generation token: UUID) async {
        guard generation == token else { return }
        for event in engine.consume(bytes) {
            switch event {
            case .detected:
                state = .configuring
                await configurePorts()
            case let .interfaces(types):
                let unavailable = configuration.ports.first { types[$0.virtualPort] == nil }
                if let unavailable {
                    await fail(RNodeMultiError.unavailableVirtualPort(unavailable.virtualPort))
                }
            case let .ready(port):
                readyPorts.insert(port)
                await drain(port)
            case let .packet(port, data):
                await packetHandler(port, data)
            case .metrics:
                break
            case let .hardwareError(_, reason):
                await fail(RNodeError.transport(reason))
            }
        }
        if !configuration.ports.isEmpty,
           configuration.ports.allSatisfy({ readyPorts.contains($0.virtualPort) }) {
            state = .ready
        }
        await publish()
    }

    private func configurePorts() async {
        do {
            for port in configuration.ports {
                try await transport?.write(engine.configurationCommands(port))
            }
        } catch {
            await fail(error)
        }
    }

    private func transmit(_ packet: Data, on port: UInt8) async throws {
        guard let configuration = configuration.ports.first(where: { $0.virtualPort == port }) else {
            throw RNodeMultiError.invalidVirtualPort
        }
        if configuration.flowControl { readyPorts.remove(port) }
        try await transport?.write(engine.packetFrame(packet, port: port))
    }

    private func drain(_ port: UInt8) async {
        guard var queue = queues[port], !queue.isEmpty else { return }
        do {
            while readyPorts.contains(port), !queue.isEmpty {
                let packet = queue.removeFirst()
                try await transmit(packet, on: port)
            }
            queues[port] = queue
        } catch {
            await fail(error)
        }
    }

    private func fail(_ error: Error) async {
        state = .failed(error.localizedDescription)
        readyPorts.removeAll()
        await publish()
    }

    private func publish() async { await snapshotHandler(snapshot()) }

    public static func defaultTransport(configuration: RNodeMultiConfiguration) throws -> any RNodeByteTransport {
        switch configuration.transport {
        case .bluetoothLE:
            return RNodeBLETransport(target: configuration.target)
        case .tcp:
            return RNodeTCPTransport(host: configuration.target, port: configuration.tcpPort)
        case .serial:
            #if os(macOS)
            return RNodeSerialTransport(path: configuration.target)
            #else
            throw RNodeError.transport("RNodeMulti USB serial is available on macOS; use Wi-Fi/TCP on iPhone and iPad.")
            #endif
        case .simulated:
            return SimulatedRNodeTransport()
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var result = lhs
        result.append(rhs)
        return result
    }
}
