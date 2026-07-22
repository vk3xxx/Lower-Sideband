import Foundation
import Observation
import CryptoKit

public enum NetworkConnectionMode: String, CaseIterable, Sendable {
    case automatic
    case configured

    public var title: String {
        switch self {
        case .automatic: "Automatic discovery"
        case .configured: "Configured gateway first"
        }
    }
}

public enum PaperMessageImportResult: Equatable, Sendable {
    case imported(conversationID: UUID)
    case duplicate
    case notAddressedToThisIdentity
    case unknownSender
    case invalid
}

public enum PaperMessageError: LocalizedError {
    case messageNotFound, incomingMessage, attachmentsUnsupported, unknownRecipient

    public var errorDescription: String? {
        switch self {
        case .messageNotFound: "The selected message no longer exists."
        case .incomingMessage: "Only messages you sent can be exported as paper messages."
        case .attachmentsUnsupported: "Paper messages currently support text and telemetry, but not attachments."
        case .unknownRecipient: "A validated identity announce from this contact is required before encrypting a paper message."
        }
    }
}

@MainActor @Observable
public final class SidebandStore {
    public private(set) var conversations: [Conversation] = []
    public private(set) var messages: [Message] = [] {
        didSet {
            messageIndexesAreDirty = true
            transcriptCache.removeAll(keepingCapacity: true)
        }
    }
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
    public private(set) var lastDeliveryAnnounceAt: Date?
    public private(set) var inboundLinksAccepted = 0
    public private(set) var opportunisticDeliveriesReceived = 0
    public private(set) var lastPropagationSync: Date?
    public private(set) var lastNetworkReadyAt: Date?
    public private(set) var automaticConnectionDescription = "Idle"
    public private(set) var deliveryTimeoutCount = 0
    public private(set) var reconnectDelaySeconds: Int?
    public private(set) var recoveredOutboundCount = 0
    public private(set) var lastBackgroundRefreshAt: Date?
    public private(set) var lastBackgroundRefreshSucceeded: Bool?
    public private(set) var incomingResourceProgress: [String: Double] = [:]
    public private(set) var isApplicationActive = true
    public private(set) var visibleConversationID: UUID?
    public private(set) var iCloudSyncEnabled = false
    public private(set) var iCloudSyncStatus: ICloudSyncStatus = .disabled
    public private(set) var lastICloudSync: Date?
    public private(set) var voiceCall: VoiceCall?
    public private(set) var voiceCallHistory: [VoiceCall] = []
    public private(set) var pluginConfigurationRevision = 0
    public private(set) var pluginAuditEvents: [SidebandPluginAuditEvent] = []
    public private(set) var secureStorageAvailable = true
    public private(set) var voiceTrustedOnly: Bool
    public private(set) var richTextTrustedOnly: Bool
    public private(set) var preferredVoiceProfile: LXSTVoice.Profile
    public private(set) var preferredVoiceMessageMode: LXMFVoiceMessageAudio.Mode
    public private(set) var telemetryRespondToTrustedRequests: Bool
    public private(set) var telemetryCollectorEnabled: Bool
    public private(set) var telemetryCollectorHash: String
    public private(set) var telemetryCollectorLatestOnly: Bool
    public var networkHost: String
    public var networkIPv6Host: String
    public var networkInternetHost: String
    public var networkInternetPort: Int
    public var networkPort: Int
    public var preferIPv6: Bool
    public var autoConnectEnabled: Bool
    public private(set) var connectionMode: NetworkConnectionMode
    public var internetOnlyEnabled: Bool
    public var autoInterfaceEnabled: Bool
    public private(set) var transportInstanceEnabled: Bool
    public private(set) var transportInstanceSnapshot = ReticulumTransportSnapshot(
        enabled: false, knownRoutes: 0, forwardedPackets: 0, duplicatePackets: 0,
        ignoredPackets: 0, lastForwardedAt: nil
    )
    public var propagationNodeHash: String
    public private(set) var propagationNodeIsAutomatic: Bool
    public private(set) var discoveredPropagationNodeCount = 0
    public private(set) var localDisplayName: String
    public let lanDiscovery = LANGatewayDiscovery()
    public let autoInterfaceDiscovery = AutoInterfaceDiscovery()
    public let reachability = NetworkReachability()
    public let notifications = LocalNotificationManager()
    public let privacyLock = AppPrivacyLock()
    public let backgroundRefresh = BackgroundRefreshCoordinator()
    public let runtimeHealth = SidebandRuntimeHealth()
    public let rnodeManager = RNodeManager()
    public let pluginRegistry: SidebandPluginRegistry
    public let attachmentStore: AttachmentStore
    public private(set) var attachmentStorageReport: AttachmentStorageReport?
    public let resourceStagingStore: ReticulumResourceStagingStore
    public private(set) var selectedGatewayName: String?
    public private(set) var activeNetworkHost: String?
    public private(set) var activeNetworkPort: Int?
    public private(set) var networkInterfaces: [ReticulumTCPInterfacePool.Snapshot] = []
    public private(set) var discoveredNetworkInterfaces: [DiscoveredReticulumInterface] = []
    public private(set) var lastQuarantinedPersistenceURL: URL?
    public var selectedConversationID: UUID?
    public var lastError: String?

    private let transport: any MessageTransport
    private let persistenceURL: URL
    private let localDataCipher: LocalDataCipher
    private let cloudSync: any CloudSnapshotSyncing
    private let syncDeviceID: String
    private var iCloudSyncTask: Task<Void, Never>?
    private var discoverySaveTask: Task<Void, Never>?
    private var deferredSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastValidatedPersistenceData: Data?
    @ObservationIgnored private var lastSavedSnapshotDigest: Data?
    @ObservationIgnored private var messageIndexesAreDirty = true
    @ObservationIgnored private var messagesByConversation: [UUID: [Message]] = [:]
    @ObservationIgnored private var latestMessageByConversation: [UUID: Message] = [:]
    @ObservationIgnored private var failedMessageCountByConversation: [UUID: Int] = [:]
    @ObservationIgnored private var latestMessageDateByConversation: [UUID: Date] = [:]
    @ObservationIgnored private var reactionCountsByConversationAndTarget: [UUID: [Data: [String: Int]]] = [:]
    @ObservationIgnored private var messageStatistics = MessageStatistics()
    @ObservationIgnored private var transcriptCache: [UUID: String] = [:]
    @ObservationIgnored private var cloudUploadedAttachmentHashes: [UUID: Data] = [:]
    @ObservationIgnored private var deletedConversationDestinations: [String: Date] = [:]
    private var iCloudSyncInProgress = false
    private var isApplyingCloudSnapshot = false
    private var networkInterfacePool: ReticulumTCPInterfacePool?
    private var knownTCPInterfaceIDs: Set<String> = []
    private var tcpNetworkState: ReticulumTCPInterface.State = .stopped
    private var autoConnectedDiscoveredInterfaceIDs: Set<String> = []
    private var networkConnectionGeneration = UUID()
    private let pathTable = ReticulumPathTable()
    private var pendingLinks: [String: ReticulumLinkRequest] = [:]
    private var pendingLinkTimeoutTokens: [String: UUID] = [:]
    private var deferredLinkRetryTokens: [String: UUID] = [:]
    private var activeLinks: [String: ReticulumLinkSession] = [:]
    private var linkRemoteDestinations: [String: String] = [:]
    private var linkInterfaceIDs: [String: String] = [:]
    private enum ReceiptKind: Hashable { case direct, opportunistic, propagation }
    private struct PendingReceipt { let messageID: UUID; let kind: ReceiptKind; let destinationHash: String }
    private var pendingReceipts: [String: PendingReceipt] = [:]
    private var receiptTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var receiptRetryTasks: [String: Task<Void, Never>] = [:]
    private var pendingReceiptRetryKinds: [String: Set<ReceiptKind>] = [:]
    private var directLinkFallbackDestinations: Set<String> = []
    private var deliveryPassesInProgress: Set<UUID> = []
    private var deliveryPassRerunRequested: Set<UUID> = []
    private struct OutgoingResource {
        let manifest: ReticulumResourceManifest; let parts: [Data]; let expectedProof: Data
        let messageID: UUID; let attachmentID: UUID?; let linkID: String
        let segmentIndex: Int; let totalSegments: Int; let remainingSegments: [ReticulumPreparedResourceSegment]
        var timeoutToken = UUID()
        var sentIndices: Set<Int> = []
    }
    private var outgoingResources: [String: OutgoingResource] = [:]
    private struct IncomingResource { let session: ReticulumLinkSession; let advertisement: ReticulumResourceAdvertisement; var receiver: ReticulumResourceReceiver; var timeoutToken = UUID() }
    private var incomingResources: [String: IncomingResource] = [:]
    private var receivedResourceHashes: Set<String> = []
    private var receivedResourceProofs: [String: Data] = [:]
    private enum PropagationRequestKind { case list, download }
    private var pendingPropagationRequests: [String: PropagationRequestKind] = [:]
    private var receivedLXMFIDs: Set<String> = []
    private var lastCommandResponseAt: [UUID: Date] = [:]
    private var inboundRemoteIdentities: [String: ReticulumIdentity] = [:]
    private var inboundLinkIDs: Set<String> = []
    private var voiceLinkIDs: Set<String> = []
    private var pendingVoiceConversations: [String: UUID] = [:]
    private var pendingVoicePublicKeys: [String: Data] = [:]
    private var activeVoiceLinkID: String?
    private var voiceCallTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var voiceFrameHandler: ((LXSTVoice.Codec, Data) -> Void)?
    private var propagationSyncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var attemptedGatewayIDs: Set<String> = []
    private var attemptedConfiguredGatewayIDs: Set<String> = []
    private var attemptedInternetGatewayIDs: Set<String> = []
    private var observedLANDiscoveryGrace = false
    private var activeGatewayID: String?
    private var activeInternetGatewayID: String?
    private var pendingLANGatewaySwitchID: String?
    private var preferredGatewayID: String?
    private var preferredInternetGatewayID: String?
    public private(set) var gatewayHealth: [String: GatewayHealthRecord] = [:]
    private var networkConnectionStartedAt: Date?
    private var deferredPathRequests: Set<String> = []
    private var intentionallyDisconnected = false
    private var reconnectAttempt = 0
    private let transportIdentity: ReticulumIdentity
    private let tcpInterfaceHash: Data
    private var messagingIdentity: ReticulumIdentity
    @ObservationIgnored private lazy var transportInstance = ReticulumTransportInstance(identityHash: transportIdentity.hash)

    private struct MessageStatistics {
        var incoming = 0
        var outgoing = 0
        var queued = 0
        var sent = 0
        var delivered = 0
        var failed = 0
        var reactions = 0
        var starred = 0
    }

    public init(transport: any MessageTransport = QueuedTransport(), persistenceURL: URL? = nil, cloudSync: (any CloudSnapshotSyncing)? = nil, plugins: [any SidebandCommandPlugin] = [SidebandInfoPlugin()]) {
        self.transport = transport
        pluginRegistry = SidebandPluginRegistry(plugins: plugins)
        #if DEBUG
        let soakPersistenceURL = ProcessInfo.processInfo.environment["SIDEBAND_SOAK_RUN_ID"].map { runID in
            let safeID = runID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return FileManager.default.temporaryDirectory
                .appending(path: "LowerSidebandDeliverySoak", directoryHint: .isDirectory)
                .appending(path: safeID.isEmpty ? "default" : safeID, directoryHint: .isDirectory)
                .appending(path: "sideband.json")
        }
        #else
        let soakPersistenceURL: URL? = nil
        #endif
        self.persistenceURL = persistenceURL ?? soakPersistenceURL ?? Self.defaultPersistenceURL()
        localDataCipher = LocalDataCipher()
        self.cloudSync = cloudSync ?? CloudKitSnapshotSync()
        let existingDeviceID = UserDefaults.standard.string(forKey: "iCloudSyncDeviceID")
        syncDeviceID = existingDeviceID ?? UUID().uuidString
        UserDefaults.standard.set(syncDeviceID, forKey: "iCloudSyncDeviceID")
        let cloudEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        iCloudSyncEnabled = cloudEnabled
        iCloudSyncStatus = cloudEnabled ? .ready : .disabled
        lastICloudSync = UserDefaults.standard.object(forKey: "iCloudLastSuccessfulSync") as? Date
        attachmentStore = AttachmentStore(directory: self.persistenceURL.deletingLastPathComponent().appending(path: "Attachments", directoryHint: .isDirectory))
        resourceStagingStore = ReticulumResourceStagingStore(directory: self.persistenceURL.deletingLastPathComponent().appending(path: "ResourceStaging", directoryHint: .isDirectory))
        let transportMaterial = SecureIdentityStore.loadOrCreate(account: "reticulum.transport", legacyDefaultsKey: "reticulumTransportIdentity")
        switch transportMaterial {
        case .success(let material): transportIdentity = (try? ReticulumIdentity(privateKey: material)) ?? ReticulumIdentity()
        case .failure: transportIdentity = ReticulumIdentity(); secureStorageAvailable = false
        }
        let interfaceMaterial = UserDefaults.standard.data(forKey: "reticulumTCPInterfaceHash") ?? ReticulumIdentity.fullHash(Data(UUID().uuidString.utf8))
        tcpInterfaceHash = interfaceMaterial
        UserDefaults.standard.set(interfaceMaterial, forKey: "reticulumTCPInterfaceHash")
        #if DEBUG
        let deliveryTestIdentityAccount = ProcessInfo.processInfo.environment["SIDEBAND_SOAK_IDENTITY_ACCOUNT"]
            .map { "lxmf.messaging.delivery-test.\($0)" }
        let deliveryTestIdentity = ProcessInfo.processInfo.environment["SIDEBAND_SOAK_IDENTITY_HEX"]
            .flatMap(Data.init(hexadecimal:))
            .flatMap { try? ReticulumIdentity(privateKey: $0) }
        #else
        let deliveryTestIdentityAccount: String? = nil
        let deliveryTestIdentity: ReticulumIdentity? = nil
        #endif
        let messagingMaterial = SecureIdentityStore.loadOrCreate(
            account: deliveryTestIdentityAccount ?? "lxmf.messaging",
            legacyDefaultsKey: deliveryTestIdentityAccount == nil ? "lxmfMessagingIdentity" : "lxmfMessagingIdentity.delivery-test",
            synchronizable: deliveryTestIdentityAccount == nil
        )
        if let deliveryTestIdentity {
            messagingIdentity = deliveryTestIdentity
        } else {
            switch messagingMaterial {
            case .success(let material): messagingIdentity = (try? ReticulumIdentity(privateKey: material)) ?? ReticulumIdentity()
            case .failure: messagingIdentity = ReticulumIdentity(); secureStorageAvailable = false
            }
        }
        if !localDataCipher.isAvailable { secureStorageAvailable = false }
        networkHost = UserDefaults.standard.string(forKey: "reticulumHost") ?? ""
        networkIPv6Host = UserDefaults.standard.string(forKey: "reticulumIPv6Host") ?? ""
        networkInternetHost = UserDefaults.standard.string(forKey: "reticulumInternetHost") ?? ""
        let savedInternetPort = UserDefaults.standard.integer(forKey: "reticulumInternetPort")
        networkInternetPort = savedInternetPort == 0 ? 4_242 : savedInternetPort
        let savedPort = UserDefaults.standard.integer(forKey: "reticulumPort")
        networkPort = savedPort == 0 ? 4242 : savedPort
        preferIPv6 = UserDefaults.standard.object(forKey: "reticulumPreferIPv6") as? Bool ?? true
        autoConnectEnabled = UserDefaults.standard.object(forKey: "reticulumAutoConnect") as? Bool ?? true
        connectionMode = UserDefaults.standard.string(forKey: "reticulumConnectionMode").flatMap(NetworkConnectionMode.init(rawValue:)) ?? .automatic
        internetOnlyEnabled = UserDefaults.standard.bool(forKey: "reticulumInternetOnly")
        autoInterfaceEnabled = UserDefaults.standard.bool(forKey: "reticulumAutoInterface")
        #if os(macOS)
        transportInstanceEnabled = UserDefaults.standard.bool(forKey: "reticulumTransportInstanceEnabled")
        #else
        transportInstanceEnabled = false
        #endif
        propagationNodeHash = UserDefaults.standard.string(forKey: "lxmfPropagationNode") ?? ""
        propagationNodeIsAutomatic = UserDefaults.standard.object(forKey: "lxmfPropagationNodeAutomatic") as? Bool ?? true
        localDisplayName = UserDefaults.standard.string(forKey: "lxmfLocalDisplayName") ?? "Lower Sideband"
        voiceTrustedOnly = UserDefaults.standard.bool(forKey: "lxstVoiceTrustedOnly")
        richTextTrustedOnly = UserDefaults.standard.object(forKey: "lxmfRichTextTrustedOnly") as? Bool ?? true
        preferredVoiceProfile = LXSTVoice.Profile(rawValue: UInt64(UserDefaults.standard.integer(forKey: "lxstVoiceProfile"))) ?? .mediumQuality
        preferredVoiceMessageMode = LXMFVoiceMessageAudio.Mode(rawValue: UInt8(UserDefaults.standard.integer(forKey: "lxmfVoiceMessageMode"))) ?? .opusOgg
        telemetryRespondToTrustedRequests = UserDefaults.standard.bool(forKey: "telemetryRespondToTrustedRequests")
        telemetryCollectorEnabled = UserDefaults.standard.bool(forKey: "telemetryCollectorEnabled")
        telemetryCollectorHash = UserDefaults.standard.string(forKey: "telemetryCollectorHash") ?? ""
        telemetryCollectorLatestOnly = UserDefaults.standard.object(forKey: "telemetryCollectorLatestOnly") as? Bool ?? true
        lastNetworkReadyAt = UserDefaults.standard.object(forKey: "reticulumLastReadyAt") as? Date
        lastBackgroundRefreshAt = UserDefaults.standard.object(forKey: "sidebandLastBackgroundRefreshAt") as? Date
        lastBackgroundRefreshSucceeded = UserDefaults.standard.object(forKey: "sidebandLastBackgroundRefreshSucceeded") as? Bool
        preferredGatewayID = UserDefaults.standard.string(forKey: "reticulumPreferredGatewayID")
        preferredInternetGatewayID = UserDefaults.standard.string(forKey: "reticulumPreferredInternetGatewayID")
        if let healthData = UserDefaults.standard.data(forKey: "reticulumGatewayHealth"),
           let decoded = try? JSONDecoder.sideband.decode([String: GatewayHealthRecord].self, from: healthData) {
            gatewayHealth = decoded
        }
        receivedLXMFIDs = Set((UserDefaults.standard.stringArray(forKey: "receivedLXMFMessageIDs") ?? []).suffix(SidebandMessageLimits.maximumRememberedMessageIDs))
        if secureStorageAvailable {
            load()
        } else {
            lastError = "Secure Keychain data is temporarily unavailable. Lower Sideband will remain offline and will not read or overwrite encrypted data. Unlock the device and reopen the app."
        }
        autoInterfaceDiscovery.setPacketHandler { [weak self] packet in await self?.receiveFromInterface(packet, interfaceID: "auto") }
        rnodeManager.setHandlers { [weak self] interfaceID, packet in
            await self?.receiveFromInterface(packet, interfaceID: interfaceID)
        } state: { [weak self] in
            self?.refreshAggregateNetworkState()
        }
        lanDiscovery.setUpdateHandler { [weak self] gateways in self?.gatewayResultsChanged(gateways) }
        reachability.setStatusHandler { [weak self] status in self?.reachabilityChanged(status) }
        backgroundRefresh.register { [weak self] in
            guard let self else { return false }
            return await self.performBackgroundRefresh()
        }
        runtimeHealth.start()
        Task { try? await resourceStagingStore.removeStale(olderThan: Date(timeIntervalSinceNow: -86_400)) }
        Task { [weak self] in _ = await self?.cleanOrphanedAttachments() }
        syncUnreadBadge()
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    /// Drops rebuildable indexes and transcript data after an operating-system
    /// memory warning. Encrypted durable messages and attachments are retained.
    public func handleMemoryPressure() {
        transcriptCache.removeAll(keepingCapacity: false)
        messagesByConversation.removeAll(keepingCapacity: false)
        latestMessageByConversation.removeAll(keepingCapacity: false)
        failedMessageCountByConversation.removeAll(keepingCapacity: false)
        latestMessageDateByConversation.removeAll(keepingCapacity: false)
        reactionCountsByConversationAndTarget.removeAll(keepingCapacity: false)
        messageIndexesAreDirty = true
        runtimeHealth.recordMemoryPressure()
    }

    public var localVoiceHash: String { LXSTVoice.destinationHash(for: messagingIdentity).hex }

    public func setVoiceTrustedOnly(_ enabled: Bool) {
        voiceTrustedOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "lxstVoiceTrustedOnly")
    }

