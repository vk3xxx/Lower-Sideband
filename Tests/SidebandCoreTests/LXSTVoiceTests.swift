import Foundation
import Testing
@testable import SidebandCore

struct LXSTVoiceTests {
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
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
