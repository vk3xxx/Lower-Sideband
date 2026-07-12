import Foundation
import Observation

@MainActor @Observable
public final class SidebandStore {
    public private(set) var conversations: [Conversation] = []
    public private(set) var messages: [Message] = []
    public private(set) var transportState: TransportState = .offline
    public private(set) var networkState: ReticulumTCPInterface.State = .stopped
    public private(set) var receivedPacketCount = 0
    public private(set) var discoveries: [DiscoveredDestination] = []
    public private(set) var knownPathHashes: Set<String> = []
    public private(set) var pendingPathHashes: Set<String> = []
    public private(set) var pendingLinkHashes: Set<String> = []
    public private(set) var activeLinkHashes: Set<String> = []
    public private(set) var encryptedPacketsReceived = 0
    public private(set) var keepalivesReceived = 0
    public private(set) var keepalivesSent = 0
    public private(set) var linkIdentificationsSent = 0
    public private(set) var propagationRequestsSent = 0
    public private(set) var propagationResponsesReceived = 0
    public private(set) var propagationMessagesAvailable = 0
    public private(set) var propagationUploadsAccepted = 0
    public private(set) var deliveryAnnouncesSent = 0
    public private(set) var inboundLinksAccepted = 0
    public private(set) var opportunisticDeliveriesReceived = 0
    public private(set) var lastPropagationSync: Date?
    public private(set) var deliveryTimeoutCount = 0
    public private(set) var reconnectDelaySeconds: Int?
    public private(set) var recoveredOutboundCount = 0
    public var networkHost: String
    public var networkIPv6Host: String
    public var networkPort: Int
    public var preferIPv6: Bool
    public var autoConnectEnabled: Bool
    public var autoInterfaceEnabled: Bool
    public var propagationNodeHash: String
    public let lanDiscovery = LANGatewayDiscovery()
    public let autoInterfaceDiscovery = AutoInterfaceDiscovery()
    public let reachability = NetworkReachability()
    public private(set) var selectedGatewayName: String?
    public private(set) var activeNetworkHost: String?
    public var selectedConversationID: UUID?
    public var lastError: String?

    private let transport: any MessageTransport
    private let persistenceURL: URL
    private var networkInterface: ReticulumTCPInterface?
    private var networkConnectionGeneration = UUID()
    private let pathTable = ReticulumPathTable()
    private var pendingLinks: [String: ReticulumLinkRequest] = [:]
    private var activeLinks: [String: ReticulumLinkSession] = [:]
    private enum ReceiptKind { case direct, opportunistic, propagation }
    private struct PendingReceipt { let messageID: UUID; let kind: ReceiptKind; let destinationHash: String }
    private var pendingReceipts: [String: PendingReceipt] = [:]
    private enum PropagationRequestKind { case list, download }
    private var pendingPropagationRequests: [String: PropagationRequestKind] = [:]
    private var receivedLXMFIDs: Set<String> = []
    private var inboundRemoteIdentities: [String: ReticulumIdentity] = [:]
    private var inboundLinkIDs: Set<String> = []
    private var propagationSyncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var deferredPathRequests: Set<String> = []
    private var intentionallyDisconnected = false
    private var reconnectAttempt = 0
    private let transportIdentity: ReticulumIdentity
    private let tcpInterfaceHash: Data
    private let messagingIdentity: ReticulumIdentity

