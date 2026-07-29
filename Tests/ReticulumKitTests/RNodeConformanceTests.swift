import Foundation
import Network
import Testing
@testable import ReticulumKit

@Suite("RNode firmware protocol conformance")
struct RNodeConformanceTests {
    @Test("Command bytes match official RNode Firmware Framing.h")
    func officialCommandBytes() {
        let expected: [RNodeKISS.Command: UInt8] = [
            .data: 0x00, .frequency: 0x01, .bandwidth: 0x02, .txPower: 0x03,
            .spreadingFactor: 0x04, .codingRate: 0x05, .radioState: 0x06,
            .radioLock: 0x07, .detect: 0x08, .implicit: 0x09, .leave: 0x0A,
            .shortTermAirtimeLock: 0x0B, .longTermAirtimeLock: 0x0C,
            .promiscuous: 0x0E, .ready: 0x0F, .receivedBytes: 0x21,
            .transmittedBytes: 0x22, .rssi: 0x23, .snr: 0x24,
            .channelMetrics: 0x25, .physicalMetrics: 0x26, .battery: 0x27,
            .csma: 0x28, .temperature: 0x29, .blink: 0x30, .random: 0x40,
            .externalFramebuffer: 0x41, .framebufferRead: 0x42,
            .framebufferWrite: 0x43, .framebufferReadLine: 0x44,
            .displayIntensity: 0x45, .bluetoothControl: 0x46, .board: 0x47,
            .platform: 0x48, .mcu: 0x49, .firmwareVersion: 0x50,
            .romRead: 0x51, .romWrite: 0x52, .configurationSave: 0x53,
            .configurationDelete: 0x54, .reset: 0x55, .deviceHash: 0x56,
            .deviceSignature: 0x57, .firmwareHash: 0x58, .romUnlock: 0x59,
            .hashes: 0x60, .firmwareUpdate: 0x61, .bluetoothPIN: 0x62,
            .displayAddress: 0x63, .displayBlank: 0x64, .neopixelIntensity: 0x65,
            .displayRead: 0x66, .displayRotation: 0x67,
            .displayRecondition: 0x68, .displayInterfaceAccess: 0x69,
            .wifiMode: 0x6A, .wifiSSID: 0x6B, .wifiPSK: 0x6C,
            .configurationRead: 0x6D, .wifiChannel: 0x6E,
            .bluetoothUnpair: 0x70, .selectInterface: 0x1F, .interfaces: 0x71,
            .log: 0x80, .time: 0x81,
            .muxChain: 0x82, .muxDiscover: 0x83, .wifiIP: 0x84,
            .wifiNetmask: 0x85, .error: 0x90, .unknown: 0xFE
        ]

        #expect(expected.count == RNodeKISS.Command.allCases.count)
        for command in RNodeKISS.Command.allCases {
            #expect(command.rawValue == expected[command])
        }
    }

