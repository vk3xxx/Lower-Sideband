import Foundation
import Testing
@testable import SidebandCore

struct LXSTVoiceTests {
    @Test func jitterBufferPrimesDrainsAndReprimesAfterUnderrun() {
        var buffer = LXSTJitterBuffer(targetDepth: 3, maximumDepth: 5)
        buffer.enqueue(Data([1]))
        buffer.enqueue(Data([2]))
        #expect(buffer.nextFrame() == nil)
        buffer.enqueue(Data([3]))
        #expect(buffer.nextFrame() == Data([1]))
        #expect(buffer.nextFrame() == Data([2]))
        #expect(buffer.nextFrame() == Data([3]))
        #expect(buffer.nextFrame() == nil)
        #expect(buffer.underrunCount == 1)
        buffer.enqueue(Data([4]))
        #expect(buffer.nextFrame() == nil)
    }

    @Test func jitterBufferBoundsLatencyByDroppingOldestFrames() {
        var buffer = LXSTJitterBuffer(targetDepth: 2, maximumDepth: 3)
        for value in 1...5 { buffer.enqueue(Data([UInt8(value)])) }
        #expect(buffer.count == 3)
        #expect(buffer.droppedFrameCount == 2)
        #expect(buffer.nextFrame() == Data([3]))
    }

    @Test func pythonCompatibleSignallingFixtures() throws {
        #expect(LXSTVoice.signalling([LXSTVoice.Signal.available.rawValue]).hexString == "81009103")
        #expect(LXSTVoice.preferredProfile(.mediumQuality).hexString == "810091cd013f")
        #expect(try LXSTVoice.decode(Data([0x81, 0x00, 0x91, 0x04])) == .signals([4]))
    }

    @Test func pythonCompatibleOpusFrameFixture() throws {
        let encoded = LXSTVoice.frame(codec: .opus, payload: Data("abc".utf8))
        #expect(encoded.hexString == "8101c40401616263")
        #expect(try LXSTVoice.decode(encoded) == .frame(codec: .opus, payload: Data("abc".utf8)))
    }

    @Test func nativeCodec2SupportsEveryPythonBoundMode() throws {
        for mode in Codec2Codec.Mode.allCases {
            let codec = try Codec2Codec(mode: mode)
            #expect(codec.samplesPerFrame > 0)
            #expect(codec.bitsPerFrame > 0)
            #expect(codec.bytesPerFrame == (codec.bitsPerFrame + 7) / 8)
            let payload = try codec.encode([Int16](repeating: 0, count: codec.samplesPerFrame))
            #expect(payload.count == codec.bytesPerFrame)
            #expect(try codec.decode(payload).count == codec.samplesPerFrame)
        }
    }

    @Test func codec2ProfilesAndLXMFModesMapWithoutAmbiguity() throws {
        #expect(LXSTVoice.Profile.ultraLowBandwidth.codec2Mode == .bitrate700C)
        #expect(LXSTVoice.Profile.veryLowBandwidth.codec2Mode == .bitrate1200)
        #expect(LXSTVoice.Profile.lowBandwidth.codec2Mode == .bitrate2400)
        #expect(LXSTVoice.Profile.mediumQuality.codec2Mode == nil)
        #expect(LXSTVoice.Profile.allCases.filter(\.isLocallySupported).count == 4)
        #expect(LXMFVoiceMessageAudio.Mode.codec2_700C.codec2Mode == .bitrate700C)
        #expect(LXMFVoiceMessageAudio.Mode.codec2_2400.codec2Mode == .bitrate2400)
        #expect(LXMFVoiceMessageAudio.Mode.codec2_450.codec2Mode == nil)

        let codec = try Codec2Codec(mode: .bitrate1200)
        let framed = LXSTVoice.frame(codec: .codec2, payload: try codec.encode(.init(repeating: 0, count: codec.samplesPerFrame)))
        guard case let .frame(frameCodec, payload) = try LXSTVoice.decode(framed) else {
            Issue.record("Codec2 LXST frame did not decode")
            return
        }
        #expect(frameCodec == .codec2)
        #expect(payload.count == codec.bytesPerFrame)
    }

