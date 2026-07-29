import CryptoKit
import Foundation
import Network

/// A bounded RFC 6455 frame codec used by the native WebSocket listener.
/// Client frames must be masked; server frames are emitted unmasked.
public enum ReticulumWebSocketFrameCodec {
    public enum Opcode: UInt8, Sendable { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }
    public struct Frame: Equatable, Sendable {
        public let opcode: Opcode
        public let payload: Data
        public init(opcode: Opcode, payload: Data) { self.opcode = opcode; self.payload = payload }
    }

    public static func serverFrame(opcode: Opcode, payload: Data) throws -> Data {
        guard payload.count <= 262_144 else { throw Error.payloadTooLarge }
        var result = Data([0x80 | opcode.rawValue])
        if payload.count < 126 {
            result.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            result.append(126)
            result.append(UInt8(payload.count >> 8))
            result.append(UInt8(payload.count))
        } else {
            result.append(127)
            result.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        }
        result.append(payload)
        return result
    }

    public static func consumeClientFrames(buffer: inout Data) throws -> [Frame] {
        var frames: [Frame] = []
        while buffer.count >= 2 {
            let start = buffer.startIndex
            func byte(at offset: Int) -> UInt8 {
                buffer[buffer.index(start, offsetBy: offset)]
            }
            let first = byte(at: 0), second = byte(at: 1)
            guard first & 0x70 == 0, first & 0x80 != 0,
                  let opcode = Opcode(rawValue: first & 0x0f) else { throw Error.invalidFrame }
            guard second & 0x80 != 0 else { throw Error.unmaskedClientFrame }
            var offset = 2
            var length = Int(second & 0x7f)
            if length == 126 {
                guard buffer.count >= offset + 2 else { break }
                length = Int(byte(at: offset)) << 8 | Int(byte(at: offset + 1)); offset += 2
            } else if length == 127 {
                guard buffer.count >= offset + 8 else { break }
                var value: UInt64 = 0
                for index in offset..<(offset + 8) { value = value << 8 | UInt64(byte(at: index)) }
                guard value <= 262_144 else { throw Error.payloadTooLarge }
                length = Int(value); offset += 8
            }
            guard length <= 262_144 else { throw Error.payloadTooLarge }
            guard buffer.count >= offset + 4 + length else { break }
            let mask = (offset..<(offset + 4)).map(byte(at:)); offset += 4
            var payload = Data((offset..<(offset + length)).map(byte(at:)))
            for (position, index) in payload.indices.enumerated() { payload[index] ^= mask[position % 4] }
            buffer.removeFirst(offset + length)
            frames.append(Frame(opcode: opcode, payload: payload))
        }
        return frames
    }

    public enum Error: Swift.Error { case invalidFrame, unmaskedClientFrame, payloadTooLarge }
}

