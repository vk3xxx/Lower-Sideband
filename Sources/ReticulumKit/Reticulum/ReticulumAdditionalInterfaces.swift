import Foundation
import Network

public struct ReticulumSharedInstanceConfiguration: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var reconnect: Bool
    public init(host: String = "127.0.0.1", port: UInt16 = 37_428, reconnect: Bool = true) {
        self.host = host; self.port = port; self.reconnect = reconnect
    }
    public var isValid: Bool { !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0 }
}

public enum ReticulumI2PSAM {
    public static func hello(version: String = "3.3") -> Data { Data("HELLO VERSION MIN=3.1 MAX=\(version)\n".utf8) }
    public static func createSession(id: String, destination: String = "TRANSIENT") throws -> Data {
        guard validToken(id), validToken(destination) else { throw Error.invalidValue }
        return Data("SESSION CREATE STYLE=STREAM ID=\(id) DESTINATION=\(destination)\n".utf8)
    }
    public static func connect(id: String, destination: String) throws -> Data {
        guard validToken(id), validToken(destination), destination.count <= 2_048 else { throw Error.invalidValue }
        return Data("STREAM CONNECT ID=\(id) DESTINATION=\(destination) SILENT=false\n".utf8)
    }
    public static func accept(id: String) throws -> Data {
        guard validToken(id) else { throw Error.invalidValue }
        return Data("STREAM ACCEPT ID=\(id) SILENT=false\n".utf8)
    }
    public static func replyIsOK(_ data: Data) -> Bool {
        guard let line = String(data: data.prefix(8_192), encoding: .utf8) else { return false }
        return (try? ReticulumSAMReply(line: line).isOK) == true
    }
    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2_048 && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && $0.value >= 0x21 && $0.value <= 0x7e }
    }
    public enum Error: Swift.Error { case invalidValue }
}

/// Weave Device Control Link wire framing used by the upstream Weave interface.
public enum ReticulumWeave {
    public static let broadcastSwitchID = Data(repeating: 0xff, count: 4)
    public enum FrameType: UInt8, Sendable { case discover = 0x00, connect = 0x01, command = 0x02, log = 0x03, display = 0x04, endpointPacket = 0x05, encapsulatedProtocol = 0x06 }

    public static func frame(switchID: Data, type: FrameType, payload: Data) throws -> Data {
        guard switchID.count == 4, payload.count <= 32_768 else { throw Error.invalidFrame }
        return HDLC.frame(switchID + Data([type.rawValue]) + payload)
    }

    public static func endpointCommand(endpointID: Data, packet: Data) throws -> Data {
        guard endpointID.count == 16, packet.count <= 32_750 else { throw Error.invalidFrame }
        return Data([0x00, 0x01]) + endpointID + packet
    }

    public static func decode(_ frame: Data) throws -> (switchID: Data, type: FrameType, payload: Data) {
        guard frame.count >= 5, let type = FrameType(rawValue: frame[4]) else { throw Error.invalidFrame }
        return (Data(frame.prefix(4)), type, Data(frame.dropFirst(5)))
    }
    public enum Error: Swift.Error { case invalidFrame }
}

public actor ReticulumUDPInterface {
    public enum State: Equatable, Sendable { case stopped, ready, failed(String) }
    public private(set) var state: State = .stopped
    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "sideband.reticulum.udp")
    private var connection: NWConnection?
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void

    public init(host: String, port: UInt16, ifac: ReticulumIFAC? = nil, packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void) {
        endpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!)
        self.ifac = ifac; self.packetHandler = packetHandler
    }

    public func start() {
        guard connection == nil else { return }
        let connection = NWConnection(to: endpoint, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in Task { await self?.update(newState) } }
        connection.start(queue: queue)
        receive(on: connection)
    }

    public func stop() { connection?.cancel(); connection = nil; state = .stopped }

    public func send(_ rawPacket: Data) async throws {
        guard let connection, state == .ready else { throw Error.notConnected }
        let data = try ifac?.protect(rawPacket) ?? rawPacket
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task {
                guard let self else { return }
                if let data { await self.consume(data) }
                if error == nil { await self.receive(on: connection) }
            }
        }
    }
    private func consume(_ data: Data) async {
        guard let raw = try? ifac?.unprotect(data) ?? data, let packet = try? ReticulumPacket(raw: raw) else { return }
        await packetHandler(packet)
    }
    private func update(_ value: NWConnection.State) {
        switch value { case .ready: state = .ready; case .failed(let e): state = .failed(e.localizedDescription); connection = nil; case .cancelled: state = .stopped; default: break }
    }
    public enum Error: Swift.Error { case notConnected }
}

