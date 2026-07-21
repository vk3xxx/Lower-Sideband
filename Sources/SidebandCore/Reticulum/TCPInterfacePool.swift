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
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
        public let host: String?
        public let port: UInt16?
        public let isBootstrap: Bool
        public let interfaceMode: ReticulumInterfaceMode
        public let ifac: ReticulumIFAC?

        public init(id: String, name: String, host: String, port: UInt16, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            self.endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            self.host = host
            self.port = port
            self.isBootstrap = isBootstrap
            self.interfaceMode = interfaceMode
            self.ifac = ifac
        }

        public init(id: String, name: String, endpoint: NWEndpoint, isBootstrap: Bool = false, interfaceMode: ReticulumInterfaceMode = .full, ifac: ReticulumIFAC? = nil) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
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
        let interface: ReticulumTCPInterface
        var state: ReticulumTCPInterface.State = .stopped
        var connectedAt: Date?
        var lastPacketAt: Date?
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
        entries[interfaceID] = entry
        await packetHandler(interfaceID, packet)
    }

    private func stateChanged(_ state: ReticulumTCPInterface.State, on interfaceID: String) async {
        guard var entry = entries[interfaceID] else { return }
        entry.state = state
        if state == .ready { entry.connectedAt = .now }
        entries[interfaceID] = entry
        let bootstrapInterfaces = entries.values
            .filter { $0.endpoint.isBootstrap }
            .map(\.interface)
        let shouldShedBootstrap = entries.values.count {
            !$0.endpoint.isBootstrap && $0.state == .ready
        } >= 2
        if shouldShedBootstrap {
            entries = entries.filter { !$0.value.endpoint.isBootstrap }
        }
        await publishState(force: true)
        if shouldShedBootstrap {
            for interface in bootstrapInterfaces { await interface.stop() }
        }
    }

    private func insert(_ endpoint: Endpoint) {
        let interface = ReticulumTCPInterface(endpoint: endpoint.endpoint, ifac: endpoint.ifac) { [weak self] packet in
            await self?.received(packet, on: endpoint.id)
        } stateHandler: { [weak self] state in
            await self?.stateChanged(state, on: endpoint.id)
        }
        entries[endpoint.id] = Entry(endpoint: endpoint, interface: interface, state: .connecting)
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