/// Native Reticulum WebSocket listener. Each binary WebSocket message carries
/// one raw Reticulum packet, matching `ReticulumWebSocketInterface`.
public actor ReticulumWebSocketServer {
    public enum State: Equatable, Sendable { case stopped, listening(UInt16), failed(String) }
    public private(set) var state: State = .stopped
    public private(set) var clientCount = 0

    private struct Peer {
        let connection: NWConnection
        var buffer = Data()
        var upgraded = false
    }
    private let requestedPort: UInt16
    private let path: String
    private let ifac: ReticulumIFAC?
    private let queue = DispatchQueue(label: "reticulum.websocket-server")
    private let packetHandler: @Sendable (String, ReticulumPacket) async -> Void
    private var listener: NWListener?
    private var peers: [String: Peer] = [:]

    public init(
        port: UInt16,
        path: String = "/",
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (String, ReticulumPacket) async -> Void
    ) {
        requestedPort = port
        self.path = path.hasPrefix("/") ? path : "/\(path)"
        self.ifac = ifac
        self.packetHandler = packetHandler
    }

    public func start() throws {
        guard listener == nil else { return }
        let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
        let options = NWProtocolTCP.Options(); options.noDelay = true; options.enableKeepalive = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: options), on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] value in Task { await self?.listenerChanged(value) } }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel(); listener = nil
        peers.values.forEach { $0.connection.cancel() }
        peers.removeAll(); clientCount = 0; state = .stopped
    }

    public func broadcast(_ rawPacket: Data, excluding excludedPeerID: String? = nil) throws {
        let protected = try ifac?.protect(rawPacket) ?? rawPacket
        let frame = try ReticulumWebSocketFrameCodec.serverFrame(opcode: .binary, payload: protected)
        for (id, peer) in peers where peer.upgraded && id != excludedPeerID {
            peer.connection.send(content: frame, completion: .idempotent)
        }
    }

    public func send(_ rawPacket: Data, to peerID: String) throws {
        guard let peer = peers[peerID], peer.upgraded else { throw InterfaceError.unknownPeer }
        let protected = try ifac?.protect(rawPacket) ?? rawPacket
        peer.connection.send(
            content: try ReticulumWebSocketFrameCodec.serverFrame(opcode: .binary, payload: protected),
            completion: .idempotent
        )
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID().uuidString
        peers[id] = Peer(connection: connection)
        clientCount = peers.count
        connection.stateUpdateHandler = { [weak self] value in
            if case .failed = value { Task { await self?.remove(id) } }
            if case .cancelled = value { Task { await self?.remove(id) } }
        }
        connection.start(queue: queue)
        receive(connection, id: id)
    }

    private func receive(_ connection: NWConnection, id: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data, !data.isEmpty { await self.consume(data, id: id) }
                if complete || error != nil { await self.remove(id) }
                else { await self.receive(connection, id: id) }
            }
        }
    }

    private func consume(_ data: Data, id: String) async {
        guard var peer = peers[id] else { return }
        peer.buffer.append(data)
        if !peer.upgraded {
            guard let headerEnd = peer.buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if peer.buffer.count > 16_384 { remove(id) } else { peers[id] = peer }
                return
            }
            let header = Data(peer.buffer[..<headerEnd.upperBound])
            peer.buffer.removeFirst(headerEnd.upperBound)
            guard let request = String(data: header, encoding: .utf8),
                  request.hasPrefix("GET \(path) "),
                  let key = Self.header("Sec-WebSocket-Key", in: request),
                  Self.header("Upgrade", in: request)?.lowercased() == "websocket" else {
                peer.connection.send(content: Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8), completion: .idempotent)
                remove(id); return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            peer.connection.send(content: Data(response.utf8), completion: .idempotent)
            peer.upgraded = true
            peers[id] = peer
        } else {
            peers[id] = peer
        }
        await consumeFrames(id: id)
    }

    private func consumeFrames(id: String) async {
        guard var peer = peers[id] else { return }
        do {
            let frames = try ReticulumWebSocketFrameCodec.consumeClientFrames(buffer: &peer.buffer)
            peers[id] = peer
            for frame in frames {
                switch frame.opcode {
                case .binary:
                    guard let raw = try? ifac?.unprotect(frame.payload) ?? frame.payload,
                          let packet = try? ReticulumPacket(raw: raw) else { continue }
                    await packetHandler(id, packet)
                case .ping:
                    peer.connection.send(content: try ReticulumWebSocketFrameCodec.serverFrame(opcode: .pong, payload: frame.payload), completion: .idempotent)
                case .close:
                    remove(id)
                default:
                    continue
                }
            }
        } catch {
            remove(id)
        }
    }

    private func remove(_ id: String) {
        peers.removeValue(forKey: id)?.connection.cancel()
        clientCount = peers.count
    }

    private func listenerChanged(_ value: NWListener.State) {
        switch value {
        case .ready: state = .listening(listener?.port?.rawValue ?? requestedPort)
        case let .failed(error): state = .failed(error.localizedDescription)
        case .cancelled: state = .stopped
        default: break
        }
    }

    private static func header(_ name: String, in request: String) -> String? {
        request.components(separatedBy: "\r\n").dropFirst().first { line in
            line.lowercased().hasPrefix(name.lowercased() + ":")
        }.flatMap { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
    }

    public enum InterfaceError: Swift.Error { case unknownPeer }
}