    public init(transport: any MessageTransport = QueuedTransport(), persistenceURL: URL? = nil) {
        self.transport = transport
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        let identityMaterial = SecureIdentityStore.loadOrCreate(account: "reticulum.transport", legacyDefaultsKey: "reticulumTransportIdentity")
        transportIdentity = (try? ReticulumIdentity(privateKey: identityMaterial)) ?? ReticulumIdentity()
        let interfaceMaterial = UserDefaults.standard.data(forKey: "reticulumTCPInterfaceHash") ?? ReticulumIdentity.fullHash(Data(UUID().uuidString.utf8))
        tcpInterfaceHash = interfaceMaterial
        UserDefaults.standard.set(interfaceMaterial, forKey: "reticulumTCPInterfaceHash")
        let messagingMaterial = SecureIdentityStore.loadOrCreate(account: "lxmf.messaging", legacyDefaultsKey: "lxmfMessagingIdentity")
        messagingIdentity = (try? ReticulumIdentity(privateKey: messagingMaterial)) ?? ReticulumIdentity()
        networkHost = UserDefaults.standard.string(forKey: "reticulumHost") ?? "127.0.0.1"
        networkIPv6Host = UserDefaults.standard.string(forKey: "reticulumIPv6Host") ?? "2403:5810:568a:1:be24:11ff:fe03:ff12"
        let savedPort = UserDefaults.standard.integer(forKey: "reticulumPort")
        networkPort = savedPort == 0 ? 4242 : savedPort
        preferIPv6 = UserDefaults.standard.object(forKey: "reticulumPreferIPv6") as? Bool ?? true
        autoConnectEnabled = UserDefaults.standard.bool(forKey: "reticulumAutoConnect")
        autoInterfaceEnabled = UserDefaults.standard.bool(forKey: "reticulumAutoInterface")
        propagationNodeHash = UserDefaults.standard.string(forKey: "lxmfPropagationNode") ?? ""
        receivedLXMFIDs = Set(UserDefaults.standard.stringArray(forKey: "receivedLXMFMessageIDs") ?? [])
        load()
        autoInterfaceDiscovery.setPacketHandler { [weak self] packet in await self?.receive(packet) }
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    public func messages(for conversationID: UUID) -> [Message] {
        messages.filter { $0.conversationID == conversationID }.sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    public func addConversation(destinationHash: String, displayName: String) -> Bool {
        let hash = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(hash) else {
            lastError = "An LXMF destination must be a 32-character hexadecimal address."
            return false
        }
        if let existing = conversations.first(where: { $0.destinationHash == hash }) {
            selectedConversationID = existing.id
            return true
        }
        let conversation = Conversation(destinationHash: hash, displayName: displayName.isEmpty ? abbreviated(hash) : displayName)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        save()
        return true
    }

    public func send(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let conversation = selectedConversation else { return }
        let message = Message(conversationID: conversation.id, body: body, direction: .outgoing, state: .queued)
        messages.append(message)
        touch(conversation.id)
        save()
        await attemptDelivery(for: conversation.id)
    }

    public func startTransport() async {
        await transport.start()
        transportState = await transport.state
    }

    public func clearError() { lastError = nil }

    public func connectNetwork(forceIPv4: Bool = false) async {
        guard networkState != .connecting, networkState != .ready else { return }
        guard !networkHost.isEmpty, (1...65_535).contains(networkPort), let port = UInt16(exactly: networkPort) else {
            lastError = "Enter a valid TCP host and port."
            return
        }
        networkState = .connecting
        let useIPv6 = !forceIPv4 && preferIPv6 && reachability.supportsIPv6 && !networkIPv6Host.isEmpty
        let selectedHost = useIPv6 ? networkIPv6Host : networkHost
        let generation = UUID()
        networkConnectionGeneration = generation
        await networkInterface?.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionallyDisconnected = false
        UserDefaults.standard.set(networkHost, forKey: "reticulumHost")
        UserDefaults.standard.set(networkIPv6Host, forKey: "reticulumIPv6Host")
        UserDefaults.standard.set(networkPort, forKey: "reticulumPort")
        UserDefaults.standard.set(preferIPv6, forKey: "reticulumPreferIPv6")
        UserDefaults.standard.set(autoConnectEnabled, forKey: "reticulumAutoConnect")
        activeNetworkHost = selectedHost
        let interface = ReticulumTCPInterface(host: selectedHost, port: port) { [weak self] packet in
            await self?.receive(packet)
        } stateHandler: { [weak self] state in
            await self?.setNetworkState(state, generation: generation)
        }
        networkInterface = interface
        await interface.start()
    }

    public func disconnectNetwork() async {
        intentionallyDisconnected = true
        reconnectAttempt = 0
        reconnectDelaySeconds = nil
        networkConnectionGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPeriodicPropagationSync()
        await networkInterface?.stop()
        networkInterface = nil
        networkState = .stopped
        activeNetworkHost = nil
    }

    public func applicationDidBecomeActive() async {
        if autoConnectEnabled, networkState != .ready { await connectNetwork() }
        if autoInterfaceEnabled, !autoInterfaceDiscovery.isListening { autoInterfaceDiscovery.start() }
        startPeriodicPropagationSync()
        await syncPropagationNow()
    }

    public func applicationDidEnterBackground() {
        stopPeriodicPropagationSync()
    }

    public func syncPropagationNow() async {
        guard networkState == .ready,
              !pendingPropagationRequests.values.contains(where: { if case .list = $0 { true } else { false } }),
              let session = activeLinks.values.first(where: { $0.destinationHash.hex == propagationNodeHash }) else { return }
        do {
            let requestPacket = try session.encryptedPacket(LXMFPropagation.messageListRequest(), context: 0x09)
            pendingPropagationRequests[try ReticulumIdentity.truncatedHash(ReticulumPacket(raw: requestPacket).hashablePart).hex] = .list
            try await transmitRawPacket(requestPacket)
            propagationRequestsSent += 1
            lastPropagationSync = .now
            UserDefaults.standard.set(propagationRequestsSent, forKey: "lxmfPropagationRequestsSent")
        } catch { lastError = "Propagation sync failed: \(error.localizedDescription)" }
    }

    private func startPeriodicPropagationSync() {
        guard propagationSyncTask == nil else { return }
        propagationSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.syncPropagationNow()
            }
        }
    }

