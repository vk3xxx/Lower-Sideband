import Foundation
import Observation

@MainActor @Observable
public final class SidebandStore {
    public private(set) var conversations: [Conversation] = []
    public private(set) var messages: [Message] = []
    public private(set) var drafts: [UUID: String] = [:]
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
    public private(set) var lastNetworkReadyAt: Date?
    public private(set) var deliveryTimeoutCount = 0
    public private(set) var reconnectDelaySeconds: Int?
    public private(set) var recoveredOutboundCount = 0
    public private(set) var incomingResourceProgress: [String: Double] = [:]
    public private(set) var isApplicationActive = true
    public private(set) var visibleConversationID: UUID?
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
    public let notifications = LocalNotificationManager()
    public let backgroundRefresh = BackgroundRefreshCoordinator()
    public let attachmentStore: AttachmentStore
    public let resourceStagingStore: ReticulumResourceStagingStore
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
    private struct OutgoingResource {
        let manifest: ReticulumResourceManifest; let parts: [Data]; let expectedProof: Data
        let messageID: UUID; let attachmentID: UUID; let linkID: String
        let segmentIndex: Int; let totalSegments: Int; let remainingSegments: [ReticulumPreparedResourceSegment]
        var timeoutToken = UUID()
        var sentIndices: Set<Int> = []
    }
    private var outgoingResources: [String: OutgoingResource] = [:]
    private struct IncomingResource { let session: ReticulumLinkSession; let advertisement: ReticulumResourceAdvertisement; var receiver: ReticulumResourceReceiver; var timeoutToken = UUID() }
    private var incomingResources: [String: IncomingResource] = [:]
    private var receivedResourceHashes: Set<String> = []
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
        attachmentStore = AttachmentStore(directory: self.persistenceURL.deletingLastPathComponent().appending(path: "Attachments", directoryHint: .isDirectory))
        resourceStagingStore = ReticulumResourceStagingStore(directory: self.persistenceURL.deletingLastPathComponent().appending(path: "ResourceStaging", directoryHint: .isDirectory))
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
        lastNetworkReadyAt = UserDefaults.standard.object(forKey: "reticulumLastReadyAt") as? Date
        receivedLXMFIDs = Set(UserDefaults.standard.stringArray(forKey: "receivedLXMFMessageIDs") ?? [])
        load()
        autoInterfaceDiscovery.setPacketHandler { [weak self] packet in await self?.receive(packet) }
        backgroundRefresh.register { [weak self] in await self?.performBackgroundRefresh() }
        Task { try? await resourceStagingStore.removeStale(olderThan: Date(timeIntervalSinceNow: -86_400)) }
        syncUnreadBadge()
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    public var totalUnreadCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    public func messages(for conversationID: UUID) -> [Message] {
        messages.filter { $0.conversationID == conversationID }.sorted { $0.timestamp < $1.timestamp }
    }

    public func latestMessage(for conversationID: UUID) -> Message? {
        messages.lazy.filter { $0.conversationID == conversationID }.max { $0.timestamp < $1.timestamp }
    }