public actor ReticulumTCPServer {
    public enum State: Equatable, Sendable { case stopped, listening(UInt16), failed(String) }
    public struct Client: Identifiable, Equatable, Sendable {
        public let id: String
        public let endpoint: String
        public let connectedAt: Date
    }
    public struct Metrics: Equatable, Sendable {
        public let state: State
        public let listenHost: String
        public let requestedPort: UInt16
        public let clients: [Client]
        public let maximumClients: Int
        public let acceptedClients: UInt64
        public let rejectedClients: UInt64
        public let packetsReceived: UInt64
        public let packetsSent: UInt64
        public let bytesReceived: UInt64
        public let bytesSent: UInt64
    }
    public private(set) var state: State = .stopped
    public private(set) var clientCount = 0
    private let listenHost: String
    private let requestedPort: UInt16
    private let maximumClients: Int
    private let queue = DispatchQueue(label: "sideband.reticulum.tcp-server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var clientMetadata: [ObjectIdentifier: Client] = [:]
    private var decoders: [ObjectIdentifier: HDLCDecoder] = [:]
    private var acceptedClients: UInt64 = 0
    private var rejectedClients: UInt64 = 0
    private var packetsReceived: UInt64 = 0
    private var packetsSent: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void

    public init(
        listenHost: String = "0.0.0.0",
        port: UInt16,
        maximumClients: Int = 64,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void
    ) {
        self.listenHost = listenHost
        requestedPort = port
        self.maximumClients = min(max(maximumClients, 1), 256)
        self.ifac = ifac
        self.packetHandler = packetHandler
    }

    public func start() throws {
        guard listener == nil else { return }
        let options = NWProtocolTCP.Options(); options.noDelay = true; options.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: options)
        let normalizedHost = listenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedHost.isEmpty, normalizedHost != "0.0.0.0", normalizedHost != "::" {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else { throw Error.invalidEndpoint }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(normalizedHost), port: port)
        }
        let listener: NWListener
        if requestedPort == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else { throw Error.invalidEndpoint }
            listener = try NWListener(using: parameters, on: port)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] client in Task { await self?.accept(client) } }
        listener.stateUpdateHandler = { [weak self] value in Task { await self?.update(value) } }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        clientMetadata.removeAll()
        decoders.removeAll()
        clientCount = 0
        state = .stopped
    }

    public func broadcast(_ rawPacket: Data) async {
        guard let outbound = try? ifac?.protect(rawPacket) ?? rawPacket else { return }
        let framed = HDLC.frame(outbound)
        let destinations = clients.values
        for connection in destinations { connection.send(content: framed, completion: .idempotent) }
        packetsSent &+= UInt64(destinations.count)
        bytesSent &+= UInt64(framed.count * destinations.count)
    }

    public func metrics() -> Metrics {
        Metrics(
            state: state,
            listenHost: listenHost,
            requestedPort: requestedPort,
            clients: clientMetadata.values.sorted { $0.connectedAt < $1.connectedAt },
            maximumClients: maximumClients,
            acceptedClients: acceptedClients,
            rejectedClients: rejectedClients,
            packetsReceived: packetsReceived,
            packetsSent: packetsSent,
            bytesReceived: bytesReceived,
            bytesSent: bytesSent
        )
    }

    private func accept(_ client: NWConnection) {
        guard clients.count < maximumClients else {
            rejectedClients &+= 1
            client.cancel()
            return
        }
        let id = ObjectIdentifier(client)
        clients[id] = client
        clientMetadata[id] = Client(
            id: String(describing: id),
            endpoint: String(describing: client.endpoint),
            connectedAt: .now
        )
        decoders[id] = HDLCDecoder()
        clientCount = clients.count
        acceptedClients &+= 1
        client.stateUpdateHandler = { [weak self] value in
            switch value {
            case .failed, .cancelled:
                Task { await self?.remove(id) }
            default:
                break
            }
        }
        client.start(queue: queue)
        receive(client, id: id)
    }
    private func receive(_ client: NWConnection, id: ObjectIdentifier) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data { await self.consume(data, id: id) }
                if complete || error != nil { await self.remove(id) } else { await self.receive(client, id: id) }
            }
        }
    }
    private func consume(_ data: Data, id: ObjectIdentifier) async {
        guard var decoder = decoders[id] else { return }
        let frames = decoder.consume(data); decoders[id] = decoder
        for frame in frames {
            guard let raw = try? ifac?.unprotect(frame) ?? frame, let packet = try? ReticulumPacket(raw: raw) else { continue }
            packetsReceived &+= 1
            bytesReceived &+= UInt64(frame.count)
            await packetHandler(packet)
        }
    }
    private func remove(_ id: ObjectIdentifier) {
        clients.removeValue(forKey: id)?.cancel()
        clientMetadata.removeValue(forKey: id)
        decoders.removeValue(forKey: id)
        clientCount = clients.count
    }
    private func update(_ value: NWListener.State) {
        switch value {
        case .ready: state = .listening(listener?.port?.rawValue ?? requestedPort)
        case .failed(let e): state = .failed(e.localizedDescription)
        case .cancelled: state = .stopped
        default: break
        }
    }
    public enum Error: Swift.Error { case invalidEndpoint }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
