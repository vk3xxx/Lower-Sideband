import Foundation
import Network

/// Keeps several Reticulum TCP entrypoints live at the same time.
///
/// Public Reticulum entrypoints are not guaranteed to share a topology. A
/// client that serially selects one entrypoint can therefore be TCP-connected
/// while still being unable to resolve a peer. The pool lets the routing layer
/// discover and use paths on every healthy entrypoint concurrently.
public actor ReticulumTCPInterfacePool {
    public struct Endpoint: Identifiable, @unchecked Sendable {
        public enum Transport: @unchecked Sendable {
            case tcp(NWEndpoint)
            case backbone(NWEndpoint, ReticulumBackboneTransportIdentity?)
            case i2p(ReticulumI2PConfiguration)
            case webSocket(URL)
            case http(URL, pollInterval: TimeInterval, mtu: Int)
        }

        public let id: String
        public let name: String
        public let transport: Transport
        public let host: String?
        public let port: UInt16?
        public let isBootstrap: Bool
        public let interfaceMode: ReticulumInterfaceMode
        public let ifac: ReticulumIFAC?

        public init(id: String, name: String, host: String, port: UInt16, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            transport = .tcp(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
            self.host = host
            self.port = port
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }

        public init(id: String, name: String, endpoint: NWEndpoint, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            transport = .tcp(endpoint)
            if case let .hostPort(host, port) = endpoint {
                self.host = "\(host)"
                self.port = port.rawValue
            } else {
                self.host = nil
                self.port = nil
            }
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }

        public init(id: String, name: String, backboneEndpoint: NWEndpoint, transportIdentity: ReticulumBackboneTransportIdentity? = nil, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            transport = .backbone(backboneEndpoint, transportIdentity)
            if case let .hostPort(host, port) = backboneEndpoint {
                self.host = "\(host)"
                self.port = port.rawValue
            } else {
                self.host = nil
                self.port = nil
            }
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }

        public init(id: String, name: String, i2pConfiguration: ReticulumI2PConfiguration, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            transport = .i2p(i2pConfiguration)
            host = i2pConfiguration.samHost
            port = i2pConfiguration.samPort
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }

        public init(id: String, name: String, webSocketURL: URL, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            transport = .webSocket(webSocketURL)
            host = webSocketURL.host
            port = webSocketURL.port.flatMap(UInt16.init(exactly:))
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }

        public init(id: String, name: String, httpURL: URL, pollInterval: TimeInterval = 0.1, mtu: Int = ReticulumHTTPInterface.defaultMTU, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            transport = .http(httpURL, pollInterval: pollInterval, mtu: mtu)
            host = httpURL.host
            port = httpURL.port.flatMap(UInt16.init(exactly:))
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }
    }

    public struct Snapshot: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let host: String?
        public let port: UInt16?
        public let state: ReticulumTCPInterface.State
        public let connectedAt: Date?
        public let lastPacketAt: Date?
        public let isBootstrap: Bool
    }

    public enum PoolError: Error { case noReadyInterfaces }

    private struct Entry {
        let endpoint: Endpoint
        let interface: InterfaceDriver
        var state: ReticulumTCPInterface.State = .stopped
        var connectedAt: Date?
        var lastPacketAt: Date?
        var reconnectAttempt = 0
        var reconnectToken: UUID?
    }

    private enum InterfaceDriver {
        case tcp(ReticulumTCPInterface)
        case backbone(ReticulumBackboneClient)
        case i2p(ReticulumI2PInterface)
        case webSocket(ReticulumWebSocketInterface)
        case http(ReticulumHTTPInterface)

        func start() async {
            switch self {
            case let .tcp(interface): await interface.start()
            case let .backbone(interface): await interface.start()
            case let .i2p(interface): await interface.start()
            case let .webSocket(interface): await interface.start()
            case let .http(interface): await interface.start()
            }
        }

        func stop() async {
            switch self {
            case let .tcp(interface): await interface.stop()
            case let .backbone(interface): await interface.stop()
            case let .i2p(interface): await interface.stop()
            case let .webSocket(interface): await interface.stop()
            case let .http(interface): await interface.stop()
            }
        }

        func send(rawPacket: Data) async throws {
            switch self {
            case let .tcp(interface):
                try await interface.send(rawPacket: rawPacket)
            case let .backbone(interface):
                try await interface.send(rawPacket: rawPacket)
            case let .i2p(interface):
                try await interface.send(rawPacket: rawPacket)
            case let .webSocket(interface):
                try await interface.send(rawPacket: rawPacket)
            case let .http(interface):
                try await interface.send(rawPacket: rawPacket)
            }
        }
    }

    private var entries: [String: Entry] = [:]
    private var aggregateState: ReticulumTCPInterface.State = .stopped
    private let packetHandler: @Sendable (String, ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (ReticulumTCPInterface.State, [Snapshot]) async -> Void

    public init(
        packetHandler: @escaping @Sendable (String, ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (ReticulumTCPInterface.State, [Snapshot]) async -> Void = { _, _ in }
    ) {
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
    }

    public func start(_ endpoints: [Endpoint]) async {
        await stop()
        guard !endpoints.isEmpty else { return }

        for endpoint in endpoints { insert(endpoint) }
        await publishState(force: true)
        for entry in entries.values { await entry.interface.start() }
    }

    /// Adds an authenticated interface discovered through Reticulum without
    /// interrupting any existing paths or in-flight packets.
    public func add(_ endpoint: Endpoint) async {
        guard entries[endpoint.id] == nil else { return }
        insert(endpoint)
        await publishState(force: true)
        await entries[endpoint.id]?.interface.start()
    }

    public func stop() async {
        let interfaces = entries.values.map(\.interface)
        entries.removeAll()
        for interface in interfaces { await interface.stop() }
        aggregateState = .stopped
        await stateHandler(.stopped, [])
    }

    public func readyInterfaceIDs() -> [String] {
        entries.values.filter { $0.state == .ready }.map(\.endpoint.id).sorted()
    }

    public func snapshots() -> [Snapshot] { makeSnapshots() }

    public func send(rawPacket: Data, on interfaceID: String) async throws {
        guard let entry = entries[interfaceID], entry.state == .ready else { throw PoolError.noReadyInterfaces }
        try await entry.interface.send(rawPacket: rawPacket)
    }

    /// Broadcasts maintenance and discovery packets to every live reticule.
    /// Success on any interface counts as success; failed siblings remain
    /// available for their own reconnect/health state transitions.
    @discardableResult
    public func send(rawPacket: Data) async throws -> [String] {
        let ready = entries.values.filter { $0.state == .ready }
        guard !ready.isEmpty else { throw PoolError.noReadyInterfaces }
        var sent: [String] = []
        var finalError: Error?
        for entry in ready {
            do {
                try await entry.interface.send(rawPacket: rawPacket)
                sent.append(entry.endpoint.id)
            } catch {
                finalError = error
            }
        }
        if sent.isEmpty { throw finalError ?? PoolError.noReadyInterfaces }
        return sent
    }

    private func received(_ packet: ReticulumPacket, on interfaceID: String) async {
        guard var entry = entries[interfaceID] else { return }
        entry.lastPacketAt = .now
        // Receiving a valid Reticulum packet proves that this connection is
        // genuinely useful, so a later retry may start from the short delay.
        // Merely reaching TCP `ready` is insufficient: overloaded or
        // rate-limiting gateways can accept and immediately reset clients.
        entry.reconnectAttempt = 0
        entries[interfaceID] = entry
        await packetHandler(interfaceID, packet)
    }

    private func stateChanged(_ state: ReticulumTCPInterface.State, on interfaceID: String) async {
        guard var entry = entries[interfaceID] else { return }
        entry.state = state
        if state == .ready {
            entry.connectedAt = .now
            entry.reconnectToken = nil
        } else if state.needsReconnect, entry.reconnectToken == nil {
            entry.reconnectAttempt += 1
            let token = UUID()
            entry.reconnectToken = token
            let delay = Self.reconnectDelay(attempt: entry.reconnectAttempt)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.restart(interfaceID: interfaceID, token: token)
            }
        }
        entries[interfaceID] = entry
        await publishState(force: true)
    }

    /// Restarts a failed member without disturbing healthy sibling sockets.
    /// Remote Reticulum peers may keep a path bound to any interface on which
    /// we announced, so silently abandoning one member can make an otherwise
    /// "ready" client unreachable until that remote path expires.
    private func restart(interfaceID: String, token: UUID) async {
        guard var entry = entries[interfaceID], entry.reconnectToken == token,
              entry.state.needsReconnect else { return }
        entry.reconnectToken = nil
        entry.state = .connecting
        entries[interfaceID] = entry
        await publishState(force: true)
        await entry.interface.start()
    }

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        TimeInterval(min(60, 1 << min(max(1, attempt), 5)))
    }

    private func insert(_ endpoint: Endpoint) {
        let interface: InterfaceDriver
        switch endpoint.transport {
        case let .tcp(networkEndpoint):
            interface = .tcp(ReticulumTCPInterface(endpoint: networkEndpoint, ifac: endpoint.ifac) { [weak self] packet in
                await self?.received(packet, on: endpoint.id)
            } stateHandler: { [weak self] state in
                await self?.stateChanged(state, on: endpoint.id)
            })
        case let .backbone(networkEndpoint, transportIdentity):
            interface = .backbone(ReticulumBackboneClient(
                endpoint: networkEndpoint,
                transportIdentity: transportIdentity,
                ifac: endpoint.ifac
            ) { [weak self] packet in
                await self?.received(packet, on: endpoint.id)
            } stateHandler: { [weak self] state in
                await self?.stateChanged(state, on: endpoint.id)
            })
        case let .i2p(configuration):
            interface = .i2p(ReticulumI2PInterface(
                configuration: configuration,
                ifac: endpoint.ifac
            ) { [weak self] packet in
                await self?.received(packet, on: endpoint.id)
            } stateHandler: { [weak self] state in
                await self?.stateChanged(state, on: endpoint.id)
            })
        case let .webSocket(url):
            interface = .webSocket(ReticulumWebSocketInterface(url: url, ifac: endpoint.ifac) { [weak self] packet in
                await self?.received(packet, on: endpoint.id)
            } stateHandler: { [weak self] state in
                await self?.stateChanged(Self.poolState(state), on: endpoint.id)
            })
        case let .http(url, pollInterval, mtu):
            interface = .http(ReticulumHTTPInterface(url: url, pollInterval: pollInterval, mtu: mtu, ifac: endpoint.ifac) { [weak self] packet in
                await self?.received(packet, on: endpoint.id)
            } stateHandler: { [weak self] state in
                await self?.stateChanged(Self.poolState(state), on: endpoint.id)
            })
        }
        entries[endpoint.id] = Entry(endpoint: endpoint, interface: interface, state: .connecting)
    }

    private static func poolState(_ state: ReticulumWebSocketInterface.State) -> ReticulumTCPInterface.State {
        switch state {
        case .stopped: .stopped
        case .connecting: .connecting
        case .ready: .ready
        case let .failed(reason): .failed(reason)
        }
    }

    private static func poolState(_ state: ReticulumHTTPInterface.State) -> ReticulumTCPInterface.State {
        switch state {
        case .stopped: .stopped
        case .connecting: .connecting
        case .ready: .ready
        case let .failed(reason): .failed(reason)
        }
    }

    private func publishState(force: Bool = false) async {
        let next: ReticulumTCPInterface.State
        if entries.values.contains(where: { $0.state == .ready }) {
            next = .ready
        } else if entries.values.contains(where: { $0.state == .connecting }) {
            next = .connecting
        } else if let failure = entries.values.compactMap({ entry -> String? in
            if case let .failed(reason) = entry.state { return reason }
            return nil
        }).first {
            next = .failed(failure)
        } else {
            next = .stopped
        }
        guard force || next != aggregateState else { return }
        aggregateState = next
        await stateHandler(next, makeSnapshots())
    }

    private func makeSnapshots() -> [Snapshot] {
        entries.values.map {
            Snapshot(
                id: $0.endpoint.id,
                name: $0.endpoint.name,
                host: $0.endpoint.host,
                port: $0.endpoint.port,
                state: $0.state,
                connectedAt: $0.connectedAt,
                lastPacketAt: $0.lastPacketAt,
                isBootstrap: $0.endpoint.isBootstrap
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private extension ReticulumTCPInterface.State {
    var needsReconnect: Bool {
        switch self {
        case .failed, .stopped: true
        case .connecting, .ready: false
        }
    }
}
