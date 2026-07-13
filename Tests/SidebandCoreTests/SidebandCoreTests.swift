import Foundation
import Testing
@testable import SidebandCore

@Test func explicitSingleDestinationProofUsesPacketHashForRoutingAndSignature() throws {
    let identity = ReticulumIdentity()
    let destination = Data(repeating: 0x22, count: 16)
    let raw = Data([0x00, 0x00]) + destination + Data([0x00, 0x41, 0x42])
    let received = try ReticulumPacket(raw: raw)
    let proof = try ReticulumPacket(raw: ReticulumProof.packet(for: received, identity: identity))

    #expect(proof.packetType == .proof)
    #expect(proof.destinationType == .single)
    #expect(proof.destinationHash == received.packetHash.prefix(16))
    #expect(proof.data.prefix(32) == received.packetHash)
    #expect(identity.validate(signature: Data(proof.data.suffix(64)), message: received.packetHash))
}

@Test func opportunisticLXMFPacketRoundTripsThroughRecipientIdentity() throws {
    let source = try ReticulumIdentity(privateKey: Data(0..<64))
    let recipient = try ReticulumIdentity(privateKey: Data(64..<128))
    let destination = ReticulumIdentity.truncatedHash(Data("destination".utf8))
    let sourceHash = ReticulumIdentity.truncatedHash(Data("source".utf8))
    let message = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: source, timestamp: 1_700_000_000, content: Data("hello".utf8))
    let raw = try message.opportunisticPacket(recipientIdentity: recipient, ephemeralPrivateKey: Data(repeating: 7, count: 32), iv: Data(repeating: 9, count: 16))
    let packet = try ReticulumPacket(raw: raw)
    let decrypted = try recipient.decrypt(packet.data)
    let received = try LXMFReceivedMessage(packed: packet.destinationHash + decrypted)

    #expect(raw.count <= 500)
    #expect(packet.packetType == .data)
    #expect(packet.destinationType == .single)
    #expect(received.content == Data("hello".utf8))
    #expect(received.validate(with: source))
}

@Test func destinationValidation() {
    #expect(DestinationHash.isValid("0123456789abcdef0123456789ABCDEF"))
    #expect(!DestinationHash.isValid("0123"))
    #expect(!DestinationHash.isValid("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
}

@Test func sidebandContactLinksRoundTripNameAndDestination() throws {
    let hash = "0123456789abcdef0123456789abcdef"
    let contact = try #require(SidebandContactLink(destinationHash: hash, displayName: "Mesh Peer"))
    let decoded = try #require(SidebandContactLink(url: contact.url))

    #expect(contact.url.absoluteString == "sideband://contact/0123456789abcdef0123456789abcdef?name=Mesh%20Peer")
    #expect(decoded == contact)
    #expect(SidebandContactLink(string: "https://example.com") == nil)
    #expect(SidebandContactLink(destinationHash: "invalid") == nil)
}

@MainActor @Test func queuesMessagesWithoutClaimingDelivery() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Test"))
    await store.send("hello")
    #expect(store.messages.count == 1)
    #expect(store.messages[0].state == .queued)
}

@MainActor @Test func rejectsOversizedMessageText() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    await store.send(String(repeating: "x", count: SidebandMessageLimits.maximumTextCharacters + 1))
    #expect(store.messages.isEmpty)
    #expect(store.lastError != nil)
}

@MainActor @Test func rejectsTooManyMessageAttachments() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let attachments = (0...SidebandMessageLimits.maximumAttachments).map {
        Attachment(filename: "\($0).bin", byteCount: 0, relativePath: "\($0).bin", state: .local)
    }
    await store.send("too many", attachments: attachments)
    #expect(store.messages.isEmpty)
    #expect(store.lastError != nil)
}

@MainActor @Test func latestMessageUsesTimestampOrder() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let newer = Message(conversationID: conversation.id, body: "newer", timestamp: Date(timeIntervalSince1970: 20), direction: .incoming, state: .delivered)
    let older = Message(conversationID: conversation.id, body: "older", timestamp: Date(timeIntervalSince1970: 10), direction: .incoming, state: .delivered)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [newer, older])).write(to: url)

    let store = SidebandStore(persistenceURL: url)
    #expect(store.latestMessage(for: conversation.id)?.id == newer.id)
}

@MainActor @Test func conversationTranscriptIncludesMessagesAndAttachments() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let attachment = Attachment(filename: "photo.jpg", byteCount: 1, relativePath: "photo.jpg", state: .available)
    let message = Message(conversationID: conversation.id, body: "hello", timestamp: Date(timeIntervalSince1970: 0), direction: .incoming, state: .delivered, attachments: [attachment])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)

    let transcript = try #require(SidebandStore(persistenceURL: url).conversationTranscript(conversation.id))
    #expect(transcript.contains("Peer: hello [Attachment: photo.jpg]"))
    #expect(transcript.contains(conversation.destinationHash))
}

@MainActor @Test func conversationContactCardIncludesNameDestinationAndTrust() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer", isTrusted: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation])).write(to: url)

    let card = try #require(SidebandStore(persistenceURL: url).conversationContactCard(conversation.id))
    #expect(card.contains("Name: Peer"))
    #expect(card.contains("LXMF Destination: \(conversation.destinationHash)"))
    #expect(card.contains("Trusted: yes"))
    #expect(card.contains("sideband://contact/\(conversation.destinationHash)?name=Peer"))
}

