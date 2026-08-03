import Foundation
import Observation

public actor RNodeInterface {
    public enum State: Equatable, Sendable {
        case stopped, searching, connecting, detecting, configuring, ready, failed(String)
    }

    public struct Snapshot: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let transport: RNodeTransportKind
        public let target: String
        public let state: State
        public let metrics: RNodeMetrics
        public let connectedAt: Date?
        public let lastPacketAt: Date?
        public let lastError: String?
        public let queuedPackets: Int
        public let framebuffer: Data?
        public let displaySnapshot: Data?
        public let romSnapshot: Data?
        public let lastBeaconAt: Date?
    }

    public typealias TransportFactory = @Sendable (RNodeConfiguration) throws -> any RNodeByteTransport
    private var configuration: RNodeConfiguration
    private let transportFactory: TransportFactory
    private var transport: (any RNodeByteTransport)?
    private var engine = RNodeProtocolEngine()
    private var state: State = .stopped
    private var connectedAt: Date?
    private var lastPacketAt: Date?
    private var lastError: String?
    private var pendingPackets: [Data] = []
    private var awaitingRadioReady = false
    private var detectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var beaconTask: Task<Void, Never>?
    private var readinessPollTask: Task<Void, Never>?
    private var generation = UUID()
    private var framebuffer: Data?
    private var displaySnapshot: Data?
    private var romSnapshot: Data?
    private var lastBeaconAt: Date?
    private let packetHandler: @Sendable (Data) async -> Void
    private let snapshotHandler: @Sendable (Snapshot) async -> Void

    public init(
        configuration: RNodeConfiguration,
        transportFactory: @escaping TransportFactory = RNodeInterface.defaultTransport,
        packetHandler: @escaping @Sendable (Data) async -> Void,
        snapshotHandler: @escaping @Sendable (Snapshot) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.packetHandler = packetHandler
        self.snapshotHandler = snapshotHandler
    }

    public func start() async {
        guard state == .stopped || isFailed else { return }
        do {
            configuration = try configuration.validated()
            generation = UUID()
            let currentGeneration = generation
            let transport = try transportFactory(configuration)
            self.transport = transport
            awaitingRadioReady = false
            state = transport.kind == .bluetoothLE ? .searching : .connecting
            lastError = nil
            await publish()
            await transport.start { [weak self] bytes in
                await self?.received(bytes, generation: currentGeneration)
            } state: { [weak self] newState in
                await self?.transportStateChanged(newState, generation: currentGeneration)
            }
        } catch {
            await fail(error.localizedDescription)
        }
    }

    public func stop() async {
        reconnectTask?.cancel(); reconnectTask = nil
        detectionTask?.cancel(); detectionTask = nil
        beaconTask?.cancel(); beaconTask = nil
        readinessPollTask?.cancel(); readinessPollTask = nil
        generation = UUID()
        if state == .ready { try? await transport?.write(engine.leaveCommand()) }
        await transport?.stop()
        transport = nil
        state = .stopped
        pendingPackets.removeAll()
        awaitingRadioReady = false
        await publish()
    }

    public func update(configuration: RNodeConfiguration) async {
        let needsRestart = configuration != self.configuration
        self.configuration = configuration
        if needsRestart { await stop(); if configuration.enabled { await start() } }
    }

    public func send(rawPacket: Data) async throws {
        guard state == .ready, transport != nil else {
            if pendingPackets.count < 128 { pendingPackets.append(rawPacket) }
            throw RNodeError.notConnected
        }
        guard pendingPackets.count < 128 else {
            throw RNodeError.transport("The RNode outbound queue is full.")
        }
        pendingPackets.append(rawPacket)
        try await pumpOutboundQueue()
    }

    public func blink() async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.blinkCommand())
    }

    public func setExternalFramebuffer(_ enabled: Bool) async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.externalFramebufferCommand(enabled: enabled))
    }

    public func writeFramebuffer(_ data: Data) async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(try engine.framebufferWriteCommands(data))
    }

    public func requestFramebuffer() async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.framebufferReadCommand())
    }

    public func requestDisplaySnapshot() async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.displayReadCommand())
    }

    public func requestROMSnapshot() async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.romReadCommand())
    }

    public func enterFirmwareUpdateMode() async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.firmwareUpdateCommand())
    }

    public func resetHardware() async throws {
        guard state == .ready, let transport else { throw RNodeError.notConnected }
        try await transport.write(engine.resetCommand())
    }

    public func snapshot() -> Snapshot { makeSnapshot() }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private func transportStateChanged(_ newState: RNodeByteTransportState, generation expected: UUID) async {
        guard generation == expected else { return }
        switch newState {
        case .stopped:
            if state != .stopped { state = .stopped; await publish() }
        case .searching: state = .searching; await publish()
        case .connecting: state = .connecting; await publish()
        case .ready:
            reconnectTask?.cancel(); reconnectTask = nil
            state = .detecting
            connectedAt = .now
            await publish()
            do { try await transport?.write(engine.detectionCommands()) }
            catch { await fail(error.localizedDescription); return }
            detectionTask?.cancel()
            let token = expected
            detectionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                await self?.detectionTimedOut(generation: token)
            }
        case .failed(let reason): await fail(reason)
        }
    }

    private func detectionTimedOut(generation expected: UUID) async {
        guard generation == expected, state == .detecting || state == .configuring else { return }
        await fail(RNodeError.detectionTimedOut.localizedDescription)
    }

    private func received(_ bytes: Data, generation expected: UUID) async {
        guard generation == expected else { return }
        for event in engine.consume(bytes) {
            switch event {
            case .packet(let raw):
                lastPacketAt = .now
                await packetHandler(raw)
            case .detected:
                state = .configuring
                await publish()
                do { try await transport?.write(engine.configurationCommands(configuration)) }
                catch { await fail(error.localizedDescription) }
            case .ready(let available):
                if available {
                    readinessPollTask?.cancel(); readinessPollTask = nil
                    awaitingRadioReady = false
                    // Resume on a fresh task boundary. Some byte transports
                    // deliver READY synchronously from write(); recursively
                    // pumping here can build an unbounded callback chain under
                    // sustained traffic and starve receipt processing.
                    Task { [weak self] in await self?.resumeOutboundQueue() }
                } else {
                    scheduleReadinessPoll()
                }
            case .metrics(let metrics):
                if let major = metrics.firmwareMajor, let minor = metrics.firmwareMinor,
                   !RNodeProtocolEngine.firmwareIsSupported(major: major, minor: minor) {
                    await fail(RNodeError.incompatibleFirmware(major, minor).localizedDescription)
                    return
                }
                if state == .configuring, engine.configurationMatches(configuration) {
                    detectionTask?.cancel(); detectionTask = nil
                    state = .ready
                    await flushQueue()
                    startBeaconSchedule()
                }
                await publish()
            case .framebuffer(let data): framebuffer = data; await publish()
            case .display(let data): displaySnapshot = data; await publish()
            case .rom(let data): romSnapshot = data; await publish()
            case .hardwareError(let code, let reason):
                await fail(RNodeError.hardware(code, reason).localizedDescription)
            }
        }
    }

    private func flushQueue() async {
        do { try await pumpOutboundQueue() }
        catch { await fail(error.localizedDescription) }
    }

    private func resumeOutboundQueue() async {
        do { try await pumpOutboundQueue() }
        catch { await fail(error.localizedDescription) }
    }

    /// RNode firmware answers CMD_READY with its queue state. Polling after
    /// each packet provides a one-packet transmit window without assuming the
    /// firmware will emit unsolicited readiness notifications.
    private func pumpOutboundQueue() async throws {
        guard state == .ready, !awaitingRadioReady, let transport,
              let packet = pendingPackets.first else { return }
        let frame = try engine.packetFrame(packet)
        pendingPackets.removeFirst()
        // Close the transmit window before awaiting the byte transport.
        // Transport callbacks are actor-reentrant, so marking the interface
        // busy afterwards allowed another sender to enter this method while
        // the first frame was still being written. On byte-stream transports
        // that could interleave responses and lose otherwise valid frames.
        awaitingRadioReady = true
        do {
            try await transport.write(frame)
        } catch {
            awaitingRadioReady = false
            pendingPackets.insert(packet, at: 0)
            throw error
        }
        do {
            try await transport.write(engine.readyQueryCommand())
        } catch {
            awaitingRadioReady = false
            throw error
        }
    }

    private func scheduleReadinessPoll() {
        guard readinessPollTask == nil else { return }
        let token = generation
        readinessPollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await self?.pollReadiness(generation: token)
        }
    }

    private func pollReadiness(generation expected: UUID) async {
        guard generation == expected, awaitingRadioReady, let transport else { return }
        readinessPollTask = nil
        do { try await transport.write(engine.readyQueryCommand()) }
        catch { await fail(error.localizedDescription) }
    }

    private func fail(_ reason: String) async {
        detectionTask?.cancel(); detectionTask = nil
        beaconTask?.cancel(); beaconTask = nil
        readinessPollTask?.cancel(); readinessPollTask = nil
        state = .failed(reason)
        awaitingRadioReady = false
        lastError = reason
        await publish()
        guard configuration.enabled, configuration.automaticallyReconnects, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.retryAfterFailure()
        }
    }

    private func retryAfterFailure() async {
        reconnectTask = nil
        await transport?.stop()
        transport = nil
        state = .stopped
        await start()
    }

    private func publish() async { await snapshotHandler(makeSnapshot()) }
    private func startBeaconSchedule() {
        beaconTask?.cancel(); beaconTask = nil
        guard let callsign = configuration.beaconCallsign, !callsign.isEmpty,
              let interval = configuration.beaconInterval, interval >= 30 else { return }
        beaconTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.transmitBeacon(Data(callsign.utf8))
            }
        }
    }

    private func transmitBeacon(_ payload: Data) async {
        guard state == .ready else { return }
        do {
            try await send(rawPacket: payload)
            lastBeaconAt = .now
            await publish()
        } catch { lastError = error.localizedDescription; await publish() }
    }
    private func makeSnapshot() -> Snapshot {
        Snapshot(
            id: configuration.id, name: configuration.name, transport: configuration.transport,
            target: configuration.target, state: state, metrics: engine.metrics,
            connectedAt: connectedAt, lastPacketAt: lastPacketAt, lastError: lastError,
            queuedPackets: pendingPackets.count, framebuffer: framebuffer,
            displaySnapshot: displaySnapshot, romSnapshot: romSnapshot,
            lastBeaconAt: lastBeaconAt
        )
    }

    public static func defaultTransport(configuration: RNodeConfiguration) throws -> any RNodeByteTransport {
        switch configuration.transport {
        case .bluetoothLE:
            return RNodeBLETransport(target: configuration.target, restorationIdentifier: "com.supes.MacSideband.rnode.\(configuration.id.uuidString)")
        case .tcp:
            return RNodeTCPTransport(host: configuration.target, port: configuration.tcpPort)
        case .serial:
            #if os(macOS)
            return RNodeSerialTransport(path: configuration.target)
            #else
            throw RNodeError.transport("USB serial RNodes are available in the macOS app; use Bluetooth LE or Wi-Fi on iPhone and iPad.")
            #endif
        case .simulated:
            return SimulatedRNodeTransport()
        }
    }
}

