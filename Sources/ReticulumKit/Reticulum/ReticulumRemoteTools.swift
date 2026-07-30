import Foundation

public enum ReticulumRemoteExecutionProtocol {
    public static let destinationName = "rnx.execute"
    public static let requestPath = "command"
    public static let maximumOutputBytes: UInt64 = 16 * 1_048_576

    public struct Request: Equatable, Sendable {
        public var command: String
        public var timeout: UInt64?
        public var stdoutLimit: UInt64?
        public var stderrLimit: UInt64?
        public var stdin: Data?

        public init(command: String, timeout: UInt64? = 30, stdoutLimit: UInt64? = 1_048_576, stderrLimit: UInt64? = 1_048_576, stdin: Data? = nil) throws {
            guard !command.isEmpty, command.utf8.count <= 32_768,
                  (timeout ?? 0) <= 3_600,
                  (stdoutLimit ?? 0) <= maximumOutputBytes,
                  (stderrLimit ?? 0) <= maximumOutputBytes,
                  (stdin?.count ?? 0) <= 1_048_576 else { throw ToolError.invalidRequest }
            self.command = command; self.timeout = timeout; self.stdoutLimit = stdoutLimit; self.stderrLimit = stderrLimit; self.stdin = stdin
        }

        public var value: MessagePackValue {
            .array([
                .binary(Data(command.utf8)),
                timeout.map(MessagePackValue.unsigned) ?? .null,
                stdoutLimit.map(MessagePackValue.unsigned) ?? .null,
                stderrLimit.map(MessagePackValue.unsigned) ?? .null,
                stdin.map(MessagePackValue.binary) ?? .null
            ])
        }
    }

    public struct Result: Equatable, Sendable {
        public var executed: Bool
        public var exitCode: Int64?
        public var stdout: Data
        public var stderr: Data
        public var totalStdoutBytes: UInt64
        public var totalStderrBytes: UInt64
        public var startedAt: Double
        public var concludedAt: Double

        public static func decode(_ data: Data) throws -> Result {
            guard case let .array(values) = try MessagePackDecoder.decode(
                data,
                limits: .init(maximumDepth: 12, maximumCollectionCount: 64, maximumNodeCount: 256, maximumScalarBytes: Int(maximumOutputBytes))
            ), values.count == 8,
                  case let .bool(executed) = values[0],
                  case let .binary(stdout) = values[2],
                  case let .binary(stderr) = values[3],
                  let totalOut = values[4].remoteUnsigned,
                  let totalErr = values[5].remoteUnsigned,
                  case let .double(started) = values[6],
                  case let .double(concluded) = values[7] else { throw ToolError.invalidResponse }
            let exitCode = values[1].remoteSigned
            return Result(executed: executed, exitCode: exitCode, stdout: stdout, stderr: stderr, totalStdoutBytes: totalOut, totalStderrBytes: totalErr, startedAt: started, concludedAt: concluded)
        }
    }

    public static func destinationHash(for identity: ReticulumIdentity) -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash)
    }

    public static func requestEnvelope(_ request: Request, timestamp: Double = Date.now.timeIntervalSince1970) throws -> ReticulumPathRequestEnvelope {
        try ReticulumPathRequestEnvelope(path: requestPath, data: request.value, timestamp: timestamp)
    }

    public enum ToolError: Error, Equatable { case invalidRequest, invalidResponse }
}

public enum ReticulumCopyProtocol {
    public static let destinationName = "rncp.receive"
    public static let fetchPath = "fetch_file"
    public static let maximumFileBytes: UInt64 = 1_073_741_824

    public struct TransferMetadata: Equatable, Sendable {
        public var filename: String
        public var size: UInt64
        public var sha256: Data

        public init(filename: String, size: UInt64, sha256: Data) throws {
            let safe = URL(fileURLWithPath: filename).lastPathComponent
            guard filename == safe, !safe.isEmpty, safe.utf8.count <= 255,
                  !safe.contains("\0"), size <= maximumFileBytes, sha256.count == 32 else {
                throw CopyError.unsafeMetadata
            }
            self.filename = safe; self.size = size; self.sha256 = sha256
        }

        /// Stock RNCP resource metadata. Extra fields are ignored by the
        /// reference receiver while allowing this app to verify integrity.
        public var messagePack: Data {
            MessagePack.map([
                ("name", MessagePack.binary(Data(filename.utf8))),
                ("size", MessagePack.unsigned(size)),
                ("sha256", MessagePack.binary(sha256))
            ])
        }
    }

    public static func destinationHash(for identity: ReticulumIdentity) -> Data {
        let nameHash = Data(ReticulumIdentity.fullHash(Data(destinationName.utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash)
    }

    public static func fetchEnvelope(remotePath: String, timestamp: Double = Date.now.timeIntervalSince1970) throws -> ReticulumPathRequestEnvelope {
        guard !remotePath.isEmpty, remotePath.utf8.count <= 4_096, !remotePath.contains("\0") else {
            throw CopyError.unsafePath
        }
        return try ReticulumPathRequestEnvelope(path: fetchPath, data: .string(remotePath), timestamp: timestamp)
    }

    public enum CopyError: Error, Equatable { case unsafeMetadata, unsafePath }
}

private extension MessagePackValue {
    var remoteUnsigned: UInt64? {
        switch self { case .unsigned(let value): value; case .signed(let value) where value >= 0: UInt64(value); default: nil }
    }
    var remoteSigned: Int64? {
        switch self { case .signed(let value): value; case .unsigned(let value) where value <= UInt64(Int64.max): Int64(value); case .null: nil; default: nil }
    }
}