@MainActor @Test func archivedConversationStatePersistsAndUnpins() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.setConversationPinned(true, conversationID: id)
    store.setConversationArchived(true, conversationID: id)

    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.conversations[0].isArchived)
    #expect(!reloaded.conversations[0].isPinned)
}

@MainActor @Test func blockedConversationStatePersistsAndPreventsSending() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.setConversationBlocked(true, conversationID: id)
    await store.send("hello")

    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.conversations[0].isBlocked)
    #expect(reloaded.conversations[0].notificationsMuted)
    #expect(reloaded.messages.isEmpty)
}

@MainActor @Test func blockedSourceIsRejectedByInboundPolicy() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let hash = "0123456789abcdef0123456789abcdef"
    #expect(store.addConversation(destinationHash: hash, displayName: "Peer"))
    #expect(!store.isSourceBlocked(hash))
    store.setConversationBlocked(true, conversationID: store.conversations[0].id)
    #expect(store.isSourceBlocked(hash.uppercased()))
}

@MainActor @Test func clearingHistoryKeepsConversationAndRemovesMessages() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer", unreadCount: 3)
    let message = Message(conversationID: conversation.id, body: "hello", direction: .incoming, state: .delivered)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    await store.clearConversationHistory(conversation.id)
    #expect(store.conversations.count == 1)
    #expect(store.messages.isEmpty)
    #expect(store.conversations[0].unreadCount == 0)
}

@MainActor @Test func retryMessageRequeuesFailedAttachments() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let attachment = Attachment(filename: "retry.bin", byteCount: 1, relativePath: "retry.bin", state: .failed)
    let message = Message(conversationID: conversation.id, body: "retry", direction: .outgoing, state: .failed, attachments: [attachment])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)

    let store = SidebandStore(persistenceURL: url)
    await store.retryMessage(message.id)
    #expect(store.messages[0].state == .queued)
    #expect(store.messages[0].attachments[0].state == .queued)
}

@MainActor @Test func removeFailedMessageKeepsDeliveredHistory() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let failed = Message(conversationID: conversation.id, body: "failed", direction: .outgoing, state: .failed)
    let delivered = Message(conversationID: conversation.id, body: "delivered", direction: .outgoing, state: .delivered)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [failed, delivered])).write(to: url)

    let store = SidebandStore(persistenceURL: url)
    await store.removeFailedMessage(failed.id)
    await store.removeFailedMessage(delivered.id)
    #expect(store.messages.map(\.id) == [delivered.id])
}

@MainActor @Test func recoversUnprovedSentOutboxAcrossRelaunch() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let message = Message(conversationID: conversation.id, body: "retry me", direction: .outgoing, state: .sent)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(store.messages[0].state == .queued)
    #expect(store.recoveredOutboundCount == 1)
}

@MainActor @Test func showingConversationClearsPersistedUnreadCount() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let unread = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Unread", unreadCount: 3)
    let selected = Conversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Selected")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [selected, unread])).write(to: url)

    let store = SidebandStore(persistenceURL: url)
    #expect(store.totalUnreadCount == 3)
    #expect(store.conversations.first(where: { $0.id == unread.id })?.unreadCount == 3)
    store.selectedConversationID = unread.id
    #expect(store.conversations.first(where: { $0.id == unread.id })?.unreadCount == 3)
    store.conversationDidAppear(unread.id)
    #expect(store.conversations.first(where: { $0.id == unread.id })?.unreadCount == 0)
    #expect(store.totalUnreadCount == 0)

    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.conversations.first(where: { $0.id == unread.id })?.unreadCount == 0)
}

@MainActor @Test func conversationCanBeMarkedUnreadExplicitly() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.markConversationUnread(id)
    #expect(store.conversations[0].unreadCount == 1)
    #expect(SidebandStore(persistenceURL: url).conversations[0].unreadCount == 1)
}

@MainActor @Test func addingBackgroundConversationDoesNotReplaceSelection() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Selected"))
    let selectedID = store.selectedConversationID

    #expect(store.addConversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Background", select: false))
    #expect(store.selectedConversationID == selectedID)
}

@MainActor @Test func renameConversationPersistsNonemptyName() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Original"))
    let id = store.conversations[0].id
    #expect(!store.renameConversation(id, to: "   "))
    #expect(store.renameConversation(id, to: " Renamed "))
    #expect(SidebandStore(persistenceURL: url).conversations[0].displayName == "Renamed")
}

@MainActor @Test func deleteConversationRemovesOnlyItsMessages() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let first = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "First")
    let second = Conversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Second")
    let firstMessage = Message(conversationID: first.id, body: "remove", direction: .incoming, state: .delivered)
    let secondMessage = Message(conversationID: second.id, body: "keep", direction: .incoming, state: .delivered)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [first, second], messages: [firstMessage, secondMessage])).write(to: url)

    let store = SidebandStore(persistenceURL: url)
    await store.deleteConversation(first.id)
    #expect(store.conversations.map(\.id) == [second.id])
    #expect(store.messages.map(\.id) == [secondMessage.id])
}

@MainActor @Test func trustedConversationStatePersists() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.setConversationTrusted(true, conversationID: id)
    #expect(SidebandStore(persistenceURL: url).conversations[0].isTrusted)
}

