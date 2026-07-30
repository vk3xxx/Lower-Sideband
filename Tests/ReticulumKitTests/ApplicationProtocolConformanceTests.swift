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

    @Test("RNCP resource metadata round-trips and detects corruption")
    func remoteCopyResourceRoundTrip() throws {
        let file = Data((0..<32_768).map { UInt8($0 & 0xff) })
        let metadata = try ReticulumCopyProtocol.TransferMetadata(
            filename: "fixture.bin",
            size: UInt64(file.count),
            sha256: ReticulumIdentity.fullHash(file)
        )
        let payload = try ReticulumCopyProtocol.TransferMetadata.resourcePayload(
            metadata: metadata,
            fileData: file
        )
        let decoded = try ReticulumCopyProtocol.TransferMetadata.decodeResourcePayload(payload)
        #expect(decoded.metadata == metadata)
        #expect(decoded.fileData == file)
        var corrupt = payload
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xff
        #expect(throws: ReticulumCopyProtocol.CopyError.integrityMismatch) {
            try ReticulumCopyProtocol.TransferMetadata.decodeResourcePayload(corrupt)
        }
    }

    @Test("Nomad and RNCP requests decode with stable correlation")
    func requestEnvelopeRoundTrip() throws {
        let request = try ReticulumCopyProtocol.fetchEnvelope(remotePath: "fixture.bin", timestamp: 42)
        let decoded = try ReticulumPathRequestEnvelope.decodeRequest(request.encoded)
        #expect(decoded.requestID == request.requestID)
        #expect(decoded.matches(path: ReticulumCopyProtocol.fetchPath))
        #expect(decoded.data == .string("fixture.bin"))
        let response = try ReticulumPathRequestEnvelope.response(
            requestID: decoded.requestID,
            value: .binary(Data("ok".utf8))
        )
        #expect(try ReticulumPathRequestEnvelope.decodeResponse(
            response,
            expectedRequestID: request.requestID
        ) == Data("ok".utf8))
    }

    @Test("Hosted relay enforces keys, moderation, bans and fanout")
    func hostedRelayPolicy() throws {
        let alice = Data(repeating: 0x11, count: 16)
        let bob = Data(repeating: 0x22, count: 16)
        let room = try ReticulumRelayHub.RoomPolicy(
            name: "ops",
            accessKey: "secret",
            isModerated: true,
            voicedIdentityHashes: [alice]
        )
        var hub = try ReticulumRelayHub(
            configuration: .init(name: "Test Hub", rooms: [room], bannedIdentityHashes: []),
            hubIdentityHash: Data(repeating: 0xaa, count: 16)
        )
        hub.connect(linkID: "alice")
        hub.connect(linkID: "bob")
        try hub.identify(linkID: "alice", identityHash: alice)
        try hub.identify(linkID: "bob", identityHash: bob)
        for (link, identity, nickname) in [("alice", alice, "Alice"), ("bob", bob, "Bob")] {
            _ = hub.receive(try .init(type: .hello, source: identity, nickname: nickname), on: link)
            let joined = hub.receive(
                try .init(type: .join, source: identity, room: "ops", body: .text("secret"), nickname: nickname),
                on: link
            )
            #expect(!joined.isEmpty)
        }
        let accepted = hub.receive(
            try .init(type: .message, source: alice, room: "ops", body: .text("authorised")),
            on: "alice"
        )
        #expect(accepted.contains { $0.linkID == "bob" })
        let rejected = hub.receive(
            try .init(type: .message, source: bob, room: "ops", body: .text("blocked")),
            on: "bob"
        )
        #expect(rejected.contains { $0.linkID == "bob" && $0.message.type == .error })

        var bannedHub = try ReticulumRelayHub(
            configuration: .init(name: "Banned", rooms: [room], bannedIdentityHashes: [bob]),
            hubIdentityHash: Data(repeating: 0xbb, count: 16)
        )
        bannedHub.connect(linkID: "bob")
        #expect(throws: ReticulumRelayHub.HubError.banned) {
            try bannedHub.identify(linkID: "bob", identityHash: bob)
        }
    }
}