    @Test("RNodeMulti selects and independently routes all virtual ports")
    func multiVirtualPortRouting() throws {
        var engine = RNodeMultiProtocolEngine()
        let escaped = Data([0x01, 0xC0, 0xDB, 0x02])
        var stream = Data()
        for port in UInt8(0)..<RNodeMultiConfiguration.maximumVirtualPorts {
            stream += RNodeKISS.frame(command: .selectInterface, payload: Data([port]))
            stream += RNodeKISS.frame(command: .data, payload: escaped + Data([port]))
        }
        let events = engine.consume(stream)
        let packets = events.compactMap { event -> (UInt8, Data)? in
            if case let .packet(port, data) = event { return (port, data) }
            return nil
        }
        #expect(packets.count == Int(RNodeMultiConfiguration.maximumVirtualPorts))
        for (index, packet) in packets.enumerated() {
            #expect(packet.0 == UInt8(index))
            #expect(packet.1 == escaped + Data([UInt8(index)]))
        }

        let outbound = try engine.packetFrame(Data([0xC0, 0xDB]), port: 7)
        var decoder = RNodeRawKISSDecoder()
        let frames = decoder.consume(outbound)
        #expect(frames == [
            RNodeRawKISSFrame(command: RNodeKISS.Command.selectInterface.rawValue, payload: Data([7])),
            RNodeRawKISSFrame(command: RNodeKISS.Command.data.rawValue, payload: Data([0xC0, 0xDB]))
        ])
    }

    @Test("KISS escaping round-trips every byte with arbitrary TCP chunking")
    func exhaustiveFramingRoundTrip() {
        let payload = Data((0...255).map(UInt8.init)) + Data((0...255).reversed().map { UInt8($0) })
        let encoded = RNodeKISS.frame(command: .data, payload: payload)

        for chunkSize in 1...97 {
            var decoder = RNodeKISSDecoder()
            var frames: [RNodeKISSFrame] = []
            var offset = 0
            while offset < encoded.count {
                let end = min(encoded.count, offset + chunkSize)
                frames += decoder.consume(encoded.subdata(in: offset..<end))
                offset = end
            }
            #expect(frames == [RNodeKISSFrame(command: .data, payload: payload)])
        }
    }

    @Test("Official detect and configuration vectors are exact")
    func configurationVectors() {
        let engine = RNodeProtocolEngine()
        let detect = engine.detectionCommands()
        #expect(detect.starts(with: Data([0xC0, 0x08, 0x73, 0xC0])))

        let configuration = RNodeConfiguration(
            transport: .tcp, target: "rnode.local", tcpPort: 7_633,
            frequency: 915_000_000, bandwidth: 125_000, txPower: 17,
            spreadingFactor: 9, codingRate: 6, shortTermAirtimeLimit: 33,
            longTermAirtimeLimit: 1.5
        )
        let commands = engine.configurationCommands(configuration)
        var decoder = RNodeKISSDecoder()
        let frames = decoder.consume(commands)
        #expect(frames.map(\.command) == [
            .frequency, .bandwidth, .txPower, .spreadingFactor, .codingRate,
            .shortTermAirtimeLock, .longTermAirtimeLock, .radioState
        ])
        #expect(frames[0].payload == Data([0x36, 0x89, 0xCA, 0xC0]))
        #expect(frames[1].payload == Data([0x00, 0x01, 0xE8, 0x48]))
        #expect(frames[5].payload == Data([0x0C, 0xE4]))
        #expect(frames[6].payload == Data([0x00, 0x96]))
    }

    @Test("Firmware comparison follows the reference major/minor rule")
    func firmwareVersionCompatibility() {
        #expect(!RNodeProtocolEngine.firmwareIsSupported(major: 0, minor: 255))
        #expect(!RNodeProtocolEngine.firmwareIsSupported(major: 1, minor: 51))
        #expect(RNodeProtocolEngine.firmwareIsSupported(major: 1, minor: 52))
        #expect(RNodeProtocolEngine.firmwareIsSupported(major: 1, minor: 86))
        #expect(RNodeProtocolEngine.firmwareIsSupported(major: 2, minor: 0))
    }

    @Test("All reference radio telemetry is decoded")
    func telemetryDecoding() {
        var engine = RNodeProtocolEngine()
        let stream =
            RNodeKISS.frame(command: .radioLock, payload: Data([1])) +
            RNodeKISS.frame(command: .shortTermAirtimeLock, payload: Data([0x0C, 0xE4])) +
            RNodeKISS.frame(command: .longTermAirtimeLock, payload: Data([0x00, 0x96])) +
            RNodeKISS.frame(command: .physicalMetrics, payload: Data([
                0x00, 0xFA, 0x0F, 0xA0, 0x00, 0x10,
                0x00, 0x04, 0x00, 0x08, 0x00, 0x0C
            ])) +
            RNodeKISS.frame(command: .csma, payload: Data([4, 2, 8])) +
            RNodeKISS.frame(command: .random, payload: Data([0xA5]))
        _ = engine.consume(stream)
        let metrics = engine.metrics
        #expect(metrics.radioLocked == true)
        #expect(metrics.shortTermAirtimeLimit == 33)
        #expect(metrics.longTermAirtimeLimit == 1.5)
        #expect(metrics.symbolTimeMilliseconds == 0.25)
        #expect(metrics.symbolRate == 4_000)
        #expect(metrics.preambleSymbols == 16)
        #expect(metrics.preambleTimeMilliseconds == 4)
        #expect(metrics.csmaSlotTimeMilliseconds == 8)
        #expect(metrics.csmaDIFSMilliseconds == 12)
        #expect(metrics.csmaContentionWindowBand == 4)
        #expect(metrics.csmaContentionWindowMinimum == 2)
        #expect(metrics.csmaContentionWindowMaximum == 8)
        #expect(metrics.randomByte == 0xA5)
    }

    @Test("Hardware MTU is enforced at the exact firmware boundary")
    func hardwareMTU() throws {
        let engine = RNodeProtocolEngine()
        _ = try engine.packetFrame(Data(repeating: 0xA5, count: 508))
        #expect(throws: RNodeError.self) { try engine.packetFrame(Data(repeating: 0xA5, count: 509)) }
    }

    @Test("TCP-sized randomized frames survive deterministic fuzzing")
    func deterministicFramingFuzz() {
        var state: UInt64 = 0x524E_4F44_4554_4350
        func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 24)
        }

        for iteration in 0..<10_000 {
            let length = iteration % 509
            let payload = Data((0..<length).map { _ in next() })
            let encoded = RNodeKISS.frame(command: .data, payload: payload)
            var decoder = RNodeKISSDecoder()
            var decoded: [RNodeKISSFrame] = []
            var offset = 0
            while offset < encoded.count {
                let width = max(1, Int(next()) % 31)
                let end = min(encoded.count, offset + width)
                decoded += decoder.consume(encoded.subdata(in: offset..<end))
                offset = end
            }
            #expect(decoded == [RNodeKISSFrame(command: .data, payload: payload)])
        }
    }
}

