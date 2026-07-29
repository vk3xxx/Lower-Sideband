import Foundation
import Network

/// The identity attached to a discovered Backbone interface. Reticulum
/// Backbone sockets deliberately remain wire-compatible with TCPInterface;
/// this identity authenticates discovery and tunnel ownership, not a private
/// socket handshake.
public struct ReticulumBackboneTransportIdentity: Hashable, Sendable {
    public static let byteCount = 16
    public let hash: Data

    public init(hash: Data) throws {
        guard hash.count == Self.byteCount else {
            throw ReticulumBackboneError.invalidTransportIdentity
        }
        self.hash = hash
    }

    public init(hex: String) throws {
        guard let data = Data(hexString: hex) else {
            throw ReticulumBackboneError.invalidTransportIdentity
        }
        try self.init(hash: data)
    }
}

public enum ReticulumBackboneError: LocalizedError, Equatable, Sendable {
    case invalidTransportIdentity
    case notListening
    case unknownPeer

    public var errorDescription: String? {
        switch self {
        case .invalidTransportIdentity: "Backbone transport identities must be 16 bytes."
        case .notListening: "The Backbone listener is not running."
        case .unknownPeer: "The Backbone peer is no longer connected."
        }
    }
}

/// Backbone client using the reference wire format: TCP + HDLC + optional IFAC.
public actor ReticulumBackboneClient {
    public typealias State = ReticulumTCPInterface.State
    public let transportIdentity: ReticulumBackboneTransportIdentity?
    private let interface: ReticulumTCPInterface

    public init(
        endpoint: NWEndpoint,
        transportIdentity: ReticulumBackboneTransportIdentity? = nil,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.transportIdentity = transportIdentity
        interface = ReticulumTCPInterface(
            endpoint: endpoint,
            ifac: ifac,
            packetHandler: packetHandler,
            stateHandler: stateHandler
        )
    }

    public func start() async { await interface.start() }
    public func stop() async { await interface.stop() }
    public func send(rawPacket: Data) async throws { try await interface.send(rawPacket: rawPacket) }
    public func state() async -> State { await interface.state }
}

/// Multi-client Backbone listener. Every accepted socket is an independent
/// Reticulum interface, matching the reference implementation's spawned
/// interface semantics and preventing one peer's decoder/state from affecting
/// another.
public actor ReticulumBackboneListener {
    public struct Peer: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let endpointDescription: String
        public let connectedAt: Date
    }

    public enum State: Equatable, Sendable {
        case stopped
        case listening(UInt16)
        case failed(String)
    }

    private struct Client {
        let peer: Peer
        let connection: NWConnection
        var decoder = HDLCDecoder()
    }

    public private(set) var state: State = .stopped
    private let requestedPort: UInt16
    private let ifac: ReticulumIFAC?
    private let queue = DispatchQueue(label: "sideband.reticulum.backbone-listener")
    private let packetHandler: @Sendable (Peer, ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State, [Peer]) async -> Void
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]

    public init(
        port: UInt16,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (Peer, ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State, [Peer]) async -> Void = { _, _ in }
    ) {
        requestedPort = port
        self.ifac = ifac
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
    }

    public func start() async throws {
        guard listener == nil else { return }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        options.keepaliveIdle = 10
        options.keepaliveInterval = 5
        let parameters = NWParameters(tls: nil, tcp: options)
        let listener: NWListener
        if requestedPort == 0 {
            listener = try NWListener(using: parameters)
        } else if let port = NWEndpoint.Port(rawValue: requestedPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            throw ReticulumBackboneError.notListening
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] value in
            Task { await self?.listenerChanged(value) }
        }
        listener.start(queue: queue)
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        await setState(.stopped)
    }

    public func peers() -> [Peer] {
        clients.values.map(\.peer).sorted { $0.connectedAt < $1.connectedAt }
    }

    public func send(rawPacket: Data, to peerID: UUID) async throws {
        guard let client = clients[peerID] else { throw ReticulumBackboneError.unknownPeer }
        try await send(rawPacket: rawPacket, on: client.connection)
    }

    public func broadcast(rawPacket: Data) async throws {
        guard !clients.isEmpty else { throw ReticulumBackboneError.notListening }
        var firstError: Error?
        var sent = false
        for client in clients.values {
            do {
                try await send(rawPacket: rawPacket, on: client.connection)
                sent = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if !sent, let firstError { throw firstError }
    }

    private func accept(_ connection: NWConnection) async {
        let id = UUID()
        let peer = Peer(
            id: id,
            endpointDescription: String(describing: connection.endpoint),
            connectedAt: .now
        )
        clients[id] = Client(peer: peer, connection: connection)
        connection.stateUpdateHandler = { [weak self] value in
            if case .failed = value { Task { await self?.remove(id) } }
            if case .cancelled = value { Task { await self?.remove(id) } }
        }
        connection.start(queue: queue)
        receive(id)
        await publish()
    }

    private func receive(_ id: UUID) {
        guard let connection = clients[id]?.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data, !data.isEmpty { await self.consume(data, from: id) }
                if complete || error != nil { await self.remove(id) }
                else { await self.receive(id) }
            }
        }
    }

    private func consume(_ data: Data, from id: UUID) async {
        guard var client = clients[id] else { return }
        let frames = client.decoder.consume(data)
        clients[id] = client
        for frame in frames {
            guard let raw = try? ifac?.unprotect(frame) ?? frame,
                  let packet = try? ReticulumPacket(raw: raw) else { continue }
            await packetHandler(client.peer, packet)
        }
    }

    private func send(rawPacket: Data, on connection: NWConnection) async throws {
        let protected = try ifac?.protect(rawPacket) ?? rawPacket
        let frame = HDLC.frame(protected)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    private func remove(_ id: UUID) async {
        clients.removeValue(forKey: id)?.connection.cancel()
        await publish()
    }

    private func listenerChanged(_ value: NWListener.State) async {
        switch value {
        case .ready:
            await setState(.listening(listener?.port?.rawValue ?? requestedPort))
        case let .failed(error):
            await setState(.failed(error.localizedDescription))
        case .cancelled:
            await setState(.stopped)
        default:
            break
        }
    }

    private func setState(_ newState: State) async {
        state = newState
        await publish()
    }

    private func publish() async { await stateHandler(state, peers()) }
}

private extension Data {
    init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }
}
