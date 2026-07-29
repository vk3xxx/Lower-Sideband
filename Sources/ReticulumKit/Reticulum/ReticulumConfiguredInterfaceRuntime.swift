import Foundation

/// Owns user-configured Reticulum interfaces and exposes one packet-routing
/// boundary to applications. Transport wire formats and socket lifecycles stay
/// inside ReticulumKit; applications only exchange parsed Reticulum packets.
public actor ReticulumConfiguredInterfaceRuntime {
    public struct Snapshot: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let kind: ReticulumInterfaceKind
        public let mode: ReticulumInterfaceMode
        public let state: State
        public let listener: ListenerDiagnostics?

        public init(
            id: UUID,
            name: String,
            kind: ReticulumInterfaceKind,
            mode: ReticulumInterfaceMode,
            state: State,
            listener: ListenerDiagnostics? = nil
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.mode = mode
            self.state = state
            self.listener = listener
        }
    }

    public struct ListenerDiagnostics: Equatable, Sendable {
        public let host: String
        public let port: UInt16
        public let connectedPeers: [ReticulumTCPServer.Client]
        public let maximumPeers: Int
        public let acceptedPeers: UInt64
        public let rejectedPeers: UInt64
        public let packetsReceived: UInt64
        public let packetsSent: UInt64
        public let bytesReceived: UInt64
        public let bytesSent: UInt64
    }

    public enum State: Equatable, Sendable {
        case starting
        case ready
        case failed(String)
        case stopped
    }

    public static let interfacePrefix = "configured:"

    private let packetHandler: @Sendable (ReticulumPacket, String) async -> Void
    private var snapshots: [UUID: Snapshot] = [:]
    private var tcpClients: [UUID: ReticulumTCPInterface] = [:]
    private var tcpServers: [UUID: ReticulumTCPServer] = [:]
    private var udpListeners: [UUID: ReticulumUDPListener] = [:]
    private var webSocketClients: [UUID: ReticulumWebSocketInterface] = [:]
    private var webSocketServers: [UUID: ReticulumWebSocketServer] = [:]
    private var httpClients: [UUID: ReticulumHTTPInterface] = [:]
    private var httpServers: [UUID: ReticulumHTTPServer] = [:]
    private var i2pInterfaces: [UUID: ReticulumI2PInterface] = [:]
    private var weaveInterfaces: [UUID: ReticulumWeaveInterface] = [:]
#if os(macOS)
    private var serialInterfaces: [UUID: ReticulumSerialPacketInterface] = [:]
    private var pipeInterfaces: [UUID: ReticulumPipeInterface] = [:]