/// Native POST/poll Reticulum tunnel listener compatible with
/// `ReticulumHTTPInterface`. Sessions are maintained with an HTTP-only cookie,
/// and response queues are strictly bounded.
public actor ReticulumHTTPServer {
    public enum State: Equatable, Sendable { case stopped, listening(UInt16), failed(String) }
    public private(set) var state: State = .stopped
    public private(set) var sessionCount = 0

    private struct Session { var outbound: [Data] = []; var updatedAt = Date.now }
    private struct RequestBuffer { let connection: NWConnection; var bytes = Data() }
    private let requestedPort: UInt16
    private let path: String
    private let mtu: Int
    private let ifac: ReticulumIFAC?
    private let queue = DispatchQueue(label: "reticulum.http-server")
    private let packetHandler: @Sendable (String, ReticulumPacket) async -> Void
    private var listener: NWListener?
    private var requests: [String: RequestBuffer] = [:]
    private var sessions: [String: Session] = [:]

    public init(
        port: UInt16,
        path: String = "/",
        mtu: Int = ReticulumHTTPInterface.defaultMTU,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (String, ReticulumPacket) async -> Void
    ) {
        requestedPort = port; self.path = path.hasPrefix("/") ? path : "/\(path)"
        self.mtu = max(256, min(262_144, mtu)); self.ifac = ifac; self.packetHandler = packetHandler
    }

    public func start() throws {
        guard listener == nil else { return }
        let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] value in Task { await self?.listenerChanged(value) } }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel(); listener = nil
        requests.values.forEach { $0.connection.cancel() }
        requests.removeAll(); sessions.removeAll(); sessionCount = 0; state = .stopped
    }

    public func broadcast(_ rawPacket: Data, excluding excludedSessionID: String? = nil) throws {
        let protected = try ifac?.protect(rawPacket) ?? rawPacket
        guard protected.count <= mtu else { throw InterfaceError.payloadTooLarge }
        let frame = HDLC.frame(protected)
        expireSessions()
        for id in sessions.keys where id != excludedSessionID {
            sessions[id]?.outbound.append(frame)
            if sessions[id]!.outbound.count > 256 { sessions[id]!.outbound.removeFirst() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID().uuidString
        requests[id] = RequestBuffer(connection: connection)
        connection.start(queue: queue)
        receive(connection, id: id)
    }

    private func receive(_ connection: NWConnection, id: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data { await self.consume(data, id: id) }
                if complete || error != nil { await self.removeRequest(id) }
                else if await self.requests[id] != nil { await self.receive(connection, id: id) }
            }
        }
    }

    private func consume(_ data: Data, id: String) async {
        guard var request = requests[id] else { return }
        request.bytes.append(data)
        guard request.bytes.count <= mtu * 256,
              let headerEnd = request.bytes.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: request.bytes[..<headerEnd.upperBound], encoding: .utf8) else {
            if request.bytes.count > mtu * 256 { reject(id, status: "413 Payload Too Large") }
            else { requests[id] = request }
            return
        }
        let length = Int(Self.header("Content-Length", in: headers) ?? "0") ?? 0
        guard length <= mtu * 256 else { reject(id, status: "413 Payload Too Large"); return }
        let bodyStart = headerEnd.upperBound
        guard request.bytes.count >= bodyStart + length else { requests[id] = request; return }
        guard headers.hasPrefix("POST \(path) ") else { reject(id, status: "404 Not Found"); return }
        let body = Data(request.bytes[bodyStart..<(bodyStart + length)])
        let sessionID = Self.sessionID(from: headers) ?? UUID().uuidString
        var session = sessions[sessionID] ?? Session()
        session.updatedAt = .now
        sessions[sessionID] = session
        sessionCount = sessions.count

        var decoder = HDLCDecoder(maximumFrameSize: mtu)
        for frame in decoder.consume(body) {
            guard let raw = try? ifac?.unprotect(frame) ?? frame,
                  let packet = try? ReticulumPacket(raw: raw) else { continue }
            await packetHandler(sessionID, packet)
        }

        let responseBody = sessions[sessionID]?.outbound.reduce(into: Data()) { $0.append($1) } ?? Data()
        sessions[sessionID]?.outbound.removeAll(keepingCapacity: true)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(responseBody.count)\r\nSet-Cookie: RNS-Session=\(sessionID); Path=\(path); HttpOnly; SameSite=Strict\r\nConnection: close\r\n\r\n"
        let connection = request.connection
        connection.send(content: Data(response.utf8) + responseBody, completion: .contentProcessed { _ in connection.cancel() })
        requests.removeValue(forKey: id)
    }

    private func reject(_ id: String, status: String) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in request.connection.cancel() })
    }

    private func removeRequest(_ id: String) { requests.removeValue(forKey: id)?.connection.cancel() }
    private func expireSessions() {
        let cutoff = Date.now.addingTimeInterval(-300)
        sessions = sessions.filter { $0.value.updatedAt >= cutoff }
        sessionCount = sessions.count
    }
    private func listenerChanged(_ value: NWListener.State) {
        switch value {
        case .ready: state = .listening(listener?.port?.rawValue ?? requestedPort)
        case let .failed(error): state = .failed(error.localizedDescription)
        case .cancelled: state = .stopped
        default: break
        }
    }
    private static func header(_ name: String, in request: String) -> String? {
        request.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
    }
    private static func sessionID(from headers: String) -> String? {
        guard let cookie = header("Cookie", in: headers) else { return nil }
        return cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("RNS-Session=") }?.dropFirst("RNS-Session=".count).description
    }
    public enum InterfaceError: Swift.Error { case payloadTooLarge }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
