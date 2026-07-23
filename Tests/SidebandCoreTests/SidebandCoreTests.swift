import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import SidebandCore

@Test func lxmfStampsTicketsAndStampedPayloadsAreInteroperable() async throws {
    let material = Data(repeating: 0x42, count: 32)
    let block = LXMFStamp.workblock(material: material, rounds: 2)
    #expect(block.count == 512)
    let generated = try await LXMFStamp.generate(for: material, cost: 4, expansionRounds: 2, maximumAttempts: 100_000)
    #expect(LXMFStamp.validate(generated.stamp, cost: 4, workblock: block))
    #expect(generated.value >= 4)

    let ticket = Data(repeating: 0x7a, count: LXMFStamp.ticketSize)
    let ticketStamp = try LXMFStamp.ticketStamp(ticket: ticket, messageID: material)
    #expect(LXMFStamp.validateTicketStamp(ticketStamp, tickets: [ticket], messageID: material))

    let source = ReticulumIdentity()
    let destination = Data(repeating: 0x11, count: 16)
    let message = try LXMFMessage(destinationHash: destination, sourceHash: source.hash, sourceIdentity: source, content: Data("stamped".utf8), stamp: ticketStamp)
    let received = try LXMFReceivedMessage(packed: message.packed)
    #expect(received.stamp == ticketStamp)
    #expect(received.messageID == message.messageID)
    #expect(received.validate(with: source))
}

@Test func destinationRatchetsRotateAdvertiseAndDecrypt() throws {
    let identity = ReticulumIdentity()
    var ratchets = ReticulumRatchetState(retentionCount: 2, rotationInterval: 60, now: Date(timeIntervalSince1970: 0))
    let firstPublic = try #require(ratchets.currentPublicKey)
    let ciphertext = try identity.encrypt(Data("forward secret".utf8), ephemeralPrivateKey: Data(0..<32), ratchet: firstPublic)
    #expect(try identity.decrypt(ciphertext, ratchets: ratchets.privateKeys, enforceRatchets: true) == Data("forward secret".utf8))

    ratchets.rotateIfNeeded(now: Date(timeIntervalSince1970: 61))
    #expect(ratchets.privateKeys.count == 2)
    #expect(ratchets.currentPublicKey != firstPublic)
    #expect(try identity.decrypt(ciphertext, ratchets: ratchets.privateKeys, enforceRatchets: true) == Data("forward secret".utf8))

    let raw = try ReticulumAnnounceBuilder.packet(identity: identity, destinationName: "lxmf.delivery", randomHash: Data(repeating: 3, count: 10), ratchet: ratchets.currentPublicKey)
    let announce = try ReticulumAnnounce(packet: ReticulumPacket(raw: raw))
    #expect(announce.ratchet == ratchets.currentPublicKey)
    #expect(announce.validate())
}

@Test func announceNonceCarriesReticulumEmissionTimebase() throws {
    let emittedAt = Date(timeIntervalSince1970: 1_700_000_123)
    let raw = try ReticulumAnnounceBuilder.packet(
        identity: ReticulumIdentity(),
        destinationName: "lxmf.delivery",
        emittedAt: emittedAt
    )
    let announce = try ReticulumAnnounce(packet: ReticulumPacket(raw: raw))
    #expect(announce.validate())
    #expect(announce.randomHash.count == 10)
    let encodedSeconds = announce.randomHash.suffix(5).reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    #expect(encodedSeconds == 1_700_000_123)
    #expect(announce.emissionTimebase == 1_700_000_123)
}

@Test func pathTableRejectsOlderReplayedAnnounceEvenWithLowerHopCount() async throws {
    let identity = ReticulumIdentity()
    var newerRaw = try ReticulumAnnounceBuilder.packet(
        identity: identity,
        destinationName: "lxmf.delivery",
        emittedAt: Date(timeIntervalSince1970: 200)
    )
    newerRaw[1] = 1
    let newerPacket = try ReticulumPacket(raw: newerRaw)
    let newerAnnounce = try ReticulumAnnounce(packet: newerPacket)

    var olderRaw = try ReticulumAnnounceBuilder.packet(
        identity: identity,
        destinationName: "lxmf.delivery",
        emittedAt: Date(timeIntervalSince1970: 100)
    )
    olderRaw[1] = 0
    let olderPacket = try ReticulumPacket(raw: olderRaw)
    let olderAnnounce = try ReticulumAnnounce(packet: olderPacket)

    let table = ReticulumPathTable()
    #expect(await table.ingest(newerAnnounce, packet: newerPacket, interfaceID: "tcp"))
    #expect(await !table.ingest(olderAnnounce, packet: olderPacket, interfaceID: "tcp"))
    #expect(await table.path(to: newerAnnounce.destinationHash, on: "tcp")?.hops == 1)
    #expect(await table.path(to: newerAnnounce.destinationHash, on: "tcp")?.announceTimebase == 200)
}

@Test func encryptedProfileAndPortableIdentityRoundTrip() throws {
    let identity = ReticulumIdentity()
    let privateText = try ReticulumIdentityText.encodePrivate(identity)
    #expect(privateText.hasPrefix("RNS-PRIVATE-1:"))
    #expect(try ReticulumIdentityText.decodePrivate(privateText).privateKey == identity.privateKey)
    #expect(try SidebandProfileArchive.importPythonIdentity(try #require(identity.privateKey)).publicKey == identity.publicKey)

    let snapshot = Data(#"{"schemaVersion":1}"#.utf8)
    let payload = try SidebandProfileArchive.Payload(messagingIdentity: try #require(identity.privateKey), applicationSnapshot: snapshot)
    let archive = try SidebandProfileArchive.seal(
        payload, passphrase: "correct horse battery staple",
        salt: Data(repeating: 0x44, count: 32), nonce: try AES.GCM.Nonce(data: Data(repeating: 0x55, count: 12))
    )
    let opened = try SidebandProfileArchive.open(archive, passphrase: "correct horse battery staple")
    #expect(opened.messagingIdentity == identity.privateKey)
    #expect(opened.applicationSnapshot == snapshot)
    #expect(throws: SidebandProfileArchive.ArchiveError.self) {
        try SidebandProfileArchive.open(archive, passphrase: "this password is wrong")
    }
}

@Test func extendedTelemetrySchedulingMQTTAndOfflineTiles() throws {
    var telemetry = SidebandTelemetry(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    telemetry.setScalarSensor(.pressure, value: 1_013.25)
    telemetry.setScalarSensor(.temperature, value: 21.5)
    telemetry.setScalarSensor(.humidity, value: 42)
    telemetry.setVectorSensor(.gravity, value: SidebandVector3(x: 0, y: 0, z: -9.81))
    let decoded = try SidebandTelemetry(packed: telemetry.packed())
    #expect(decoded.pressureMillibars == 1_013.25)
    #expect(decoded.temperatureCelsius == 21.5)
    #expect(decoded.relativeHumidityPercent == 42)
    #expect(decoded.gravity?.z == -9.81)

    let destination = "0123456789abcdef0123456789abcdef"
    let schedule = SidebandTelemetrySchedule(interval: 60, excludedDestinationHashes: [destination])
    #expect(!schedule.shouldSend(lastSent: nil, destinationHash: destination))
    #expect(SidebandTelemetryMQTT.records(decoded, root: "lower sideband", source: "unit/one").contains { $0.topic == "lower_sideband/unit_one/pressure/mbar" })

    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporary.appending(path: "tiles/0/0"), withIntermediateDirectories: true)
    let manifest = SidebandOfflineMapManifest(name: "Test", format: "png", minimumZoom: 0, maximumZoom: 1, bounds: [-180, -90, 180, 90])
    try JSONEncoder().encode(manifest).write(to: temporary.appending(path: "manifest.json"))
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary.appending(path: "tiles/0/0/0.png"))
    #expect(try SidebandOfflineMapPackage.validate(directory: temporary).name == "Test")
}

@Test func additionalInterfaceWireFormatsAreSafeAndCompatible() throws {
    #expect(String(data: ReticulumI2PSAM.hello(), encoding: .utf8) == "HELLO VERSION MIN=3.1 MAX=3.3\n")
    #expect(String(data: try ReticulumI2PSAM.createSession(id: "sideband-1"), encoding: .utf8)?.contains("STYLE=STREAM") == true)
    #expect(ReticulumI2PSAM.replyIsOK(Data("HELLO REPLY RESULT=OK VERSION=3.3\n".utf8)))
    #expect(throws: ReticulumI2PSAM.Error.self) { try ReticulumI2PSAM.accept(id: "bad id") }

    let switchID = Data([1, 2, 3, 4])
    let framed = try ReticulumWeave.frame(switchID: switchID, type: .discover, payload: Data([9, 8]))
    var decoder = HDLCDecoder()
    let decodedFrame = try #require(decoder.consume(framed).first)
    let decoded = try ReticulumWeave.decode(decodedFrame)
    #expect(decoded.switchID == switchID)
    #expect(decoded.type == .discover)
    #expect(decoded.payload == Data([9, 8]))
    #expect(try ReticulumWeave.endpointCommand(endpointID: Data(repeating: 5, count: 16), packet: Data([7])).prefix(2) == Data([0, 1]))
    #expect(ReticulumSharedInstanceConfiguration().isValid)
}

@MainActor @Test func declarativePluginsAreBoundedPermissionScopedAndExecutable() async throws {
    let definition = SidebandDeclarativePluginDefinition(
        identifier: "org.example.field-status", name: "Field Status", version: "1.0",
        permissions: [.networkStatus],
        responses: ["field-status": "Network {{network.state}}, route {{route.state}}, sender {{sender.short}}, note {{argument.0}}"]
    )
    let data = try JSONEncoder().encode(definition)
    let decoded = try SidebandDeclarativePluginDefinition.decode(data)
    let registry = SidebandPluginRegistry(plugins: [], telemetry: [], enabledIdentifiers: [], persistsConfiguration: false)
    #expect(registry.registerDeclarative(decoded, enabled: true))
    let result = await registry.execute(command: "field-status", arguments: ["ok"], context: .init(
        command: "field-status", arguments: ["ok"], senderDestinationHash: String(repeating: "a", count: 32), networkReady: true, routeAvailable: false
    ))
    #expect(result.outcome == .succeeded)
    #expect(result.response?.text == "Network ready, route unavailable, sender redacted, note ok")

    let unsafe = SidebandDeclarativePluginDefinition(identifier: "org.example.unsafe", name: "Unsafe", version: "1", responses: ["unsafe": "{{file.read}}"])
    #expect(throws: SidebandDeclarativePluginDefinition.Error.self) { try unsafe.validate() }
}

@Test func signedRNodeCatalogConfigArchiveAndRichTextAreValidated() throws {
    let signer = ReticulumIdentity()
    let entry = RNodeFirmwareCatalog.Entry(
        version: "1.80", platform: 1, board: 2,
        imageURL: try #require(URL(string: "https://firmware.example/rnode.bin")),
        sha256Hex: String(repeating: "a", count: 64)
    )
    let catalog = RNodeFirmwareCatalog(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: [entry])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(catalog)
    let signed = RNodeSignedFirmwareCatalog(payload: payload, signature: try signer.sign(payload))
    let verified = try signed.verified(publicKey: Data(signer.publicKey.suffix(32)))
    var metrics = RNodeMetrics(); metrics.platform = 1; metrics.board = 2
    #expect(verified.bestMatch(for: metrics)?.version == "1.80")

    let configuration = RNodeConfiguration(transport: .simulated)
    let archived = try RNodeConfigurationArchive.encode([configuration])
    #expect(try RNodeConfigurationArchive.decode(archived) == [configuration])
    #expect(SidebandRichTextRenderer.bbcodeToMarkdown("[b]bold[/b] [url=https://example.com]site[/url]") == "**bold** [site](https://example.com)")
    #expect(SidebandRichTextRenderer.micronToMarkdown("! alert") == "**alert**")
    #expect(SidebandRichTextRenderer.attributed("[b]bold[/b]", renderer: .bbcode) != nil)
}

private struct TestNativePlugin: SidebandCommandPlugin {
    let manifest = SidebandPluginManifest(identifier: "test.native", name: "Test Plugin", version: "1", commands: ["test-echo"])
    func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse {
        SidebandPluginResponse(text: context.arguments.joined(separator: "|"))
    }
}

@Test func rnodeKISSEscapingAndChunkedDecodingRoundTrips() {
    let payload = Data([0x01, RNodeKISS.frameEnd, 0x02, RNodeKISS.frameEscape, 0x03])
    let framed = RNodeKISS.frame(command: .data, payload: payload)
    #expect(framed == Data([0xC0, 0x00, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0]))
    var decoder = RNodeKISSDecoder()
    var decoded: [RNodeKISSFrame] = []
    for byte in framed { decoded += decoder.consume(Data([byte])) }
    #expect(decoded == [RNodeKISSFrame(command: .data, payload: payload)])
}

@Test func rnodeConfigurationProducesReferenceCommandsAndValidatesSafetyBounds() throws {
    let configuration = RNodeConfiguration(
        transport: .tcp, target: "rnode.local", frequency: 867_200_000,
        bandwidth: 125_000, txPower: 7, spreadingFactor: 8, codingRate: 5,
        shortTermAirtimeLimit: 33, longTermAirtimeLimit: 1.5
    )
    _ = try configuration.validated()
    let commands = RNodeProtocolEngine().configurationCommands(configuration)
    var decoder = RNodeKISSDecoder()
    let frames = decoder.consume(commands)
    #expect(frames.map(\.command) == [.frequency, .bandwidth, .txPower, .spreadingFactor, .codingRate, .shortTermAirtimeLock, .longTermAirtimeLock, .radioState])
    #expect(frames[0].payload == Data([0x33, 0xB0, 0x6C, 0x00]))
    #expect(frames[5].payload == Data([0x0C, 0xE4]))
    #expect(frames[6].payload == Data([0x00, 0x96]))
    var invalid = configuration
    invalid.spreadingFactor = 13
    #expect(throws: RNodeError.invalidSpreadingFactor) { try invalid.validated() }
}

@Test func rnodeProtocolInterpretsDetectionFirmwareAndRadioTelemetry() {
    var engine = RNodeProtocolEngine()
    let bytes = RNodeKISS.frame(command: .detect, payload: Data([RNodeProtocolEngine.detectResponse]))
        + RNodeKISS.frame(command: .firmwareVersion, payload: Data([1, 80]))
        + RNodeKISS.frame(command: .rssi, payload: Data([77]))
        + RNodeKISS.frame(command: .snr, payload: Data([20]))
        + RNodeKISS.frame(command: .battery, payload: Data([2, 93]))
    let events = engine.consume(bytes)
    #expect(events.contains(.detected))
    #expect(engine.metrics.firmwareMajor == 1)
    #expect(engine.metrics.firmwareMinor == 80)
    #expect(engine.metrics.rssi == -80)
    #expect(engine.metrics.snr == 5)
    #expect(engine.metrics.batteryState == .charging)
    #expect(engine.metrics.batteryPercent == 93)
}

@Test func simulatedRNodeCompletesHandshakeAndLoopsBackReticulumPackets() async throws {
    let transport = SimulatedRNodeTransport(loopbackPackets: true, responseChunkSize: 1)
    let configuration = RNodeConfiguration(name: "Test RNode", transport: .simulated, target: "simulation")
    let counter = RNodeTestCounter()
    let interface = RNodeInterface(
        configuration: configuration,
        transportFactory: { _ in transport },
        packetHandler: { packet in await counter.record(packet) }
    )
    await interface.start()
    let readyDeadline = ContinuousClock.now + .seconds(2)
    while await interface.snapshot().state != .ready, ContinuousClock.now < readyDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await interface.snapshot().state == .ready)
    var expected: [Data] = []
    for sequence in 0..<100 {
        let raw = Data([0x00, 0x00]) + Data(repeating: UInt8(sequence), count: 16) + Data([0x00]) + Data([UInt8(sequence), 0xC0, 0xDB])
        expected.append(raw)
        try await interface.send(rawPacket: raw)
    }
    let receiveDeadline = ContinuousClock.now + .seconds(2)
    while await counter.count < 100, ContinuousClock.now < receiveDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await counter.count == 100)
    #expect(await counter.lastPacket == expected.last)
    #expect(await transport.transmittedPackets == expected)
    await interface.stop()
}

private actor RNodeTestCounter {
    private(set) var count = 0
    private(set) var lastPacket: Data?
    func record(_ packet: Data) { count += 1; lastPacket = packet }
}

@Test func rnodeFramebufferMatchesReferenceGeometryAndEscapesEveryLine() throws {
    var framebuffer = try RNodeFramebuffer()
    framebuffer[0, 0] = true
    framebuffer[63, 63] = true
    framebuffer[16, 20] = true
    #expect(framebuffer[0, 0])
    #expect(framebuffer[63, 63])
    #expect(framebuffer[16, 20])
    #expect(!framebuffer[1, 0])
    let commands = try RNodeProtocolEngine().framebufferWriteCommands(framebuffer.bytes)
    var decoder = RNodeKISSDecoder()
    let frames = decoder.consume(commands)
    #expect(frames.count == 64)
    #expect(frames.allSatisfy { $0.command == .framebufferWrite && $0.payload.count == 9 })
    #expect(frames.first?.payload == Data([0]) + framebuffer.bytes.prefix(8))
    #expect(frames.last?.payload == Data([63]) + framebuffer.bytes.suffix(8))
}

@Test func simulatedRNodeRoundTripsFramebufferDisplayAndROM() async throws {
    let transport = SimulatedRNodeTransport(responseChunkSize: 3)
    let interface = RNodeInterface(
        configuration: RNodeConfiguration(name: "Display", transport: .simulated, target: "simulation"),
        transportFactory: { _ in transport }, packetHandler: { _ in }
    )
    await interface.start()
    let deadline = ContinuousClock.now + .seconds(2)
    while await interface.snapshot().state != .ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let pattern = RNodeFramebuffer.testPattern().bytes
    try await interface.writeFramebuffer(pattern)
    try await interface.requestFramebuffer()
    try await interface.requestDisplaySnapshot()
    try await interface.requestROMSnapshot()
    let snapshot = await interface.snapshot()
    #expect(snapshot.framebuffer == pattern)
    #expect(snapshot.displaySnapshot?.prefix(512) == pattern)
    #expect(snapshot.displaySnapshot?.count == 1_024)
    #expect(snapshot.romSnapshot?.count == 256)
    await interface.stop()
}

