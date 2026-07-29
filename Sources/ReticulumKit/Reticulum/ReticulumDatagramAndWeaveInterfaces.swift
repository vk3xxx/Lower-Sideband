import Foundation
import Network

public struct ReticulumUDPListenerConfiguration: Codable, Hashable, Sendable {
    public var listenHost: String
    public var listenPort: UInt16
    public var forwardHost: String?
    public var forwardPort: UInt16?
    public var allowBroadcast: Bool

    public init(
        listenHost: String = "0.0.0.0",
        listenPort: UInt16 = 4_242,
        forwardHost: String? = nil,
        forwardPort: UInt16? = nil,
        allowBroadcast: Bool = false
    ) {
        self.listenHost = listenHost; self.listenPort = listenPort
        self.forwardHost = forwardHost; self.forwardPort = forwardPort
        self.allowBroadcast = allowBroadcast
    }

    public func validated() throws -> Self {
        guard !listenHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidListener
        }
        if forwardHost?.isEmpty == false {
            guard let forwardPort, forwardPort > 0 else { throw ValidationError.invalidForwarder }
        }
        return self
    }
    public enum ValidationError: Swift.Error { case invalidListener, invalidForwarder }
}

/// A bidirectional UDP listener with independent peer connections and an
/// optional Reticulum-compatible forward/broadcast destination.
public actor ReticulumUDPListener {
    public enum State: Equatable, Sendable { case stopped, listening(UInt16), failed(String) }
    public private(set) var state: State = .stopped
    public private(set) var peerCount = 0

    private let configuration: ReticulumUDPListenerConfiguration
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (String, ReticulumPacket) async -> Void
    private let queue = DispatchQueue(label: "reticulum.udp-listener")
    private var listener: NWListener?
    private var peers: [String: NWConnection] = [:]
    private var forwarder: NWConnection?

    public init(
        configuration: ReticulumUDPListenerConfiguration,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (String, ReticulumPacket) async -> Void
    ) throws {
        self.configuration = try configuration.validated()
        self.ifac = ifac; self.packetHandler = packetHandler
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.listenHost),
            port: NWEndpoint.Port(rawValue: configuration.listenPort)!
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] value in Task { await self?.listenerChanged(value) } }
        listener.start(queue: queue)

        if let host = configuration.forwardHost, let port = configuration.forwardPort {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            if configuration.allowBroadcast {
                parameters.prohibitedInterfaceTypes = []
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: parameters
            )
            forwarder = connection
            connection.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        peers.values.forEach { $0.cancel() }; peers.removeAll()
        forwarder?.cancel(); forwarder = nil
        peerCount = 0; state = .stopped
    }

    public func broadcast(_ rawPacket: Data, excluding excludedPeerID: String? = nil) throws {
        let payload = try ifac?.protect(rawPacket) ?? rawPacket
        for (id, peer) in peers where id != excludedPeerID {
            peer.send(content: payload, completion: .idempotent)
        }
        forwarder?.send(content: payload, completion: .idempotent)
    }

    public func send(_ rawPacket: Data, to peerID: String) throws {
        guard let peer = peers[peerID] else { throw InterfaceError.unknownPeer }
        peer.send(content: try ifac?.protect(rawPacket) ?? rawPacket, completion: .idempotent)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID().uuidString
        peers[id] = connection; peerCount = peers.count
        connection.stateUpdateHandler = { [weak self] value in
            if case .failed = value { Task { await self?.remove(id) } }
            if case .cancelled = value { Task { await self?.remove(id) } }
        }
        connection.start(queue: queue)
        receive(connection, id: id)
    }
    private func receive(_ connection: NWConnection, id: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task {
                guard let self else { return }
                if let data,
                   let raw = try? await self.unprotect(data),
                   let packet = try? ReticulumPacket(raw: raw) {
                    await self.packetHandler(id, packet)
                }
                if error == nil { await self.receive(connection, id: id) }
                else { await self.remove(id) }
            }
        }
    }
    private func unprotect(_ data: Data) throws -> Data { try ifac?.unprotect(data) ?? data }
    private func remove(_ id: String) { peers.removeValue(forKey: id)?.cancel(); peerCount = peers.count }
    private func listenerChanged(_ value: NWListener.State) {
        switch value {
        case .ready: state = .listening(listener?.port?.rawValue ?? configuration.listenPort)
        case let .failed(error): state = .failed(error.localizedDescription)
        case .cancelled: state = .stopped
        default: break
        }
    }
    public enum InterfaceError: Swift.Error { case unknownPeer }
}

public struct ReticulumWeaveConfiguration: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var switchID: Data
    public var localEndpointID: Data
    public var remoteEndpointID: Data?
    public var reconnect: Bool

    public init(
        host: String,
        port: UInt16,
        switchID: Data,
        localEndpointID: Data,
        remoteEndpointID: Data? = nil,
        reconnect: Bool = true
    ) {
        self.host = host; self.port = port; self.switchID = switchID
        self.localEndpointID = localEndpointID; self.remoteEndpointID = remoteEndpointID
        self.reconnect = reconnect
    }
    public func validated() throws -> Self {
        guard !host.isEmpty, port > 0, switchID.count == 4, localEndpointID.count == 16,
              remoteEndpointID == nil || remoteEndpointID?.count == 16 else {
            throw ValidationError.invalidConfiguration
        }
        return self
    }
    public enum ValidationError: Swift.Error { case invalidConfiguration }
}

