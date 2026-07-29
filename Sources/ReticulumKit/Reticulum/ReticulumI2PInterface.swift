import Foundation
import Network

/// A parsed I2P SAM v3 reply line.
public struct ReticulumSAMReply: Equatable, Sendable {
    public let verb: String
    public let operation: String
    public let parameters: [String: String]

    public init(line: String) throws {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard fields.count >= 2 else { throw ReticulumSAMError.malformedReply }
        verb = fields[0]
        operation = fields[1]
        parameters = Dictionary(uniqueKeysWithValues: fields.dropFirst(2).compactMap { field in
            guard let separator = field.firstIndex(of: "=") else { return nil }
            return (String(field[..<separator]), String(field[field.index(after: separator)...]))
        })
    }

    public var result: String? { parameters["RESULT"] }
    public var isOK: Bool { result == "OK" }
}

public enum ReticulumSAMError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case connectionFailed(String)
    case malformedReply
    case rejected(String)
    case timedOut
    case disconnected
    case notReady

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The I2P SAM configuration is invalid."
        case let .connectionFailed(reason): "Could not connect to the I2P SAM bridge: \(reason)"
        case .malformedReply: "The I2P SAM bridge returned a malformed reply."
        case let .rejected(reason): "The I2P SAM bridge rejected the request: \(reason)"
        case .timedOut: "The I2P SAM bridge did not respond before the timeout."
        case .disconnected: "The I2P stream disconnected."
        case .notReady: "The I2P interface is not ready."
        }
    }
}

public enum ReticulumI2PStreamRole: Equatable, Sendable {
    case connect(destination: String)
    case accept
}

public struct ReticulumI2PConfiguration: Equatable, Sendable {
    public var samHost: String
    public var samPort: UInt16
    public var sessionID: String
    public var sessionDestination: String
    public var role: ReticulumI2PStreamRole
    public var timeout: TimeInterval

    public init(
        samHost: String = "127.0.0.1",
        samPort: UInt16 = 7_656,
        sessionID: String = "lower-sideband-\(UUID().uuidString.lowercased())",
        sessionDestination: String = "TRANSIENT",
        role: ReticulumI2PStreamRole,
        timeout: TimeInterval = 30
    ) {
        self.samHost = samHost
        self.samPort = samPort
        self.sessionID = sessionID
        self.sessionDestination = sessionDestination
        self.role = role
        self.timeout = timeout
    }

    public func validated() throws -> Self {
        guard !samHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              samPort > 0,
              ReticulumI2PSAM.validToken(sessionID),
              ReticulumI2PSAM.validToken(sessionDestination),
              timeout > 0, timeout <= 300 else {
            throw ReticulumSAMError.invalidConfiguration
        }
        if case let .connect(destination) = role {
            guard ReticulumI2PSAM.validToken(destination) else {
                throw ReticulumSAMError.invalidConfiguration
            }
        }
        return self
    }
}