@Test func rnodeFirmwarePreflightRejectsTamperingAndHardwareMismatch() throws {
    let image = Data("verified firmware".utf8)
    let package = RNodeFirmwarePackage(version: "1.81", platform: 0x80, board: 0x33, trustedImage: image)
    var metrics = RNodeMetrics()
    metrics.platform = 0x80
    metrics.board = 0x33
    metrics.firmwareMajor = 1
    metrics.firmwareMinor = 80
    let plan = try RNodeFirmwareUpdatePlan(package: package, metrics: metrics)
    #expect(plan.currentVersion == "1.80")
    #expect(plan.imageBytes == image.count)
    #expect(plan.requiresExternalBootloader)

    let tampered = RNodeFirmwarePackage(version: "1.81", platform: 0x80, board: 0x33,
                                        image: image + Data([0]), sha256: package.sha256)
    #expect(throws: RNodeFirmwareValidationError.digestMismatch) { try tampered.validate(against: metrics) }
    let wrongBoard = RNodeFirmwarePackage(version: "1.81", platform: 0x80, board: 0x34, trustedImage: image)
    #expect(throws: RNodeFirmwareValidationError.boardMismatch) { try wrongBoard.validate(against: metrics) }
}

@Test func nativeTransportInstanceRoutesOneHundredPacketsBothWaysWithoutLoops() async throws {
    let transportIdentity = try ReticulumIdentity(privateKey: Data(repeating: 0x71, count: 64))
    let alice = try ReticulumIdentity(privateKey: Data(repeating: 0x72, count: 64))
    let bob = try ReticulumIdentity(privateKey: Data(repeating: 0x73, count: 64))
    let router = ReticulumTransportInstance(identityHash: transportIdentity.hash, enabled: true)
    let a = ReticulumTransportInterfaceDescriptor(id: "tcp-a", mode: .gateway)
    let b = ReticulumTransportInterfaceDescriptor(id: "rnode-b", mode: .full)
    let interfaces = [a, b]
    let aliceAnnounce = try ReticulumPacket(raw: ReticulumAnnounceBuilder.packet(identity: alice, destinationName: "lxmf.delivery"))
    let bobAnnounce = try ReticulumPacket(raw: ReticulumAnnounceBuilder.packet(identity: bob, destinationName: "lxmf.delivery"))
    _ = await router.process(aliceAnnounce, from: a, available: interfaces)
    _ = await router.process(bobAnnounce, from: b, available: interfaces)

    for sequence in 0..<100 {
        let toBob = try ReticulumPacket(raw: testTransportData(destination: bobAnnounce.destinationHash, sequence: sequence))
        let forward = await router.process(toBob, from: a, available: interfaces)
        #expect(forward.forwards.map { $0.interfaceID } == [b.id])
        #expect(try ReticulumPacket(raw: forward.forwards[0].rawPacket).destinationHash == bobAnnounce.destinationHash)

        let toAlice = try ReticulumPacket(raw: testTransportData(destination: aliceAnnounce.destinationHash, sequence: sequence + 100))
        let reverse = await router.process(toAlice, from: b, available: interfaces)
        #expect(reverse.forwards.map { $0.interfaceID } == [a.id])
    }
    let duplicate = try ReticulumPacket(raw: testTransportData(destination: bobAnnounce.destinationHash, sequence: 99))
    #expect(await router.process(duplicate, from: a, available: interfaces).forwards.isEmpty)
    let snapshot = await router.snapshot()
    #expect(snapshot.forwardedPackets == 202)
    #expect(snapshot.duplicatePackets == 1)
    #expect(snapshot.knownRoutes == 2)
}

@Test func nativeTransportInstanceEnforcesAddressingAndInterfaceModeBoundaries() async throws {
    let local = try ReticulumIdentity(privateKey: Data(repeating: 0x74, count: 64))
    let remote = try ReticulumIdentity(privateKey: Data(repeating: 0x75, count: 64))
    let router = ReticulumTransportInstance(identityHash: local.hash, enabled: true)
    let boundary = ReticulumTransportInterfaceDescriptor(id: "boundary", mode: .boundary)
    let roaming = ReticulumTransportInterfaceDescriptor(id: "roaming", mode: .roaming)
    let full = ReticulumTransportInterfaceDescriptor(id: "full", mode: .full)
    let announce = try ReticulumPacket(raw: ReticulumAnnounceBuilder.packet(identity: remote, destinationName: "lxmf.delivery"))
    let result = await router.process(announce, from: boundary, available: [boundary, roaming, full])
    #expect(result.forwards.map { $0.interfaceID } == [full.id])

    let otherTransport = try ReticulumIdentity(privateKey: Data(repeating: 0x76, count: 64))
    let ordinary = try ReticulumPacket(raw: testTransportData(destination: announce.destinationHash, sequence: 1))
    let addressedElsewhere = try ReticulumPacket(raw: ordinary.routed(via: otherTransport.hash))
    let ignored = await router.process(addressedElsewhere, from: full, available: [boundary, full])
    #expect(!ignored.deliverLocally)
    #expect(ignored.forwards.isEmpty)
    #expect(await router.snapshot().ignoredPackets == 1)
}

private func testTransportData(destination: Data, sequence: Int) -> Data {
    var raw = Data([0x00, 0x00])
    raw.append(destination)
    raw.append(0x00)
    raw.append(contentsOf: withUnsafeBytes(of: UInt32(sequence).bigEndian, Array.init))
    return raw
}

private struct PermissionProbePlugin: SidebandCommandPlugin {
    let manifest: SidebandPluginManifest
    init(permissions: Set<SidebandPluginPermission>) {
        manifest = SidebandPluginManifest(identifier: "test.permissions", name: "Permission Probe", version: "1", commands: ["probe"], permissions: permissions)
    }
    func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse {
        SidebandPluginResponse(text: [context.senderDestinationHash ?? "redacted", context.networkReady.map(String.init) ?? "redacted", context.routeAvailable.map(String.init) ?? "redacted"].joined(separator: "|"))
    }
}

private struct SlowNativePlugin: SidebandCommandPlugin {
    let manifest = SidebandPluginManifest(identifier: "test.slow", name: "Slow Plugin", version: "1", commands: ["slow"])
    func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse {
        try await Task.sleep(for: .seconds(10))
        return SidebandPluginResponse(text: "late")
    }
}

private actor CountingCloudSync: CloudSnapshotSyncing {
    private var snapshot: CloudSnapshotPayload?
    private var snapshotSaves = 0

    func accountAvailable() async -> Bool { true }
    func fetchSnapshot() async throws -> CloudSnapshotPayload? { snapshot }
    func saveSnapshot(_ payload: CloudSnapshotPayload) async throws {
        snapshot = payload
        snapshotSaves += 1
    }
    func fetchAttachment(id: UUID) async throws -> CloudAttachmentPayload? { nil }
    func saveAttachment(_ payload: CloudAttachmentPayload) async throws { }
    func saveCount() -> Int { snapshotSaves }
    func seedSnapshot(_ payload: CloudSnapshotPayload) { snapshot = payload }
    func currentSnapshot() -> CloudSnapshotPayload? { snapshot }
}

@MainActor @Test func messageIndexesAggregateReactionsAndDeliveryStatistics() throws {
    let conversation = Conversation(
        destinationHash: "0123456789abcdef0123456789abcdef",
        displayName: "Indexed Conversation"
    )
    let target = Data(repeating: 0x42, count: 32)
    let messages = [
        Message(conversationID: conversation.id, body: "Original", direction: .incoming, state: .delivered, lxmfID: target),
        Message(conversationID: conversation.id, body: "", direction: .incoming, state: .delivered, reactionTo: target, reactionContent: "👍"),
        Message(conversationID: conversation.id, body: "", direction: .outgoing, state: .sent, reactionTo: target, reactionContent: "👍", isStarred: true),
        Message(conversationID: conversation.id, body: "Queued", direction: .outgoing, state: .queued)
    ]
    let snapshot = AppSnapshot(conversations: [conversation], messages: messages)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let store = SidebandStore(
        persistenceURL: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "store.json")
    )

    try store.restoreSnapshotData(encoder.encode(snapshot))

    #expect(store.reactionCounts(for: target, in: conversation.id) == ["👍": 2])
    #expect(store.reactionCount == 2)
    #expect(store.incomingMessageCount == 2)
    #expect(store.outgoingMessageCount == 2)
    #expect(store.sentMessageCount == 1)
    #expect(store.queuedMessageCount == 1)
    #expect(store.starredMessageCount == 1)
}

@MainActor @Test func reactionIndexDoesNotCrossConversationBoundaries() throws {
    let first = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "First")
    let second = Conversation(destinationHash: "abcdef0123456789abcdef0123456789", displayName: "Second")
    let target = Data(repeating: 0x24, count: 32)
    let snapshot = AppSnapshot(conversations: [first, second], messages: [
        Message(conversationID: first.id, body: "Original", direction: .incoming, state: .delivered, lxmfID: target),
        Message(conversationID: second.id, body: "", direction: .incoming, state: .delivered, reactionTo: target, reactionContent: "👍")
    ])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString).appending(path: "store.json"))
    try store.restoreSnapshotData(encoder.encode(snapshot))

    #expect(store.reactionCounts(for: target, in: first.id).isEmpty)
    #expect(store.reactionCounts(for: target, in: second.id) == ["👍": 1])
}

@MainActor @Test func unchangedICloudSnapshotDoesNotCreateAnotherRecordVersion() async {
    let cloud = CountingCloudSync()
    let store = SidebandStore(
        persistenceURL: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "store.json"),
        cloudSync: cloud
    )

    await store.setICloudSyncEnabled(true)
    await store.syncICloudNow()

    #expect(await cloud.saveCount() == 1)
}

@MainActor @Test func cancelledRemoteWakeReturnsWithoutSpinningToDeadline() async {
    let store = SidebandStore(
        persistenceURL: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "store.json")
    )
    store.setAutoConnect(false)
    let clock = ContinuousClock()
    let started = clock.now
    let wake = Task { await store.performRemoteWakeSync() }
    wake.cancel()

    #expect(await wake.value == false)
    #expect(started.duration(to: clock.now) < .seconds(1))
}

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
    #expect(ReticulumProof.validates(proof, packetHash: received.packetHash, identity: identity))
}

@Test func implicitSingleDestinationProofValidatesAgainstPendingPacketHash() throws {
    let identity = ReticulumIdentity()
    let destination = Data(repeating: 0x23, count: 16)
    let received = try ReticulumPacket(raw: Data([0x00, 0x00]) + destination + Data([0x00, 0x43]))
    let signature = try identity.sign(received.packetHash)
    let raw = Data([0x03, 0x00]) + received.packetHash.prefix(16) + Data([0x00]) + signature
    let proof = try ReticulumPacket(raw: raw)

    #expect(proof.data.count == 64)
    #expect(ReticulumProof.validates(proof, packetHash: received.packetHash, identity: identity))
}

@Test func explicitLinkProofUsesEmbeddedPacketHashInsteadOfLinkIDForRouting() throws {
    let identity = ReticulumIdentity()
    let packetHash = Data(ReticulumIdentity.fullHash(Data("link payload".utf8)))
    let linkID = Data(repeating: 0x7a, count: ReticulumPacket.truncatedHashBytes)
    let proofData = packetHash + (try identity.sign(packetHash))
    let raw = Data([0x0f, 0x00]) + linkID + Data([0x00]) + proofData
    let proof = try ReticulumPacket(raw: raw)

    #expect(proof.packetType == .proof)
    #expect(proof.destinationType == .link)
    #expect(proof.destinationHash == linkID)
    #expect(proof.destinationHash != packetHash.prefix(ReticulumPacket.truncatedHashBytes))
    #expect(ReticulumProof.validates(proof, packetHash: packetHash, identity: identity))
}

@Test func explicitLinkProofRejectsWrongEmbeddedHashOrSignature() throws {
    let identity = ReticulumIdentity()
    let packetHash = Data(ReticulumIdentity.fullHash(Data("expected packet".utf8)))
    let wrongHash = Data(ReticulumIdentity.fullHash(Data("different packet".utf8)))
    let linkID = Data(repeating: 0x7b, count: ReticulumPacket.truncatedHashBytes)
    let wrongHashProof = try ReticulumPacket(
        raw: Data([0x0f, 0x00]) + linkID + Data([0x00])
            + wrongHash + (try identity.sign(wrongHash))
    )
    let wrongSigner = ReticulumIdentity()
    let wrongSignatureProof = try ReticulumPacket(
        raw: Data([0x0f, 0x00]) + linkID + Data([0x00])
            + packetHash + (try wrongSigner.sign(packetHash))
    )

    #expect(!ReticulumProof.validates(wrongHashProof, packetHash: packetHash, identity: identity))
    #expect(!ReticulumProof.validates(wrongSignatureProof, packetHash: packetHash, identity: identity))
}

@Test func outboundPacketOnlyAddsTransportHeaderForMultiHopPath() throws {
    let destination = Data(repeating: 0x24, count: 16)
    let normalRaw = Data([0x00, 0x00]) + destination + Data([0x00, 0x44])
    let packet = try ReticulumPacket(raw: normalRaw)
    let nextHop = Data(repeating: 0x25, count: 16)
    let direct = ReticulumPath(destinationHash: destination, nextHop: nextHop, hops: 1, updatedAt: .now, expiresAt: .distantFuture, publicKey: Data(), appData: Data(), interfaceID: "direct")
    let transported = ReticulumPath(destinationHash: destination, nextHop: nextHop, hops: 2, updatedAt: .now, expiresAt: .distantFuture, publicKey: Data(), appData: Data(), interfaceID: "transport")

    #expect(try packet.prepared(for: direct) == normalRaw)
    let routed = try ReticulumPacket(raw: packet.prepared(for: transported))
    #expect(routed.headerType == .transport)
    #expect(routed.transportID == nextHop)
    #expect(routed.packetHash == packet.packetHash)
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

@Test func messagePackIntegerMapsAndSignedValuesRoundTrip() throws {
    let packed = MessagePack.map([
        (UInt64(1), MessagePack.signed(-42)),
        (UInt64(2), MessagePack.bool(true)),
        (UInt64(3), MessagePack.null)
    ])
    #expect(try MessagePackDecoder.decode(packed) == .map([
        (.unsigned(1), .signed(-42)),
        (.unsigned(2), .bool(true)),
        (.unsigned(3), .null)
    ]))
}

@Test func messagePackDecoderRejectsHostileAllocationAndRecursionClaims() {
    let hugeArrayClaim = Data([0xdd, 0xff, 0xff, 0xff, 0xff])
    let oversizedScalarClaim = Data([0xc6, 0x00, 0x20, 0x00, 0x00])
    let deeplyNested = Data([UInt8](repeating: 0x91, count: 40) + [0xc0])

    #expect(throws: MessagePackDecoder.DecodeError.self) { try MessagePackDecoder.decode(hugeArrayClaim) }
    #expect(throws: MessagePackDecoder.DecodeError.self) { try MessagePackDecoder.decode(oversizedScalarClaim) }
    #expect(throws: MessagePackDecoder.DecodeError.self) { try MessagePackDecoder.decode(deeplyNested) }
}

@Test func messagePackDecoderHonorsCallerBudgetsBeforeReservingCollections() {
    let encoded = MessagePack.array([MessagePack.unsigned(1), MessagePack.unsigned(2), MessagePack.unsigned(3)])
    let limits = MessagePackDecoder.Limits(maximumDepth: 4, maximumCollectionCount: 2, maximumNodeCount: 8, maximumScalarBytes: 64)
    #expect(throws: MessagePackDecoder.DecodeError.self) { try MessagePackDecoder.decode(encoded, limits: limits) }
}

@Test func keychainReadFailuresNeverFallBackToNewOrUserDefaultsMaterial() {
    var fallbackInvoked = false
    let result = SecureIdentityStore.resolveKeychainRead(.failure(.readFailed(-25308))) {
        fallbackInvoked = true
        return .success(Data(repeating: 7, count: 64))
    }
    #expect(!fallbackInvoked)
    guard case .failure(.readFailed(-25308)) = result else {
        Issue.record("A transient Keychain read error was not propagated")
        return
    }
}

@Test func keychainResolutionRejectsCorruptStoredMaterialWithoutOverwritingIt() {
    var fallbackInvoked = false
    let result = SecureIdentityStore.resolveKeychainRead(.success(Data(repeating: 1, count: 32))) {
        fallbackInvoked = true
        return .success(Data(repeating: 2, count: 64))
    }
    #expect(!fallbackInvoked)
    guard case .failure(.invalidStoredMaterial) = result else {
        Issue.record("Invalid stored key material was not rejected")
        return
    }
}

@Test func telemetryMatchesPythonSidebandFixture() throws {
    let telemetry = SidebandTelemetry(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        location: .init(latitude: -37.8136, longitude: 144.9631, altitude: 123.45, speed: 1.5, bearing: 90.5, accuracy: 8, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        battery: .init(chargePercent: 87.5, isCharging: true)
    )
    let pythonFixture = Data(hex: "8301ce6553f1000297c404fdbf02a0c40408a3f61cc40400003039c40400000096c4040000235ac4020320ce6553f1000493cb4055e00000000000c3c0")
    #expect(telemetry.packed() == pythonFixture)

    let decoded = try SidebandTelemetry(packed: pythonFixture)
    #expect(decoded == telemetry)
}

@Test func telemetryPreservesEveryUpstreamAndPluginSensorLosslessly() throws {
    let extra: [UInt8: Data] = [
        SidebandTelemetry.SensorKind.pressure.rawValue: MessagePack.double(1_013.25),
        SidebandTelemetry.SensorKind.temperature.rawValue: MessagePack.double(22.5),
        SidebandTelemetry.SensorKind.physicalLink.rawValue: MessagePack.array([MessagePack.signed(-92), MessagePack.double(7.25), MessagePack.unsigned(74)]),
        SidebandTelemetry.SensorKind.custom.rawValue: MessagePack.map([("sensor", MessagePack.string("value"))])
    ]
    let telemetry = SidebandTelemetry(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), additionalSensors: extra)
    let decoded = try SidebandTelemetry(packed: telemetry.packed())
    #expect(decoded == telemetry)
    #expect(decoded.sensorKinds.contains(.pressure))
    #expect(decoded.sensorKinds.contains(.temperature))
    #expect(decoded.sensorKinds.contains(.physicalLink))
    #expect(decoded.sensorKinds.contains(.custom))
}

@Test func telemetryCollectorStreamMatchesUpstreamFieldShapeAndRoundTrips() throws {
    let entry = SidebandTelemetryStreamEntry(
        sourceHash: Data(repeating: 0x42, count: 16),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        telemetry: SidebandTelemetry(capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     additionalSensors: [SidebandTelemetry.SensorKind.humidity.rawValue: MessagePack.double(62.5)])
    )
    let encoded = try #require(SidebandTelemetryStreamEntry.encode([entry]))
    let decoded = SidebandTelemetryStreamEntry.decode(try MessagePackDecoder.decode(encoded))
    #expect(decoded == [entry])
}

@Test func geospatialRelationshipCalculatesBearingDistanceAndRadioHorizon() {
    let origin = SidebandTelemetry.Location(latitude: -37.8136, longitude: 144.9631, altitude: 100)
    let target = SidebandTelemetry.Location(latitude: -37.8146, longitude: 144.9731, altitude: 200)
    let relationship = SidebandGeospatial.relationship(from: origin, to: target)
    #expect(relationship.surfaceDistanceMeters > 850 && relationship.surfaceDistanceMeters < 1_000)
    #expect(relationship.initialBearingDegrees > 90 && relationship.initialBearingDegrees < 110)
    #expect(relationship.verticalSeparationMeters == 100)
    #expect(relationship.withinRadioHorizon)
}

