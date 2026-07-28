import Foundation

/// Binary WebSocket Reticulum interface compatible with MeshChatX's
/// WebsocketClientInterface. Each binary WebSocket message contains exactly
/// one Reticulum packet; unlike TCP, no HDLC envelope is added.
public actor ReticulumWebSocketInterface {
    public enum State: Equatable, Sendable {
        case stopped
        case connecting
        case ready
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public private(set) var receivedBytes: UInt64 = 0
    public private(set) var sentBytes: UInt64 = 0

    private let url: URL
    private let session: URLSession
    private let ifac: ReticulumIFAC?
    private let reconnect: Bool
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var intentionallyStopped = false
    private var reconnectAttempt = 0

    public init(
        url: URL,
        ifac: ReticulumIFAC? = nil,
        reconnect: Bool = true,
        session: URLSession = .shared,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.url = url
        self.ifac = ifac
        self.reconnect = reconnect
        self.session = session
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
    }

    public func start() async {
        guard task == nil else { return }
        intentionallyStopped = false
        await connect()
    }

    public func stop() async {
        intentionallyStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        reconnectAttempt = 0
        await setState(.stopped)
    }

    public func send(rawPacket: Data) async throws {
        guard let task, state == .ready else { throw InterfaceError.notConnected }
        let packet = try ifac?.protect(rawPacket) ?? rawPacket
        try await task.send(.data(packet))
        sentBytes += UInt64(packet.count)
    }

    private func connect() async {
        guard !intentionallyStopped else { return }
        guard ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            await setState(.failed("Invalid WebSocket URL"))
            return
        }
        await setState(.connecting)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        do {
            try await task.sendPing()
            reconnectAttempt = 0
            await setState(.ready)
            receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        } catch {
            await connectionFailed(error.localizedDescription)
        }
    }

    private func receiveLoop(_ currentTask: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, task === currentTask {
                let message = try await currentTask.receive()
                switch message {
                case let .data(data):
                    await consume(data)
                case .string:
                    // Reticulum WebSocket interfaces are binary-only.
                    continue
                @unknown default:
                    continue
                }
            }
        } catch {
            if !Task.isCancelled { await connectionFailed(error.localizedDescription) }
        }
    }

    private func consume(_ data: Data) async {
        do {
            let raw = try ifac?.unprotect(data) ?? data
            let packet = try ReticulumPacket(raw: raw)
            receivedBytes += UInt64(data.count)
            await packetHandler(packet)
        } catch {
            // Invalid or unauthenticated frames are dropped at the interface
            // boundary, matching the TCP interface's behaviour.
        }
    }

    private func connectionFailed(_ reason: String) async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask = nil
        await setState(.failed(reason))
        guard reconnect, !intentionallyStopped, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(60.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.clearReconnectAndConnect()
        }
    }

    private func clearReconnectAndConnect() async {
        reconnectTask = nil
        await connect()
    }

    private func setState(_ value: State) async {
        guard state != value else { return }
        state = value
        await stateHandler(value)
    }

    public enum InterfaceError: Error {
        case notConnected
    }
}

private extension URLSessionWebSocketTask {
    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
