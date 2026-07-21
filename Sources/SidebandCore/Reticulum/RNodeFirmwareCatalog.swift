import CryptoKit
import Foundation

public struct RNodeFirmwareCatalog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(platform)-\(board.map(String.init) ?? "any")-\(version)" }
        public let version: String
        public let platform: UInt8
        public let board: UInt8?
        public let imageURL: URL
        public let sha256Hex: String

        public init(version: String, platform: UInt8, board: UInt8? = nil, imageURL: URL, sha256Hex: String) {
            self.version = version; self.platform = platform; self.board = board; self.imageURL = imageURL; self.sha256Hex = sha256Hex.lowercased()
        }
        public var isValid: Bool {
            !version.isEmpty && version.count <= 32 && imageURL.scheme == "https" && imageURL.user == nil && imageURL.password == nil &&
            sha256Hex.count == 64 && sha256Hex.allSatisfy(\.isHexDigit)
        }
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let entries: [Entry]

    public init(generatedAt: Date = .now, entries: [Entry]) { schemaVersion = 1; self.generatedAt = generatedAt; self.entries = entries }
    public func validate() throws {
        guard schemaVersion == 1, entries.count <= 1_024, entries.allSatisfy(\.isValid), Set(entries.map(\.id)).count == entries.count else { throw Error.invalidCatalog }
    }
    public func bestMatch(for metrics: RNodeMetrics) -> Entry? {
        entries.filter { metrics.platform == nil || $0.platform == metrics.platform }
            .filter { $0.board == nil || metrics.board == nil || $0.board == metrics.board }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }.first
    }
    public enum Error: Swift.Error { case invalidCatalog }
}

public struct RNodeSignedFirmwareCatalog: Codable, Sendable {
    public let payload: Data
    public let signature: Data
    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }

    public func verified(publicKey: Data) throws -> RNodeFirmwareCatalog {
        guard payload.count <= 2 * 1_024 * 1_024, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey), key.isValidSignature(signature, for: payload) else { throw Error.invalidSignature }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RNodeFirmwareCatalog.self, from: payload)
        try catalog.validate(); return catalog
    }
    public enum Error: Swift.Error { case invalidSignature }
}

public enum RNodeFirmwareDownloader {
    public static func download(_ entry: RNodeFirmwareCatalog.Entry, using session: URLSession = .shared) async throws -> RNodeFirmwarePackage {
        guard entry.isValid else { throw Error.invalidEntry }
        let (data, response) = try await session.data(from: entry.imageURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty, data.count <= 16 * 1_024 * 1_024 else { throw Error.invalidResponse }
        let digest = Data(SHA256.hash(data: data))
        guard digest.hex == entry.sha256Hex else { throw RNodeFirmwareValidationError.digestMismatch }
        return RNodeFirmwarePackage(version: entry.version, platform: entry.platform, board: entry.board, image: data, sha256: digest)
    }
    public enum Error: Swift.Error { case invalidEntry, invalidResponse }
}

public protocol RNodeFirmwareFlasher: Sendable {
    func flash(_ package: RNodeFirmwarePackage, progress: @escaping @Sendable (Double) async -> Void) async throws
}

/// Bootloader adapter used by BLE, serial and Wi-Fi implementations. Hardware
/// families can provide their own erase/write/verify commands while sharing
/// digest validation, bounded chunking and monotonic progress reporting.
public protocol RNodeBootloaderTransport: Sendable {
    func begin(imageBytes: Int, sha256: Data) async throws
    func write(offset: Int, bytes: Data) async throws
    func finish() async throws -> Data
    func cancel() async
}

public struct RNodeChunkedFirmwareFlasher: RNodeFirmwareFlasher, Sendable {
    public enum Error: Swift.Error, Equatable { case invalidChunkSize, verificationFailed }
    private let transport: any RNodeBootloaderTransport
    private let chunkSize: Int

    public init(transport: any RNodeBootloaderTransport, chunkSize: Int = 1_024) throws {
        guard (128...16_384).contains(chunkSize) else { throw Error.invalidChunkSize }
        self.transport = transport; self.chunkSize = chunkSize
    }

    public func flash(_ package: RNodeFirmwarePackage, progress: @escaping @Sendable (Double) async -> Void) async throws {
        try package.validate(against: RNodeMetrics())
        do {
            try await transport.begin(imageBytes: package.image.count, sha256: package.sha256)
            await progress(0)
            var offset = 0
            while offset < package.image.count {
                try Task.checkCancellation()
                let end = min(package.image.count, offset + chunkSize)
                try await transport.write(offset: offset, bytes: package.image.subdata(in: offset..<end))
                offset = end
                await progress(Double(offset) / Double(package.image.count))
            }
            guard try await transport.finish() == package.sha256 else { throw Error.verificationFailed }
            await progress(1)
        } catch {
            await transport.cancel()
            throw error
        }
    }
}

#if os(macOS)
/// Executes an explicitly installed native vendor bootloader on macOS. The
/// firmware is written to a private temporary file and removed after use.
public struct RNodeExternalBootloaderFlasher: RNodeFirmwareFlasher, Sendable {
    public enum Error: LocalizedError {
        case unsafeExecutable, failed(Int32, String)
        public var errorDescription: String? {
            switch self {
            case .unsafeExecutable: "The selected RNode bootloader is not an executable absolute path."
            case let .failed(code, output): "The RNode bootloader exited with status \(code): \(output)"
            }
        }
    }
    public let executableURL: URL
    public let arguments: [String]
    public let imagePlaceholder: String

    public init(executableURL: URL, arguments: [String], imagePlaceholder: String = "{image}") {
        self.executableURL = executableURL; self.arguments = arguments; self.imagePlaceholder = imagePlaceholder
    }

    public func flash(_ package: RNodeFirmwarePackage, progress: @escaping @Sendable (Double) async -> Void) async throws {
        try package.validate(against: RNodeMetrics())
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw Error.unsafeExecutable }
        let directory = FileManager.default.temporaryDirectory.appending(path: "lower-sideband-rnode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appending(path: "firmware.bin")
        try package.image.write(to: imageURL, options: [.atomic, .completeFileProtection])
        await progress(0.1)
        let process = Process(); process.executableURL = executableURL
        process.arguments = arguments.map { $0.replacingOccurrences(of: imagePlaceholder, with: imageURL.path) }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile().prefix(8_192), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw Error.failed(process.terminationStatus, output) }
        await progress(1)
    }
}
#endif

public enum RNodeConfigurationArchive {
    public static func encode(_ configurations: [RNodeConfiguration]) throws -> Data {
        guard configurations.count <= 32 else { throw Error.invalid }
        for configuration in configurations { _ = try configuration.validated() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configurations)
    }
    public static func decode(_ data: Data) throws -> [RNodeConfiguration] {
        guard data.count <= 1_024 * 1_024 else { throw Error.invalid }
        let values = try JSONDecoder().decode([RNodeConfiguration].self, from: data)
        guard values.count <= 32, Set(values.map(\.id)).count == values.count else { throw Error.invalid }
        return try values.map { try $0.validated() }
    }
    public enum Error: Swift.Error { case invalid }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