@Test func telemetryHistorySummarizesTrackAndExportsInteroperableFiles() throws {
    let conversationID = UUID()
    let first = SidebandTelemetry(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), location: .init(latitude: -37.8136, longitude: 144.9631, altitude: 12, accuracy: 5, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    let second = SidebandTelemetry(capturedAt: Date(timeIntervalSince1970: 1_700_000_060), location: .init(latitude: -37.8146, longitude: 144.9641, altitude: 13, speed: 5, accuracy: 7, updatedAt: Date(timeIntervalSince1970: 1_700_000_060)), battery: .init(chargePercent: 50, isCharging: false))
    let messages = [
        Message(conversationID: conversationID, body: "one", direction: .incoming, state: .delivered, telemetry: first),
        Message(conversationID: conversationID, body: "two", direction: .outgoing, state: .delivered, telemetry: second)
    ]
    let summary = SidebandTelemetryHistory.summary(messages: messages)
    #expect(summary.sampleCount == 2)
    #expect(summary.locationCount == 2)
    #expect(summary.duration == 60)
    #expect(summary.distanceMeters > 100 && summary.distanceMeters < 200)

    let csv = try #require(SidebandTelemetryHistory.export(messages: messages, contactName: "Test & Contact", format: .csv))
    let csvText = String(decoding: csv, as: UTF8.self)
    #expect(csvText.contains("timestamp,direction,latitude"))
    #expect(csvText.contains("outgoing,-37.8146,144.9641"))

    let gpx = try #require(SidebandTelemetryHistory.export(messages: messages, contactName: "Test & Contact", format: .gpx))
    let gpxText = String(decoding: gpx, as: UTF8.self)
    #expect(gpxText.contains("<gpx version=\"1.1\""))
    #expect(gpxText.contains("Test &amp; Contact"))
    #expect(gpxText.components(separatedBy: "<trkpt ").count == 3)
}

@Test func telemetryValidationRejectsUnsafeValuesAndReportsFreshness() {
    let current = SidebandTelemetry(capturedAt: .now, location: .init(latitude: -37.8, longitude: 145, updatedAt: .now), battery: .init(chargePercent: 40, isCharging: true))
    #expect(current.validationError == nil)
    #expect(current.isFresh())
    let invalid = SidebandTelemetry(capturedAt: .now, location: .init(latitude: 120, longitude: 145), battery: .init(chargePercent: 140, isCharging: false))
    #expect(invalid.validationError != nil)
    let staleDate = Date(timeIntervalSinceNow: -3_600)
    #expect(!SidebandTelemetry(capturedAt: staleDate, location: .init(latitude: 0, longitude: 0, updatedAt: staleDate)).isFresh())
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

@Test func sidebandContactLinksCarryVerifiableIdentityKeys() throws {
    let identity = ReticulumIdentity()
    let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
    let hash = ReticulumIdentity.truncatedHash(nameHash + identity.hash).hex
    let contact = try #require(SidebandContactLink(destinationHash: hash, displayName: "Offline Peer", publicKey: identity.publicKey))
    let decoded = try #require(SidebandContactLink(url: contact.url))

    #expect(decoded == contact)
    #expect(decoded.publicKey == identity.publicKey)
    #expect(contact.url.absoluteString.contains("key="))
    #expect(SidebandContactLink(destinationHash: "0123456789abcdef0123456789abcdef", publicKey: identity.publicKey) == nil)
    #expect(SidebandContactLink(string: "sideband://contact/\(hash)?key=not+base64") == nil)
}

@Test func identityFingerprintsAreStableAndHumanComparable() throws {
    let identity = ReticulumIdentity()
    let fingerprint = try #require(ReticulumIdentity.fingerprint(of: identity.publicKey))

    #expect(fingerprint.split(separator: " ").count == 16)
    #expect(fingerprint.replacingOccurrences(of: " ", with: "").count == 64)
    #expect(fingerprint == ReticulumIdentity.fingerprint(of: identity.publicKey))
    #expect(ReticulumIdentity.fingerprint(of: Data(repeating: 0, count: 10)) == nil)
}

@MainActor @Test func storeOpensSidebandContactLinks() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let contactURL = try #require(URL(string: "sideband://contact/0123456789abcdef0123456789abcdef?name=Deep%20Link"))

    #expect(store.openContactLink(contactURL))
    #expect(store.selectedConversation?.displayName == "Deep Link")
    #expect(!store.openContactLink(URL(string: "https://example.com")!))
}

@MainActor @Test func storeTrustsIdentityBoundByContactLink() throws {
    let identity = ReticulumIdentity()
    let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
    let hash = ReticulumIdentity.truncatedHash(nameHash + identity.hash).hex
    let contact = try #require(SidebandContactLink(destinationHash: hash, displayName: "Paper Peer", publicKey: identity.publicKey))
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)

    #expect(store.openContactLink(contact.url))
    let discovery = try #require(store.discoveries.first(where: { $0.destinationHash == hash }))
    #expect(discovery.isValidated)
    #expect(discovery.publicKey == identity.publicKey)
    #expect(store.contactLink(for: try #require(store.selectedConversationID)) == contact)
}

@MainActor @Test func contactIdentityVerificationPinsPublicKey() throws {
    let identity = ReticulumIdentity()
    let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
    let hash = ReticulumIdentity.truncatedHash(nameHash + identity.hash).hex
    let contact = try #require(SidebandContactLink(destinationHash: hash, displayName: "Verified Peer", publicKey: identity.publicKey))
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.openContactLink(contact.url))
    let conversation = try #require(store.selectedConversation)

    #expect(store.setConversationIdentityVerified(true, conversationID: conversation.id))
    #expect(store.isConversationIdentityVerified(conversation.id))
    #expect(store.identityFingerprint(for: conversation.id) == ReticulumIdentity.fingerprint(of: identity.publicKey))

    let restored = SidebandStore(persistenceURL: url)
    let restoredConversation = try #require(restored.conversations.first)
    #expect(restored.isConversationIdentityVerified(restoredConversation.id))
}

@MainActor @Test func perContactDeliveryPreferencePersists() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Remote Peer"))
    let conversation = try #require(store.selectedConversation)

    store.setConversationDeliveryPreference(.propagationPreferred, conversationID: conversation.id)
    #expect(store.selectedConversation?.deliveryPreference == .propagationPreferred)

    let restored = SidebandStore(persistenceURL: url)
    #expect(restored.conversations.first?.deliveryPreference == .propagationPreferred)
}

@MainActor @Test func conversationDeliveryDiagnosticsExplainQueuedState() throws {
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Remote Peer"))
    let conversation = try #require(store.selectedConversation)
    store.updateDraft("waiting for a route", for: conversation.id)

    let report = try #require(store.conversationDeliveryDiagnostics(conversation.id))
    #expect(report.contains("Destination: 0123456789abcdef0123456789abcdef"))
    #expect(report.contains("Path: unknown"))
    #expect(report.contains("Delivery policy: automatic direct with propagation fallback"))
}

@MainActor @Test func structuredConversationExportOmitsLocalPathsAndOutboxOwnership() async throws {
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Archive Peer"))
    let conversation = try #require(store.selectedConversation)
    let attachment = Attachment(filename: "map.png", mimeType: "image/png", byteCount: 42, relativePath: "private-local-file.sbenc", state: .available, contentHash: Data(repeating: 7, count: 32))
    await store.send("status", attachments: [attachment])

    let data = try store.exportConversationData(conversation.id)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(SidebandConversationExport.self, from: data)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(archive.contact.destinationHash == conversation.destinationHash)
    #expect(archive.messages.first?.attachments.first?.filename == "map.png")
    #expect(!text.contains("private-local-file.sbenc"))
    #expect(!text.contains("outboxOwnerID"))
}

@Test func structuredConversationExportVersionTwoPreservesPortableMessageMetadata() throws {
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Archive Peer")
    let reference = Data(repeating: 0x22, count: 32)
    let message = Message(
        conversationID: conversation.id,
        body: "status",
        direction: .outgoing,
        state: .failed,
        attachments: [Attachment(filename: "map.png", mimeType: "image/png", byteCount: 42, relativePath: "local.sbenc", state: .failed, contentHash: Data(repeating: 7, count: 32))],
        replyTo: reference,
        replyQuote: "earlier",
        reactionTo: reference,
        reactionContent: "👍",
        commentTo: reference,
        continuationOf: reference,
        commands: [.ping],
        deliveryAttemptCount: 3,
        lastDeliveryAttemptAt: Date(timeIntervalSince1970: 1_234),
        lastDeliveryMode: .propagation,
        lastDeliveryFailure: "No route",
        isStarred: true,
        starredUpdatedAt: Date(timeIntervalSince1970: 1_235)
    )

    let archive = SidebandConversationExport(conversation: conversation, fingerprint: nil, messages: [message])
    let exported = try #require(archive.messages.first)
    #expect(archive.version == 2)
    #expect(exported.replyTo == reference)
    #expect(exported.reactionContent == "👍")
    #expect(exported.commentTo == reference)
    #expect(exported.continuationOf == reference)
    #expect(exported.commands == [.ping])
    #expect(exported.attachments.first?.state == .failed)
    #expect(exported.deliveryAttemptCount == 3)
    #expect(exported.lastDeliveryMode == .propagation)
    #expect(exported.lastDeliveryFailure == "No route")
    #expect(exported.isStarred == true)
}

@MainActor @Test func starredMessagesPersistFilterAndUnstar() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversation = try #require(store.selectedConversation)
    #expect(await store.send("Important", attachments: []))
    let message = try #require(store.messages.first)

    store.setMessageStarred(true, messageID: message.id)
    #expect(store.starredMessageCount == 1)
    #expect(store.starredMessages(for: conversation.id).map(\.id) == [message.id])
    let restored = SidebandStore(persistenceURL: url)
    #expect(restored.messages.first?.isStarred == true)

    restored.setMessageStarred(false, messageID: message.id)
    #expect(restored.starredMessageCount == 0)
}

@Test func cloudMergeUsesNewestStarredState() {
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let id = UUID()
    let local = Message(id: id, conversationID: conversation.id, body: "Important", direction: .incoming, state: .delivered, isStarred: false, starredUpdatedAt: Date(timeIntervalSince1970: 20))
    let remote = Message(id: id, conversationID: conversation.id, body: "Important", direction: .incoming, state: .delivered, isStarred: true, starredUpdatedAt: Date(timeIntervalSince1970: 10))
    let merged = AppSnapshot(conversations: [conversation], messages: [local]).mergingCloudSnapshot(AppSnapshot(conversations: [conversation], messages: [remote]))
    #expect(merged.messages.first?.isStarred == false)
    #expect(merged.messages.first?.starredUpdatedAt == local.starredUpdatedAt)
}

@MainActor @Test func conversationArchiveImportIsDeduplicatedSafeAndDoesNotGrantTrust() throws {
    let destination = "0123456789abcdef0123456789abcdef"
    let sourceConversation = Conversation(destinationHash: destination, displayName: "Archive Peer", isTrusted: true)
    let attachment = Attachment(filename: "map.png", mimeType: "image/png", byteCount: 42, relativePath: "private.sbenc", state: .available, contentHash: Data(repeating: 7, count: 32))
    let sourceMessage = Message(conversationID: sourceConversation.id, body: "Restore me", direction: .outgoing, state: .queued, attachments: [attachment], isStarred: true)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(SidebandConversationExport(conversation: sourceConversation, fingerprint: "not-authoritative", messages: [sourceMessage]))
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)

    #expect(try store.importConversationData(data) == 1)
    let importedConversation = try #require(store.selectedConversation)
    let importedMessage = try #require(store.messages.first)
    #expect(!importedConversation.isTrusted)
    #expect(importedMessage.conversationID == importedConversation.id)
    #expect(importedMessage.state == .failed)
    #expect(importedMessage.outboxOwnerID == nil)
    #expect(importedMessage.lastDeliveryFailure == "Imported archive item; not queued")
    #expect(importedMessage.isStarred)
    #expect(importedMessage.attachments.first?.state == .failed)
    #expect(importedMessage.attachments.first?.relativePath.contains("private.sbenc") == false)
    #expect(try store.importConversationData(data) == 0)
}

@MainActor @Test func scheduledMessagesPersistStayGatedAndCanSendNow() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let future = Date.now.addingTimeInterval(3_600)
    #expect(await store.send("Later", attachments: [], scheduledFor: future))
    let message = try #require(store.messages.first)
    #expect(message.scheduledFor == future)
    #expect(store.dueQueuedMessageCount() == 0)
    #expect(store.nextScheduledMessageDate == future)
    let restored = SidebandStore(persistenceURL: url)
    #expect(abs((restored.messages.first?.scheduledFor?.timeIntervalSince(future)) ?? .infinity) < 1)

    await restored.sendScheduledMessageNow(message.id)
    #expect(restored.messages.first?.scheduledFor == nil)
    #expect(restored.dueQueuedMessageCount() == 1)
}

@MainActor @Test func scheduledMessageValidationRejectsPastAndExcessiveDates() async {
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    #expect(!(await store.send("Past", attachments: [], scheduledFor: Date.now.addingTimeInterval(-60))))
    #expect(!(await store.send("Too far", attachments: [], scheduledFor: Date.now.addingTimeInterval(367 * 24 * 60 * 60))))
    #expect(store.messages.isEmpty)
}

@MainActor @Test func perContactNotificationPreviewPersistsAndOverridesGlobalPolicy() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Private Peer"))
    let conversation = try #require(store.selectedConversation)
    store.notifications.setShowPreviews(true)
    store.setConversationNotificationPreview(false, conversationID: conversation.id)
    #expect(!store.shouldShowNotificationPreview(for: conversation.id))
    let restored = SidebandStore(persistenceURL: url)
    #expect(restored.conversations.first?.notificationPreviewEnabled == false)
    #expect(!restored.shouldShowNotificationPreview(for: conversation.id))
    restored.setConversationNotificationPreview(nil, conversationID: conversation.id)
    #expect(restored.shouldShowNotificationPreview(for: conversation.id))
}

@MainActor @Test func notificationReplyCanSendWithoutChangingSelectedConversation() async throws {
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "First"))
    let first = try #require(store.selectedConversation)
    #expect(store.addConversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Second"))
    let selected = try #require(store.selectedConversationID)
    #expect(await store.send("Quick reply", to: first.id))
    #expect(store.selectedConversationID == selected)
    #expect(store.messages.first?.conversationID == first.id)
}

@Test func attachmentStorageReportFindsMissingCorruptAndOrphanFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = AttachmentStore(directory: directory)
    let available = try await store.save(data: Data("valid".utf8), filename: "valid.txt", mimeType: "text/plain")
    let missing = Attachment(filename: "missing.txt", byteCount: 7, relativePath: "missing.sbenc", state: .failed)
    try Data("orphan".utf8).write(to: directory.appending(path: "orphan.sbenc"))
    let corrupt = try await store.save(data: Data("original".utf8), filename: "corrupt.txt", mimeType: "text/plain")
    try Data("tampered".utf8).write(to: await store.url(for: corrupt))

    let report = await store.storageReport(for: [available, missing, corrupt])
    #expect(report.attachmentCount == 3)
    #expect(report.missingCount == 1)
    #expect(report.corruptCount == 1)
    #expect(report.orphanCount == 1)
    #expect(!report.isHealthy)
    #expect(try await store.removeOrphans(referencedRelativePaths: Set([available.relativePath, corrupt.relativePath])) == 1)
}

@MainActor @Test func storeRemovesFailedAttachmentMetadataWithoutRemovingMessages() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let store = SidebandStore(persistenceURL: root.appending(path: "store.json"))
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let attachment = Attachment(filename: "missing.txt", byteCount: 7, relativePath: "missing.sbenc", state: .failed)
    #expect(await store.send("Keep message", attachments: [attachment]))
    #expect(await store.removeFailedAttachmentMetadata() == 1)
    #expect(store.messages.count == 1)
    #expect(store.messages.first?.attachments.isEmpty == true)
}

@Test func gatewayHealthTracksSuccessFailureLatencyAndCooldown() {
    let now = Date(timeIntervalSince1970: 10_000)
    var record = GatewayHealthRecord()
    record.recordFailure(at: now.addingTimeInterval(-30))
    record.recordFailure(at: now.addingTimeInterval(-20))
    record.recordFailure(at: now.addingTimeInterval(-10))
    #expect(record.consecutiveFailures == 3)
    #expect(record.isCoolingDown(at: now))
    record.recordSuccess(at: now, latency: 2)
    record.recordSuccess(at: now, latency: 1)
    #expect(record.consecutiveFailures == 0)
    #expect(record.successfulConnections == 2)
    #expect(record.smoothedConnectLatency == 1.7)
    #expect(!record.isCoolingDown(at: now))
}

@Test func publicGatewayOrderingUsesCooldownFailureAndLatencyHealth() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let first = try #require(PublicReticulumGateways.defaults.first)
    let second = try #require(PublicReticulumGateways.defaults.dropFirst().first)
    var unhealthy = GatewayHealthRecord()
    for offset in [30.0, 20.0, 10.0] { unhealthy.recordFailure(at: now.addingTimeInterval(-offset)) }
    var healthy = GatewayHealthRecord(); healthy.recordSuccess(at: now, latency: 0.5)
    let ordered = PublicReticulumGateways.ordered(customHost: nil, customPort: 4_242, preferredID: first.id, health: [first.id: unhealthy, second.id: healthy], now: now)
    #expect(ordered.first?.id == second.id)
    #expect(ordered.last?.id == first.id)
}

@MainActor @Test func contactTagsNormalizePersistSearchAndTransfer() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversation = try #require(store.selectedConversation)
    store.setConversationTags([" Field ", "field", "Priority", "", String(repeating: "x", count: 40)], conversationID: conversation.id)
    #expect(store.selectedConversation?.tags == ["Field", "Priority", String(repeating: "x", count: 32)])
    #expect(store.conversationMatchesSearch(conversation.id, query: "priority"))
    let restored = SidebandStore(persistenceURL: url)
    #expect(restored.conversations.first?.tags == store.selectedConversation?.tags)

    let data = try store.exportContactCollectionData()
    let destination = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    #expect(try destination.importContactCollectionData(data) == 1)
    #expect(destination.selectedConversation?.tags == store.selectedConversation?.tags)
}

@Test func legacyConversationWithoutTagsDecodesSafely() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000001","destinationHash":"0123456789abcdef0123456789abcdef","displayName":"Legacy","updatedAt":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(Conversation.self, from: json).tags.isEmpty)
}