    @Test func pythonCompatibleLXMURIEncodingAndLimits() throws {
        #expect(try LXMURI.encode(Data([0xfb, 0xef])) == "lxm://--8")
        #expect(try LXMURI.decode("lxm://--8") == Data([0xfb, 0xef]))
        #expect(throws: LXMURI.Error.self) { try LXMURI.encode(Data(repeating: 0, count: LXMURI.maximumPackedBytes + 1)) }
        #expect(throws: LXMURI.Error.self) { try LXMURI.decode("https://example.com") }
    }

    @Test func encryptedPaperMessageRoundTripsWithoutNetwork() throws {
        let source = try ReticulumIdentity(privateKey: Data((0..<64).map(UInt8.init)))
        let recipient = try ReticulumIdentity(privateKey: Data((64..<128).map(UInt8.init)))
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(combine(nameHash, source.hash))
        let destinationHash = ReticulumIdentity.truncatedHash(combine(nameHash, recipient.hash))
        let message = try LXMFMessage(destinationHash: destinationHash, sourceHash: sourceHash, sourceIdentity: source, timestamp: 1_700_000_000, content: Data("Paper hello".utf8))
        let uri = try message.paperURI(
            recipientIdentity: recipient,
            ephemeralPrivateKey: Data(repeating: 0x42, count: 32),
            iv: Data(repeating: 0x24, count: 16)
        )

        let paperPacked = try LXMURI.decode(uri)
        #expect(paperPacked.prefix(16) == destinationHash)
        let decrypted = try recipient.decrypt(Data(paperPacked.dropFirst(16)))
        let received = try LXMFReceivedMessage(packed: combine(destinationHash, decrypted))
        #expect(received.content == Data("Paper hello".utf8))
        #expect(received.validate(with: source))
    }

    @Test func destinationUsesTelephonyAspectAndIdentity() {
        let identity = ReticulumIdentity()
        #expect(LXSTVoice.destinationHash(for: identity).count == 16)
        #expect(LXSTVoice.destinationHash(for: identity) != ReticulumIdentity.truncatedHash(identity.hash))
    }

    @Test func encryptedLinkCloseMatchesReticulumSemantics() throws {
        let session = ReticulumLinkSession(
            linkID: Data(repeating: 0x22, count: 16),
            destinationHash: Data(repeating: 0x33, count: 16),
            peerPublicKey: Data(repeating: 0x44, count: 32),
            derivedKey: Data(repeating: 0x55, count: 64),
            mtu: 500
        )
        let packet = try ReticulumPacket(raw: session.closePacket())
        #expect(packet.context == 0xfc)
        #expect(try session.decrypt(packet) == session.linkID)
    }

    @Test func encryptedSnapshotsPreserveCallHistoryModel() throws {
        let conversation = Conversation(destinationHash: String(repeating: "ab", count: 16), displayName: "Alice")
        let call = VoiceCall(conversationID: conversation.id, direction: .outgoing, state: .idle, connectedAt: .now, endedAt: .now)
        let data = try JSONEncoder().encode(AppSnapshot(conversations: [conversation], voiceCallHistory: [call]))
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)
        #expect(decoded.voiceCallHistory == [call])
    }

    @Test func callHistoryClassifiesOutcomesAndDuration() {
        let conversationID = UUID()
        let connected = Date(timeIntervalSince1970: 100)
        let completed = VoiceCall(conversationID: conversationID, direction: .outgoing, state: .idle, connectedAt: connected, endedAt: connected.addingTimeInterval(65))
        let missed = VoiceCall(conversationID: conversationID, direction: .incoming, state: .failed, endedAt: .now, failureReason: "Timed out")
        let declined = VoiceCall(conversationID: conversationID, direction: .incoming, state: .idle, endedAt: .now)
        let failed = VoiceCall(conversationID: conversationID, direction: .outgoing, state: .failed, endedAt: .now, failureReason: "No route")
        let cancelled = VoiceCall(conversationID: conversationID, direction: .outgoing, state: .idle, endedAt: .now)

        #expect(completed.historyOutcome == .completed)
        #expect(completed.connectedDuration == 65)
        #expect(missed.historyOutcome == .missed)
        #expect(declined.historyOutcome == .declined)
        #expect(failed.historyOutcome == .failed)
        #expect(cancelled.historyOutcome == .cancelled)
    }

    private func combine(_ first: Data, _ second: Data) -> Data {
        var value = first
        value.append(second)
        return value
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