    private func stopPeriodicPropagationSync() {
        propagationSyncTask?.cancel()
        propagationSyncTask = nil
    }

    public func setAutoConnect(_ enabled: Bool) {
        autoConnectEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "reticulumAutoConnect")
    }

    public func setPreferIPv6(_ enabled: Bool) {
        preferIPv6 = enabled
        UserDefaults.standard.set(enabled, forKey: "reticulumPreferIPv6")
    }

    public func setPropagationNode(_ hash: String) {
        propagationNodeHash = hash.trimmingCharacters(in: CharacterSet(charactersIn: "<> ").union(.whitespacesAndNewlines)).lowercased()
        UserDefaults.standard.set(propagationNodeHash, forKey: "lxmfPropagationNode")
    }

    public func requestPropagationNodePath() async {
        guard DestinationHash.isValid(propagationNodeHash) else {
            lastError = "Enter a valid 32-character LXMF propagation-node destination."
            return
        }
        await requestPath(to: propagationNodeHash)
    }

    public var propagationNodeHasPath: Bool { hasPath(to: propagationNodeHash) }
    public var propagationNodePathPending: Bool { isPathPending(to: propagationNodeHash) }
    public var localDeliveryHash: String {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + messagingIdentity.hash).hex
    }

    public func startGatewayDiscovery() { lanDiscovery.start() }
    public func stopGatewayDiscovery() { lanDiscovery.stop() }
    public func startAutoInterfaceDiscovery() {
        autoInterfaceEnabled = true
        UserDefaults.standard.set(true, forKey: "reticulumAutoInterface")
        autoInterfaceDiscovery.start()
    }
    public func stopAutoInterfaceDiscovery() {
        autoInterfaceEnabled = false
        UserDefaults.standard.set(false, forKey: "reticulumAutoInterface")
        autoInterfaceDiscovery.stop()
    }

    public func connect(to gateway: LANGateway) async {
        guard networkState != .connecting else { return }
        networkState = .connecting
        let generation = UUID()
        networkConnectionGeneration = generation
        await networkInterface?.stop()
        selectedGatewayName = gateway.name
        let interface = ReticulumTCPInterface(endpoint: gateway.endpoint) { [weak self] packet in
            await self?.receive(packet)
        } stateHandler: { [weak self] state in
            await self?.setNetworkState(state, generation: generation)
        }
        networkInterface = interface
        await interface.start()
    }

    public func addConversation(from discovery: DiscoveredDestination) {
        _ = addConversation(destinationHash: discovery.destinationHash, displayName: "Discovered \(discovery.destinationHash.prefix(8))")
    }

    public func requestPath(to destinationHash: String) async {
        guard let target = Data(hexadecimal: destinationHash) else {
            lastError = "The destination address is invalid."
            return
        }
        let normalized = destinationHash.lowercased()
        guard networkState == .ready, let networkInterface else {
            deferredPathRequests.insert(normalized)
            pendingPathHashes.insert(normalized)
            switch networkState {
            case .stopped, .failed: await connectNetwork()
            case .connecting, .ready: break
            }
            return
        }
        do {
            let packet = try ReticulumPathRequest.packet(targetHash: target)
            try await networkInterface.send(rawPacket: packet)
            for peer in autoInterfaceDiscovery.peers { autoInterfaceDiscovery.send(rawPacket: packet, to: peer) }
            await pathTable.markRequested(target)
            pendingPathHashes.insert(destinationHash.lowercased())
            Task {
                try? await Task.sleep(for: .seconds(16))
                if await !pathTable.isPending(target), !hasPath(to: destinationHash) {
                    pendingPathHashes.remove(destinationHash.lowercased())
                    if let conversation = conversations.first(where: { $0.destinationHash == destinationHash }) { await propagateQueued(for: conversation.id) }
                }
            }
        } catch {
            lastError = "Path request failed: \(error.localizedDescription)"
        }
    }

    public func hasPath(to destinationHash: String) -> Bool { knownPathHashes.contains(destinationHash.lowercased()) }
    public func isPathPending(to destinationHash: String) -> Bool { pendingPathHashes.contains(destinationHash.lowercased()) }
    public var validatedDiscoveryCount: Int { discoveries.count(where: \.isValidated) }
    public var unverifiedDiscoveryCount: Int { discoveries.count - validatedDiscoveryCount }
    public var knownPathCount: Int { knownPathHashes.count }
    public var pendingPathCount: Int { pendingPathHashes.count }
    public var pendingLinkCount: Int { pendingLinkHashes.count }
    public var activeLinkCount: Int { activeLinkHashes.count }

    public func requestLink(to destinationHash: String) async {
        guard hasPath(to: destinationHash), let target = Data(hexadecimal: destinationHash) else {
            lastError = "A validated path is required before establishing a link."
            return
        }
        do {
            let request = try ReticulumLinkRequest(destinationHash: target)
            if let networkInterface, networkState == .ready { try await networkInterface.send(rawPacket: request.rawPacket) }
            for peer in autoInterfaceDiscovery.peers { autoInterfaceDiscovery.send(rawPacket: request.rawPacket, to: peer) }
            pendingLinks[request.linkID.hex] = request
            pendingLinkHashes.insert(destinationHash.lowercased())
            UserDefaults.standard.set(request.linkID.hex, forKey: "reticulumLastPendingLink")
        } catch { lastError = "Link request failed: \(error.localizedDescription)" }
    }

    private func setNetworkState(_ state: ReticulumTCPInterface.State, generation: UUID) {
        guard generation == networkConnectionGeneration else { return }
        networkState = state
        if state == .ready {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            reconnectDelaySeconds = nil
            startPeriodicPropagationSync()
            Task {
                await synthesizeTCPTunnel()
                await announceLocalDeliveryDestination()
                let deferred = deferredPathRequests
                deferredPathRequests.removeAll()
                for destination in deferred {
                    pendingPathHashes.remove(destination)
                    await requestPath(to: destination)
                }
                if DestinationHash.isValid(propagationNodeHash), !propagationNodeHasPath, !propagationNodePathPending { await requestPropagationNodePath() }
                for conversation in conversations { await attemptDelivery(for: conversation.id) }
            }
        }
        switch state {
        case .failed:
            stopPeriodicPropagationSync()
            if activeNetworkHost == networkIPv6Host, networkHost != networkIPv6Host {
                Task { await connectNetwork(forceIPv4: true) }
            } else {
                scheduleReconnect()
            }
        case .stopped: stopPeriodicPropagationSync()
        case .connecting, .ready: break
        }
    }

    private func scheduleReconnect() {
        guard autoConnectEnabled, !intentionallyDisconnected, reconnectTask == nil else { return }
        let delay = min(60, 1 << min(reconnectAttempt + 1, 5))
        reconnectAttempt += 1
        reconnectDelaySeconds = delay
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connectNetwork()
        }
    }

    private func synthesizeTCPTunnel() async {
        guard let networkInterface else { return }
        do { try await networkInterface.send(rawPacket: ReticulumTunnelSynthesis.packet(identity: transportIdentity, interfaceHash: tcpInterfaceHash)) }
        catch { lastError = "TCP tunnel synthesis failed: \(error.localizedDescription)" }
    }

    private func announceLocalDeliveryDestination() async {
        do {
            let packet = try ReticulumAnnounceBuilder.packet(identity: messagingIdentity, destinationName: "lxmf.delivery", appData: ReticulumAnnounceBuilder.lxmfAppData(displayName: "Sideband Swift"))
            try await transmitRawPacket(packet)
            deliveryAnnouncesSent += 1
        } catch {
            // Connection transitions are retried by the engine. An announce is
            // maintenance traffic and must never interrupt the user with a modal.
        }
    }

    private func receive(_ packet: ReticulumPacket) {
        receivedPacketCount += 1
        if packet.packetType == .proof, packet.context == 0xff {
            receiveLinkProof(packet)
            return
        }
        if packet.packetType == .linkRequest, packet.destinationHash.hex == localDeliveryHash {
            acceptIncomingLink(packet)
            return
        }
        if packet.packetType == .proof {
            receiveDeliveryProof(packet)
            return
        }
        if packet.destinationType == .link {
            receiveLinkPacket(packet)
            return
        }
        if packet.packetType == .data, packet.destinationType == .single, packet.destinationHash.hex == localDeliveryHash {
            receiveOpportunisticPacket(packet)
            return
        }
        guard packet.packetType == .announce else { return }
        let hash = packet.destinationHash.hex
        let announce = try? ReticulumAnnounce(packet: packet)
        let isValidated = announce?.validate() == true
        if isValidated, let announce {
            Task {
                _ = await pathTable.ingest(announce, packet: packet)
                await refreshPathState()
                let hash = announce.destinationHash.hex
                if hash == propagationNodeHash, !pendingLinkHashes.contains(hash), !activeLinkHashes.contains(hash) {
                    await requestLink(to: hash)
                }
                if let conversation = conversations.first(where: { $0.destinationHash == hash }) { await attemptDelivery(for: conversation.id) }
            }
        }
        if let index = discoveries.firstIndex(where: { $0.destinationHash == hash }) {
            discoveries[index].hops = packet.hops
            discoveries[index].lastSeen = .now
            discoveries[index].packetCount += 1
            if isValidated, let announce {
                discoveries[index].isValidated = true
                discoveries[index].publicKey = announce.publicKey
                discoveries[index].appData = announce.appData
                discoveries[index].ratchet = announce.ratchet
            }
        } else {
            discoveries.insert(DiscoveredDestination(destinationHash: hash, hops: packet.hops, isValidated: isValidated, publicKey: announce?.publicKey, appData: announce?.appData, ratchet: announce?.ratchet), at: 0)
        }
        discoveries.sort { $0.lastSeen > $1.lastSeen }
        save()
    }

    private func receiveLinkProof(_ packet: ReticulumPacket) {
        let linkID = packet.destinationHash.hex
        guard let request = pendingLinks[linkID],
              let discovery = discoveries.first(where: { $0.destinationHash == request.destinationHash.hex }),
              let publicKey = discovery.publicKey,
              let session = try? request.validateProof(packet, destinationPublicKey: publicKey) else { return }
        activeLinks[linkID] = session
        pendingLinks.removeValue(forKey: linkID)
        let destination = request.destinationHash.hex
        pendingLinkHashes.remove(destination)
        activeLinkHashes.insert(destination)
        UserDefaults.standard.set(linkID, forKey: "reticulumLastActiveLink")
        UserDefaults.standard.removeObject(forKey: "reticulumLastPendingLink")
        if destination == propagationNodeHash { Task { await activateAndRequestPropagation(on: session) } }
        else if let conversation = conversations.first(where: { $0.destinationHash == destination }) {
            Task { await activateDirectLink(session, conversationID: conversation.id) }
        }
    }

    private func receiveLinkPacket(_ packet: ReticulumPacket) {
        guard let session = activeLinks[packet.destinationHash.hex] else { return }
        if packet.context == 0xfa {
            keepalivesReceived += 1
            return
        }
        if let plaintext = try? session.decrypt(packet) {
            encryptedPacketsReceived += 1
            if inboundLinkIDs.contains(session.linkID.hex) {
                handleInboundLinkPacket(packet, plaintext: plaintext, session: session)
                return
            }
            if packet.context == 0x0a {
                propagationResponsesReceived += 1
                UserDefaults.standard.set(propagationResponsesReceived, forKey: "lxmfPropagationResponsesReceived")
                UserDefaults.standard.set(plaintext, forKey: "lxmfLastPropagationResponse")
                Task { await handlePropagationResponse(plaintext, session: session) }
            }
        }
    }

    private func acceptIncomingLink(_ packet: ReticulumPacket) {
        guard let incoming = try? ReticulumIncomingLink(request: packet, localIdentity: messagingIdentity) else { return }
        activeLinks[incoming.session.linkID.hex] = incoming.session
        inboundLinkIDs.insert(incoming.session.linkID.hex)
        Task {
            do { try await transmitRawPacket(incoming.proofPacket); inboundLinksAccepted += 1 }
            catch { lastError = "Incoming link proof failed: \(error.localizedDescription)" }
        }
    }

    private func handleInboundLinkPacket(_ packet: ReticulumPacket, plaintext: Data, session: ReticulumLinkSession) {
        if packet.context == 0xfe { return }
        if packet.context == 0xfb {
            guard plaintext.count == 128 else { return }
            let publicKey = Data(plaintext.prefix(64))
            let signature = Data(plaintext.suffix(64))
            guard let identity = try? ReticulumIdentity(publicKey: publicKey), identity.validate(signature: signature, message: session.linkID + publicKey) else { return }
            inboundRemoteIdentities[session.linkID.hex] = identity
            return
        }
        guard packet.context == 0x00, let message = try? LXMFReceivedMessage(packed: plaintext), message.destinationHash.hex == localDeliveryHash else { return }
        let remoteIdentity = inboundRemoteIdentities[session.linkID.hex] ?? discoveries.first(where: { $0.destinationHash == message.sourceHash.hex }).flatMap { $0.publicKey }.flatMap { try? ReticulumIdentity(publicKey: $0) }
        guard let remoteIdentity, message.validate(with: remoteIdentity), importReceivedMessage(message, sourceIdentity: remoteIdentity) else { return }
        Task {
            do {
                let hash = packet.packetHash
                let proofData = hash + (try messagingIdentity.sign(hash))
                let proof = Data([0x0f, 0x00]) + session.linkID + Data([0x00]) + proofData
                try await transmitRawPacket(proof)
            } catch { lastError = "Delivery proof failed: \(error.localizedDescription)" }
        }
    }

    private func receiveOpportunisticPacket(_ packet: ReticulumPacket) {
        guard let decrypted = try? messagingIdentity.decrypt(packet.data),
              let message = try? LXMFReceivedMessage(packed: packet.destinationHash + decrypted),
              message.destinationHash.hex == localDeliveryHash,
              let discovery = discoveries.first(where: { $0.destinationHash == message.sourceHash.hex }),
              let publicKey = discovery.publicKey,
              let sourceIdentity = try? ReticulumIdentity(publicKey: publicKey),
              message.validate(with: sourceIdentity),
              importReceivedMessage(message, sourceIdentity: sourceIdentity) else { return }
        opportunisticDeliveriesReceived += 1
        Task {
            do { try await transmitRawPacket(try ReticulumProof.packet(for: packet, identity: messagingIdentity)) }
            catch { lastError = "Opportunistic delivery proof failed: \(error.localizedDescription)" }
        }
    }

    private func sendKeepalive(on session: ReticulumLinkSession) async {
        do {
            try await transmitRawPacket(session.keepalivePacket())
            keepalivesSent += 1
            UserDefaults.standard.set(keepalivesSent, forKey: "reticulumKeepalivesSent")
        } catch { lastError = "Link keepalive failed: \(error.localizedDescription)" }
    }

    private func activateAndRequestPropagation(on session: ReticulumLinkSession) async {
        do {
            try await transmitRawPacket(try session.encryptedPacket(MessagePack.double(session.rtt), context: 0xfe))
            let signedData = session.linkID + messagingIdentity.publicKey
            let identifyData = messagingIdentity.publicKey + (try messagingIdentity.sign(signedData))
            try await transmitRawPacket(try session.encryptedPacket(identifyData, context: 0xfb))
            linkIdentificationsSent += 1
            await syncPropagationNow()
            await sendKeepalive(on: session)
        } catch { lastError = "Propagation request failed: \(error.localizedDescription)" }
    }

    private func activateDirectLink(_ session: ReticulumLinkSession, conversationID: UUID) async {
        do {
            try await transmitRawPacket(try session.encryptedPacket(MessagePack.double(session.rtt), context: 0xfe))
            await attemptDelivery(for: conversationID)
            await sendKeepalive(on: session)
        } catch { lastError = "Direct link activation failed: \(error.localizedDescription)" }
    }

    private func handlePropagationResponse(_ plaintext: Data, session: ReticulumLinkSession) async {
        guard case let .array(parts)? = try? MessagePackDecoder.decode(plaintext), parts.count == 2,
              case let .binary(requestID) = parts[0], let kind = pendingPropagationRequests.removeValue(forKey: requestID.hex),
              case let .array(values) = parts[1] else { return }
        switch kind {
        case .list:
            let ids = values.compactMap { if case let .binary(value) = $0 { value } else { nil } }
            propagationMessagesAvailable = ids.count
            guard !ids.isEmpty else { return }
            let request = LXMFPropagation.messageDownloadRequest(ids)
            do {
                let requestPacket = try session.encryptedPacket(request, context: 0x09)
                pendingPropagationRequests[try ReticulumIdentity.truncatedHash(ReticulumPacket(raw: requestPacket).hashablePart).hex] = .download
                try await transmitRawPacket(requestPacket); propagationRequestsSent += 1
            }
            catch { lastError = "Propagation download request failed: \(error.localizedDescription)" }
        case .download:
            var acknowledgements: [Data] = []
            for value in values {
                guard case let .binary(lxmfData) = value else { continue }
                if importPropagatedMessage(lxmfData) { acknowledgements.append(ReticulumIdentity.fullHash(lxmfData)) }
            }
            propagationMessagesAvailable = max(0, propagationMessagesAvailable - acknowledgements.count)
            guard !acknowledgements.isEmpty else { return }
            do { try await transmitRawPacket(try session.encryptedPacket(LXMFPropagation.acknowledgementRequest(acknowledgements), context: 0x09)) }
            catch { lastError = "Propagation acknowledgement failed: \(error.localizedDescription)" }
        }
    }

    private func importPropagatedMessage(_ lxmfData: Data) -> Bool {
        guard lxmfData.count > 16 else { return false }
        let localNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let localDestination = ReticulumIdentity.truncatedHash(localNameHash + messagingIdentity.hash)
        guard lxmfData.prefix(16) == localDestination,
              let decrypted = try? messagingIdentity.decrypt(Data(lxmfData.dropFirst(16))),
              let message = try? LXMFReceivedMessage(packed: localDestination + decrypted),
              !receivedLXMFIDs.contains(message.messageID.hex),
              let discovery = discoveries.first(where: { $0.destinationHash == message.sourceHash.hex }),
              let publicKey = discovery.publicKey,
              let sourceIdentity = try? ReticulumIdentity(publicKey: publicKey),
              message.validate(with: sourceIdentity) else { return false }
        return importReceivedMessage(message, sourceIdentity: sourceIdentity)
    }

    private func importReceivedMessage(_ message: LXMFReceivedMessage, sourceIdentity: ReticulumIdentity) -> Bool {
        let expectedNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        guard message.sourceHash == ReticulumIdentity.truncatedHash(expectedNameHash + sourceIdentity.hash),
              !receivedLXMFIDs.contains(message.messageID.hex) else { return false }
        let source = message.sourceHash.hex
        if !conversations.contains(where: { $0.destinationHash == source }) { _ = addConversation(destinationHash: source, displayName: "Received \(source.prefix(8))") }
        guard let conversation = conversations.first(where: { $0.destinationHash == source }), let body = String(data: message.content, encoding: .utf8) else { return false }
        messages.append(Message(conversationID: conversation.id, body: body, timestamp: Date(timeIntervalSince1970: message.timestamp), direction: .incoming, state: .delivered))
        receivedLXMFIDs.insert(message.messageID.hex)
        UserDefaults.standard.set(Array(receivedLXMFIDs), forKey: "receivedLXMFMessageIDs")
        save()
        return true
    }

    private func transmitRawPacket(_ packet: Data) async throws {
        var transmitted = false
        if let networkInterface, networkState == .ready {
            try await networkInterface.send(rawPacket: packet)
            transmitted = true
        }
        for peer in autoInterfaceDiscovery.peers {
            autoInterfaceDiscovery.send(rawPacket: packet, to: peer)
            transmitted = true
        }
        if !transmitted { throw TransportError.nativeEngineUnavailable }
    }

    private func attemptDelivery(for conversationID: UUID) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let queued = messages.filter { $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued }
        guard !queued.isEmpty else { return }
        if !hasPath(to: conversation.destinationHash) {
            if !isPathPending(to: conversation.destinationHash) { await requestPath(to: conversation.destinationHash) }
            return
        }
        guard let destination = Data(hexadecimal: conversation.destinationHash),
              let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash }),
              let publicKey = discovery.publicKey,
              let recipient = try? ReticulumIdentity(publicKey: publicKey) else { return }
        let sourceNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(sourceNameHash + messagingIdentity.hash)
        var requiresLink = false
        for item in queued {
            do {
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, content: Data(item.body.utf8))
                let raw = try lxmf.opportunisticPacket(recipientIdentity: recipient, ratchet: discovery.ratchet)
                guard raw.count <= 500 else { requiresLink = true; continue }
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(messageID: item.id, kind: .opportunistic, destinationHash: conversation.destinationHash)
                try await transmitRawPacket(raw)
                updateMessage(item.id, state: .sent)
                scheduleReceiptTimeout(packetHash)
            } catch { requiresLink = true }
        }
        guard requiresLink else { return }
        if !activeLinkHashes.contains(conversation.destinationHash) {
            if !pendingLinkHashes.contains(conversation.destinationHash) { await requestLink(to: conversation.destinationHash) }
            return
        }
        guard let session = activeLinks.values.first(where: { $0.destinationHash.hex == conversation.destinationHash }) else { return }
        for item in messages.filter({ $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued }) {
            do {
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, content: Data(item.body.utf8))
                let raw = try session.encryptedPacket(lxmf.packed)
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(messageID: item.id, kind: .direct, destinationHash: conversation.destinationHash)
                try await transmitRawPacket(raw)
                updateMessage(item.id, state: .sent)
                scheduleReceiptTimeout(packetHash)
            } catch { lastError = "LXMF delivery failed: \(error.localizedDescription)" }
        }
    }

    private func receiveDeliveryProof(_ packet: ReticulumPacket) {
        guard packet.data.count == 96 else { return }
        let provedHash = Data(packet.data.prefix(32))
        guard let receipt = pendingReceipts[provedHash.hex],
              let discovery = discoveries.first(where: { $0.destinationHash == receipt.destinationHash }),
              let publicKey = discovery.publicKey,
              let identity = try? ReticulumIdentity(publicKey: publicKey),
              identity.validate(signature: Data(packet.data.suffix(64)), message: provedHash) else { return }
        pendingReceipts.removeValue(forKey: provedHash.hex)
        updateMessage(receipt.messageID, state: receipt.kind == .propagation ? .sent : .delivered)
        if receipt.kind == .propagation {
            propagationUploadsAccepted += 1
            UserDefaults.standard.set(propagationUploadsAccepted, forKey: "lxmfPropagationUploadsAccepted")
        }
    }

    private func scheduleReceiptTimeout(_ packetHash: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.expireReceipt(packetHash)
        }
    }

    private func expireReceipt(_ packetHash: String) async {
        guard let receipt = pendingReceipts.removeValue(forKey: packetHash) else { return }
        deliveryTimeoutCount += 1
        switch receipt.kind {
        case .opportunistic:
            updateMessage(receipt.messageID, state: .queued)
            await requestLink(to: receipt.destinationHash)
        case .direct:
            updateMessage(receipt.messageID, state: .queued)
            if let conversation = conversations.first(where: { $0.destinationHash == receipt.destinationHash }) {
                await propagateQueued(for: conversation.id)
            }
        case .propagation:
            updateMessage(receipt.messageID, state: .queued)
        }
    }

    private func propagateQueued(for conversationID: UUID) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let destination = Data(hexadecimal: conversation.destinationHash),
              let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash }),
              let publicKey = discovery.publicKey,
              let recipient = try? ReticulumIdentity(publicKey: publicKey),
              let propagationSession = activeLinks.values.first(where: { $0.destinationHash.hex == propagationNodeHash }) else { return }
        let sourceNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(sourceNameHash + messagingIdentity.hash)
        for item in messages.filter({ $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued }) {
            do {
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, content: Data(item.body.utf8))
                let envelope = try lxmf.propagatedEnvelope(recipientIdentity: recipient, ratchet: discovery.ratchet)
                let raw = try propagationSession.encryptedPacket(envelope)
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(messageID: item.id, kind: .propagation, destinationHash: propagationNodeHash)
                try await transmitRawPacket(raw)
                updateMessage(item.id, state: .sent)
                scheduleReceiptTimeout(packetHash)
            } catch { lastError = "Propagation upload failed: \(error.localizedDescription)" }
        }
    }

    private func refreshPathState() async {
        let paths = await pathTable.all()
        knownPathHashes = Set(paths.map { $0.destinationHash.hex })
        pendingPathHashes.subtract(knownPathHashes)
    }

    private func touch(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].updatedAt = .now
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func updateMessage(_ id: UUID, state: Message.DeliveryState) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = state
        save()
    }

    private func abbreviated(_ hash: String) -> String { "\(hash.prefix(8))…\(hash.suffix(4))" }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let snapshot = try? JSONDecoder.sideband.decode(AppSnapshot.self, from: data) else { return }
        conversations = snapshot.conversations
        messages = snapshot.messages
        for index in messages.indices where messages[index].direction == .outgoing && messages[index].state == .sent {
            messages[index].state = .queued
            recoveredOutboundCount += 1
        }
        discoveries = snapshot.discoveries
        selectedConversationID = conversations.first?.id
        if recoveredOutboundCount > 0 { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.sideband.encode(AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries))
            try data.write(to: persistenceURL, options: .atomic)
        } catch { lastError = "Could not save local data: \(error.localizedDescription)" }
    }

    private static func defaultPersistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "SidebandSwift", directoryHint: .isDirectory).appending(path: "sideband.json")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }
}

private extension JSONEncoder {
    static var sideband: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }
}
private extension JSONDecoder {
    static var sideband: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