@MainActor @Test func privacyLockPersistsOnlySuccessfulAuthenticatedChangesAndRelocks() throws {
    let suite = "SidebandPrivacyLockTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let lock = AppPrivacyLock(defaults: defaults)
    #expect(!lock.isEnabled)
    #expect(lock.isUnlocked)

    lock.applyAuthenticationResult(false, enabling: true)
    #expect(!lock.isEnabled)
    lock.applyAuthenticationResult(true, enabling: true)
    #expect(lock.isEnabled)
    lock.lock()
    #expect(!lock.isUnlocked)

    let restored = AppPrivacyLock(defaults: defaults)
    #expect(restored.isEnabled)
    #expect(!restored.isUnlocked)
    restored.applyAuthenticationResult(true, enabling: false)
    #expect(!restored.isEnabled)
    #expect(restored.isUnlocked)
}

@MainActor @Test func notificationPreviewsDefaultOffAndRemainExplicitlyOptIn() throws {
    let suite = "SidebandNotificationPrivacyTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let notifications = LocalNotificationManager(defaults: defaults)
    #expect(!notifications.showPreviews)
    notifications.setShowPreviews(true)
    #expect(LocalNotificationManager(defaults: defaults).showPreviews)
}

@MainActor @Test func contactCollectionsRoundTripWithoutGrantingVerification() throws {
    let identity = ReticulumIdentity()
    let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
    let destination = ReticulumIdentity.truncatedHash(nameHash + identity.hash).hex
    let source = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "source.json"))
    let link = try #require(SidebandContactLink(destinationHash: destination, displayName: "Portable Peer", publicKey: identity.publicKey))
    #expect(source.openContactLink(link.url))
    let sourceConversation = try #require(source.selectedConversation)
    #expect(source.setConversationIdentityVerified(true, conversationID: sourceConversation.id))

    let data = try source.exportContactCollectionData()
    let destinationStore = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "destination.json"))
    #expect(try destinationStore.importContactCollectionData(data) == 1)
    let imported = try #require(destinationStore.selectedConversation)
    #expect(imported.displayName == "Portable Peer")
    #expect(destinationStore.identityPublicKey(for: imported.id) == identity.publicKey)
    #expect(!destinationStore.isConversationIdentityVerified(imported.id))
}