@MainActor @Test func pinnedConversationsSortFirstAndPersist() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "First"))
    #expect(store.addConversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Second"))
    let firstID = store.conversations.first(where: { $0.displayName == "First" })!.id
    store.setConversationPinned(true, conversationID: firstID)
    #expect(store.conversations.first?.id == firstID)
    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.conversations.first?.id == firstID)
    #expect(reloaded.conversations.first?.isPinned == true)
}

@MainActor @Test func mutedConversationStatePersists() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.setConversationNotificationsMuted(true, conversationID: id)
    #expect(!store.shouldNotifyIncoming(for: id))
    #expect(SidebandStore(persistenceURL: url).conversations[0].notificationsMuted)
    store.setConversationNotificationsMuted(false, conversationID: id)
    #expect(store.shouldNotifyIncoming(for: id))
}

@MainActor @Test func conversationDraftPersistsAndClears() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.updateDraft("unfinished", for: id)
    #expect(SidebandStore(persistenceURL: url).draft(for: id) == "unfinished")
    store.updateDraft("", for: id)
    #expect(SidebandStore(persistenceURL: url).draft(for: id).isEmpty)
}

@MainActor @Test func selectedConversationRemainsUnreadUntilApplicationIsActive() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Selected"))
    let selectedID = try #require(store.selectedConversationID)
    store.conversationDidAppear(selectedID)

    store.applicationDidBecomeInactive()
    store.noteIncomingActivity(in: selectedID)
    #expect(store.conversations.first?.unreadCount == 1)

    await store.applicationDidBecomeActive()
    #expect(store.conversations.first?.unreadCount == 0)
}

@Test func attachmentStoreImportsFilesAndReturnsDurableMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "sample.txt")
    try Data("attachment".utf8).write(to: source)
    let store = AttachmentStore(directory: root.appending(path: "stored"))
    let attachment = try await store.importFile(from: source)
    let storedURL = await store.url(for: attachment)

    #expect(attachment.filename == "sample.txt")
    #expect(attachment.byteCount == 10)
    #expect(FileManager.default.fileExists(atPath: storedURL.path))
    #expect(attachment.contentHash != nil)
}

@Test func attachmentStoreRejectsCorruptedLocalFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "original.bin")
    try Data([1, 2, 3]).write(to: source)
    let store = AttachmentStore(directory: root.appending(path: "stored"))
    let attachment = try await store.importFile(from: source)
    try Data([9, 9, 9]).write(to: await store.url(for: attachment))
    do { _ = try await store.read(attachment); Issue.record("Corrupted attachment was accepted") }
    catch AttachmentStoreError.integrityMismatch { }
}

@Test func resourcePartsVerifyReassembleAndReportProgress() throws {
    let data = Data((0..<1_200).map { UInt8($0 % 251) })
    let manifest = try ReticulumResourceManifest(data: data, randomHash: Data([1, 2, 3, 4]))
    let parts = try manifest.parts(from: data)
    var receiver = ReticulumResourceReceiver(manifest: manifest)

    #expect(manifest.partCount == 3)
    try receiver.accept(part: parts[1], at: 1)
    #expect(receiver.progress == 1.0 / 3.0)
    try receiver.accept(part: parts[0], at: 0)
    try receiver.accept(part: parts[2], at: 2)
    #expect(receiver.isComplete)
    #expect(try receiver.assemble() == data)
}

@Test func resourceReceiverRejectsCorruptParts() throws {
    let data = Data(repeating: 0x41, count: 600)
    let manifest = try ReticulumResourceManifest(data: data, randomHash: Data([1, 1, 1, 1]))
    var receiver = ReticulumResourceReceiver(manifest: manifest)
    #expect(throws: ResourceError.self) { try receiver.accept(part: Data(repeating: 0x42, count: 465), at: 0) }
}

@Test func resourceAdvertisementRoundTripsProtocolFields() throws {
    let data = Data(repeating: 0x31, count: 900)
    let manifest = try ReticulumResourceManifest(data: data, randomHash: Data([1, 2, 3, 4]))
    let advertisement = ReticulumResourceAdvertisement(manifest: manifest)
    let decoded = try ReticulumResourceAdvertisement(encoded: advertisement.encode())

    #expect(decoded.transferSize == 900)
    #expect(decoded.partCount == 2)
    #expect(decoded.resourceHash == manifest.resourceHash)
    #expect(decoded.partHashes == manifest.partHashes)
    #expect(decoded.flags == 0x01)
}

@Test func resourceNegotiationPacketsRoundTripOverEncryptedLink() throws {
    let session = ReticulumLinkSession(linkID: Data(repeating: 0x11, count: 16), destinationHash: Data(repeating: 0x22, count: 16), peerPublicKey: Data(repeating: 0x33, count: 32), derivedKey: Data(0..<64), mtu: 500)
    let data = Data(repeating: 0x44, count: 800)
    let manifest = try ReticulumResourceManifest(data: data, randomHash: Data([1, 2, 3, 4]))
    let advertisement = ReticulumResourceAdvertisement(manifest: manifest)
    let advertisementPacket = try ReticulumPacket(raw: session.resourceAdvertisementPacket(advertisement, iv: Data(repeating: 9, count: 16)))
    let decodedAdvertisement = try ReticulumResourceAdvertisement(encoded: session.decrypt(advertisementPacket))
    let request = try ReticulumResourceRequest(manifest: manifest, missingIndices: [0, 1])
    let requestPacket = try ReticulumPacket(raw: session.resourceRequestPacket(request, iv: Data(repeating: 10, count: 16)))
    let decodedRequest = try ReticulumResourceRequest(encoded: session.decrypt(requestPacket))

    #expect(advertisementPacket.context == 0x02)
    #expect(decodedAdvertisement.resourceHash == manifest.resourceHash)
    #expect(requestPacket.context == 0x03)
    #expect(decodedRequest.resourceHash == manifest.resourceHash)
    #expect(decodedRequest.requestedPartHashes == manifest.partHashes)
}