    public func setRichTextTrustedOnly(_ enabled: Bool) {
        richTextTrustedOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "lxmfRichTextTrustedOnly")
    }

    public func shouldRenderRichText(_ message: Message, conversationID: UUID) -> Bool {
        guard message.renderer != .plain else { return false }
        if message.direction == .outgoing || !richTextTrustedOnly { return true }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        return conversation.isTrusted || isConversationIdentityVerified(conversationID)
    }

    public func setPreferredVoiceProfile(_ profile: LXSTVoice.Profile) {
        guard profile.isLocallySupported else { return }
        preferredVoiceProfile = profile
        UserDefaults.standard.set(Int(profile.rawValue), forKey: "lxstVoiceProfile")
    }

    public func setPreferredVoiceMessageMode(_ mode: LXMFVoiceMessageAudio.Mode) {
        guard mode == .opusOgg || mode.codec2Mode != nil else { return }
        preferredVoiceMessageMode = mode
        UserDefaults.standard.set(Int(mode.rawValue), forKey: "lxmfVoiceMessageMode")
    }

    public func setTelemetryRespondToTrustedRequests(_ enabled: Bool) {
        telemetryRespondToTrustedRequests = enabled
        UserDefaults.standard.set(enabled, forKey: "telemetryRespondToTrustedRequests")
    }

    public func setTelemetryCollectorEnabled(_ enabled: Bool) {
        telemetryCollectorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "telemetryCollectorEnabled")
    }

    public func setTelemetryCollectorHash(_ destinationHash: String) {
        let normalized = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        telemetryCollectorHash = DestinationHash.isValid(normalized) ? normalized : ""
        UserDefaults.standard.set(telemetryCollectorHash, forKey: "telemetryCollectorHash")
    }

    public func setTelemetryCollectorLatestOnly(_ enabled: Bool) {
        telemetryCollectorLatestOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "telemetryCollectorLatestOnly")
    }

    public func setVoiceFrameHandler(_ handler: ((LXSTVoice.Codec, Data) -> Void)?) { voiceFrameHandler = handler }

    public func startVoiceCall(conversationID: UUID) async {
        guard voiceCall == nil,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              !conversation.isBlocked,
              let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash }),
              let publicKey = discovery.publicKey,
              let remoteIdentity = try? ReticulumIdentity(publicKey: publicKey)
        else {
            lastError = voiceCall == nil ? "A validated identity announce is required before calling this contact." : "Another voice call is already active."
            return
        }
        let call = VoiceCall(conversationID: conversationID, direction: .outgoing, state: .findingRoute, profile: preferredVoiceProfile)
        voiceCall = call
        let voiceDestination = LXSTVoice.destinationHash(for: remoteIdentity)
        if !hasPath(to: voiceDestination.hex) {
            await requestPath(to: voiceDestination.hex)
            let deadline = ContinuousClock.now + .seconds(10)
            while !hasPath(to: voiceDestination.hex), ContinuousClock.now < deadline,
                  voiceCall?.id == call.id, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard voiceCall?.id == call.id, !Task.isCancelled else { return }
        guard hasPath(to: voiceDestination.hex), networkState == .ready else {
            finishVoiceCall(failure: "No route to the contact's LXST voice service.")
            return
        }
        do {
            voiceCall?.state = .connecting
            let request = try ReticulumLinkRequest(destinationHash: voiceDestination)
            let linkID = request.linkID.hex
            pendingLinks[linkID] = request
            pendingVoiceConversations[linkID] = conversationID
            pendingVoicePublicKeys[linkID] = publicKey
            pendingLinkTimeoutTokens[linkID] = UUID()
            try await transmitDestinationPacket(request.rawPacket, destinationHash: voiceDestination)
            scheduleVoiceTimeout(callID: call.id, seconds: 70)
        } catch {
            finishVoiceCall(failure: "Could not establish the encrypted voice link.")
        }
    }

    public func answerVoiceCall() async {
        guard var call = voiceCall, call.direction == .incoming, call.state == .incoming,
              let linkID = activeVoiceLinkID, let session = activeLinks[linkID] else { return }
        call.state = .connecting
        voiceCall = call
        do {
            try await sendVoiceSignal(.connecting, on: session)
            call.state = .active
            call.connectedAt = .now
            voiceCall = call
            try await sendVoiceSignal(.established, on: session)
        } catch { finishVoiceCall(failure: "Voice call setup failed.") }
    }

    public func declineVoiceCall() async {
        guard let linkID = activeVoiceLinkID, let session = activeLinks[linkID] else { finishVoiceCall(); return }
        try? await sendVoiceSignal(.rejected, on: session)
        await closeVoiceLink(session)
        finishVoiceCall()
    }

    public func hangUpVoiceCall() async {
        guard voiceCall != nil else { return }
        voiceCall?.state = .ending
        if let linkID = activeVoiceLinkID, let session = activeLinks[linkID] { await closeVoiceLink(session) }
        finishVoiceCall()
    }

    public func sendVoiceFrame(_ payload: Data) async {
        guard let call = voiceCall, call.state == .active, !payload.isEmpty,
              let linkID = activeVoiceLinkID, let session = activeLinks[linkID] else { return }
        try? await transmitRawPacket(try session.encryptedPacket(LXSTVoice.frame(codec: call.profile.codec, payload: payload)))
    }

    public var automaticBackupURL: URL {
        persistenceURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    public var totalUnreadCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }
    public var incomingMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.incoming }
    public var outgoingMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.outgoing }
    public var queuedMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.queued }
    public var sentMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.sent }
    public var deliveredMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.delivered }
    public var failedMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.failed }
    public var reactionCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.reactions }
    public var starredMessageCount: Int { rebuildMessageIndexesIfNeeded(); return messageStatistics.starred }
    public var nextScheduledMessageDate: Date? { messages.compactMap(\.scheduledFor).filter { $0 > .now }.min() }
    public func dueQueuedMessageCount(at date: Date = .now) -> Int {
        messages.count { $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= date }
    }
    public var activeAttachmentTransferCount: Int {
        messages.reduce(0) { count, message in
            count + message.attachments.count(where: { $0.state == .queued || $0.state == .transferring })
        }
    }
    public func attachmentBytes(for conversationID: UUID) -> Int {
        messages(for: conversationID).flatMap(\.attachments).reduce(0) { $0 + max(0, $1.byteCount) }
    }

    public func refreshAttachmentStorageReport() async {
        attachmentStorageReport = await attachmentStore.storageReport(for: messages.flatMap(\.attachments))
    }

    @discardableResult
    public func cleanupOrphanedAttachmentFiles() async -> Int {
        let paths = Set(messages.flatMap(\.attachments).map(\.relativePath))
        let removed = (try? await attachmentStore.removeOrphans(referencedRelativePaths: paths)) ?? 0
        await refreshAttachmentStorageReport()
        return removed
    }

    @discardableResult
    public func removeFailedAttachmentMetadata() async -> Int {
        var removed = 0
        for messageIndex in messages.indices {
            let failed = messages[messageIndex].attachments.filter { $0.state == .failed }
            for attachment in failed { try? await attachmentStore.remove(attachment) }
            removed += failed.count
            messages[messageIndex].attachments.removeAll { $0.state == .failed }
        }
        if removed > 0 { save() }
        await refreshAttachmentStorageReport()
        return removed
    }

    public var attachmentStorageDiagnostics: String {
        guard let report = attachmentStorageReport else { return "Attachment storage has not been inspected this session." }
        return [
            "Attachments: \(report.attachmentCount)",
            "Logical payload: \(ByteCountFormatter.string(fromByteCount: Int64(report.logicalBytes), countStyle: .file))",
            "Encrypted storage: \(ByteCountFormatter.string(fromByteCount: Int64(report.storedBytes), countStyle: .file))",
            "Missing: \(report.missingCount)",
            "Corrupt: \(report.corruptCount)",
            "Orphans: \(report.orphanCount) (\(ByteCountFormatter.string(fromByteCount: Int64(report.orphanBytes), countStyle: .file)))"
        ].joined(separator: "\n")
    }
    public var deliverySuccessRate: Double? {
        let terminal = deliveredMessageCount + failedMessageCount
        return terminal == 0 ? nil : Double(deliveredMessageCount) / Double(terminal)
    }

    public func messages(for conversationID: UUID) -> [Message] {
        rebuildMessageIndexesIfNeeded()
        return messagesByConversation[conversationID] ?? []
    }

    public func latestMessage(for conversationID: UUID) -> Message? {
        rebuildMessageIndexesIfNeeded()
        return latestMessageByConversation[conversationID]
    }

    public func failedMessageCount(for conversationID: UUID) -> Int {
        rebuildMessageIndexesIfNeeded()
        return failedMessageCountByConversation[conversationID] ?? 0
    }

    /// Returns pre-indexed reaction counts without rescanning an entire
    /// conversation for every visible message row.
    public func reactionCounts(for messageID: Data?, in conversationID: UUID) -> [String: Int] {
        guard let messageID else { return [:] }
        rebuildMessageIndexesIfNeeded()
        return reactionCountsByConversationAndTarget[conversationID]?[messageID] ?? [:]
    }

    public func starredMessages(for conversationID: UUID) -> [Message] {
        messages(for: conversationID).filter(\.isStarred)
    }

    public func setMessageStarred(_ starred: Bool, messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].isStarred != starred else { return }
        messages[index].isStarred = starred
        messages[index].starredUpdatedAt = .now
        save()
    }

    public func conversationTranscript(_ conversationID: UUID) -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        rebuildMessageIndexesIfNeeded()
        if let cached = transcriptCache[conversationID] { return cached }
        let formatter = ISO8601DateFormatter()
        let lines = (messagesByConversation[conversationID] ?? []).map { message in
            let sender = message.direction == .outgoing ? "Me" : conversation.displayName
            let attachments = message.attachments.map { "[Attachment: \($0.filename)]" }.joined(separator: " ")
            let telemetry = message.telemetry?.location.map {
                "[Location: \($0.latitude.formatted(.number.precision(.fractionLength(6)))), \($0.longitude.formatted(.number.precision(.fractionLength(6)))) ±\($0.accuracy.formatted(.number.precision(.fractionLength(0))))m]"
            } ?? ""
            return "[\(formatter.string(from: message.timestamp))] \(sender): \([message.body, attachments, telemetry].filter { !$0.isEmpty }.joined(separator: " "))"
        }
        let transcript = (["Conversation with \(conversation.displayName)", "Destination: \(conversation.destinationHash)", ""] + lines).joined(separator: "\n")
        if transcriptCache.count >= 64, let oldestKey = transcriptCache.keys.first {
            transcriptCache.removeValue(forKey: oldestKey)
        }
        transcriptCache[conversationID] = transcript
        return transcript
    }

    public func conversationDeliveryDiagnostics(_ conversationID: UUID) -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        let conversationMessages = messages(for: conversationID)
        let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash })
        let latest = conversationMessages.max(by: { $0.timestamp < $1.timestamp })
        let queued = conversationMessages.count(where: { $0.direction == .outgoing && $0.state == .queued })
        let sent = conversationMessages.count(where: { $0.direction == .outgoing && $0.state == .sent })
        let delivered = conversationMessages.count(where: { $0.direction == .outgoing && $0.state == .delivered })
        let failed = conversationMessages.count(where: { $0.direction == .outgoing && $0.state == .failed })
        return [
            "Lower Sideband Conversation Delivery Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: .now))",
            "Contact: \(conversation.displayName)",
            "Destination: \(conversation.destinationHash)",
            "Identity key: \(identityFingerprint(for: conversationID) == nil ? "unknown" : (isConversationIdentityVerified(conversationID) ? "fingerprint verified" : "fingerprint available, not verified"))",
            "Network: \(networkState == .ready ? "ready" : "not ready")",
            "Path: \(hasPath(to: conversation.destinationHash) ? "available" : (isPathPending(to: conversation.destinationHash) ? "requested" : "unknown"))",
            "Announce: \(discovery == nil ? "not received" : "\(discovery!.isValidated ? "validated" : "unverified"), \(discovery!.hops) hop(s), \(discovery!.packetCount) packet(s)")",
            "Link: \(activeLinkHashes.contains(conversation.destinationHash) ? "active" : (pendingLinkHashes.contains(conversation.destinationHash) ? "establishing" : "inactive"))",
            "Delivery policy: \(conversation.deliveryPreference == .propagationPreferred ? "prefer propagation" : "automatic direct with propagation fallback")",
            "Propagation node: \(DestinationHash.isValid(propagationNodeHash) ? (propagationNodeHasPath ? "reachable" : "configured, path unknown") : "not configured")",
            "Outgoing states: \(queued) queued, \(sent) sent, \(delivered) delivered, \(failed) failed",
            "Latest message: \(latest.map { "\($0.direction.rawValue), \($0.state.rawValue), \(ISO8601DateFormatter().string(from: $0.timestamp))" } ?? "none")",
            "Latest delivery attempt: \(latest?.lastDeliveryAttemptAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
            "Latest delivery mode: \(latest?.lastDeliveryMode?.rawValue ?? "none")",
            "Latest delivery failure: \(latest?.lastDeliveryFailure ?? "none")"
        ].joined(separator: "\n")
    }

    public func exportConversationData(_ conversationID: UUID) throws -> Data {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { throw SnapshotError.invalidData }
        let archive = SidebandConversationExport(
            conversation: conversation,
            fingerprint: identityFingerprint(for: conversationID),
            messages: messages(for: conversationID)
        )
        return try JSONEncoder.sideband.encode(archive)
    }

    /// Imports a portable conversation archive without granting trust or
    /// re-queuing historical outbound messages. Attachment payloads are not
    /// embedded in the archive, so their metadata is retained as unavailable.
    @discardableResult
    public func importConversationData(_ data: Data) throws -> Int {
        guard data.count <= 256 * 1_024 * 1_024 else { throw SnapshotError.invalidData }
        let archive = try JSONDecoder.sideband.decode(SidebandConversationExport.self, from: data)
        guard archive.version <= SidebandConversationExport.currentVersion,
              archive.messages.count <= 250_000,
              DestinationHash.isValid(archive.contact.destinationHash) else { throw SnapshotError.unsupportedVersion }
        let destination = archive.contact.destinationHash.lowercased()
        var seenIDs = Set(messages.map(\.id))
        var seenLXMFIDs = Set(messages.compactMap(\.lxmfID))
        guard addConversation(destinationHash: destination, displayName: String(archive.contact.displayName.prefix(128))),
              let conversation = conversations.first(where: { $0.destinationHash == destination }) else {
            throw SnapshotError.invalidData
        }
        var inserted = 0
        for item in archive.messages {
            guard !seenIDs.contains(item.id), item.lxmfID.map({ !seenLXMFIDs.contains($0) }) ?? true else { continue }
            guard item.body.count <= SidebandMessageLimits.maximumTextCharacters,
                  item.attachments.count <= SidebandMessageLimits.maximumAttachments,
                  item.attachments.allSatisfy({
                      !$0.filename.isEmpty && $0.filename.count <= 180 &&
                      (0...ReticulumResourceLimits.maximumAttachmentBytes).contains($0.byteCount) &&
                      ($0.contentHash == nil || $0.contentHash?.count == 32)
                  }),
                  item.attachments.reduce(0, { $0 + $1.byteCount }) <= SidebandMessageLimits.maximumCombinedAttachmentBytes else { continue }
            let attachments = item.attachments.map { attachment in
                Attachment(
                    filename: attachment.filename, mimeType: attachment.mimeType,
                    byteCount: attachment.byteCount, relativePath: "missing-\(UUID().uuidString).sbenc",
                    state: .failed, progress: 0, contentHash: attachment.contentHash
                )
            }
            let safeState: Message.DeliveryState = item.direction == .outgoing && (item.state == .queued || item.state == .sent)
                ? .failed : item.state
            messages.append(Message(
                id: item.id, conversationID: conversation.id, body: item.body,
                timestamp: item.timestamp, direction: item.direction, state: safeState,
                attachments: attachments, telemetry: item.telemetry, renderer: item.renderer,
                lxmfID: item.lxmfID, replyTo: item.replyTo, replyQuote: item.replyQuote,
                reactionTo: item.reactionTo, reactionContent: item.reactionContent,
                commentTo: item.commentTo, continuationOf: item.continuationOf,
                commands: item.commands ?? [], deliveryAttemptCount: item.deliveryAttemptCount ?? 0,
                lastDeliveryAttemptAt: item.lastDeliveryAttemptAt, lastDeliveryMode: item.lastDeliveryMode,
                lastDeliveryFailure: safeState == item.state ? item.lastDeliveryFailure : "Imported archive item; not queued",
                isStarred: item.isStarred ?? false, scheduledFor: nil
            ))
            seenIDs.insert(item.id)
            if let lxmfID = item.lxmfID { seenLXMFIDs.insert(lxmfID) }
            inserted += 1
        }
        if inserted > 0 {
            touch(conversation.id)
            sortConversations()
            save()
        }
        return inserted
    }

    public func exportContactCollectionData() throws -> Data {
        let contacts = conversations.map { conversation in
            SidebandContactCollection.Contact(
                destinationHash: conversation.destinationHash,
                displayName: conversation.displayName,
                publicKey: identityPublicKey(for: conversation.id),
                wasIdentityVerified: isConversationIdentityVerified(conversation.id),
                contactNote: conversation.contactNote,
                appearanceColor: conversation.appearanceColor,
                appearanceSymbol: conversation.appearanceSymbol,
                tags: conversation.tags
            )
        }
        return try JSONEncoder.sideband.encode(SidebandContactCollection(contacts: contacts))
    }

    @discardableResult
    public func importContactCollectionData(_ data: Data) throws -> Int {
        let collection = try JSONDecoder.sideband.decode(SidebandContactCollection.self, from: data)
        guard collection.version <= SidebandContactCollection.currentVersion, collection.contacts.count <= 10_000 else {
            throw SnapshotError.unsupportedVersion
        }
        let previousSelection = selectedConversationID
        var imported = 0
        for contact in collection.contacts {
            guard let link = SidebandContactLink(
                destinationHash: contact.destinationHash,
                displayName: String(contact.displayName.prefix(128)),
                publicKey: contact.publicKey
            ) else { continue }
            if openContactLink(link.url) {
                if let existing = conversations.first(where: { $0.destinationHash == link.destinationHash }),
                   contact.contactNote != nil || contact.appearanceColor != nil || contact.appearanceSymbol != nil || contact.tags != nil {
                    setConversationAppearance(
                        conversationID: existing.id,
                        note: contact.contactNote ?? existing.contactNote,
                        color: contact.appearanceColor ?? existing.appearanceColor,
                        symbol: contact.appearanceSymbol ?? existing.appearanceSymbol
                    )
                    if let tags = contact.tags { setConversationTags(tags, conversationID: existing.id) }
                }
                imported += 1
            }
        }
        if let previousSelection, conversations.contains(where: { $0.id == previousSelection }) {
            selectedConversationID = previousSelection
        }
        if imported == 0 { throw SnapshotError.invalidData }
        return imported
    }

    public func paperMessageURI(for messageID: UUID) throws -> String {
        guard let message = messages.first(where: { $0.id == messageID }),
              let conversation = conversations.first(where: { $0.id == message.conversationID }) else {
            throw PaperMessageError.messageNotFound
        }
        guard message.direction == .outgoing else { throw PaperMessageError.incomingMessage }
        guard message.attachments.isEmpty else { throw PaperMessageError.attachmentsUnsupported }
        guard let publicKey = discoveries.first(where: { $0.destinationHash == conversation.destinationHash && $0.isValidated })?.publicKey,
              let recipientIdentity = try? ReticulumIdentity(publicKey: publicKey),
              let destinationHash = Data(hexadecimal: conversation.destinationHash),
              let sourceHash = Data(hexadecimal: localDeliveryHash) else { throw PaperMessageError.unknownRecipient }
        let lxmf = try LXMFMessage(
            destinationHash: destinationHash,
            sourceHash: sourceHash,
            sourceIdentity: messagingIdentity,
            timestamp: message.timestamp.timeIntervalSince1970,
            content: Data(message.body.utf8),
            fields: lxmfFields(for: message),
            encodedFields: lxmfEncodedFields(for: message)
        )
        return try lxmf.paperURI(recipientIdentity: recipientIdentity)
    }

    @discardableResult
    public func ingestPaperMessageURI(_ uri: String) -> PaperMessageImportResult {
        guard let paperPacked = try? LXMURI.decode(uri), paperPacked.count > 16 else { return .invalid }
        let destinationHash = Data(paperPacked.prefix(16))
        guard destinationHash.hex == localDeliveryHash else { return .notAddressedToThisIdentity }
        guard let decrypted = try? messagingIdentity.decrypt(Data(paperPacked.dropFirst(16))),
              let message = try? LXMFReceivedMessage(packed: destinationHash + decrypted) else { return .invalid }
        if receivedLXMFIDs.contains(message.messageID.hex) { return .duplicate }
        guard let publicKey = discoveries.first(where: { $0.destinationHash == message.sourceHash.hex && $0.isValidated })?.publicKey,
              let sourceIdentity = try? ReticulumIdentity(publicKey: publicKey),
              message.validate(with: sourceIdentity) else { return .unknownSender }
        guard importReceivedMessage(message, sourceIdentity: sourceIdentity),
              let conversation = conversations.first(where: { $0.destinationHash == message.sourceHash.hex }) else { return .invalid }
        selectedConversationID = conversation.id
        return .imported(conversationID: conversation.id)
    }

    public func conversationContactCard(_ conversationID: UUID) -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        var lines = [
            "Lower Sideband Contact",
            "Name: \(conversation.displayName)",
            "LXMF Destination: \(conversation.destinationHash)",
            "Trusted: \(conversation.isTrusted ? "yes" : "no")"
        ]
        if let fingerprint = identityFingerprint(for: conversationID) {
            lines.append("Identity Fingerprint: \(fingerprint)")
            lines.append("Identity Verified: \(isConversationIdentityVerified(conversationID) ? "yes" : "no")")
        }
        if let link = contactLink(for: conversationID) {
            lines.append("Contact Link: \(link.url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }

    public func contactLink(for conversationID: UUID) -> SidebandContactLink? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        let publicKey = discoveries.first(where: { $0.destinationHash == conversation.destinationHash && $0.isValidated })?.publicKey
        return SidebandContactLink(destinationHash: conversation.destinationHash, displayName: conversation.displayName, publicKey: publicKey)
    }

    public func identityPublicKey(for conversationID: UUID) -> Data? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        return discoveries.first(where: { $0.destinationHash == conversation.destinationHash && $0.isValidated })?.publicKey
            ?? conversation.verifiedIdentityKey
    }

    public func identityFingerprint(for conversationID: UUID) -> String? {
        identityPublicKey(for: conversationID).flatMap { ReticulumIdentity.fingerprint(of: $0) }
    }

    public func isConversationIdentityVerified(_ conversationID: UUID) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let verified = conversation.verifiedIdentityKey,
              conversation.identityVerifiedAt != nil,
              let current = identityPublicKey(for: conversationID) else { return false }
        return verified == current
    }

    @discardableResult
    public func setConversationIdentityVerified(_ verified: Bool, conversationID: UUID) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        if verified {
            guard let key = identityPublicKey(for: conversationID) else {
                lastError = "Receive or scan this contact's verified public identity before marking it verified."
                return false
            }
            conversations[index].verifiedIdentityKey = key
            conversations[index].identityVerifiedAt = .now
        } else {
            conversations[index].verifiedIdentityKey = nil
            conversations[index].identityVerifiedAt = nil
        }
        save()
        return true
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
        let clearedDeletion = deletedConversationDestinations.removeValue(forKey: hash) != nil
        if let existing = conversations.first(where: { $0.destinationHash == hash }) {
            if select {
                if let index = conversations.firstIndex(where: { $0.id == existing.id }) {
                    conversations[index].isArchived = false
                }
                selectedConversationID = existing.id
                touch(existing.id)
                save()
            } else if clearedDeletion {
                save()
            }
            return true
        }
        let conversation = Conversation(destinationHash: hash, displayName: displayName.isEmpty ? abbreviated(hash) : displayName)
        conversations.insert(conversation, at: 0)
        if select { selectedConversationID = conversation.id }
        save()
        return true
    }

    @discardableResult
    public func forgetDiscovery(_ destinationHash: String) -> Bool {
        let normalized = destinationHash.lowercased()
        guard !conversations.contains(where: { $0.destinationHash == normalized }),
              ![localDeliveryHash, localVoiceHash, propagationNodeHash].contains(normalized),
              let index = discoveries.firstIndex(where: { $0.destinationHash == normalized }) else { return false }
        discoveries.remove(at: index)
        save()
        return true
    }

    @discardableResult
    public func pruneDiscoveries(olderThan age: TimeInterval, now: Date = .now) -> Int {
        guard age >= 0 else { return 0 }
        let protected = Set(conversations.map(\.destinationHash)).union([localDeliveryHash, localVoiceHash, propagationNodeHash])
        let before = discoveries.count
        discoveries.removeAll { discovery in
            !protected.contains(discovery.destinationHash) && now.timeIntervalSince(discovery.lastSeen) > age
        }
        let removed = before - discoveries.count
        if removed > 0 { save() }
        return removed
    }

    @discardableResult
    public func openContactLink(_ url: URL) -> Bool {
        guard let contact = SidebandContactLink(url: url) else {
            lastError = "This is not a valid Lower Sideband contact link."
            return false
        }
        if let publicKey = contact.publicKey {
            if let conversation = conversations.first(where: { $0.destinationHash == contact.destinationHash }),
               let verifiedKey = conversation.verifiedIdentityKey,
               verifiedKey != publicKey {
                lastError = "This contact link does not match the identity key you previously verified."
                return false
            }
            let appData = contact.displayName.map { ReticulumAnnounceBuilder.lxmfAppData(displayName: $0) }
            if let index = discoveries.firstIndex(where: { $0.destinationHash == contact.destinationHash }) {
                discoveries[index].publicKey = publicKey
                discoveries[index].isValidated = true
                discoveries[index].lastSeen = .now
                if let appData { discoveries[index].appData = appData }
            } else {
                discoveries.insert(DiscoveredDestination(
                    destinationHash: contact.destinationHash,
                    hops: 0,
                    isValidated: true,
                    publicKey: publicKey,
                    appData: appData
                ), at: 0)
            }
        }
        return addConversation(destinationHash: contact.destinationHash, displayName: contact.displayName ?? "")
    }

    public func markConversationRead(_ conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if conversations[index].unreadCount > 0 {
            conversations[index].unreadCount = 0
            save()
            syncUnreadBadge()
        }
        Task { await notifications.removeNotifications(for: conversationID) }
    }

    public func openConversationFromNotification(_ conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isArchived = false
        selectedConversationID = conversationID
        touch(conversationID)
        markConversationRead(conversationID)
        save()
    }

    public func markConversationUnread(_ conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = max(1, conversations[index].unreadCount)
        save()
        syncUnreadBadge()
    }

    @discardableResult
    public func markAllConversationsRead() -> Int {
        let unreadIDs = conversations.filter { $0.unreadCount > 0 }.map(\.id)
        guard !unreadIDs.isEmpty else { return 0 }
        for index in conversations.indices { conversations[index].unreadCount = 0 }
        save()
        syncUnreadBadge()
        Task {
            for conversationID in unreadIDs { await notifications.removeNotifications(for: conversationID) }
        }
        return unreadIDs.count
    }

    @discardableResult
    public func archiveReadConversations() -> Int {
        let candidates = conversations.indices.filter {
            !conversations[$0].isArchived && !conversations[$0].isPinned && conversations[$0].unreadCount == 0
        }
        guard !candidates.isEmpty else { return 0 }
        for index in candidates { conversations[index].isArchived = true }
        if let selectedConversationID,
           conversations.first(where: { $0.id == selectedConversationID })?.isArchived == true {
            self.selectedConversationID = conversations.first(where: { !$0.isArchived })?.id
        }
        save()
        return candidates.count
    }

    @discardableResult
    public func unarchiveAllConversations() -> Int {
        let archived = conversations.indices.filter { conversations[$0].isArchived }
        guard !archived.isEmpty else { return 0 }
        for index in archived { conversations[index].isArchived = false }
        sortConversations()
        save()
        return archived.count
    }

    public func conversationMatchesSearch(_ conversationID: UUID, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        if conversation.displayName.localizedCaseInsensitiveContains(needle)
            || conversation.destinationHash.localizedCaseInsensitiveContains(needle)
            || conversation.contactNote.localizedCaseInsensitiveContains(needle)
            || conversation.tags.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
        return messages(for: conversationID).contains { message in
            message.body.localizedCaseInsensitiveContains(needle)
                || (message.replyQuote?.localizedCaseInsensitiveContains(needle) ?? false)
                || message.attachments.contains { $0.filename.localizedCaseInsensitiveContains(needle) }
        }
    }

    @discardableResult
    public func renameConversation(_ conversationID: UUID, to displayName: String) -> Bool {
        let name = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        guard !name.isEmpty, let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        guard conversations[index].displayName != name else { return true }
        conversations[index].displayName = name
        conversations[index].updatedAt = .now
        transcriptCache.removeValue(forKey: conversationID)
        sortConversations()
        save()
        return true
    }

    public func deleteConversation(_ conversationID: UUID) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let removedMessages = messages.filter { $0.conversationID == conversationID }
        deletedConversationDestinations[conversation.destinationHash] = .now
        if deletedConversationDestinations.count > 10_000 {
            deletedConversationDestinations = Dictionary(uniqueKeysWithValues:
                deletedConversationDestinations.sorted { $0.value > $1.value }.prefix(10_000).map { ($0.key, $0.value) }
            )
        }
        messages.removeAll { $0.conversationID == conversationID }
        drafts.removeValue(forKey: conversationID)
        conversations.removeAll { $0.id == conversationID }
        if visibleConversationID == conversationID { visibleConversationID = nil }
        if selectedConversationID == conversationID { selectedConversationID = conversations.first?.id }
        save()
        syncUnreadBadge()

        for message in removedMessages {
            for attachment in message.attachments {
                await cancelActiveResources(messageID: message.id, attachmentID: attachment.id)
                try? await attachmentStore.remove(attachment)
            }
        }
    }

    public func clearConversationHistory(_ conversationID: UUID) async {
        let removedMessages = messages.filter { $0.conversationID == conversationID }
        for message in removedMessages {
            for attachment in message.attachments {
                await cancelActiveResources(messageID: message.id, attachmentID: attachment.id)
                try? await attachmentStore.remove(attachment)
            }
        }
        messages.removeAll { $0.conversationID == conversationID }
        markConversationRead(conversationID)
        save()
    }

    public func telemetryMessageCount(for conversationID: UUID) -> Int {
        messages.lazy.filter { $0.conversationID == conversationID && $0.telemetry != nil }.count
    }

    @discardableResult
    public func clearTelemetryHistory(_ conversationID: UUID) -> Int {
        let indices = messages.indices.filter { messages[$0].conversationID == conversationID && messages[$0].telemetry != nil }
        guard !indices.isEmpty else { return 0 }
        for index in indices { messages[index].telemetry = nil }
        save()
        return indices.count
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

    public func setConversationArchived(_ archived: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isArchived = archived
        if archived { conversations[index].isPinned = false }
        save()
    }

    public func setConversationBlocked(_ blocked: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isBlocked = blocked
        if blocked { conversations[index].notificationsMuted = true }
        save()
    }

    public func setConversationNotificationsMuted(_ muted: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].notificationsMuted = muted
        save()
    }

    public func setConversationNotificationPreview(_ enabled: Bool?, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].notificationPreviewEnabled = enabled
        conversations[index].updatedAt = .now
        save()
    }

    public func shouldShowNotificationPreview(for conversationID: UUID) -> Bool {
        conversations.first(where: { $0.id == conversationID })?.notificationPreviewEnabled ?? notifications.showPreviews
    }

    public func setConversationTelemetrySharing(_ enabled: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].telemetrySharingEnabled = enabled
        save()
    }

    public func setConversationPluginCommands(_ enabled: Bool, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].pluginCommandsEnabled = enabled
        save()
    }

    public func setConversationAppearance(conversationID: UUID, note: String, color: Conversation.AppearanceColor, symbol: Conversation.AppearanceSymbol) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].contactNote = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        conversations[index].appearanceColor = color
        conversations[index].appearanceSymbol = symbol
        conversations[index].updatedAt = .now
        save()
    }

    public func setConversationTags(_ proposedTags: [String], conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var seen: Set<String> = []
        let tags = proposedTags.compactMap { raw -> String? in
            let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
        conversations[index].tags = Array(tags.prefix(8))
        conversations[index].updatedAt = .now
        save()
    }

    public func setPluginEnabled(_ enabled: Bool, identifier: String) {
        pluginRegistry.setEnabled(enabled, identifier: identifier)
        pluginConfigurationRevision &+= 1
    }

    public func isPluginEnabled(_ identifier: String) -> Bool {
        _ = pluginConfigurationRevision
        return pluginRegistry.isEnabled(identifier)
    }

    public func clearPluginAuditHistory() {
        pluginAuditEvents.removeAll()
        save()
    }

    public func setConversationDeliveryPreference(_ preference: Conversation.DeliveryPreference, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].deliveryPreference = preference
        conversations[index].updatedAt = .now
        save()
        if preference == .propagationPreferred { Task { await attemptDelivery(for: conversationID) } }
    }

    public func shouldNotifyIncoming(for conversationID: UUID) -> Bool {
        guard conversations.first(where: { $0.id == conversationID })?.notificationsMuted == false else { return false }
        return !isApplicationActive || visibleConversationID != conversationID
    }

    public func isSourceBlocked(_ destinationHash: String) -> Bool {
        conversations.first(where: { $0.destinationHash == destinationHash.lowercased() })?.isBlocked == true
    }

    public func conversationDidAppear(_ conversationID: UUID) {
        visibleConversationID = conversationID
        if isApplicationActive { markConversationRead(conversationID) }
    }

    public func conversationDidDisappear(_ conversationID: UUID) {
        if visibleConversationID == conversationID { visibleConversationID = nil }
    }

    @discardableResult
    public func send(_ text: String) async -> Bool {
        await send(text, attachments: [], telemetry: nil)
    }

    @discardableResult
    public func send(_ text: String, attachments: [Attachment], telemetry: SidebandTelemetry? = nil, voiceAudio: LXMFVoiceMessageAudio? = nil, replyingTo repliedMessage: Message? = nil, renderer requestedRenderer: Message.Renderer = .plain, scheduledFor: Date? = nil) async -> Bool {
        guard let conversationID = selectedConversationID else { return false }
        return await send(text, to: conversationID, attachments: attachments, telemetry: telemetry, voiceAudio: voiceAudio, replyingTo: repliedMessage, renderer: requestedRenderer, scheduledFor: scheduledFor)
    }

    @discardableResult
    public func send(_ text: String, to conversationID: UUID, attachments: [Attachment] = [], telemetry: SidebandTelemetry? = nil, voiceAudio: LXMFVoiceMessageAudio? = nil, replyingTo repliedMessage: Message? = nil, renderer requestedRenderer: Message.Renderer = .plain, scheduledFor: Date? = nil) async -> Bool {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var renderer = requestedRenderer
        if body.hasPrefix("#!md\n") {
            body.removeFirst(5)
            renderer = .markdown
        }
        guard (!body.isEmpty || !attachments.isEmpty || telemetry != nil || voiceAudio != nil), let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        guard !conversation.isBlocked else {
            lastError = "Unblock this contact before sending a message."
            return false
        }
        guard telemetry == nil || conversation.telemetrySharingEnabled else {
            lastError = "Telemetry sharing is disabled for this contact."
            return false
        }
        guard body.count <= SidebandMessageLimits.maximumTextCharacters,
              body.utf8.count <= SidebandMessageLimits.maximumTextBytes else {
            lastError = "Messages are limited to \(SidebandMessageLimits.maximumTextCharacters.formatted()) characters."
            return false
        }
        guard attachments.count <= SidebandMessageLimits.maximumAttachments else {
            lastError = "Messages are limited to \(SidebandMessageLimits.maximumAttachments) attachments."
            return false
        }
        guard telemetry == nil || attachments.isEmpty else {
            lastError = "Send telemetry separately from file attachments."
            return false
        }
        if let telemetryError = telemetry?.validationError {
            lastError = telemetryError
            return false
        }
        guard validateAttachmentTotal(attachments) else { return false }
        if let scheduledFor, scheduledFor < Date.now.addingTimeInterval(30) || scheduledFor > Date.now.addingTimeInterval(366 * 24 * 60 * 60) {
            lastError = "Scheduled messages must be between one minute and one year in the future."
            return false
        }
        let message = Message(
            conversationID: conversation.id, body: body, direction: .outgoing, state: .queued,
            attachments: attachments, telemetry: telemetry, voiceAudio: voiceAudio, renderer: renderer,
            replyTo: repliedMessage?.lxmfID,
            replyQuote: repliedMessage.map { replyQuote(for: $0) },
            commentTo: repliedMessage?.lxmfID,
            outboxOwnerID: syncDeviceID, outboxOwnerUpdatedAt: .now, scheduledFor: scheduledFor
        )
        messages.append(message)
        touch(conversation.id)
        save()
        if scheduledFor == nil { await attemptDelivery(for: conversation.id) }
        else { backgroundRefresh.schedule(earliest: scheduledFor) }
        return true
    }

    public func sendScheduledMessageNow(_ messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID && $0.direction == .outgoing && $0.state == .queued && $0.scheduledFor != nil }) else { return }
        messages[index].scheduledFor = nil
        messages[index].outboxOwnerID = syncDeviceID
        messages[index].outboxOwnerUpdatedAt = .now
        let conversationID = messages[index].conversationID
        save()
        await attemptDelivery(for: conversationID)
    }

    public func cancelScheduledMessage(_ messageID: UUID) async {
        guard messages.contains(where: { $0.id == messageID && $0.state == .queued && $0.scheduledFor != nil }) else { return }
        await deleteMessage(messageID)
    }

    public func sendReaction(_ content: String, to target: Message) async {
        let reaction = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetHash = target.lxmfID,
              target.conversationID == selectedConversationID,
              let conversation = selectedConversation,
              !conversation.isBlocked else {
            lastError = "Reactions require a delivered LXMF message in the open conversation."
            return
        }
        guard Message.isValidReaction(content: reaction, target: targetHash) else {
            lastError = "A reaction must contain between 1 and 8 characters."
            return
        }
        guard !messages.contains(where: {
            $0.conversationID == conversation.id && $0.direction == .outgoing &&
            $0.reactionTo == targetHash && $0.reactionContent == reaction
        }) else { return }
        let message = Message(
            conversationID: conversation.id,
            body: "",
            direction: .outgoing,
            state: .queued,
            reactionTo: targetHash,
            reactionContent: reaction,
            outboxOwnerID: syncDeviceID,
            outboxOwnerUpdatedAt: .now
        )
        messages.append(message)
        touch(conversation.id)
        save()
        await attemptDelivery(for: conversation.id)
    }

    public func sendCommand(_ command: LXMFCommand, conversationID: UUID) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              !conversation.isBlocked else {
            lastError = "Unblock this contact before sending a command request."
            return
        }
        if case let .echo(value) = command,
           value.isEmpty || value.count > LXMFCommand.maximumEchoCharacters {
            lastError = "Echo requests are limited to \(LXMFCommand.maximumEchoCharacters) characters."
            return
        }
        let message = Message(
            conversationID: conversationID,
            body: "",
            direction: .outgoing,
            state: .queued,
            commands: [command],
            outboxOwnerID: syncDeviceID,
            outboxOwnerUpdatedAt: .now
        )
        messages.append(message)
        save()
        await attemptDelivery(for: conversationID)
    }

    public func requestTelemetry(conversationID: UUID, since: Date = Date(timeIntervalSince1970: 0), collector: Bool = false) async {
        await sendCommand(.telemetryRequest(timebase: since, collector: collector), conversationID: conversationID)
    }

    public func sendPluginCommand(_ command: String, arguments: [String] = [], conversationID: UUID) async {
        guard SidebandPluginCommandLine.encode(command: command, arguments: arguments) != nil else {
            lastError = "Plugin command names, arguments or total payload are invalid."
            return
        }
        await sendCommand(.plugin(command: command, arguments: arguments), conversationID: conversationID)
    }

    public func validateAttachmentSelection(currentCount: Int, adding newCount: Int) -> Bool {
        guard currentCount + newCount <= SidebandMessageLimits.maximumAttachments else {
            lastError = "Messages are limited to \(SidebandMessageLimits.maximumAttachments) attachments."
            return false
        }
        return true
    }

    public func validateAttachmentIsUnique(_ candidate: Attachment, among existing: [Attachment]) -> Bool {
        let isDuplicate = existing.contains { attachment in
            if let candidateHash = candidate.contentHash, let existingHash = attachment.contentHash {
                return candidateHash == existingHash
            }
            return candidate.filename == attachment.filename && candidate.byteCount == attachment.byteCount
        }
        guard !isDuplicate else {
            lastError = "\(candidate.filename) is already attached."
            return false
        }
        return true
    }

    public func validateAttachmentTotal(_ attachments: [Attachment]) -> Bool {
        let total = attachments.reduce(0) { $0 + $1.byteCount }
        guard total <= SidebandMessageLimits.maximumCombinedAttachmentBytes else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(SidebandMessageLimits.maximumCombinedAttachmentBytes), countStyle: .file)
            lastError = "Combined attachments are limited to \(limit) per message."
            return false
        }
        return true
    }

    public func reportAttachmentImportFailure(filename: String, error: Error) {
        lastError = "Could not attach \(filename): \(error.localizedDescription)"
    }

    public func retryAttachment(messageID: UUID, attachmentID: UUID) async {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let attachmentIndex = messages[messageIndex].attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        await cancelActiveResources(messageID: messageID, attachmentID: attachmentID)
        messages[messageIndex].attachments[attachmentIndex].state = .queued
        messages[messageIndex].attachments[attachmentIndex].progress = 0
        messages[messageIndex].state = .queued
        messages[messageIndex].outboxOwnerID = syncDeviceID
        messages[messageIndex].outboxOwnerUpdatedAt = .now
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
        messages[index].outboxOwnerID = syncDeviceID
        messages[index].outboxOwnerUpdatedAt = .now
        let conversationID = messages[index].conversationID
        save()
        await attemptDelivery(for: conversationID)
    }

    public func retryAllFailedMessages(in conversationID: UUID) async {
        let failedIndices = messages.indices.filter {
            messages[$0].conversationID == conversationID && messages[$0].direction == .outgoing && messages[$0].state == .failed
        }
        guard !failedIndices.isEmpty else { return }
        for index in failedIndices {
            messages[index].state = .queued
            messages[index].outboxOwnerID = syncDeviceID
            messages[index].outboxOwnerUpdatedAt = .now
            for attachmentIndex in messages[index].attachments.indices where messages[index].attachments[attachmentIndex].state == .failed {
                messages[index].attachments[attachmentIndex].state = .queued
                messages[index].attachments[attachmentIndex].progress = 0
            }
        }
        save()
        await attemptDelivery(for: conversationID)
    }

    public func retryAllFailedMessages() async {
        let conversationIDs = Set(messages.lazy.filter {
            $0.direction == .outgoing && $0.state == .failed
        }.map(\.conversationID))
        for conversationID in conversationIDs { await retryAllFailedMessages(in: conversationID) }
    }

    public func flushQueuedMessages() async {
        let conversationIDs = Set(messages.lazy.filter {
            $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= .now && self.ownsOutbox($0)
        }.map(\.conversationID))
        for conversationID in conversationIDs { await attemptDelivery(for: conversationID) }
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

    /// Removes a message from local and synced history. This does not recall a
    /// copy that has already been delivered to another LXMF destination.
    public func deleteMessage(_ messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[index]
        for attachment in message.attachments {
            await cancelActiveResources(messageID: messageID, attachmentID: attachment.id)
            try? await attachmentStore.remove(attachment)
        }
        pendingReceipts = pendingReceipts.filter { $0.value.messageID != messageID }
        messages.remove(at: index)
        if let conversationIndex = conversations.firstIndex(where: { $0.id == message.conversationID }) {
            conversations[conversationIndex].updatedAt = latestMessage(for: message.conversationID)?.timestamp ?? .now
        }
        sortConversations()
        save()
    }

    @discardableResult
    public func forwardMessage(_ messageID: UUID, to conversationID: UUID) async -> Bool {
        guard let source = messages.first(where: { $0.id == messageID }),
              let destination = conversations.first(where: { $0.id == conversationID }),
              !destination.isBlocked else { return false }
        var forwardedAttachments: [Attachment] = []
        do {
            for attachment in source.attachments {
                let data = try await attachmentStore.read(attachment)
                var copy = try await attachmentStore.save(data: data, filename: attachment.filename, mimeType: attachment.mimeType)
                copy.state = .local
                copy.progress = 0
                forwardedAttachments.append(copy)
            }
        } catch {
            for attachment in forwardedAttachments { try? await attachmentStore.remove(attachment) }
            lastError = "Could not forward the attachment: \(error.localizedDescription)"
            return false
        }
        let forwarded = Message(
            conversationID: conversationID,
            body: source.body,
            direction: .outgoing,
            state: .queued,
            attachments: forwardedAttachments,
            telemetry: source.telemetry,
            renderer: source.renderer,
            outboxOwnerID: syncDeviceID,
            outboxOwnerUpdatedAt: .now
        )
        messages.append(forwarded)
        touch(conversationID)
        selectedConversationID = conversationID
        save()
        await attemptDelivery(for: conversationID)
        return true
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
        await transportInstance.setEnabled(transportInstanceEnabled)
        transportInstanceSnapshot = await transportInstance.snapshot()
    }

    public func clearError() { lastError = nil }

    #if DEBUG
    public func removeDeliverySoakMessages() {
        let soakConversationIDs = Set(messages.filter { $0.body.hasPrefix("SOAK-") }.map(\.conversationID))
        messages.removeAll { $0.body.hasPrefix("SOAK-") }
        for conversationID in soakConversationIDs { touch(conversationID) }
        save()
    }
    #endif

    public func connectNetwork(forceIPv4: Bool = false, explicitHost: String? = nil, explicitPort: UInt16? = nil, internetGatewayID: String? = nil) async {
        guard secureStorageAvailable else {
            lastError = "Secure Keychain data is unavailable. Reopen Lower Sideband after unlocking the device."
            return
        }
        guard tcpNetworkState != .connecting, tcpNetworkState != .ready else { return }
        let useIPv6 = !forceIPv4 && preferIPv6 && reachability.supportsIPv6 && !networkIPv6Host.isEmpty
        let selectedHost = explicitHost ?? (useIPv6 ? networkIPv6Host : networkHost)
        let selectedPort = explicitPort ?? UInt16(exactly: networkPort)
        guard !selectedHost.isEmpty, let port = selectedPort, port > 0 else {
            lastError = "Enter a valid TCP host and port."
            return
        }
        tcpNetworkState = .connecting
        refreshAggregateNetworkState()
        networkConnectionStartedAt = .now
        let generation = UUID()
        networkConnectionGeneration = generation
        await networkInterfacePool?.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionallyDisconnected = false
        activeGatewayID = nil
        activeInternetGatewayID = internetGatewayID
        autoConnectedDiscoveredInterfaceIDs.removeAll()
        selectedGatewayName = nil
        UserDefaults.standard.set(networkHost, forKey: "reticulumHost")
        UserDefaults.standard.set(networkIPv6Host, forKey: "reticulumIPv6Host")
        UserDefaults.standard.set(networkInternetHost, forKey: "reticulumInternetHost")
        UserDefaults.standard.set(networkInternetPort, forKey: "reticulumInternetPort")
        UserDefaults.standard.set(networkPort, forKey: "reticulumPort")
        UserDefaults.standard.set(preferIPv6, forKey: "reticulumPreferIPv6")
        UserDefaults.standard.set(autoConnectEnabled, forKey: "reticulumAutoConnect")
        let endpoints: [ReticulumTCPInterfacePool.Endpoint]
        if let internetGatewayID {
            let publicGateways = PublicReticulumGateways.ordered(
                customHost: networkInternetHost,
                customPort: networkInternetPort,
                preferredID: internetGatewayID,
                health: gatewayHealth
            )
            endpoints = Array(publicGateways.prefix(3)).map {
                ReticulumTCPInterfacePool.Endpoint(id: $0.id, name: $0.name, host: $0.host, port: $0.port, isBootstrap: true)
            }
            activeNetworkHost = "\(endpoints.count) public gateways"
            activeNetworkPort = nil
        } else {
            let id = "\(selectedHost.lowercased()):\(port)"
            endpoints = [ReticulumTCPInterfacePool.Endpoint(id: id, name: selectedHost, host: selectedHost, port: port)]
            activeNetworkHost = selectedHost
            activeNetworkPort = Int(port)
        }
        let pool = makeInterfacePool(generation: generation)
        networkInterfacePool = pool
        await pool.start(endpoints)
    }

    public func disconnectNetwork() async {
        intentionallyDisconnected = true
        deferredLinkRetryTokens.removeAll()
        reconnectAttempt = 0
        reconnectDelaySeconds = nil
        networkConnectionGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        automaticConnectionDescription = "Disconnected"
        stopPeriodicPropagationSync()
        resetLinkState()
        await networkInterfacePool?.stop()
        await rnodeManager.stopAll()
        networkInterfacePool = nil
        networkInterfaces = []
        autoConnectedDiscoveredInterfaceIDs.removeAll()
        tcpNetworkState = .stopped
        refreshAggregateNetworkState()
        activeNetworkHost = nil
        activeNetworkPort = nil
    }

    public func reconnectNetwork() async {
        await disconnectNetwork()
        await startAutomaticConnection()
    }

    public func applicationDidBecomeActive() async {
        await pluginRegistry.startEnabledServices()
        isApplicationActive = true
        if let visibleConversationID { markConversationRead(visibleConversationID) }
        // Re-evaluate every configured transport on foregrounding. The aggregate
        // state may already be ready through a radio while the TCP pool still
        // needs to reconnect (or vice versa).
        if autoConnectEnabled { await startAutomaticConnection() }
        if autoInterfaceEnabled, !autoInterfaceDiscovery.isListening { autoInterfaceDiscovery.start() }
        startPeriodicPropagationSync()
        await syncPropagationNow()
        if networkState == .ready { await flushQueuedMessages() }
        if iCloudSyncEnabled { await syncICloudNow() }
    }

    public func applicationDidBecomeInactive() {
        isApplicationActive = false
        Task { await attachmentStore.removeAllMaterializedFiles() }
    }

    public func applicationDidEnterBackground() {
        isApplicationActive = false
        flushDeferredSave()
        stopPeriodicPropagationSync()
        backgroundRefresh.schedule(earliest: nextScheduledMessageDate)
    }

    private func performBackgroundRefresh() async -> Bool {
        let startedAt = Date.now
        defer {
            lastBackgroundRefreshAt = startedAt
            UserDefaults.standard.set(startedAt, forKey: "sidebandLastBackgroundRefreshAt")
            if let lastBackgroundRefreshSucceeded {
                UserDefaults.standard.set(lastBackgroundRefreshSucceeded, forKey: "sidebandLastBackgroundRefreshSucceeded")
            }
        }
        if autoConnectEnabled, networkState != .ready { await startAutomaticConnection() }
        let deadline = ContinuousClock.now + .seconds(10)
        while networkState != .ready, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard networkState == .ready, !Task.isCancelled else {
            lastBackgroundRefreshSucceeded = false
            backgroundRefresh.schedule()
            return false
        }
        await announceLocalDeliveryDestination()
        await syncPropagationNow()
        await flushQueuedMessages()
        for conversation in conversations { await propagateQueued(for: conversation.id) }
        if iCloudSyncEnabled { await syncICloudNow() }
        lastBackgroundRefreshSucceeded = !Task.isCancelled
        backgroundRefresh.schedule()
        return !Task.isCancelled
    }

    /// Performs the bounded work allowed after an iOS silent wake. The push
    /// contains no message data; it only prompts a Reticulum reconnect and an
    /// end-to-end encrypted LXMF propagation sync.
    @discardableResult
    public func performRemoteWakeSync() async -> Bool {
        if autoConnectEnabled, networkState != .ready { await startAutomaticConnection() }
        let networkDeadline = ContinuousClock.now + .seconds(12)
        while networkState != .ready, ContinuousClock.now < networkDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard networkState == .ready, !Task.isCancelled else {
            backgroundRefresh.schedule()
            return false
        }

        await announceLocalDeliveryDestination()
        guard !Task.isCancelled else { return false }
        if DestinationHash.isValid(propagationNodeHash) {
            if !propagationNodeHasPath { await requestPropagationNodePath() }
            if propagationNodeHasPath,
               !pendingLinkHashes.contains(propagationNodeHash),
               !activeLinkHashes.contains(propagationNodeHash) {
                await requestLink(to: propagationNodeHash)
            }
        }
        await syncPropagationNow()
        guard !Task.isCancelled else { return false }
        for conversation in conversations {
            guard !Task.isCancelled else { return false }
            await attemptDelivery(for: conversation.id)
            await propagateQueued(for: conversation.id)
        }
        if iCloudSyncEnabled { await syncICloudNow() }
        backgroundRefresh.schedule()
        return true
    }

    public func setICloudSyncEnabled(_ enabled: Bool) async {
        iCloudSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "iCloudSyncEnabled")
        if enabled {
            iCloudSyncStatus = .checkingAccount
            await syncICloudNow()
        } else {
            iCloudSyncTask?.cancel()
            iCloudSyncTask = nil
            iCloudSyncStatus = .disabled
        }
    }

    public func syncICloudNow() async {
        guard iCloudSyncEnabled, !iCloudSyncInProgress else { return }
        iCloudSyncInProgress = true
        iCloudSyncStatus = .checkingAccount
        defer { iCloudSyncInProgress = false }
        guard await cloudSync.accountAvailable() else {
            iCloudSyncStatus = .unavailable("Sign in to iCloud to sync devices")
            return
        }
        iCloudSyncStatus = .syncing
        do {
            let local = AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries, drafts: drafts, voiceCallHistory: voiceCallHistory, deletedConversationDestinations: deletedConversationDestinations)
            let localData = try JSONEncoder.sideband.encode(local)
            var merged: AppSnapshot
            let remotePayload = try await cloudSync.fetchSnapshot()
            if let payload = remotePayload {
                let remote = try validatedSnapshot(from: payload.data)
                merged = local.mergingCloudSnapshot(remote)
            } else {
                merged = local
            }
            merged = await synchronizeCloudAttachments(in: merged, local: local)
            let mergedData = try JSONEncoder.sideband.encode(merged)
            if mergedData != localData {
                isApplyingCloudSnapshot = true
                applyCloudSnapshot(merged)
                save()
                isApplyingCloudSnapshot = false
                syncUnreadBadge()
            }
            let now = Date()
            // Avoid creating a new CloudKit record version on every app
            // activation when the canonical snapshot bytes are unchanged.
            if remotePayload?.data != mergedData {
                try await cloudSync.saveSnapshot(CloudSnapshotPayload(data: mergedData, modifiedAt: now, deviceID: syncDeviceID))
            }
            lastICloudSync = now
            UserDefaults.standard.set(now, forKey: "iCloudLastSuccessfulSync")
            iCloudSyncStatus = .synced(now)
        } catch {
            isApplyingCloudSnapshot = false
            iCloudSyncStatus = .failed(error.localizedDescription)
        }
    }

    private func synchronizeCloudAttachments(in snapshot: AppSnapshot, local: AppSnapshot) async -> AppSnapshot {
        var uploaded = Set<UUID>()
        var validatedLocally = Set<UUID>()
        for attachment in local.messages.flatMap(\.attachments) where uploaded.insert(attachment.id).inserted {
            guard let data = try? await attachmentStore.read(attachment) else { continue }
            validatedLocally.insert(attachment.id)
            let hash = attachment.contentHash ?? Data(SHA256.hash(data: data))
            if cloudUploadedAttachmentHashes[attachment.id] == hash { continue }
            let payload = CloudAttachmentPayload(
                id: attachment.id, data: data, filename: attachment.filename,
                mimeType: attachment.mimeType, contentHash: hash
            )
            do {
                try await cloudSync.saveAttachment(payload)
                cloudUploadedAttachmentHashes[attachment.id] = hash
            } catch { continue }
        }

        var result = snapshot
        for messageIndex in result.messages.indices {
            for attachmentIndex in result.messages[messageIndex].attachments.indices {
                let attachment = result.messages[messageIndex].attachments[attachmentIndex]
                // Upload processing already performed the authenticated local
                // read; do not decrypt and hash the same large file twice.
                if validatedLocally.contains(attachment.id) { continue }
                if (try? await attachmentStore.read(attachment)) != nil { continue }
                guard let payload = try? await cloudSync.fetchAttachment(id: attachment.id),
                      let restored = try? await attachmentStore.restoreCloudAttachment(payload) else {
                    result.messages[messageIndex].attachments[attachmentIndex].state = .queued
                    result.messages[messageIndex].attachments[attachmentIndex].progress = 0
                    continue
                }
                result.messages[messageIndex].attachments[attachmentIndex] = restored
            }
        }
        let retainedAttachmentIDs = Set(result.messages.flatMap(\.attachments).map(\.id))
        cloudUploadedAttachmentHashes = cloudUploadedAttachmentHashes.filter { retainedAttachmentIDs.contains($0.key) }
        return result
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
        } catch {
            // Periodic propagation sync is best-effort background work. Direct
            // delivery and later sync cycles continue without a modal error.
        }
    }

    private func startPeriodicPropagationSync() {
        guard propagationSyncTask == nil else { return }
        propagationSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.announceLocalDeliveryDestination()
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
        if enabled {
            Task { await startAutomaticConnection() }
        } else {
            reconnectTask?.cancel()
            reconnectTask = nil
            automaticConnectionDescription = "Automatic connection disabled"
        }
    }

    public func setConnectionMode(_ mode: NetworkConnectionMode) {
        guard connectionMode != mode else { return }
        connectionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "reticulumConnectionMode")
        attemptedConfiguredGatewayIDs.removeAll()
        attemptedGatewayIDs.removeAll()
        attemptedInternetGatewayIDs.removeAll()
        if autoConnectEnabled { Task { await reconnectNetwork() } }
    }

    public func setTransportInstanceEnabled(_ enabled: Bool) {
        #if os(macOS)
        transportInstanceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "reticulumTransportInstanceEnabled")
        Task {
            await transportInstance.setEnabled(enabled)
            transportInstanceSnapshot = await transportInstance.snapshot()
        }
        #else
        transportInstanceEnabled = false
        #endif
    }

    public func setPreferIPv6(_ enabled: Bool) {
        preferIPv6 = enabled
        UserDefaults.standard.set(enabled, forKey: "reticulumPreferIPv6")
    }

    public func setInternetOnly(_ enabled: Bool) {
        internetOnlyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "reticulumInternetOnly")
        if enabled {
            lanDiscovery.stop()
            pendingLANGatewaySwitchID = nil
        }
        if autoConnectEnabled { Task { await reconnectNetwork() } }
    }

    public func setPropagationNode(_ hash: String) {
        propagationNodeHash = hash.trimmingCharacters(in: CharacterSet(charactersIn: "<> ").union(.whitespacesAndNewlines)).lowercased()
        UserDefaults.standard.set(propagationNodeHash, forKey: "lxmfPropagationNode")
        propagationNodeIsAutomatic = propagationNodeHash.isEmpty
        UserDefaults.standard.set(propagationNodeIsAutomatic, forKey: "lxmfPropagationNodeAutomatic")
    }

    public func setAutomaticPropagationNode(_ enabled: Bool) {
        propagationNodeIsAutomatic = enabled
        UserDefaults.standard.set(enabled, forKey: "lxmfPropagationNodeAutomatic")
        if enabled {
            propagationNodeHash = ""
            UserDefaults.standard.removeObject(forKey: "lxmfPropagationNode")
            Task { await announceLocalDeliveryDestination() }
        }
    }

    public func setLocalDisplayName(_ displayName: String) {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        localDisplayName = normalized.isEmpty ? "Lower Sideband" : String(normalized.prefix(64))
        UserDefaults.standard.set(localDisplayName, forKey: "lxmfLocalDisplayName")
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
    public var localAnnounceAppData: Data { ReticulumAnnounceBuilder.lxmfAppData(displayName: localDisplayName) }
    public var localContactLink: SidebandContactLink {
        SidebandContactLink(destinationHash: localDeliveryHash, displayName: localDisplayName, publicKey: messagingIdentity.publicKey)!
    }
    public var networkDiagnosticsReport: String {
        let state: String
        switch networkState {
        case .stopped: state = "stopped"
        case .connecting: state = "connecting"
        case .ready: state = "ready"
        case .failed(let reason): state = "failed: \(reason)"
        }
        let rnodeDetails = rnodeManager.snapshots.map { snapshot in
            let state: String
            switch snapshot.state {
            case .stopped: state = "stopped"
            case .searching: state = "searching"
            case .connecting: state = "connecting"
            case .detecting: state = "detecting"
            case .configuring: state = "configuring"
            case .ready: state = "ready"
            case .failed(let reason): state = "failed: \(reason)"
            }
            let firmware = if let major = snapshot.metrics.firmwareMajor, let minor = snapshot.metrics.firmwareMinor { "\(major).\(minor)" } else { "unknown" }
            return "\(snapshot.name)[\(snapshot.transport.rawValue)]=\(state), firmware \(firmware), RX \(snapshot.metrics.receivedBytes ?? 0) B, TX \(snapshot.metrics.transmittedBytes ?? 0) B"
        }.joined(separator: ", ")
        return [
            "Lower Sideband Network Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: .now))",
            "Local name: \(localDisplayName)",
            "Local destination: \(localDeliveryHash)",
            "Network state: \(state)",
            "TCP endpoint: \(networkInterfaces.map { "\($0.name)\($0.isBootstrap ? "[bootstrap]" : "[discovered]")=\($0.state)" }.joined(separator: ", "))",
            "RNode interfaces: \(rnodeDetails.isEmpty ? "none" : rnodeDetails)",
            "RNode automatic discovery: \(rnodeManager.automaticDiscoveryEnabled)",
            "Authenticated network interfaces discovered: \(discoveredNetworkInterfaces.count)",
            "Prefer IPv6: \(preferIPv6)",
            "System interface: \(reachability.interfaceSummary)",
            "Packets received: \(receivedPacketCount)",
            "Known paths: \(knownPathCount)",
            "Discoveries: \(discoveries.count) (\(validatedDiscoveryCount) validated)",
            "Links: \(activeLinkCount) active, \(pendingLinkCount) pending",
            "Messages: \(messages.count) total, \(messages.count(where: { $0.state == .queued })) queued, \(messages.count(where: { $0.state == .failed })) failed",
            "Plugins: \(pluginRegistry.manifests.count) loaded, \(pluginRegistry.rejectedPluginDescriptions.count) rejected, \(pluginAuditEvents.count) audit events",
            "Propagation node: \(propagationNodeHash.isEmpty ? "not discovered" : propagationNodeHash) (\(propagationNodeIsAutomatic ? "automatic" : "manual"))",
            "Remote wake token: \(UserDefaults.standard.string(forKey: "sidebandAPNsDeviceToken") == nil ? "not registered" : "registered")",
            "Runtime: low power \(runtimeHealth.isLowPowerModeEnabled ? "on" : "off"), thermal \(runtimeHealth.thermalState.rawValue), memory warnings \(runtimeHealth.memoryPressureEvents)",
            "Last connected: \(lastNetworkReadyAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "Background refresh: \(lastBackgroundRefreshAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never") · \(lastBackgroundRefreshSucceeded.map { $0 ? "succeeded" : "incomplete" } ?? "not run")"
        ].joined(separator: "\n")
    }

    public func cleanOrphanedAttachments() async -> Int {
        let referencedPaths = Set(messages.flatMap(\.attachments).map(\.relativePath))
        return (try? await attachmentStore.removeOrphans(referencedRelativePaths: referencedPaths)) ?? 0
    }

    @discardableResult
    public func validateAttachmentStorage() async -> Int {
        var invalidCount = 0
        for messageIndex in messages.indices {
            for attachmentIndex in messages[messageIndex].attachments.indices {
                let attachment = messages[messageIndex].attachments[attachmentIndex]
                guard attachment.state == .local || attachment.state == .queued || attachment.state == .available else { continue }
                do { _ = try await attachmentStore.read(attachment) }
                catch {
                    messages[messageIndex].attachments[attachmentIndex].state = .failed
                    messages[messageIndex].attachments[attachmentIndex].progress = 0
                    if messages[messageIndex].direction == .outgoing { messages[messageIndex].state = .failed }
                    invalidCount += 1
                }
            }
        }
        if invalidCount > 0 { save() }
        return invalidCount
    }

    public func exportSnapshotData() throws -> Data {
        let snapshot = AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries, drafts: drafts, voiceCallHistory: voiceCallHistory, pluginAuditEvents: pluginAuditEvents, deletedConversationDestinations: deletedConversationDestinations)
        let data = try JSONEncoder.sideband.encode(snapshot)
        let validated = try JSONDecoder.sideband.decode(AppSnapshot.self, from: data)
        guard validated.schemaVersion <= AppSnapshot.currentSchemaVersion else { throw SnapshotError.unsupportedVersion }
        return data
    }

    public func exportPrivateIdentityText() throws -> String {
        try ReticulumIdentityText.encodePrivate(messagingIdentity)
    }

    public func exportEncryptedProfile(passphrase: String, ratchets: ReticulumRatchetState? = nil) throws -> Data {
        guard let privateKey = messagingIdentity.privateKey else { throw SidebandProfileArchive.ArchiveError.invalidPayload }
        let payload = try SidebandProfileArchive.Payload(
            messagingIdentity: privateKey,
            applicationSnapshot: exportSnapshotData(),
            ratchets: ratchets
        )
        return try SidebandProfileArchive.seal(payload, passphrase: passphrase)
    }

    @discardableResult public func restoreEncryptedProfile(_ archive: Data, passphrase: String) throws -> ReticulumRatchetState? {
        let payload = try SidebandProfileArchive.open(archive, passphrase: passphrase)
        let identity = try ReticulumIdentity(privateKey: payload.messagingIdentity)
        _ = try validatedSnapshot(from: payload.applicationSnapshot)
        switch SecureIdentityStore.replace(payload.messagingIdentity, account: "lxmf.messaging", synchronizable: true) {
        case .failure: throw SidebandProfileArchive.ArchiveError.invalidPayload
        case .success: break
        }
        messagingIdentity = identity
        try restoreSnapshotData(payload.applicationSnapshot)
        return payload.ratchets
    }

    public func importPythonIdentity(_ rawIdentity: Data) throws {
        let identity = try SidebandProfileArchive.importPythonIdentity(rawIdentity)
        guard let privateKey = identity.privateKey else { throw SidebandProfileArchive.ArchiveError.invalidPayload }
        switch SecureIdentityStore.replace(privateKey, account: "lxmf.messaging", synchronizable: true) {
        case .failure: throw SidebandProfileArchive.ArchiveError.invalidPayload
        case .success: messagingIdentity = identity
        }
    }

    /// Imports conversations and messages directly from a historical Python
    /// Sideband SQLite database without modifying the source file.
    @discardableResult
    public func importLegacySidebandDatabase(at url: URL) throws -> LegacySidebandSQLiteImporter.Report {
        let report = try LegacySidebandSQLiteImporter.load(from: url)
        let local = AppSnapshot(
            conversations: conversations, messages: messages, discoveries: discoveries,
            drafts: drafts, voiceCallHistory: voiceCallHistory,
            pluginAuditEvents: pluginAuditEvents,
            deletedConversationDestinations: deletedConversationDestinations
        )
        let merged = local.mergingCloudSnapshot(report.snapshot)
        applyCloudSnapshot(merged)
        save()
        syncUnreadBadge()
        return report
    }

    public func validatedSnapshot(from data: Data) throws -> AppSnapshot {
        guard data.count <= 256 * 1_024 * 1_024 else { throw SnapshotError.invalidData }
        let snapshot = try JSONDecoder.sideband.decode(AppSnapshot.self, from: data)
        guard snapshot.schemaVersion <= AppSnapshot.currentSchemaVersion else { throw SnapshotError.unsupportedVersion }
        let conversationIDs = Set(snapshot.conversations.map(\.id))
        let destinations = snapshot.conversations.map(\.destinationHash)
        guard snapshot.conversations.count <= 10_000,
              snapshot.messages.count <= 250_000,
              snapshot.discoveries.count <= 50_000,
              snapshot.drafts.count <= 10_000,
              snapshot.voiceCallHistory.count <= 100,
              snapshot.deletedConversationDestinations.count <= 10_000,
              conversationIDs.count == snapshot.conversations.count,
              Set(destinations).count == destinations.count,
              destinations.allSatisfy(DestinationHash.isValid),
              snapshot.deletedConversationDestinations.keys.allSatisfy(DestinationHash.isValid),
              snapshot.deletedConversationDestinations.values.allSatisfy(supportedMessageDates.contains),
              snapshot.messages.allSatisfy({ conversationIDs.contains($0.conversationID) }),
              snapshot.messages.compactMap(\.telemetry).allSatisfy({ $0.validationError == nil }),
              snapshot.messages.allSatisfy({ message in
                  isAcceptableMessageBody(message.body) && isSupportedPersistedMessage(message) &&
                  message.attachments.count <= SidebandMessageLimits.maximumAttachments &&
                  message.attachments.allSatisfy { (0...ReticulumResourceLimits.maximumAttachmentBytes).contains($0.byteCount) } &&
                  message.attachments.reduce(0) { $0 + $1.byteCount } <= SidebandMessageLimits.maximumCombinedAttachmentBytes &&
                  (0...10_000).contains(message.deliveryAttemptCount) && (message.lastDeliveryFailure?.count ?? 0) <= 256
              }),
              snapshot.drafts.keys.allSatisfy({ conversationIDs.contains($0) }),
              snapshot.pluginAuditEvents.count <= 200,
              snapshot.pluginAuditEvents.allSatisfy({ event in
                  conversationIDs.contains(event.conversationID) &&
                  !event.command.isEmpty && event.command.count <= 64 &&
                  (event.pluginIdentifier?.count ?? 0) <= 128
              }),
              snapshot.messages.flatMap(\.attachments).allSatisfy({
                  !$0.relativePath.isEmpty && URL(fileURLWithPath: $0.relativePath).lastPathComponent == $0.relativePath &&
                  !$0.filename.isEmpty && $0.filename.count <= 180 &&
                  (0...ReticulumResourceLimits.maximumAttachmentBytes).contains($0.byteCount) &&
                  $0.progress.isFinite && (0...1).contains($0.progress) &&
                  ($0.contentHash == nil || $0.contentHash?.count == 32)
              }),
              snapshot.conversations.allSatisfy({ conversation in
                  guard conversation.contactNote.count <= 512, conversation.displayName.count <= 128,
                        conversation.tags.count <= 8, conversation.tags.allSatisfy({ !$0.isEmpty && $0.count <= 32 }) else { return false }
                  guard let key = conversation.verifiedIdentityKey else { return conversation.identityVerifiedAt == nil }
                  guard conversation.identityVerifiedAt != nil,
                        let identity = try? ReticulumIdentity(publicKey: key) else { return false }
                  let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
                  return ReticulumIdentity.truncatedHash(nameHash + identity.hash).hex == conversation.destinationHash
              }) else { throw SnapshotError.invalidData }
        return snapshot
    }

    private var supportedMessageDates: ClosedRange<Date> {
        Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4_102_444_800)
    }

    private func isAcceptableMessageBody(_ body: String) -> Bool {
        body.count <= SidebandMessageLimits.maximumTextCharacters && body.utf8.count <= SidebandMessageLimits.maximumTextBytes
    }

    private func isAcceptableReplyQuote(_ quote: String?) -> Bool {
        guard let quote else { return true }
        return quote.count <= SidebandMessageLimits.maximumReplyQuoteCharacters && quote.utf8.count <= SidebandMessageLimits.maximumReplyQuoteBytes
    }

    private func isSupportedPersistedMessage(_ message: Message) -> Bool {
        message.timestamp.timeIntervalSinceReferenceDate.isFinite && supportedMessageDates.contains(message.timestamp) &&
            (message.lxmfID == nil || message.lxmfID?.count == 32) &&
            (message.replyTo == nil || message.replyTo?.count == 32) && isAcceptableReplyQuote(message.replyQuote) &&
            (message.reactionTo == nil || message.reactionTo?.count == 32) &&
            (message.reactionContent == nil || (message.reactionTo.map { Message.isValidReaction(content: message.reactionContent ?? "", target: $0) } ?? false)) &&
            (message.commentTo == nil || message.commentTo?.count == 32) &&
            (message.continuationOf == nil || message.continuationOf?.count == 32) &&
            message.telemetryStream.count <= 512 && message.telemetryStream.allSatisfy {
                $0.sourceHash.count == 16 && supportedMessageDates.contains($0.timestamp) &&
                $0.telemetry.validationError == nil && ($0.encodedAppearance?.count ?? 0) <= 4_096
            } && (message.voiceAudio?.encodedAudio.count ?? 0) <= LXMFVoiceMessageAudio.maximumEncodedBytes &&
            message.commands.count <= LXMFCommand.maximumCommandsPerMessage
    }

    private func rememberReceivedLXMFID(_ id: String) {
        guard !id.isEmpty else { return }
        if receivedLXMFIDs.count >= SidebandMessageLimits.maximumRememberedMessageIDs,
           let evicted = receivedLXMFIDs.first { receivedLXMFIDs.remove(evicted) }
        receivedLXMFIDs.insert(id)
        UserDefaults.standard.set(Array(receivedLXMFIDs), forKey: "receivedLXMFMessageIDs")
    }

    public func restoreSnapshotData(_ data: Data) throws {
        let snapshot = try validatedSnapshot(from: data)
        conversations = snapshot.conversations
        messages = snapshot.messages
        sortConversations()
        discoveries = snapshot.discoveries
        deletedConversationDestinations = snapshot.deletedConversationDestinations
        voiceCallHistory = Array(snapshot.voiceCallHistory.prefix(100))
        pluginAuditEvents = Array(snapshot.pluginAuditEvents.prefix(200))
        drafts = snapshot.drafts
        selectedConversationID = conversations.first?.id
        visibleConversationID = nil
        save()
        syncUnreadBadge()
    }

    public func startGatewayDiscovery() { lanDiscovery.start() }
    public func stopGatewayDiscovery() { lanDiscovery.stop() }
    public func startAutoInterfaceDiscovery() {
        guard secureStorageAvailable else {
            lastError = "Secure Keychain data is unavailable. Reopen Lower Sideband after unlocking the device."
            return
        }
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
        guard secureStorageAvailable else {
            lastError = "Secure Keychain data is unavailable. Reopen Lower Sideband after unlocking the device."
            return
        }
        guard tcpNetworkState != .connecting else { return }
        tcpNetworkState = .connecting
        refreshAggregateNetworkState()
        let generation = UUID()
        networkConnectionGeneration = generation
        await networkInterfacePool?.stop()
        selectedGatewayName = gateway.name
        activeGatewayID = gateway.id
        activeInternetGatewayID = nil
        activeNetworkHost = gateway.name
        activeNetworkPort = nil
        automaticConnectionDescription = "Trying discovered gateway \(gateway.name)"
        let pool = makeInterfacePool(generation: generation)
        networkInterfacePool = pool
        await pool.start([ReticulumTCPInterfacePool.Endpoint(id: gateway.id, name: gateway.name, endpoint: gateway.endpoint)])
    }

    @discardableResult
    public func addConversation(from discovery: DiscoveredDestination) -> Bool {
        addConversation(destinationHash: discovery.destinationHash, displayName: discovery.announcedDisplayName ?? "Discovered \(discovery.destinationHash.prefix(8))")
    }

    public func requestPath(to destinationHash: String) async {
        guard let target = Data(hexadecimal: destinationHash) else {
            lastError = "The destination address is invalid."
            return
        }
        let normalized = destinationHash.lowercased()
        guard networkState == .ready else {
            deferredPathRequests.insert(normalized)
            pendingPathHashes.insert(normalized)
            switch networkState {
            case .stopped, .failed:
                if autoConnectEnabled { await startAutomaticConnection() }
                else { await connectNetwork() }
            case .connecting, .ready: break
            }
            return
        }
        do {
            let packet = try ReticulumPathRequest.packet(targetHash: target)
            try await transmitRawPacket(packet)
            await pathTable.markRequested(target)
            pendingPathHashes.insert(destinationHash.lowercased())
            Task {
                try? await Task.sleep(for: .seconds(16))
                if await !pathTable.isPending(target), !hasPath(to: destinationHash) {
                    pendingPathHashes.remove(destinationHash.lowercased())
                    let hasQueuedMessages = conversations
                        .first(where: { $0.destinationHash == normalized })
                        .map { conversation in
                            messages.contains {
                                $0.conversationID == conversation.id
                                    && $0.direction == .outgoing
                                    && $0.state == .queued
                            }
                        } ?? false
                    if AutomaticGatewayFailoverPolicy.shouldRotateInternetGateway(
                        activeInternetGatewayID: activeInternetGatewayID,
                        hasPath: false,
                        hasQueuedMessages: hasQueuedMessages
                    ) {
                        await rotateToNextInternetGateway(for: normalized)
                        return
                    }
                    if let conversation = conversations.first(where: { $0.destinationHash == destinationHash }) {
                        await attemptDelivery(for: conversation.id)
                        await propagateQueued(for: conversation.id)
                    }
                }
            }
        } catch {
            lastError = "Path request failed: \(error.localizedDescription)"
        }
    }

    public func hasPath(to destinationHash: String) -> Bool { knownPathHashes.contains(destinationHash.lowercased()) }
    public func isPathPending(to destinationHash: String) -> Bool { pendingPathHashes.contains(destinationHash.lowercased()) }
    public var validatedDiscoveryCount: Int { discoveries.count(where: \.isValidated) }
    public func hasValidatedDiscovery(to destinationHash: String) -> Bool {
        discoveries.contains { $0.destinationHash == destinationHash.lowercased() && $0.isValidated && $0.publicKey != nil }
    }
    public var unverifiedDiscoveryCount: Int { discoveries.count - validatedDiscoveryCount }
    public var knownPathCount: Int { knownPathHashes.count }
    public var pendingPathCount: Int { pendingPathHashes.count }
    public var pendingLinkCount: Int { pendingLinkHashes.count }
    public var activeLinkCount: Int { activeLinkHashes.count }

    public func requestLink(to destinationHash: String) async {
        let normalized = destinationHash.lowercased()
        guard let target = Data(hexadecimal: normalized) else {
            lastError = "The destination address is invalid."
            return
        }
        guard hasPath(to: normalized) else {
            await requestPath(to: normalized)
            deferLinkRequest(to: normalized)
            return
        }
        guard networkState == .ready else {
            deferLinkRequest(to: normalized)
            if networkState != .connecting { await startAutomaticConnection() }
            return
        }
        guard !activeLinkHashes.contains(normalized),
              !pendingLinks.values.contains(where: { $0.destinationHash == target }) else {
            return
        }
        deferredLinkRetryTokens.removeValue(forKey: normalized)
        pendingLinkHashes.remove(normalized)
        do {
            clearPendingLinks(to: normalized)
            let request = try ReticulumLinkRequest(destinationHash: target)
            try await transmitDestinationPacket(request.rawPacket, destinationHash: target)
            let linkID = request.linkID.hex
            let timeoutToken = UUID()
            pendingLinks[linkID] = request
            pendingLinkTimeoutTokens[linkID] = timeoutToken
            pendingLinkHashes.insert(normalized)
            UserDefaults.standard.set(linkID, forKey: "reticulumLastPendingLink")
            scheduleLinkTimeout(linkID: linkID, destinationHash: normalized, token: timeoutToken)
        } catch {
            // iOS can replace a TCP connection while a still-valid route is
            // visible. Secure-link maintenance retries in the background.
            deferLinkRequest(to: normalized)
            if networkState != .connecting { await startAutomaticConnection() }
        }
    }

    private func deferLinkRequest(to destinationHash: String) {
        guard !activeLinkHashes.contains(destinationHash) else { return }
        let token = UUID()
        deferredLinkRetryTokens[destinationHash] = token
        pendingLinkHashes.insert(destinationHash)
        automaticConnectionDescription = networkState == .ready ? "Establishing secure link" : "Reconnecting securely"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.retryDeferredLink(to: destinationHash, token: token)
        }
    }

    private func retryDeferredLink(to destinationHash: String, token: UUID) async {
        guard deferredLinkRetryTokens[destinationHash] == token else { return }
        deferredLinkRetryTokens.removeValue(forKey: destinationHash)
        pendingLinkHashes.remove(destinationHash)
        if networkState != .ready {
            await startAutomaticConnection()
            deferLinkRequest(to: destinationHash)
            return
        }
        await requestLink(to: destinationHash)
    }

    private func scheduleLinkTimeout(linkID: String, destinationHash: String, token: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            await self?.expireLinkRequest(linkID: linkID, destinationHash: destinationHash, token: token)
        }
    }

    private func expireLinkRequest(linkID: String, destinationHash: String, token: UUID) async {
        guard pendingLinkTimeoutTokens[linkID] == token, pendingLinks.removeValue(forKey: linkID) != nil else { return }
        pendingLinkTimeoutTokens.removeValue(forKey: linkID)
        pendingLinkHashes.remove(destinationHash)
        if UserDefaults.standard.string(forKey: "reticulumLastPendingLink") == linkID {
            UserDefaults.standard.removeObject(forKey: "reticulumLastPendingLink")
        }
        guard networkState == .ready else { return }
        if let destination = Data(hexadecimal: destinationHash) {
            await pathTable.invalidate(destination)
            await refreshPathState()
        }
        await requestPath(to: destinationHash)
    }

    private func clearPendingLinks(to destinationHash: String) {
        deferredLinkRetryTokens.removeValue(forKey: destinationHash)
        let linkIDs = pendingLinks.compactMap { $0.value.destinationHash.hex == destinationHash ? $0.key : nil }
        for linkID in linkIDs {
            pendingLinks.removeValue(forKey: linkID)
            pendingLinkTimeoutTokens.removeValue(forKey: linkID)
        }
        pendingLinkHashes.remove(destinationHash)
    }

    private func resetLinkState() {
        if voiceCall != nil { finishVoiceCall(failure: "The network connection ended.") }
        // A receipt tied to a vanished interface cannot arrive on the new
        // connection. Requeue it immediately instead of displaying Sent and
        // holding a delivery-window slot until its timer expires.
        for receipt in pendingReceipts.values {
            if let messageIndex = messages.firstIndex(where: { $0.id == receipt.messageID }) {
                messages[messageIndex].state = .queued
                messages[messageIndex].lastDeliveryFailure = "Network changed; retrying on the new connection."
            }
        }
        pendingReceipts.removeAll()
        for task in receiptTimeoutTasks.values { task.cancel() }
        receiptTimeoutTasks.removeAll()
        for task in receiptRetryTasks.values { task.cancel() }
        receiptRetryTasks.removeAll()
        pendingReceiptRetryKinds.removeAll()
        // Link and resource cryptographic state is bound to the interface that
        // disappeared. Preserve the durable outbox, but return interrupted
        // transfers to queued so reconnect can negotiate a fresh link and
        // resume from a clean resource advertisement.
        let interruptedResources = Array(outgoingResources.values)
        for resource in interruptedResources {
            if let messageIndex = messages.firstIndex(where: { $0.id == resource.messageID }) {
                messages[messageIndex].state = .queued
                messages[messageIndex].outboxOwnerID = syncDeviceID
                messages[messageIndex].outboxOwnerUpdatedAt = .now
                if let attachmentID = resource.attachmentID,
                   let attachmentIndex = messages[messageIndex].attachments.firstIndex(where: { $0.id == attachmentID }) {
                    messages[messageIndex].attachments[attachmentIndex].state = .queued
                    messages[messageIndex].attachments[attachmentIndex].progress = 0
                }
            }
        }
        outgoingResources.removeAll()
        incomingResources.removeAll()
        pendingLinks.removeAll()
        pendingLinkTimeoutTokens.removeAll()
        activeLinks.removeAll()
        linkRemoteDestinations.removeAll()
        linkInterfaceIDs.removeAll()
        pendingLinkHashes.removeAll()
        activeLinkHashes.removeAll()
        inboundLinkIDs.removeAll()
        inboundRemoteIdentities.removeAll()
        voiceLinkIDs.removeAll()
        pendingVoiceConversations.removeAll()
        pendingVoicePublicKeys.removeAll()
        activeVoiceLinkID = nil
        pendingPropagationRequests.removeAll()
        if !interruptedResources.isEmpty { save() }
        UserDefaults.standard.removeObject(forKey: "reticulumLastPendingLink")
        UserDefaults.standard.removeObject(forKey: "reticulumLastActiveLink")
    }

    private func makeInterfacePool(generation: UUID) -> ReticulumTCPInterfacePool {
        ReticulumTCPInterfacePool { [weak self] interfaceID, packet in
            await self?.receiveFromInterface(packet, interfaceID: interfaceID)
        } stateHandler: { [weak self] state, snapshots in
            await self?.setNetworkState(state, generation: generation, snapshots: snapshots)
        }
    }

    private func setNetworkState(
        _ state: ReticulumTCPInterface.State,
        generation: UUID,
        snapshots: [ReticulumTCPInterfacePool.Snapshot] = []
    ) async {
        guard generation == networkConnectionGeneration else { return }
        let currentInterfaceIDs = Set(snapshots.compactMap { snapshot in
            snapshot.state == .ready ? snapshot.id : nil
        })
        let removedInterfaceIDs = knownTCPInterfaceIDs.subtracting(currentInterfaceIDs)
        knownTCPInterfaceIDs = currentInterfaceIDs
        if !removedInterfaceIDs.isEmpty {
            await pathTable.removePaths(on: removedInterfaceIDs)
            await refreshPathState()
        }
        networkInterfaces = snapshots
        tcpNetworkState = state
        refreshAggregateNetworkState()
        if state == .ready {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            reconnectDelaySeconds = nil
            let readyCount = snapshots.count { $0.state == .ready }
            let latency = networkConnectionStartedAt.map { Date.now.timeIntervalSince($0) }
            for snapshot in snapshots where snapshot.state == .ready {
                var record = gatewayHealth[snapshot.id] ?? GatewayHealthRecord()
                record.recordSuccess(latency: latency)
                gatewayHealth[snapshot.id] = record
            }
            persistGatewayHealth()
            networkConnectionStartedAt = nil
            automaticConnectionDescription = selectedGatewayName.map { "Connected automatically to \($0)" }
                ?? (readyCount > 1 ? "Connected securely through \(readyCount) gateways" : "Connected automatically to \(activeNetworkHost ?? networkHost)")
            if let activeGatewayID {
                preferredGatewayID = activeGatewayID
                UserDefaults.standard.set(activeGatewayID, forKey: "reticulumPreferredGatewayID")
            }
            if let activeInternetGatewayID {
                preferredInternetGatewayID = activeInternetGatewayID
                UserDefaults.standard.set(activeInternetGatewayID, forKey: "reticulumPreferredInternetGatewayID")
            }
            Task {
                await synthesizeTCPTunnel()
                await announceLocalDeliveryDestination()
            }
        }
        switch state {
        case .failed:
            for snapshot in snapshots where snapshot.state != .ready {
                var record = gatewayHealth[snapshot.id] ?? GatewayHealthRecord()
                record.recordFailure()
                gatewayHealth[snapshot.id] = record
            }
            persistGatewayHealth()
            networkConnectionStartedAt = nil
            if networkState != .ready {
                stopPeriodicPropagationSync()
                resetLinkState()
            }
            if autoConnectEnabled, !intentionallyDisconnected {
                Task { await tryNextAutomaticConnection() }
            } else {
                scheduleReconnect()
            }
        case .stopped:
            if networkState != .ready {
                stopPeriodicPropagationSync()
                resetLinkState()
            }
        case .connecting, .ready: break
        }
    }

    private func refreshAggregateNetworkState() {
        let previous = networkState
        let rnodeReady = rnodeManager.hasReadyInterface
        let rnodeConnecting = rnodeManager.snapshots.contains {
            switch $0.state {
            case .searching, .connecting, .detecting, .configuring: true
            default: false
            }
        }
        if tcpNetworkState == .ready || rnodeReady {
            networkState = .ready
        } else if tcpNetworkState == .connecting || rnodeConnecting {
            networkState = .connecting
        } else if case .failed(let reason) = tcpNetworkState {
            networkState = .failed(reason)
        } else if let reason = rnodeManager.snapshots.compactMap({ snapshot -> String? in
            if case .failed(let reason) = snapshot.state { return reason }
            return nil
        }).first {
            networkState = .failed(reason)
        } else {
            networkState = .stopped
        }

        guard previous != .ready, networkState == .ready else { return }
        lastNetworkReadyAt = .now
        UserDefaults.standard.set(lastNetworkReadyAt, forKey: "reticulumLastReadyAt")
        if rnodeReady && tcpNetworkState != .ready {
            automaticConnectionDescription = "Connected directly through RNode radio"
        }
        startPeriodicPropagationSync()
        Task {
            if tcpNetworkState == .ready { await synthesizeTCPTunnel() }
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

    private func scheduleReconnect() {
        guard autoConnectEnabled, !intentionallyDisconnected, reconnectTask == nil else { return }
        let delay = min(60, 1 << min(reconnectAttempt + 1, 5))
        reconnectAttempt += 1
        reconnectDelaySeconds = delay
        automaticConnectionDescription = "No gateway available; retrying in \(delay)s"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.reconnectTask = nil
            self.attemptedGatewayIDs.removeAll()
            self.attemptedConfiguredGatewayIDs.removeAll()
            self.attemptedInternetGatewayIDs.removeAll()
            self.observedLANDiscoveryGrace = false
            await self.tryNextAutomaticConnection()
        }
    }

    public func startAutomaticConnection() async {
        guard secureStorageAvailable else {
            automaticConnectionDescription = "Secure Keychain data unavailable"
            return
        }
        guard autoConnectEnabled, !intentionallyDisconnected || networkState == .stopped else { return }
        intentionallyDisconnected = false
        await rnodeManager.startAll()
        refreshAggregateNetworkState()
        if internetOnlyEnabled { lanDiscovery.stop() }
        else { lanDiscovery.start() }
        guard tcpNetworkState != .ready, tcpNetworkState != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        attemptedGatewayIDs.removeAll()
        attemptedConfiguredGatewayIDs.removeAll()
        attemptedInternetGatewayIDs.removeAll()
        observedLANDiscoveryGrace = false
        automaticConnectionDescription = connectionMode == .automatic
            ? "Discovering Reticulum gateways automatically"
            : "Trying configured Reticulum gateway"
        await tryNextAutomaticConnection()
    }

    private func tryNextAutomaticConnection() async {
        guard autoConnectEnabled, !intentionallyDisconnected else { return }
        guard reachability.status != .unavailable else {
            automaticConnectionDescription = "Waiting for a network"
            return
        }
        guard tcpNetworkState != .ready, tcpNetworkState != .connecting else { return }

        if !internetOnlyEnabled, connectionMode == .configured {
            let configuredCandidates = ConfiguredReticulumGateways.ordered(
                ipv4Host: networkHost,
                ipv6Host: networkIPv6Host,
                port: networkPort,
                preferIPv6: preferIPv6,
                supportsIPv6: reachability.supportsIPv6,
                excluding: attemptedConfiguredGatewayIDs
            )
            if let gateway = configuredCandidates.first {
                attemptedConfiguredGatewayIDs.insert(gateway.id)
                automaticConnectionDescription = "Trying \(gateway.name.lowercased())"
                await connectNetwork(explicitHost: gateway.host, explicitPort: gateway.port)
                return
            }
        }

        if !internetOnlyEnabled {
            let candidates = AutomaticGatewaySelector.ordered(
                lanDiscovery.gateways,
                preferredID: preferredGatewayID,
                excluding: attemptedGatewayIDs
            )
            if let gateway = candidates.first {
                attemptedGatewayIDs.insert(gateway.id)
                await connect(to: gateway)
                return
            }

            if lanDiscovery.isSearching, !observedLANDiscoveryGrace {
                observedLANDiscoveryGrace = true
                automaticConnectionDescription = "Looking for a local Reticulum gateway"
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await tryNextAutomaticConnection()
                return
            }
        }

        let internetCandidates = PublicReticulumGateways.ordered(
            customHost: networkInternetHost,
            customPort: networkInternetPort,
            preferredID: preferredInternetGatewayID,
            excluding: attemptedInternetGatewayIDs,
            health: gatewayHealth
        )
        if let gateway = internetCandidates.first {
            attemptedInternetGatewayIDs.insert(gateway.id)
            automaticConnectionDescription = "Trying public gateway \(gateway.name)"
            await connectNetwork(
                explicitHost: gateway.host,
                explicitPort: gateway.port,
                internetGatewayID: gateway.id
            )
            return
        }
        scheduleReconnect()
    }

    public func resetGatewayHealth() {
        gatewayHealth.removeAll()
        UserDefaults.standard.removeObject(forKey: "reticulumGatewayHealth")
    }

    public var gatewayHealthDiagnostics: String {
        guard !gatewayHealth.isEmpty else { return "No gateway health history recorded." }
        return gatewayHealth.sorted(by: { $0.key < $1.key }).map { id, record in
            let latency = record.smoothedConnectLatency.map { String(format: "%.2fs", $0) } ?? "unknown"
            return "\(id): \(record.successfulConnections) success, \(record.failedConnections) failure, \(record.consecutiveFailures) consecutive, latency \(latency)"
        }.joined(separator: "\n")
    }

    private func persistGatewayHealth() {
        if let data = try? JSONEncoder.sideband.encode(gatewayHealth) {
            UserDefaults.standard.set(data, forKey: "reticulumGatewayHealth")
        }
    }

    private func gatewayResultsChanged(_ gateways: [LANGateway]) {
        guard autoConnectEnabled, !internetOnlyEnabled, !gateways.isEmpty else { return }
        if tcpNetworkState == .ready,
           AutomaticGatewayFailoverPolicy.shouldPreferDiscoveredLAN(
               activeInternetGatewayID: activeInternetGatewayID,
               discoveredGatewayCount: gateways.count
           ),
           let gateway = AutomaticGatewaySelector.ordered(gateways, preferredID: preferredGatewayID).first,
           pendingLANGatewaySwitchID != gateway.id {
            pendingLANGatewaySwitchID = gateway.id
            attemptedGatewayIDs.insert(gateway.id)
            automaticConnectionDescription = "Switching to local gateway \(gateway.name)"
            Task {
                await connect(to: gateway)
                pendingLANGatewaySwitchID = nil
            }
            return
        }
        guard tcpNetworkState != .ready, tcpNetworkState != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { await tryNextAutomaticConnection() }
    }

    private func rotateToNextInternetGateway(for destinationHash: String) async {
        guard autoConnectEnabled, networkState == .ready, activeInternetGatewayID != nil else { return }
        // Public interfaces are now connected concurrently. Reissue the path
        // request across the pool instead of tearing down healthy reticules.
        automaticConnectionDescription = "Searching all connected gateways for \(abbreviated(destinationHash))"
        guard let target = Data(hexadecimal: destinationHash), let packet = try? ReticulumPathRequest.packet(targetHash: target) else { return }
        _ = try? await networkInterfacePool?.send(rawPacket: packet)
    }

    private func reachabilityChanged(_ status: NetworkReachability.Status) {
        guard autoConnectEnabled else { return }
        if status == .available, tcpNetworkState != .ready, tcpNetworkState != .connecting {
            reconnectTask?.cancel()
            reconnectTask = nil
            attemptedGatewayIDs.removeAll()
            attemptedConfiguredGatewayIDs.removeAll()
            attemptedInternetGatewayIDs.removeAll()
            observedLANDiscoveryGrace = false
            Task { await tryNextAutomaticConnection() }
        } else if status == .unavailable {
            automaticConnectionDescription = "Waiting for a network"
        }
    }

    private func synthesizeTCPTunnel() async {
        guard let networkInterfacePool else { return }
        do { try await networkInterfacePool.send(rawPacket: ReticulumTunnelSynthesis.packet(identity: transportIdentity, interfaceHash: tcpInterfaceHash)) }
        catch { lastError = "TCP tunnel synthesis failed: \(error.localizedDescription)" }
    }

    /// Immediately broadcasts this profile's LXMF delivery and voice
    /// destinations on every ready Reticulum interface. Automatic announces
    /// continue to run independently on connection and during maintenance.
    @discardableResult
    public func announceDeliveryDestinationNow() async -> Bool {
        guard networkState == .ready else { return false }
        return await announceLocalDeliveryDestination()
    }

    @discardableResult
    private func announceLocalDeliveryDestination() async -> Bool {
        do {
            let packet = try ReticulumAnnounceBuilder.packet(identity: messagingIdentity, destinationName: "lxmf.delivery", appData: localAnnounceAppData)
            try await transmitRawPacket(packet)
            let voicePacket = try ReticulumAnnounceBuilder.packet(identity: messagingIdentity, destinationName: LXSTVoice.destinationName)
            try await transmitRawPacket(voicePacket)
            deliveryAnnouncesSent += 1
            lastDeliveryAnnounceAt = .now
            return true
        } catch {
            // Connection transitions are retried by the engine. An announce is
            // maintenance traffic and must never interrupt the user with a modal.
            return false
        }
    }

    private func receiveFromInterface(_ packet: ReticulumPacket, interfaceID: String) async {
        guard transportInstanceEnabled else { receive(packet, interfaceID: interfaceID); return }
        await transportInstance.setEnabled(true)
        var interfaces: [ReticulumTransportInterfaceDescriptor] = []
        if let pool = networkInterfacePool {
            interfaces += await pool.readyInterfaceIDs().map { ReticulumTransportInterfaceDescriptor(id: $0, mode: .full) }
        }
        interfaces += rnodeManager.readyInterfaceIDs.map { ReticulumTransportInterfaceDescriptor(id: "rnode:\($0.uuidString)", mode: .full) }
        if autoInterfaceDiscovery.isListening, !autoInterfaceDiscovery.peers.isEmpty {
            interfaces.append(ReticulumTransportInterfaceDescriptor(id: "auto", mode: .internalMode))
        }
        let source = interfaces.first(where: { $0.id == interfaceID })
            ?? ReticulumTransportInterfaceDescriptor(id: interfaceID, mode: interfaceID == "auto" ? .internalMode : .full)
        if !interfaces.contains(where: { $0.id == interfaceID }) { interfaces.append(source) }
        let localDestinations = Set([localDeliveryHash, localVoiceHash].compactMap(Data.init(hexadecimal:)))
        let result = await transportInstance.process(packet, from: source, available: interfaces, localDestinations: localDestinations)
        for forward in result.forwards { await transmitTransportForward(forward) }
        transportInstanceSnapshot = await transportInstance.snapshot()
        if result.deliverLocally { receive(packet, interfaceID: interfaceID) }
    }

    private func transmitTransportForward(_ forward: ReticulumTransportForward) async {
        if forward.interfaceID.hasPrefix("rnode:"),
           let id = UUID(uuidString: String(forward.interfaceID.dropFirst("rnode:".count))) {
            try? await rnodeManager.send(rawPacket: forward.rawPacket, on: id)
        } else if forward.interfaceID == "auto" {
            for peer in autoInterfaceDiscovery.peers { autoInterfaceDiscovery.send(rawPacket: forward.rawPacket, to: peer) }
        } else {
            try? await networkInterfacePool?.send(rawPacket: forward.rawPacket, on: forward.interfaceID)
        }
    }

    private func receive(_ packet: ReticulumPacket, interfaceID: String? = nil) {
        receivedPacketCount += 1
        if packet.destinationHash.hex == localDeliveryHash || packet.packetType == .proof {
            deliveryDebugTrace("RX \(packet.packetType) for \(packet.destinationHash.hex) on \(interfaceID ?? "unknown"), header \(packet.headerType), hops \(packet.hops)")
        }
        if packet.packetType == .proof, packet.context == 0xff {
            receiveLinkProof(packet, interfaceID: interfaceID)
            return
        }
        if packet.packetType == .proof, packet.context == 0x05, packet.destinationType == .link {
            receiveResourceProof(packet)
            return
        }
        if packet.packetType == .linkRequest,
           packet.destinationHash.hex == localDeliveryHash || packet.destinationHash.hex == localVoiceHash {
            acceptIncomingLink(packet, interfaceID: interfaceID, isVoice: packet.destinationHash.hex == localVoiceHash)
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
            receiveOpportunisticPacket(packet, interfaceID: interfaceID)
            return
        }
        guard packet.packetType == .announce else { return }
        let hash = packet.destinationHash.hex
        let announce = try? ReticulumAnnounce(packet: packet)
        let isValidated = announce?.validate() == true
        if isValidated, let announce {
            considerPropagationNode(announce, packet: packet)
            if let interface = ReticulumInterfaceDiscovery.decode(announce, hops: packet.hops) {
                considerDiscoveredNetworkInterface(interface)
            }
            Task {
                _ = await pathTable.ingest(announce, packet: packet, interfaceID: interfaceID)
                await refreshPathState()
                let hash = announce.destinationHash.hex
                if hash == propagationNodeHash, !pendingLinkHashes.contains(hash), !activeLinkHashes.contains(hash) {
                    await requestLink(to: hash)
                }
                if let conversation = conversations.first(where: { $0.destinationHash == hash }) { await attemptDelivery(for: conversation.id) }
            }
        }
        let now = Date.now
        if let index = discoveries.firstIndex(where: { $0.destinationHash == hash }) {
            let existing = discoveries[index]
            let identityChanged = isValidated && (
                !existing.isValidated
                || existing.publicKey != announce?.publicKey
                || existing.appData != announce?.appData
                || existing.ratchet != announce?.ratchet
            )
            let routeChanged = existing.hops != packet.hops
            guard identityChanged || routeChanged || now.timeIntervalSince(existing.lastSeen) >= 2 else { return }
            discoveries[index].hops = packet.hops
            discoveries[index].lastSeen = now
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
        trimDiscoveryCache()
        scheduleDiscoverySave()
    }

    private func considerDiscoveredNetworkInterface(_ candidate: DiscoveredReticulumInterface) {
        let expiry = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        discoveredNetworkInterfaces.removeAll { $0.lastSeen < expiry }
        if let index = discoveredNetworkInterfaces.firstIndex(where: { $0.id == candidate.id }) {
            let firstSeen = discoveredNetworkInterfaces[index].firstSeen
            discoveredNetworkInterfaces[index] = DiscoveredReticulumInterface(
                name: candidate.name,
                host: candidate.host,
                port: candidate.port,
                transportID: candidate.transportID,
                networkID: candidate.networkID,
                hops: candidate.hops,
                stampValue: candidate.stampValue,
                firstSeen: firstSeen,
                lastSeen: candidate.lastSeen
            )
        } else {
            discoveredNetworkInterfaces.append(candidate)
        }
        discoveredNetworkInterfaces.sort {
            if $0.hops != $1.hops { return $0.hops < $1.hops }
            if $0.stampValue != $1.stampValue { return $0.stampValue > $1.stampValue }
            return $0.lastSeen > $1.lastSeen
        }
        if discoveredNetworkInterfaces.count > 32 {
            discoveredNetworkInterfaces.removeLast(discoveredNetworkInterfaces.count - 32)
        }

        guard activeInternetGatewayID != nil,
              ReticulumInterfaceDiscovery.isSafeAutomaticPublicHost(candidate.host),
              autoConnectedDiscoveredInterfaceIDs.count < 3,
              autoConnectedDiscoveredInterfaceIDs.insert(candidate.id).inserted,
              let pool = networkInterfacePool
        else { return }
        let endpoint = ReticulumTCPInterfacePool.Endpoint(
            id: "discovered:\(candidate.id)",
            name: candidate.name,
            host: candidate.host,
            port: candidate.port
        )
        Task { await pool.add(endpoint) }
    }

    private func trimDiscoveryCache(limit: Int = 500) {
        guard discoveries.count > limit else { return }
        let protected = Set(conversations.map(\.destinationHash)).union([localDeliveryHash, localVoiceHash, propagationNodeHash])
        while discoveries.count > limit,
              let index = discoveries.lastIndex(where: { !protected.contains($0.destinationHash) }) {
            discoveries.remove(at: index)
        }
    }

    private func scheduleDiscoverySave() {
        discoverySaveTask?.cancel()
        discoverySaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func considerPropagationNode(_ announce: ReticulumAnnounce, packet: ReticulumPacket) {
        let propagationNameHash = LXMFPropagation.destinationNameHash
        guard LXMFPropagation.isPropagationAnnounce(announce) else { return }
        let hash = announce.destinationHash.hex
        let knownPropagationHashes = Set(discoveries.compactMap { discovery -> String? in
            guard let publicKey = discovery.publicKey else { return nil }
            let identityHash = ReticulumIdentity.truncatedHash(publicKey)
            return ReticulumIdentity.truncatedHash(propagationNameHash + identityHash).hex == discovery.destinationHash
                ? discovery.destinationHash : nil
        }).union([hash])
        discoveredPropagationNodeCount = knownPropagationHashes.count
        guard propagationNodeIsAutomatic else { return }

        let currentHops = discoveries.first(where: { $0.destinationHash == propagationNodeHash })?.hops
        let shouldSelect = !DestinationHash.isValid(propagationNodeHash)
            || propagationNodeHash == hash
            || currentHops == nil
            || packet.hops < (currentHops ?? .max)
        guard shouldSelect else { return }
        let changed = propagationNodeHash != hash
        propagationNodeHash = hash
        UserDefaults.standard.set(hash, forKey: "lxmfPropagationNode")
        if changed {
            Task {
                await requestPath(to: hash)
                if hasPath(to: hash) { await requestLink(to: hash) }
            }
        }
    }

    private func receiveLinkProof(_ packet: ReticulumPacket, interfaceID: String?) {
        let linkID = packet.destinationHash.hex
        guard let request = pendingLinks[linkID] else {
            deliveryDebugTrace("RX link proof \(linkID) has no pending request")
            return
        }
        guard let publicKey = pendingVoicePublicKeys[linkID]
            ?? discoveries.first(where: { $0.destinationHash == request.destinationHash.hex })?.publicKey else {
            deliveryDebugTrace("RX link proof \(linkID) has no destination identity")
            return
        }
        guard let session = try? request.validateProof(packet, destinationPublicKey: publicKey) else {
            deliveryDebugTrace("RX link proof \(linkID) failed validation; bytes=\(packet.data.count), context=\(packet.context)")
            return
        }
        deliveryDebugTrace("RX link proof \(linkID) activated for \(request.destinationHash.hex)")
        activeLinks[linkID] = session
        if let interfaceID { linkInterfaceIDs[linkID] = interfaceID }
        pendingLinks.removeValue(forKey: linkID)
        pendingLinkTimeoutTokens.removeValue(forKey: linkID)
        let destination = request.destinationHash.hex
        linkRemoteDestinations[linkID] = destination
        pendingLinkHashes.remove(destination)
        activeLinkHashes.insert(destination)
        UserDefaults.standard.set(linkID, forKey: "reticulumLastActiveLink")
        UserDefaults.standard.removeObject(forKey: "reticulumLastPendingLink")
        if pendingVoiceConversations[linkID] != nil {
            voiceLinkIDs.insert(linkID)
            activeVoiceLinkID = linkID
            pendingVoicePublicKeys.removeValue(forKey: linkID)
            return
        }
        if destination == propagationNodeHash { Task { await activateAndRequestPropagation(on: session) } }
        else if let conversation = conversations.first(where: { $0.destinationHash == destination }) {
            Task { await activateDirectLink(session, conversationID: conversation.id) }
        }
    }

    private func receiveLinkPacket(_ packet: ReticulumPacket) {
        let linkID = packet.destinationHash.hex
        guard let session = activeLinks[linkID] else {
            deliveryDebugTrace("RX link packet for unknown session \(linkID), context \(packet.context), bytes \(packet.data.count)")
            return
        }
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
            if packet.context == 0xfc {
                guard plaintext == session.linkID else { return }
                removeLink(linkID)
                if voiceLinkIDs.contains(linkID) || activeVoiceLinkID == linkID { finishVoiceCall() }
                return
            }
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
            if packet.context == 0x00 || packet.context == 0xfb || packet.context == 0xfe {
                if voiceLinkIDs.contains(linkID), handleVoiceLinkPacket(packet, plaintext: plaintext, session: session) { return }
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

    private func acceptIncomingLink(_ packet: ReticulumPacket, interfaceID: String?, isVoice: Bool = false) {
        guard let incoming = try? ReticulumIncomingLink(request: packet, localIdentity: messagingIdentity) else {
            deliveryDebugTrace("RX link request rejected; bytes=\(packet.data.count)")
            return
        }
        let linkID = incoming.session.linkID.hex
        deliveryDebugTrace("RX link request \(linkID) accepted; returning proof")
        activeLinks[linkID] = incoming.session
        if let interfaceID { linkInterfaceIDs[linkID] = interfaceID }
        inboundLinkIDs.insert(linkID)
        if isVoice { voiceLinkIDs.insert(linkID) }
        Task {
            do {
                if let interfaceID { try await transmitRawPacket(incoming.proofPacket, on: interfaceID) }
                else { try await transmitRawPacket(incoming.proofPacket) }
                inboundLinksAccepted += 1
                if isVoice {
                    if voiceCall != nil {
                        try await sendVoiceSignal(.busy, on: incoming.session)
                        await closeVoiceLink(incoming.session)
                    } else {
                        try await sendVoiceSignal(.available, on: incoming.session)
                    }
                }
            }
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
            bind(session: session, to: identity)
            return
        }
        guard packet.context == 0x00, let message = try? LXMFReceivedMessage(packed: plaintext), message.destinationHash.hex == localDeliveryHash else { return }
        let remoteIdentity = inboundRemoteIdentities[session.linkID.hex] ?? discoveries.first(where: { $0.destinationHash == message.sourceHash.hex }).flatMap { $0.publicKey }.flatMap { try? ReticulumIdentity(publicKey: $0) }
        guard let remoteIdentity, message.validate(with: remoteIdentity) else { return }
        bind(session: session, to: remoteIdentity)
        Task {
            let wasPreviouslyReceived = receivedLXMFIDs.contains(message.messageID.hex)
            let accepted = wasPreviouslyReceived ? true : await importReceivedResourceMessage(message, sourceIdentity: remoteIdentity)
            guard accepted else { return }
            do {
                let hash = packet.packetHash
                let proofData = hash + (try messagingIdentity.sign(hash))
                let proof = Data([0x0f, 0x00]) + session.linkID + Data([0x00]) + proofData
                try await transmitRawPacket(proof)
            } catch {
                // The sender retains the message until it receives this proof
                // and will retry idempotently. Interface transitions are
                // therefore recoverable background state, not a user-facing
                // modal error on the receiving device.
                deliveryDebugTrace("RX direct proof send deferred after interface loss: \(error.localizedDescription)")
            }
        }
    }

    /// Handles LXST telephony payloads before the normal LXMF link decoder.
    /// Returns true when the packet belongs to the voice primitive.
    private func handleVoiceLinkPacket(_ packet: ReticulumPacket, plaintext: Data, session: ReticulumLinkSession) -> Bool {
        let linkID = session.linkID.hex
        if packet.context == 0xfe { return true }
        if packet.context == 0xfb {
            guard plaintext.count == 128 else { return true }
            let publicKey = Data(plaintext.prefix(64))
            let signature = Data(plaintext.suffix(64))
            guard let identity = try? ReticulumIdentity(publicKey: publicKey),
                  identity.validate(signature: signature, message: session.linkID + publicKey) else { return true }
            inboundRemoteIdentities[linkID] = identity
            let deliveryNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
            let deliveryHash = ReticulumIdentity.truncatedHash(deliveryNameHash + identity.hash).hex
            if !conversations.contains(where: { $0.destinationHash == deliveryHash }) {
                let name = discoveries.first(where: { $0.destinationHash == deliveryHash })?.announcedDisplayName ?? "Caller \(deliveryHash.prefix(8))"
                _ = addConversation(destinationHash: deliveryHash, displayName: name, select: false)
            }
            guard let conversation = conversations.first(where: { $0.destinationHash == deliveryHash }),
                  !conversation.isBlocked,
                  !voiceTrustedOnly || conversation.isTrusted else {
                Task { try? await sendVoiceSignal(.rejected, on: session); await closeVoiceLink(session) }
                return true
            }
            if voiceCall != nil {
                Task { try? await sendVoiceSignal(.busy, on: session); await closeVoiceLink(session) }
                return true
            }
            activeVoiceLinkID = linkID
            var call = VoiceCall(conversationID: conversation.id, direction: .incoming, state: .incoming, profile: preferredVoiceProfile)
            call.state = .incoming
            voiceCall = call
            scheduleVoiceTimeout(callID: call.id, seconds: 60)
            Task {
                try? await sendVoiceSignal(.ringing, on: session)
                if !isApplicationActive { await notifications.notifyIncomingCall(conversationID: conversation.id, callerName: conversation.displayName) }
            }
            return true
        }
        guard packet.context == 0x00, let event = try? LXSTVoice.decode(plaintext) else { return packet.context == 0x00 }
        switch event {
        case .signals(let signals):
            for signal in signals { handleVoiceSignal(signal, session: session) }
        case .frame(let codec, let payload):
            if codec == voiceCall?.profile.codec, voiceCall?.state == .active { voiceFrameHandler?(codec, payload) }
        }
        return true
    }

    private func handleVoiceSignal(_ value: UInt64, session: ReticulumLinkSession) {
        let linkID = session.linkID.hex
        if value >= 0xff, let profile = LXSTVoice.Profile(rawValue: value - 0xff), profile.isLocallySupported {
            voiceCall?.profile = profile
            return
        }
        guard let signal = LXSTVoice.Signal(rawValue: value) else { return }
        switch signal {
        case .available:
            guard voiceCall?.direction == .outgoing, pendingVoiceConversations[linkID] != nil else { return }
            Task {
                do {
                    let signedData = session.linkID + messagingIdentity.publicKey
                    let identifyData = messagingIdentity.publicKey + (try messagingIdentity.sign(signedData))
                    try await transmitRawPacket(try session.encryptedPacket(identifyData, context: 0xfb))
                    try await transmitRawPacket(try session.encryptedPacket(LXSTVoice.preferredProfile(voiceCall?.profile ?? preferredVoiceProfile)))
                } catch { finishVoiceCall(failure: "Voice identity exchange failed.") }
            }
        case .ringing:
            if voiceCall?.direction == .outgoing { voiceCall?.state = .ringing }
        case .connecting:
            guard var call = voiceCall, call.direction == .outgoing else { return }
            call.state = .active
            call.connectedAt = .now
            voiceCall = call
            Task { try? await sendVoiceSignal(.established, on: session) }
        case .established:
            if var call = voiceCall {
                call.state = .active
                call.connectedAt = call.connectedAt ?? .now
                voiceCall = call
            }
        case .busy:
            finishVoiceCall(failure: "The contact is already on another call.")
        case .rejected:
            finishVoiceCall(failure: "The contact declined the call.")
        case .calling:
            break
        }
    }

    private func sendVoiceSignal(_ signal: LXSTVoice.Signal, on session: ReticulumLinkSession) async throws {
        try await transmitRawPacket(try session.encryptedPacket(LXSTVoice.signalling([signal.rawValue])))
    }

    private func closeVoiceLink(_ session: ReticulumLinkSession) async {
        try? await transmitRawPacket(try session.closePacket())
        removeLink(session.linkID.hex)
    }

    private func removeLink(_ linkID: String) {
        let remote = linkRemoteDestinations.removeValue(forKey: linkID)
        activeLinks.removeValue(forKey: linkID)
        inboundLinkIDs.remove(linkID)
        inboundRemoteIdentities.removeValue(forKey: linkID)
        linkInterfaceIDs.removeValue(forKey: linkID)
        voiceLinkIDs.remove(linkID)
        pendingVoiceConversations.removeValue(forKey: linkID)
        pendingVoicePublicKeys.removeValue(forKey: linkID)
        if activeVoiceLinkID == linkID { activeVoiceLinkID = nil }
        if let remote, !linkRemoteDestinations.values.contains(remote) { activeLinkHashes.remove(remote) }
    }

    private func scheduleVoiceTimeout(callID: UUID, seconds: TimeInterval) {
        voiceCallTimeoutTask?.cancel()
        voiceCallTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.voiceCall?.id == callID else { return }
            if let linkID = self?.activeVoiceLinkID, let session = self?.activeLinks[linkID] {
                await self?.closeVoiceLink(session)
            }
            self?.finishVoiceCall(failure: "The voice call timed out.")
        }
    }

    private func finishVoiceCall(failure: String? = nil) {
        voiceCallTimeoutTask?.cancel()
        voiceCallTimeoutTask = nil
        guard var call = voiceCall else { return }
        call.state = failure == nil ? .idle : .failed
        call.endedAt = .now
        call.failureReason = failure
        voiceCallHistory.insert(call, at: 0)
        voiceCallHistory = Array(voiceCallHistory.prefix(100))
        voiceCall = nil
        if let linkID = activeVoiceLinkID { removeLink(linkID) }
        for linkID in pendingVoiceConversations.keys {
            pendingLinks.removeValue(forKey: linkID)
            pendingLinkTimeoutTokens.removeValue(forKey: linkID)
            pendingVoicePublicKeys.removeValue(forKey: linkID)
        }
        pendingVoiceConversations.removeAll()
        activeVoiceLinkID = nil
        if let failure { lastError = failure }
        save()
    }

    private func bind(session: ReticulumLinkSession, to remoteIdentity: ReticulumIdentity) {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let destinationHash = ReticulumIdentity.truncatedHash(nameHash + remoteIdentity.hash).hex
        let linkID = session.linkID.hex
        guard linkRemoteDestinations[linkID] != destinationHash else { return }
        linkRemoteDestinations[linkID] = destinationHash
        activeLinkHashes.insert(destinationHash)
        clearPendingLinks(to: destinationHash)
        if let conversation = conversations.first(where: { $0.destinationHash == destinationHash }) {
            Task { await attemptDelivery(for: conversation.id) }
        }
    }

    private func activeSession(to destinationHash: String) -> ReticulumLinkSession? {
        activeLinks.first { linkRemoteDestinations[$0.key] == destinationHash }.map(\.value)
    }

    private func receiveOpportunisticPacket(_ packet: ReticulumPacket, interfaceID: String?) {
        guard let decrypted = try? messagingIdentity.decrypt(packet.data) else {
            deliveryDebugTrace("RX opportunistic decrypt failed")
            return
        }
        guard let message = try? LXMFReceivedMessage(packed: packet.destinationHash + decrypted),
              message.destinationHash.hex == localDeliveryHash else {
            deliveryDebugTrace("RX opportunistic LXMF decode failed")
            return
        }
        guard let discovery = discoveries.first(where: { $0.destinationHash == message.sourceHash.hex }),
              let publicKey = discovery.publicKey,
              let sourceIdentity = try? ReticulumIdentity(publicKey: publicKey) else {
            deliveryDebugTrace("RX opportunistic sender identity unavailable: \(message.sourceHash.hex)")
            return
        }
        guard message.validate(with: sourceIdentity) else {
            deliveryDebugTrace("RX opportunistic signature invalid: \(message.sourceHash.hex)")
            return
        }
        deliveryDebugTrace("RX opportunistic LXMF accepted from \(message.sourceHash.hex)")
        let wasPreviouslyReceived = receivedLXMFIDs.contains(message.messageID.hex)
        guard wasPreviouslyReceived || importReceivedMessage(message, sourceIdentity: sourceIdentity) else { return }
        if !wasPreviouslyReceived { opportunisticDeliveriesReceived += 1 }
        Task {
            do {
                let proof = try ReticulumProof.packet(for: packet, identity: messagingIdentity)
                if let interfaceID { try await transmitRawPacket(proof, on: interfaceID) }
                else { try await transmitRawPacket(proof) }
            }
            catch { deliveryDebugTrace("RX proof send deferred after interface loss: \(error.localizedDescription)") }
        }
    }

    private func deliveryDebugTrace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SIDEBAND_SOAK_NETWORK_MODE"] != nil else { return }
        print("SIDEBAND_DELIVERY_TRACE \(message())")
        #endif
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
            for conversation in conversations { await propagateQueued(for: conversation.id) }
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
              !receivedLXMFIDs.contains(message.messageID.hex),
              message.payload.count <= SidebandMessageLimits.maximumWireMessageBytes,
              message.timestamp.isFinite,
              supportedMessageDates.contains(Date(timeIntervalSince1970: message.timestamp)),
              message.title.count <= 1_024,
              messages.count < 250_000 else { return false }
        let source = message.sourceHash.hex
        if isSourceBlocked(source) {
            rememberReceivedLXMFID(message.messageID.hex)
            return true
        }
        if !conversations.contains(where: { $0.destinationHash == source }) {
            let name = discoveries.first(where: { $0.destinationHash == source })?.announcedDisplayName ?? "Received \(source.prefix(8))"
            _ = addConversation(destinationHash: source, displayName: name, select: false)
        }
        guard let conversation = conversations.first(where: { $0.destinationHash == source }),
              let body = String(data: message.content, encoding: .utf8),
              isAcceptableMessageBody(body) else { return false }
        let telemetry = message.binaryField(0x02).flatMap { try? SidebandTelemetry(packed: $0) }
        let telemetryStream = SidebandTelemetryStreamEntry.decode(message.fields[0x03])
        let voiceAudio = LXMFVoiceMessageAudio(field: message.fields[0x07])
        let replyTo = message.binaryField(0x30)
        let replyQuote = message.binaryField(0x31).flatMap { String(data: $0, encoding: .utf8) }
        let reactionTarget = message.binaryMapField(0x40, key: 0x00)
        let reactionContent = message.binaryMapField(0x40, key: 0x01).flatMap { String(data: $0, encoding: .utf8) }
        let commentTo = message.binaryMapField(0x41, key: 0x00)
        let continuationOf = message.binaryMapField(0x42, key: 0x00)
        let commands = LXMFCommand.decode(message.fields[0x09])
        guard (message.fields[0x07] == nil || voiceAudio != nil),
              replyTo == nil || replyTo?.count == 32,
              isAcceptableReplyQuote(replyQuote),
              commentTo == nil || commentTo?.count == 32,
              continuationOf == nil || continuationOf?.count == 32 else { return false }
        if message.fields[0x40] != nil {
            guard let reactionTarget, let reactionContent,
                  Message.isValidReaction(content: reactionContent, target: reactionTarget) else { return false }
            if messages.contains(where: {
                $0.conversationID == conversation.id && $0.direction == .incoming &&
                $0.reactionTo == reactionTarget && $0.reactionContent == reactionContent
            }) {
                rememberReceivedLXMFID(message.messageID.hex)
                return true
            }
        }
        let renderer = message.unsignedField(0x0F).flatMap { UInt8(exactly: $0) }.flatMap(Message.Renderer.init(rawValue:)) ?? .plain
        let incomingMessage = Message(
            conversationID: conversation.id,
            body: body,
            timestamp: Date(timeIntervalSince1970: message.timestamp),
            direction: .incoming,
            state: .delivered,
            telemetry: telemetry,
            telemetryStream: telemetryStream,
            voiceAudio: voiceAudio,
            renderer: renderer,
            lxmfID: message.messageID,
            replyTo: replyTo,
            replyQuote: replyQuote,
            reactionTo: reactionTarget,
            reactionContent: reactionContent,
            commentTo: commentTo,
            continuationOf: continuationOf,
            commands: commands
        )
        messages.append(incomingMessage)
        if message.fields[0x09] != nil {
            rememberReceivedLXMFID(message.messageID.hex)
            save()
            if conversation.isTrusted, isConversationIdentityVerified(conversation.id), !commands.isEmpty {
                Task { await handleIncomingCommands(commands, conversationID: conversation.id) }
            }
            return true
        }
        noteIncomingActivity(in: conversation.id)
        rememberReceivedLXMFID(message.messageID.hex)
        save()
        if shouldNotifyIncoming(for: conversation.id) {
            Task {
                await notifications.notifyIncoming(
                    conversationID: conversation.id,
                    messageID: incomingMessage.id,
                    title: conversation.displayName,
                    body: reactionContent.map { "Reacted \($0)" } ?? (voiceAudio == nil ? body : "Voice message"),
                    showPreview: shouldShowNotificationPreview(for: conversation.id)
                )
            }
        }
        return true
    }

    /// Imports the standard Python LXMF file and image fields before a
    /// delivery proof is emitted. Staging first avoids acknowledging a message
    /// whose attachment could not be durably saved.
    private func importReceivedResourceMessage(_ message: LXMFReceivedMessage, sourceIdentity: ReticulumIdentity) async -> Bool {
        guard let payloads = standardLXMFResourcePayloads(message) else { return false }
        if payloads.isEmpty { return importReceivedMessage(message, sourceIdentity: sourceIdentity) }
        guard payloads.count <= SidebandMessageLimits.maximumAttachments,
              payloads.reduce(0, { $0 + $1.data.count }) <= SidebandMessageLimits.maximumCombinedAttachmentBytes else { return false }
        var staged: [Attachment] = []
        for payload in payloads {
            guard let attachment = try? await attachmentStore.save(
                data: payload.data,
                filename: payload.filename,
                mimeType: payload.mimeType
            ) else { return false }
            staged.append(attachment)
        }
        guard importReceivedMessage(message, sourceIdentity: sourceIdentity),
              let index = messages.firstIndex(where: { $0.lxmfID == message.messageID && $0.direction == .incoming }) else { return false }
        messages[index].attachments = staged
        save()
        return true
    }

    private func standardLXMFResourcePayloads(_ message: LXMFReceivedMessage) -> [(filename: String, mimeType: String?, data: Data)]? {
        var payloads: [(String, String?, Data)] = []
        if let value = message.fields[0x05] {
            guard case let .array(files) = value else { return nil }
            for file in files {
                guard case let .array(parts) = file, parts.count == 2,
                      let name = messagePackString(parts[0]),
                      case let .binary(data) = parts[1],
                      !name.isEmpty, name.count <= 180, name.utf8.count <= 720,
                      data.count <= ReticulumResourceLimits.maximumAttachmentBytes else { return nil }
                payloads.append((name, nil, data))
            }
        }
        if let value = message.fields[0x06] {
            guard case let .array(parts) = value, parts.count == 2,
                  let rawExtension = messagePackString(parts[0]),
                  case let .binary(data) = parts[1],
                  data.count <= ReticulumResourceLimits.maximumAttachmentBytes else { return nil }
            let ext = rawExtension.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)
            guard !ext.isEmpty else { return nil }
            payloads.append(("image.\(ext)", "image/\(ext)", data))
        }
        return payloads
    }

    private func messagePackString(_ value: MessagePackValue) -> String? {
        switch value {
        case .string(let string): string
        case .binary(let data): String(data: data, encoding: .utf8)
        default: nil
        }
    }

    private func transmitRawPacket(_ packet: Data) async throws {
        var transmitted = false
        var finalError: Error?
        let linkedInterfaceID = (try? ReticulumPacket(raw: packet)).flatMap { linkInterfaceIDs[$0.destinationHash.hex] }
        if let linkedInterfaceID, linkedInterfaceID.hasPrefix("rnode:"),
           let id = UUID(uuidString: String(linkedInterfaceID.dropFirst("rnode:".count))) {
            do { try await rnodeManager.send(rawPacket: packet, on: id); transmitted = true }
            catch { finalError = error }
        } else if let networkInterfacePool, tcpNetworkState == .ready {
            do {
                if let interfaceID = linkedInterfaceID { try await networkInterfacePool.send(rawPacket: packet, on: interfaceID) }
                else { try await networkInterfacePool.send(rawPacket: packet) }
                transmitted = true
            } catch {
                finalError = error
            }
        }
        if linkedInterfaceID == nil, rnodeManager.hasReadyInterface {
            do { _ = try await rnodeManager.send(rawPacket: packet); transmitted = true }
            catch { finalError = error }
        }
        for peer in autoInterfaceDiscovery.peers {
            autoInterfaceDiscovery.send(rawPacket: packet, to: peer)
            transmitted = true
        }
        if !transmitted { throw finalError ?? TransportError.nativeEngineUnavailable }
    }

    /// Sends a response back on the interface where its triggering packet was
    /// received. Reticulum reverse-path state is interface-specific, so proofs
    /// must not be broadcast across unrelated public gateways.
    private func transmitRawPacket(_ packet: Data, on interfaceID: String) async throws {
        if interfaceID.hasPrefix("rnode:"),
           let id = UUID(uuidString: String(interfaceID.dropFirst("rnode:".count))) {
            try await rnodeManager.send(rawPacket: packet, on: id)
            return
        }
        if interfaceID == "auto" {
            guard !autoInterfaceDiscovery.peers.isEmpty else { throw TransportError.nativeEngineUnavailable }
            for peer in autoInterfaceDiscovery.peers { autoInterfaceDiscovery.send(rawPacket: packet, to: peer) }
            return
        }
        guard let networkInterfacePool, tcpNetworkState == .ready else { throw TransportError.nativeEngineUnavailable }
        try await networkInterfacePool.send(rawPacket: packet, on: interfaceID)
    }

    private func transmitDestinationPacket(_ packet: Data, destinationHash: Data) async throws {
        var transmitted = false
        if let networkInterfacePool, tcpNetworkState == .ready {
            let interfaceIDs = await networkInterfacePool.readyInterfaceIDs()
            var tcpSent = false
            if let path = await pathTable.path(to: destinationHash),
               let interfaceID = path.interfaceID,
               interfaceIDs.contains(interfaceID) {
                do {
                    let routedPacket = try ReticulumPacket(raw: packet).prepared(for: path)
                    try await networkInterfacePool.send(rawPacket: routedPacket, on: interfaceID)
                    tcpSent = true
                    let routeDescription = path.hops > 1 ? "routed via \(path.nextHop?.hex ?? "unknown")" : "direct"
                    deliveryDebugTrace("TX \(destinationHash.hex) on \(interfaceID), \(path.hops) hop(s), \(routeDescription)")
                } catch {
                    deliveryDebugTrace("TX \(destinationHash.hex) on \(interfaceID) failed: \(error.localizedDescription)")
                }
            } else {
                // Path discovery has not selected a route yet. Preserve the
                // Reticulum broadcast fallback for directly attached peers.
                for interfaceID in interfaceIDs {
                    do {
                        try await networkInterfacePool.send(rawPacket: packet, on: interfaceID)
                        tcpSent = true
                    } catch {
                        deliveryDebugTrace("TX \(destinationHash.hex) fallback on \(interfaceID) failed: \(error.localizedDescription)")
                    }
                }
            }
            transmitted = tcpSent
        }
        for id in rnodeManager.readyInterfaceIDs {
            let interfaceID = "rnode:\(id.uuidString)"
            let routedPacket: Data
            if let path = await pathTable.path(to: destinationHash, on: interfaceID) {
                routedPacket = (try? ReticulumPacket(raw: packet).prepared(for: path)) ?? packet
            } else {
                routedPacket = packet
            }
            if (try? await rnodeManager.send(rawPacket: routedPacket, on: id)) != nil { transmitted = true }
        }
        for peer in autoInterfaceDiscovery.peers {
            autoInterfaceDiscovery.send(rawPacket: packet, to: peer)
            transmitted = true
        }
        if !transmitted { throw TransportError.nativeEngineUnavailable }
    }

    private func attemptDelivery(for conversationID: UUID) async {
        guard deliveryPassesInProgress.insert(conversationID).inserted else {
            deliveryPassRerunRequested.insert(conversationID)
            return
        }
        defer {
            deliveryPassesInProgress.remove(conversationID)
            if deliveryPassRerunRequested.remove(conversationID) != nil {
                Task { await attemptDelivery(for: conversationID) }
            }
        }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let pending = messages.filter {
            $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= .now && ownsOutbox($0)
        }
        guard !pending.isEmpty else { return }
        let attachmentMessages = pending.filter { !$0.attachments.isEmpty }
        guard let destination = Data(hexadecimal: conversation.destinationHash),
              let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash && $0.isValidated }),
              let publicKey = discovery.publicKey,
              let recipient = try? ReticulumIdentity(publicKey: publicKey) else {
            if !isPathPending(to: conversation.destinationHash) { await requestPath(to: conversation.destinationHash) }
            return
        }
        if !hasPath(to: conversation.destinationHash) {
            if !isPathPending(to: conversation.destinationHash) { await requestPath(to: conversation.destinationHash) }
        }
        let sourceNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(sourceNameHash + messagingIdentity.hash)
        if conversation.deliveryPreference == .propagationPreferred,
           activeLinks.values.contains(where: { $0.destinationHash.hex == propagationNodeHash }) {
            await propagateQueued(for: conversationID)
        }
        let remainingQueued = messages.filter {
            $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= .now && $0.attachments.isEmpty && ownsOutbox($0)
        }
        let maximumInFlightReceipts = 24
        let inFlightForDestination = pendingReceipts.values.count { $0.destinationHash == conversation.destinationHash }
        let availableReceiptSlots = max(0, maximumInFlightReceipts - inFlightForDestination)
        let forceDirectLink = directLinkFallbackDestinations.contains(conversation.destinationHash)
        var requiresLink = !attachmentMessages.isEmpty || forceDirectLink
        for item in forceDirectLink ? [] : Array(remainingQueued.prefix(availableReceiptSlots)) {
            do {
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, timestamp: item.timestamp.timeIntervalSince1970, content: Data(item.body.utf8), fields: lxmfFields(for: item), encodedFields: lxmfEncodedFields(for: item))
                recordLXMFID(lxmf.messageID, for: item.id)
                let raw = try lxmf.opportunisticPacket(recipientIdentity: recipient, ratchet: discovery.ratchet)
                guard raw.count <= 500 else { requiresLink = true; continue }
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(messageID: item.id, kind: .opportunistic, destinationHash: conversation.destinationHash)
                recordDeliveryAttempt(item.id, mode: .opportunistic)
                try await transmitDestinationPacket(raw, destinationHash: destination)
                updateMessage(item.id, state: .sent)
                scheduleReceiptTimeout(packetHash)
            } catch {
                removePendingReceipts(for: item.id)
                recordDeliveryFailure(item.id, reason: "Opportunistic send failed; trying an encrypted link.")
                requiresLink = true
            }
        }
        guard requiresLink else { return }
        if !activeLinkHashes.contains(conversation.destinationHash) {
            if !pendingLinkHashes.contains(conversation.destinationHash) { await requestLink(to: conversation.destinationHash) }
            return
        }
        guard let session = activeSession(to: conversation.destinationHash) else { return }
        let directSlots = max(0, maximumInFlightReceipts - pendingReceipts.values.count { $0.destinationHash == conversation.destinationHash })
        for item in messages.filter({ $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= .now && $0.attachments.isEmpty && ownsOutbox($0) }).prefix(directSlots) {
            guard item.attachments.isEmpty else { continue }
            do {
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, timestamp: item.timestamp.timeIntervalSince1970, content: Data(item.body.utf8), fields: lxmfFields(for: item), encodedFields: lxmfEncodedFields(for: item))
                recordLXMFID(lxmf.messageID, for: item.id)
                if lxmf.packed.count > 400 {
                    try await advertiseLXMFResource(lxmf.packed, messageID: item.id, session: session)
                    continue
                }
                let raw = try session.encryptedPacket(lxmf.packed)
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(messageID: item.id, kind: .direct, destinationHash: conversation.destinationHash)
                recordDeliveryAttempt(item.id, mode: .directLink)
                try await transmitRawPacket(raw)
                updateMessage(item.id, state: .sent)
                scheduleReceiptTimeout(packetHash)
            } catch {
                removePendingReceipts(for: item.id)
                recordDeliveryFailure(item.id, reason: "Encrypted-link delivery failed.")
                lastError = "LXMF delivery failed: \(error.localizedDescription)"
            }
        }
        // Serialize attachment resources per conversation. Reticulum resource
        // receivers intentionally cap concurrent reassemblies; advertising an
        // entire backlog at once causes otherwise-valid transfers to be
        // rejected during reconnect bursts. The next resource is started from
        // receiveResourceProof() after this one is durably accepted.
        let hasActiveResourceForConversation = outgoingResources.values.contains { resource in
            messages.first(where: { $0.id == resource.messageID })?.conversationID == conversationID
        }
        if !hasActiveResourceForConversation,
           let nextAttachmentMessage = attachmentMessages.first(where: { message in
               message.attachments.contains(where: { $0.state == .local || $0.state == .queued })
           }) {
            await advertiseAttachments(for: nextAttachmentMessage, session: session)
        }
    }

    private func advertiseAttachments(for message: Message, session: ReticulumLinkSession) async {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(nameHash + messagingIdentity.hash)
        guard let attachment = message.attachments.first(where: { $0.state == .local || $0.state == .queued }) else { return }
        do {
            let data = try await attachmentStore.read(attachment)
            var encodedFields = lxmfEncodedFields(for: message)
            if attachment.mimeType?.lowercased().hasPrefix("image/") == true {
                let ext = URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()
                let format = ext.isEmpty ? "png" : ext
                encodedFields[0x06] = MessagePack.array([
                    MessagePack.binary(Data(format.utf8)), MessagePack.binary(data)
                ])
            } else {
                encodedFields[0x05] = MessagePack.array([
                    MessagePack.array([
                        MessagePack.binary(Data(attachment.filename.utf8)), MessagePack.binary(data)
                    ])
                ])
            }
            guard let conversation = conversations.first(where: { $0.id == message.conversationID }),
                  let destination = Data(hexadecimal: conversation.destinationHash) else { return }
            let lxmf = try LXMFMessage(
                destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity,
                timestamp: message.timestamp.timeIntervalSince1970, content: Data(message.body.utf8),
                fields: lxmfFields(for: message), encodedFields: encodedFields
            )
            recordLXMFID(lxmf.messageID, for: message.id)
            let segments = try ReticulumResourceSegmentPlanner.prepare(data: lxmf.packed, session: session, hasMetadata: false)
            guard let first = segments.first else { return }
            registerOutgoingSegment(first, remaining: Array(segments.dropFirst()), messageID: message.id, attachmentID: attachment.id, session: session)
            recordDeliveryAttempt(message.id, mode: .resource)
            updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .transferring, progress: 0)
            deliveryDebugTrace("TX attachment resource \(first.manifest.resourceHash.hex) on link \(session.linkID.hex), \(first.parts.count) parts")
            try await transmitRawPacket(try session.resourceAdvertisementPacket(first.advertisement))
        } catch {
            recordDeliveryFailure(message.id, reason: "Attachment transfer could not start.")
            updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .failed, progress: 0)
        }
    }

    private func advertiseLXMFResource(_ packed: Data, messageID: UUID, session: ReticulumLinkSession) async throws {
        let segments = try ReticulumResourceSegmentPlanner.prepare(data: packed, session: session, hasMetadata: false)
        guard let first = segments.first else { return }
        registerOutgoingSegment(first, remaining: Array(segments.dropFirst()), messageID: messageID, attachmentID: nil, session: session)
        recordDeliveryAttempt(messageID, mode: .resource)
        updateMessage(messageID, state: .sent)
        try await transmitRawPacket(try session.resourceAdvertisementPacket(first.advertisement))
    }

    private func registerOutgoingSegment(_ segment: ReticulumPreparedResourceSegment, remaining: [ReticulumPreparedResourceSegment], messageID: UUID, attachmentID: UUID?, session: ReticulumLinkSession) {
        outgoingResources[segment.manifest.resourceHash.hex] = OutgoingResource(
            manifest: segment.manifest, parts: segment.parts, expectedProof: segment.expectedProof,
            messageID: messageID, attachmentID: attachmentID, linkID: session.linkID.hex,
            segmentIndex: segment.index, totalSegments: segment.totalSegments, remainingSegments: remaining
        )
        scheduleResourceTimeout(hash: segment.manifest.resourceHash.hex, incoming: false)
    }

    private func handleResourceRequest(_ plaintext: Data, session: ReticulumLinkSession) {
        guard let request = try? ReticulumResourceRequest(encoded: plaintext), var resource = outgoingResources[request.resourceHash.hex], resource.linkID == session.linkID.hex else {
            deliveryDebugTrace("RX unmatched resource request on link \(session.linkID.hex)")
            return
        }
        deliveryDebugTrace("RX resource request \(request.resourceHash.hex) for \(request.requestedPartHashes.count) parts")
        resource.timeoutToken = UUID()
        outgoingResources[request.resourceHash.hex] = resource
        scheduleResourceTimeout(hash: request.resourceHash.hex, incoming: false)
        Task {
            for requestedHash in request.requestedPartHashes {
                guard let index = resource.manifest.partHashes.firstIndex(of: requestedHash) else { continue }
                do {
                    try await transmitRawPacket(session.resourcePartPacket(resource.parts[index]))
                    resource.sentIndices.insert(index)
                    deliveryDebugTrace("TX resource part \(index + 1)/\(resource.parts.count) for \(request.resourceHash.hex) on link \(session.linkID.hex)")
                } catch {
                    deliveryDebugTrace("TX resource part failed for \(request.resourceHash.hex): \(error.localizedDescription)")
                    return
                }
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
            if let attachmentID = resource.attachmentID {
                updateAttachment(messageID: resource.messageID, attachmentID: attachmentID, state: .transferring, progress: progress)
            }
        }
    }

    private func receiveResourceProof(_ packet: ReticulumPacket) {
        guard packet.data.count == 64 else { return }
        let hash = Data(packet.data.prefix(32))
        guard let resource = outgoingResources[hash.hex], packet.destinationHash.hex == resource.linkID,
              Data(packet.data.suffix(32)) == resource.expectedProof else {
            deliveryDebugTrace("RX unmatched resource proof for \(hash.hex)")
            return
        }
        deliveryDebugTrace("RX resource proof \(hash.hex)")
        outgoingResources.removeValue(forKey: hash.hex)
        if let next = resource.remainingSegments.first, let session = activeLinks[resource.linkID] {
            let remaining = Array(resource.remainingSegments.dropFirst())
            registerOutgoingSegment(next, remaining: remaining, messageID: resource.messageID, attachmentID: resource.attachmentID, session: session)
            if let attachmentID = resource.attachmentID {
                updateAttachment(messageID: resource.messageID, attachmentID: attachmentID, state: .transferring, progress: Double(resource.segmentIndex) / Double(resource.totalSegments))
            }
            Task { try? await transmitRawPacket(try session.resourceAdvertisementPacket(next.advertisement)) }
            return
        }
        if let attachmentID = resource.attachmentID {
            updateAttachment(messageID: resource.messageID, attachmentID: attachmentID, state: .available, progress: 1)
        }
        if resource.attachmentID == nil || (messages.first(where: { $0.id == resource.messageID })?.attachments.allSatisfy({ $0.state == .available }) == true) {
            updateMessage(resource.messageID, state: .delivered)
        }
        if let conversationID = messages.first(where: { $0.id == resource.messageID })?.conversationID {
            Task { await attemptDelivery(for: conversationID) }
        }
    }

    private func acceptResourceAdvertisement(_ plaintext: Data, session: ReticulumLinkSession) {
        guard let advertisement = try? ReticulumResourceAdvertisement(encoded: plaintext) else {
            deliveryDebugTrace("RX invalid resource advertisement on link \(session.linkID.hex)")
            return
        }
        if let proof = receivedResourceProofs[advertisement.resourceHash.hex] {
            // Resource advertisements are retried when their proof is lost.
            // Re-acknowledge a payload already accepted on this live session
            // instead of transferring or importing it a second time.
            Task { try? await transmitRawPacket(Data([0x0f, 0x00]) + session.linkID + Data([0x05]) + proof) }
            return
        }
        guard
              advertisement.flags & 0x01 == 0x01,
              incomingResources.count < ReticulumResourceLimits.maximumConcurrentIncoming,
              ReticulumResourceLimits.accepts(
                  dataSize: advertisement.dataSize,
                  transferSize: advertisement.transferSize,
                  partCount: advertisement.partCount,
                  segments: advertisement.totalSegments,
                  segmentIndex: advertisement.segmentIndex,
                  advertisedPartHashCount: advertisement.partHashes.count
              ),
              !receivedResourceHashes.contains(advertisement.resourceHash.hex),
              let manifest = try? ReticulumResourceManifest(advertisement: advertisement) else {
            deliveryDebugTrace("RX rejected resource advertisement \(advertisement.resourceHash.hex), incoming=\(incomingResources.count), parts=\(advertisement.partCount), bytes=\(advertisement.dataSize)")
            return
        }
        deliveryDebugTrace("RX resource advertisement \(advertisement.resourceHash.hex) on link \(session.linkID.hex), \(advertisement.partCount) parts")
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
        guard let match else {
            deliveryDebugTrace("RX unmatched resource part on link \(session.linkID.hex), bytes \(part.count)")
            return
        }
        let hash = match.key
        var incoming = match.value
        guard let index = incoming.receiver.missingPartIndices.first(where: { incoming.receiver.expectedHash(at: $0) == Data(ReticulumIdentity.fullHash(part + incoming.receiver.manifest.randomHash).prefix(4)) }) else { return }
        do { try incoming.receiver.accept(part: part, at: index) } catch { return }
        incoming.timeoutToken = UUID()
        incomingResources[hash] = incoming
        incomingResourceProgress[incoming.advertisement.originalHash.hex] = (Double(incoming.advertisement.segmentIndex - 1) + incoming.receiver.progress) / Double(incoming.advertisement.totalSegments)
        scheduleResourceTimeout(hash: hash, incoming: true)
        if incoming.receiver.isComplete { Task { await finishIncomingResource(resourceHash: hash) } }
        else if incoming.receiver.receivedPartCount.isMultiple(of: 4)
                    || (incoming.receiver.missingPartIndices.isEmpty && incoming.receiver.needsMoreHashMap) {
            requestIncomingResourceParts(resourceHash: hash)
        }
    }

    private func finishIncomingResource(resourceHash: String) async {
        guard let incoming = incomingResources.removeValue(forKey: resourceHash),
              let encrypted = try? incoming.receiver.assemble(),
              let data = try? incoming.session.decryptResourcePayload(encrypted),
              incoming.receiver.manifest.validate(data: data) else {
            deliveryDebugTrace("RX resource \(resourceHash) failed reassembly or validation")
            return
        }
        deliveryDebugTrace("RX resource \(resourceHash) reassembled, \(data.count) bytes")
        let proof = incoming.receiver.manifest.resourceHash + ReticulumIdentity.fullHash(data + incoming.receiver.manifest.resourceHash)
        func acknowledgeResource() async {
            receivedResourceHashes.insert(resourceHash)
            receivedResourceProofs[resourceHash] = proof
            if receivedResourceHashes.count > SidebandMessageLimits.maximumRememberedMessageIDs,
               let evicted = receivedResourceHashes.first {
                receivedResourceHashes.remove(evicted)
                receivedResourceProofs.removeValue(forKey: evicted)
            }
            do {
                try await transmitRawPacket(Data([0x0f, 0x00]) + incoming.session.linkID + Data([0x05]) + proof)
                deliveryDebugTrace("TX resource proof \(resourceHash) on link \(incoming.session.linkID.hex)")
            } catch {
                deliveryDebugTrace("TX resource proof failed for \(resourceHash): \(error.localizedDescription)")
            }
        }

        let completeData: Data
        if incoming.advertisement.totalSegments > 1 {
            guard (try? await resourceStagingStore.stage(data: data, originalHash: incoming.advertisement.originalHash, segmentIndex: incoming.advertisement.segmentIndex, totalSegments: incoming.advertisement.totalSegments, totalSize: incoming.advertisement.dataSize)) != nil else { return }
            guard await resourceStagingStore.isComplete(originalHash: incoming.advertisement.originalHash) else {
                // Intermediate segments must be acknowledged so the sender can
                // advertise the next segment. The final segment is not
                // acknowledged until the complete LXMF payload is validated
                // and durably imported below.
                await acknowledgeResource()
                return
            }
            guard let assembled = try? await resourceStagingStore.assemble(originalHash: incoming.advertisement.originalHash) else { return }
            completeData = assembled
        } else { completeData = data }

        if incoming.advertisement.flags & 0x20 == 0,
           let message = try? LXMFReceivedMessage(packed: completeData),
           let identity = inboundRemoteIdentities[incoming.session.linkID.hex]
                ?? discoveries.first(where: { $0.destinationHash == message.sourceHash.hex })?.publicKey.flatMap({ try? ReticulumIdentity(publicKey: $0) }),
           message.validate(with: identity) {
            let alreadyImported = receivedLXMFIDs.contains(message.messageID.hex)
            let accepted = alreadyImported ? true : await importReceivedResourceMessage(message, sourceIdentity: identity)
            if accepted {
                incomingResourceProgress.removeValue(forKey: incoming.advertisement.originalHash.hex)
                await acknowledgeResource()
                return
            }
        }

        guard let envelope = try? LXMFResourceEnvelope(encoded: completeData) else {
            deliveryDebugTrace("RX resource \(resourceHash) is neither valid LXMF nor an attachment envelope")
            return
        }
        guard !envelope.filename.isEmpty, envelope.filename.count <= 180,
              envelope.filename.utf8.count <= 720,
              envelope.mimeType.map({ $0.count <= 127 && $0.utf8.count <= 508 }) ?? true,
              isAcceptableMessageBody(envelope.messageBody),
              isAcceptableReplyQuote(envelope.replyQuote),
              envelope.replyTo == nil || envelope.replyTo?.count == 32,
              envelope.fileData.count <= ReticulumResourceLimits.maximumAttachmentBytes else {
            deliveryDebugTrace("RX attachment envelope \(resourceHash) failed metadata limits")
            return
        }
        var resolvedIdentity = identityForIncomingResource(envelope: envelope, session: incoming.session)
        if resolvedIdentity == nil, DestinationHash.isValid(envelope.sourceHash.hex) {
            // A peer can establish a link immediately after our own announce,
            // before its announce/identity has finished traversing the reverse
            // path. Hold the fully reassembled resource briefly and actively
            // request that identity instead of discarding a valid attachment.
            await requestPath(to: envelope.sourceHash.hex)
            let identityDeadline = ContinuousClock.now + .seconds(12)
            while resolvedIdentity == nil, ContinuousClock.now < identityDeadline {
                try? await Task.sleep(for: .milliseconds(250))
                resolvedIdentity = identityForIncomingResource(envelope: envelope, session: incoming.session)
            }
        }
        guard let identity = resolvedIdentity else {
            deliveryDebugTrace("RX attachment envelope \(resourceHash) has no validated identity for \(envelope.sourceHash.hex)")
            return
        }
        let expectedNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        guard envelope.sourceHash == ReticulumIdentity.truncatedHash(expectedNameHash + identity.hash) else {
            deliveryDebugTrace("RX attachment envelope \(resourceHash) source does not match its identity")
            return
        }
        guard envelope.validate(with: identity) else {
            deliveryDebugTrace("RX attachment envelope \(resourceHash) signature invalid")
            return
        }
        let source = envelope.sourceHash.hex
        if !conversations.contains(where: { $0.destinationHash == source }) {
            let name = discoveries.first(where: { $0.destinationHash == source })?.announcedDisplayName ?? "Received \(source.prefix(8))"
            _ = addConversation(destinationHash: source, displayName: name, select: false)
        }
        guard let conversation = conversations.first(where: { $0.destinationHash == source }) else { return }
        let existingIndex = messages.firstIndex(where: { $0.id == envelope.groupID && $0.conversationID == conversation.id })
        if let index = existingIndex {
            let existing = messages[index]
            guard existing.direction == .incoming,
                  existing.body == envelope.messageBody,
                  existing.renderer == envelope.renderer,
                  existing.replyTo == envelope.replyTo,
                  existing.replyQuote == envelope.replyQuote,
                  existing.attachments.count < SidebandMessageLimits.maximumAttachments,
                  existing.attachments.reduce(0, { $0 + $1.byteCount }) <= SidebandMessageLimits.maximumCombinedAttachmentBytes - envelope.fileData.count else { return }
            let incomingHash = Data(SHA256.hash(data: envelope.fileData))
            if existing.attachments.contains(where: { $0.contentHash == incomingHash }) {
                // The receiver may have persisted the attachment and then lost
                // the TCP interface before its proof was transmitted. Treat an
                // exact retransmission as success without creating a duplicate.
                incomingResourceProgress.removeValue(forKey: incoming.advertisement.originalHash.hex)
                await acknowledgeResource()
                return
            }
        } else {
            guard messages.count < 250_000 else { return }
        }
        guard let attachment = try? await attachmentStore.save(data: envelope.fileData, filename: envelope.filename, mimeType: envelope.mimeType) else { return }
        if let index = existingIndex {
            messages[index].attachments.append(attachment)
        } else {
            messages.append(Message(id: envelope.groupID, conversationID: conversation.id, body: envelope.messageBody, timestamp: envelope.timestamp ?? .now, direction: .incoming, state: .delivered, attachments: [attachment], renderer: envelope.renderer, replyTo: envelope.replyTo, replyQuote: envelope.replyQuote))
            noteIncomingActivity(in: conversation.id)
        }
        incomingResourceProgress.removeValue(forKey: incoming.advertisement.originalHash.hex)
        save()
        // A resource proof now means the complete LXMF message or attachment
        // passed signature/content validation and was durably accepted. This
        // prevents a sender from displaying Delivered when the recipient had
        // to discard the application payload after transport reassembly.
        await acknowledgeResource()
        if shouldNotifyIncoming(for: conversation.id) {
            await notifications.notifyIncoming(
                conversationID: conversation.id,
                messageID: envelope.groupID,
                title: conversation.displayName,
                body: envelope.messageBody.isEmpty ? envelope.filename : envelope.messageBody,
                isAttachment: true,
                showPreview: shouldShowNotificationPreview(for: conversation.id)
            )
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
            let conversationID = messages.first(where: { $0.id == resource.messageID })?.conversationID
            let destinationHash = conversationID.flatMap { id in conversations.first(where: { $0.id == id })?.destinationHash }
            if let attachmentID = resource.attachmentID {
                updateAttachment(messageID: resource.messageID, attachmentID: attachmentID, state: .queued, progress: 0)
                updateMessage(resource.messageID, state: .queued)
            } else { updateMessage(resource.messageID, state: .queued) }
            if let session = activeLinks[resource.linkID] { try? await transmitRawPacket(try session.resourceCancelPacket(resourceHash: resource.manifest.resourceHash, initiatedBySender: true)) }
            removeLink(resource.linkID)
            if let destinationHash {
                directLinkFallbackDestinations.insert(destinationHash)
                await requestLink(to: destinationHash)
                if let conversationID { await attemptDelivery(for: conversationID) }
            }
        }
    }

    private func cancelResource(hash: String) {
        if let outgoing = outgoingResources.removeValue(forKey: hash) {
            if let attachmentID = outgoing.attachmentID {
                updateAttachment(messageID: outgoing.messageID, attachmentID: attachmentID, state: .failed, progress: 0)
            } else { updateMessage(outgoing.messageID, state: .failed) }
        }
        incomingResources.removeValue(forKey: hash)
    }

    private func updateAttachment(messageID: UUID, attachmentID: UUID, state: Attachment.TransferState, progress: Double) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let attachmentIndex = messages[messageIndex].attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        let previousState = messages[messageIndex].attachments[attachmentIndex].state
        messages[messageIndex].attachments[attachmentIndex].state = state
        messages[messageIndex].attachments[attachmentIndex].progress = progress
        if state == .failed { messages[messageIndex].state = .failed }
        if state == .transferring, previousState == .transferring, progress < 1 {
            scheduleDeferredSave()
        } else {
            save()
        }
    }

    private func receiveDeliveryProof(_ packet: ReticulumPacket) {
        let matched: (hash: String, receipt: PendingReceipt)?
        if packet.data.count == 96 {
            let hash = Data(packet.data.prefix(32)).hex
            matched = pendingReceipts[hash].map { (hash, $0) }
        } else if packet.data.count == 64 {
            matched = pendingReceipts.first { key, _ in
                Data(hexadecimal: key)?.prefix(ReticulumPacket.truncatedHashBytes) == packet.destinationHash
            }.map { ($0.key, $0.value) }
        } else {
            matched = nil
        }
        guard let matched,
              let provedHash = Data(hexadecimal: matched.hash) else { return }
        let receipt = matched.receipt
        guard let discovery = discoveries.first(where: { $0.destinationHash == receipt.destinationHash }),
              let publicKey = discovery.publicKey,
              let identity = try? ReticulumIdentity(publicKey: publicKey),
              ReticulumProof.validates(packet, packetHash: provedHash, identity: identity) else { return }
        pendingReceipts.removeValue(forKey: matched.hash)
        receiptTimeoutTasks.removeValue(forKey: matched.hash)?.cancel()
        updateMessage(receipt.messageID, state: receipt.kind == .propagation ? .sent : .delivered)
        if receipt.kind != .propagation,
           let conversation = conversations.first(where: { $0.destinationHash == receipt.destinationHash }) {
            // Advance the bounded delivery window only after an authenticated
            // proof frees a slot. Secure-link fallback intentionally remains
            // sticky for this process once opportunistic delivery proved
            // unreliable on the current network path.
            Task { await attemptDelivery(for: conversation.id) }
        }
        if receipt.kind == .propagation {
            propagationUploadsAccepted += 1
            UserDefaults.standard.set(propagationUploadsAccepted, forKey: "lxmfPropagationUploadsAccepted")
        }
    }

    private func scheduleReceiptTimeout(_ packetHash: String) {
        receiptTimeoutTasks.removeValue(forKey: packetHash)?.cancel()
        receiptTimeoutTasks[packetHash] = Task { [weak self] in
            // Proofs share the same constrained links as payloads. A modest
            // window avoids manufacturing retries during legitimate bursts,
            // while the durable outbox still recovers a truly lost proof.
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.expireReceipt(packetHash)
        }
    }

    private func expireReceipt(_ packetHash: String) async {
        receiptTimeoutTasks.removeValue(forKey: packetHash)
        guard let receipt = pendingReceipts.removeValue(forKey: packetHash) else { return }
        deliveryTimeoutCount += 1
        if let index = messages.firstIndex(where: { $0.id == receipt.messageID }) {
            messages[index].state = .queued
            messages[index].lastDeliveryFailure = "Delivery proof timed out; retry scheduled."
        }
        pendingReceiptRetryKinds[receipt.destinationHash, default: []].insert(receipt.kind)
        scheduleReceiptRetry(for: receipt.destinationHash)
    }

    private func scheduleReceiptRetry(for destinationHash: String) {
        guard receiptRetryTasks[destinationHash] == nil else { return }
        receiptRetryTasks[destinationHash] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.performReceiptRetry(for: destinationHash)
        }
    }

    private func performReceiptRetry(for destinationHash: String) async {
        receiptRetryTasks.removeValue(forKey: destinationHash)
        let kinds = pendingReceiptRetryKinds.removeValue(forKey: destinationHash) ?? []
        save()
        if kinds.contains(.opportunistic), !isPathPending(to: destinationHash) {
            // A missing opportunistic proof can indicate that ordinary data
            // packets are not traversing a path that still answers discovery.
            // Escalate the durable outbox to an encrypted link instead of
            // repeating the same unreliable delivery method indefinitely.
            directLinkFallbackDestinations.insert(destinationHash)
            // Refresh this client's direct route before asking the network for
            // the peer again. This is essential after roaming or reconnecting
            // through a different gateway interface.
            if lastDeliveryAnnounceAt.map({ Date.now.timeIntervalSince($0) >= 5 }) ?? true {
                await announceLocalDeliveryDestination()
            }
            if let destination = Data(hexadecimal: destinationHash) {
                await pathTable.invalidate(destination)
                await refreshPathState()
            }
            pendingPathHashes.remove(destinationHash)
            await requestPath(to: destinationHash)
            if activeLinkHashes.contains(destinationHash),
               let conversation = conversations.first(where: { $0.destinationHash == destinationHash }) {
                // An attachment or an explicit link request may have activated
                // the secure session while the opportunistic receipts were
                // still waiting. In that case deferLinkRequest() is correctly
                // a no-op, but the newly requeued messages still need an
                // immediate delivery pass over the already-active link.
                await attemptDelivery(for: conversation.id)
            } else {
                deferLinkRequest(to: destinationHash)
            }
            if DestinationHash.isValid(propagationNodeHash),
               let conversation = conversations.first(where: { $0.destinationHash == destinationHash }),
               conversation.deliveryPreference == .propagationPreferred {
                await propagateQueued(for: conversation.id)
            }
        }
        if kinds.contains(.direct),
           let conversation = conversations.first(where: { $0.destinationHash == destinationHash }) {
            // A direct packet timed out on an established link. Reusing that
            // session indefinitely creates a permanent Sent/Queued stall after
            // roaming or a gateway child-interface change. Retire the whole
            // peer window, then negotiate fresh link/path state.
            let otherReceipts = pendingReceipts.filter {
                $0.value.kind == .direct && $0.value.destinationHash == destinationHash
            }
            for (hash, pending) in otherReceipts {
                pendingReceipts.removeValue(forKey: hash)
                receiptTimeoutTasks.removeValue(forKey: hash)?.cancel()
                if let index = messages.firstIndex(where: { $0.id == pending.messageID }) {
                    messages[index].state = .queued
                    messages[index].lastDeliveryFailure = "Secure route changed; negotiating a fresh link."
                }
            }
            let staleLinks = linkRemoteDestinations.filter { $0.value == destinationHash }.map(\.key)
            for linkID in staleLinks { removeLink(linkID) }
            if let destination = Data(hexadecimal: destinationHash) {
                await pathTable.invalidate(destination)
                await refreshPathState()
            }
            pendingPathHashes.remove(destinationHash)
            await requestPath(to: destinationHash)
            await requestLink(to: destinationHash)
            deferLinkRequest(to: destinationHash)
            if conversation.deliveryPreference == .propagationPreferred {
                await propagateQueued(for: conversation.id)
            }
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
        for item in messages.filter({ $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= .now && $0.attachments.isEmpty && ownsOutbox($0) }) {
            do {
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, timestamp: item.timestamp.timeIntervalSince1970, content: Data(item.body.utf8), fields: lxmfFields(for: item), encodedFields: lxmfEncodedFields(for: item))
                recordLXMFID(lxmf.messageID, for: item.id)
                let envelope = try lxmf.propagatedEnvelope(recipientIdentity: recipient, ratchet: discovery.ratchet)
                let raw = try propagationSession.encryptedPacket(envelope)
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(messageID: item.id, kind: .propagation, destinationHash: propagationNodeHash)
                recordDeliveryAttempt(item.id, mode: .propagation)
                try await transmitRawPacket(raw)
                updateMessage(item.id, state: .sent)
                scheduleReceiptTimeout(packetHash)
            } catch {
                removePendingReceipts(for: item.id)
                recordDeliveryFailure(item.id, reason: "Propagation-node upload failed.")
                // Propagation is a background fallback. A transient interface
                // race must remain in delivery diagnostics instead of
                // interrupting the user with a modal alert.
            }
        }
    }

    private func refreshPathState() async {
        let paths = await pathTable.all()
        let currentPaths = Set(paths.map { $0.destinationHash.hex })
        if currentPaths != knownPathHashes { knownPathHashes = currentPaths }
        let resolvedPending = pendingPathHashes.intersection(currentPaths)
        if !resolvedPending.isEmpty { pendingPathHashes.subtract(resolvedPending) }
    }

    private func lxmfFields(for message: Message) -> [UInt64: Data] {
        var fields: [UInt64: Data] = message.telemetry.map { [0x02: $0.packed()] } ?? [:]
        if let replyTo = message.replyTo { fields[0x30] = replyTo }
        if let replyQuote = message.replyQuote { fields[0x31] = Data(replyQuote.utf8) }
        return fields
    }

    private func lxmfEncodedFields(for message: Message) -> [UInt64: Data] {
        var fields: [UInt64: Data] = message.renderer == .plain ? [:] : [0x0F: MessagePack.unsigned(UInt64(message.renderer.rawValue))]
        if let target = message.reactionTo, let content = message.reactionContent {
            fields[0x40] = MessagePack.map([
                (0x00, MessagePack.binary(target)),
                (0x01, MessagePack.binary(Data(content.utf8)))
            ])
        }
        if let target = message.commentTo {
            fields[0x41] = MessagePack.map([(0x00, MessagePack.binary(target))])
        }
        if let target = message.continuationOf {
            fields[0x42] = MessagePack.map([(0x00, MessagePack.binary(target))])
        }
        if let commands = LXMFCommand.encode(message.commands) { fields[0x09] = commands }
        if !message.telemetryStream.isEmpty,
           let stream = SidebandTelemetryStreamEntry.encode(message.telemetryStream) { fields[0x03] = stream }
        if let voiceAudio = message.voiceAudio { fields[0x07] = voiceAudio.encodedField }
        return fields
    }

    private func handleIncomingCommands(_ commands: [LXMFCommand], conversationID: UUID) async {
        let now = Date.now
        if let previous = lastCommandResponseAt[conversationID], now.timeIntervalSince(previous) < 5 { return }
        lastCommandResponseAt[conversationID] = now
        for command in commands {
            let response: String
            switch command {
            case .telemetryRequest(let timebase, let collector):
                guard let conversation = conversations.first(where: { $0.id == conversationID }),
                      conversation.isTrusted, conversation.telemetrySharingEnabled,
                      telemetryRespondToTrustedRequests else { continue }
                if collector, telemetryCollectorEnabled {
                    let stream = telemetryCollectorEntries(since: timebase, excluding: conversation.destinationHash)
                    guard !stream.isEmpty else { continue }
                    messages.append(Message(
                        conversationID: conversationID,
                        body: "Telemetry collector response",
                        direction: .outgoing,
                        state: .queued,
                        telemetryStream: stream,
                        outboxOwnerID: syncDeviceID,
                        outboxOwnerUpdatedAt: .now
                    ))
                } else if let latest = messages
                    .filter({ $0.direction == .outgoing && $0.telemetry != nil && $0.timestamp >= timebase })
                    .sorted(by: { $0.timestamp > $1.timestamp }).first?.telemetry {
                    messages.append(Message(conversationID: conversationID, body: "Telemetry response", direction: .outgoing,
                                            state: .queued, telemetry: latest, outboxOwnerID: syncDeviceID,
                                            outboxOwnerUpdatedAt: .now))
                } else {
                    continue
                }
                touch(conversationID)
                save()
                continue
            case .ping:
                response = "Ping reply"
            case .echo(let value):
                response = "Echo reply: \(value)"
            case .signalReport:
                let route = hasPath(to: conversations.first(where: { $0.id == conversationID })?.destinationHash ?? "") ? "available" : "unknown"
                response = "Signal report: Reticulum route \(route). RSSI and SNR are not exposed by Apple Network.framework."
            case .plugin(let command, let arguments):
                guard let conversation = conversations.first(where: { $0.id == conversationID }),
                      conversation.pluginCommandsEnabled else {
                    recordPluginAudit(command: command, conversationID: conversationID, pluginIdentifier: nil, outcome: .denied)
                    continue
                }
                let context = SidebandPluginContext(
                    command: command,
                    arguments: arguments,
                    senderDestinationHash: conversation.destinationHash,
                    networkReady: networkState == .ready,
                    routeAvailable: hasPath(to: conversation.destinationHash)
                )
                let execution = await pluginRegistry.execute(command: command, arguments: arguments, context: context)
                recordPluginAudit(command: command, conversationID: conversationID, pluginIdentifier: execution.pluginIdentifier, outcome: execution.outcome)
                guard let pluginResponse = execution.response else { continue }
                response = pluginResponse.text
            }
            enqueueAutomatedResponse(response, conversationID: conversationID)
        }
        await attemptDelivery(for: conversationID)
    }

    private func telemetryCollectorEntries(since: Date, excluding destinationHash: String) -> [SidebandTelemetryStreamEntry] {
        let localHash = Data(hexadecimal: localDeliveryHash) ?? Data()
        let trustedIDs = Set(conversations.filter(\.isTrusted).map(\.id))
        let destinations = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.destinationHash) })
        var collected: [SidebandTelemetryStreamEntry] = messages.flatMap { message -> [SidebandTelemetryStreamEntry] in
            guard trustedIDs.contains(message.conversationID), message.timestamp >= since else { return [] }
            var entries = message.telemetryStream.filter { $0.timestamp >= since && $0.sourceHash.hex != destinationHash }
            if let telemetry = message.telemetry {
                let source = message.direction == .outgoing ? localHash : Data(hexadecimal: destinations[message.conversationID] ?? "") ?? Data()
                if source.count == 16, source.hex != destinationHash {
                    entries.append(.init(sourceHash: source, timestamp: telemetry.capturedAt, telemetry: telemetry))
                }
            }
            return entries
        }
        collected.sort { $0.timestamp > $1.timestamp }
        if telemetryCollectorLatestOnly {
            var seen: Set<Data> = []
            collected = collected.filter { seen.insert($0.sourceHash).inserted }
        }
        return Array(collected.prefix(512))
    }

    private func recordPluginAudit(command: String, conversationID: UUID, pluginIdentifier: String?, outcome: SidebandPluginExecutionOutcome) {
        pluginAuditEvents.insert(SidebandPluginAuditEvent(pluginIdentifier: pluginIdentifier, command: command, conversationID: conversationID, outcome: outcome), at: 0)
        if pluginAuditEvents.count > 200 { pluginAuditEvents.removeLast(pluginAuditEvents.count - 200) }
        save()
    }

    private func enqueueAutomatedResponse(_ body: String, conversationID: UUID) {
        messages.append(Message(
            conversationID: conversationID,
            body: body,
            direction: .outgoing,
            state: .queued,
            outboxOwnerID: syncDeviceID,
            outboxOwnerUpdatedAt: .now
        ))
        touch(conversationID)
        save()
    }

    private func replyQuote(for message: Message) -> String {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(280)) }
        if let attachment = message.attachments.first { return "Attachment: \(attachment.filename)" }
        if message.telemetry != nil { return "Shared telemetry" }
        return "Message"
    }

    private func recordLXMFID(_ lxmfID: Data, for messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].lxmfID != lxmfID else { return }
        messages[index].lxmfID = lxmfID
        save()
    }

    private func touch(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].updatedAt = .now
        sortConversations()
    }

    private func sortConversations() {
        rebuildMessageIndexesIfNeeded()
        conversations.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            let leftActivity = max($0.updatedAt, latestMessageDateByConversation[$0.id] ?? .distantPast)
            let rightActivity = max($1.updatedAt, latestMessageDateByConversation[$1.id] ?? .distantPast)
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            return $0.id.uuidString < $1.id.uuidString
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
        if state == .delivered { messages[index].lastDeliveryFailure = nil }
        // The queued record and stable LXMF ID are synchronously durable before
        // transmission. Sent/delivered are high-frequency acknowledgements and
        // can be safely coalesced: after a crash the stable ID is retried, the
        // receiver deduplicates it and returns another proof.
        if state == .sent || state == .delivered { scheduleDeferredSave() }
        else { save() }
    }

    private func recordDeliveryAttempt(_ id: UUID, mode: Message.DeliveryMode) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].deliveryAttemptCount = min(10_000, messages[index].deliveryAttemptCount + 1)
        messages[index].lastDeliveryAttemptAt = .now
        messages[index].lastDeliveryMode = mode
    }

    private func recordDeliveryFailure(_ id: UUID, reason: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].lastDeliveryFailure = String(reason.prefix(256))
        save()
    }

    private func removePendingReceipts(for messageID: UUID) {
        let hashes = pendingReceipts.compactMap { $0.value.messageID == messageID ? $0.key : nil }
        for hash in hashes {
            pendingReceipts.removeValue(forKey: hash)
            receiptTimeoutTasks.removeValue(forKey: hash)?.cancel()
        }
    }

    private func ownsOutbox(_ message: Message) -> Bool {
        message.outboxOwnerID == nil || message.outboxOwnerID == syncDeviceID
    }

    private func abbreviated(_ hash: String) -> String { "\(hash.prefix(8))…\(hash.suffix(4))" }

    private func load() {
        guard localDataCipher.isAvailable else { return }
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        guard let data = try? Data(contentsOf: persistenceURL),
              let plaintext = try? localDataCipher.open(data, context: "application-snapshot-v1"),
              let snapshot = try? validatedSnapshot(from: plaintext) else {
            quarantineInvalidPersistence()
            if let backupData = try? Data(contentsOf: automaticBackupURL),
               let backupPlaintext = try? localDataCipher.open(backupData, context: "application-snapshot-v1"),
               let backup = try? validatedSnapshot(from: backupPlaintext) {
                lastValidatedPersistenceData = backupData
                lastSavedSnapshotDigest = Data(SHA256.hash(data: backupPlaintext))
                applyLoadedSnapshot(backup)
                save()
            }
            return
        }
        lastValidatedPersistenceData = data
        lastSavedSnapshotDigest = Data(SHA256.hash(data: plaintext))
        applyLoadedSnapshot(snapshot)
        if recoveredOutboundCount > 0 || !localDataCipher.isEncrypted(data) { save() }
    }

    private func applyLoadedSnapshot(_ snapshot: AppSnapshot) {
        conversations = snapshot.conversations
        messages = snapshot.messages
        sortConversations()
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
        deletedConversationDestinations = snapshot.deletedConversationDestinations
        voiceCallHistory = Array(snapshot.voiceCallHistory.prefix(100))
        pluginAuditEvents = Array(snapshot.pluginAuditEvents.prefix(200))
        let conversationIDs = Set(conversations.map(\.id))
        drafts = snapshot.drafts.filter { conversationIDs.contains($0.key) }
        selectedConversationID = conversations.first?.id
    }

    private func applyCloudSnapshot(_ snapshot: AppSnapshot) {
        let selectedDestination = selectedConversation?.destinationHash
        conversations = snapshot.conversations
        messages = snapshot.messages
        sortConversations()
        discoveries = snapshot.discoveries
        voiceCallHistory = Array(snapshot.voiceCallHistory.prefix(100))
        let conversationIDs = Set(conversations.map(\.id))
        drafts = snapshot.drafts.filter { conversationIDs.contains($0.key) }
        selectedConversationID = selectedDestination.flatMap { destination in
            conversations.first(where: { $0.destinationHash == destination })?.id
        } ?? conversations.first?.id
    }

    private func quarantineInvalidPersistence() {
        let quarantineURL = persistenceURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: persistenceURL, to: quarantineURL)
            lastQuarantinedPersistenceURL = quarantineURL
        } catch {
            lastQuarantinedPersistenceURL = nil
        }
    }

    private func save() {
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plaintext = try JSONEncoder.sideband.encode(AppSnapshot(conversations: conversations, messages: messages, discoveries: discoveries, drafts: drafts, voiceCallHistory: voiceCallHistory, pluginAuditEvents: pluginAuditEvents, deletedConversationDestinations: deletedConversationDestinations))
            let digest = Data(SHA256.hash(data: plaintext))
            if digest == lastSavedSnapshotDigest,
               FileManager.default.fileExists(atPath: persistenceURL.path),
               FileManager.default.fileExists(atPath: automaticBackupURL.path) { return }
            if let lastValidatedPersistenceData {
                try lastValidatedPersistenceData.write(to: automaticBackupURL, options: .atomic)
            } else if let existingData = try? Data(contentsOf: persistenceURL),
                      let existingPlaintext = try? localDataCipher.open(existingData, context: "application-snapshot-v1"),
                      (try? validatedSnapshot(from: existingPlaintext)) != nil {
                try existingData.write(to: automaticBackupURL, options: .atomic)
            }
            let encrypted = try localDataCipher.seal(plaintext, context: "application-snapshot-v1")
            try encrypted.write(to: persistenceURL, options: .atomic)
            lastValidatedPersistenceData = encrypted
            lastSavedSnapshotDigest = digest
            if iCloudSyncEnabled, !isApplyingCloudSnapshot { scheduleICloudSync() }
        } catch { lastError = "Could not save local data: \(error.localizedDescription)" }
    }

    private func scheduleDeferredSave() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func flushDeferredSave() {
        guard deferredSaveTask != nil else { return }
        save()
    }

    private func rebuildMessageIndexesIfNeeded() {
        guard messageIndexesAreDirty else { return }
        var grouped: [UUID: [Message]] = [:]
        var latest: [UUID: Message] = [:]
        var failed: [UUID: Int] = [:]
        var latestDates: [UUID: Date] = [:]
        var reactions: [UUID: [Data: [String: Int]]] = [:]
        var statistics = MessageStatistics()
        for message in messages {
            grouped[message.conversationID, default: []].append(message)
            if latestDates[message.conversationID, default: .distantPast] < message.timestamp {
                latestDates[message.conversationID] = message.timestamp
                latest[message.conversationID] = message
            }
            if message.direction == .outgoing, message.state == .failed {
                failed[message.conversationID, default: 0] += 1
            }
            switch message.direction {
            case .incoming:
                statistics.incoming += 1
            case .outgoing:
                statistics.outgoing += 1
                switch message.state {
                case .queued: statistics.queued += 1
                case .sent: statistics.sent += 1
                case .delivered: statistics.delivered += 1
                case .failed: statistics.failed += 1
                }
            }
            if message.reactionTo != nil { statistics.reactions += 1 }
            if let target = message.reactionTo,
               let content = message.reactionContent, !content.isEmpty {
                reactions[message.conversationID, default: [:]][target, default: [:]][content, default: 0] += 1
            }
            if message.isStarred { statistics.starred += 1 }
        }
        for conversationID in grouped.keys {
            grouped[conversationID]?.sort { $0.timestamp < $1.timestamp }
        }
        messagesByConversation = grouped
        latestMessageByConversation = latest
        failedMessageCountByConversation = failed
        latestMessageDateByConversation = latestDates
        reactionCountsByConversationAndTarget = reactions
        messageStatistics = statistics
        messageIndexesAreDirty = false
    }

    private func scheduleICloudSync() {
        iCloudSyncTask?.cancel()
        iCloudSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncICloudNow()
        }
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