@Test func legacyConversationsDecodeWithSafeFeatureDefaults() throws {
    let id = UUID()
    let json = """
    {"id":"\(id.uuidString)","destinationHash":"0123456789abcdef0123456789abcdef","displayName":"Legacy Peer","unreadCount":2,"updatedAt":0}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let conversation = try decoder.decode(Conversation.self, from: Data(json.utf8))

    #expect(conversation.deliveryPreference == .automatic)
    #expect(conversation.telemetrySharingEnabled)
    #expect(conversation.verifiedIdentityKey == nil)
    #expect(conversation.identityVerifiedAt == nil)
}

@MainActor @Test func contactAppearancePersistsSyncsAndExportsWithoutRemoteOverwrite() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Field Team"))
    let id = try #require(store.conversations.first?.id)
    store.setConversationAppearance(conversationID: id, note: "Primary response crew", color: .orange, symbol: .team)
    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.conversations.first?.contactNote == "Primary response crew")
    #expect(reloaded.conversations.first?.appearanceColor == .orange)
    #expect(reloaded.conversations.first?.appearanceSymbol == .team)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let exported = try decoder.decode(SidebandContactCollection.self, from: reloaded.exportContactCollectionData())
    #expect(exported.contacts.first?.contactNote == "Primary response crew")
    #expect(exported.contacts.first?.appearanceColor == .orange)

    let newer = Conversation(id: id, destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Field Team", pluginCommandsEnabled: true, contactNote: "Primary response crew", appearanceColor: .orange, appearanceSymbol: .team, updatedAt: Date(timeIntervalSince1970: 20))
    let older = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Remote", contactNote: "Old", appearanceColor: .gray, appearanceSymbol: .person, updatedAt: Date(timeIntervalSince1970: 10))
    let merged = AppSnapshot(conversations: [newer]).mergingCloudSnapshot(AppSnapshot(conversations: [older]))
    #expect(merged.conversations.first?.contactNote == "Primary response crew")
    #expect(merged.conversations.first?.pluginCommandsEnabled == true)
}

@MainActor @Test func snapshotValidationRejectsIdentityPinnedToDifferentDestination() throws {
    let identity = ReticulumIdentity()
    let conversation = Conversation(
        destinationHash: "0123456789abcdef0123456789abcdef",
        displayName: "Mismatched Peer",
        verifiedIdentityKey: identity.publicKey,
        identityVerifiedAt: .now
    )
    let snapshot = AppSnapshot(conversations: [conversation])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))

    #expect(throws: SnapshotError.self) { try store.validatedSnapshot(from: data) }
}

@MainActor @Test func discoveryCleanupProtectsConversationDestinations() async throws {
    let now = Date.now.addingTimeInterval(8 * 24 * 60 * 60)
    let firstIdentity = ReticulumIdentity()
    let secondIdentity = ReticulumIdentity()
    let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
    let protectedHash = ReticulumIdentity.truncatedHash(nameHash + firstIdentity.hash).hex
    let removableHash = ReticulumIdentity.truncatedHash(nameHash + secondIdentity.hash).hex
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let protectedLink = try #require(SidebandContactLink(destinationHash: protectedHash, publicKey: firstIdentity.publicKey))
    let removableLink = try #require(SidebandContactLink(destinationHash: removableHash, publicKey: secondIdentity.publicKey))
    #expect(store.openContactLink(protectedLink.url))
    #expect(store.openContactLink(removableLink.url))
    await store.deleteConversation(try #require(store.selectedConversationID))
    #expect(store.pruneDiscoveries(olderThan: 7 * 24 * 60 * 60, now: now) == 1)
    #expect(store.discoveries.contains(where: { $0.destinationHash == protectedHash }))
    #expect(!store.discoveries.contains(where: { $0.destinationHash == removableHash }))
    #expect(!store.forgetDiscovery(protectedHash))
}

@MainActor @Test func localDisplayNameIsNormalizedAndPersisted() {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: "lxmfLocalDisplayName")
    defer {
        if let previous { defaults.set(previous, forKey: "lxmfLocalDisplayName") }
        else { defaults.removeObject(forKey: "lxmfLocalDisplayName") }
    }
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    store.setLocalDisplayName("  Mesh Phone  ")

    #expect(store.localDisplayName == "Mesh Phone")
    #expect(SidebandStore(persistenceURL: url).localDisplayName == "Mesh Phone")
}

@MainActor @Test func localDisplayNameIsEncodedInAnnounceData() {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: "lxmfLocalDisplayName")
    defer {
        if let previous { defaults.set(previous, forKey: "lxmfLocalDisplayName") }
        else { defaults.removeObject(forKey: "lxmfLocalDisplayName") }
    }
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    store.setLocalDisplayName("Native iPhone")

    #expect(LXMFAnnounceInfo(appData: store.localAnnounceAppData)?.displayName == "Native iPhone")
}

@MainActor @Test func manualDeliveryAnnounceRequiresReadyNetwork() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)

    let announced = await store.announceDeliveryDestinationNow()

    #expect(!announced)
    #expect(store.lastDeliveryAnnounceAt == nil)
    #expect(store.deliveryAnnouncesSent == 0)
}

@MainActor @Test func internetOnlyConnectionPolicyPersists() {
    let defaults = UserDefaults.standard
    let previousInternetOnly = defaults.object(forKey: "reticulumInternetOnly")
    let previousAutoConnect = defaults.object(forKey: "reticulumAutoConnect")
    defer {
        if let previousInternetOnly { defaults.set(previousInternetOnly, forKey: "reticulumInternetOnly") }
        else { defaults.removeObject(forKey: "reticulumInternetOnly") }
        if let previousAutoConnect { defaults.set(previousAutoConnect, forKey: "reticulumAutoConnect") }
        else { defaults.removeObject(forKey: "reticulumAutoConnect") }
    }
    defaults.set(false, forKey: "reticulumInternetOnly")
    defaults.set(false, forKey: "reticulumAutoConnect")
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)

    store.setInternetOnly(true)

    #expect(store.internetOnlyEnabled)
    #expect(defaults.bool(forKey: "reticulumInternetOnly"))
    #expect(SidebandStore(persistenceURL: url).internetOnlyEnabled)
}

@MainActor @Test func automaticDiscoveryIsTheDefaultAndConfiguredModePersists() {
    let defaults = UserDefaults.standard
    let previousMode = defaults.object(forKey: "reticulumConnectionMode")
    let previousAutoConnect = defaults.object(forKey: "reticulumAutoConnect")
    let previousInternetOnly = defaults.object(forKey: "reticulumInternetOnly")
    defer {
        if let previousMode { defaults.set(previousMode, forKey: "reticulumConnectionMode") }
        else { defaults.removeObject(forKey: "reticulumConnectionMode") }
        if let previousAutoConnect { defaults.set(previousAutoConnect, forKey: "reticulumAutoConnect") }
        else { defaults.removeObject(forKey: "reticulumAutoConnect") }
        if let previousInternetOnly { defaults.set(previousInternetOnly, forKey: "reticulumInternetOnly") }
        else { defaults.removeObject(forKey: "reticulumInternetOnly") }
    }
    defaults.removeObject(forKey: "reticulumConnectionMode")
    defaults.removeObject(forKey: "reticulumAutoConnect")
    defaults.removeObject(forKey: "reticulumInternetOnly")
    let firstURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let first = SidebandStore(persistenceURL: firstURL)
    #expect(first.connectionMode == .automatic)
    #expect(first.autoConnectEnabled)
    #expect(!first.internetOnlyEnabled)

    first.setAutoConnect(false)
    first.setConnectionMode(.configured)
    let restored = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    #expect(restored.connectionMode == .configured)
}

@MainActor @Test func localContactLinkContainsDeliveryDestination() {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: "lxmfLocalDisplayName")
    defer {
        if let previous { defaults.set(previous, forKey: "lxmfLocalDisplayName") }
        else { defaults.removeObject(forKey: "lxmfLocalDisplayName") }
    }
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    store.setLocalDisplayName("My Device")

    #expect(store.localContactLink.destinationHash == store.localDeliveryHash)
    #expect(store.localContactLink.displayName == "My Device")
    #expect(store.localContactLink.publicKey?.count == 64)
}

@MainActor @Test func diagnosticsReportContainsSafeRoutingContext() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let report = store.networkDiagnosticsReport

    #expect(report.contains("Sideband Network Diagnostics"))
    #expect(report.contains("Messaging identity: \(store.messagingIdentityHash)"))
    #expect(report.contains("Local destination: \(store.localDeliveryHash)"))
    #expect(report.contains("Last announced destination:"))
    #expect(report.contains("Inbound packet:"))
    #expect(report.contains("Inbound message:"))
    #expect(report.contains("Delivery proofs:"))
    #expect(report.contains("Recent delivery events:"))
    #expect(report.contains("TCP endpoint:"))
    #expect(report.contains("Deferred maintenance:"))
    #expect(!report.localizedCaseInsensitiveContains("private key"))
}

@MainActor @Test func inboundDeliveryProofReturnsOnLinkIngressInterface() {
    let linkID = "0123456789abcdef0123456789abcdef"
    let interfaces = [
        linkID: "public-beleth-ipv6",
        "fedcba9876543210fedcba9876543210": "public-dismail-ipv4"
    ]

    #expect(SidebandStore.inboundProofInterface(for: linkID, registeredInterfaces: interfaces) == "public-beleth-ipv6")
    #expect(SidebandStore.inboundProofInterface(for: "unknown", registeredInterfaces: interfaces) == nil)
}

@Test func applicationSnapshotsCarrySchemaVersion() throws {
    let data = try JSONEncoder().encode(AppSnapshot())
    let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)
    #expect(decoded.schemaVersion == AppSnapshot.currentSchemaVersion)
}

@Test func messagesMigrateAndPersistLXMFReplyMetadata() throws {
    let conversationID = UUID()
    let lxmfID = Data(repeating: 0x11, count: 32)
    let replyID = Data(repeating: 0x22, count: 32)
    let message = Message(
        conversationID: conversationID,
        body: "Reply body",
        direction: .incoming,
        state: .delivered,
        lxmfID: lxmfID,
        replyTo: replyID,
        replyQuote: "Original body"
    )
    let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
    #expect(decoded.lxmfID == lxmfID)
    #expect(decoded.replyTo == replyID)
    #expect(decoded.replyQuote == "Original body")

    let legacy = #"{"id":"\#(UUID().uuidString)","conversationID":"\#(conversationID.uuidString)","body":"Old","timestamp":0,"direction":"incoming","state":"delivered","attachments":[]}"#
    let migrated = try JSONDecoder().decode(Message.self, from: Data(legacy.utf8))
    #expect(migrated.lxmfID == nil)
    #expect(migrated.replyTo == nil)
    #expect(migrated.replyQuote == nil)
    #expect(migrated.renderer == .plain)
}

@Test func lxmfReplyFieldsRoundTripWithUpstreamFieldIDs() throws {
    let sender = ReticulumIdentity()
    let replyID = Data(repeating: 0xAB, count: 32)
    let quote = Data("Quoted message".utf8)
    let message = try LXMFMessage(
        destinationHash: Data(repeating: 0x01, count: 16),
        sourceHash: Data(repeating: 0x02, count: 16),
        sourceIdentity: sender,
        content: Data("Reply".utf8),
        fields: [0x30: replyID, 0x31: quote]
    )
    let received = try LXMFReceivedMessage(packed: message.packed)
    #expect(received.binaryField(0x30) == replyID)
    #expect(received.binaryField(0x31) == quote)
    #expect(received.validate(with: sender))
}

@Test func lxmfMarkdownRendererUsesUpstreamIntegerField() throws {
    let sender = ReticulumIdentity()
    let message = try LXMFMessage(
        destinationHash: Data(repeating: 0x01, count: 16),
        sourceHash: Data(repeating: 0x02, count: 16),
        sourceIdentity: sender,
        content: Data("**formatted**".utf8),
        encodedFields: [0x0F: MessagePack.unsigned(0x02)]
    )
    let received = try LXMFReceivedMessage(packed: message.packed)
    #expect(received.unsignedField(0x0F) == 0x02)
    #expect(received.binaryField(0x0F) == nil)
    #expect(received.validate(with: sender))
}

@Test func standardPythonLXMFOneMiBAttachmentsDecodeAndValidate() throws {
    let sender = ReticulumIdentity()
    let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
    let destination = Data(repeating: 0x01, count: 16)
    let source = Data(repeating: 0x02, count: 16)
    let file = try LXMFMessage(
        destinationHash: destination, sourceHash: source, sourceIdentity: sender,
        content: Data("file".utf8),
        encodedFields: [0x05: MessagePack.array([
            MessagePack.array([MessagePack.binary(Data("payload.bin".utf8)), MessagePack.binary(payload)])
        ])]
    )
    let image = try LXMFMessage(
        destinationHash: destination, sourceHash: source, sourceIdentity: sender,
        content: Data("image".utf8),
        encodedFields: [0x06: MessagePack.array([
            MessagePack.binary(Data("bmp".utf8)), MessagePack.binary(payload)
        ])]
    )
    let receivedFile = try LXMFReceivedMessage(packed: file.packed)
    let receivedImage = try LXMFReceivedMessage(packed: image.packed)
    #expect(receivedFile.fields[0x05] != nil)
    #expect(receivedImage.fields[0x06] != nil)
    #expect(receivedFile.validate(with: sender))
    #expect(receivedImage.validate(with: sender))
}

@Test func lxmfReactionFieldMatchesUpstreamMapShape() throws {
    let sender = ReticulumIdentity()
    let target = Data(repeating: 0xAB, count: 32)
    let content = Data("👍".utf8)
    let reaction = MessagePack.map([
        (0x00, MessagePack.binary(target)),
        (0x01, MessagePack.binary(content))
    ])
    let message = try LXMFMessage(
        destinationHash: Data(repeating: 0x01, count: 16),
        sourceHash: Data(repeating: 0x02, count: 16),
        sourceIdentity: sender,
        content: Data(),
        encodedFields: [0x40: reaction]
    )
    let received = try LXMFReceivedMessage(packed: message.packed)
    #expect(received.binaryMapField(0x40, key: 0x00) == target)
    #expect(received.binaryMapField(0x40, key: 0x01) == content)
    #expect(received.validate(with: sender))
}

@Test func lxmfCommentAndContinuationFieldsMatchUpstreamMaps() throws {
    let sender = ReticulumIdentity()
    let commentTarget = Data(repeating: 0x11, count: 32)
    let continuationTarget = Data(repeating: 0x22, count: 32)
    let message = try LXMFMessage(
        destinationHash: Data(repeating: 0x01, count: 16),
        sourceHash: Data(repeating: 0x02, count: 16),
        sourceIdentity: sender,
        content: Data("Threaded response".utf8),
        encodedFields: [
            0x41: MessagePack.map([(0x00, MessagePack.binary(commentTarget))]),
            0x42: MessagePack.map([(0x00, MessagePack.binary(continuationTarget))])
        ]
    )
    let received = try LXMFReceivedMessage(packed: message.packed)
    #expect(received.binaryMapField(0x41, key: 0x00) == commentTarget)
    #expect(received.binaryMapField(0x42, key: 0x00) == continuationTarget)
    #expect(received.validate(with: sender))
}

@Test func typedLXMFCommandsMatchPythonSidebandFieldShape() throws {
    let request = LXMFCommand.telemetryRequest(timebase: Date(timeIntervalSince1970: 1_700_000_000), collector: true)
    let encoded = try #require(LXMFCommand.encode([request, .ping, .echo("hello"), .signalReport]))
    let sender = ReticulumIdentity()
    let message = try LXMFMessage(
        destinationHash: Data(repeating: 0x01, count: 16),
        sourceHash: Data(repeating: 0x02, count: 16),
        sourceIdentity: sender,
        content: Data(),
        encodedFields: [0x09: encoded]
    )
    let received = try LXMFReceivedMessage(packed: message.packed)
    #expect(LXMFCommand.decode(received.fields[0x09]) == [request, .ping, .echo("hello"), .signalReport])
    #expect(received.validate(with: sender))
}

@Test func pluginCommandsDecodeAsTypedRequestsWithoutExecution() {
    let plugin = MessagePack.array([MessagePack.map([(0x00, MessagePack.string("weather \"Melbourne CBD\""))])])
    let oversized = MessagePack.array([MessagePack.map([(0x03, MessagePack.binary(Data(repeating: 0x61, count: 1_025)))])])
    #expect(LXMFCommand.decode(try? MessagePackDecoder.decode(plugin)) == [.plugin(command: "weather", arguments: ["Melbourne CBD"])])
    #expect(LXMFCommand.decode(try? MessagePackDecoder.decode(oversized)).isEmpty)
    #expect(LXMFCommand.encode(Array(repeating: .ping, count: 9)) == nil)
}

@Test func pluginCommandLinesRoundTripQuotesAndRejectUnsafeNames() {
    let line = SidebandPluginCommandLine.encode(command: "test-echo", arguments: ["two words", "quote\"slash\\"])
    let parsed = line.flatMap(SidebandPluginCommandLine.parse)
    #expect(parsed?.command == "test-echo")
    #expect(parsed?.arguments == ["two words", "quote\"slash\\"])
    #expect(SidebandPluginCommandLine.encode(command: "bad;command", arguments: []) == nil)
    #expect(SidebandPluginCommandLine.parse("unterminated \"quote") == nil)
}

@Test func messagePackExtendedStringsRoundTrip() throws {
    for length in [32, 255, 256, 1_024] {
        let value = String(repeating: "x", count: length)
        #expect(try MessagePackDecoder.decode(MessagePack.string(value)) == .string(value))
    }
}

@MainActor @Test func nativePluginRegistryDispatchesOnlyEnabledDeclaredCommands() async {
    let defaults = UserDefaults.standard
    let key = "sidebandEnabledPlugins"
    let previous = defaults.stringArray(forKey: key)
    defer {
        if let previous { defaults.set(previous, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    defaults.removeObject(forKey: key)
    let registry = SidebandPluginRegistry(plugins: [TestNativePlugin()], enabledIdentifiers: ["test.native"], persistsConfiguration: false)
    let context = SidebandPluginContext(command: "test-echo", arguments: ["a", "b"], senderDestinationHash: String(repeating: "0", count: 32), networkReady: true, routeAvailable: true)
    let success = await registry.execute(command: "test-echo", arguments: ["a", "b"], context: context)
    #expect(success.response?.text == "a|b")
    #expect(success.outcome == .succeeded)
    #expect(await registry.execute(command: "undeclared", arguments: [], context: context).outcome == .unavailable)
    registry.setEnabled(false, identifier: "test.native")
    #expect(await registry.execute(command: "test-echo", arguments: [], context: context).outcome == .unavailable)
}

@MainActor @Test func nativePluginsReceiveOnlyDeclaredContextPermissions() async {
    let fullContext = SidebandPluginContext(command: "probe", arguments: [], senderDestinationHash: String(repeating: "a", count: 32), networkReady: true, routeAvailable: false)
    let restricted = SidebandPluginRegistry(plugins: [PermissionProbePlugin(permissions: [])], enabledIdentifiers: ["test.permissions"], persistsConfiguration: false)
    #expect(await restricted.execute(command: "probe", arguments: [], context: fullContext).response?.text == "redacted|redacted|redacted")

    let allowed = SidebandPluginRegistry(plugins: [PermissionProbePlugin(permissions: [.networkStatus, .conversationMetadata])], enabledIdentifiers: ["test.permissions"], persistsConfiguration: false)
    #expect(await allowed.execute(command: "probe", arguments: [], context: fullContext).response?.text == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|true|false")
}

@MainActor @Test func nativeTelemetryPluginsContributeCanonicalSensors() async throws {
    let registry = SidebandPluginRegistry(plugins: [], telemetry: [SystemTelemetryPlugin()],
                                          enabledIdentifiers: ["app.sideband.system-telemetry"], persistsConfiguration: false)
    let sensors = await registry.collectTelemetry()
    #expect(sensors[SidebandTelemetry.SensorKind.processor.rawValue] != nil)
    #expect(sensors[SidebandTelemetry.SensorKind.ram.rawValue] != nil)
    for encoded in sensors.values { _ = try MessagePackDecoder.decode(encoded) }
}

@MainActor @Test func nativePluginTimeoutIsBoundedAndReported() async {
    let registry = SidebandPluginRegistry(plugins: [SlowNativePlugin()], executionTimeout: .milliseconds(10), enabledIdentifiers: ["test.slow"], persistsConfiguration: false)
    let context = SidebandPluginContext(command: "slow", arguments: [])
    let result = await registry.execute(command: "slow", arguments: [], context: context)
    #expect(result.outcome == .timedOut)
    #expect(result.response?.text == "Plugin request timed out safely.")
}

@Test func pluginAuditHistoryDecodesLegacySnapshotsAndRejectsSensitivePayloads() throws {
    let legacy = Data("{\"schemaVersion\":1}".utf8)
    #expect(try JSONDecoder().decode(AppSnapshot.self, from: legacy).pluginAuditEvents.isEmpty)
    let event = SidebandPluginAuditEvent(pluginIdentifier: "test.native", command: "probe", conversationID: UUID(), outcome: .succeeded)
    let encoded = try JSONEncoder().encode(event)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("arguments"))
    #expect(!text.contains("senderDestinationHash"))
}

@MainActor @Test func reactionsAreBoundedQueuedAndPersisted() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Reaction Peer"))
    let conversationID = store.conversations[0].id
    let targetHash = Data(repeating: 0xCD, count: 32)
    let target = Message(conversationID: conversationID, body: "Hello", direction: .incoming, state: .delivered, lxmfID: targetHash)

    await store.sendReaction(" 👍 ", to: target)
    #expect(store.messages.count == 1)
    #expect(store.messages[0].reactionTo == targetHash)
    #expect(store.messages[0].reactionContent == "👍")
    #expect(store.messages[0].state == .queued)
    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.messages[0].reactionTo == targetHash)
    #expect(reloaded.messages[0].reactionContent == "👍")

    await store.sendReaction("👍", to: target)
    #expect(store.messages.count == 1)

    await store.sendReaction("123456789", to: target)
    #expect(store.messages.count == 1)
    #expect(store.lastError == "A reaction must contain between 1 and 8 characters.")
}

@MainActor @Test func repliesPersistLXMFCommentReference() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Thread Peer"))
    let conversationID = store.conversations[0].id
    let targetHash = Data(repeating: 0xEF, count: 32)
    let target = Message(conversationID: conversationID, body: "Original", direction: .incoming, state: .delivered, lxmfID: targetHash)

    await store.send("Response", attachments: [], replyingTo: target)
    #expect(store.messages[0].replyTo == targetHash)
    #expect(store.messages[0].commentTo == targetHash)
    #expect(SidebandStore(persistenceURL: url).messages[0].commentTo == targetHash)
}

@MainActor @Test func commandRequestsAreProtocolOnlyBoundedAndPersisted() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Command Peer"))
    let conversationID = store.conversations[0].id

    await store.sendCommand(.ping, conversationID: conversationID)
    #expect(store.messages.count == 1)
    #expect(store.messages[0].body.isEmpty)
    #expect(store.messages[0].commands == [.ping])
    #expect(SidebandStore(persistenceURL: url).messages[0].commands == [.ping])

    await store.sendCommand(.echo(String(repeating: "x", count: 257)), conversationID: conversationID)
    #expect(store.messages.count == 1)
    #expect(store.lastError?.contains("256") == true)
}

@MainActor @Test func markdownComposerPrefixIsStrippedAndPersisted() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Markdown Peer"))
    await store.send("#!md\n**important**", attachments: [])
    #expect(store.messages.first?.body == "**important**")
    #expect(store.messages.first?.renderer == .markdown)
    #expect(SidebandStore(persistenceURL: url).messages.first?.renderer == .markdown)
}

@MainActor @Test func exportedSnapshotDataRoundTripsCurrentState() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Backup Peer"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(AppSnapshot.self, from: store.exportSnapshotData())
    #expect(snapshot.schemaVersion == AppSnapshot.currentSchemaVersion)
    #expect(snapshot.conversations.first?.displayName == "Backup Peer")
}

@MainActor @Test func validatedBackupRestoresApplicationState() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let source = SidebandStore(persistenceURL: root.appending(path: "source.json"))
    #expect(source.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Restored Peer"))
    source.updateDraft("saved draft", for: source.conversations[0].id)
    let backup = try source.exportSnapshotData()
    let target = SidebandStore(persistenceURL: root.appending(path: "target.json"))

    try target.restoreSnapshotData(backup)
    #expect(target.conversations.first?.displayName == "Restored Peer")
    #expect(target.draft(for: target.conversations[0].id) == "saved draft")
}

@MainActor @Test func automaticBackupPreservesPreviousValidSnapshot() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Before Rename"))
    #expect(store.renameConversation(store.conversations[0].id, to: "After Rename"))

    let backupData = try Data(contentsOf: store.automaticBackupURL)
    #expect(LocalDataCipher().isEncrypted(backupData))
    let backupPlaintext = try LocalDataCipher().open(backupData, context: "application-snapshot-v1")
    let backup = try store.validatedSnapshot(from: backupPlaintext)
    #expect(backup.conversations.first?.displayName == "Before Rename")
    #expect(store.conversations.first?.displayName == "After Rename")
}

@MainActor @Test func corruptPersistenceIsQuarantinedAndRollingBackupRecovered() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let url = root.appending(path: "store.json")
    let original = SidebandStore(persistenceURL: url)
    #expect(original.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Recover Me"))
    #expect(original.renameConversation(original.conversations[0].id, to: "Current Name"))
    try Data("not-json".utf8).write(to: url, options: .atomic)

    let recovered = SidebandStore(persistenceURL: url)
    let quarantineURL = try #require(recovered.lastQuarantinedPersistenceURL)
    #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
    #expect(try Data(contentsOf: quarantineURL) == Data("not-json".utf8))
    #expect(recovered.conversations.first?.displayName == "Recover Me")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@MainActor @Test func localPersistenceIsEncryptedAndMigratesPlaintext() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let url = root.appending(path: "store.json")
    let destination = "0123456789abcdef0123456789abcdef"
    let conversation = Conversation(destinationHash: destination, displayName: "Private local message")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let plaintext = try encoder.encode(AppSnapshot(conversations: [conversation]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try plaintext.write(to: url, options: .atomic)

    let migrated = SidebandStore(persistenceURL: url)
    #expect(migrated.conversations.first?.displayName == "Private local message")
    let encrypted = try Data(contentsOf: url)
    #expect(LocalDataCipher().isEncrypted(encrypted))
    #expect(!encrypted.contains(Data("Private local message".utf8)))
    #expect(SidebandStore(persistenceURL: url).conversations.first?.destinationHash == destination)
}

@Test func attachmentStoreRemovesOnlyUnreferencedRegularFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = AttachmentStore(directory: directory)
    let kept = try await store.save(data: Data("keep".utf8), filename: "keep.txt", mimeType: "text/plain")
    let orphan = try await store.save(data: Data("remove".utf8), filename: "orphan.txt", mimeType: "text/plain")

    let removed = try await store.removeOrphans(referencedRelativePaths: [kept.relativePath])
    #expect(removed == 1)
    #expect(FileManager.default.fileExists(atPath: await store.url(for: kept).path))
    #expect(!FileManager.default.fileExists(atPath: await store.url(for: orphan).path))
}

@MainActor @Test func queuesMessagesWithoutClaimingDelivery() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Test"))
    await store.send("hello")
    #expect(store.messages.count == 1)
    #expect(store.messages[0].state == .queued)
    #expect(store.messages[0].outboxOwnerID?.isEmpty == false)
    #expect(store.messages[0].outboxOwnerUpdatedAt != nil)
}

@MainActor @Test func queuedTelemetryPersistsAcrossRelaunch() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Telemetry Peer"))
    let telemetry = SidebandTelemetry(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        location: .init(latitude: -37.8136, longitude: 144.9631, accuracy: 8, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    )

    await store.send("Position", attachments: [], telemetry: telemetry)
    let reloaded = SidebandStore(persistenceURL: url)
    #expect(reloaded.messages.first?.telemetry == telemetry)
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
    let telemetry = SidebandTelemetry(location: .init(latitude: -37.8136, longitude: 144.9631, accuracy: 8))
    let message = Message(conversationID: conversation.id, body: "hello", timestamp: Date(timeIntervalSince1970: 0), direction: .incoming, state: .delivered, attachments: [attachment], telemetry: telemetry)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)

    let transcript = try #require(SidebandStore(persistenceURL: url).conversationTranscript(conversation.id))
    #expect(transcript.contains("Peer: hello [Attachment: photo.jpg]"))
    #expect(transcript.contains("[Location: -37.813600, 144.963100 ±8m]"))
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

@MainActor @Test func retryAllFailedMessagesRequeuesConversationOutbox() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let failed = Message(conversationID: conversation.id, body: "one", direction: .outgoing, state: .failed)
    let delivered = Message(conversationID: conversation.id, body: "two", direction: .outgoing, state: .delivered)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [failed, delivered])).write(to: url)
    let store = SidebandStore(persistenceURL: url)
    #expect(store.failedMessageCount(for: conversation.id) == 1)

    await store.retryAllFailedMessages(in: conversation.id)
    #expect(store.messages.first(where: { $0.id == failed.id })?.state == .queued)
    #expect(store.messages.first(where: { $0.id == delivered.id })?.state == .delivered)
}

@MainActor @Test func deliveryHealthMetricsReflectPersistedOutbox() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let attachment = Attachment(filename: "active.bin", byteCount: 1, relativePath: "active", state: .transferring)
    let target = Data(repeating: 0xAA, count: 32)
    let messages = [
        Message(conversationID: conversation.id, body: "in", direction: .incoming, state: .delivered),
        Message(conversationID: conversation.id, body: "queued", direction: .outgoing, state: .queued, attachments: [attachment]),
        Message(conversationID: conversation.id, body: "sent", direction: .outgoing, state: .sent),
        Message(conversationID: conversation.id, body: "done", direction: .outgoing, state: .delivered),
        Message(conversationID: conversation.id, body: "failed", direction: .outgoing, state: .failed),
        Message(conversationID: conversation.id, body: "", direction: .outgoing, state: .queued, reactionTo: target, reactionContent: "👍")
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: messages)).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(store.incomingMessageCount == 1)
    #expect(store.outgoingMessageCount == 5)
    // Unproved sent messages are intentionally recovered into the queued outbox on launch.
    #expect(store.queuedMessageCount == 3)
    #expect(store.sentMessageCount == 0)
    #expect(store.deliveredMessageCount == 1)
    #expect(store.failedMessageCount == 1)
    #expect(store.reactionCount == 1)
    #expect(store.activeAttachmentTransferCount == 1)
    #expect(store.deliverySuccessRate == 0.5)
}

@Test func deliveryAttemptMetadataIsLegacySafeAndCloudMergeKeepsNewestEvidence() throws {
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let legacy = Message(conversationID: conversation.id, body: "legacy", direction: .outgoing, state: .queued)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Message.self, from: encoder.encode(legacy))
    #expect(decoded.deliveryAttemptCount == 0)
    #expect(decoded.lastDeliveryAttemptAt == nil)

    let older = Message(id: legacy.id, conversationID: conversation.id, body: "send", direction: .outgoing, state: .queued, deliveryAttemptCount: 1, lastDeliveryAttemptAt: Date(timeIntervalSince1970: 10), lastDeliveryMode: .opportunistic, lastDeliveryFailure: "Timed out")
    let newer = Message(id: legacy.id, conversationID: conversation.id, body: "send", direction: .outgoing, state: .delivered, deliveryAttemptCount: 2, lastDeliveryAttemptAt: Date(timeIntervalSince1970: 20), lastDeliveryMode: .directLink)
    let merged = AppSnapshot(conversations: [conversation], messages: [newer]).mergingCloudSnapshot(AppSnapshot(conversations: [conversation], messages: [older]))
    let result = try #require(merged.messages.first)
    #expect(result.state == .delivered)
    #expect(result.deliveryAttemptCount == 2)
    #expect(result.lastDeliveryAttemptAt == Date(timeIntervalSince1970: 20))
    #expect(result.lastDeliveryMode == .directLink)
    #expect(result.lastDeliveryFailure == nil)
}

@MainActor @Test func duplicateAttachmentsAreRejectedByContentHash() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let hash = Data(repeating: 7, count: 32)
    let first = Attachment(filename: "first.jpg", byteCount: 10, relativePath: "first", state: .local, contentHash: hash)
    let duplicate = Attachment(filename: "copy.jpg", byteCount: 10, relativePath: "copy", state: .local, contentHash: hash)

    #expect(!store.validateAttachmentIsUnique(duplicate, among: [first]))
    #expect(store.lastError?.contains("already attached") == true)
}

@MainActor @Test func combinedAttachmentSizeIsLimitedPerMessage() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let half = SidebandMessageLimits.maximumCombinedAttachmentBytes / 2
    let first = Attachment(filename: "first.bin", byteCount: half + 1, relativePath: "first", state: .local)
    let second = Attachment(filename: "second.bin", byteCount: half, relativePath: "second", state: .local)

    #expect(!store.validateAttachmentTotal([first, second]))
    #expect(store.lastError?.contains("Combined attachments") == true)
}

@MainActor @Test func attachmentImportFailuresArePresentedToTheUser() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    store.reportAttachmentImportFailure(filename: "large.bin", error: AttachmentStoreError.tooLarge)

    #expect(store.lastError?.contains("large.bin") == true)
    #expect(store.lastError?.contains("maximum attachment size") == true)
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

@MainActor @Test func deletingAnyMessageUpdatesConversationHistory() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversation = try #require(store.selectedConversation)
    await store.send("Delete me")
    let message = try #require(store.messages(for: conversation.id).first)

    await store.deleteMessage(message.id)

    #expect(store.messages(for: conversation.id).isEmpty)
    #expect(store.conversations.contains(where: { $0.id == conversation.id }))
}

@MainActor @Test func forwardingCreatesIndependentQueuedMessage() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Source"))
    let source = try #require(store.selectedConversation)
    await store.send("**Forward this**", attachments: [], renderer: .markdown)
    let original = try #require(store.messages(for: source.id).first)
    #expect(store.addConversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Destination"))
    let destination = try #require(store.selectedConversation)

    #expect(await store.forwardMessage(original.id, to: destination.id))

    let forwarded = try #require(store.messages(for: destination.id).first)
    #expect(forwarded.id != original.id)
    #expect(forwarded.body == original.body)
    #expect(forwarded.renderer == .markdown)
    #expect(forwarded.direction == .outgoing)
    #expect(forwarded.state == .queued)
}

@MainActor @Test func messageSummaryIndexesRefreshAfterMessageRemoval() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let delivered = Message(
        conversationID: conversation.id,
        body: "delivered",
        timestamp: Date(timeIntervalSince1970: 100),
        direction: .outgoing,
        state: .delivered
    )
    let failed = Message(
        conversationID: conversation.id,
        body: "failed",
        timestamp: Date(timeIntervalSince1970: 200),
        direction: .outgoing,
        state: .failed
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [delivered, failed])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(store.latestMessage(for: conversation.id)?.id == failed.id)
    #expect(store.failedMessageCount(for: conversation.id) == 1)
    await store.removeFailedMessage(failed.id)
    #expect(store.latestMessage(for: conversation.id)?.id == delivered.id)
    #expect(store.failedMessageCount(for: conversation.id) == 0)
}

@MainActor @Test func cachedConversationTranscriptRefreshesAfterRename() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Before")
    let message = Message(conversationID: conversation.id, body: "hello", direction: .incoming, state: .delivered)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(store.conversationTranscript(conversation.id)?.contains("Conversation with Before") == true)
    #expect(store.renameConversation(conversation.id, to: "After"))
    #expect(store.conversationTranscript(conversation.id)?.contains("Conversation with After") == true)
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

@MainActor @Test func notificationSelectionRestoresOpensAndReadsConversation() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(
        destinationHash: "0123456789abcdef0123456789abcdef",
        displayName: "Notification peer",
        isArchived: true,
        unreadCount: 2
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation])).write(to: url)
    let store = SidebandStore(persistenceURL: url)
    store.selectedConversationID = nil

    store.openConversationFromNotification(conversation.id)

    #expect(store.selectedConversationID == conversation.id)
    #expect(store.selectedConversation?.isArchived == false)
    #expect(store.selectedConversation?.unreadCount == 0)
}

@MainActor @Test func notificationPolicySuppressesMutedAndVisibleActiveConversations() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversationID = store.conversations[0].id

    #expect(store.shouldNotifyIncoming(for: conversationID))
    store.conversationDidAppear(conversationID)
    #expect(!store.shouldNotifyIncoming(for: conversationID))
    store.applicationDidBecomeInactive()
    #expect(store.shouldNotifyIncoming(for: conversationID))
    store.setConversationNotificationsMuted(true, conversationID: conversationID)
    #expect(!store.shouldNotifyIncoming(for: conversationID))
}

@MainActor @Test func addingBackgroundConversationDoesNotReplaceSelection() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Selected"))
    let selectedID = store.selectedConversationID

    #expect(store.addConversation(destinationHash: "fedcba9876543210fedcba9876543210", displayName: "Background", select: false))
    #expect(store.selectedConversationID == selectedID)
}

@MainActor @Test func latestMessageActivitySurfacesConversationAfterRelaunch() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let staleRecord = Conversation(
        destinationHash: "0123456789abcdef0123456789abcdef",
        displayName: "Recently active",
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newerRecord = Conversation(
        destinationHash: "fedcba9876543210fedcba9876543210",
        displayName: "Stale chat",
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let latestMessage = Message(
        conversationID: staleRecord.id,
        body: "Newest activity",
        timestamp: Date(timeIntervalSince1970: 300),
        direction: .incoming,
        state: .delivered
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [newerRecord, staleRecord], messages: [latestMessage])).write(to: url)

    let store = SidebandStore(persistenceURL: url)

    #expect(store.conversations.first?.id == staleRecord.id)
}

@MainActor @Test func startingAnExistingConversationSurfacesItAgain() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let firstHash = "0123456789abcdef0123456789abcdef"
    let secondHash = "fedcba9876543210fedcba9876543210"
    #expect(store.addConversation(destinationHash: firstHash, displayName: "First"))
    #expect(store.addConversation(destinationHash: secondHash, displayName: "Second"))
    #expect(store.conversations.first?.destinationHash == secondHash)

    #expect(store.addConversation(destinationHash: firstHash, displayName: "First"))

    #expect(store.conversations.first?.destinationHash == firstHash)
}

@MainActor @Test func startingAnArchivedDiscoveryRestoresAndSelectsConversation() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    let hash = "0123456789abcdef0123456789abcdef"
    #expect(store.addConversation(destinationHash: hash, displayName: "Peer"))
    let conversationID = store.conversations[0].id
    store.setConversationArchived(true, conversationID: conversationID)
    store.selectedConversationID = nil
    let discovery = DiscoveredDestination(destinationHash: hash, hops: 1, isValidated: true)

    #expect(store.addConversation(from: discovery))

    #expect(store.selectedConversationID == conversationID)
    #expect(store.conversations.first(where: { $0.id == conversationID })?.isArchived == false)
}

@MainActor @Test func renameConversationPersistsNonemptyName() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Original"))
    let id = store.conversations[0].id
    #expect(!store.renameConversation(id, to: "   "))
    let previousUpdate = store.conversations[0].updatedAt
    #expect(store.renameConversation(id, to: " Renamed "))
    let reloaded = SidebandStore(persistenceURL: url).conversations[0]
    #expect(reloaded.displayName == "Renamed")
    #expect(reloaded.updatedAt.timeIntervalSince1970.rounded(.down) >= previousUpdate.timeIntervalSince1970.rounded(.down))
    #expect(store.renameConversation(id, to: String(repeating: "a", count: 200)))
    #expect(store.conversations[0].displayName.count == 128)
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

@Test func cloudConversationDeletionWinsOverOlderSnapshots() throws {
    let destination = "0123456789abcdef0123456789abcdef"
    let conversation = Conversation(
        destinationHash: destination,
        displayName: "Old cloud conversation",
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let message = Message(
        conversationID: conversation.id,
        body: "old message",
        timestamp: Date(timeIntervalSince1970: 10),
        direction: .incoming,
        state: .delivered
    )
    let remote = AppSnapshot(conversations: [conversation], messages: [message], drafts: [conversation.id: "old draft"])
    let local = AppSnapshot(deletedConversationDestinations: [destination: Date(timeIntervalSince1970: 20)])

    let merged = local.mergingCloudSnapshot(remote)

    #expect(merged.conversations.isEmpty)
    #expect(merged.messages.isEmpty)
    #expect(merged.drafts.isEmpty)
    #expect(merged.deletedConversationDestinations[destination] == Date(timeIntervalSince1970: 20))
}

@Test func newerConversationActivityClearsOlderDeletionTombstone() {
    let destination = "0123456789abcdef0123456789abcdef"
    let conversation = Conversation(
        destinationHash: destination,
        displayName: "New message",
        updatedAt: Date(timeIntervalSince1970: 30)
    )
    let merged = AppSnapshot(deletedConversationDestinations: [destination: Date(timeIntervalSince1970: 20)])
        .mergingCloudSnapshot(AppSnapshot(conversations: [conversation]))

    #expect(merged.conversations.map(\.destinationHash) == [destination])
    #expect(merged.deletedConversationDestinations[destination] == nil)
}

@MainActor @Test func iCloudSyncDoesNotRestoreDeletedConversation() async throws {
    let destination = "0123456789abcdef0123456789abcdef"
    let conversation = Conversation(
        destinationHash: destination,
        displayName: "Cloud peer",
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let cloud = CountingCloudSync()
    await cloud.seedSnapshot(CloudSnapshotPayload(
        data: try encoder.encode(AppSnapshot(conversations: [conversation])),
        modifiedAt: Date(timeIntervalSince1970: 10),
        deviceID: "old-device"
    ))
    let store = SidebandStore(
        persistenceURL: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "store.json"),
        cloudSync: cloud
    )

    await store.setICloudSyncEnabled(true)
    #expect(store.conversations.map(\.destinationHash) == [destination])
    await store.deleteConversation(try #require(store.conversations.first?.id))
    await store.syncICloudNow()
    await store.syncICloudNow()

    #expect(store.conversations.isEmpty)
    let saved = try #require(await cloud.currentSnapshot())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(AppSnapshot.self, from: saved.data)
    #expect(snapshot.conversations.isEmpty)
    #expect(snapshot.deletedConversationDestinations[destination] != nil)
}

@MainActor @Test func trustedConversationStatePersists() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = store.conversations[0].id
    store.setConversationTrusted(true, conversationID: id)
    #expect(SidebandStore(persistenceURL: url).conversations[0].isTrusted)
}

@MainActor @Test func perContactPluginAuthorizationIsOffByDefaultAndPersists() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Plugin Peer"))
    let id = store.conversations[0].id
    #expect(!store.conversations[0].pluginCommandsEnabled)
    store.setConversationPluginCommands(true, conversationID: id)
    #expect(SidebandStore(persistenceURL: url).conversations[0].pluginCommandsEnabled)
}

@MainActor @Test func richTextRenderingDefaultsToTrustedIncomingContacts() {
    let defaults = UserDefaults.standard
    let key = "lxmfRichTextTrustedOnly"
    let previous = defaults.object(forKey: key)
    defaults.removeObject(forKey: key)
    defer {
        if let previous { defaults.set(previous, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversationID = store.conversations[0].id
    let incoming = Message(conversationID: conversationID, body: "[site](https://example.com)", direction: .incoming, state: .delivered, renderer: .markdown)
    let outgoing = Message(conversationID: conversationID, body: "**hello**", direction: .outgoing, state: .sent, renderer: .markdown)

    #expect(store.richTextTrustedOnly)
    #expect(!store.shouldRenderRichText(incoming, conversationID: conversationID))
    #expect(store.shouldRenderRichText(outgoing, conversationID: conversationID))
    store.setConversationTrusted(true, conversationID: conversationID)
    #expect(store.shouldRenderRichText(incoming, conversationID: conversationID))
}

@MainActor @Test func richTextTrustPolicyCanBeDisabledAndPersists() {
    let defaults = UserDefaults.standard
    let key = "lxmfRichTextTrustedOnly"
    let previous = defaults.object(forKey: key)
    defer {
        if let previous { defaults.set(previous, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    let firstURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: firstURL)
    store.setRichTextTrustedOnly(false)
    let reloaded = SidebandStore(persistenceURL: firstURL)
    #expect(!reloaded.richTextTrustedOnly)
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

@MainActor @Test func telemetrySharingPolicyPersistsAndBlocksSend() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversation = try #require(store.selectedConversation)
    store.setConversationTelemetrySharing(false, conversationID: conversation.id)

    await store.send("Shared telemetry", attachments: [], telemetry: SidebandTelemetry())

    #expect(store.messages(for: conversation.id).isEmpty)
    #expect(store.lastError == "Telemetry sharing is disabled for this contact.")
    #expect(SidebandStore(persistenceURL: url).conversations.first?.telemetrySharingEnabled == false)
}

@MainActor @Test func clearingTelemetryPreservesMessages() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let conversation = try #require(store.selectedConversation)
    await store.send("Position", attachments: [], telemetry: SidebandTelemetry(location: .init(latitude: -37.8, longitude: 145.0)))

    #expect(store.telemetryMessageCount(for: conversation.id) == 1)
    #expect(store.clearTelemetryHistory(conversation.id) == 1)
    #expect(store.messages(for: conversation.id).count == 1)
    #expect(store.messages(for: conversation.id).first?.body == "Position")
    #expect(store.messages(for: conversation.id).first?.telemetry == nil)
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
    let storedData = try Data(contentsOf: storedURL)
    #expect(LocalDataCipher().isEncrypted(storedData))
    #expect(!storedData.contains(Data("attachment".utf8)))
    #expect(try await store.read(attachment) == Data("attachment".utf8))
}

@Test func attachmentStoreMigratesLegacyPlaintextFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("legacy attachment".utf8)
    let id = UUID()
    let relativePath = "\(id.uuidString)-legacy.txt"
    let attachment = Attachment(
        id: id, filename: "legacy.txt", mimeType: "text/plain", byteCount: data.count,
        relativePath: relativePath, state: .available, progress: 1,
        contentHash: ReticulumIdentity.fullHash(data)
    )
    let storedURL = root.appending(path: relativePath)
    try data.write(to: storedURL)
    let store = AttachmentStore(directory: root)

    #expect(try await store.read(attachment) == data)
    #expect(LocalDataCipher().isEncrypted(try Data(contentsOf: storedURL)))
}

@Test func attachmentStoreMaterializesAndRemovesTemporaryPlaintext() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AttachmentStore(directory: root)
    let data = Data("preview only".utf8)
    let attachment = try await store.save(data: data, filename: "preview.txt", mimeType: "text/plain")

    let previewURL = try await store.materializedURL(for: attachment)
    #expect(try Data(contentsOf: previewURL) == data)
    await store.removeMaterializedFile(for: attachment)
    #expect(!FileManager.default.fileExists(atPath: previewURL.path))
}

@Test func attachmentStoreRecognizesVoiceMessageAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let source = root.appending(path: "voice.m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0, 1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = AttachmentStore(directory: root.appending(path: "stored"))
    let attachment = try await store.importFile(from: source)

    #expect(attachment.filename == "voice.m4a")
    #expect(attachment.mimeType?.hasPrefix("audio/") == true)
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

@Test func attachmentStoreRestoresCloudAssetWithStableIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("cloud image bytes".utf8)
    let id = UUID()
    let payload = CloudAttachmentPayload(
        id: id, data: data, filename: "../photo.jpg", mimeType: "image/jpeg",
        contentHash: ReticulumIdentity.fullHash(data)
    )
    let store = AttachmentStore(directory: root)
    let attachment = try await store.restoreCloudAttachment(payload)

    #expect(attachment.id == id)
    #expect(attachment.filename == "photo.jpg")
    #expect(attachment.state == .available)
    #expect(attachment.progress == 1)
    #expect(try await store.read(attachment) == data)
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

@Test func attachmentResourceEnvelopePreservesRichMessageContext() throws {
    let identity = ReticulumIdentity()
    let replyID = Data(repeating: 0x5A, count: 32)
    let timestamp = Date(timeIntervalSince1970: 1_725_000_123.25)
    let envelope = try LXMFResourceEnvelope(
        filename: "report.md", mimeType: "text/markdown", messageBody: "**Update**",
        sourceHash: Data(repeating: 4, count: 16), renderer: .markdown,
        replyTo: replyID, replyQuote: "Earlier update", timestamp: timestamp,
        fileData: Data("details".utf8), signingIdentity: identity
    )
    let decoded = try LXMFResourceEnvelope(encoded: envelope.encode())
    #expect(decoded.renderer == .markdown)
    #expect(decoded.replyTo == replyID)
    #expect(decoded.replyQuote == "Earlier update")
    #expect(decoded.timestamp == timestamp)
    #expect(decoded.validate(with: identity))
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
    let staged = try Data(contentsOf: root.appending(path: hash.hex).appending(path: "2.part"))
    #expect(LocalDataCipher().isEncrypted(staged))
    #expect(!staged.contains(Data("cd".utf8)))
    _ = try await store.stage(data: Data("ab".utf8), originalHash: hash, segmentIndex: 1, totalSegments: 2, totalSize: 4)
    #expect(await store.isComplete(originalHash: hash))
    #expect(try await store.assemble(originalHash: hash) == Data("abcd".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: hash.hex).path))
}

@Test func resourceSafetyLimitsRejectOversizedTransfers() {
    #expect(ReticulumResourceLimits.accepts(dataSize: 1024, transferSize: 1100, partCount: 3, segments: 1, segmentIndex: 1, advertisedPartHashCount: 3))
    #expect(!ReticulumResourceLimits.accepts(dataSize: ReticulumResourceLimits.maximumAttachmentBytes + 100_000, transferSize: 1, partCount: 1, segments: 1, segmentIndex: 1, advertisedPartHashCount: 1))
    #expect(!ReticulumResourceLimits.accepts(dataSize: 1, transferSize: 1, partCount: 1, segments: 66, segmentIndex: 1, advertisedPartHashCount: 1))
    #expect(!ReticulumResourceLimits.accepts(dataSize: 1, transferSize: 1, partCount: 1_000_000_000, segments: 1, segmentIndex: 1, advertisedPartHashCount: 0))
    #expect(!ReticulumResourceLimits.accepts(dataSize: 1, transferSize: .max, partCount: 1, segments: 1, segmentIndex: 1, advertisedPartHashCount: 1))
}

@Test func resourceHashMapRejectsOverflowingSegmentsAndOversizedUpdates() throws {
    let manifest = try ReticulumResourceManifest(
        data: Data([0x11]),
        randomHash: Data(repeating: 0x22, count: ReticulumResourceManifest.randomHashLength)
    )
    var receiver = ReticulumResourceReceiver(manifest: manifest)
    #expect(throws: ResourceError.self) {
        try receiver.applyHashMap(segment: .max, hashes: [Data(repeating: 0x33, count: 4)])
    }

    let oversizedMap = Data(repeating: 0x44, count: (ReticulumResourceAdvertisement.hashMapMaximumEntries + 1) * 4)
    let encoded = manifest.resourceHash + MessagePack.array([
        MessagePack.unsigned(0), MessagePack.binary(oversizedMap)
    ])
    #expect(throws: ResourceError.self) { try ReticulumResourceHashMapUpdate(encoded: encoded) }

    let oversizedAdvertisement = MessagePack.map([
        ("t", MessagePack.unsigned(1)), ("d", MessagePack.unsigned(1)),
        ("n", MessagePack.unsigned(1)), ("h", MessagePack.binary(manifest.resourceHash)),
        ("r", MessagePack.binary(Data(repeating: 1, count: 4))),
        ("o", MessagePack.binary(manifest.resourceHash)), ("i", MessagePack.unsigned(1)),
        ("l", MessagePack.unsigned(1)), ("q", MessagePack.null),
        ("f", MessagePack.unsigned(0x21)), ("m", MessagePack.binary(oversizedMap))
    ])
    #expect(throws: ResourceError.self) { try ReticulumResourceAdvertisement(encoded: oversizedAdvertisement) }
}

@Test func resourceStagingRejectsUnboundedPreallocationClaims() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReticulumResourceStagingStore(directory: root)
    let hash = Data(repeating: 0x55, count: 32)

    await #expect(throws: ResourceError.self) {
        try await store.stage(data: Data(), originalHash: hash, segmentIndex: 1, totalSegments: 1, totalSize: .max)
    }
    await #expect(throws: ResourceError.self) {
        try await store.stage(data: Data(), originalHash: hash, segmentIndex: 1, totalSegments: ReticulumResourceLimits.maximumSegments + 1, totalSize: 0)
    }
}

@Test func resourceManifestRejectsForgedPartCountBeforeReceiverAllocation() throws {
    let forged = MessagePack.map([
        ("t", MessagePack.unsigned(1)), ("d", MessagePack.unsigned(1)),
        ("n", MessagePack.unsigned(1_000_000_000)), ("h", MessagePack.binary(Data(repeating: 1, count: 32))),
        ("r", MessagePack.binary(Data(repeating: 2, count: 4))), ("o", MessagePack.binary(Data(repeating: 3, count: 32))),
        ("i", MessagePack.unsigned(1)), ("l", MessagePack.unsigned(1)),
        ("q", MessagePack.null), ("f", MessagePack.unsigned(0x21)), ("m", MessagePack.binary(Data()))
    ])
    let advertisement = try ReticulumResourceAdvertisement(encoded: forged)
    #expect(throws: ResourceError.self) { try ReticulumResourceManifest(advertisement: advertisement) }
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

@Test func largeResourceRequestsNextHashMapAtPartialWindowBoundary() throws {
    let data = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0) })
    let randomHash = Data([0x10, 0x20, 0x30, 0x40])
    let manifest = try ReticulumResourceManifest(data: data, randomHash: randomHash)
    #expect(manifest.partCount > ReticulumResourceAdvertisement.hashMapMaximumEntries)
    let wireAdvertisement = ReticulumResourceAdvertisement(manifest: manifest).encode()
    let advertised = try ReticulumResourceAdvertisement(encoded: wireAdvertisement)
    var receiver = ReticulumResourceReceiver(manifest: try ReticulumResourceManifest(advertisement: advertised))
    let parts = stride(from: 0, to: data.count, by: ReticulumResourceManifest.defaultSDU).map {
        data.subdata(in: $0..<min($0 + ReticulumResourceManifest.defaultSDU, data.count))
    }

    for index in 0..<ReticulumResourceAdvertisement.hashMapMaximumEntries {
        try receiver.accept(part: parts[index], at: index)
    }
    #expect(receiver.receivedPartCount == 82)
    #expect(receiver.missingPartIndices.isEmpty)
    #expect(receiver.needsMoreHashMap)
    let mapRequest = try receiver.nextRequest()
    #expect(mapRequest.wantsMoreHashMap)
    #expect(mapRequest.requestedPartHashes.isEmpty)

    try receiver.applyHashMap(segment: 1, hashes: Array(manifest.partHashes.dropFirst(82)))
    let nextParts = try receiver.nextRequest()
    #expect(!nextParts.wantsMoreHashMap)
    #expect(nextParts.requestedPartHashes.count == 4)
}

@Test func hdlcMatchesReticulumEscapingAndStreams() {
    let payload = Data([0x01, HDLC.flag, 0x02, HDLC.escape, 0x03])
    #expect(HDLC.frame(payload) == Data([0x7e, 0x01, 0x7d, 0x5e, 0x02, 0x7d, 0x5d, 0x03, 0x7e]))
    var decoder = HDLCDecoder()
    #expect(decoder.consume(Data([0x7e, 0x01, 0x7d])).isEmpty)
    #expect(decoder.consume(Data([0x5e, 0x7e])).first == Data([0x01, 0x7e]))
}

@Test func tcpPoolReconnectBackoffIsBounded() {
    #expect(ReticulumTCPInterfacePool.reconnectDelay(attempt: 1) == 2)
    #expect(ReticulumTCPInterfacePool.reconnectDelay(attempt: 2) == 4)
    #expect(ReticulumTCPInterfacePool.reconnectDelay(attempt: 5) == 32)
    #expect(ReticulumTCPInterfacePool.reconnectDelay(attempt: 6) == 32)
    #expect(ReticulumTCPInterfacePool.reconnectDelay(attempt: 100) == 32)
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

@Test func buildsValidReticulumPathResponseAnnounce() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let raw = try ReticulumAnnounceBuilder.packet(
        identity: identity,
        destinationName: "lxmf.delivery",
        appData: ReticulumAnnounceBuilder.lxmfAppData(displayName: "Sideband Swift"),
        randomHash: Data(0..<10),
        context: 0x0B
    )
    let packet = try ReticulumPacket(raw: raw)
    #expect(packet.packetType == .announce)
    #expect(packet.context == 0x0B)
    #expect(try ReticulumAnnounce(packet: packet).validate())
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
    let decoded = try #require(ReticulumPathRequest.decode(parsed))
    #expect(decoded.targetHash == target)
    #expect(decoded.tag == tag)
}

@Test func transportOriginatedPathRequestDecodesTrailingTag() throws {
    let target = Data(0..<16)
    let requestingTransport = Data(32..<48)
    let tag = Data(16..<32)
    let raw = Data([0x08, 0x00])
        + ReticulumPathRequest.destinationHash
        + Data([0x00])
        + target
        + requestingTransport
        + tag
    let decoded = try #require(ReticulumPathRequest.decode(ReticulumPacket(raw: raw)))
    #expect(decoded.targetHash == target)
    #expect(decoded.tag == tag)
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

@Test func requestedPathCanReplaceAStaleLowerHopRoute() async throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let directPacket = try ReticulumPacket(raw: raw)
    let announce = try ReticulumAnnounce(packet: directPacket)
    let table = ReticulumPathTable(lifetime: 60)
    #expect(await table.ingest(announce, packet: directPacket))

    var routedRaw = try directPacket.routed(via: Data(repeating: 0x44, count: 16))
    routedRaw[routedRaw.startIndex + 1] = 7
    let routedPacket = try ReticulumPacket(raw: routedRaw)
    #expect(!(await table.ingest(announce, packet: routedPacket)))
    #expect(await table.path(to: announce.destinationHash)?.hops == 0)

    await table.markRequested(announce.destinationHash)
    #expect(await table.ingest(announce, packet: routedPacket))
    #expect(await table.path(to: announce.destinationHash)?.hops == 7)
    #expect(await table.path(to: announce.destinationHash)?.nextHop == Data(repeating: 0x44, count: 16))
}

@Test func pathTableKeepsIndependentRoutesForConcurrentInterfaces() async throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let directPacket = try ReticulumPacket(raw: raw)
    let announce = try ReticulumAnnounce(packet: directPacket)
    var routedRaw = try directPacket.routed(via: Data(repeating: 0x55, count: 16))
    routedRaw[routedRaw.startIndex + 1] = 3
    let routedPacket = try ReticulumPacket(raw: routedRaw)
    let table = ReticulumPathTable(lifetime: 60)

    #expect(await table.ingest(announce, packet: directPacket, interfaceID: "sydney"))
    #expect(await table.ingest(announce, packet: routedPacket, interfaceID: "europe"))
    #expect(await table.path(to: announce.destinationHash, on: "sydney")?.hops == 0)
    #expect(await table.path(to: announce.destinationHash, on: "europe")?.hops == 3)
    #expect(await table.path(to: announce.destinationHash, on: "europe")?.nextHop == Data(repeating: 0x55, count: 16))
    #expect(await table.all().count == 2)
}

@Test func invalidatingPathRemovesFailedRoute() async throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let packet = try ReticulumPacket(raw: raw)
    let announce = try ReticulumAnnounce(packet: packet)
    let table = ReticulumPathTable()
    #expect(await table.ingest(announce, packet: packet))

    await table.invalidate(announce.destinationHash)

    #expect(await table.path(to: announce.destinationHash) == nil)
}

@Test func removingDisconnectedInterfacePathsPreservesLiveSiblingRoutes() async throws {
    let raw = Data(hex: "0100fae321c442e3c9bdcd7a3e79d850e03c008f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd76ec60bc318e2c0f0d90800010203040506070809347836c9e884f6714ddbdf1e58cdafcc3f6e7354301ef80373b1238f9ae1b8ffd550e9a0d12c0478d6c17d29ae71fd0b2c8f39ad0868532ce4fd00e20ef0cf0853776966742050656572")
    let packet = try ReticulumPacket(raw: raw)
    let announce = try ReticulumAnnounce(packet: packet)
    let table = ReticulumPathTable()
    #expect(await table.ingest(announce, packet: packet, interfaceID: "bootstrap-a"))
    #expect(await table.ingest(announce, packet: packet, interfaceID: "public-b"))

    await table.removePaths(on: ["bootstrap-a"])

    #expect(await table.path(to: announce.destinationHash, on: "bootstrap-a") == nil)
    #expect(await table.path(to: announce.destinationHash, on: "public-b") != nil)
    #expect(await table.path(to: announce.destinationHash) != nil)
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

@Test func automaticGatewaySelectionPrefersLastSuccessfulReticulumService() {
    let first = LANGateway(
        name: "Alpha",
        type: "_reticulum._tcp.",
        domain: "local.",
        endpoint: .service(name: "Alpha", type: "_reticulum._tcp", domain: "local", interface: nil)
    )
    let preferred = LANGateway(
        name: "Zulu",
        type: "_sideband._tcp.",
        domain: "local.",
        endpoint: .service(name: "Zulu", type: "_sideband._tcp", domain: "local", interface: nil)
    )
    let ordered = AutomaticGatewaySelector.ordered([first, preferred], preferredID: preferred.id)
    #expect(ordered.map(\.id) == [preferred.id, first.id])
    #expect(AutomaticGatewaySelector.ordered([first, preferred], preferredID: preferred.id, excluding: [preferred.id]).map(\.id) == [first.id])
}

@Test func automaticGatewayFailoverPrefersLANAndRotatesUnreachablePublicGateways() {
    #expect(AutomaticGatewayFailoverPolicy.shouldPreferDiscoveredLAN(
        activeInternetGatewayID: "public.example:4242",
        discoveredGatewayCount: 1
    ))
    #expect(!AutomaticGatewayFailoverPolicy.shouldPreferDiscoveredLAN(
        activeInternetGatewayID: nil,
        discoveredGatewayCount: 1
    ))
    #expect(AutomaticGatewayFailoverPolicy.shouldRotateInternetGateway(
        activeInternetGatewayID: "public.example:4242",
        hasPath: false,
        hasQueuedMessages: true
    ))
    #expect(!AutomaticGatewayFailoverPolicy.shouldRotateInternetGateway(
        activeInternetGatewayID: "public.example:4242",
        hasPath: true,
        hasQueuedMessages: true
    ))
}

@Test func publicGatewaySelectionUsesCustomThenRotatesVerifiedDefaults() {
    let custom = InternetGateway(name: "Configured internet gateway", host: "gateway.example", port: 5_000)
    let ordered = PublicReticulumGateways.ordered(customHost: custom.host, customPort: Int(custom.port), preferredID: nil)
    #expect(ordered.first?.id == custom.id)
    #expect(ordered.count == PublicReticulumGateways.defaults.count + 1)
    #expect(PublicReticulumGateways.defaults.first?.host == "rns.beleth.net")
    #expect(PublicReticulumGateways.defaults.first?.port == 4_242)
    #expect(PublicReticulumGateways.defaults.count >= 5)

    let preferred = PublicReticulumGateways.defaults[2]
    let preferredOrder = PublicReticulumGateways.ordered(customHost: nil, customPort: 4_242, preferredID: preferred.id)
    #expect(preferredOrder.first?.id == preferred.id)
    #expect(PublicReticulumGateways.ordered(customHost: nil, customPort: 4_242, preferredID: preferred.id, excluding: [preferred.id]).allSatisfy { $0.id != preferred.id })
}

@Test func configuredGatewaySelectionPrefersIPv6ThenFallsBackToIPv4() {
    let ordered = ConfiguredReticulumGateways.ordered(
        ipv4Host: " 10.20.20.133 ",
        ipv6Host: " fd20:20:20::133 ",
        port: 4_242,
        preferIPv6: true,
        supportsIPv6: true
    )
    #expect(ordered.map(\.host) == ["fd20:20:20::133", "10.20.20.133"])
    #expect(ConfiguredReticulumGateways.ordered(
        ipv4Host: "10.20.20.133",
        ipv6Host: "fd20:20:20::133",
        port: 4_242,
        preferIPv6: true,
        supportsIPv6: true,
        excluding: [ordered[0].id]
    ).map(\.host) == ["10.20.20.133"])
}

@Test func configuredGatewaySelectionIgnoresEmptyHostsAndInvalidPorts() {
    #expect(ConfiguredReticulumGateways.ordered(
        ipv4Host: "  ",
        ipv6Host: "",
        port: 4_242,
        preferIPv6: true,
        supportsIPv6: true
    ).isEmpty)
    #expect(ConfiguredReticulumGateways.ordered(
        ipv4Host: "localhost",
        ipv6Host: "::1",
        port: 70_000,
        preferIPv6: true,
        supportsIPv6: true
    ).isEmpty)
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

@Test func routedLinkRequestMatchesReticulumTransportHeader() throws {
    let destination = Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c")
    let transportID = Data(hex: "9341153646d8038181a09e85bc5d2971")
    let request = try ReticulumLinkRequest(destinationHash: destination, keyAgreementPrivateKey: Data(0..<32), signingPrivateKey: Data(32..<64))
    let normal = try ReticulumPacket(raw: request.rawPacket)
    let routed = try ReticulumPacket(raw: normal.routed(via: transportID))
    #expect(routed.raw.prefix(2).hex == "5200")
    #expect(routed.headerType == .transport)
    #expect(routed.transportType == 1)
    #expect(routed.transportID == transportID)
    #expect(routed.destinationHash == destination)
    #expect(routed.hashablePart == normal.hashablePart)
    #expect(routed.packetHash == normal.packetHash)
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

@MainActor @Test func directLinkIdentificationBindsMessagingIdentity() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let session = ReticulumLinkSession(
        linkID: Data(hex: "c85013b4b47e0f4e804b72ebd0641407"),
        destinationHash: Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c"),
        peerPublicKey: Data(hex: "79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a"),
        derivedKey: Data(hex: "09e497207060e1f86c5af8e6799238216b85aeb5b6ee7111cdfc247f88fa5047dda46186f4847c9730b6001d080f6cfd163b0fadb84752cb3139abdc15ee1c16"),
        mtu: 500
    )

    let payload = try SidebandStore.linkIdentificationPayload(session: session, identity: identity)

    #expect(payload.count == 128)
    #expect(Data(payload.prefix(64)) == identity.publicKey)
    #expect(identity.validate(
        signature: Data(payload.suffix(64)),
        message: session.linkID + identity.publicKey
    ))
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

@Test func lxmfRetryKeepsStableMessageIdentity() throws {
    let identity = try ReticulumIdentity(privateKey: Data(repeating: 0x31, count: 64))
    let destination = Data(hex: "cf0b2a4a8d2a0b6978b71290da7cc80e")
    let source = Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c")
    let timestamp = 1_700_000_000.25
    let first = try LXMFMessage(destinationHash: destination, sourceHash: source, sourceIdentity: identity, timestamp: timestamp, content: Data("retry me".utf8))
    let retry = try LXMFMessage(destinationHash: destination, sourceHash: source, sourceIdentity: identity, timestamp: timestamp, content: Data("retry me".utf8))
    let differentMessage = try LXMFMessage(destinationHash: destination, sourceHash: source, sourceIdentity: identity, timestamp: timestamp + 1, content: Data("retry me".utf8))
    #expect(first.messageID == retry.messageID)
    #expect(first.messageID != differentMessage.messageID)
}

@Test func lxmfTelemetryFieldRoundTripsAndRemainsSigned() throws {
    let identity = try ReticulumIdentity(privateKey: Data(0..<64))
    let telemetry = SidebandTelemetry(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), location: .init(latitude: -37.8136, longitude: 144.9631, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    let outgoing = try LXMFMessage(
        destinationHash: Data(hex: "cf0b2a4a8d2a0b6978b71290da7cc80e"),
        sourceHash: Data(hex: "fae321c442e3c9bdcd7a3e79d850e03c"),
        sourceIdentity: identity,
        timestamp: 1_700_000_000,
        content: Data("position".utf8),
        fields: [0x02: telemetry.packed()]
    )
    let incoming = try LXMFReceivedMessage(packed: outgoing.packed)
    #expect(incoming.validate(with: identity))
    #expect(incoming.binaryField(0x02) == telemetry.packed())
    #expect(try SidebandTelemetry(packed: incoming.binaryField(0x02)!) == telemetry)
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

@Test func propagationAnnouncesAreRecognizedCryptographically() throws {
    let identity = ReticulumIdentity()
    let raw = try ReticulumAnnounceBuilder.packet(
        identity: identity,
        destinationName: "lxmf.propagation",
        appData: MessagePack.array([MessagePack.bool(true)])
    )
    let announce = try ReticulumAnnounce(packet: ReticulumPacket(raw: raw))
    #expect(LXMFPropagation.isPropagationAnnounce(announce))

    let deliveryRaw = try ReticulumAnnounceBuilder.packet(identity: identity, destinationName: "lxmf.delivery")
    let delivery = try ReticulumAnnounce(packet: ReticulumPacket(raw: deliveryRaw))
    #expect(!LXMFPropagation.isPropagationAnnounce(delivery))
}

@Test func decodesLivePropagationResponseShape() throws {
    let value = try MessagePackDecoder.decode(Data(hex: "92c410465325777278df3c52630da81dd6b56f90"))
    guard case let .array(parts) = value, parts.count == 2, case let .array(messages) = parts[1] else { Issue.record("Unexpected response shape"); return }
    #expect(messages.isEmpty)
}

@Test func cloudSnapshotMergeRemapsConversationsAndAdvancesDeliveryState() {
    let destination = "00112233445566778899aabbccddeeff"
    let localConversation = Conversation(destinationHash: destination, displayName: "Local", updatedAt: Date(timeIntervalSince1970: 20))
    let remoteConversation = Conversation(destinationHash: destination, displayName: "Remote", updatedAt: Date(timeIntervalSince1970: 10))
    let messageID = UUID()
    let localMessage = Message(
        id: messageID, conversationID: localConversation.id, body: "hello", timestamp: Date(timeIntervalSince1970: 20),
        direction: .outgoing, state: .queued, outboxOwnerID: "phone", outboxOwnerUpdatedAt: Date(timeIntervalSince1970: 20)
    )
    let remoteMessage = Message(
        id: messageID, conversationID: remoteConversation.id, body: "hello", timestamp: Date(timeIntervalSince1970: 20),
        direction: .outgoing, state: .delivered, outboxOwnerID: "ipad", outboxOwnerUpdatedAt: Date(timeIntervalSince1970: 30)
    )
    let merged = AppSnapshot(
        conversations: [localConversation], messages: [localMessage], drafts: [localConversation.id: "local draft"]
    ).mergingCloudSnapshot(AppSnapshot(
        conversations: [remoteConversation], messages: [remoteMessage], drafts: [remoteConversation.id: "remote draft"]
    ))

    #expect(merged.conversations.count == 1)
    #expect(merged.conversations[0].id == remoteConversation.id)
    #expect(merged.conversations[0].displayName == "Local")
    #expect(merged.messages.count == 1)
    #expect(merged.messages[0].conversationID == remoteConversation.id)
    #expect(merged.messages[0].state == .delivered)
    #expect(merged.messages[0].outboxOwnerID == "ipad")
    #expect(merged.drafts[remoteConversation.id] == "local draft")
}

@Test func cloudSnapshotMergePreservesLXMFReplyReferences() throws {
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let lxmfID = Data(repeating: 0x41, count: 32)
    let replyTo = Data(repeating: 0x42, count: 32)
    let message = Message(
        conversationID: conversation.id,
        body: "Reply",
        direction: .outgoing,
        state: .sent,
        renderer: .markdown,
        lxmfID: lxmfID,
        replyTo: replyTo,
        replyQuote: "Original"
    )
    let merged = AppSnapshot().mergingCloudSnapshot(AppSnapshot(conversations: [conversation], messages: [message]))
    let result = try #require(merged.messages.first)

    #expect(result.lxmfID == lxmfID)
    #expect(result.replyTo == replyTo)
    #expect(result.replyQuote == "Original")
    #expect(result.renderer == .markdown)
}

@Test func cloudSnapshotMergeKeepsRoutingDiscoveriesDeviceLocal() {
    let localDiscovery = DiscoveredDestination(destinationHash: "00112233445566778899aabbccddeeff", hops: 1)
    let remoteDiscovery = DiscoveredDestination(destinationHash: "ffeeddccbbaa99887766554433221100", hops: 2)
    let merged = AppSnapshot(discoveries: [localDiscovery])
        .mergingCloudSnapshot(AppSnapshot(discoveries: [remoteDiscovery]))

    #expect(merged.discoveries == [localDiscovery])
}

@Test func cloudPayloadEncryptionRoundTripsWithoutExposingPlaintext() throws {
    struct Secret: Codable, Equatable { let message: String; let count: Int }
    let cipher = CloudPayloadCipher(keyMaterial: Data(repeating: 0x42, count: 64))
    let secret = Secret(message: "private conversation text", count: 7)

    let ciphertext = try cipher.seal(secret, context: "snapshot-v1")
    let opened = try cipher.open(Secret.self, ciphertext: ciphertext, context: "snapshot-v1")

    #expect(opened == secret)
    #expect(!ciphertext.contains(Data(secret.message.utf8)))
}

@Test func cloudPayloadEncryptionRejectsTamperingAndWrongContext() throws {
    struct Secret: Codable { let message: String }
    let cipher = CloudPayloadCipher(keyMaterial: Data(repeating: 0x24, count: 64))
    let ciphertext = try cipher.seal(Secret(message: "authenticated"), context: "snapshot-v1")
    var tampered = ciphertext
    tampered[tampered.index(before: tampered.endIndex)] ^= 0x01

    var tamperRejected = false
    do { _ = try cipher.open(Secret.self, ciphertext: tampered, context: "snapshot-v1") }
    catch { tamperRejected = true }
    #expect(tamperRejected)

    var wrongContextRejected = false
    do { _ = try cipher.open(Secret.self, ciphertext: ciphertext, context: "attachment-v1") }
    catch { wrongContextRejected = true }
    #expect(wrongContextRejected)
}

@Test func cloudRecordNamesAreOpaqueAndDomainSeparated() throws {
    let cipher = CloudPayloadCipher(keyMaterial: Data(repeating: 0x5a, count: 64))
    let attachmentID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let attachmentScope = "attachment-v1:\(attachmentID.uuidString.lowercased())"
    let first = try cipher.recordName(for: attachmentScope)
    let same = try cipher.recordName(for: attachmentScope)
    let snapshot = try cipher.recordName(for: "snapshot-v1")

    #expect(first == same)
    #expect(first != snapshot)
    #expect(!first.contains(attachmentID.uuidString.lowercased()))
    #expect(first.count == 64)
}

@Test func decodesAuthenticatedReticulumInterfaceDiscoveryFixture() {
    let appData = Data(hex: "008900b14261636b626f6e65496e7465726661636501c3ccfec41000112233445566778899aabbccddeeffccffaf5379646e6579204261636b626f6e6503cbc040ef34d6a161e504cb4062e6b295e9e1b105cb404500000000000002af726e732e6578616d706c652e6e657406cd10929fbbbec43a8031ce376d1afbf43ad843726731ee7623c9f32a6217a9252c7059")
    let networkID = Data(hex: "ffeeddccbbaa99887766554433221100")
    let seen = Date(timeIntervalSince1970: 1_700_000_000)

    let discovered = ReticulumInterfaceDiscovery.decode(appData: appData, networkID: networkID, hops: 2, now: seen)

    #expect(discovered?.name == "Sydney Backbone")
    #expect(discovered?.host == "rns.example.net")
    #expect(discovered?.port == 4_242)
    #expect(discovered?.transportID == Data(hex: "00112233445566778899aabbccddeeff"))
    #expect(discovered?.networkID == networkID)
    #expect(discovered?.hops == 2)
    #expect(discovered?.stampValue == 14)
    #expect(discovered?.lastSeen == seen)
}

@Test func rejectsTamperedReticulumInterfaceDiscoveryStamp() {
    var appData = Data(hex: "008900b14261636b626f6e65496e7465726661636501c3ccfec41000112233445566778899aabbccddeeffccffaf5379646e6579204261636b626f6e6503cbc040ef34d6a161e504cb4062e6b295e9e1b105cb404500000000000002af726e732e6578616d706c652e6e657406cd10929fbbbec43a8031ce376d1afbf43ad843726731ee7623c9f32a6217a9252c7059")
    appData[appData.index(before: appData.endIndex)] ^= 0x01

    #expect(ReticulumInterfaceDiscovery.decode(
        appData: appData,
        networkID: Data(hex: "ffeeddccbbaa99887766554433221100"),
        hops: 1
    ) == nil)
}

@Test func automaticInterfaceDiscoveryRejectsLocalAndSpecialUseHosts() {
    #expect(ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("rns.beleth.net"))
    #expect(ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("202.61.243.41"))
    #expect(ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("2603:c020:401f:d7af::a1"))
    #expect(!ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("127.0.0.1"))
    #expect(!ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("10.20.20.133"))
    #expect(!ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("192.168.1.10"))
    #expect(!ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("fd20:20:20::133"))
    #expect(!ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("fe80::1%en0"))
    #expect(!ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost("gateway.local"))
}

@MainActor @Test func bulkConversationOrganizationIsSafeAndPersists() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let pinned = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Pinned", isPinned: true)
    let unread = Conversation(destinationHash: "1123456789abcdef0123456789abcdef", displayName: "Unread", unreadCount: 3)
    let read = Conversation(destinationHash: "2123456789abcdef0123456789abcdef", displayName: "Read")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(AppSnapshot(conversations: [pinned, unread, read])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(store.markAllConversationsRead() == 1)
    #expect(store.totalUnreadCount == 0)
    #expect(store.archiveReadConversations() == 2)
    #expect(store.conversations.first(where: { $0.id == pinned.id })?.isArchived == false)
    #expect(store.unarchiveAllConversations() == 2)
    let reloaded = SidebandStore(persistenceURL: url)
    #expect(!reloaded.conversations.contains { $0.isArchived })
}

@MainActor @Test func conversationSearchIncludesPrivateNotesMessagesQuotesAndAttachments() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(
        destinationHash: "0123456789abcdef0123456789abcdef",
        displayName: "Station",
        contactNote: "Emergency coordinator"
    )
    let attachment = Attachment(filename: "field-map.png", byteCount: 4, relativePath: "field-map.png", state: .available)
    let message = Message(conversationID: conversation.id, body: "Meet at checkpoint", direction: .incoming, state: .delivered, attachments: [attachment], replyQuote: "Original schedule")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(store.conversationMatchesSearch(conversation.id, query: "coordinator"))
    #expect(store.conversationMatchesSearch(conversation.id, query: "checkpoint"))
    #expect(store.conversationMatchesSearch(conversation.id, query: "schedule"))
    #expect(store.conversationMatchesSearch(conversation.id, query: "field-map"))
    #expect(!store.conversationMatchesSearch(conversation.id, query: "unrelated"))
}

@Test func attachmentStoreSanitizesNamesAndNormalizesMIMETypes() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = AttachmentStore(directory: directory)
    let attachment = try await store.save(data: Data("image".utf8), filename: "../unsafe\nphoto.png", mimeType: " IMAGE/PNG ")

    #expect(!attachment.filename.contains("/"))
    #expect(!attachment.filename.contains("\n"))
    #expect(attachment.mimeType == "image/png")
    #expect(try await store.read(attachment) == Data("image".utf8))
}

@Test func attachmentStoreConfinesUntrustedRelativePaths() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let directory = root.appending(path: "attachments")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let outside = root.appending(path: "outside.bin")
    let data = Data("secret".utf8)
    try data.write(to: outside)
    let attachment = Attachment(
        filename: "outside.bin", byteCount: data.count, relativePath: "../outside.bin", state: .available,
        contentHash: Data(SHA256.hash(data: data))
    )
    let store = AttachmentStore(directory: directory)

    await #expect(throws: (any Error).self) { try await store.read(attachment) }
}

@MainActor @Test func attachmentAuditMarksMissingPayloadsFailed() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let attachment = Attachment(filename: "missing.pdf", byteCount: 20, relativePath: "missing.pdf", state: .local)
    let message = Message(conversationID: conversation.id, body: "", direction: .outgoing, state: .queued, attachments: [attachment])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(AppSnapshot(conversations: [conversation], messages: [message])).write(to: url)
    let store = SidebandStore(persistenceURL: url)

    #expect(await store.validateAttachmentStorage() == 1)
    #expect(store.messages[0].attachments[0].state == .failed)
    #expect(store.messages[0].state == .failed)
}

@MainActor @Test func sendReportsWhetherMessageWasAcceptedIntoOutbox() async {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(!(await store.send("no selected contact")))
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    #expect(await store.send("accepted"))
    #expect(store.messages.last?.body == "accepted")
}

@MainActor @Test func unchangedSnapshotsDoNotRewriteEncryptedPersistence() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json")
    let store = SidebandStore(persistenceURL: url)
    #expect(store.addConversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer"))
    let id = try #require(store.conversations.first?.id)
    store.setConversationTrusted(false, conversationID: id) // Creates the rolling backup.
    let before = try Data(contentsOf: url)
    store.setConversationTrusted(false, conversationID: id)
    let after = try Data(contentsOf: url)

    #expect(after == before)
}

@MainActor @Test func snapshotValidationRejectsOversizedMessageAndUnsafeAttachmentMetadata() throws {
    let store = SidebandStore(persistenceURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let oversized = Message(conversationID: conversation.id, body: String(repeating: "x", count: SidebandMessageLimits.maximumTextCharacters + 1), direction: .incoming, state: .delivered)
    let unsafe = Attachment(filename: "payload.bin", byteCount: 1, relativePath: "../payload.bin", state: .available, progress: 2)
    let attachmentMessage = Message(conversationID: conversation.id, body: "", direction: .incoming, state: .delivered, attachments: [unsafe])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let oversizedData = try encoder.encode(AppSnapshot(conversations: [conversation], messages: [oversized]))
    let unsafeData = try encoder.encode(AppSnapshot(conversations: [conversation], messages: [attachmentMessage]))
    #expect(throws: SnapshotError.self) { try store.validatedSnapshot(from: oversizedData) }
    #expect(throws: SnapshotError.self) { try store.validatedSnapshot(from: unsafeData) }
}

@Test func cloudMergePreservesCallHistoryAcrossDevices() {
    let conversation = Conversation(destinationHash: "0123456789abcdef0123456789abcdef", displayName: "Peer")
    let remoteCall = VoiceCall(conversationID: conversation.id, direction: .incoming, state: .idle, endedAt: .now)
    let localCall = VoiceCall(conversationID: conversation.id, direction: .outgoing, state: .failed, endedAt: .now, failureReason: "No route")
    let local = AppSnapshot(conversations: [conversation], voiceCallHistory: [localCall])
    let remote = AppSnapshot(conversations: [conversation], voiceCallHistory: [remoteCall])

    let merged = local.mergingCloudSnapshot(remote)
    #expect(Set(merged.voiceCallHistory.map(\.id)) == Set([localCall.id, remoteCall.id]))
}

@Test func safetyReportRequiresUserSendAndOmitsPrivateContent() throws {
    let conversation = Conversation(
        destinationHash: "0123456789abcdef0123456789abcdef",
        displayName: "Private display name",
        contactNote: "private contact note"
    )
    let message = Message(
        conversationID: conversation.id,
        body: "private message body",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        direction: .incoming,
        state: .delivered,
        attachments: [Attachment(filename: "secret.jpg", byteCount: 1, relativePath: "secret.jpg", state: .available)],
        lxmfID: Data([0x01, 0x02, 0x03])
    )

    let url = try #require(SidebandSafetyReport.emailURL(for: conversation, message: message))
    let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
    #expect(url.scheme == "mailto")
    #expect(decoded.contains(SidebandSafetyReport.supportEmail))
    #expect(decoded.contains(conversation.destinationHash))
    #expect(decoded.contains("010203"))
    #expect(!decoded.contains(message.body))
    #expect(!decoded.contains("secret.jpg"))
    #expect(!decoded.contains(conversation.displayName))
    #expect(!decoded.contains(conversation.contactNote))
}

@Test func ifacMatchesPythonReticulumReferenceAndRejectsTampering() throws {
    let ifac = try ReticulumIFAC(networkName: "Lower Sideband", passphrase: "test passphrase", size: 8)
    #expect(ifac.key.hex == "98fd583893582503381cd15e373bdd44980014d40a56c5930851452504b2b7eaf8b94289efb677c5f48e37541a9de8dc025a40acb2cf805022fb64b4914c7723")
    let raw = Data(hex: "0000102030405060708090a0b0c0d0e0f00102030405")
    let protected = try ifac.protect(raw)
    #expect(protected.hex == "cb6758c963ab7568ca0a5a6049471c35cbb8e9c978263c27411c51902d8d")
    #expect(try ifac.unprotect(protected) == raw)

    var tampered = protected
    tampered[tampered.count - 1] ^= 1
    #expect(throws: ReticulumIFAC.IFACError.authenticationFailed) { try ifac.unprotect(tampered) }
}

@Test func genericKISSModemSupportsPortsCommandsEscapingAndChunking() {
    let payload = Data([0x01, KISSModem.frameEnd, 0x02, KISSModem.frameEscape, 0x03])
    let encoded = KISSModem.frame(port: 7, command: .data, payload: payload)
    var decoder = KISSModemDecoder()
    var frames: [KISSModemFrame] = []
    for byte in encoded { frames.append(contentsOf: decoder.consume(Data([byte]))) }
    #expect(frames == [.init(port: 7, command: .data, payload: payload)])

    let command = KISSModem.frame(port: 2, command: .persistence, payload: Data([63]))
    #expect(decoder.consume(command) == [.init(port: 2, command: .persistence, payload: Data([63]))])
}

@Test func interfaceModesAndKISSConfigurationMatchReticulumSemantics() throws {
    #expect(ReticulumInterfaceMode.full.rawValue == 0x01)
    #expect(ReticulumInterfaceMode.gateway.rawValue == 0x06)
    #expect(ReticulumInterfaceMode.internalMode.rawValue == 0x07)
    var configuration = KISSModemConfiguration()
    configuration.serialPath = "/dev/cu.usbmodem-test"
    configuration.interfaceMode = .pointToPoint
    configuration.ifacNetworkName = "mesh"
    configuration.ifacSize = 8
    #expect(try configuration.validated() == configuration)
    configuration.port = 16
    #expect(throws: KISSModemConfiguration.ValidationError.self) { try configuration.validated() }
}

@Test func lxmfVoiceAudioFieldMatchesPythonShapeAndPersists() throws {
    let ogg = OggOpusStream.mux(packets: [Data([0x48, 0x83, 0x01]), Data([0x48, 0x83, 0x02])], frameSamplesAt48k: 2_880, serial: 0x12345678)
    let audio = try LXMFVoiceMessageAudio(mode: .opusOgg, encodedAudio: ogg)
    let decodedValue = try MessagePackDecoder.decode(audio.encodedField)
    guard case let .array(parts) = decodedValue else { Issue.record("Audio field was not an array"); return }
    #expect(parts.count == 2)
    #expect(parts[0] == .unsigned(0x10))
    #expect(parts[1] == .binary(ogg))
    #expect(LXMFVoiceMessageAudio(field: decodedValue) == audio)

    let message = Message(conversationID: UUID(), body: "", direction: .outgoing, state: .queued, voiceAudio: audio)
    let persisted = try JSONEncoder().encode(message)
    #expect(try JSONDecoder().decode(Message.self, from: persisted).voiceAudio == audio)
}

@Test func oggOpusMuxerCreatesChecksummedPagesAndGranules() throws {
    let stream = OggOpusStream.mux(packets: [Data(repeating: 0xAB, count: 300)], frameSamplesAt48k: 2_880, serial: 7)
    #expect(OggOpusStream.isOggOpus(stream))
    var offset = 0
    var pages = 0
    while offset < stream.count {
        #expect(stream.subdata(in: offset..<(offset + 4)) == Data("OggS".utf8))
        let segmentCount = Int(stream[offset + 26])
        let lacing = stream.subdata(in: (offset + 27)..<(offset + 27 + segmentCount))
        let length = 27 + segmentCount + lacing.reduce(0) { $0 + Int($1) }
        var page = stream.subdata(in: offset..<(offset + length))
        let stored = UInt32(page[22]) | UInt32(page[23]) << 8 | UInt32(page[24]) << 16 | UInt32(page[25]) << 24
        page.replaceSubrange(22..<26, with: repeatElement(UInt8(0), count: 4))
        #expect(OggOpusStream.crc(page) == stored)
        pages += 1; offset += length
    }
    #expect(pages == 3)
}

@Test func legacyPythonSQLiteDatabaseImportsReadOnly() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "sideband-legacy-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: url) }
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    guard let database else { return }
    let sql = """
    CREATE TABLE conv (dest_context BLOB PRIMARY KEY, last_tx INTEGER, last_rx INTEGER, unread INTEGER, type INTEGER, trust INTEGER, name BLOB, data BLOB);
    CREATE TABLE lxm (lxm_hash BLOB PRIMARY KEY, dest BLOB, source BLOB, title BLOB, tx_ts INTEGER, rx_ts INTEGER, state INTEGER, method INTEGER, t_encrypted INTEGER, t_encryption INTEGER, data BLOB, extra BLOB);
    INSERT INTO conv VALUES (x'00112233445566778899aabbccddeeff',10,20,1,0,1,x'4c65676163792050656572',NULL);
    INSERT INTO lxm VALUES (x'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',x'ffffffffffffffffffffffffffffffff',x'00112233445566778899aabbccddeeff',x'',0,21,4,0,0,0,x'68656c6c6f206c6567616379',NULL);
    """
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let before = try Data(contentsOf: url)
    let report = try LegacySidebandSQLiteImporter.load(from: url)
    #expect(report.snapshot.conversations.count == 1)
    #expect(report.snapshot.conversations[0].displayName == "Legacy Peer")
    #expect(report.snapshot.conversations[0].isTrusted)
    #expect(report.snapshot.messages.count == 1)
    #expect(report.snapshot.messages[0].body == "hello legacy")
    #expect(report.snapshot.messages[0].direction == .incoming)
    #expect(try Data(contentsOf: url) == before)
}

@Test func chunkedRNodeFlasherWritesInOrderAndVerifiesDigest() async throws {
    let image = Data((0..<2_500).map { UInt8($0 % 251) })
    let package = RNodeFirmwarePackage(version: "1.0", platform: 1, trustedImage: image)
    let transport = TestBootloaderTransport()
    let flasher = try RNodeChunkedFirmwareFlasher(transport: transport, chunkSize: 512)
    let progress = TestProgressRecorder()
    try await flasher.flash(package) { value in await progress.add(value) }
    #expect(await transport.image() == image)
    let values = await progress.values()
    #expect(values.first == 0 && values.last == 1)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
}

private actor TestBootloaderTransport: RNodeBootloaderTransport {
    private var bytes = Data(); private var digest = Data()
    func begin(imageBytes: Int, sha256: Data) { bytes.removeAll(keepingCapacity: true); digest = sha256 }
    func write(offset: Int, bytes value: Data) throws {
        guard offset == bytes.count else { throw RNodeChunkedFirmwareFlasher.Error.verificationFailed }
        bytes.append(value)
    }
    func finish() -> Data { Data(SHA256.hash(data: bytes)) }
    func cancel() {}
    func image() -> Data { bytes }
}

private actor TestProgressRecorder {
    private var recorded: [Double] = []
    func add(_ value: Double) { recorded.append(value) }
    func values() -> [Double] { recorded }
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