@Test func encryptedResourcePartsReassembleDecryptAndValidate() throws {
    let session = ReticulumLinkSession(linkID: Data(repeating: 0x10, count: 16), destinationHash: Data(repeating: 0x20, count: 16), peerPublicKey: Data(repeating: 0x30, count: 32), derivedKey: Data(0..<64), mtu: 500)
    let original = Data((0..<1_000).map { UInt8($0 % 239) })
    let encrypted = try session.encryptResourcePayload(original, iv: Data(repeating: 0x40, count: 16), payloadRandomHash: Data([9, 9, 9, 9]))
    let manifest = try ReticulumResourceManifest(data: original, transferData: encrypted, randomHash: Data([1, 3, 5, 7]))
    let parts = try manifest.parts(from: encrypted)
    var receiver = ReticulumResourceReceiver(manifest: manifest)
    for (index, part) in parts.enumerated() {
        let packet = try ReticulumPacket(raw: session.resourcePartPacket(part))
        #expect(packet.context == 0x01)
        try receiver.accept(part: packet.data, at: index)
    }
    let decrypted = try session.decryptResourcePayload(receiver.assemble())

    #expect(decrypted == original)
    #expect(manifest.validate(data: decrypted))
}

@Test func attachmentResourceEnvelopeRoundTripsMetadataAndFile() throws {
    let source = Data(repeating: 0x44, count: 16)
    let groupID = UUID()
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let envelope = try LXMFResourceEnvelope(filename: "photo.jpg", mimeType: "image/jpeg", messageBody: "A photo", sourceHash: source, groupID: groupID, fileData: Data([1, 2, 3]), signingIdentity: identity)
    let decoded = try LXMFResourceEnvelope(encoded: envelope.encode())

    #expect(decoded.filename == "photo.jpg")
    #expect(decoded.mimeType == "image/jpeg")
    #expect(decoded.messageBody == "A photo")
    #expect(decoded.sourceHash == source)
    #expect(decoded.fileData == Data([1, 2, 3]))
    #expect(decoded.groupID == groupID)
    #expect(decoded.validate(with: identity))
    var tampered = try envelope.encode(); tampered[tampered.count - 1] ^= 0xff
    #expect(!((try? LXMFResourceEnvelope(encoded: tampered))?.validate(with: identity) ?? true))
}

@Test func resourceHashMapUpdatesContinueBeyondAdvertisementWindow() throws {
    let data = Data((0..<43_000).map { UInt8($0 % 251) })
    let manifest = try ReticulumResourceManifest(data: data, randomHash: Data([7, 7, 7, 7]))
    let encodedAdvertisement = ReticulumResourceAdvertisement(manifest: manifest).encode()
    let advertised = try ReticulumResourceAdvertisement(encoded: encodedAdvertisement)
    let partialManifest = try ReticulumResourceManifest(advertisement: advertised)
    var receiver = ReticulumResourceReceiver(manifest: partialManifest)
    let parts = try manifest.parts(from: data)
    for index in 0..<ReticulumResourceAdvertisement.hashMapMaximumEntries { try receiver.accept(part: parts[index], at: index) }

    let mapRequest = try receiver.nextRequest()
    #expect(mapRequest.wantsMoreHashMap)
    let remaining = Array(manifest.partHashes.dropFirst(ReticulumResourceAdvertisement.hashMapMaximumEntries))
    let update = try ReticulumResourceHashMapUpdate(resourceHash: manifest.resourceHash, segment: 1, partHashes: remaining)
    let decoded = try ReticulumResourceHashMapUpdate(encoded: update.encode())
    try receiver.applyHashMap(segment: decoded.segment, hashes: decoded.partHashes)

    #expect(receiver.knownHashCount == manifest.partCount)
    #expect(!receiver.needsMoreHashMap)
    #expect(try receiver.nextRequest().requestedPartHashes.count == 4)
}

@Test func largeResourcesPrepareLinkedProtocolSegments() throws {
    let session = ReticulumLinkSession(linkID: Data(repeating: 1, count: 16), destinationHash: Data(repeating: 2, count: 16), peerPublicKey: Data(repeating: 3, count: 32), derivedKey: Data(0..<64), mtu: 500)
    let data = Data(repeating: 0x5a, count: ReticulumResourceSegmentPlanner.maximumEfficientSize * 2 + 17)
    let segments = try ReticulumResourceSegmentPlanner.prepare(data: data, session: session, hasMetadata: true)

    #expect(segments.count == 3)
    #expect(segments.map(\.index) == [1, 2, 3])
    #expect(segments.allSatisfy { $0.totalSegments == 3 && $0.originalHash == segments[0].manifest.resourceHash })
    #expect(segments.allSatisfy { $0.advertisement.dataSize == data.count && $0.advertisement.flags & 0x04 == 0x04 })
    #expect(segments[2].manifest.dataSize == 17)
}

