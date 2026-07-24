import Foundation
import Network

public actor ReticulumTCPInterface {
    public enum State: Equatable, Sendable { case stopped, connecting, ready, failed(String) }

    public private(set) var state: State = .stopped
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let endpoint: NWEndpoint
    private let connectionQueue = DispatchQueue(label: "sideband.reticulum.tcp")
    private var connection: NWConnection?
    private var decoder = HDLCDecoder()
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void

    public init(host: String, port: UInt16, ifac: ReticulumIFAC? = nil, packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void, stateHandler: @escaping @Sendable (State) async -> Void = { _ in }) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), ifac: ifac, packetHandler: packetHandler, stateHandler: stateHandler)
    }

    public init(endpoint: NWEndpoint, ifac: ReticulumIFAC? = nil, packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void, stateHandler: @escaping @Sendable (State) async -> Void = { _ in }) {
        if case let .hostPort(host, port) = endpoint { self.host = host; self.port = port }
        else { self.host = "localhost"; self.port = 1 }
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
        self.endpoint = endpoint
        self.ifac = ifac
    }

    public func start() {
        guard connection == nil else { return }
        state = .connecting
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 5
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            Task { await self?.handle(newState) }
        }
        connection.start(queue: connectionQueue)
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        state = .stopped
    }

    public func send(rawPacket: Data) async throws {
        guard let connection, state == .ready else { throw InterfaceError.notConnected }
        let outbound = try ifac?.protect(rawPacket) ?? rawPacket
        let framed = HDLC.frame(outbound)
        trace("TX raw=\(rawPacket.count) protected=\(outbound.count) framed=\(framed.count) header=\(rawPacket.prefix(2).traceHex)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data { await self.consume(data) }
                if let error { await self.fail(error.localizedDescription); return }
                if complete { await self.fail("Connection closed"); return }
                await self.receive(on: connection)
            }
        }
    }

    private func consume(_ data: Data) async {
        let frames = decoder.consume(data)
        trace("RX chunk=\(data.count) frames=\(frames.count)")
        for frame in frames {
            do {
                let raw = try ifac?.unprotect(frame) ?? frame
                let packet = try ReticulumPacket(raw: raw)
                trace("RX packet raw=\(raw.count) header=\(raw.prefix(2).traceHex) destination=\(packet.destinationHash.traceHex) context=\(packet.context) base64=\(raw.base64EncodedString())")
                await packetHandler(packet)
            } catch {
                trace("RX rejected frame=\(frame.count) prefix=\(frame.prefix(16).traceHex) error=\(error)")
            }
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["SIDEBAND_SOAK_NETWORK_MODE"] != nil else { return }
        print("SIDEBAND_TCP_TRACE \(message())")
    }

    private func handle(_ newState: NWConnection.State) async {
        switch newState {
        case .ready:
            await setState(.ready)
            if let connection { receive(on: connection) }
        case .failed(let error): await fail(error.localizedDescription)
        case .cancelled:
            // A remotely or system-cancelled NWConnection cannot be started
            // again. Clear it so the owning interface pool can create a fresh
            // socket during its per-endpoint reconnect cycle.
            connection = nil
            await setState(.stopped)
        default: break
        }
    }

    private func fail(_ reason: String) async {
        await setState(.failed(reason))
        connection?.cancel()
        connection = nil
    }

    private func setState(_ newState: State) async {
        state = newState
        await stateHandler(newState)
    }

    public enum InterfaceError: Error { case notConnected }
}

private extension DataProtocol {
    var traceHex: String { map { String(format: "%02x", $0) }.joined() }
}
