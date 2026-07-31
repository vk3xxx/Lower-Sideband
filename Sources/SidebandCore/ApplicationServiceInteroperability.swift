import CryptoKit
import Foundation
import ReticulumKit

public struct ApplicationServiceInteroperabilityResult: Identifiable, Codable, Hashable, Sendable {
    public let kind: ReticulumApplicationServiceKind
    public let passed: Bool
    public let detail: String
    public let checkedAt: Date
    public var id: String { kind.rawValue }

    public init(kind: ReticulumApplicationServiceKind, passed: Bool, detail: String, checkedAt: Date = .now) {
        self.kind = kind
        self.passed = passed
        self.detail = String(detail.prefix(512))
        self.checkedAt = checkedAt
    }
}

/// Deterministic wire-format checks for every Reticulum application service
/// supported by Lower Sideband. These exercise the same bounded codecs used by
/// live links without opening a route or changing network configuration.
public enum ApplicationServiceInteroperabilitySuite {
    public static func run() -> [ApplicationServiceInteroperabilityResult] {
        [
            check(.nomad, detail: "Nomad request, query and response framing") { try checkNomad() },
            check(.relay, detail: "RRC canonical-CBOR hello and message framing") { try checkRelay() },
            check(.shell, detail: "RNSH channel version, stream and terminal framing") { try checkShell() },
            check(.execution, detail: "RNX request and result MessagePack framing") { try checkExecution() },
            check(.copy, detail: "RNCP metadata, payload integrity and traversal rejection") { try checkCopy() }
        ]
    }

    private static func check(
        _ kind: ReticulumApplicationServiceKind,
        detail: String,
        operation: () throws -> Void
    ) -> ApplicationServiceInteroperabilityResult {
        do {
            try operation()
            return .init(kind: kind, passed: true, detail: detail)
        } catch {
            return .init(kind: kind, passed: false, detail: "\(detail): \(error.localizedDescription)")
        }
    }

    private static func checkNomad() throws {
        let request = try NomadNetworkProtocol.pageRequest(
            path: "/page/index.mu",
            query: ["callsign": "VK3XXX"],
            timestamp: 1_700_000_000
        )
        let decoded = try ReticulumPathRequestEnvelope.decodeRequest(request.encoded)
        guard decoded.matches(path: "/page/index.mu"),
              case let .map(entries) = decoded.data,
              entries.contains(where: { $0.0 == .string("var_callsign") && $0.1 == .string("VK3XXX") })
        else { throw InteroperabilityError.roundTripFailed }
        let page = Data("# Lower Sideband\nReady".utf8)
        let response = try ReticulumPathRequestEnvelope.response(requestID: request.requestID, value: .binary(page))
        guard try ReticulumPathRequestEnvelope.decodeResponse(response, expectedRequestID: request.requestID) == page
        else { throw InteroperabilityError.roundTripFailed }
        guard (try? ReticulumPathRequestEnvelope.decodeResponse(response, expectedRequestID: Data(repeating: 1, count: 16))) == nil
        else { throw InteroperabilityError.malformedInputAccepted }
    }

    private static func checkRelay() throws {
        let hello = try ReticulumRelayChatProtocol.helloBody(
            client: "Lower Sideband",
            clientVersion: "1",
            capabilities: [3, 1, 2]
        )
        let message = try ReticulumRelayChatProtocol.Message(
            type: .hello,
            messageID: Data(repeating: 0x31, count: 8),
            timestampMilliseconds: 1_700_000_000_000,
            source: Data(repeating: 0x42, count: 16),
            room: "general",
            body: hello,
            nickname: "VK3XXX"
        )
        let encoded = try message.encoded
        guard try ReticulumRelayChatProtocol.Message.decode(encoded) == message else {
            throw InteroperabilityError.roundTripFailed
        }
        guard (try? ReticulumRelayChatProtocol.Message.decode(Data(encoded.dropLast()))) == nil else {
            throw InteroperabilityError.malformedInputAccepted
        }
    }

    private static func checkShell() throws {
        let version = ReticulumShellProtocol.Message.version(software: "Lower Sideband", protocolVersion: 1)
        let versionEnvelope = try ReticulumShellProtocol.envelope(for: version, sequence: 7)
        guard try ReticulumShellProtocol.decode(versionEnvelope) == version else {
            throw InteroperabilityError.roundTripFailed
        }
        let stream = ReticulumShellProtocol.Message.stream(
            id: .stdin,
            data: Data("status\n".utf8),
            eof: false,
            compressed: false
        )
        guard try ReticulumShellProtocol.decode(ReticulumShellProtocol.envelope(for: stream, sequence: 8)) == stream else {
            throw InteroperabilityError.roundTripFailed
        }
        let invalid = try ReticulumChannel.Envelope(messageType: 1, sequence: 0, payload: Data())
        guard (try? ReticulumShellProtocol.decode(invalid)) == nil else {
            throw InteroperabilityError.malformedInputAccepted
        }
    }

    private static func checkExecution() throws {
        let request = try ReticulumRemoteExecutionProtocol.Request(
            command: "printf ready",
            timeout: 30,
            stdoutLimit: 4_096,
            stderrLimit: 4_096
        )
        let envelope = try ReticulumRemoteExecutionProtocol.requestEnvelope(request, timestamp: 1_700_000_000)
        let decoded = try ReticulumPathRequestEnvelope.decodeRequest(envelope.encoded)
        guard decoded.matches(path: ReticulumRemoteExecutionProtocol.requestPath),
              decoded.data == request.value else { throw InteroperabilityError.roundTripFailed }
        let resultData = MessagePack.array([
            MessagePack.bool(true),
            MessagePack.signed(0),
            MessagePack.binary(Data("ready".utf8)),
            MessagePack.binary(Data()),
            MessagePack.unsigned(5),
            MessagePack.unsigned(0),
            MessagePack.double(1_700_000_000),
            MessagePack.double(1_700_000_001)
        ])
        let result = try ReticulumRemoteExecutionProtocol.Result.decode(resultData)
        guard result.executed, result.exitCode == 0, result.stdout == Data("ready".utf8) else {
            throw InteroperabilityError.roundTripFailed
        }
        guard (try? ReticulumRemoteExecutionProtocol.Result.decode(Data(resultData.dropLast()))) == nil else {
            throw InteroperabilityError.malformedInputAccepted
        }
    }

    private static func checkCopy() throws {
        let file = Data("Lower Sideband RNCP fixture".utf8)
        let metadata = try ReticulumCopyProtocol.TransferMetadata(
            filename: "fixture.txt",
            size: UInt64(file.count),
            sha256: Data(SHA256.hash(data: file))
        )
        let payload = try ReticulumCopyProtocol.TransferMetadata.resourcePayload(metadata: metadata, fileData: file)
        let decoded = try ReticulumCopyProtocol.TransferMetadata.decodeResourcePayload(payload)
        guard decoded.metadata == metadata, decoded.fileData == file else {
            throw InteroperabilityError.roundTripFailed
        }
        guard (try? ReticulumCopyProtocol.TransferMetadata(
            filename: "../unsafe",
            size: 0,
            sha256: Data(repeating: 0, count: 32)
        )) == nil else { throw InteroperabilityError.malformedInputAccepted }
    }

    private enum InteroperabilityError: LocalizedError {
        case roundTripFailed
        case malformedInputAccepted

        var errorDescription: String? {
            switch self {
            case .roundTripFailed: "Reference-compatible round trip failed"
            case .malformedInputAccepted: "Malformed input was not rejected"
            }
        }
    }
}