@Test func inboundResourceSegmentsAccumulateInProtocolOrder() throws {
    let originalHash = Data(repeating: 0x55, count: 32)
    var accumulator = try ReticulumResourceSegmentAccumulator(originalHash: originalHash, totalSegments: 3, totalDataSize: 6)
    try accumulator.accept(Data("cd".utf8), segmentIndex: 2, originalHash: originalHash, totalSegments: 3)
    try accumulator.accept(Data("ab".utf8), segmentIndex: 1, originalHash: originalHash, totalSegments: 3)
    #expect(accumulator.progress == 2.0 / 3.0)
    try accumulator.accept(Data("ef".utf8), segmentIndex: 3, originalHash: originalHash, totalSegments: 3)
    #expect(try accumulator.assemble() == Data("abcdef".utf8))
}

@Test func resourceCancellationUsesReticulumContexts() throws {
    let session = ReticulumLinkSession(linkID: Data(repeating: 1, count: 16), destinationHash: Data(repeating: 2, count: 16), peerPublicKey: Data(repeating: 3, count: 32), derivedKey: Data(0..<64), mtu: 500)
    let hash = Data(repeating: 4, count: 32)
    let initiator = try ReticulumPacket(raw: session.resourceCancelPacket(resourceHash: hash, initiatedBySender: true, iv: Data(repeating: 5, count: 16)))
    let receiver = try ReticulumPacket(raw: session.resourceCancelPacket(resourceHash: hash, initiatedBySender: false, iv: Data(repeating: 6, count: 16)))
    #expect(initiator.context == 0x06)
    #expect(receiver.context == 0x07)
    #expect(try session.decrypt(initiator) == hash)
}

@Test func resourceSegmentsStageOnDiskAndCleanUpAfterAssembly() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ReticulumResourceStagingStore(directory: root)
    let hash = Data(repeating: 0x77, count: 32)
    _ = try await store.stage(data: Data("cd".utf8), originalHash: hash, segmentIndex: 2, totalSegments: 2, totalSize: 4)
    _ = try await store.stage(data: Data("ab".utf8), originalHash: hash, segmentIndex: 1, totalSegments: 2, totalSize: 4)
    #expect(await store.isComplete(originalHash: hash))
    #expect(try await store.assemble(originalHash: hash) == Data("abcd".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: hash.hex).path))
}

@Test func resourceSafetyLimitsRejectOversizedTransfers() {
    #expect(ReticulumResourceLimits.accepts(dataSize: 1024, transferSize: 1100, segments: 1))
    #expect(!ReticulumResourceLimits.accepts(dataSize: ReticulumResourceLimits.maximumAttachmentBytes + 100_000, transferSize: 1, segments: 1))
    #expect(!ReticulumResourceLimits.accepts(dataSize: 1, transferSize: 1, segments: 66))
}

@Test func staleResourceStagingIsRemoved() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = root.appending(path: "stale")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: folder.path)
    let store = ReticulumResourceStagingStore(directory: root)
    #expect(try await store.removeStale(olderThan: Date(timeIntervalSinceNow: -50)) == 1)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@Test func resourceWireFormatsMatchPythonReticulumFixtures() throws {
    let advertisementBytes = Data(hex: "8ba174cd0384a164cd0370a16e02a168c420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fa172c40401020304a16fc420202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3fa16901a16c01a171c0a16621a16dc408aabbccdd11223344")
    let requestBytes = Data(hex: "00000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1faabbccdd11223344")
    let updateBytes = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f9201c408aabbccdd11223344")

    #expect(try ReticulumResourceAdvertisement(encoded: advertisementBytes).encode() == advertisementBytes)
    #expect(try ReticulumResourceRequest(encoded: requestBytes).encode() == requestBytes)
    #expect(try ReticulumResourceHashMapUpdate(encoded: updateBytes).encode() == updateBytes)
}

@Test func hdlcMatchesReticulumEscapingAndStreams() {
    let payload = Data([0x01, HDLC.flag, 0x02, HDLC.escape, 0x03])
    #expect(HDLC.frame(payload) == Data([0x7e, 0x01, 0x7d, 0x5e, 0x02, 0x7d, 0x5d, 0x03, 0x7e]))
    var decoder = HDLCDecoder()
    #expect(decoder.consume(Data([0x7e, 0x01, 0x7d])).isEmpty)
    #expect(decoder.consume(Data([0x5e, 0x7e])).first == Data([0x01, 0x7e]))
}

@Test func parsesNormalAndTransportHeaders() throws {
    let destination = Data(0..<16)
    let normalRaw = Data([0b0010_0001, 3]) + destination + Data([0x0b, 0xaa, 0xbb])
    let normal = try ReticulumPacket(raw: normalRaw)
    #expect(normal.headerType == .normal)
    #expect(normal.contextFlag)
    #expect(normal.packetType == .announce)
    #expect(normal.context == 0x0b)
    #expect(normal.data == Data([0xaa, 0xbb]))

    let transportID = Data(repeating: 0xee, count: 16)
    let transportRaw = Data([0b0101_0010, 1]) + transportID + destination + Data([0x00, 0xcc])
    let transport = try ReticulumPacket(raw: transportRaw)
    #expect(transport.headerType == .transport)
    #expect(transport.transportID == transportID)
    #expect(transport.packetType == .linkRequest)
    #expect(normal.packetHash == ReticulumIdentity.fullHash(Data([normalRaw[0] & 0x0f]) + normalRaw.dropFirst(2)))
}

