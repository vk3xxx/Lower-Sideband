import Foundation

#if os(macOS)
/// Native macOS implementation of Reticulum's subprocess PipeInterface.
/// Executables must be explicit absolute paths; packets use HDLC framing on
/// stdin/stdout and stderr is kept separate from the protocol stream.
public actor ReticulumPipeInterface {
    public enum State: Equatable, Sendable { case stopped, connecting, ready, failed(String) }
    public enum Error: LocalizedError {
        case unsafeExecutable, notConnected
        public var errorDescription: String? {
            switch self {
            case .unsafeExecutable: "PipeInterface requires an installed executable at an absolute path."
            case .notConnected: "The PipeInterface process is not running."
            }
        }
    }
    public private(set) var state: State = .stopped
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let reconnect: Bool
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void
    private var process: Process?
    private var input: FileHandle?
    private var decoder = HDLCDecoder()
    private var generation = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    public private(set) var lastStandardError = ""

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        reconnect: Bool = true,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.executableURL = executableURL; self.arguments = arguments
        self.environment = environment; self.reconnect = reconnect
        self.packetHandler = packetHandler; self.stateHandler = stateHandler
    }

    public func start() async throws {
        guard process == nil else { return }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw Error.unsafeExecutable }
        reconnectTask?.cancel()
        reconnectTask = nil
        generation = UUID()
        reconnectAttempt = 0
        try await launch(generation: generation)
    }

    private func launch(generation token: UUID) async throws {
        guard generation == token else { return }
        await setState(.connecting)
        let process = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = executableURL; process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in configured }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeStandardError(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.terminated(status: process.terminationStatus, generation: token) }
        }
        do {
            try process.run()
            guard generation == token else {
                process.terminate()
                return
            }
            self.process = process
            input = stdin.fileHandleForWriting
            reconnectAttempt = 0
            await setState(.ready)
        } catch {
            await setState(.failed(error.localizedDescription))
            scheduleReconnect(generation: token)
            throw error
        }
    }

    public func stop() async {
        generation = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        input = nil
        decoder = HDLCDecoder()
        reconnectAttempt = 0
        await setState(.stopped)
    }

    public func send(_ rawPacket: Data) throws {
        guard state == .ready, let input else { throw Error.notConnected }
        try input.write(contentsOf: HDLC.frame(rawPacket))
    }

    private func consume(_ data: Data) async {
        for frame in decoder.consume(data) {
            if let packet = try? ReticulumPacket(raw: frame) { await packetHandler(packet) }
        }
    }

    private func consumeStandardError(_ data: Data) {
        let text = String(decoding: data.prefix(8_192), as: UTF8.self)
        lastStandardError = String((lastStandardError + text).suffix(8_192))
    }

    private func terminated(status: Int32, generation token: UUID) async {
        guard generation == token else { return }
        process = nil
        input = nil
        decoder = HDLCDecoder()
        let diagnostic = lastStandardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = diagnostic.isEmpty ? "" : " — \(diagnostic)"
        await setState(.failed("Pipe process exited with status \(status)\(suffix)."))
        scheduleReconnect(generation: token)
    }

    private func scheduleReconnect(generation token: UUID) {
        guard reconnect, generation == token, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(pow(2, Double(max(0, reconnectAttempt - 1))), 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.retry(generation: token)
        }
    }

    private func retry(generation token: UUID) async {
        reconnectTask = nil
        guard generation == token, process == nil else { return }
        do {
            try await launch(generation: token)
        } catch {
            scheduleReconnect(generation: token)
        }
    }

    private func setState(_ value: State) async {
        state = value
        await stateHandler(value)
    }
}
#endif