#endif

    public init(
        packetHandler: @escaping @Sendable (ReticulumPacket, String) async -> Void
    ) {
        self.packetHandler = packetHandler
    }

    public func apply(_ profiles: [ReticulumInterfaceProfile]) async {
        await stopAll()
        for profile in profiles where profile.enabled {
            do {
                try await start(profile.validated())
            } catch {
                snapshots[profile.id] = Snapshot(
                    id: profile.id,
                    name: profile.name,
                    kind: profile.kind,
                    mode: profile.mode,
                    state: .failed(error.localizedDescription)
                )
            }
        }
    }

    public func currentSnapshots() async -> [Snapshot] {
        var current = snapshots
        for (id, server) in tcpServers {
            guard let snapshot = current[id] else { continue }
            let metrics = await server.metrics()
            let port: UInt16
            if case .listening(let activePort) = metrics.state { port = activePort }
            else { port = metrics.requestedPort }
            current[id] = Snapshot(
                id: snapshot.id,
                name: snapshot.name,
                kind: snapshot.kind,
                mode: snapshot.mode,
                state: snapshot.state,
                listener: ListenerDiagnostics(
                    host: metrics.listenHost,
                    port: port,
                    connectedPeers: metrics.clients,
                    maximumPeers: metrics.maximumClients,
                    acceptedPeers: metrics.acceptedClients,
                    rejectedPeers: metrics.rejectedClients,
                    packetsReceived: metrics.packetsReceived,
                    packetsSent: metrics.packetsSent,
                    bytesReceived: metrics.bytesReceived,
                    bytesSent: metrics.bytesSent
                )
            )
        }
        return current.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func readyInterfaceIDs() -> [String] {
        snapshots.values.compactMap {
            $0.state == .ready ? Self.interfaceID(for: $0.id) : nil
        }
    }

    public func readyInterfaceDescriptors() -> [ReticulumTransportInterfaceDescriptor] {
        snapshots.values.compactMap {
            guard $0.state == .ready else { return nil }
            return ReticulumTransportInterfaceDescriptor(id: Self.interfaceID(for: $0.id), mode: $0.mode)
        }
    }

    public func send(rawPacket: Data, on interfaceID: String) async throws {
        guard let id = Self.profileID(from: interfaceID) else {
            throw RuntimeError.unknownInterface
        }
        if let interface = tcpClients[id] { try await interface.send(rawPacket: rawPacket); return }
        if let interface = tcpServers[id] { await interface.broadcast(rawPacket); return }
        if let interface = udpListeners[id] { try await interface.broadcast(rawPacket); return }
        if let interface = webSocketClients[id] { try await interface.send(rawPacket: rawPacket); return }
        if let interface = webSocketServers[id] { try await interface.broadcast(rawPacket); return }
        if let interface = httpClients[id] { try await interface.send(rawPacket: rawPacket); return }
        if let interface = httpServers[id] { try await interface.broadcast(rawPacket); return }
        if let interface = i2pInterfaces[id] { try await interface.send(rawPacket: rawPacket); return }
        if let interface = weaveInterfaces[id] { try await interface.send(rawPacket: rawPacket); return }
#if os(macOS)
        if let interface = serialInterfaces[id] { try await interface.send(rawPacket: rawPacket); return }
        if let interface = pipeInterfaces[id] { try await interface.send(rawPacket); return }
#endif
        throw RuntimeError.interfaceNotReady
    }

    /// Sends to every ready configured interface. A failure on one interface
    /// does not prevent healthy independent interfaces from carrying traffic.
    @discardableResult
    public func broadcast(rawPacket: Data) async -> Int {
        var successes = 0
        for interfaceID in readyInterfaceIDs() {
            if (try? await send(rawPacket: rawPacket, on: interfaceID)) != nil {
                successes += 1
            }
        }
        return successes
    }

    public func stopAll() async {
        for interface in tcpClients.values { await interface.stop() }
        for interface in tcpServers.values { await interface.stop() }
        for interface in udpListeners.values { await interface.stop() }
        for interface in webSocketClients.values { await interface.stop() }
        for interface in webSocketServers.values { await interface.stop() }
        for interface in httpClients.values { await interface.stop() }
        for interface in httpServers.values { await interface.stop() }
        for interface in i2pInterfaces.values { await interface.stop() }
        for interface in weaveInterfaces.values { await interface.stop() }
#if os(macOS)
        for interface in serialInterfaces.values { await interface.stop() }
        for interface in pipeInterfaces.values { await interface.stop() }
        serialInterfaces.removeAll()
        pipeInterfaces.removeAll()
#endif
        tcpClients.removeAll(); tcpServers.removeAll(); udpListeners.removeAll()
        webSocketClients.removeAll(); webSocketServers.removeAll()
        httpClients.removeAll(); httpServers.removeAll(); i2pInterfaces.removeAll(); weaveInterfaces.removeAll()
        snapshots = snapshots.mapValues {
            Snapshot(id: $0.id, name: $0.name, kind: $0.kind, mode: $0.mode, state: .stopped)
        }
    }

    public static func interfaceID(for profileID: UUID) -> String {
        interfacePrefix + profileID.uuidString.lowercased()
    }

    public static func profileID(from interfaceID: String) -> UUID? {
        guard interfaceID.hasPrefix(interfacePrefix) else { return nil }
        return UUID(uuidString: String(interfaceID.dropFirst(interfacePrefix.count)))
    }

    private func start(_ profile: ReticulumInterfaceProfile) async throws {
        let id = profile.id
        let interfaceID = Self.interfaceID(for: id)
        let ifac = try profile.makeIFAC()
        snapshots[id] = Snapshot(id: id, name: profile.name, kind: profile.kind, mode: profile.mode, state: .starting)
        let receive: @Sendable (ReticulumPacket) async -> Void = { [packetHandler] packet in
            await packetHandler(packet, interfaceID)
        }

        switch profile.kind {
        case .tcpClient, .backboneClient:
            let interface = ReticulumTCPInterface(
                host: profile.host!,
                port: profile.port!,
                ifac: ifac,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setTCPState(state, profile: profile)
                }
            )
            tcpClients[id] = interface
            await interface.start()
        case .tcpServer, .backboneServer:
            let interface = ReticulumTCPServer(
                listenHost: profile.listenHost ?? "0.0.0.0",
                port: profile.port!,
                maximumClients: profile.maximumClients ?? 64,
                ifac: ifac,
                packetHandler: receive
            )
            tcpServers[id] = interface
            try await interface.start()
            setReady(profile)
        case .udp:
            let configuration = try ReticulumUDPListenerConfiguration(
                listenHost: profile.listenHost ?? "0.0.0.0",
                listenPort: profile.port!,
                forwardHost: profile.forwardHost,
                forwardPort: profile.forwardPort,
                allowBroadcast: profile.forwardHost == "255.255.255.255"
            ).validated()
            let interface = try ReticulumUDPListener(
                configuration: configuration,
                ifac: ifac,
                packetHandler: { [packetHandler] _, packet in await packetHandler(packet, interfaceID) }
            )
            udpListeners[id] = interface
            try await interface.start()
            setReady(profile)
        case .webSocketClient:
            let interface = ReticulumWebSocketInterface(
                url: profile.url!,
                ifac: ifac,
                reconnect: profile.reconnect,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setWebSocketState(state, profile: profile)
                }
            )
            webSocketClients[id] = interface
            await interface.start()
        case .webSocketServer:
            let interface = ReticulumWebSocketServer(
                port: profile.port!,
                path: profile.url?.path.isEmpty == false ? profile.url!.path : "/",
                ifac: ifac,
                packetHandler: { [packetHandler] _, packet in await packetHandler(packet, interfaceID) }
            )
            webSocketServers[id] = interface
            try await interface.start()
            setReady(profile)
        case .httpClient:
            let interface = ReticulumHTTPInterface(
                url: profile.url!,
                pollInterval: profile.pollInterval,
                mtu: profile.fixedMTU ?? ReticulumHTTPInterface.defaultMTU,
                ifac: ifac,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setHTTPState(state, profile: profile)
                }
            )
            httpClients[id] = interface
            await interface.start()
        case .httpServer:
            let interface = ReticulumHTTPServer(
                port: profile.port!,
                path: profile.url?.path.isEmpty == false ? profile.url!.path : "/",
                mtu: profile.fixedMTU ?? ReticulumHTTPInterface.defaultMTU,
                ifac: ifac,
                packetHandler: { [packetHandler] _, packet in await packetHandler(packet, interfaceID) }
            )
            httpServers[id] = interface
            try await interface.start()
            setReady(profile)
        case .i2p:
            let interface = ReticulumI2PInterface(
                configuration: ReticulumI2PConfiguration(
                    samHost: profile.samHost ?? "127.0.0.1",
                    samPort: profile.samPort ?? 7_656,
                    sessionID: profile.sessionID ?? "lower-sideband-\(profile.id.uuidString.lowercased())",
                    role: .connect(destination: profile.host!),
                    timeout: profile.connectTimeout,
                    reconnect: profile.reconnect
                ),
                ifac: ifac,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setTCPState(state, profile: profile)
                }
            )
            i2pInterfaces[id] = interface
            await interface.start()
        case .weave:
            let interface = try ReticulumWeaveInterface(
                configuration: ReticulumWeaveConfiguration(
                    host: profile.host!,
                    port: profile.port!,
                    switchID: profile.switchID!,
                    localEndpointID: profile.localEndpointID!,
                    remoteEndpointID: profile.remoteEndpointID,
                    reconnect: profile.reconnect
                ),
                ifac: ifac,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setWeaveState(state, profile: profile)
                }
            )
            weaveInterfaces[id] = interface
            await interface.start()
        case .serial, .kiss, .ax25Kiss:
#if os(macOS)
            var configuration = KISSModemConfiguration()
            configuration.name = profile.name
            configuration.serialPath = profile.device!
            configuration.baudRate = profile.bitrate ?? 115_200
            configuration.port = profile.kissPort ?? 0
            configuration.framing = profile.kind == .serial ? .hdlc : (profile.kind == .ax25Kiss ? .ax25Kiss : .kiss)
            configuration.callsign = profile.callsign ?? ""
            configuration.ssid = profile.ssid ?? 0
            configuration.flowControl = profile.flowControl ?? false
            configuration.ifacNetworkName = profile.networkName
            configuration.ifacPassphrase = profile.passphrase
            configuration.ifacSize = profile.ifacSize
            let interface = try ReticulumSerialPacketInterface(
                configuration: configuration,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setSerialState(state, profile: profile)
                }
            )
            serialInterfaces[id] = interface
            await interface.start()
#else
            throw RuntimeError.unsupportedOnPlatform
#endif
        case .pipe:
#if os(macOS)
            let interface = ReticulumPipeInterface(
                executableURL: URL(fileURLWithPath: profile.device!),
                arguments: profile.pipeArguments ?? [],
                environment: profile.pipeEnvironment ?? [:],
                reconnect: profile.reconnect,
                packetHandler: receive,
                stateHandler: { [weak self] state in
                    await self?.setPipeState(state, profile: profile)
                }
            )
            pipeInterfaces[id] = interface
            try await interface.start()