/// Native SAM v3 STREAM interface.
///
/// The control connection owns the SAM session for the lifetime of the
/// interface. A separate data connection performs STREAM CONNECT or
/// STREAM ACCEPT, after which Reticulum packets use the same HDLC framing as
/// the reference I2P interface.
public actor ReticulumI2PInterface {
    public typealias State = ReticulumTCPInterface.State

    public private(set) var state: State = .stopped
    public private(set) var sessionDestination: String?

    private let configuration: ReticulumI2PConfiguration
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void
    private let queue = DispatchQueue(label: "sideband.reticulum.i2p-sam")
    private var controlConnection: NWConnection?
    private var streamConnection: NWConnection?
    private var decoder = HDLCDecoder()
    private var lifecycleTask: Task<Void, Never>?
    private var generation = UUID()

    public init(
        configuration: ReticulumI2PConfiguration,
        ifac: ReticulumIFAC? = nil,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.ifac = ifac
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
    }

    public func start() {
        guard lifecycleTask == nil, controlConnection == nil, streamConnection == nil else { return }
        generation = UUID()
        let token = generation
        lifecycleTask = Task { [weak self] in await self?.establish(generation: token) }
    }

    public func stop() async {
        generation = UUID()
        lifecycleTask?.cancel()
        lifecycleTask = nil
        controlConnection?.cancel()
        streamConnection?.cancel()
        controlConnection = nil
        streamConnection = nil
        decoder = HDLCDecoder()
        sessionDestination = nil
        await setState(.stopped)
    }

    public func send(rawPacket: Data) async throws {
        guard let streamConnection, state == .ready else { throw ReticulumSAMError.notReady }
        let protected = try ifac?.protect(rawPacket) ?? rawPacket
        try await Self.send(HDLC.frame(protected), on: streamConnection)
    }

    private func establish(generation token: UUID) async {
        await setState(.connecting)
        do {
            let configuration = try configuration.validated()
            let control = try await Self.openConnection(
                host: configuration.samHost,
                port: configuration.samPort,
                timeout: configuration.timeout,
                queue: queue
            )
            try await Self.negotiateHello(on: control, timeout: configuration.timeout)
            let session = try await Self.command(
                ReticulumI2PSAM.createSession(
                    id: configuration.sessionID,
                    destination: configuration.sessionDestination
                ),
                on: control,
                timeout: configuration.timeout
            )
            sessionDestination = session.parameters["DESTINATION"]

            let stream = try await Self.openConnection(
                host: configuration.samHost,
                port: configuration.samPort,
                timeout: configuration.timeout,
                queue: queue
            )
            try await Self.negotiateHello(on: stream, timeout: configuration.timeout)
            let streamCommand: Data
            switch configuration.role {
            case let .connect(destination):
                streamCommand = try ReticulumI2PSAM.connect(id: configuration.sessionID, destination: destination)
            case .accept:
                streamCommand = try ReticulumI2PSAM.accept(id: configuration.sessionID)
            }
            _ = try await Self.command(streamCommand, on: stream, timeout: configuration.timeout)

            guard generation == token, !Task.isCancelled else {
                control.cancel()
                stream.cancel()
                return
            }
            controlConnection = control
            streamConnection = stream
            lifecycleTask = nil
            await setState(.ready)
            receive(on: stream, generation: token)
            monitorControl(control, generation: token)
        } catch is CancellationError {
            lifecycleTask = nil
        } catch {
            lifecycleTask = nil
            await fail(error.localizedDescription, generation: token)
        }
    }

    private func receive(on connection: NWConnection, generation token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let connection else { return }
            Task {
                guard let self, await self.isCurrent(connection, generation: token) else { return }
                if let data, !data.isEmpty { await self.consume(data) }
                if let error { await self.fail(error.localizedDescription, generation: token) }
                else if complete { await self.fail(ReticulumSAMError.disconnected.localizedDescription, generation: token) }
                else { await self.receive(on: connection, generation: token) }
            }
        }
    }

    private func monitorControl(_ connection: NWConnection, generation token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self, weak connection] _, _, complete, error in
            guard let connection else { return }
            Task {
                guard let self, await self.isCurrentControl(connection, generation: token) else { return }
                if let error { await self.fail(error.localizedDescription, generation: token) }
                else if complete { await self.fail(ReticulumSAMError.disconnected.localizedDescription, generation: token) }
                else { await self.monitorControl(connection, generation: token) }
            }
        }
    }

    private func consume(_ bytes: Data) async {
        for frame in decoder.consume(bytes) {
            guard let raw = try? ifac?.unprotect(frame) ?? frame,
                  let packet = try? ReticulumPacket(raw: raw) else { continue }
            await packetHandler(packet)
        }
    }

    private func isCurrent(_ connection: NWConnection, generation token: UUID) -> Bool {
        generation == token && streamConnection === connection
    }

    private func isCurrentControl(_ connection: NWConnection, generation token: UUID) -> Bool {
        generation == token && controlConnection === connection
    }

    private func fail(_ reason: String, generation token: UUID) async {
        guard generation == token else { return }
        controlConnection?.cancel()
        streamConnection?.cancel()
        controlConnection = nil
        streamConnection = nil
        decoder = HDLCDecoder()
        await setState(.failed(reason))
    }

    private func setState(_ value: State) async {
        state = value
        await stateHandler(value)
    }

    private static func negotiateHello(on connection: NWConnection, timeout: TimeInterval) async throws {
        let reply = try await command(ReticulumI2PSAM.hello(), on: connection, timeout: timeout)
        guard reply.verb == "HELLO", reply.operation == "REPLY" else {
            throw ReticulumSAMError.malformedReply
        }
    }

    private static func command(_ command: Data, on connection: NWConnection, timeout: TimeInterval) async throws -> ReticulumSAMReply {
        try await send(command, on: connection)
        let line = try await withTimeout(seconds: timeout, connection: connection) {
            try await receiveLine(on: connection)
        }
        let reply = try ReticulumSAMReply(line: line)
        guard reply.isOK else { throw ReticulumSAMError.rejected(reply.result ?? "UNKNOWN") }
        return reply
    }

    private static func openConnection(
        host: String,
        port: UInt16,
        timeout: TimeInterval,
        queue: DispatchQueue
    ) async throws -> NWConnection {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ReticulumSAMError.invalidConfiguration
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.connectionTimeout = Int(min(timeout, TimeInterval(Int.max)))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: nil, tcp: tcp))
        let gate = SAMContinuationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.succeed(continuation, connection: connection)
                    case let .failed(error):
                        gate.fail(continuation, error: ReticulumSAMError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        gate.fail(continuation, error: CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    private static func receiveLine(on connection: NWConnection) async throws -> String {
        var bytes = Data()
        while bytes.count < 8_192 {
            let byte: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: ReticulumSAMError.disconnected) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            if byte.isEmpty { continue }
            bytes.append(byte)
            if byte.last == 0x0A {
                guard let line = String(data: bytes, encoding: .utf8) else {
                    throw ReticulumSAMError.malformedReply
                }
                return line
            }
        }
        throw ReticulumSAMError.malformedReply
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        connection: NWConnection,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                connection.cancel()
                throw ReticulumSAMError.timedOut
            }
            guard let value = try await group.next() else { throw ReticulumSAMError.timedOut }
            group.cancelAll()
            return value
        }
    }
}

private final class SAMContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func succeed(_ continuation: CheckedContinuation<NWConnection, Error>, connection: NWConnection) {
        let shouldResume = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(returning: connection)
    }

    func fail(_ continuation: CheckedContinuation<NWConnection, Error>, error: Error) {
        let shouldResume = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(throwing: error)
    }
}