    public func conversationTranscript(_ conversationID: UUID) -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        let formatter = ISO8601DateFormatter()
        let lines = messages(for: conversationID).map { message in
            let sender = message.direction == .outgoing ? "Me" : conversation.displayName
            let attachments = message.attachments.map { "[Attachment: \($0.filename)]" }.joined(separator: " ")
            return "[\(formatter.string(from: message.timestamp))] \(sender): \([message.body, attachments].filter { !$0.isEmpty }.joined(separator: " "))"
        }
        return (["Conversation with \(conversation.displayName)", "Destination: \(conversation.destinationHash)", ""] + lines).joined(separator: "\n")
    }

    public func conversationContactCard(_ conversationID: UUID) -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        return [
            "Sideband Contact",
            "Name: \(conversation.displayName)",
            "LXMF Destination: \(conversation.destinationHash)",
            "Trusted: \(conversation.isTrusted ? "yes" : "no")"
        ].joined(separator: "\n")
    }

    public func draft(for conversationID: UUID) -> String { drafts[conversationID] ?? "" }

    public func updateDraft(_ text: String, for conversationID: UUID) {
        if text.isEmpty { drafts.removeValue(forKey: conversationID) }
        else { drafts[conversationID] = text }
        save()
    }

    @discardableResult
    public func addConversation(destinationHash: String, displayName: String, select: Bool = true) -> Bool {
        let hash = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(hash) else {
            lastError = "An LXMF destination must be a 32-character hexadecimal address."
            return false
        }
        if let existing = conversations.first(where: { $0.destinationHash == hash }) {
            if select { selectedConversationID = existing.id }
            return true
        }
        let conversation = Conversation(destinationHash: hash, displayName: displayName.isEmpty ? abbreviated(hash) : displayName)
        conversations.insert(conversation, at: 0)
        if select { selectedConversationID = conversation.id }
        save()
        return true
    }

    public func markConversationRead(_ conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }), conversations[index].unreadCount > 0 else { return }
        conversations[index].unreadCount = 0
        save()
        syncUnreadBadge()
    }

    public func markConversationUnread(_ conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = max(1, conversations[index].unreadCount)
        save()
        syncUnreadBadge()
    }

    @discardableResult
    public func renameConversation(_ conversationID: UUID, to displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        conversations[index].displayName = name
        save()
        return true
    }

    public func deleteConversation(_ conversationID: UUID) async {
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        let removedMessages = messages.filter { $0.conversationID == conversationID }
        for message in removedMessages {
            for attachment in message.attachments {
                await cancelActiveResources(messageID: message.id, attachmentID: attachment.id)
                try? await attachmentStore.remove(attachment)
            }
        }
        messages.removeAll { $0.conversationID == conversationID }
        drafts.removeValue(forKey: conversationID)
        conversations.removeAll { $0.id == conversationID }
        if visibleConversationID == conversationID { visibleConversationID = nil }
        if selectedConversationID == conversationID { selectedConversationID = conversations.first?.id }
        save()
        syncUnreadBadge()
    }

    public func setConversationTrusted(_ trusted: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isTrusted = trusted
        save()
    }

    public func setConversationPinned(_ pinned: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isPinned = pinned
        sortConversations()
        save()
    }

    public func setConversationNotificationsMuted(_ muted: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].notificationsMuted = muted
        save()
    }

    public func shouldNotifyIncoming(for conversationID: UUID) -> Bool {
        conversations.first(where: { $0.id == conversationID })?.notificationsMuted == false
    }

    public func conversationDidAppear(_ conversationID: UUID) {
        visibleConversationID = conversationID
        if isApplicationActive { markConversationRead(conversationID) }
    }

    public func conversationDidDisappear(_ conversationID: UUID) {
        if visibleConversationID == conversationID { visibleConversationID = nil }
    }

    public func send(_ text: String) async {
        await send(text, attachments: [])
    }

    public func send(_ text: String, attachments: [Attachment]) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!body.isEmpty || !attachments.isEmpty), let conversation = selectedConversation else { return }
        guard body.count <= SidebandMessageLimits.maximumTextCharacters else {
            lastError = "Messages are limited to \(SidebandMessageLimits.maximumTextCharacters.formatted()) characters."
            return
        }
        guard attachments.count <= SidebandMessageLimits.maximumAttachments else {
            lastError = "Messages are limited to \(SidebandMessageLimits.maximumAttachments) attachments."
            return
        }
        let message = Message(conversationID: conversation.id, body: body, direction: .outgoing, state: .queued, attachments: attachments)
        messages.append(message)
        touch(conversation.id)
        save()
        await attemptDelivery(for: conversation.id)
    }

    public func validateAttachmentSelection(currentCount: Int, adding newCount: Int) -> Bool {
        guard currentCount + newCount <= SidebandMessageLimits.maximumAttachments else {
            lastError = "Messages are limited to \(SidebandMessageLimits.maximumAttachments) attachments."
            return false
        }
        return true
    }

    public func retryAttachment(messageID: UUID, attachmentID: UUID) async {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let attachmentIndex = messages[messageIndex].attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        await cancelActiveResources(messageID: messageID, attachmentID: attachmentID)
        messages[messageIndex].attachments[attachmentIndex].state = .queued
        messages[messageIndex].attachments[attachmentIndex].progress = 0
        messages[messageIndex].state = .queued
        save()
        await attemptDelivery(for: messages[messageIndex].conversationID)
    }

    public func retryMessage(_ messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID && $0.direction == .outgoing }) else { return }
        for attachmentIndex in messages[index].attachments.indices where messages[index].attachments[attachmentIndex].state == .failed {
            messages[index].attachments[attachmentIndex].state = .queued
            messages[index].attachments[attachmentIndex].progress = 0
        }
        messages[index].state = .queued
        let conversationID = messages[index].conversationID
        save()
        await attemptDelivery(for: conversationID)
    }

    public func removeFailedMessage(_ messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID && $0.direction == .outgoing && $0.state == .failed }) else { return }
        let message = messages[index]
        for attachment in message.attachments {
            await cancelActiveResources(messageID: messageID, attachmentID: attachment.id)
            try? await attachmentStore.remove(attachment)
        }
        messages.remove(at: index)
        save()
    }

    public func cancelAttachment(messageID: UUID, attachmentID: UUID) async {
        await cancelActiveResources(messageID: messageID, attachmentID: attachmentID)
        updateAttachment(messageID: messageID, attachmentID: attachmentID, state: .failed, progress: 0)
    }

    private func cancelActiveResources(messageID: UUID, attachmentID: UUID) async {
        let matches = outgoingResources.filter { $0.value.messageID == messageID && $0.value.attachmentID == attachmentID }
        for (hash, resource) in matches {
            outgoingResources.removeValue(forKey: hash)
            if let session = activeLinks[resource.linkID] { try? await transmitRawPacket(try session.resourceCancelPacket(resourceHash: resource.manifest.resourceHash, initiatedBySender: true)) }
        }
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

    public func reconnectNetwork() async {
        await disconnectNetwork()
        await connectNetwork()
    }

    public func applicationDidBecomeActive() async {
        isApplicationActive = true
        if let visibleConversationID { markConversationRead(visibleConversationID) }
        if autoConnectEnabled, networkState != .ready { await connectNetwork() }
        if autoInterfaceEnabled, !autoInterfaceDiscovery.isListening { autoInterfaceDiscovery.start() }
        startPeriodicPropagationSync()
        await syncPropagationNow()
    }

    public func applicationDidBecomeInactive() {
        isApplicationActive = false
    }

    public func applicationDidEnterBackground() {
        isApplicationActive = false
        stopPeriodicPropagationSync()
        backgroundRefresh.schedule()
    }

    private func performBackgroundRefresh() async {
        if autoConnectEnabled, networkState != .ready { await connectNetwork() }
        await syncPropagationNow()
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
        _ = addConversation(destinationHash: discovery.destinationHash, displayName: discovery.announcedDisplayName ?? "Discovered \(discovery.destinationHash.prefix(8))")
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
            lastNetworkReadyAt = .now
            UserDefaults.standard.set(lastNetworkReadyAt, forKey: "reticulumLastReadyAt")
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
        if packet.packetType == .proof, packet.context == 0x05, packet.destinationType == .link {
            receiveResourceProof(packet)
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
        if packet.context == 0x01 {
            handleIncomingResourcePart(packet.data, session: session)
            return
        }
        if let plaintext = try? session.decrypt(packet) {
            encryptedPacketsReceived += 1
            if packet.context == 0x03 {
                handleResourceRequest(plaintext, session: session)
                return
            }
            if packet.context == 0x02 {
                acceptResourceAdvertisement(plaintext, session: session)
                return
            }
            if packet.context == 0x04 {
                handleResourceHashMapUpdate(plaintext, session: session)
                return
            }
            if packet.context == 0x06 || packet.context == 0x07 {
                cancelResource(hash: plaintext.hex)
                return
            }
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
        if !conversations.contains(where: { $0.destinationHash == source }) {
            let name = discoveries.first(where: { $0.destinationHash == source })?.announcedDisplayName ?? "Received \(source.prefix(8))"
            _ = addConversation(destinationHash: source, displayName: name, select: false)
        }
        guard let conversation = conversations.first(where: { $0.destinationHash == source }), let body = String(data: message.content, encoding: .utf8) else { return false }
        messages.append(Message(conversationID: conversation.id, body: body, timestamp: Date(timeIntervalSince1970: message.timestamp), direction: .incoming, state: .delivered))
        noteIncomingActivity(in: conversation.id)
        receivedLXMFIDs.insert(message.messageID.hex)
        UserDefaults.standard.set(Array(receivedLXMFIDs), forKey: "receivedLXMFMessageIDs")
        save()
        if shouldNotifyIncoming(for: conversation.id) {
            Task { await notifications.notifyIncoming(title: conversation.displayName, body: body) }
        }
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
        let pending = messages.filter { $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued }
        guard !pending.isEmpty else { return }
        let queued = pending.filter { $0.attachments.isEmpty }
        let attachmentMessages = pending.filter { !$0.attachments.isEmpty }
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
        var requiresLink = !attachmentMessages.isEmpty
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
            guard item.attachments.isEmpty else { continue }
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
        for message in attachmentMessages { await advertiseAttachments(for: message, session: session) }
    }

    private func advertiseAttachments(for message: Message, session: ReticulumLinkSession) async {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(nameHash + messagingIdentity.hash)
        for attachment in message.attachments where attachment.state == .local || attachment.state == .queued {
            do {
                let data = try await attachmentStore.read(attachment)
                let envelope = try LXMFResourceEnvelope(filename: attachment.filename, mimeType: attachment.mimeType, messageBody: message.body, sourceHash: sourceHash, groupID: message.id, fileData: data, signingIdentity: messagingIdentity).encode()
                let segments = try ReticulumResourceSegmentPlanner.prepare(data: envelope, session: session, hasMetadata: true)
                guard let first = segments.first else { continue }
                registerOutgoingSegment(first, remaining: Array(segments.dropFirst()), messageID: message.id, attachmentID: attachment.id, session: session)
                updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .transferring, progress: 0)
                try await transmitRawPacket(try session.resourceAdvertisementPacket(first.advertisement))
            } catch {
                updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .failed, progress: 0)
            }
        }
    }

    private func registerOutgoingSegment(_ segment: ReticulumPreparedResourceSegment, remaining: [ReticulumPreparedResourceSegment], messageID: UUID, attachmentID: UUID, session: ReticulumLinkSession) {
        outgoingResources[segment.manifest.resourceHash.hex] = OutgoingResource(
            manifest: segment.manifest, parts: segment.parts, expectedProof: segment.expectedProof,
            messageID: messageID, attachmentID: attachmentID, linkID: session.linkID.hex,
            segmentIndex: segment.index, totalSegments: segment.totalSegments, remainingSegments: remaining
        )
        scheduleResourceTimeout(hash: segment.manifest.resourceHash.hex, incoming: false)
    }

    private func handleResourceRequest(_ plaintext: Data, session: ReticulumLinkSession) {
        guard let request = try? ReticulumResourceRequest(encoded: plaintext), var resource = outgoingResources[request.resourceHash.hex], resource.linkID == session.linkID.hex else { return }
        resource.timeoutToken = UUID()
        outgoingResources[request.resourceHash.hex] = resource
        scheduleResourceTimeout(hash: request.resourceHash.hex, incoming: false)
        Task {
            for requestedHash in request.requestedPartHashes {
                guard let index = resource.manifest.partHashes.firstIndex(of: requestedHash) else { continue }
                do { try await transmitRawPacket(session.resourcePartPacket(resource.parts[index])); resource.sentIndices.insert(index) }
                catch { return }
            }
            if request.wantsMoreHashMap, let last = request.lastKnownMapHash,
               let lastIndex = resource.manifest.partHashes.firstIndex(of: last) {
                let segment = (lastIndex + 1) / ReticulumResourceAdvertisement.hashMapMaximumEntries
                let start = segment * ReticulumResourceAdvertisement.hashMapMaximumEntries
                let end = min(start + ReticulumResourceAdvertisement.hashMapMaximumEntries, resource.manifest.partHashes.count)
                if start < end {
                    let update = try ReticulumResourceHashMapUpdate(resourceHash: resource.manifest.resourceHash, segment: segment, partHashes: Array(resource.manifest.partHashes[start..<end]))
                    try? await transmitRawPacket(try session.resourceHashMapUpdatePacket(update))
                }
            }
            outgoingResources[request.resourceHash.hex] = resource
            let segmentProgress = resource.parts.isEmpty ? 1 : Double(resource.sentIndices.count) / Double(resource.parts.count)
            let progress = (Double(resource.segmentIndex - 1) + segmentProgress) / Double(resource.totalSegments)
            updateAttachment(messageID: resource.messageID, attachmentID: resource.attachmentID, state: .transferring, progress: progress)
        }
    }

    private func receiveResourceProof(_ packet: ReticulumPacket) {
        guard packet.data.count == 64 else { return }
        let hash = Data(packet.data.prefix(32))
        guard let resource = outgoingResources[hash.hex], packet.destinationHash.hex == resource.linkID,
              Data(packet.data.suffix(32)) == resource.expectedProof else { return }
        outgoingResources.removeValue(forKey: hash.hex)
        if let next = resource.remainingSegments.first, let session = activeLinks[resource.linkID] {
            let remaining = Array(resource.remainingSegments.dropFirst())
            registerOutgoingSegment(next, remaining: remaining, messageID: resource.messageID, attachmentID: resource.attachmentID, session: session)
            updateAttachment(messageID: resource.messageID, attachmentID: resource.attachmentID, state: .transferring, progress: Double(resource.segmentIndex) / Double(resource.totalSegments))
            Task { try? await transmitRawPacket(try session.resourceAdvertisementPacket(next.advertisement)) }
            return
        }
        updateAttachment(messageID: resource.messageID, attachmentID: resource.attachmentID, state: .available, progress: 1)
        if let message = messages.first(where: { $0.id == resource.messageID }), message.attachments.allSatisfy({ $0.state == .available }) {
            updateMessage(resource.messageID, state: .delivered)
        }
    }

    private func acceptResourceAdvertisement(_ plaintext: Data, session: ReticulumLinkSession) {
        guard let advertisement = try? ReticulumResourceAdvertisement(encoded: plaintext),
              advertisement.flags & 0x01 == 0x01, advertisement.flags & 0x20 == 0x20,
              incomingResources.count < ReticulumResourceLimits.maximumConcurrentIncoming,
              ReticulumResourceLimits.accepts(dataSize: advertisement.dataSize, transferSize: advertisement.transferSize, segments: advertisement.totalSegments),
              !receivedResourceHashes.contains(advertisement.resourceHash.hex),
              let manifest = try? ReticulumResourceManifest(advertisement: advertisement) else { return }
        incomingResources[manifest.resourceHash.hex] = IncomingResource(session: session, advertisement: advertisement, receiver: ReticulumResourceReceiver(manifest: manifest))
        incomingResourceProgress[advertisement.originalHash.hex] = Double(advertisement.segmentIndex - 1) / Double(advertisement.totalSegments)
        scheduleResourceTimeout(hash: manifest.resourceHash.hex, incoming: true)
        requestIncomingResourceParts(resourceHash: manifest.resourceHash.hex)
    }

    private func requestIncomingResourceParts(resourceHash: String) {
        guard let incoming = incomingResources[resourceHash],
              let request = try? incoming.receiver.nextRequest() else { return }
        Task { try? await transmitRawPacket(try incoming.session.resourceRequestPacket(request)) }
    }

    private func handleResourceHashMapUpdate(_ plaintext: Data, session: ReticulumLinkSession) {
        guard let update = try? ReticulumResourceHashMapUpdate(encoded: plaintext),
              var incoming = incomingResources[update.resourceHash.hex], incoming.session.linkID == session.linkID else { return }
        do { try incoming.receiver.applyHashMap(segment: update.segment, hashes: update.partHashes) } catch { return }
        incoming.timeoutToken = UUID()
        incomingResources[update.resourceHash.hex] = incoming
        scheduleResourceTimeout(hash: update.resourceHash.hex, incoming: true)
        requestIncomingResourceParts(resourceHash: update.resourceHash.hex)
    }

    private func handleIncomingResourcePart(_ part: Data, session: ReticulumLinkSession) {
        let match = incomingResources.first { _, incoming in
            incoming.session.linkID == session.linkID && incoming.receiver.missingPartIndices.contains { index in
                Data(ReticulumIdentity.fullHash(part + incoming.receiver.manifest.randomHash).prefix(4)) == incoming.receiver.expectedHash(at: index)
            }
        }
        guard let match else { return }
        let hash = match.key
        var incoming = match.value
        guard let index = incoming.receiver.missingPartIndices.first(where: { incoming.receiver.expectedHash(at: $0) == Data(ReticulumIdentity.fullHash(part + incoming.receiver.manifest.randomHash).prefix(4)) }) else { return }
        do { try incoming.receiver.accept(part: part, at: index) } catch { return }
        incoming.timeoutToken = UUID()
        incomingResources[hash] = incoming
        incomingResourceProgress[incoming.advertisement.originalHash.hex] = (Double(incoming.advertisement.segmentIndex - 1) + incoming.receiver.progress) / Double(incoming.advertisement.totalSegments)
        scheduleResourceTimeout(hash: hash, incoming: true)
        if incoming.receiver.isComplete { Task { await finishIncomingResource(resourceHash: hash) } }
        else if incoming.receiver.receivedPartCount.isMultiple(of: 4) { requestIncomingResourceParts(resourceHash: hash) }
    }

    private func finishIncomingResource(resourceHash: String) async {
        guard let incoming = incomingResources.removeValue(forKey: resourceHash),
              let encrypted = try? incoming.receiver.assemble(),
              let data = try? incoming.session.decryptResourcePayload(encrypted),
              incoming.receiver.manifest.validate(data: data) else { return }
        receivedResourceHashes.insert(resourceHash)
        let proof = incoming.receiver.manifest.resourceHash + ReticulumIdentity.fullHash(data + incoming.receiver.manifest.resourceHash)
        try? await transmitRawPacket(Data([0x0f, 0x00]) + incoming.session.linkID + Data([0x05]) + proof)

        let completeData: Data
        if incoming.advertisement.totalSegments > 1 {
            guard (try? await resourceStagingStore.stage(data: data, originalHash: incoming.advertisement.originalHash, segmentIndex: incoming.advertisement.segmentIndex, totalSegments: incoming.advertisement.totalSegments, totalSize: incoming.advertisement.dataSize)) != nil else { return }
            guard await resourceStagingStore.isComplete(originalHash: incoming.advertisement.originalHash),
                  let assembled = try? await resourceStagingStore.assemble(originalHash: incoming.advertisement.originalHash) else { return }
            completeData = assembled
        } else { completeData = data }

        guard let envelope = try? LXMFResourceEnvelope(encoded: completeData),
              let identity = identityForIncomingResource(envelope: envelope, session: incoming.session) else { return }
        let expectedNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        guard envelope.sourceHash == ReticulumIdentity.truncatedHash(expectedNameHash + identity.hash), envelope.validate(with: identity),
              let attachment = try? await attachmentStore.save(data: envelope.fileData, filename: envelope.filename, mimeType: envelope.mimeType) else { return }
        let source = envelope.sourceHash.hex
        if !conversations.contains(where: { $0.destinationHash == source }) {
            let name = discoveries.first(where: { $0.destinationHash == source })?.announcedDisplayName ?? "Received \(source.prefix(8))"
            _ = addConversation(destinationHash: source, displayName: name, select: false)
        }
        guard let conversation = conversations.first(where: { $0.destinationHash == source }) else { return }
        if let index = messages.firstIndex(where: { $0.id == envelope.groupID && $0.conversationID == conversation.id }) {
            messages[index].attachments.append(attachment)
        } else {
            messages.append(Message(id: envelope.groupID, conversationID: conversation.id, body: envelope.messageBody, direction: .incoming, state: .delivered, attachments: [attachment]))
            noteIncomingActivity(in: conversation.id)
        }
        incomingResourceProgress.removeValue(forKey: incoming.advertisement.originalHash.hex)
        save()
        if shouldNotifyIncoming(for: conversation.id) {
            await notifications.notifyIncoming(title: conversation.displayName, body: envelope.messageBody.isEmpty ? envelope.filename : envelope.messageBody)
        }
    }

    private func identityForIncomingResource(envelope: LXMFResourceEnvelope, session: ReticulumLinkSession) -> ReticulumIdentity? {
        if let identity = inboundRemoteIdentities[session.linkID.hex] { return identity }
        return discoveries.first(where: { $0.destinationHash == envelope.sourceHash.hex })?.publicKey.flatMap { try? ReticulumIdentity(publicKey: $0) }
    }

    private func scheduleResourceTimeout(hash: String, incoming: Bool) {
        let token = incoming ? incomingResources[hash]?.timeoutToken : outgoingResources[hash]?.timeoutToken
        guard let token else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.expireResource(hash: hash, token: token, incoming: incoming)
        }
    }

    private func expireResource(hash: String, token: UUID, incoming: Bool) async {
        if incoming {
            guard let resource = incomingResources[hash], resource.timeoutToken == token else { return }
            incomingResources.removeValue(forKey: hash)
            try? await transmitRawPacket(try resource.session.resourceCancelPacket(resourceHash: resource.receiver.manifest.resourceHash, initiatedBySender: false))
        } else {
            guard let resource = outgoingResources[hash], resource.timeoutToken == token else { return }
            outgoingResources.removeValue(forKey: hash)
            updateAttachment(messageID: resource.messageID, attachmentID: resource.attachmentID, state: .failed, progress: 0)
            if let session = activeLinks[resource.linkID] { try? await transmitRawPacket(try session.resourceCancelPacket(resourceHash: resource.manifest.resourceHash, initiatedBySender: true)) }
        }
    }

    private func cancelResource(hash: String) {
        if let outgoing = outgoingResources.removeValue(forKey: hash) { updateAttachment(messageID: outgoing.messageID, attachmentID: outgoing.attachmentID, state: .failed, progress: 0) }
        incomingResources.removeValue(forKey: hash)
    }

    private func updateAttachment(messageID: UUID, attachmentID: UUID, state: Attachment.TransferState, progress: Double) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let attachmentIndex = messages[messageIndex].attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        messages[messageIndex].attachments[attachmentIndex].state = state
        messages[messageIndex].attachments[attachmentIndex].progress = progress
        if state == .failed { messages[messageIndex].state = .failed }
        save()
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
        sortConversations()
    }

    private func sortConversations() {
        conversations.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func noteIncomingActivity(in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if !isApplicationActive || visibleConversationID != conversationID {
            conversations[index].unreadCount += 1
        }
        touch(conversationID)
        syncUnreadBadge()
    }

    private func syncUnreadBadge() {
        let count = totalUnreadCount
        Task { await notifications.setBadgeCount(count) }
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
        sortConversations()
        messages = snapshot.messages
        for index in messages.indices where messages[index].direction == .outgoing && messages[index].state == .sent {
            messages[index].state = .queued
            recoveredOutboundCount += 1
        }
        for messageIndex in messages.indices where messages[messageIndex].direction == .outgoing {
            for attachmentIndex in messages[messageIndex].attachments.indices where messages[messageIndex].attachments[attachmentIndex].state == .transferring {
                messages[messageIndex].attachments[attachmentIndex].state = .queued
                messages[messageIndex].attachments[attachmentIndex].progress = 0
                messages[messageIndex].state = .queued
                recoveredOutboundCount += 1
            }
        }
        discoveries = snapshot.discoveries
        let conversationIDs = Set(conversations.map(\.id))
        drafts = snapshot.drafts.filter { conversationIDs.contains($0.key) }
        selectedConversationID = conversations.first?.id
        if recoveredOutboundCount > 0 { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.sideband.encode(AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries, drafts: drafts))
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