@Test func identityMatchesPythonReferenceVector() throws {
    let privateKey = Data(0..<64)
    let identity = try ReticulumIdentity(privateKey: privateKey)
    #expect(identity.publicKey.hex == "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7")
    #expect(identity.hash.hex == "aca31af0441d81dbec71e82da0b4b5f5")
    let message = Data("sideband-swift".utf8)
    let signature = try identity.sign(message)
    #expect(identity.validate(signature: signature, message: message))
    let pythonSignature = Data(hex: "45fe4f6da9998bf9832ed0df1e224d8724f6fd50c313b5efe9a6e185e5b80a7d49547e63c771cc9badefb1433aa8a7f2c111e84df3eb9cad9e6c4e6059aae80b")
    #expect(identity.validate(signature: pythonSignature, message: message))
}

@Test func identityEncryptionMatchesPythonReference() throws {
    let recipient = try ReticulumIdentity(privateKey: Data(64..<128))
    let encrypted = try recipient.encrypt(Data("propagated lxmf".utf8), ephemeralPrivateKey: Data(0..<32), iv: Data(32..<48))
    #expect(recipient.hash.hex == "069092a03c194639207219dd05f9c840")
    #expect(encrypted.hex == "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f202122232425262728292a2b2c2d2e2f3326290040465178611223f86a85273a09859dd6092d72036923d752de7f0f21d9fcea31286a2b21aff0644d4e95af75")
    #expect(try recipient.decrypt(encrypted) == Data("propagated lxmf".utf8))
}

@Test func validatesPythonReticulumAnnounceVector() throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let announce = try ReticulumAnnounce(packet: ReticulumPacket(raw: raw))
    #expect(announce.validate())
    #expect(announce.destinationHash.hex == "fae321c442e3c9bdcd7a3e79d850e03c")
    #expect(String(data: announce.appData, encoding: .utf8) == "Swift Peer")
    var corrupted = raw
    corrupted[corrupted.endIndex - 1] ^= 1
    #expect(try !ReticulumAnnounce(packet: ReticulumPacket(raw: corrupted)).validate())
}

@Test func buildsValidLXMFDeliveryAnnounce() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let appData = ReticulumAnnounceBuilder.lxmfAppData(displayName: "Sideband Swift")
    #expect(appData.hex == "93c40e5369646562616e64205377696674c09100")
    let raw = try ReticulumAnnounceBuilder.packet(identity: identity, destinationName: "lxmf.delivery", appData: appData, randomHash: Data(0..<10))
    let announce = try ReticulumAnnounce(packet: ReticulumPacket(raw: raw))
    #expect(announce.validate())
    #expect(announce.destinationHash.hex == "fae321c442e3c9bdcd7a3e79d850e03c")
}

@Test func decodesLXMFAnnounceDisplayNameAndStampCost() {
    let appData = MessagePack.array([MessagePack.binary(Data("Alice".utf8)), Data([0x07]), MessagePack.array([Data([0x00])])])
    let info = LXMFAnnounceInfo(appData: appData)
    #expect(info?.displayName == "Alice")
    #expect(info?.stampCost == 7)
}

@Test func pathRequestMatchesPythonReferenceLayout() throws {
    let target = Data(0..<16)
    let tag = Data(16..<32)
    let packet = try ReticulumPathRequest.packet(targetHash: target, tag: tag)
    #expect(packet.hex == "08006b9f66014d9853faab220fba47d0276100000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    let parsed = try ReticulumPacket(raw: packet)
    #expect(parsed.destinationType == .plain)
    #expect(parsed.destinationHash == ReticulumPathRequest.destinationHash)
}

@Test func pathTableAcceptsValidatedAndPrefersBetterPaths() async throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let packet = try ReticulumPacket(raw: raw)
    let announce = try ReticulumAnnounce(packet: packet)
    let table = ReticulumPathTable(lifetime: 60)
    #expect(await table.ingest(announce, packet: packet))
    #expect(await table.path(to: announce.destinationHash)?.hops == 0)
    await table.markRequested(announce.destinationHash)
    #expect(await table.isPending(announce.destinationHash))
    #expect(await table.ingest(announce, packet: packet))
    #expect(await !table.isPending(announce.destinationHash))
}

@Test func pathTableExpiresRoutes() async throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let packet = try ReticulumPacket(raw: raw)
    let announce = try ReticulumAnnounce(packet: packet)
    let start = Date(timeIntervalSince1970: 100)
    let table = ReticulumPathTable(lifetime: 5)
    #expect(await table.ingest(announce, packet: packet, now: start))
    #expect(await table.path(to: announce.destinationHash, now: start.addingTimeInterval(6)) == nil)
}

@Test func autoInterfaceConstantsMatchReference() {
    #expect(AutoInterfaceProtocol.multicastAddress == "ff12:0:d70b:fb1c:16e4:5e39:485e:31e1")
    #expect(AutoInterfaceProtocol.discoveryPort == 29_716)
    #expect(AutoInterfaceProtocol.dataPort == 42_671)
}