@Suite("RNode TCP runtime")
struct RNodeTCPRuntimeTests {
    @Test("Network.framework TCP transport streams bytes bidirectionally")
    func networkFrameworkTransport() async throws {
        let serverBytes = PacketCounter()
        let clientBytes = PacketCounter()
        let states = TransportStateRecorder()
        let server = try LocalTCPFixture { data in await serverBytes.add(data) }
        let port = try await server.start()
        let transport = RNodeTCPTransport(host: "127.0.0.1", port: port)

        await transport.start(
            receive: { data in await clientBytes.add(data) },
            state: { state in await states.add(state) }
        )
        try await waitUntil { await states.containsReady }

        let outbound = RNodeKISS.frame(command: .detect, payload: Data([RNodeProtocolEngine.detectRequest]))
        try await transport.write(outbound)
        try await waitUntil { await serverBytes.combined == outbound }

        let inbound = RNodeKISS.frame(command: .detect, payload: Data([RNodeProtocolEngine.detectResponse]))
        for byte in inbound {
            try await server.send(Data([byte]))
        }
        try await waitUntil { await clientBytes.combined == inbound }

        await transport.stop()
        try await waitUntil { await states.containsStopped }

        await transport.start(
            receive: { data in await clientBytes.add(data) },
            state: { state in await states.add(state) }
        )
        try await waitUntil { await states.readyCount == 2 }
        try await transport.write(outbound)
        try await waitUntil { await serverBytes.combined == outbound + outbound }

        await transport.stop()
        await server.stop()
        #expect(await states.containsStopped)
    }

    @Test("Simulated TCP protocol obeys firmware READY flow control under load", .timeLimit(.minutes(1)))
    func flowControlledSoak() async throws {
        let transport = SimulatedRNodeTransport(
            loopbackPackets: true, responseChunkSize: 1,
            firmware: (1, 86), readyDenials: 3
        )
        let received = PacketCounter()
        let interface = RNodeInterface(
            configuration: RNodeConfiguration(
                name: "TCP soak", transport: .tcp, target: "127.0.0.1",
                frequency: 915_000_000, bandwidth: 125_000
            ),
            transportFactory: { _ in transport },
            packetHandler: { packet in await received.add(packet) }
        )
        await interface.start()
        try await waitUntil { await interface.snapshot().state == .ready }

        for sequence in 0..<2_500 {
            var packet = Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 64 + sequence % 445)
            packet[0] = UInt8(sequence >> 8)
            packet[1] = UInt8(truncatingIfNeeded: sequence)
            try await interface.send(rawPacket: packet)
            if await interface.snapshot().queuedPackets >= 64 {
                try await waitUntil(timeout: .seconds(5)) {
                    await interface.snapshot().queuedPackets < 32
                }
            }
        }

