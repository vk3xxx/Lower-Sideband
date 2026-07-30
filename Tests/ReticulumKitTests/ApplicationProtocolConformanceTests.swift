import Foundation
import Testing
@testable import ReticulumKit

@Suite("Reticulum application protocol conformance")
struct ApplicationProtocolConformanceTests {
    @Test("Canonical CBOR uses deterministic integer-key ordering")
    func deterministicCBOR() throws {
        let value: CanonicalCBORValue = .map([
            .unsigned(10): .text("ten"),
            .unsigned(1): .text("one"),
            .text("z"): .bool(true)
        ])
        let encoded = try CanonicalCBOR.encode(value)
        #expect(encoded == Data([0xa3, 0x01, 0x63, 0x6f, 0x6e, 0x65, 0x0a, 0x63, 0x74, 0x65, 0x6e, 0x61, 0x7a, 0xf5]))
        #expect(try CanonicalCBOR.decode(encoded) == value)
        #expect(throws: CanonicalCBOR.CodecError.nonCanonical) {
            try CanonicalCBOR.decode(Data([0xa2, 0x01, 0x00, 0x00, 0x00]))
        }
    }

    @Test("RRC packet matches the MeshChatX version-one integer-key envelope")
    func relayChatEnvelope() throws {
        let source = Data(repeating: 0xaa, count: 16)
        let message = try ReticulumRelayChatProtocol.Message(
            type: .message,
            messageID: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            timestampMilliseconds: 1_000,
            source: source,
            room: "#test",
            body: .text("hello"),
            nickname: "swift"
        )
        let encoded = try message.encoded
        let decoded = try ReticulumRelayChatProtocol.Message.decode(encoded)
        #expect(decoded == message)
        #expect(encoded.prefix(3) == Data([0xa8, 0x00, 0x01]))
        #expect(ReticulumRelayChatProtocol.mentions(in: "hello @Swift!", nickname: "swift"))
        #expect(!ReticulumRelayChatProtocol.mentions(in: "hello @swiftish", nickname: "swift"))
    }

    @Test("RNSH Channel header and message types match upstream")
    func shellChannelFrames() throws {
        let window = try ReticulumShellProtocol.envelope(
            for: .windowSize(rows: 24, columns: 80, horizontalPixels: 0, verticalPixels: 0),
            sequence: 0x1234
        )
        #expect(window.messageType == 0xac02)
        #expect(window.encoded.prefix(6) == Data([0xac, 0x02, 0x12, 0x34, 0x00, 0x05]))
        #expect(try ReticulumShellProtocol.decode(.decode(window.encoded)) == .windowSize(rows: 24, columns: 80, horizontalPixels: 0, verticalPixels: 0))

        let stream = try ReticulumShellProtocol.envelope(
            for: .stream(id: .stdout, data: Data("ok".utf8), eof: true, compressed: false),
            sequence: 2
        )
        #expect(stream.messageType == 0xac04)
        #expect(stream.payload == Data([0x80, 0x01, 0x6f, 0x6b]))
        #expect(try ReticulumShellProtocol.decode(stream) == .stream(id: .stdout, data: Data("ok".utf8), eof: true, compressed: false))
    }

    @Test("Channel receiver orders, deduplicates and bounds frames")
    func channelOrdering() throws {
        var receiver = ReticulumChannel.Receiver(maximumBuffered: 4)
        let one = try ReticulumChannel.Envelope(messageType: 1, sequence: 1, payload: Data([1]))
        let zero = try ReticulumChannel.Envelope(messageType: 1, sequence: 0, payload: Data([0]))
        #expect(receiver.ingest(one).isEmpty)
        #expect(receiver.ingest(zero).map(\.sequence) == [0, 1])
        #expect(receiver.ingest(zero).isEmpty)
    }

    @Test("RNX request and response match the official eight-field shape")
    func remoteExecution() throws {
        let request = try ReticulumRemoteExecutionProtocol.Request(command: "uname -a", timeout: 15)
        guard case let .array(values) = request.value else { Issue.record("Not an RNX request array"); return }
        #expect(values.count == 5)
        #expect(values[0] == .binary(Data("uname -a".utf8)))

        let response = MessagePack.array([
            MessagePack.bool(true), MessagePack.signed(0),
            MessagePack.binary(Data("Darwin\n".utf8)), MessagePack.binary(Data()),
            MessagePack.unsigned(7), MessagePack.unsigned(0),
            MessagePack.double(10), MessagePack.double(11)
        ])
        let result = try ReticulumRemoteExecutionProtocol.Result.decode(response)
        #expect(result.executed && result.exitCode == 0)
        #expect(result.stdout == Data("Darwin\n".utf8))
    }

    @Test("RNCP rejects path traversal filenames and frames stock fetch requests")
    func remoteCopySafety() throws {
        #expect(throws: ReticulumCopyProtocol.CopyError.unsafeMetadata) {
            try ReticulumCopyProtocol.TransferMetadata(filename: "../secret", size: 1, sha256: Data(repeating: 0, count: 32))
        }
        let metadata = try ReticulumCopyProtocol.TransferMetadata(filename: "report.bin", size: 1, sha256: Data(repeating: 1, count: 32))
        #expect(!metadata.messagePack.isEmpty)
        let fetch = try ReticulumCopyProtocol.fetchEnvelope(remotePath: "/safe/report.bin", timestamp: 123)
        #expect(fetch.path == "fetch_file")
        #expect(!fetch.encoded.isEmpty)
    }
}