@Test func autoInterfaceAuthenticatesAndExpiresPeers() async {
    let address = "fe80::1234"
    let token = AutoInterfaceProtocol.discoveryToken(forIPv6Address: address)
    let table = AutoInterfacePeerTable(timeout: 22)
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(await table.receive(token: token, sourceAddress: "FE80::1234%en0", interfaceName: "en0", now: start))
    #expect(await table.activePeers(now: start.addingTimeInterval(21)).count == 1)
    #expect(await table.activePeers(now: start.addingTimeInterval(23)).isEmpty)
    #expect(await !table.receive(token: Data(repeating: 0, count: 32), sourceAddress: address, now: start))
}

@Test func linkRequestAndHKDFMatchPythonReference() throws {
    let destination = Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c")
    let request = try ReticulumLinkRequest(destinationHash: destination, keyAgreementPrivateKey: Data(0..<32), signingPrivateKey: Data(32..<64))
    #expect(ReticulumLinkRequest.signallingBytes(mtu: 500, mode: 1).hex == "2001f4")
    #expect(request.rawPacket.hex == "0200fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd72001f4")
    #expect(request.linkID.hex == "c85013b4b47e0f4e804b72ebd0641407")
    let peerPublicKey = Data(hex: "79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a")
    #expect(try request.deriveKey(peerPublicKey: peerPublicKey).hex == "09e497207060e1f86c5af8e6799238216b85aeb5b6ee7111cdfc247f88fa5047dda46186f4847c9730b6001d080f6cfd163b0fadb84752cb3139abdc15ee1c16")
}

@Test func validatesPythonLinkProofAndActivatesSession() throws {
    let destination = Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c")
    let request = try ReticulumLinkRequest(destinationHash: destination, keyAgreementPrivateKey: Data(0..<32), signingPrivateKey: Data(32..<64))
    let identityPublicKey = Data(hex: "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52fcd14b37f956e953194ff7fb73b3d81dcc561d61a7538094b7c3e1a643ee5f3aa")
    let proofRaw = Data(hex: "0f00c85013b4b47e0f4e804b72ebd0641407ffa7ede5e7eaa19e080421ed88ba64d77ee384b55289083f2f2c7e12383e2762af2d8f22ce000c8e6eab5f8cf1483331b2c9aca7fed6ac44b24686da5aae67ab0d79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a2001f4")
    let session = try request.validateProof(ReticulumPacket(raw: proofRaw), destinationPublicKey: identityPublicKey)
    #expect(session.linkID == request.linkID)
    #expect(session.derivedKey.hex == "09e497207060e1f86c5af8e6799238216b85aeb5b6ee7111cdfc247f88fa5047dda46186f4847c9730b6001d080f6cfd163b0fadb84752cb3139abdc15ee1c16")
    var corrupted = proofRaw
    corrupted[40] ^= 1
    #expect(throws: (any Error).self) { try request.validateProof(ReticulumPacket(raw: corrupted), destinationPublicKey: identityPublicKey) }
}

@Test func acceptsPythonStyleIncomingLinkRequest() throws {
    let identity = try ReticulumIdentity(privateKey: Data(96..<160))
    let requestRaw = Data(hex: "0200909adf42bd0928fbde542be8008fd8eb008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd72001f4")
    let incoming = try ReticulumIncomingLink(request: ReticulumPacket(raw: requestRaw), localIdentity: identity, responderPrivateKey: Data(64..<96))
    #expect(incoming.session.linkID.hex == "96eee935e9fb614558b33d9324cb3559")
    #expect(incoming.session.derivedKey.hex == "580b56fcdfa20365c08d6b8000b13c63e08821e7c367fbcb772b4560a20c70131565a116169265df1d25b582e223694e57468f616c1e1efde5f42599b4807129")
    let proof = try ReticulumPacket(raw: incoming.proofPacket)
    #expect(proof.context == 0xff && proof.destinationHash == incoming.session.linkID)
}

@Test func tokenEncryptionMatchesPythonReference() throws {
    let key = Data(hex: "09e497207060e1f86c5af8e6799238216b85aeb5b6ee7111cdfc247f88fa5047dda46186f4847c9730b6001d080f6cfd163b0fadb84752cb3139abdc15ee1c16")
    let token = try ReticulumToken(key: key)
    let encrypted = try token.encrypt(Data("hello reticulum".utf8), iv: Data(0..<16))
    #expect(encrypted.hex == "000102030405060708090a0b0c0d0e0f2b99cf9e13d3bf5c75e98d6b412027eda1e891ff2f07cd680a7e16cf507b86f751235d687fcea1c4bdcc25dafc03758d")
    #expect(try token.decrypt(encrypted) == Data("hello reticulum".utf8))
    var corrupted = encrypted
    corrupted[corrupted.endIndex - 1] ^= 1
    #expect(throws: (any Error).self) { try token.decrypt(corrupted) }
}

@Test func tunnelSynthesisMatchesPythonReference() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let packet = try ReticulumTunnelSynthesis.packet(identity: identity, interfaceHash: Data(64..<96), randomHash: Data(96..<112))
    let parsed = try ReticulumPacket(raw: packet)
    #expect(parsed.destinationHash == ReticulumTunnelSynthesis.destinationHash)
    #expect(parsed.data.prefix(112).hex == "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f")
    #expect(identity.validate(signature: Data(parsed.data.suffix(64)), message: Data(parsed.data.prefix(112))))
}