@MainActor @Observable
public final class RNodeManager {
    public private(set) var configurations: [RNodeConfiguration]
    public private(set) var snapshots: [RNodeInterface.Snapshot] = []
    public private(set) var selfTestResult: String?
    public var automaticDiscoveryEnabled: Bool
    private var interfaces: [UUID: RNodeInterface] = [:]
    private var packetHandler: (@Sendable (String, Data) async -> Void)?
    private var stateHandler: (@MainActor @Sendable () -> Void)?
    private let defaults: UserDefaults
    private let configurationsKey = "rnodeConfigurations"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticDiscoveryEnabled = defaults.object(forKey: "rnodeAutomaticDiscovery") as? Bool ?? true
        if let data = defaults.data(forKey: configurationsKey),
           let saved = try? JSONDecoder().decode([RNodeConfiguration].self, from: data) {
            configurations = saved
        } else {
            configurations = []
        }
    }

    public var hasReadyInterface: Bool { snapshots.contains { $0.state == .ready } }
    public var isActive: Bool { snapshots.contains { $0.state != .stopped } }
    public var readyInterfaceIDs: [UUID] { snapshots.filter { $0.state == .ready }.map(\.id) }

    public func setHandlers(
        packet: @escaping @Sendable (String, Data) async -> Void,
        state: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        packetHandler = packet
        stateHandler = state
    }

    public func setAutomaticDiscovery(_ enabled: Bool) {
        automaticDiscoveryEnabled = enabled
        defaults.set(enabled, forKey: "rnodeAutomaticDiscovery")
        if enabled { Task { await startAll() } }
        else if let automatic = configurations.first(where: { $0.name == "Automatic Bluetooth RNode" && $0.target.isEmpty }) {
            Task { await remove(automatic.id) }
        }
    }

    public func upsert(_ configuration: RNodeConfiguration) async throws {
        let validated = try configuration.validated()
        if let index = configurations.firstIndex(where: { $0.id == validated.id }) { configurations[index] = validated }
        else { configurations.append(validated) }
        save()
        if let interface = interfaces[validated.id] { await interface.update(configuration: validated) }
        else if validated.enabled { await start(validated) }
    }

    public func remove(_ id: UUID) async {
        if let interface = interfaces.removeValue(forKey: id) { await interface.stop() }
        configurations.removeAll { $0.id == id }
        snapshots.removeAll { $0.id == id }
        save(); stateHandler?()
    }

    public func startAll() async {
        #if !targetEnvironment(simulator)
        if automaticDiscoveryEnabled,
           !configurations.contains(where: { $0.transport == .bluetoothLE && $0.target.isEmpty }) {
            configurations.append(RNodeConfiguration(name: "Automatic Bluetooth RNode", transport: .bluetoothLE, target: ""))
            save()
        }
        #endif
        for configuration in configurations where configuration.enabled {
            #if targetEnvironment(simulator)
            if configuration.transport == .bluetoothLE { continue }
            #endif
            await start(configuration)
        }
    }

    public func stopAll() async {
        for interface in interfaces.values { await interface.stop() }
        interfaces.removeAll()
        snapshots.removeAll()
        stateHandler?()
    }

    @discardableResult
    public func send(rawPacket: Data) async throws -> [UUID] {
        let readyIDs = snapshots.filter { $0.state == .ready }.map(\.id)
        guard !readyIDs.isEmpty else { throw RNodeError.notConnected }
        var sent: [UUID] = []
        var finalError: Error?
        for id in readyIDs {
            do { try await interfaces[id]?.send(rawPacket: rawPacket); sent.append(id) }
            catch { finalError = error }
        }
        if sent.isEmpty { throw finalError ?? RNodeError.notConnected }
        return sent
    }

    public func send(rawPacket: Data, on id: UUID) async throws {
        guard snapshots.contains(where: { $0.id == id && $0.state == .ready }), let interface = interfaces[id] else {
            throw RNodeError.notConnected
        }
        try await interface.send(rawPacket: rawPacket)
    }

    public func blink(_ id: UUID) async { try? await interfaces[id]?.blink() }
    public func setExternalFramebuffer(_ enabled: Bool, on id: UUID) async throws { try await interfaces[id]?.setExternalFramebuffer(enabled) }
    public func writeFramebuffer(_ data: Data, on id: UUID) async throws { try await interfaces[id]?.writeFramebuffer(data) }
    public func requestFramebuffer(on id: UUID) async throws { try await interfaces[id]?.requestFramebuffer() }
    public func requestDisplaySnapshot(on id: UUID) async throws { try await interfaces[id]?.requestDisplaySnapshot() }
    public func requestROMSnapshot(on id: UUID) async throws { try await interfaces[id]?.requestROMSnapshot() }
    public func enterFirmwareUpdateMode(on id: UUID) async throws { try await interfaces[id]?.enterFirmwareUpdateMode() }
    public func resetHardware(_ id: UUID) async throws { try await interfaces[id]?.resetHardware() }

    /// Runs framing, chunk-boundary, detection, configuration and packet-loopback checks without radio hardware.
    public func runSelfTest() async {
        selfTestResult = "Testing…"
        let configuration = RNodeConfiguration(name: "Self-test", transport: .simulated, target: "simulation")
        let received = RNodeSelfTestCounter()
        let interface = RNodeInterface(configuration: configuration, packetHandler: { raw in await received.record(raw) })
        await interface.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while await interface.snapshot().state != .ready, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        do {
            for sequence in 0..<100 {
                let payload = Data("RNode self-test \(sequence)".utf8) + Data([RNodeKISS.frameEnd, RNodeKISS.frameEscape])
                let packet = Data([0x00, 0x00]) + Data(repeating: UInt8(sequence & 0xFF), count: 16) + Data([0x00]) + payload
                try await interface.send(rawPacket: packet)
            }
            let receiveDeadline = ContinuousClock.now + .seconds(2)
            while await received.count < 100, ContinuousClock.now < receiveDeadline { try? await Task.sleep(for: .milliseconds(20)) }
            let count = await received.count
            selfTestResult = count == 100 ? "Passed — 100/100 protocol loopbacks" : "Failed — received \(count)/100 loopbacks"
        } catch { selfTestResult = "Failed — \(error.localizedDescription)" }
        await interface.stop()
    }

    private func start(_ configuration: RNodeConfiguration) async {
        guard interfaces[configuration.id] == nil else { return }
        let id = configuration.id
        let interface = RNodeInterface(configuration: configuration) { [weak self] raw in
            await self?.packetHandler?("rnode:\(id.uuidString)", raw)
        } snapshotHandler: { [weak self] snapshot in
            await self?.update(snapshot)
        }
        interfaces[id] = interface
        await interface.start()
    }

    private func update(_ snapshot: RNodeInterface.Snapshot) {
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) { snapshots[index] = snapshot }
        else { snapshots.append(snapshot) }
        snapshots.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        stateHandler?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configurations) { defaults.set(data, forKey: configurationsKey) }
    }
}

private actor RNodeSelfTestCounter {
    private(set) var count = 0
    func record(_ data: Data) { count += 1 }
}
