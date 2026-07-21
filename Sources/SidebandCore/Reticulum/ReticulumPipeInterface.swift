import Foundation

#if os(macOS)
/// Native macOS implementation of Reticulum's subprocess PipeInterface.
/// Executables must be explicit absolute paths; packets use HDLC framing on
/// stdin/stdout and stderr is kept separate from the protocol stream.
public actor ReticulumPipeInterface {
    public enum State: Equatable, Sendable { case stopped, ready, failed(String) }
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
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private var process: Process?
    private var input: FileHandle?
    private var decoder = HDLCDecoder()

    public init(executableURL: URL, arguments: [String] = [], environment: [String: String] = [:], packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void) {
        self.executableURL = executableURL; self.arguments = arguments
        self.environment = environment; self.packetHandler = packetHandler
    }

    public func start() throws {
        guard process == nil else { return }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw Error.unsafeExecutable }
        let process = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = executableURL; process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in configured }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.terminated(status: process.terminationStatus) }
        }
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting; state = .ready
    }

    public func stop() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate(); process = nil; input = nil; decoder = HDLCDecoder(); state = .stopped
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

    private func terminated(status: Int32) {
        process = nil; input = nil
        if state != .stopped { state = .failed("Pipe process exited with status \(status).") }
    }
}
#endif