        let receiveDeadline = ContinuousClock.now + .seconds(30)
        while await received.count != 2_500, ContinuousClock.now < receiveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await received.count == 2_500 else {
            let receivedCount = await received.count
            let transmittedCount = await transport.transmittedPackets.count
            let queuedCount = await interface.snapshot().queuedPackets
            throw RNodeError.transport(
                "RNode flow-control soak stalled: received \(receivedCount), transmitted \(transmittedCount), queued \(queuedCount)."
            )
        }
        #expect(await received.count == 2_500)
        #expect(await transport.transmittedPackets.count == 2_500)
        #expect(await interface.snapshot().queuedPackets == 0)
        await interface.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw RNodeError.transport("Timed out waiting for the RNode test condition.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("ReticulumKit transport runtimes")
struct ReticulumKitTransportRuntimeTests {
    @Test("WebSocket server framing accepts masked clients and emits binary server frames")
    func webSocketServerFraming() async throws {
        let payload = packet(payload: "websocket-client")
        let mask = Data([0x12, 0x34, 0x56, 0x78])
        var masked = Data()
        for (index, byte) in payload.enumerated() {
            masked.append(byte ^ mask[index % 4])
        }
        var clientFrame = Data([0x82, 0x80 | UInt8(payload.count)])
        clientFrame.append(mask)
        clientFrame.append(masked)
        let frames = try ReticulumWebSocketFrameCodec.consumeClientFrames(buffer: &clientFrame)
        #expect(frames.count == 1)
        #expect(frames.first?.opcode == .binary)
        #expect(frames.first?.payload == payload)
        #expect(clientFrame.isEmpty)

        let serverFrame = try ReticulumWebSocketFrameCodec.serverFrame(opcode: .binary, payload: payload)
        #expect(serverFrame.prefix(2) == Data([0x82, UInt8(payload.count)]))
        #expect(serverFrame.dropFirst(2) == payload)

        let received = PacketCounter()
        let server = ReticulumWebSocketServer(port: 0) { _, packet in
            await received.add(packet.raw)
        }
        try await server.start()
        try await waitUntil {
            if case .listening = await server.state { return true }
            return false
        }
        guard case let .listening(port) = await server.state else {
            Issue.record("WebSocket listener did not become ready.")
            return
        }
        let bytes = PacketCounter()
        let client = LocalRawConnectionFixture(port: port) { data in await bytes.add(data) }
        try await client.start()
        try await client.send(Data(
            "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8
        ))
        try await waitUntil {
            String(data: await bytes.combined, encoding: .utf8)?.contains("101 Switching Protocols") == true
        }
        try await client.send(Data([0x82, 0x80 | UInt8(payload.count)]) + mask + masked)
        try await waitUntil { await received.combined == payload }
        try await server.broadcast(payload)
        try await waitUntil { await bytes.combined.suffix(serverFrame.count) == serverFrame }
        await client.stop()
        await server.stop()
    }

    @Test("HTTP tunnel server and client carry Reticulum packets bidirectionally")
    func httpServerLifecycle() async throws {
        let serverReceived = PacketCounter()
        let clientReceived = PacketCounter()
        let server = ReticulumHTTPServer(port: 0) { _, packet in
            await serverReceived.add(packet.raw)
        }
        try await server.start()
        try await waitUntil {
            if case .listening = await server.state { return true }
            return false
        }
        guard case let .listening(port) = await server.state else {
            Issue.record("HTTP server did not begin listening.")
            return
        }
        let client = ReticulumHTTPInterface(
            url: URL(string: "http://127.0.0.1:\(port)/")!,
            pollInterval: 0.05,
            packetHandler: { packet in await clientReceived.add(packet.raw) }
        )
        await client.start()
        try await waitUntil { await client.state == .ready }

        let outbound = packet(payload: "http-client")
        try await client.send(rawPacket: outbound)
        try await waitUntil { await serverReceived.combined == outbound }

        let inbound = packet(payload: "http-server", destinationByte: 0x35)
        try await server.broadcast(inbound)
        try await waitUntil { await clientReceived.combined == inbound }

        await client.stop()
        await server.stop()
    }

    @Test("UDP listener carries packets in both directions")
    func udpListenerLifecycle() async throws {
        let serverReceived = PacketCounter()
        let clientReceived = PacketCounter()
        let server = try ReticulumUDPListener(
            configuration: ReticulumUDPListenerConfiguration(listenHost: "127.0.0.1", listenPort: 0)
        ) { _, packet in
            await serverReceived.add(packet.raw)
        }
        try await server.start()
        try await waitUntil {
            if case .listening = await server.state { return true }
            return false
        }
        guard case let .listening(port) = await server.state else {
            Issue.record("UDP server did not begin listening.")
            return
        }
        let client = ReticulumUDPInterface(host: "127.0.0.1", port: port) { packet in
            await clientReceived.add(packet.raw)
        }
        await client.start()
        try await waitUntil { await client.state == .ready }

        let outbound = packet(payload: "udp-client")
        try await client.send(outbound)
        try await waitUntil { await serverReceived.combined == outbound }

        let inbound = packet(payload: "udp-server", destinationByte: 0x36)
        try await server.broadcast(inbound)
        try await waitUntil { await clientReceived.combined == inbound }

        await client.stop()
        await server.stop()
    }

    @Test("AX.25 KISS UI envelope matches the Reticulum address rules")
    func ax25KISSEnvelope() throws {
        let raw = packet(payload: "ax25")
        let frame = try AX25UIFrame.encode(
            payload: raw,
            sourceCallsign: "VK3XXX",
            sourceSSID: 7,
            destinationCallsign: "APZRNS",
            destinationSSID: 0
        )
        #expect(frame.count == raw.count + AX25UIFrame.headerSize)
        #expect(frame[14] == AX25UIFrame.controlUI)
        #expect(frame[15] == AX25UIFrame.pidNoLayer3)
        #expect(try AX25UIFrame.decode(frame) == raw)
    }

    @Test("Configured runtime provides one ReticulumKit interface boundary")
    func configuredRuntimeBoundary() async throws {
        let profile = ReticulumInterfaceProfile(
            name: "UDP test",
            kind: .udp,
            port: 54_321,
            listenHost: "127.0.0.1"
        )
        let runtime = ReticulumConfiguredInterfaceRuntime { _, _ in }
        await runtime.apply([profile])
        let snapshots = await runtime.currentSnapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.kind == .udp)
        #expect(snapshots.first?.mode == .full)
        #expect(await runtime.readyInterfaceIDs() == [
            ReticulumConfiguredInterfaceRuntime.interfaceID(for: profile.id)
        ])
        await runtime.stopAll()
    }

    @Test("I2P SAM session and stream lifecycle carries Reticulum packets")
    func i2pSAMLifecycle() async throws {
        let fixture = try LocalSAMFixture()
        let port = try await fixture.start()
        let probe = try await ReticulumI2PSAMDiagnostics.probe(host: "127.0.0.1", port: port, timeout: 2)
        #expect(probe.samVersion == "3.3")
        let states = TCPStateRecorder()
        let received = PacketCounter()
        let interface = ReticulumI2PInterface(
            configuration: ReticulumI2PConfiguration(
                samPort: port,
                sessionID: "reticulum-kit-test",
                role: .connect(destination: "peer.b32.i2p"),
                timeout: 2
            ),
            packetHandler: { packet in await received.add(packet.raw) },
            stateHandler: { state in await states.add(state) }
        )
        await interface.start()
        try await waitUntil { await states.isReady }

        let raw = Data([0x00, 0x00]) + Data(repeating: 0x42, count: 16) + Data([0x00]) + Data("sam".utf8)
        try await interface.send(rawPacket: raw)
        try await waitUntil { await received.combined == raw }
        #expect(fixture.sawSession)
        #expect(fixture.sawStream)

        await interface.stop()
        await fixture.stop()
    }

    @Test("External I2P SAM router carries Reticulum packets bidirectionally when configured")
    func externalI2PSAMAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["SIDEBAND_EXTERNAL_I2P_SAM_PORT"],
              let port = UInt16(portText) else { return }
        let host = environment["SIDEBAND_EXTERNAL_I2P_SAM_HOST"] ?? "127.0.0.1"
        let suffix = UUID().uuidString.lowercased()
        let acceptReceived = PacketCounter()
        let connectReceived = PacketCounter()
        let acceptStates = TCPStateRecorder()
        let connectStates = TCPStateRecorder()
        let acceptor = ReticulumI2PInterface(
            configuration: ReticulumI2PConfiguration(
                samHost: host,
                samPort: port,
                sessionID: "lsb-accept-\(suffix)",
                role: .accept,
                timeout: 60,
                reconnect: false
            ),
            packetHandler: { await acceptReceived.add($0.raw) },
            stateHandler: { await acceptStates.add($0) }
        )
        await acceptor.start()
        let destinationDeadline = ContinuousClock.now + .seconds(60)
        while await acceptor.sessionDestination == nil, ContinuousClock.now < destinationDeadline {
            if case let .failed(reason) = await acceptor.state {
                throw RNodeError.transport("External SAM accept session failed: \(reason)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let destination = try #require(await acceptor.sessionDestination)
        let connector = ReticulumI2PInterface(
            configuration: ReticulumI2PConfiguration(
                samHost: host,
                samPort: port,
                sessionID: "lsb-connect-\(suffix)",
                role: .connect(destination: destination),
                timeout: 60,
                reconnect: false
            ),
            packetHandler: { await connectReceived.add($0.raw) },
            stateHandler: { await connectStates.add($0) }
        )
        await connector.start()
        let readyDeadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < readyDeadline {
            let acceptReady = await acceptStates.isReady
            let connectReady = await connectStates.isReady
            if acceptReady && connectReady { break }
            let acceptState = await acceptor.state
            let connectState = await connector.state
            if case let .failed(reason) = acceptState {
                throw RNodeError.transport("External SAM accept stream failed: \(reason)")
            }
            if case let .failed(reason) = connectState {
                throw RNodeError.transport("External SAM connect stream failed: \(reason)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await acceptStates.isReady)
        #expect(await connectStates.isReady)

        let forward = packet(payload: "external-i2p-forward", destinationByte: 0x51)
        try await connector.send(rawPacket: forward)
        try await waitUntil(timeout: .seconds(30)) { await acceptReceived.combined == forward }
        let reverse = packet(payload: "external-i2p-reverse", destinationByte: 0x52)
        try await acceptor.send(rawPacket: reverse)
        try await waitUntil(timeout: .seconds(30)) { await connectReceived.combined == reverse }

        await connector.stop()
        await acceptor.stop()
    }

    #if os(macOS)
    @Test("Configured Pipe profile owns a safe HDLC subprocess lifecycle")
    func configuredPipeLifecycle() async throws {
        let received = PacketCounter()
        let profile = try ReticulumInterfaceProfile(
            name: "Local echo pipe",
            kind: .pipe,
            device: "/bin/cat",
            reconnect: false,
            pipeArguments: [],
            pipeEnvironment: ["LC_ALL": "C"]
        ).validated()
        let runtime = ReticulumConfiguredInterfaceRuntime { packet, interfaceID in
            #expect(interfaceID == ReticulumConfiguredInterfaceRuntime.interfaceID(for: profile.id))
            await received.add(packet.raw)
        }
        await runtime.apply([profile])
        try await waitUntil {
            await runtime.currentSnapshots().first?.state == .ready
        }
        let raw = packet(payload: "pipe-runtime", destinationByte: 0x39)
        try await runtime.send(
            rawPacket: raw,
            on: ReticulumConfiguredInterfaceRuntime.interfaceID(for: profile.id)
        )
        try await waitUntil { await received.combined == raw }
        await runtime.stopAll()
        #expect(await runtime.currentSnapshots().first?.state == .stopped)
    }
    #endif

    @Test("Backbone listener keeps independent peer sockets and HDLC decoders")
    func backboneListener() async throws {
        let listenerStates = BackboneStateRecorder()
        let received = PacketCounter()
        let listener = ReticulumBackboneListener(
            port: 0,
            packetHandler: { _, packet in await received.add(packet.raw) },
            stateHandler: { state, peers in await listenerStates.update(state, peers: peers.count) }
        )
        try await listener.start()
        try await waitUntil { await listenerStates.port != nil }
        let port = try #require(await listenerStates.port)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let clientStates = TCPStateRecorder()
        let client = ReticulumBackboneClient(endpoint: endpoint, packetHandler: { _ in }) {
            await clientStates.add($0)
        }
        await client.start()
        try await waitUntil {
            let ready = await clientStates.isReady
            let peerCount = await listener.peers().count
            return ready && peerCount == 1
        }

        let raw = Data([0x00, 0x00]) + Data(repeating: 0x24, count: 16) + Data([0x00]) + Data("backbone".utf8)
        try await client.send(rawPacket: raw)
        try await waitUntil { await received.combined == raw }
        #expect(await listenerStates.peerCount == 1)

        await client.stop()
        await listener.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw RNodeError.transport("Timed out waiting for a transport test condition.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func packet(payload: String, destinationByte: UInt8 = 0x42) -> Data {
        Data([0x00, 0x00])
            + Data(repeating: destinationByte, count: 16)
            + Data([0x00])
            + Data(payload.utf8)
    }
}

private actor PacketCounter {
    private(set) var packets: [Data] = []
    var count: Int { packets.count }
    var combined: Data { packets.reduce(into: Data()) { $0 += $1 } }
    func add(_ packet: Data) { packets.append(packet) }
}

private actor TransportStateRecorder {
    private var states: [RNodeByteTransportState] = []
    var containsReady: Bool { states.contains(.ready) }
    var containsStopped: Bool { states.contains(.stopped) }
    var readyCount: Int { states.filter { $0 == .ready }.count }
    func add(_ state: RNodeByteTransportState) { states.append(state) }
}

private actor TCPStateRecorder {
    private var states: [ReticulumTCPInterface.State] = []
    var isReady: Bool { states.contains(.ready) }
    func add(_ state: ReticulumTCPInterface.State) { states.append(state) }
}

private actor BackboneStateRecorder {
    private(set) var port: UInt16?
    private(set) var peerCount = 0
    func update(_ state: ReticulumBackboneListener.State, peers: Int) {
        if case let .listening(value) = state { port = value }
        peerCount = peers
    }
}

private final class LocalSAMFixture: @unchecked Sendable {
    private struct ConnectionState {
        var lineBuffer = Data()
        var streamReady = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ReticulumKitTests.SAM")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var states: [ObjectIdentifier: ConnectionState] = [:]
    private var sessionSeen = false
    private var streamSeen = false

    var sawSession: Bool { lock.withLock { sessionSeen } }
    var sawStream: Bool { lock.withLock { streamSeen } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard resumed.claim(), let port = self.listener.port?.rawValue else { return }
                    continuation.resume(returning: port)
                case let .failed(error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() async {
        lock.withLock {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            states.removeAll()
        }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.withLock {
            connections[id] = connection
            states[id] = ConnectionState()
        }
        connection.start(queue: queue)
        receive(connection, id: id)
    }

    private func receive(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data, connection: connection, id: id) }
            if error == nil, !complete { self.receive(connection, id: id) }
        }
    }

    private func consume(_ data: Data, connection: NWConnection, id: ObjectIdentifier) {
        var responses: [Data] = []
        var echo: Data?
        lock.withLock {
            guard var state = states[id] else { return }
            if state.streamReady {
                echo = data
            } else {
                state.lineBuffer.append(data)
                while let newline = state.lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = state.lineBuffer.prefix(through: newline)
                    state.lineBuffer.removeSubrange(...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    if line.hasPrefix("HELLO VERSION") {
                        responses.append(Data("HELLO REPLY RESULT=OK VERSION=3.3\n".utf8))
                    } else if line.hasPrefix("SESSION CREATE") {
                        sessionSeen = true
                        responses.append(Data("SESSION STATUS RESULT=OK DESTINATION=local.b32.i2p\n".utf8))
                    } else if line.hasPrefix("STREAM CONNECT") || line.hasPrefix("STREAM ACCEPT") {
                        streamSeen = true
                        state.streamReady = true
                        responses.append(Data("STREAM STATUS RESULT=OK\n".utf8))
                    }
                }
            }
            states[id] = state
        }
        for response in responses {
            connection.send(content: response, completion: .idempotent)
        }
        if let echo { connection.send(content: echo, completion: .idempotent) }
    }
}

private final class LocalTCPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ReticulumKitTests.RNodeTCPServer")
    private let receive: @Sendable (Data) async -> Void
    private let lock = NSLock()
    private var connection: NWConnection?

    init(receive: @escaping @Sendable (Data) async -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.receive = receive
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard resumed.claim(), let port = self.listener.port?.rawValue else { return }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.connection = connection }
                connection.start(queue: self.queue)
                self.receiveNext(connection)
            }
            listener.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        guard let connection = lock.withLock({ connection }) else {
            throw RNodeError.transport("The local TCP test client is not connected.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func stop() async {
        lock.withLock {
            connection?.cancel()
            connection = nil
        }
        listener.cancel()
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { Task { await self.receive(data) } }
            if error == nil, !complete { self.receiveNext(connection) }
        }
    }
}

private final class LocalRawConnectionFixture: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ReticulumKitTests.RawConnection")
    private let receive: @Sendable (Data) async -> Void

    init(port: UInt16, receive: @escaping @Sendable (Data) async -> Void) {
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.receive = receive
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready where resumed.claim():
                    continuation.resume()
                case let .failed(error) where resumed.claim():
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func stop() async { connection.cancel() }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { Task { await self.receive(data) } }
            if error == nil, !complete { self.receiveNext() }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func claim() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}