#else
            throw RuntimeError.unsupportedOnPlatform
#endif
        case .auto, .rnode, .rnodeMulti:
            // These lifecycles are owned by dedicated ReticulumKit managers.
            throw RuntimeError.managedByDedicatedRuntime
        }
    }

    private func setReady(_ profile: ReticulumInterfaceProfile) {
        snapshots[profile.id] = Snapshot(
            id: profile.id, name: profile.name, kind: profile.kind, mode: profile.mode, state: .ready
        )
    }

    private func setTCPState(_ state: ReticulumTCPInterface.State, profile: ReticulumInterfaceProfile) {
        switch state {
        case .ready: setReady(profile)
        case .connecting: setState(.starting, profile: profile)
        case .failed(let reason): setState(.failed(reason), profile: profile)
        case .stopped: setState(.stopped, profile: profile)
        }
    }

    private func setWebSocketState(_ state: ReticulumWebSocketInterface.State, profile: ReticulumInterfaceProfile) {
        switch state {
        case .ready: setReady(profile)
        case .connecting: setState(.starting, profile: profile)
        case .failed(let reason): setState(.failed(reason), profile: profile)
        case .stopped: setState(.stopped, profile: profile)
        }
    }

    private func setHTTPState(_ state: ReticulumHTTPInterface.State, profile: ReticulumInterfaceProfile) {
        switch state {
        case .ready: setReady(profile)
        case .connecting: setState(.starting, profile: profile)
        case .failed(let reason): setState(.failed(reason), profile: profile)
        case .stopped: setState(.stopped, profile: profile)
        }
    }

    private func setWeaveState(_ state: ReticulumWeaveInterface.State, profile: ReticulumInterfaceProfile) {
        switch state {
        case .ready: setReady(profile)
        case .connecting, .discovering: setState(.starting, profile: profile)
        case .failed(let reason): setState(.failed(reason), profile: profile)
        case .stopped: setState(.stopped, profile: profile)
        }
    }

#if os(macOS)
    private func setSerialState(_ state: ReticulumSerialPacketInterface.State, profile: ReticulumInterfaceProfile) {
        switch state {
        case .ready: setReady(profile)
        case .connecting: setState(.starting, profile: profile)
        case .failed(let reason): setState(.failed(reason), profile: profile)
        case .stopped: setState(.stopped, profile: profile)
        }
    }

    private func setPipeState(_ state: ReticulumPipeInterface.State, profile: ReticulumInterfaceProfile) {
        switch state {
        case .ready: setReady(profile)
        case .connecting: setState(.starting, profile: profile)
        case .failed(let reason): setState(.failed(reason), profile: profile)
        case .stopped: setState(.stopped, profile: profile)
        }
    }
#endif

    private func setState(_ state: State, profile: ReticulumInterfaceProfile) {
        snapshots[profile.id] = Snapshot(
            id: profile.id, name: profile.name, kind: profile.kind, mode: profile.mode, state: state
        )
    }

    public enum RuntimeError: Swift.Error {
        case unknownInterface
        case interfaceNotReady
        case unsupportedOnPlatform
        case managedByDedicatedRuntime
    }
}