/// Complete Weave endpoint lifecycle over a TCP Device Control Link.
/// Control frames are HDLC-delimited and endpoint packets are bounded before
/// Reticulum parsing.
public actor ReticulumWeaveInterface {
    public enum State: Equatable, Sendable { case stopped, connecting, discovering, ready, failed(String) }
    public private(set) var state: State = .stopped
    public private(set) var remoteEndpointID: Data?

    private let configuration: ReticulumWeaveConfiguration
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void
    private let queue = DispatchQueue(label: "reticulum.weave")
    private var connection: NWConnection?
    private var decoder = HDLCDecoder(maximumFrameSize: 65_535)
    private var stopped = true
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    public init(
        configuration: ReticulumWeaveConfiguration,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) throws {
        self.configuration = try configuration.validated()
        self.remoteEndpointID = configuration.remoteEndpointID
        self.ifac = ifac; self.packetHandler = packetHandler; self.stateHandler = stateHandler
    }

    public func start() async {
        guard connection == nil else { return }
        stopped = false
        await connect()
    }
    public func stop() async {
        stopped = true; reconnectTask?.cancel(); reconnectTask = nil
        connection?.cancel(); connection = nil; decoder = HDLCDecoder(maximumFrameSize: 65_535)
        await setState(.stopped)
    }
    public func send(rawPacket: Data) async throws {
        guard let connection, state == .ready, let remoteEndpointID else { throw InterfaceError.notConnected }
        let raw = try ifac?.protect(rawPacket) ?? rawPacket
        let command = try ReticulumWeave.endpointCommand(endpointID: remoteEndpointID, packet: raw)
        let frame = try ReticulumWeave.frame(switchID: configuration.switchID, type: .command, payload: command)
        connection.send(content: frame, completion: .idempotent)
    }

    private func connect() async {
        guard !stopped else { return }
        await setState(.connecting)
        let options = NWProtocolTCP.Options(); options.noDelay = true; options.enableKeepalive = true
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port)!,
            using: NWParameters(tls: nil, tcp: options)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] value in Task { await self?.connectionChanged(value, connection: connection) } }
        connection.start(queue: queue)
        receive(connection)
    }

    private func connectionChanged(_ value: NWConnection.State, connection current: NWConnection) async {
        guard connection === current else { return }
        switch value {
        case .ready:
            reconnectAttempt = 0
            await setState(.discovering)
            let discover = try? ReticulumWeave.frame(switchID: ReticulumWeave.broadcastSwitchID, type: .discover, payload: configuration.localEndpointID)
            if let discover { current.send(content: discover, completion: .idempotent) }
            if remoteEndpointID != nil { await setState(.ready) }
        case let .failed(error): await failed(error.localizedDescription)
        case .cancelled where !stopped: await failed("Weave connection closed.")
        default: break
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data { await self.consume(data) }
                if complete || error != nil { await self.failed(error?.localizedDescription ?? "Weave connection closed.") }
                else { await self.receive(connection) }
            }
        }
    }
    private func consume(_ data: Data) async {
        for rawFrame in decoder.consume(data) {
            guard let frame = try? ReticulumWeave.decode(rawFrame),
                  frame.switchID == configuration.switchID || frame.switchID == ReticulumWeave.broadcastSwitchID else { continue }
            switch frame.type {
            case .discover, .connect:
                guard frame.payload.count >= 16 else { continue }
                remoteEndpointID = Data(frame.payload.prefix(16))
                await setState(.ready)
            case .endpointPacket:
                await consumeEndpointPayload(frame.payload)
            case .command:
                guard frame.payload.count >= 18, frame.payload.prefix(2) == Data([0, 1]) else { continue }
                await consumeEndpointPayload(Data(frame.payload.dropFirst(2)))
            default: continue
            }
        }
    }
    private func consumeEndpointPayload(_ payload: Data) async {
        guard payload.count > 16 else { return }
        let destination = Data(payload.prefix(16))
        guard destination == configuration.localEndpointID else { return }
        let protected = Data(payload.dropFirst(16))
        guard let raw = try? ifac?.unprotect(protected) ?? protected,
              let packet = try? ReticulumPacket(raw: raw) else { return }
        await packetHandler(packet)
    }
    private func failed(_ reason: String) async {
        connection?.cancel(); connection = nil
        await setState(.failed(reason))
        guard configuration.reconnect, !stopped, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(60, 1 << min(reconnectAttempt, 5))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.resumeReconnect()
        }
    }
    private func resumeReconnect() async { reconnectTask = nil; await connect() }
    private func setState(_ value: State) async { guard state != value else { return }; state = value; await stateHandler(value) }
    public enum InterfaceError: Swift.Error { case notConnected }
}
