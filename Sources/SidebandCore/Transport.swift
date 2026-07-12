import Foundation

public enum TransportState: Equatable, Sendable {
    case offline
    case connecting
    case ready
    case failed(String)
}

public protocol MessageTransport: Sendable {
    var state: TransportState { get async }
    func start() async
    func stop() async
    func send(_ message: Message, to destinationHash: String) async throws
}

public enum TransportError: LocalizedError {
    case nativeEngineUnavailable
    public var errorDescription: String? {
        "The native Reticulum/LXMF engine has not been connected yet. The message remains safely queued."
    }
}

/// Safe first-port transport: preserves the outbox without claiming network delivery.
public actor QueuedTransport: MessageTransport {
    public private(set) var state: TransportState = .offline
    public init() {}
    public func start() { state = .failed("Native Reticulum engine pending") }
    public func stop() { state = .offline }
    public func send(_ message: Message, to destinationHash: String) throws {
        throw TransportError.nativeEngineUnavailable
    }
}