@Test func encryptedLinkPacketMatchesReticulumToken() throws {
    let session = ReticulumLinkSession(
        linkID: Data(hex: "c85013b4b47e0f4e804b72ebd0641407"),
        destinationHash: Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c"),
        peerPublicKey: Data(hex: "79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a"),
        derivedKey: Data(hex: "09e497207060e1f86c5af8e6799238216b85aeb5b6ee7111cdfc247f88fa5047dda46186f4847c9730b6001d080f6cfd163b0fadb84752cb3139abdc15ee1c16"),
        mtu: 500
    )
    let raw = try session.encryptedPacket(Data("hello reticulum".utf8), iv: Data(0..<16))
    #expect(raw.hex == "0c00c85013b4b47e0f4e804b72ebd064140700000102030405060708090a0b0c0d0e0f2b99cf9e13d3bf5c75e98d6b412027eda1e891ff2f07cd680a7e16cf507b86f751235d687fcea1c4bdcc25dafc03758d")
    #expect(try session.decrypt(ReticulumPacket(raw: raw)) == Data("hello reticulum".utf8))
    #expect(session.keepalivePacket().hex == "0c00c85013b4b47e0f4e804b72ebd0641407faff")
}

@Test func lxmfPackingMatchesPythonReference() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let source = Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c")
    let destination = Data(hex: "cf0b2a4a8d2a0b6978b71290da7cc80e")
    let message = try LXMFMessage(destinationHash: destination, sourceHash: source, sourceIdentity: identity, timestamp: 1_700_000_000.25, title: Data("title".utf8), content: Data("hello".utf8))
    #expect(message.payload.hex == "94cb41d954fc40100000c4057469746c65c40568656c6c6f80")
    #expect(message.messageID.hex == "827a92d9307e794546a3ff7c4ecccd1090d0787dc84ed24d1a4b5523583ff867")
    #expect(message.validate(with: identity))
    #expect(message.packed.prefix(32).hex == "cf0b2a4a8d2a0b6978b71290da7cc80efae321c442e3c9bdcd7a3e79d850e03c")
}

@Test func propagatedEnvelopeHasExpectedShape() throws {
    let sourceIdentity = try ReticulumIdentity(privateKey: Data(0..<64))
    let recipient = try ReticulumIdentity(privateKey: Data(64..<128))
    let message = try LXMFMessage(destinationHash: Data(hex: "cf0b2a4a8d2a0b6978b71290da7cc80e"), sourceHash: Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c"), sourceIdentity: sourceIdentity, timestamp: 1_700_000_000.25, content: Data("hello".utf8))
    let envelope = try message.propagatedEnvelope(recipientIdentity: recipient, timestamp: 1_700_000_001, ephemeralPrivateKey: Data(0..<32), iv: Data(32..<48))
    guard case let .array(parts) = try MessagePackDecoder.decode(envelope), parts.count == 2, case let .array(messages) = parts[1] else { Issue.record("Unexpected envelope"); return }
    #expect(messages.count == 1)
}

@Test func parsesAndValidatesReceivedLXMFMessage() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let outgoing = try LXMFMessage(destinationHash: Data(hex: "cf0b2a4a8d2a0b6978b71290da7cc80e"), sourceHash: Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c"), sourceIdentity: identity, timestamp: 1_700_000_000.25, title: Data("title".utf8), content: Data("hello".utf8))
    let incoming = try LXMFReceivedMessage(packed: outgoing.packed)
    #expect(incoming.content == Data("hello".utf8))
    #expect(incoming.title == Data("title".utf8))
    #expect(incoming.validate(with: identity))
}

@Test func propagationDownloadAndAckHaveExpectedShape() throws {
    let id = Data(0..<32)
    let download = LXMFPropagation.messageDownloadRequest([id], timestamp: 1_700_000_000.25)
    let ack = LXMFPropagation.acknowledgementRequest([id], timestamp: 1_700_000_000.25)
    guard case let .array(downloadParts) = try MessagePackDecoder.decode(download), case let .array(downloadData) = downloadParts[2],
          case let .array(wants) = downloadData[0], case let .binary(wanted) = wants[0] else { Issue.record("Invalid download shape"); return }
    #expect(wanted == id)
    guard case let .array(ackParts) = try MessagePackDecoder.decode(ack), case let .array(ackData) = ackParts[2],
          case .null = ackData[0], case let .array(haves) = ackData[1] else { Issue.record("Invalid ack shape"); return }
    #expect(haves.count == 1)
}

@Test func propagationListRequestMatchesPythonReference() {
    let request = LXMFPropagation.messageListRequest(timestamp: 1_700_000_000.25)
    #expect(LXMFPropagation.messageGetPathHash.hex == "9dc1a72883468f57fed571e796e9ce98")
    #expect(request.hex == "93cb41d954fc40100000c4109dc1a72883468f57fed571e796e9ce9892c0c0")
    #expect(ReticulumIdentity.truncatedHash(request).hex == "4e14dd881d3528a02a08e9a2802d05bc")
}

@Test func decodesLivePropagationResponseShape() throws {
    let value = try MessagePackDecoder.decode(Data(hex: "92c410465325777278df3c52630da81dd6b56f90"))
    guard case let .array(parts) = value, parts.count == 2, case let .array(messages) = parts[1] else { Issue.record("Unexpected response shape"); return }
    #expect(messages.isEmpty)
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }
}
