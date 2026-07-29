import Foundation
import Observation
import CryptoKit
import Network
import ReticulumKit

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

public struct ConnectedRoute: Equatable, Sendable {
    public let interfaceName: String
    public let endpoint: String?
    public let interfaceID: String?
    public let nextHopHash: String?
    public let hops: UInt8
    public let updatedAt: Date

    public init(
        interfaceName: String,
        endpoint: String?,
        interfaceID: String? = nil,
        nextHopHash: String? = nil,
        hops: UInt8,
        updatedAt: Date
    ) {
        self.interfaceName = interfaceName
        self.endpoint = endpoint
        self.interfaceID = interfaceID
        self.nextHopHash = nextHopHash
        self.hops = hops
        self.updatedAt = updatedAt
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
    public private(set) var connectedRoutes: [String: ConnectedRoute] = [:]
    public private(set) var pendingPathHashes: Set<String> = []
    public private(set) var pendingLinkHashes: Set<String> = []
    public private(set) var activeLinkHashes: Set<String> = []
    public private(set) var encryptedPacketsReceived = 0
    public private(set) var keepalivesReceived = 0
    public private(set) var keepalivesSent = 0
    public private(set) var deferredKeepalives = 0
    public private(set) var deferredTunnelSyntheses = 0
    public private(set) var lastDeferredTunnelSynthesisAt: Date?
    public private(set) var linkIdentificationsSent = 0
    public private(set) var propagationRequestsSent = 0
    public private(set) var propagationResponsesReceived = 0
    public private(set) var propagationMessagesAvailable = 0
    public private(set) var propagationUploadsAccepted = 0
    public private(set) var deliveryAnnouncesSent = 0
    public private(set) var lastDeliveryAnnounceAt: Date?
    public private(set) var lastAnnouncedDeliveryHash: String?
    public private(set) var lastInboundDeliveryPacketAt: Date?
    public private(set) var lastInboundDeliveryDestination: String?
    public private(set) var lastInboundDeliveryInterface: String?
    public private(set) var lastInboundDeliveryMatched: Bool?
    public private(set) var lastInboundMessageAt: Date?
    public private(set) var lastInboundMessageSource: String?
    public private(set) var lastInboundMessageID: String?
    public private(set) var lastInboundMessageResult: String?
    public private(set) var lastDeliveryProofSentAt: Date?
    public private(set) var lastDeliveryProofInterface: String?
    public private(set) var lastDeliveryProofKind: String?
    public private(set) var lastDeliveryProofFailureAt: Date?
    public private(set) var lastDeliveryProofFailure: String?
    public private(set) var inboundMessagesAccepted = 0
    public private(set) var inboundMessagesRejected = 0
    public private(set) var deliveryProofsSent = 0
    public private(set) var deliveryProofsDeferred = 0
    public private(set) var deliveryDiagnosticEvents: [String] = []
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
    public private(set) var reticulumInterfaceProfiles: [ReticulumInterfaceProfile] = []
    public private(set) var reticulumInterfaceProfileErrors: [UUID: String] = [:]
    public private(set) var configuredInterfaceSnapshots: [ReticulumConfiguredInterfaceRuntime.Snapshot] = []
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
    public let deviceAcceptance = SidebandDeviceAcceptance()
    public let rnodeManager = RNodeManager()
    public let pluginRegistry: SidebandPluginRegistry
    public let attachmentStore: AttachmentStore
    public private(set) var attachmentStorageReport: AttachmentStorageReport?
    public private(set) var storagePolicy = SidebandStoragePolicy()
    public private(set) var lastStorageCleanupResult: SidebandStorageCleanupResult?
    public let resourceStagingStore: ReticulumResourceStagingStore
    public private(set) var selectedGatewayName: String?
    public private(set) var activeNetworkHost: String?
    public private(set) var activeNetworkPort: Int?
    public private(set) var networkInterfaces: [ReticulumTCPInterfacePool.Snapshot] = []
    public private(set) var discoveredNetworkInterfaces: [DiscoveredReticulumInterface] = []
    public private(set) var lastQuarantinedPersistenceURL: URL?
    public private(set) var canRollbackLegacyImport = false
    public private(set) var lastLegacyImportAt: Date?
    public private(set) var lastLegacyImportSummary: String?
    public var selectedConversationID: UUID?
    public var lastError: String?

    public var deliveryActivity: [DeliveryActivityItem] {
        DeliveryActivityBuilder.build(
            messages: messages,
            conversations: conversations,
            diagnostics: deliveryDiagnosticEvents,
            routes: connectedRoutes
        )
    }

    private let transport: any MessageTransport
    private let persistenceURL: URL
    private let localDataCipher: LocalDataCipher
    private let cloudSync: any CloudSnapshotSyncing
    private let syncDeviceID: String
    private var iCloudSyncTask: Task<Void, Never>?
    private var discoverySaveTask: Task<Void, Never>?
    private var deferredSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastValidatedPersistenceData: Data?
    @ObservationIgnored private var legacyImportRollbackData: Data?
    private var legacyImportRollbackURL: URL {
        persistenceURL.deletingLastPathComponent().appending(path: "LegacyImportRollback.lsb", directoryHint: .notDirectory)
    }
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
    @ObservationIgnored private lazy var configuredInterfaceRuntime = ReticulumConfiguredInterfaceRuntime {
        [weak self] packet, interfaceID in
        await self?.receiveFromInterface(packet, interfaceID: interfaceID)
    }
    private var iCloudSyncInProgress = false
    private var isApplyingCloudSnapshot = false
    private var networkInterfacePool: ReticulumTCPInterfacePool?
    private var tcpTunnelSynthesisInProgress = false
    private var knownTCPInterfaceIDs: Set<String> = []
    private var tcpNetworkState: ReticulumTCPInterface.State = .stopped
    private var autoConnectedDiscoveredInterfaceIDs: Set<String> = []
    private var networkConnectionGeneration = UUID()
    /// Changes whenever link/receipt state is invalidated. Async sends capture
    /// this value before yielding to an interface and must not publish `sent`
    /// state if the connection was reset while the write was in progress.
    private var deliveryConnectionEpoch = UUID()
    private let pathTable = ReticulumPathTable()
    private var pendingLinks: [String: ReticulumLinkRequest] = [:]
    private var pendingLinkTimeoutTokens: [String: UUID] = [:]
    private var deferredLinkRetryTokens: [String: UUID] = [:]
    private var activeLinks: [String: ReticulumLinkSession] = [:]
    /// Outbound links are cryptographically active as soon as their proof is
    /// validated, but LXMF delivery must wait until our fresh announce and
    /// LINKIDENTIFY exchange have been handed to the transport.
    private var activatingOutboundLinkIDs: Set<String> = []
    private var deliveryReadyOutboundLinkIDs: Set<String> = []
    private var linkRemoteDestinations: [String: String] = [:]
    private var linkInterfaceIDs: [String: String] = [:]
    private enum ReceiptKind: Hashable { case direct, opportunistic, propagation }
    private struct PendingReceipt {
        let messageID: UUID
        let kind: ReceiptKind
        let destinationHash: String
        let linkID: String?

        init(messageID: UUID, kind: ReceiptKind, destinationHash: String, linkID: String? = nil) {
            self.messageID = messageID
            self.kind = kind
            self.destinationHash = destinationHash
            self.linkID = linkID
        }
    }
    private var pendingReceipts: [String: PendingReceipt] = [:]
    private var receiptTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var receiptRetryTasks: [String: Task<Void, Never>] = [:]
    private var pendingReceiptRetryKinds: [String: Set<ReceiptKind>] = [:]
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
    private var backgroundWakeTask: Task<Bool, Never>?
    private var backgroundWakeToken: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var attemptedGatewayIDs: Set<String> = []
    private var attemptedConfiguredGatewayIDs: Set<String> = []
    private var attemptedInternetGatewayIDs: Set<String> = []
    private var didRefreshCommunityGateways = false
    private var observedLANDiscoveryGrace = false
    private var activeGatewayID: String?
    private var activeInternetGatewayID: String?
    private var pendingLANGatewaySwitchID: String?
    private var preferredGatewayID: String?
    private var preferredInternetGatewayID: String?
    public private(set) var gatewayHealth: [String: GatewayHealthRecord] = [:]
    public private(set) var communityInternetGateways: [InternetGateway] = []
    public private(set) var managedInternetGateways: [InternetGateway] = []
    public private(set) var managedPropagationNodeCount = 0
    public private(set) var managedInfrastructureStatus = "Not configured"
    public private(set) var managedInfrastructureLastRefresh: Date?
    public var managedInfrastructureEnabled: Bool
    public var managedInfrastructureURL: String
    public var managedInfrastructurePublicKey: String
    public var remoteWakeEnabled: Bool
    public private(set) var remoteWakeStatus = "Not configured"
    public private(set) var remoteWakeLastRegisteredAt: Date?
    private var networkConnectionStartedAt: Date?
    private var deferredPathRequests: Set<String> = []
    private var answeredLocalPathRequestTags: [Data: Date] = [:]
    private var intentionallyDisconnected = false
    private var reconnectAttempt = 0
    private let transportIdentity: ReticulumIdentity
    @ObservationIgnored private let communityInterfaceDirectory = CommunityInterfaceDirectory()
    @ObservationIgnored private let managedInfrastructureDirectory = ManagedInfrastructureDirectory()
    @ObservationIgnored private let remoteWakeRegistrationClient = RemoteWakeRegistrationClient()
    @ObservationIgnored private var managedInfrastructureSnapshot: ManagedInfrastructureDirectory.Snapshot?
    private var didRefreshManagedInfrastructure = false
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
        if let policyData = UserDefaults.standard.data(forKey: "sidebandStoragePolicy.v1"),
           let policy = try? JSONDecoder.sideband.decode(SidebandStoragePolicy.self, from: policyData) {
            storagePolicy = policy.normalized
        }
        if let cleanupData = UserDefaults.standard.data(forKey: "sidebandLastStorageCleanup.v1"),
           let result = try? JSONDecoder.sideband.decode(SidebandStorageCleanupResult.self, from: cleanupData) {
            lastStorageCleanupResult = result
        }
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
        if let encryptedProfiles = UserDefaults.standard.data(forKey: "reticulumInterfaceProfiles.v1"),
           let profileData = try? localDataCipher.open(encryptedProfiles, context: "reticulum-interface-profiles-v1"),
           let profiles = try? JSONDecoder.sideband.decode([ReticulumInterfaceProfile].self, from: profileData) {
            reticulumInterfaceProfiles = Array(profiles.prefix(64))
        }
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
        managedInfrastructureEnabled = UserDefaults.standard.bool(forKey: "managedInfrastructureEnabled")
        managedInfrastructureURL = UserDefaults.standard.string(forKey: "managedInfrastructureURL") ?? ""
        managedInfrastructurePublicKey = UserDefaults.standard.string(forKey: "managedInfrastructurePublicKey") ?? ""
        remoteWakeEnabled = UserDefaults.standard.bool(forKey: "remoteWakeEnabled")
        remoteWakeLastRegisteredAt = UserDefaults.standard.object(forKey: "sidebandAPNsLastRegisteredAt") as? Date
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
        deferredKeepalives = UserDefaults.standard.integer(forKey: "reticulumDeferredKeepalives")
        deferredTunnelSyntheses = UserDefaults.standard.integer(forKey: "reticulumDeferredTunnelSyntheses")
        lastDeferredTunnelSynthesisAt = UserDefaults.standard.object(forKey: "reticulumLastDeferredTunnelSynthesisAt") as? Date
        lastAnnouncedDeliveryHash = UserDefaults.standard.string(forKey: "lxmfLastAnnouncedDeliveryHash")
        lastDeliveryAnnounceAt = UserDefaults.standard.object(forKey: "lxmfLastDeliveryAnnounceAt") as? Date
        lastInboundDeliveryPacketAt = UserDefaults.standard.object(forKey: "lxmfLastInboundDeliveryPacketAt") as? Date
        lastInboundDeliveryDestination = UserDefaults.standard.string(forKey: "lxmfLastInboundDeliveryDestination")
        lastInboundDeliveryInterface = UserDefaults.standard.string(forKey: "lxmfLastInboundDeliveryInterface")
        if UserDefaults.standard.object(forKey: "lxmfLastInboundDeliveryMatched") != nil {
            lastInboundDeliveryMatched = UserDefaults.standard.bool(forKey: "lxmfLastInboundDeliveryMatched")
        }
        lastInboundMessageAt = UserDefaults.standard.object(forKey: "lxmfLastInboundMessageAt") as? Date
        lastInboundMessageSource = UserDefaults.standard.string(forKey: "lxmfLastInboundMessageSource")
        lastInboundMessageID = UserDefaults.standard.string(forKey: "lxmfLastInboundMessageID")
        lastInboundMessageResult = UserDefaults.standard.string(forKey: "lxmfLastInboundMessageResult")
        lastDeliveryProofSentAt = UserDefaults.standard.object(forKey: "lxmfLastDeliveryProofSentAt") as? Date
        lastDeliveryProofInterface = UserDefaults.standard.string(forKey: "lxmfLastDeliveryProofInterface")
        lastDeliveryProofKind = UserDefaults.standard.string(forKey: "lxmfLastDeliveryProofKind")
        lastDeliveryProofFailureAt = UserDefaults.standard.object(forKey: "lxmfLastDeliveryProofFailureAt") as? Date
        lastDeliveryProofFailure = UserDefaults.standard.string(forKey: "lxmfLastDeliveryProofFailure")
        inboundMessagesAccepted = UserDefaults.standard.integer(forKey: "lxmfInboundMessagesAccepted")
        inboundMessagesRejected = UserDefaults.standard.integer(forKey: "lxmfInboundMessagesRejected")
        deliveryProofsSent = UserDefaults.standard.integer(forKey: "lxmfDeliveryProofsSent")
        deliveryProofsDeferred = UserDefaults.standard.integer(forKey: "lxmfDeliveryProofsDeferred")
        deliveryDiagnosticEvents = Array((UserDefaults.standard.stringArray(forKey: "lxmfDeliveryDiagnosticEvents") ?? []).prefix(24))
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
            if FileManager.default.fileExists(atPath: legacyImportRollbackURL.path) {
                canRollbackLegacyImport = true
            }
        } else {
            lastError = "Secure Keychain data is temporarily unavailable. Lower Sideband will remain offline and will not read or overwrite encrypted data. Unlock the device and reopen the app."
        }
        autoInterfaceDiscovery.setPacketHandler { [weak self] packet in await self?.receiveFromInterface(packet, interfaceID: "auto") }
        rnodeManager.setHandlers { [weak self] interfaceID, raw in
            guard let packet = try? ReticulumPacket(raw: raw) else { return }
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
        runtimeHealth.recordForeground()
        Task { try? await resourceStagingStore.removeStale(olderThan: Date(timeIntervalSinceNow: -86_400)) }
        Task { [weak self] in
            guard let self else { return }
            if self.storagePolicy.automaticCleanupEnabled {
                _ = await self.performStorageMaintenance()
            } else {
                _ = await self.cleanOrphanedAttachments()
            }
        }
        syncUnreadBadge()
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    /// Drops rebuildable indexes and transcript data after an operating-system
    /// memory warning. Encrypted durable messages and attachments are retained.
    public func handleMemoryPressure() {
        releaseRebuildableCaches()
        runtimeHealth.recordMemoryPressure()
    }

    private func releaseRebuildableCaches() {
        transcriptCache.removeAll(keepingCapacity: false)
        messagesByConversation.removeAll(keepingCapacity: false)
        latestMessageByConversation.removeAll(keepingCapacity: false)
        failedMessageCountByConversation.removeAll(keepingCapacity: false)
        latestMessageDateByConversation.removeAll(keepingCapacity: false)
        reactionCountsByConversationAndTarget.removeAll(keepingCapacity: false)
        messageIndexesAreDirty = true
    }

    /// Releases only derived in-memory data. Durable encrypted content remains intact.
    @discardableResult
    public func releasePerformanceCaches() -> Int {
        let count = transcriptCache.count
            + messagesByConversation.count
            + latestMessageByConversation.count
            + failedMessageCountByConversation.count
            + latestMessageDateByConversation.count
            + reactionCountsByConversationAndTarget.count
        releaseRebuildableCaches()
        return count
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
            await requestPath(to: voiceDestination.hex, surfaceErrors: false)
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
        try? await transmitLinkPacket(
            try session.encryptedPacket(LXSTVoice.frame(codec: call.profile.codec, payload: payload)),
            session: session
        )
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

    public func setStoragePolicy(_ policy: SidebandStoragePolicy) {
        storagePolicy = policy.normalized
        if let data = try? JSONEncoder.sideband.encode(storagePolicy) {
            UserDefaults.standard.set(data, forKey: "sidebandStoragePolicy.v1")
        }
    }

    /// Applies explicit retention and quota limits without removing starred content,
    /// scheduled/outbound work, or attachments involved in an active transfer.
    @discardableResult
    public func performStorageMaintenance(now: Date = .now) async -> SidebandStorageCleanupResult {
        let policy = storagePolicy.normalized
        let calendar = Calendar(identifier: .gregorian)
        let messageCutoff = policy.messageRetentionDays > 0
            ? calendar.date(byAdding: .day, value: -policy.messageRetentionDays, to: now)
            : nil
        let attachmentCutoff = policy.attachmentRetentionDays > 0
            ? calendar.date(byAdding: .day, value: -policy.attachmentRetentionDays, to: now)
            : nil

        func isTerminal(_ message: Message) -> Bool {
            message.state == .delivered || message.state == .failed
        }
        func hasActiveAttachment(_ message: Message) -> Bool {
            message.attachments.contains { $0.state == .queued || $0.state == .transferring }
        }

        let removableMessageIDs = Set(messages.compactMap { message -> UUID? in
            guard let messageCutoff,
                  message.timestamp < messageCutoff,
                  isTerminal(message),
                  !message.isStarred,
                  !hasActiveAttachment(message) else { return nil }
            return message.id
        })

        var removableAttachmentIDs = Set<UUID>()
        if let attachmentCutoff {
            for message in messages where !removableMessageIDs.contains(message.id) {
                guard message.timestamp < attachmentCutoff, isTerminal(message), !message.isStarred else { continue }
                for attachment in message.attachments
                    where attachment.state != .queued && attachment.state != .transferring {
                    removableAttachmentIDs.insert(attachment.id)
                }
            }
        }

        if policy.maximumAttachmentStorageMB > 0 {
            let limit = policy.maximumAttachmentStorageMB * 1_000_000
            let retainedMessages = messages.filter { !removableMessageIDs.contains($0.id) }
            var remainingBytes = retainedMessages
                .flatMap(\.attachments)
                .filter { !removableAttachmentIDs.contains($0.id) }
                .reduce(0) { $0 + max(0, $1.byteCount) }
            if remainingBytes > limit {
                let candidates = retainedMessages
                    .filter { isTerminal($0) && !$0.isStarred }
                    .flatMap { message in
                        message.attachments
                            .filter {
                                !removableAttachmentIDs.contains($0.id)
                                    && $0.state != .queued
                                    && $0.state != .transferring
                            }
                            .map { (message.timestamp, $0) }
                    }
                    .sorted { $0.0 < $1.0 }
                for (_, attachment) in candidates where remainingBytes > limit {
                    removableAttachmentIDs.insert(attachment.id)
                    remainingBytes -= max(0, attachment.byteCount)
                }
            }
        }

        let attachmentsFromMessages = messages
            .filter { removableMessageIDs.contains($0.id) }
            .flatMap(\.attachments)
        let individuallyRemoved = messages
            .flatMap(\.attachments)
            .filter { removableAttachmentIDs.contains($0.id) }
        let allRemovedAttachments = Dictionary(
            uniqueKeysWithValues: (attachmentsFromMessages + individuallyRemoved).map { ($0.id, $0) }
        ).values
        for attachment in allRemovedAttachments {
            try? await attachmentStore.remove(attachment)
        }

        if !removableMessageIDs.isEmpty {
            messages.removeAll { removableMessageIDs.contains($0.id) }
        }
        if !removableAttachmentIDs.isEmpty {
            for index in messages.indices {
                messages[index].attachments.removeAll { removableAttachmentIDs.contains($0.id) }
            }
        }
        if !removableMessageIDs.isEmpty || !removableAttachmentIDs.isEmpty {
            sortConversations()
            save()
        }

        let paths = Set(messages.flatMap(\.attachments).map(\.relativePath))
        let orphaned = (try? await attachmentStore.removeOrphans(referencedRelativePaths: paths)) ?? 0
        await refreshAttachmentStorageReport()
        let result = SidebandStorageCleanupResult(
            messagesRemoved: removableMessageIDs.count,
            attachmentsRemoved: allRemovedAttachments.count,
            attachmentBytesRemoved: allRemovedAttachments.reduce(0) { $0 + max(0, $1.byteCount) },
            orphanedFilesRemoved: orphaned,
            performedAt: now
        )
        lastStorageCleanupResult = result
        if let data = try? JSONEncoder.sideband.encode(result) {
            UserDefaults.standard.set(data, forKey: "sidebandLastStorageCleanup.v1")
        }
        return result
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
            if let session = activeLinks[resource.linkID] {
                try? await transmitLinkPacket(
                    try session.resourceCancelPacket(
                        resourceHash: resource.manifest.resourceHash,
                        initiatedBySender: true
                    ),
                    session: session
                )
            }
        }
    }

    public func startTransport() async {
        await transport.start()
        transportState = await transport.state
        await transportInstance.setEnabled(transportInstanceEnabled)
        transportInstanceSnapshot = await transportInstance.snapshot()
        await restartConfiguredInterfaces()
    }

    public func clearError() { lastError = nil }

    public func saveReticulumInterfaceProfile(_ profile: ReticulumInterfaceProfile) throws {
        let validated = try profile.validated()
        var profiles = reticulumInterfaceProfiles
        if let index = profiles.firstIndex(where: { $0.id == validated.id }) { profiles[index] = validated }
        else {
            guard profiles.count < 64 else { throw InterfaceProfileError.tooManyProfiles }
            profiles.append(validated)
        }
        let conflicts = ReticulumInterfacePreflight.conflictingProfileIDs(in: profiles)
        guard conflicts.isEmpty else { throw InterfaceProfileError.listenerConflict }
        reticulumInterfaceProfiles = profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        reticulumInterfaceProfileErrors.removeValue(forKey: validated.id)
        try persistReticulumInterfaceProfiles()
        Task { await restartConfiguredInterfaces() }
    }

    public func removeReticulumInterfaceProfile(id: UUID) throws {
        reticulumInterfaceProfiles.removeAll { $0.id == id }
        reticulumInterfaceProfileErrors.removeValue(forKey: id)
        try persistReticulumInterfaceProfiles()
        Task { await restartConfiguredInterfaces() }
    }

    public func setReticulumInterfaceProfileEnabled(id: UUID, enabled: Bool) throws {
        guard let profile = reticulumInterfaceProfiles.first(where: { $0.id == id }) else { return }
        var updated = profile; updated.enabled = enabled
        try saveReticulumInterfaceProfile(updated)
    }

    private func persistReticulumInterfaceProfiles() throws {
        let plaintext = try JSONEncoder.sideband.encode(reticulumInterfaceProfiles)
        let encrypted = try localDataCipher.seal(plaintext, context: "reticulum-interface-profiles-v1")
        UserDefaults.standard.set(encrypted, forKey: "reticulumInterfaceProfiles.v1")
    }

    private func restartConfiguredInterfaces() async {
        await configuredInterfaceRuntime.apply(reticulumInterfaceProfiles)
        await refreshConfiguredInterfaceSnapshots()
    }

    public func refreshConfiguredInterfaceSnapshots() async {
        configuredInterfaceSnapshots = await configuredInterfaceRuntime.currentSnapshots()
        reticulumInterfaceProfileErrors = Dictionary(uniqueKeysWithValues: configuredInterfaceSnapshots.compactMap {
            if case .failed(let reason) = $0.state { return ($0.id, reason) }
            return nil
        })
    }

    public enum InterfaceProfileError: LocalizedError {
        case tooManyProfiles, listenerConflict
        public var errorDescription: String? {
            switch self {
            case .tooManyProfiles: "A maximum of 64 interface profiles can be stored."
            case .listenerConflict: "Two enabled listener interfaces cannot use the same TCP port."
            }
        }
    }

    /// Removes artifacts from earlier automated delivery runs without touching
    /// the currently requested run or ordinary user messages. A terminated
    /// soak can otherwise leave thousands of queued retries that contaminate
    /// the next acceptance result.
    @discardableResult
    public func purgeDeliverySoakMessages(keepingPrefixes: Set<String> = []) async -> Int {
        let removedMessages = messages.filter { message in
            let isSoak = Self.isDeliverySoakMessageBody(message.body)
            return isSoak && !keepingPrefixes.contains(where: message.body.hasPrefix)
        }
        guard !removedMessages.isEmpty else { return 0 }
        let removedIDs = Set(removedMessages.map(\.id))
        let affectedConversations = Set(removedMessages.map(\.conversationID))
        for message in removedMessages {
            for attachment in message.attachments {
                await cancelActiveResources(messageID: message.id, attachmentID: attachment.id)
                try? await attachmentStore.remove(attachment)
            }
        }
        pendingReceipts = pendingReceipts.filter { !removedIDs.contains($0.value.messageID) }
        messages.removeAll { removedIDs.contains($0.id) }
        for conversationID in affectedConversations {
            if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[index].updatedAt = latestMessage(for: conversationID)?.timestamp ?? .now
            }
        }
        sortConversations()
        save()
        return removedMessages.count
    }

    static func isDeliverySoakMessageBody(_ body: String) -> Bool {
        if body.hasPrefix("SOAK-") || body.hasPrefix("LSB-INTERNET-") { return true }
        guard body.hasPrefix("LSB-") else { return false }
        for marker in ["-MAC-", "-SIM-", "-LINUX-"] {
            guard let range = body.range(of: marker, options: .backwards) else { continue }
            let sequence = body[range.upperBound...]
            if sequence.count >= 3, sequence.count <= 6,
               sequence.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

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
                managedGateways: managedInternetGateways,
                communityGateways: communityInternetGateways,
                health: gatewayHealth
            )
            // Keep every configured public entrypoint live. Remote transports
            // can retain a valid route to any gateway on which this identity
            // announced for up to seven days. Rotating a three-gateway subset
            // made the client unreachable through a previously advertised
            // entrypoint even though its remaining sockets were healthy.
            endpoints = publicGateways.compactMap {
                Self.networkPoolEndpoint(for: $0, isBootstrap: true)
            }
            activeNetworkHost = "\(endpoints.count) public gateways"
            activeNetworkPort = nil
        } else {
            let gateway = InternetGateway(name: selectedHost, host: selectedHost, port: port)
            guard let endpoint = Self.networkPoolEndpoint(for: gateway, isBootstrap: false) else {
                lastError = "Enter a valid TCP host, WebSocket URL or HTTP tunnel URL."
                tcpNetworkState = .failed(lastError ?? "Invalid interface")
                refreshAggregateNetworkState()
                return
            }
            endpoints = [endpoint]
            activeNetworkHost = selectedHost
            activeNetworkPort = Int(port)
        }
        let pool = makeInterfacePool(generation: generation)
        networkInterfacePool = pool
        await pool.start(endpoints)
    }

    static func networkPoolEndpoint(
        for gateway: InternetGateway,
        isBootstrap: Bool
    ) -> ReticulumTCPInterfacePool.Endpoint? {
        let value = gateway.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host != nil {
            switch scheme {
            case "ws", "wss":
                return ReticulumTCPInterfacePool.Endpoint(
                    id: gateway.id,
                    name: gateway.name,
                    webSocketURL: url,
                    isBootstrap: isBootstrap
                )
            case "http", "https":
                return ReticulumTCPInterfacePool.Endpoint(
                    id: gateway.id,
                    name: gateway.name,
                    httpURL: url,
                    isBootstrap: isBootstrap
                )
            default:
                break
            }
        }
        guard !value.isEmpty, gateway.port > 0 else { return nil }
        if let rawIdentity = gateway.backboneTransportIdentity,
           let identity = try? ReticulumBackboneTransportIdentity(hash: rawIdentity),
           let port = NWEndpoint.Port(rawValue: gateway.port) {
            return ReticulumTCPInterfacePool.Endpoint(
                id: gateway.id,
                name: gateway.name,
                backboneEndpoint: .hostPort(host: NWEndpoint.Host(value), port: port),
                transportIdentity: identity,
                isBootstrap: isBootstrap
            )
        }
        return ReticulumTCPInterfacePool.Endpoint(
            id: gateway.id,
            name: gateway.name,
            host: value,
            port: gateway.port,
            isBootstrap: isBootstrap
        )
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
        runtimeHealth.recordForeground()
        let recoveredConversations = recoverStaleSentMessages()
        for conversationID in recoveredConversations {
            await attemptDelivery(for: conversationID)
        }
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
        if remoteWakeEnabled { await registerRemoteWake() }
    }

    public func applicationDidBecomeInactive() {
        isApplicationActive = false
        Task { await attachmentStore.removeAllMaterializedFiles() }
    }

    public func applicationDidEnterBackground() {
        isApplicationActive = false
        runtimeHealth.recordBackground()
        flushDeferredSave()
        releaseRebuildableCaches()
        stopPeriodicPropagationSync()
        backgroundRefresh.schedule(earliest: nextScheduledMessageDate)
    }

    private func performBackgroundRefresh() async -> Bool {
        await performCoalescedWakeSync(networkTimeout: 10)
    }

    /// Performs the bounded work allowed after an iOS silent wake. The push
    /// contains no message data; it only prompts a Reticulum reconnect and an
    /// end-to-end encrypted LXMF propagation sync.
    @discardableResult
    public func performRemoteWakeSync() async -> Bool {
        await performCoalescedWakeSync(networkTimeout: 12)
    }

    private func performCoalescedWakeSync(networkTimeout: TimeInterval) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let backgroundWakeTask {
            return await withTaskCancellationHandler {
                await backgroundWakeTask.value
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelBackgroundWake() }
            }
        }
        let token = UUID()
        backgroundWakeToken = token
        let task = Task { @MainActor [weak self] in
            await self?.runWakeSync(networkTimeout: networkTimeout) ?? false
        }
        backgroundWakeTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelBackgroundWake(token: token) }
        }
        if backgroundWakeToken == token {
            backgroundWakeTask = nil
            backgroundWakeToken = nil
        }
        return result
    }

    private func cancelBackgroundWake(token: UUID? = nil) {
        guard token == nil || backgroundWakeToken == token else { return }
        backgroundWakeTask?.cancel()
        backgroundWakeTask = nil
        backgroundWakeToken = nil
    }

    private func runWakeSync(networkTimeout: TimeInterval) async -> Bool {
        let startedAt = Date.now
        var wakeSucceeded = false
        defer {
            let succeeded = wakeSucceeded && !Task.isCancelled
            lastBackgroundRefreshAt = startedAt
            lastBackgroundRefreshSucceeded = succeeded
            UserDefaults.standard.set(startedAt, forKey: "sidebandLastBackgroundRefreshAt")
            UserDefaults.standard.set(succeeded, forKey: "sidebandLastBackgroundRefreshSucceeded")
            runtimeHealth.recordBackgroundWake(
                succeeded: succeeded,
                duration: Date.now.timeIntervalSince(startedAt)
            )
            backgroundRefresh.schedule()
        }
        if autoConnectEnabled, networkState != .ready { await startAutomaticConnection() }
        let networkDeadline = ContinuousClock.now + .seconds(networkTimeout)
        while networkState != .ready, ContinuousClock.now < networkDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard networkState == .ready, !Task.isCancelled else {
            return false
        }

        await announceLocalDeliveryDestination()
        guard !Task.isCancelled else { return false }
        if DestinationHash.isValid(propagationNodeHash),
           await preparePropagationLink(until: ContinuousClock.now + .seconds(8)) {
            let responseBaseline = propagationResponsesReceived
            await syncPropagationNow()
            let responseDeadline = ContinuousClock.now + .seconds(4)
            while propagationResponsesReceived == responseBaseline,
                  pendingPropagationRequests.values.contains(where: { if case .list = $0 { true } else { false } }),
                  ContinuousClock.now < responseDeadline,
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard !Task.isCancelled else { return false }
        await flushQueuedMessages()
        for conversation in conversations {
            guard !Task.isCancelled else { return false }
            await attemptDelivery(for: conversation.id)
            await propagateQueued(for: conversation.id)
        }
        if iCloudSyncEnabled { await syncICloudNow() }
        wakeSucceeded = true
        return true
    }

    private func preparePropagationLink(until deadline: ContinuousClock.Instant) async -> Bool {
        guard DestinationHash.isValid(propagationNodeHash) else { return false }
        var lastPathRequest = ContinuousClock.now - .seconds(10)
        var lastLinkRequest = ContinuousClock.now - .seconds(10)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if activeLinks.values.contains(where: { $0.destinationHash.hex == propagationNodeHash }) {
                return true
            }
            if !propagationNodeHasPath,
               !propagationNodePathPending,
               lastPathRequest.duration(to: ContinuousClock.now) >= .seconds(2) {
                lastPathRequest = ContinuousClock.now
                await requestPropagationNodePath()
            } else if propagationNodeHasPath,
                      !pendingLinkHashes.contains(propagationNodeHash),
                      lastLinkRequest.duration(to: ContinuousClock.now) >= .seconds(2) {
                lastLinkRequest = ContinuousClock.now
                await requestLink(to: propagationNodeHash)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return activeLinks.values.contains(where: { $0.destinationHash.hex == propagationNodeHash })
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
            try await transmitLinkPacket(requestPacket, session: session)
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
                let interval = self?.runtimeHealth.shouldReduceBackgroundWork == true ? 180 : 60
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                let recoveredConversations = self?.recoverStaleSentMessages() ?? []
                for conversationID in recoveredConversations {
                    await self?.attemptDelivery(for: conversationID)
                }
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
        didRefreshCommunityGateways = false
        didRefreshManagedInfrastructure = false
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

    public func configureManagedInfrastructure(enabled: Bool, url: String, publicKey: String) {
        managedInfrastructureEnabled = enabled
        managedInfrastructureURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        managedInfrastructurePublicKey = publicKey
            .filter(\.isHexDigit)
            .lowercased()
        UserDefaults.standard.set(enabled, forKey: "managedInfrastructureEnabled")
        UserDefaults.standard.set(managedInfrastructureURL, forKey: "managedInfrastructureURL")
        UserDefaults.standard.set(managedInfrastructurePublicKey, forKey: "managedInfrastructurePublicKey")
        didRefreshManagedInfrastructure = false
        if !enabled {
            managedInfrastructureSnapshot = nil
            managedInternetGateways = []
            managedPropagationNodeCount = 0
            managedInfrastructureStatus = "Disabled"
        }
    }

    public func setRemoteWakeEnabled(_ enabled: Bool) {
        remoteWakeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "remoteWakeEnabled")
        remoteWakeStatus = enabled ? "Waiting for registration" : "Disabled"
        if enabled { Task { await registerRemoteWake() } }
    }

    public func updateRemoteWakeDeviceToken(_ token: String) async {
        let normalized = token.lowercased()
        guard Data(hexadecimal: normalized)?.count == 32 else {
            remoteWakeStatus = "APNs token invalid"
            return
        }
        let defaults = UserDefaults.standard
        let changed = defaults.string(forKey: "sidebandAPNsDeviceToken") != normalized
        defaults.set(normalized, forKey: "sidebandAPNsDeviceToken")
        defaults.removeObject(forKey: "sidebandAPNsRegistrationError")
        if remoteWakeEnabled {
            remoteWakeStatus = changed ? "Token updated" : remoteWakeStatus
            await registerRemoteWake(force: changed)
        }
    }

    public func remoteWakeRegistrationFailed(_ message: String) {
        let reason = String(message.prefix(240))
        UserDefaults.standard.set(reason, forKey: "sidebandAPNsRegistrationError")
        remoteWakeStatus = "APNs registration unavailable"
    }

    public func refreshManagedInfrastructure(force: Bool = true, surfaceErrors: Bool = true) async {
        guard managedInfrastructureEnabled else {
            managedInfrastructureStatus = "Disabled"
            managedInternetGateways = []
            managedPropagationNodeCount = 0
            return
        }
        guard let url = URL(string: managedInfrastructureURL),
              let publicKey = Data(hexadecimal: managedInfrastructurePublicKey) else {
            managedInfrastructureStatus = "Configuration incomplete"
            if surfaceErrors { lastError = "Enter a valid HTTPS manifest URL and trusted 128-character operator public key." }
            return
        }
        managedInfrastructureStatus = "Refreshing signed directory…"
        do {
            let snapshot = try await managedInfrastructureDirectory.snapshot(
                url: url,
                trustedPublicKey: publicKey,
                forceRefresh: force
            )
            managedInfrastructureSnapshot = snapshot
            managedInternetGateways = snapshot.gateways
            managedPropagationNodeCount = snapshot.manifest.propagationNodes.count
            managedInfrastructureLastRefresh = snapshot.refreshedAt
            managedInfrastructureStatus = "\(snapshot.gateways.count) verified gateways"
            if propagationNodeIsAutomatic,
               let node = snapshot.manifest.propagationNodes.sorted(by: {
                   $0.priority == $1.priority ? $0.name < $1.name : $0.priority < $1.priority
               }).first {
                propagationNodeHash = node.destinationHash.lowercased()
                UserDefaults.standard.set(propagationNodeHash, forKey: "lxmfPropagationNode")
                if networkState == .ready { await requestPropagationNodePath() }
            }
            if remoteWakeEnabled { await registerRemoteWake() }
        } catch {
            managedInfrastructureStatus = "Verification failed"
            if surfaceErrors { lastError = error.localizedDescription }
        }
    }

    public func registerRemoteWake(force: Bool = false) async {
        guard remoteWakeEnabled else {
            remoteWakeStatus = "Disabled"
            return
        }
        guard let endpoint = managedInfrastructureSnapshot?.manifest.wakeRegistrationURL else {
            remoteWakeStatus = "No verified wake service"
            return
        }
        guard let token = UserDefaults.standard.string(forKey: "sidebandAPNsDeviceToken"), !token.isEmpty else {
            remoteWakeStatus = "Waiting for APNs token"
            return
        }
        do {
            #if DEBUG
            let environment = "sandbox"
            #else
            let environment = "production"
            #endif
            let registrationKey = ReticulumIdentity.fullHash(
                Data("\(endpoint.absoluteString)|\(environment)|\(token)|\(localDeliveryHash)".utf8)
            ).hex
            let defaults = UserDefaults.standard
            if !force,
               defaults.string(forKey: "sidebandAPNsRegistrationKey") == registrationKey,
               let lastRegistered = defaults.object(forKey: "sidebandAPNsLastRegisteredAt") as? Date,
               Date().timeIntervalSince(lastRegistered) < 24 * 60 * 60 {
                remoteWakeLastRegisteredAt = lastRegistered
                remoteWakeStatus = "Registered securely"
                return
            }
            remoteWakeStatus = "Registering…"
            let registration = try RemoteWakeRegistration.create(
                deviceToken: token,
                apnsEnvironment: environment,
                deliveryDestination: localDeliveryHash,
                identity: messagingIdentity
            )
            try await remoteWakeRegistrationClient.register(registration, at: endpoint)
            let registeredAt = Date.now
            defaults.set(registrationKey, forKey: "sidebandAPNsRegistrationKey")
            defaults.set(registeredAt, forKey: "sidebandAPNsLastRegisteredAt")
            defaults.removeObject(forKey: "sidebandAPNsRegistrationError")
            remoteWakeLastRegisteredAt = registeredAt
            remoteWakeStatus = "Registered securely"
        } catch {
            remoteWakeStatus = "Registration failed"
            lastError = error.localizedDescription
        }
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
        await requestPath(to: propagationNodeHash, surfaceErrors: false)
    }

    public var propagationNodeHasPath: Bool { hasPath(to: propagationNodeHash) }
    public var propagationNodePathPending: Bool { isPathPending(to: propagationNodeHash) }
    public var messagingIdentityHash: String { messagingIdentity.hash.hex }
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
            "Messaging identity: \(messagingIdentityHash)",
            "Local destination: \(localDeliveryHash)",
            "Last announced destination: \(lastAnnouncedDeliveryHash ?? "never")",
            "Last announce: \(lastDeliveryAnnounceAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
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
            "Inbound packet: \(lastInboundDeliveryPacketAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never"), destination \(lastInboundDeliveryDestination ?? "none"), interface \(lastInboundDeliveryInterface ?? "unknown"), matched \(lastInboundDeliveryMatched.map(String.init) ?? "unknown")",
            "Inbound message: \(lastInboundMessageAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never"), source \(lastInboundMessageSource ?? "unknown"), ID \(lastInboundMessageID ?? "none"), result \(lastInboundMessageResult ?? "none")",
            "Inbound validation: \(inboundMessagesAccepted) accepted, \(inboundMessagesRejected) rejected",
            "Delivery proofs: \(deliveryProofsSent) sent, \(deliveryProofsDeferred) deferred, last \(lastDeliveryProofSentAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never") via \(lastDeliveryProofInterface ?? "unknown") (\(lastDeliveryProofKind ?? "none"))",
            "Last proof failure: \(lastDeliveryProofFailureAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never") · \(lastDeliveryProofFailure ?? "none")",
            "Deferred maintenance: \(deferredKeepalives) keepalives, \(deferredTunnelSyntheses) tunnel syntheses",
            "Messages: \(messages.count) total, \(messages.count(where: { $0.state == .queued })) queued, \(messages.count(where: { $0.state == .failed })) failed",
            "Plugins: \(pluginRegistry.manifests.count) loaded, \(pluginRegistry.rejectedPluginDescriptions.count) rejected, \(pluginAuditEvents.count) audit events",
            "Propagation node: \(propagationNodeHash.isEmpty ? "not discovered" : propagationNodeHash) (\(propagationNodeIsAutomatic ? "automatic" : "manual"))",
            "Remote wake token: \(UserDefaults.standard.string(forKey: "sidebandAPNsDeviceToken") == nil ? "not registered" : "registered")",
            "Runtime: low power \(runtimeHealth.isLowPowerModeEnabled ? "on" : "off"), thermal \(runtimeHealth.thermalState.rawValue), memory warnings \(runtimeHealth.memoryPressureEvents)",
            "Last connected: \(lastNetworkReadyAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "Background refresh: \(lastBackgroundRefreshAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never") · \(lastBackgroundRefreshSucceeded.map { $0 ? "succeeded" : "incomplete" } ?? "not run")",
            "Recent delivery events:\n\(deliveryDiagnosticEvents.isEmpty ? "none" : deliveryDiagnosticEvents.joined(separator: "\n"))"
        ].joined(separator: "\n")
    }

    public var supportHealth: SidebandSupportHealth {
        let state: String
        switch networkState {
        case .stopped: state = "stopped"
        case .connecting: state = "connecting"
        case .ready: state = "ready"
        case .failed: state = "failed"
        }
        return SidebandSupportHealth(
            networkState: state,
            conversations: conversations.count,
            messages: messages.count,
            queuedMessages: queuedMessageCount,
            failedMessages: failedMessageCount,
            activeLinks: activeLinkCount,
            knownPaths: knownPathCount,
            attachmentTransfers: activeAttachmentTransferCount,
            memoryPressureEvents: runtimeHealth.memoryPressureEvents,
            backgroundWakeAttempts: runtimeHealth.backgroundWakeAttempts,
            backgroundWakeSuccesses: runtimeHealth.backgroundWakeSuccesses,
            lowPowerMode: runtimeHealth.isLowPowerModeEnabled,
            thermalState: runtimeHealth.thermalState.rawValue
        )
    }

    public func exportRedactedSupportBundleData(now: Date = .now) throws -> Data {
        let version = [
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ].compactMap { $0 }.joined(separator: " (") + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) == nil ? "" : ")")
        let bundle = SidebandSupportBundle(
            generatedAt: now,
            applicationVersion: version.isEmpty ? "development" : version,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            health: supportHealth,
            networkReport: SidebandSupportRedactor.redact(
                networkDiagnosticsReport.replacingOccurrences(of: "Local name: \(localDisplayName)", with: "Local name: <redacted>")
            ),
            attachmentReport: attachmentStorageReport == nil
                ? "Attachment storage has not been inspected."
                : SidebandSupportRedactor.redact(attachmentStorageDiagnostics)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
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

    /// Inspects or imports supported records from a historical Python
    /// Sideband SQLite database without modifying the source file.
    public func previewLegacySidebandDatabase(at url: URL) throws -> LegacySidebandSQLiteImporter.Preview {
        try LegacySidebandSQLiteImporter.preview(from: url)
    }

    public enum LegacyImportConflictPolicy: String, CaseIterable, Sendable {
        case mergeSafely
        case newConversationsOnly

        public var title: String {
            switch self {
            case .mergeSafely: "Merge with existing conversations"
            case .newConversationsOnly: "Import only new conversations"
            }
        }
    }

    @discardableResult
    public func importLegacySidebandDatabase(
        at url: URL,
        selection: LegacySidebandSQLiteImporter.Selection = .all,
        conflictPolicy: LegacyImportConflictPolicy = .mergeSafely
    ) throws -> LegacySidebandSQLiteImporter.Report {
        var effectiveSelection = selection
        if conflictPolicy == .newConversationsOnly {
            let existing = Set(conversations.map(\.destinationHash))
            let selected: Set<String>
            if let explicitlySelected = selection.selectedDestinations {
                selected = explicitlySelected
            } else {
                selected = Set(try LegacySidebandSQLiteImporter.preview(from: url).conversationCandidates.map(\.destinationHash))
            }
            effectiveSelection.selectedDestinations = selected.subtracting(existing)
        }
        let report = try LegacySidebandSQLiteImporter.load(from: url, selection: effectiveSelection)
        let rollback = try exportSnapshotData()
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
        legacyImportRollbackData = rollback
        let encryptedRollback = try localDataCipher.seal(rollback, context: "legacy-import-rollback-v1")
        try encryptedRollback.write(to: legacyImportRollbackURL, options: [.atomic, .completeFileProtection])
        canRollbackLegacyImport = true
        lastLegacyImportAt = .now
        lastLegacyImportSummary = "\(report.snapshot.conversations.count) conversations · \(report.snapshot.messages.count) messages · \(report.importedTelemetry) telemetry · \(report.importedAnnounces) announces"
        return report
    }

    @discardableResult
    public func rollbackLastLegacyImport() throws -> Bool {
        let rollback: Data?
        if let legacyImportRollbackData {
            rollback = legacyImportRollbackData
        } else if let encrypted = try? Data(contentsOf: legacyImportRollbackURL) {
            rollback = try localDataCipher.open(encrypted, context: "legacy-import-rollback-v1")
        } else {
            rollback = nil
        }
        guard let rollback else { return false }
        try restoreSnapshotData(rollback)
        self.legacyImportRollbackData = nil
        try? FileManager.default.removeItem(at: legacyImportRollbackURL)
        canRollbackLegacyImport = false
        lastLegacyImportAt = nil
        lastLegacyImportSummary = nil
        return true
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

    public func requestPath(to destinationHash: String, surfaceErrors: Bool = true) async {
        guard let target = Data(hexadecimal: destinationHash) else {
            if surfaceErrors { lastError = "The destination address is invalid." }
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
            if surfaceErrors { lastError = "Path request failed: \(error.localizedDescription)" }
        }
    }

    public func hasPath(to destinationHash: String) -> Bool { knownPathHashes.contains(destinationHash.lowercased()) }
    public func connectedRoute(to destinationHash: String) -> ConnectedRoute? {
        connectedRoutes[destinationHash.lowercased()]
    }
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

    public func networkMapSnapshot(now: Date = .now) async -> NetworkMapSnapshot {
        var interfaces = networkInterfaces.map { snapshot in
            NetworkMapInterface(
                id: snapshot.id,
                name: snapshot.name,
                detail: [snapshot.host, snapshot.port.map(String.init)].compactMap(\.self).joined(separator: ":"),
                status: Self.networkMapStatus(snapshot.state),
                lastSeen: snapshot.lastPacketAt ?? snapshot.connectedAt
            )
        }
        if autoInterfaceEnabled || autoInterfaceDiscovery.isListening || !autoInterfaceDiscovery.peers.isEmpty {
            let peerSummary = autoInterfaceDiscovery.peers.isEmpty
                ? "IPv6 multicast peer discovery"
                : "\(autoInterfaceDiscovery.peers.count) active peer\(autoInterfaceDiscovery.peers.count == 1 ? "" : "s")"
            interfaces.append(.init(
                id: "auto",
                name: "AutoInterface",
                detail: peerSummary,
                status: autoInterfaceDiscovery.isListening ? .online : (autoInterfaceEnabled ? .connecting : .offline),
                lastSeen: autoInterfaceDiscovery.peers.map(\.lastSeen).max()
            ))
        }
        for snapshot in rnodeManager.snapshots {
            interfaces.append(.init(
                id: "rnode:\(snapshot.id.uuidString)",
                name: snapshot.name,
                detail: "\(snapshot.transport.title) · \(snapshot.target.isEmpty ? "automatic" : snapshot.target)",
                status: Self.networkMapStatus(snapshot.state),
                lastSeen: snapshot.lastPacketAt ?? snapshot.connectedAt
            ))
        }

        let routes = await pathTable.all(now: now).map {
            NetworkMapRoute(
                destinationHash: $0.destinationHash.hex,
                interfaceID: $0.interfaceID,
                nextHopHash: $0.nextHop?.hex,
                hops: $0.hops,
                updatedAt: $0.updatedAt
            )
        }
        return NetworkMapBuilder.build(
            localHash: localDeliveryHash,
            localName: localDisplayName,
            interfaces: interfaces,
            routes: routes,
            discoveries: discoveries,
            conversations: conversations,
            propagationNodeHash: propagationNodeHash,
            generatedAt: now
        )
    }

    private static func networkMapStatus(_ state: ReticulumTCPInterface.State) -> NetworkMapNode.Status {
        switch state {
        case .ready: .online
        case .connecting: .connecting
        case .stopped, .failed: .offline
        }
    }

    private static func networkMapStatus(_ state: RNodeInterface.State) -> NetworkMapNode.Status {
        switch state {
        case .ready: .online
        case .searching, .connecting, .detecting, .configuring: .connecting
        case .stopped, .failed: .offline
        }
    }

    /// Installs the request state before any bytes leave the process.
    ///
    /// A TCP send can yield long enough for a fast peer's link proof to arrive.
    /// Registering after `transmit` therefore loses valid proofs as "unknown"
    /// and leaves attachment delivery waiting for a link that was already
    /// accepted remotely.
    static func transmitRegisteredLinkRequest(
        register: () -> Void,
        transmit: () async throws -> Void,
        rollback: () -> Void
    ) async throws {
        register()
        do {
            try await transmit()
        } catch {
            rollback()
            throw error
        }
    }

    public func requestLink(to destinationHash: String) async {
        let normalized = destinationHash.lowercased()
        guard let target = Data(hexadecimal: normalized) else {
            lastError = "The destination address is invalid."
            return
        }
        guard hasPath(to: normalized) else {
            if !isPathPending(to: normalized) {
                await requestPath(to: normalized, surfaceErrors: false)
            }
            deferLinkRequest(to: normalized)
            return
        }
        guard networkState == .ready else {
            deferLinkRequest(to: normalized)
            if networkState != .connecting { await startAutomaticConnection() }
            return
        }
        guard outboundSession(to: normalized) == nil,
              !activatingOutboundLinkIDs.contains(where: { linkRemoteDestinations[$0] == normalized }),
              !pendingLinks.values.contains(where: { $0.destinationHash == target }) else {
            return
        }
        deferredLinkRetryTokens.removeValue(forKey: normalized)
        pendingLinkHashes.remove(normalized)
        do {
            clearPendingLinks(to: normalized)
            let request = try ReticulumLinkRequest(destinationHash: target)
            let linkID = request.linkID.hex
            let timeoutToken = UUID()
            try await Self.transmitRegisteredLinkRequest {
                pendingLinks[linkID] = request
                pendingLinkTimeoutTokens[linkID] = timeoutToken
                pendingLinkHashes.insert(normalized)
                UserDefaults.standard.set(linkID, forKey: "reticulumLastPendingLink")
                deliveryDebugTrace("TX link request \(linkID) registered for \(normalized)")
            } transmit: {
                // A peer may be reachable through more than one independent
                // public reticule. The proof binds the link to whichever route
                // actually succeeds, after which encrypted traffic uses only
                // that interface.
                try await transmitDestinationPacket(
                    request.rawPacket,
                    destinationHash: target,
                    redundantRoutes: true
                )
            } rollback: {
                pendingLinks.removeValue(forKey: linkID)
                pendingLinkTimeoutTokens.removeValue(forKey: linkID)
                if !pendingLinks.values.contains(where: { $0.destinationHash == target }) {
                    pendingLinkHashes.remove(normalized)
                }
                if UserDefaults.standard.string(forKey: "reticulumLastPendingLink") == linkID {
                    UserDefaults.standard.removeObject(forKey: "reticulumLastPendingLink")
                }
            }
            scheduleLinkTimeout(linkID: linkID, destinationHash: normalized, token: timeoutToken)
        } catch {
            // iOS can replace a TCP connection while a still-valid route is
            // visible. Secure-link maintenance retries in the background.
            deferLinkRequest(to: normalized)
            if networkState != .connecting { await startAutomaticConnection() }
        }
    }

    private func deferLinkRequest(to destinationHash: String) {
        guard outboundSession(to: destinationHash) == nil,
              !activatingOutboundLinkIDs.contains(where: { linkRemoteDestinations[$0] == destinationHash }),
              !pendingLinks.values.contains(where: { $0.destinationHash.hex == destinationHash })
        else { return }
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
        // A direct-link attempt can fail when a public route becomes stale.
        // Refresh the path and negotiate a new authenticated link; stock LXMF
        // keeps ordinary automatic delivery direct throughout this lifecycle.
        if UserDefaults.standard.string(forKey: "reticulumLastPendingLink") == linkID {
            UserDefaults.standard.removeObject(forKey: "reticulumLastPendingLink")
        }
        guard networkState == .ready else { return }
        if let destination = Data(hexadecimal: destinationHash) {
            await pathTable.invalidate(destination)
            await refreshPathState()
        }
        await requestPath(to: destinationHash, surfaceErrors: false)
        // Route refresh is asynchronous. Keep the durable attachment moving
        // even if the next announce arrives outside a foreground delivery
        // pass; deferLinkRequest coalesces retries and requestLink suppresses
        // duplicate path broadcasts while discovery is pending.
        deferLinkRequest(to: destinationHash)
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
        deliveryConnectionEpoch = UUID()
        // A receipt tied to a vanished interface cannot arrive on the new
        // connection. Requeue it immediately instead of displaying Sent and
        // holding a delivery-window slot until its timer expires.
        let interruptedReceiptCount = pendingReceipts.count
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
        activatingOutboundLinkIDs.removeAll()
        deliveryReadyOutboundLinkIDs.removeAll()
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
        if interruptedReceiptCount > 0 || !interruptedResources.isEmpty { save() }
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
        let aggregateWasReady = networkState == .ready
        let previousInterfaceIDs = knownTCPInterfaceIDs
        let currentInterfaceIDs = Set(snapshots.compactMap { snapshot in
            snapshot.state == .ready ? snapshot.id : nil
        })
        let addedInterfaceIDs = currentInterfaceIDs.subtracting(previousInterfaceIDs)
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
            // The first ready interface is handled by
            // refreshAggregateNetworkState(), which broadcasts one initial
            // announce. When another interface joins an already-live pool,
            // announce only on that interface. Broadcasting on every ready
            // callback caused reconnecting public gateways to amplify one
            // transition into an announce storm across the whole pool.
            if aggregateWasReady, !addedInterfaceIDs.isEmpty {
                Task {
                    for interfaceID in addedInterfaceIDs {
                        await announceLocalDeliveryDestination(on: interfaceID)
                    }
                }
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
                await requestPath(to: destination, surfaceErrors: false)
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
        didRefreshCommunityGateways = false
        didRefreshManagedInfrastructure = false
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

        if !didRefreshCommunityGateways {
            if !didRefreshManagedInfrastructure {
                didRefreshManagedInfrastructure = true
                await refreshManagedInfrastructure(surfaceErrors: false)
            }
            didRefreshCommunityGateways = true
            communityInternetGateways = await communityInterfaceDirectory.gateways()
        }
        let internetCandidates = PublicReticulumGateways.ordered(
            customHost: networkInternetHost,
            customPort: networkInternetPort,
            preferredID: preferredInternetGatewayID,
            managedGateways: managedInternetGateways,
            communityGateways: communityInternetGateways,
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
        runtimeHealth.recordReachabilityTransition()
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
        // The ready transition can arrive through both the TCP pool and the
        // aggregate network state. Coalesce those callbacks so maintenance
        // traffic is emitted once per transition instead of racing itself.
        guard !tcpTunnelSynthesisInProgress, let networkInterfacePool else { return }
        tcpTunnelSynthesisInProgress = true
        defer { tcpTunnelSynthesisInProgress = false }
        do {
            try await networkInterfacePool.send(
                rawPacket: ReticulumTunnelSynthesis.packet(identity: transportIdentity, interfaceHash: tcpInterfaceHash)
            )
        } catch {
            // A ready interface can disappear between the state callback and
            // this send. Tunnel synthesis is advisory maintenance traffic; the
            // pool's reconnect controller will retry it on the next ready
            // transition. Record the event without interrupting the user or
            // disturbing queued messages.
            deferredTunnelSyntheses += 1
            lastDeferredTunnelSynthesisAt = .now
            UserDefaults.standard.set(deferredTunnelSyntheses, forKey: "reticulumDeferredTunnelSyntheses")
            UserDefaults.standard.set(lastDeferredTunnelSynthesisAt, forKey: "reticulumLastDeferredTunnelSynthesisAt")
            deliveryDebugTrace("TCP tunnel synthesis deferred during reconnect: \(error.localizedDescription)")
        }
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
    private func announceLocalDeliveryDestination(on interfaceID: String? = nil) async -> Bool {
        do {
            let packet = try ReticulumAnnounceBuilder.packet(identity: messagingIdentity, destinationName: "lxmf.delivery", appData: localAnnounceAppData)
            let voicePacket = try ReticulumAnnounceBuilder.packet(identity: messagingIdentity, destinationName: LXSTVoice.destinationName)
            if let interfaceID {
                try await transmitRawPacket(packet, on: interfaceID)
                try await transmitRawPacket(voicePacket, on: interfaceID)
            } else {
                try await transmitRawPacket(packet)
                try await transmitRawPacket(voicePacket)
            }
            deliveryAnnouncesSent += 1
            lastDeliveryAnnounceAt = .now
            lastAnnouncedDeliveryHash = localDeliveryHash
            UserDefaults.standard.set(lastAnnouncedDeliveryHash, forKey: "lxmfLastAnnouncedDeliveryHash")
            UserDefaults.standard.set(lastDeliveryAnnounceAt, forKey: "lxmfLastDeliveryAnnounceAt")
            let scope = interfaceID.map { " on \($0)" } ?? " on all ready interfaces"
            recordDeliveryDiagnosticEvent("Announced delivery destination \(localDeliveryHash)\(scope)")
            return true
        } catch {
            // Connection transitions are retried by the engine. An announce is
            // maintenance traffic and must never interrupt the user with a modal.
            recordDeliveryDiagnosticEvent("Delivery announce deferred: \(error.localizedDescription)")
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
        interfaces += await configuredInterfaceRuntime.readyInterfaceDescriptors()
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
        if ReticulumConfiguredInterfaceRuntime.profileID(from: forward.interfaceID) != nil {
            try? await configuredInterfaceRuntime.send(rawPacket: forward.rawPacket, on: forward.interfaceID)
        } else if forward.interfaceID.hasPrefix("rnode:"),
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
        if let request = ReticulumPathRequest.decode(packet),
           request.targetHash.hex == localDeliveryHash || request.targetHash.hex == localVoiceHash {
            answerLocalPathRequest(request, interfaceID: interfaceID)
            return
        }
        if packet.packetType == .linkRequest,
           packet.destinationHash.hex == localDeliveryHash || packet.destinationHash.hex == localVoiceHash {
            recordInboundDeliveryPacket(destination: packet.destinationHash.hex, interfaceID: interfaceID, matched: true)
        } else if packet.packetType == .data,
                  packet.destinationType == .single,
                  packet.destinationHash.hex == localDeliveryHash {
            recordInboundDeliveryPacket(destination: packet.destinationHash.hex, interfaceID: interfaceID, matched: true)
        }
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
            receiveLinkPacket(packet, interfaceID: interfaceID)
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

    private func answerLocalPathRequest(
        _ request: (targetHash: Data, tag: Data),
        interfaceID: String?
    ) {
        let now = Date.now
        answeredLocalPathRequestTags = answeredLocalPathRequestTags.filter {
            now.timeIntervalSince($0.value) < 120
        }
        let requestKey = request.targetHash + request.tag
        guard answeredLocalPathRequestTags[requestKey] == nil else { return }
        answeredLocalPathRequestTags[requestKey] = now
        let destinationName = request.targetHash.hex == localVoiceHash
            ? LXSTVoice.destinationName
            : "lxmf.delivery"
        let appData = destinationName == "lxmf.delivery" ? localAnnounceAppData : Data()
        Task {
            // Match the reference transport grace period so a directly
            // attached destination can answer before a cached transport route.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let response = try ReticulumAnnounceBuilder.packet(
                    identity: messagingIdentity,
                    destinationName: destinationName,
                    appData: appData,
                    context: 0x0B
                )
                if let interfaceID { try await transmitRawPacket(response, on: interfaceID) }
                else { try await transmitRawPacket(response) }
                recordDeliveryDiagnosticEvent(
                    "Answered path request for \(request.targetHash.hex) on \(interfaceID ?? "automatic route")"
                )
            } catch {
                recordDeliveryDiagnosticEvent(
                    "Path response deferred on \(interfaceID ?? "automatic route"): \(error.localizedDescription)"
                )
            }
        }
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
                await requestPath(to: hash, surfaceErrors: false)
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
        let destination = request.destinationHash.hex
        let supersededLinkIDs = Self.supersededOutboundLinkIDs(
            destinationHash: destination,
            keeping: linkID,
            remoteDestinations: linkRemoteDestinations,
            inboundLinkIDs: inboundLinkIDs,
            protectedLinkIDs: Set(outgoingResources.values.map(\.linkID))
        )
        for supersededLinkID in supersededLinkIDs {
            let orphanedReceipts = pendingReceipts.filter { $0.value.linkID == supersededLinkID }
            for (hash, receipt) in orphanedReceipts {
                pendingReceipts.removeValue(forKey: hash)
                receiptTimeoutTasks.removeValue(forKey: hash)?.cancel()
                if let index = messages.firstIndex(where: { $0.id == receipt.messageID }) {
                    messages[index].state = .queued
                    messages[index].lastDeliveryFailure = "Secure route changed; retrying on the newest verified link."
                }
            }
            deliveryDebugTrace("Retiring superseded outbound link \(supersededLinkID) for \(destination)")
            removeLink(supersededLinkID)
        }
        deliveryDebugTrace("RX link proof \(linkID) activated for \(request.destinationHash.hex)")
        activeLinks[linkID] = session
        if let interfaceID { linkInterfaceIDs[linkID] = interfaceID }
        pendingLinks.removeValue(forKey: linkID)
        pendingLinkTimeoutTokens.removeValue(forKey: linkID)
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
            activatingOutboundLinkIDs.insert(linkID)
            Task { await activateDirectLink(session, conversationID: conversation.id) }
        }
    }

    static func supersededOutboundLinkIDs(
        destinationHash: String,
        keeping linkID: String,
        remoteDestinations: [String: String],
        inboundLinkIDs: Set<String>,
        protectedLinkIDs: Set<String> = []
    ) -> [String] {
        remoteDestinations.compactMap { candidateLinkID, remoteDestination in
            guard candidateLinkID != linkID,
                  remoteDestination == destinationHash,
                  !inboundLinkIDs.contains(candidateLinkID),
                  !protectedLinkIDs.contains(candidateLinkID) else {
                return nil
            }
            return candidateLinkID
        }.sorted()
    }

    private func receiveLinkPacket(_ packet: ReticulumPacket, interfaceID: String?) {
        let linkID = packet.destinationHash.hex
        guard let session = activeLinks[linkID] else {
            deliveryDebugTrace("RX link packet for unknown session \(linkID), context \(packet.context), bytes \(packet.data.count)")
            return
        }
        // Reticulum paths can move between public gateways during a live link.
        // Always return application proofs over the interface that most
        // recently carried this link, rather than its original or an arbitrary
        // ready interface.
        if let interfaceID { linkInterfaceIDs[linkID] = interfaceID }
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
                cancelResource(
                    hash: plaintext.hex,
                    initiatedBySender: packet.context == 0x06
                )
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
        let ingress = interfaceID ?? "all ready interfaces"
        deliveryDebugTrace(
            "RX link request \(linkID) accepted on \(ingress); returning proof "
                + "bytes=\(incoming.proofPacket.count) rawBase64=\(incoming.proofPacket.base64EncodedString())"
        )
        activeLinks[linkID] = incoming.session
        if let interfaceID { linkInterfaceIDs[linkID] = interfaceID }
        inboundLinkIDs.insert(linkID)
        if isVoice { voiceLinkIDs.insert(linkID) }
        Task {
            do {
                if let interfaceID { try await transmitRawPacket(incoming.proofPacket, on: interfaceID) }
                else { try await transmitRawPacket(incoming.proofPacket) }
                deliveryDebugTrace("RX link proof \(linkID) handed to transport on \(ingress)")
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
            catch {
                deliveryDebugTrace("RX link proof \(linkID) failed on \(ingress): \(error.localizedDescription)")
                lastError = "Incoming link proof failed: \(error.localizedDescription)"
            }
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
        guard packet.context == 0x00 else { return }
        guard let message = try? LXMFReceivedMessage(packed: plaintext) else {
            recordInboundMessage(source: nil, messageID: nil, result: "rejected: LXMF decode failed")
            return
        }
        guard message.destinationHash.hex == localDeliveryHash else {
            recordInboundDeliveryPacket(destination: message.destinationHash.hex, interfaceID: linkInterfaceIDs[session.linkID.hex], matched: false)
            recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: destination mismatch")
            return
        }
        Task {
            // Stock LXMF senders are not required to identify themselves with
            // LINKIDENTIFY before sending a message. Resolve the signing
            // identity from a validated announce, including an announce that
            // was restored into the path table before this UI session began.
            var remoteIdentity = inboundRemoteIdentities[session.linkID.hex]
                ?? discoveries.first(where: {
                    $0.destinationHash == message.sourceHash.hex && $0.isValidated
                }).flatMap(\.publicKey).flatMap { try? ReticulumIdentity(publicKey: $0) }

            if remoteIdentity == nil,
               let path = await pathTable.path(to: message.sourceHash),
               Self.identityPublicKey(path.publicKey, matchesLXMFDeliveryHash: message.sourceHash) {
                remoteIdentity = try? ReticulumIdentity(publicKey: path.publicKey)
            }

            guard let remoteIdentity else {
                recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: sender identity unavailable")
                return
            }
            guard message.validate(with: remoteIdentity) else {
                recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: signature invalid")
                return
            }
            bind(session: session, to: remoteIdentity)

            let wasPreviouslyReceived = receivedLXMFIDs.contains(message.messageID.hex)
            let accepted = wasPreviouslyReceived ? true : await importReceivedResourceMessage(message, sourceIdentity: remoteIdentity)
            guard accepted else {
                recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: payload validation failed")
                return
            }
            recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: wasPreviouslyReceived ? "accepted duplicate" : "accepted")
            let proofInterface = Self.inboundProofInterface(
                for: session.linkID.hex,
                registeredInterfaces: linkInterfaceIDs
            )
            do {
                let hash = packet.packetHash
                let proof = try session.proofPacket(for: packet)
                deliveryDebugTrace(
                    "RX direct proof prepared link=\(session.linkID.hex) " +
                    "interface=\(proofInterface ?? "automatic route") " +
                    "packetHash=\(hash.hex) rawBase64=\(proof.base64EncodedString())"
                )
                if let proofInterface { try await transmitRawPacket(proof, on: proofInterface) }
                else { try await transmitRawPacket(proof) }
                deliveryDebugTrace(
                    "RX direct proof handed to transport link=\(session.linkID.hex) " +
                    "interface=\(proofInterface ?? "automatic route") packetHash=\(hash.hex)"
                )
                recordDeliveryProofSent(kind: "direct", interfaceID: proofInterface)
            } catch {
                // The sender retains the message until it receives this proof
                // and will retry idempotently. Interface transitions are
                // therefore recoverable background state, not a user-facing
                // modal error on the receiving device.
                recordDeliveryProofFailure(kind: "direct", interfaceID: proofInterface, error: error)
                deliveryDebugTrace("RX direct proof send deferred after interface loss: \(error.localizedDescription)")
            }
        }
    }

    static func identityPublicKey(_ publicKey: Data, matchesLXMFDeliveryHash destinationHash: Data) -> Bool {
        guard let identity = try? ReticulumIdentity(publicKey: publicKey) else { return false }
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash) == destinationHash
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
                    try await transmitLinkPacket(
                        try session.encryptedPacket(identifyData, context: 0xfb),
                        session: session
                    )
                    try await transmitLinkPacket(
                        try session.encryptedPacket(LXSTVoice.preferredProfile(voiceCall?.profile ?? preferredVoiceProfile)),
                        session: session
                    )
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
        try await transmitLinkPacket(
            try session.encryptedPacket(LXSTVoice.signalling([signal.rawValue])),
            session: session
        )
    }

    private func closeVoiceLink(_ session: ReticulumLinkSession) async {
        try? await transmitLinkPacket(try session.closePacket(), session: session)
        removeLink(session.linkID.hex)
    }

    private func removeLink(_ linkID: String) {
        let remote = linkRemoteDestinations.removeValue(forKey: linkID)
        activeLinks.removeValue(forKey: linkID)
        activatingOutboundLinkIDs.remove(linkID)
        deliveryReadyOutboundLinkIDs.remove(linkID)
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
        outboundSession(to: destinationHash)
            ?? activeLinks.first { linkRemoteDestinations[$0.key] == destinationHash }.map(\.value)
    }

    /// A link initiated by the remote peer is an inbound delivery channel.
    /// Stock LXMF does not install an incoming-resource handler on the
    /// initiating end of that link, so it must not replace our independently
    /// initiated outbound delivery channel.
    private func outboundSession(to destinationHash: String) -> ReticulumLinkSession? {
        guard let linkID = Self.deliveryReadyOutboundLinkID(
            destinationHash: destinationHash,
            activeLinkIDs: Set(activeLinks.keys),
            readyLinkIDs: deliveryReadyOutboundLinkIDs,
            inboundLinkIDs: inboundLinkIDs,
            remoteDestinations: linkRemoteDestinations
        ) else { return nil }
        return activeLinks[linkID]
    }

    static func deliveryReadyOutboundLinkID(
        destinationHash: String,
        activeLinkIDs: Set<String>,
        readyLinkIDs: Set<String>,
        inboundLinkIDs: Set<String>,
        remoteDestinations: [String: String]
    ) -> String? {
        activeLinkIDs.sorted().first {
            readyLinkIDs.contains($0)
                && !inboundLinkIDs.contains($0)
                && remoteDestinations[$0] == destinationHash
        }
    }

    private func receiveOpportunisticPacket(_ packet: ReticulumPacket, interfaceID: String?) {
        guard let decrypted = try? messagingIdentity.decrypt(packet.data) else {
            recordInboundMessage(source: nil, messageID: nil, result: "rejected: opportunistic decrypt failed")
            deliveryDebugTrace("RX opportunistic decrypt failed")
            return
        }
        guard let message = try? LXMFReceivedMessage(packed: packet.destinationHash + decrypted),
              message.destinationHash.hex == localDeliveryHash else {
            recordInboundMessage(source: nil, messageID: nil, result: "rejected: opportunistic LXMF decode failed")
            deliveryDebugTrace("RX opportunistic LXMF decode failed")
            return
        }
        guard let discovery = discoveries.first(where: { $0.destinationHash == message.sourceHash.hex }),
              let publicKey = discovery.publicKey,
              let sourceIdentity = try? ReticulumIdentity(publicKey: publicKey) else {
            recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: sender identity unavailable")
            deliveryDebugTrace("RX opportunistic sender identity unavailable: \(message.sourceHash.hex)")
            return
        }
        guard message.validate(with: sourceIdentity) else {
            recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: signature invalid")
            deliveryDebugTrace("RX opportunistic signature invalid: \(message.sourceHash.hex)")
            return
        }
        deliveryDebugTrace("RX opportunistic LXMF accepted from \(message.sourceHash.hex)")
        let wasPreviouslyReceived = receivedLXMFIDs.contains(message.messageID.hex)
        guard wasPreviouslyReceived || importReceivedMessage(message, sourceIdentity: sourceIdentity) else {
            recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: "rejected: payload validation failed")
            return
        }
        recordInboundMessage(source: message.sourceHash.hex, messageID: message.messageID.hex, result: wasPreviouslyReceived ? "accepted duplicate" : "accepted")
        if !wasPreviouslyReceived { opportunisticDeliveriesReceived += 1 }
        Task {
            do {
                let proof = try ReticulumProof.packet(for: packet, identity: messagingIdentity)
                if let interfaceID { try await transmitRawPacket(proof, on: interfaceID) }
                else { try await transmitRawPacket(proof) }
                recordDeliveryProofSent(kind: "opportunistic", interfaceID: interfaceID)
            }
            catch {
                recordDeliveryProofFailure(kind: "opportunistic", interfaceID: interfaceID, error: error)
                deliveryDebugTrace("RX proof send deferred after interface loss: \(error.localizedDescription)")
            }
        }
    }

    private func recordInboundDeliveryPacket(destination: String, interfaceID: String?, matched: Bool) {
        lastInboundDeliveryPacketAt = .now
        lastInboundDeliveryDestination = destination
        lastInboundDeliveryInterface = interfaceID
        lastInboundDeliveryMatched = matched
        UserDefaults.standard.set(lastInboundDeliveryPacketAt, forKey: "lxmfLastInboundDeliveryPacketAt")
        UserDefaults.standard.set(destination, forKey: "lxmfLastInboundDeliveryDestination")
        if let interfaceID { UserDefaults.standard.set(interfaceID, forKey: "lxmfLastInboundDeliveryInterface") }
        else { UserDefaults.standard.removeObject(forKey: "lxmfLastInboundDeliveryInterface") }
        UserDefaults.standard.set(matched, forKey: "lxmfLastInboundDeliveryMatched")
        recordDeliveryDiagnosticEvent("Inbound packet for \(destination) on \(interfaceID ?? "unknown") · \(matched ? "destination matched" : "destination mismatch")")
    }

    static func inboundProofInterface(for linkID: String, registeredInterfaces: [String: String]) -> String? {
        registeredInterfaces[linkID]
    }

    private func recordInboundMessage(source: String?, messageID: String?, result: String) {
        lastInboundMessageAt = .now
        lastInboundMessageSource = source
        lastInboundMessageID = messageID
        lastInboundMessageResult = result
        if result.hasPrefix("accepted") { inboundMessagesAccepted += 1 }
        else { inboundMessagesRejected += 1 }
        UserDefaults.standard.set(lastInboundMessageAt, forKey: "lxmfLastInboundMessageAt")
        if let source { UserDefaults.standard.set(source, forKey: "lxmfLastInboundMessageSource") }
        else { UserDefaults.standard.removeObject(forKey: "lxmfLastInboundMessageSource") }
        if let messageID { UserDefaults.standard.set(messageID, forKey: "lxmfLastInboundMessageID") }
        else { UserDefaults.standard.removeObject(forKey: "lxmfLastInboundMessageID") }
        UserDefaults.standard.set(result, forKey: "lxmfLastInboundMessageResult")
        UserDefaults.standard.set(inboundMessagesAccepted, forKey: "lxmfInboundMessagesAccepted")
        UserDefaults.standard.set(inboundMessagesRejected, forKey: "lxmfInboundMessagesRejected")
        recordDeliveryDiagnosticEvent("Inbound LXMF \(messageID ?? "unknown") from \(source ?? "unknown") · \(result)")
    }

    private func recordDeliveryProofSent(kind: String, interfaceID: String?) {
        lastDeliveryProofSentAt = .now
        lastDeliveryProofInterface = interfaceID
        lastDeliveryProofKind = kind
        deliveryProofsSent += 1
        UserDefaults.standard.set(lastDeliveryProofSentAt, forKey: "lxmfLastDeliveryProofSentAt")
        if let interfaceID { UserDefaults.standard.set(interfaceID, forKey: "lxmfLastDeliveryProofInterface") }
        else { UserDefaults.standard.removeObject(forKey: "lxmfLastDeliveryProofInterface") }
        UserDefaults.standard.set(kind, forKey: "lxmfLastDeliveryProofKind")
        UserDefaults.standard.set(deliveryProofsSent, forKey: "lxmfDeliveryProofsSent")
        recordDeliveryDiagnosticEvent("Sent \(kind) delivery proof on \(interfaceID ?? "automatic route")")
    }

    private func recordDeliveryProofFailure(kind: String, interfaceID: String?, error: Error) {
        lastDeliveryProofFailureAt = .now
        lastDeliveryProofFailure = "\(kind) on \(interfaceID ?? "automatic route"): \(error.localizedDescription)"
        deliveryProofsDeferred += 1
        UserDefaults.standard.set(lastDeliveryProofFailureAt, forKey: "lxmfLastDeliveryProofFailureAt")
        UserDefaults.standard.set(lastDeliveryProofFailure, forKey: "lxmfLastDeliveryProofFailure")
        UserDefaults.standard.set(deliveryProofsDeferred, forKey: "lxmfDeliveryProofsDeferred")
        recordDeliveryDiagnosticEvent("Deferred \(lastDeliveryProofFailure ?? "delivery proof")")
    }

    private func recordDeliveryDiagnosticEvent(_ event: String) {
        let entry = "\(ISO8601DateFormatter().string(from: .now)) · \(event)"
        deliveryDiagnosticEvents.insert(entry, at: 0)
        deliveryDiagnosticEvents = Array(deliveryDiagnosticEvents.prefix(24))
        UserDefaults.standard.set(deliveryDiagnosticEvents, forKey: "lxmfDeliveryDiagnosticEvents")
        deliveryDebugTrace(event)
    }

    private func deliveryDebugTrace(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["SIDEBAND_SOAK_NETWORK_MODE"] != nil else { return }
        print("SIDEBAND_DELIVERY_TRACE \(message())")
    }

    private func sendKeepalive(on session: ReticulumLinkSession) async {
        do {
            try await transmitLinkPacket(session.keepalivePacket(), session: session)
            keepalivesSent += 1
            UserDefaults.standard.set(keepalivesSent, forKey: "reticulumKeepalivesSent")
        } catch {
            // A link timer can race an intentional disconnect or automatic gateway
            // handover. Keepalives are advisory, so retain this as diagnostics and
            // let the background connection controller recover without interrupting
            // the user or changing queued-message state.
            deferredKeepalives += 1
            UserDefaults.standard.set(deferredKeepalives, forKey: "reticulumDeferredKeepalives")
            deliveryDebugTrace("Link keepalive deferred during reconnect: \(error.localizedDescription)")
        }
    }

    private func activateAndRequestPropagation(on session: ReticulumLinkSession) async {
        do {
            try await transmitLinkPacket(
                try session.encryptedPacket(MessagePack.double(session.rtt), context: 0xfe),
                session: session
            )
            try await identify(session)
            await syncPropagationNow()
            for conversation in conversations { await propagateQueued(for: conversation.id) }
            await sendKeepalive(on: session)
        } catch { lastError = "Propagation request failed: \(error.localizedDescription)" }
    }

    private func activateDirectLink(_ session: ReticulumLinkSession, conversationID: UUID) async {
        do {
            // LINKIDENTIFY authenticates this secure link, but stock LXMF
            // resolves message signatures through the separately announced
            // `lxmf.delivery` destination. Send a fresh signed announce for
            // every newly activated peer link and give transports a bounded
            // propagation window before the first queued message is released.
            // This prevents the receiver from permanently recording the first
            // message as SOURCE_UNKNOWN on multi-hop public paths.
            guard await prepareLocalIdentityForDirectDelivery() else {
                recordDeliveryDiagnosticEvent("Held direct delivery until the local identity can be announced")
                return
            }
            try await transmitLinkPacket(
                try session.encryptedPacket(MessagePack.double(session.rtt), context: 0xfe),
                session: session
            )
            try await identify(session)
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                activatingOutboundLinkIDs.remove(session.linkID.hex)
                return
            }
            guard activeLinks[session.linkID.hex] != nil else { return }
            activatingOutboundLinkIDs.remove(session.linkID.hex)
            deliveryReadyOutboundLinkIDs.insert(session.linkID.hex)
            await attemptDelivery(for: conversationID)
            await sendKeepalive(on: session)
        } catch {
            activatingOutboundLinkIDs.remove(session.linkID.hex)
            deliveryReadyOutboundLinkIDs.remove(session.linkID.hex)
            lastError = "Direct link activation failed: \(error.localizedDescription)"
            removeLink(session.linkID.hex)
            if let conversation = conversations.first(where: { $0.id == conversationID }) {
                deferLinkRequest(to: conversation.destinationHash)
            }
        }
    }

    private func prepareLocalIdentityForDirectDelivery() async -> Bool {
        for retry in 0..<3 {
            if await announceLocalDeliveryDestination() { return true }
            guard retry < 2, !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func identify(_ session: ReticulumLinkSession) async throws {
        let payload = try Self.linkIdentificationPayload(session: session, identity: messagingIdentity)
        try await transmitLinkPacket(
            try session.encryptedPacket(payload, context: 0xfb),
            session: session
        )
        linkIdentificationsSent += 1
        recordDeliveryDiagnosticEvent("Identified messaging identity \(messagingIdentityHash) on link \(session.linkID.hex)")
    }

    static func linkIdentificationPayload(session: ReticulumLinkSession, identity: ReticulumIdentity) throws -> Data {
        identity.publicKey + (try identity.sign(session.linkID + identity.publicKey))
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
                try await transmitLinkPacket(requestPacket, session: session); propagationRequestsSent += 1
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
            do {
                try await transmitLinkPacket(
                    try session.encryptedPacket(
                        LXMFPropagation.acknowledgementRequest(acknowledgements),
                        context: 0x09
                    ),
                    session: session
                )
            }
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
                Task { await handleIncomingCommands(commands, conversationID: conversation.id, messageTimestamp: incomingMessage.timestamp) }
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
        if let linkedInterfaceID,
           ReticulumConfiguredInterfaceRuntime.profileID(from: linkedInterfaceID) != nil {
            do {
                try await configuredInterfaceRuntime.send(rawPacket: packet, on: linkedInterfaceID)
                transmitted = true
            } catch {
                finalError = error
            }
        } else if let linkedInterfaceID, linkedInterfaceID.hasPrefix("rnode:"),
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
        if linkedInterfaceID == nil {
            if await configuredInterfaceRuntime.broadcast(rawPacket: packet) > 0 {
                transmitted = true
            }
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
        if ReticulumConfiguredInterfaceRuntime.profileID(from: interfaceID) != nil {
            try await configuredInterfaceRuntime.send(rawPacket: packet, on: interfaceID)
            return
        }
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

    /// Link packets follow the interface on which the handshake completed.
    /// Broadcasting encrypted link traffic to every public gateway wastes
    /// constrained capacity and can strand a session behind a transport that
    /// never saw its link request.
    private func transmitLinkPacket(_ packet: Data, session: ReticulumLinkSession) async throws {
        if let interfaceID = Self.inboundProofInterface(
            for: session.linkID.hex,
            registeredInterfaces: linkInterfaceIDs
        ) {
            try await transmitRawPacket(packet, on: interfaceID)
        } else {
            try await transmitRawPacket(packet)
        }
    }

    private func transmitDestinationPacket(
        _ packet: Data,
        destinationHash: Data,
        redundantRoutes: Bool = false
    ) async throws {
        var transmitted = false
        let configuredInterfaceIDs = await configuredInterfaceRuntime.readyInterfaceIDs()
        let configuredRoutes = await pathTable.paths(to: destinationHash).filter {
            $0.interfaceID.map(configuredInterfaceIDs.contains) == true
        }
        if let route = configuredRoutes.first, let interfaceID = route.interfaceID {
            let routedPacket = (try? ReticulumPacket(raw: packet).prepared(for: route)) ?? packet
            if (try? await configuredInterfaceRuntime.send(rawPacket: routedPacket, on: interfaceID)) != nil {
                transmitted = true
            }
        } else if await configuredInterfaceRuntime.broadcast(rawPacket: packet) > 0 {
            transmitted = true
        }
        if let networkInterfacePool, tcpNetworkState == .ready {
            let interfaceIDs = await networkInterfacePool.readyInterfaceIDs()
            var tcpSent = false
            let availableRoutes = await pathTable.paths(to: destinationHash).filter { path in
                path.interfaceID.map(interfaceIDs.contains) == true
            }
            let selectedRoutes = redundantRoutes
                ? Array(availableRoutes.prefix(3))
                : Array(availableRoutes.prefix(1))
            if !selectedRoutes.isEmpty {
                for path in selectedRoutes {
                    guard let interfaceID = path.interfaceID else { continue }
                    do {
                        let routedPacket = try ReticulumPacket(raw: packet).prepared(for: path)
                        try await networkInterfacePool.send(rawPacket: routedPacket, on: interfaceID)
                        tcpSent = true
                        let routeDescription = path.hops > 1 ? "routed via \(path.nextHop?.hex ?? "unknown")" : "direct"
                        deliveryDebugTrace("TX \(destinationHash.hex) on \(interfaceID), \(path.hops) hop(s), \(routeDescription)")
                    } catch {
                        deliveryDebugTrace("TX \(destinationHash.hex) on \(interfaceID) failed: \(error.localizedDescription)")
                    }
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
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard !pending.isEmpty else { return }
        // Preserve conversational order across mixed text and resource
        // messages. A later small packet must never overtake an earlier large
        // attachment while it is waiting for its resource proof.
        let hasReceiptInFlight = pendingReceipts.values.contains {
            $0.destinationHash == conversation.destinationHash
        }
        let hasResourceInFlight = outgoingResources.values.contains { resource in
            messages.first(where: { $0.id == resource.messageID })?.conversationID == conversationID
        }
        guard let nextMessage = pending.first,
              Self.deliveryPassCanAdvance(
                  hasReceiptInFlight: hasReceiptInFlight,
                  hasResourceInFlight: hasResourceInFlight,
                  nextMessageHasAttachments: !nextMessage.attachments.isEmpty
              ) else { return }
        let attachmentMessages = nextMessage.attachments.isEmpty ? [] : [nextMessage]
        guard let destination = Data(hexadecimal: conversation.destinationHash),
              let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash && $0.isValidated }),
              let publicKey = discovery.publicKey,
              (try? ReticulumIdentity(publicKey: publicKey)) != nil else {
            if !isPathPending(to: conversation.destinationHash) { await requestPath(to: conversation.destinationHash, surfaceErrors: false) }
            return
        }
        if !hasPath(to: conversation.destinationHash) {
            if !isPathPending(to: conversation.destinationHash) {
                await requestPath(to: conversation.destinationHash, surfaceErrors: false)
            }
            // Direct LXMF delivery needs a validated Reticulum route before
            // link negotiation can begin.
            return
        }
        let sourceNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(sourceNameHash + messagingIdentity.hash)
        if Self.shouldUsePropagation(conversation.deliveryPreference),
           activeLinks.values.contains(where: { $0.destinationHash.hex == propagationNodeHash }) {
            await propagateQueued(for: conversationID)
        }
        // Supply the receipt window with consecutive text messages, stopping
        // at the first attachment so no later packet can overtake a resource
        // transfer. Previously this array contained only `nextMessage`, which
        // silently reduced the four-receipt public window back to one.
        let remainingQueued = nextMessage.attachments.isEmpty
            ? Array(pending.prefix { $0.attachments.isEmpty })
            : []
        // Keep a small proof window open on high-latency public routes. A
        // single receipt serialises an entire conversation behind the public
        // round-trip time and can turn a healthy 100-message queue into a
        // multi-hour drain. Four matches the bounded upstream LXMF router
        // window while attachments remain strictly serialised below.
        let maximumInFlightReceipts = 4
        // Match stock LXMF exactly: when no delivery method is explicitly
        // requested, LXMessage selects DIRECT. Opportunistic delivery is an
        // explicit opt-in in upstream LXMF and is not a reliable substitute
        // for a direct link across multi-hop public routes. Keeping automatic
        // messages on the authenticated link also gives every send the same
        // proof and retry semantics as attachments.
        if outboundSession(to: conversation.destinationHash) == nil {
            if !pendingLinkHashes.contains(conversation.destinationHash) { await requestLink(to: conversation.destinationHash) }
            return
        }
        guard let session = outboundSession(to: conversation.destinationHash) else { return }
        let directSlots = max(0, maximumInFlightReceipts - pendingReceipts.values.count { $0.destinationHash == conversation.destinationHash })
        for item in remainingQueued.prefix(directSlots) {
            guard item.attachments.isEmpty else { continue }
            do {
                let deliveryEpoch = deliveryConnectionEpoch
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, timestamp: item.timestamp.timeIntervalSince1970, content: Data(item.body.utf8), fields: lxmfFields(for: item), encodedFields: lxmfEncodedFields(for: item))
                recordLXMFID(lxmf.messageID, for: item.id)
                if lxmf.packed.count > 400 {
                    try await advertiseLXMFResource(lxmf.packed, messageID: item.id, session: session)
                    continue
                }
                let raw = try session.encryptedPacket(lxmf.packed)
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(
                    messageID: item.id,
                    kind: .direct,
                    destinationHash: conversation.destinationHash,
                    linkID: session.linkID.hex
                )
                recordDeliveryAttempt(item.id, mode: .directLink)
                try await transmitLinkPacket(raw, session: session)
                guard deliveryEpoch == deliveryConnectionEpoch else {
                    removePendingReceipts(for: item.id)
                    updateMessage(item.id, state: .queued)
                    deliveryPassRerunRequested.insert(conversationID)
                    continue
                }
                updateMessage(item.id, state: .sent)
                await scheduleReceiptTimeout(packetHash)
            } catch {
                removePendingReceipts(for: item.id)
                await recoverLinkTransmission(
                    messageID: item.id,
                    attachmentID: nil,
                    session: session,
                    error: error
                )
                break
            }
        }
        // Serialize attachment resources per conversation. Reticulum resource
        // receivers intentionally cap concurrent reassemblies; advertising an
        // entire backlog at once causes otherwise-valid transfers to be
        // rejected during reconnect bursts. The next resource is started from
        // receiveResourceProof() after this one is durably accepted.
        if let nextAttachmentMessage = attachmentMessages.first(where: { message in
               message.attachments.contains(where: { $0.state == .local || $0.state == .queued })
           }) {
            await advertiseAttachments(for: nextAttachmentMessage, session: session)
        }
    }

    private func advertiseAttachments(for message: Message, session: ReticulumLinkSession) async {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(nameHash + messagingIdentity.hash)
        guard let attachment = message.attachments.first(where: { $0.state == .local || $0.state == .queued }) else { return }
        let deliveryEpoch = deliveryConnectionEpoch
        do {
            let data = try await attachmentStore.read(attachment)
            guard deliveryEpoch == deliveryConnectionEpoch else { return }
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
            do {
                try await transmitLinkPacket(
                    try session.resourceAdvertisementPacket(first.advertisement),
                    session: session
                )
            } catch {
                outgoingResources.removeValue(forKey: first.manifest.resourceHash.hex)
                await recoverLinkTransmission(
                    messageID: message.id,
                    attachmentID: attachment.id,
                    session: session,
                    error: error
                )
                return
            }
            guard deliveryEpoch == deliveryConnectionEpoch else {
                outgoingResources.removeValue(forKey: first.manifest.resourceHash.hex)
                updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .queued, progress: 0)
                updateMessage(message.id, state: .queued)
                return
            }
        } catch {
            if deliveryEpoch != deliveryConnectionEpoch {
                updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .queued, progress: 0)
                updateMessage(message.id, state: .queued)
                return
            }
            recordDeliveryFailure(message.id, reason: "Attachment transfer could not start.")
            updateAttachment(messageID: message.id, attachmentID: attachment.id, state: .failed, progress: 0)
        }
    }

    /// A link is bound to the interface that returned its proof. Public
    /// Reticulum pools can replace that interface immediately afterwards as a
    /// discovered route supersedes a bootstrap socket. Losing that interface
    /// is a recoverable network transition, not a permanent message failure.
    private func recoverLinkTransmission(
        messageID: UUID,
        attachmentID: UUID?,
        session: ReticulumLinkSession,
        error: Error
    ) async {
        guard let message = messages.first(where: { $0.id == messageID }),
              let conversation = conversations.first(where: { $0.id == message.conversationID })
        else { return }
        deliveryDebugTrace(
            "TX link \(session.linkID.hex) became unavailable for \(conversation.destinationHash): \(error.localizedDescription); retrying"
        )
        let resourceHashes = outgoingResources.compactMap {
            $0.value.messageID == messageID ? $0.key : nil
        }
        for hash in resourceHashes { outgoingResources.removeValue(forKey: hash) }
        removePendingReceipts(for: messageID)
        if let attachmentID {
            updateAttachment(messageID: messageID, attachmentID: attachmentID, state: .queued, progress: 0)
        }
        updateMessage(messageID, state: .queued)
        recordDeliveryFailure(messageID, reason: "Secure route changed; retrying automatically.")
        removeLink(session.linkID.hex)
        await requestLink(to: conversation.destinationHash)
        deliveryPassRerunRequested.insert(conversation.id)
    }

    private func advertiseLXMFResource(_ packed: Data, messageID: UUID, session: ReticulumLinkSession) async throws {
        let deliveryEpoch = deliveryConnectionEpoch
        let segments = try ReticulumResourceSegmentPlanner.prepare(data: packed, session: session, hasMetadata: false)
        guard let first = segments.first else { return }
        registerOutgoingSegment(first, remaining: Array(segments.dropFirst()), messageID: messageID, attachmentID: nil, session: session)
        recordDeliveryAttempt(messageID, mode: .resource)
        updateMessage(messageID, state: .sent)
        try await transmitLinkPacket(
            try session.resourceAdvertisementPacket(first.advertisement),
            session: session
        )
        guard deliveryEpoch == deliveryConnectionEpoch else {
            outgoingResources.removeValue(forKey: first.manifest.resourceHash.hex)
            updateMessage(messageID, state: .queued)
            return
        }
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
                    try await transmitLinkPacket(
                        session.resourcePartPacket(resource.parts[index]),
                        session: session
                    )
                    resource.sentIndices.insert(index)
                    deliveryDebugTrace("TX resource part \(index + 1)/\(resource.parts.count) for \(request.resourceHash.hex) on link \(session.linkID.hex)")
                } catch {
                    deliveryDebugTrace("TX resource part failed for \(request.resourceHash.hex): \(error.localizedDescription)")
                    return
                }
            }
            // Resource requests can take longer than the base inactivity
            // window on constrained links. Refresh activity after each
            // successfully transmitted batch so a progressing transfer is
            // never retired solely because of its total wall-clock duration.
            if var current = outgoingResources[request.resourceHash.hex],
               current.linkID == session.linkID.hex {
                current.sentIndices.formUnion(resource.sentIndices)
                current.timeoutToken = UUID()
                outgoingResources[request.resourceHash.hex] = current
                scheduleResourceTimeout(hash: request.resourceHash.hex, incoming: false)
            }
            if request.wantsMoreHashMap, let last = request.lastKnownMapHash,
               let lastIndex = resource.manifest.partHashes.firstIndex(of: last) {
                let segment = (lastIndex + 1) / ReticulumResourceAdvertisement.hashMapMaximumEntries
                let start = segment * ReticulumResourceAdvertisement.hashMapMaximumEntries
                let end = min(start + ReticulumResourceAdvertisement.hashMapMaximumEntries, resource.manifest.partHashes.count)
                if start < end {
                    let update = try ReticulumResourceHashMapUpdate(resourceHash: resource.manifest.resourceHash, segment: segment, partHashes: Array(resource.manifest.partHashes[start..<end]))
                    try? await transmitLinkPacket(
                        try session.resourceHashMapUpdatePacket(update),
                        session: session
                    )
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
            Task {
                try? await transmitLinkPacket(
                    try session.resourceAdvertisementPacket(next.advertisement),
                    session: session
                )
            }
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
            Task {
                try? await transmitLinkPacket(
                    Data([0x0f, 0x00]) + session.linkID + Data([0x05]) + proof,
                    session: session
                )
            }
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
                  advertisedPartHashCount: advertisement.partHashes.count,
                  sdu: session.resourceSDU
              ),
              !receivedResourceHashes.contains(advertisement.resourceHash.hex),
              let manifest = try? ReticulumResourceManifest(advertisement: advertisement, sdu: session.resourceSDU) else {
            let expectedParts = advertisement.transferSize == 0
                ? 0
                : (advertisement.transferSize + session.resourceSDU - 1) / session.resourceSDU
            deliveryDebugTrace(
                "RX rejected resource advertisement \(advertisement.resourceHash.hex), " +
                "incoming=\(incomingResources.count), flags=\(advertisement.flags), " +
                "data=\(advertisement.dataSize), transfer=\(advertisement.transferSize), " +
                "parts=\(advertisement.partCount)/\(expectedParts), hashes=\(advertisement.partHashes.count), " +
                "segment=\(advertisement.segmentIndex)/\(advertisement.totalSegments), " +
                "alreadyReceived=\(receivedResourceHashes.contains(advertisement.resourceHash.hex))"
            )
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
        Task {
            try? await transmitLinkPacket(
                try incoming.session.resourceRequestPacket(request),
                session: incoming.session
            )
        }
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
              let transferData = try? incoming.session.decryptResourcePayload(encrypted),
              let data = try? (
                  incoming.advertisement.flags & 0x02 == 0x02
                      ? BZip2.decompress(transferData, maximumOutputBytes: incoming.advertisement.dataSize)
                      : transferData
              ),
              incoming.receiver.manifest.validateHash(data: data),
              incoming.advertisement.totalSegments == 1
                  ? data.count == incoming.advertisement.dataSize
                  : (data.count > 0 && data.count <= ReticulumResourceSegmentPlanner.maximumEfficientSize) else {
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
                try await transmitLinkPacket(
                    Data([0x0f, 0x00]) + incoming.session.linkID + Data([0x05]) + proof,
                    session: incoming.session
                )
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
            await requestPath(to: envelope.sourceHash.hex, surfaceErrors: false)
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
        let transferSize = incoming ? incomingResources[hash]?.receiver.manifest.size : outgoingResources[hash]?.manifest.size
        guard let token, let transferSize else { return }
        let timeoutSeconds = Self.resourceInactivityTimeoutSeconds(transferSize: transferSize)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            await self?.expireResource(hash: hash, token: token, incoming: incoming)
        }
    }

    static func resourceInactivityTimeoutSeconds(transferSize: Int) -> TimeInterval {
        // Allow at least three minutes, then scale for an intentionally modest
        // 8 KiB/s path. The cap prevents abandoned transfers from occupying
        // memory forever while still supporting large radio/mesh resources.
        min(1_800, max(180, 60 + Double(max(0, transferSize)) / 8_192))
    }

    private func expireResource(hash: String, token: UUID, incoming: Bool) async {
        if incoming {
            guard let resource = incomingResources[hash], resource.timeoutToken == token else { return }
            incomingResources.removeValue(forKey: hash)
            try? await transmitLinkPacket(
                try resource.session.resourceCancelPacket(
                    resourceHash: resource.receiver.manifest.resourceHash,
                    initiatedBySender: false
                ),
                session: resource.session
            )
        } else {
            guard let resource = outgoingResources[hash], resource.timeoutToken == token else { return }
            outgoingResources.removeValue(forKey: hash)
            let conversationID = messages.first(where: { $0.id == resource.messageID })?.conversationID
            let destinationHash = conversationID.flatMap { id in conversations.first(where: { $0.id == id })?.destinationHash }
            if let attachmentID = resource.attachmentID {
                updateAttachment(messageID: resource.messageID, attachmentID: attachmentID, state: .queued, progress: 0)
                updateMessage(resource.messageID, state: .queued)
            } else { updateMessage(resource.messageID, state: .queued) }
            if let session = activeLinks[resource.linkID] {
                try? await transmitLinkPacket(
                    try session.resourceCancelPacket(
                        resourceHash: resource.manifest.resourceHash,
                        initiatedBySender: true
                    ),
                    session: session
                )
            }
            removeLink(resource.linkID)
            if let destinationHash {
                await requestLink(to: destinationHash)
                if let conversationID { await attemptDelivery(for: conversationID) }
            }
        }
    }

    private func cancelResource(hash: String, initiatedBySender: Bool) {
        if let outgoing = outgoingResources.removeValue(forKey: hash) {
            let reason = initiatedBySender
                ? "Attachment transfer was cancelled."
                : "The recipient declined this attachment. Its receive-size policy may be lower than the file size."
            deliveryDebugTrace("RX resource cancel \(hash), sender initiated: \(initiatedBySender)")
            recordDeliveryFailure(outgoing.messageID, reason: reason)
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
        let proofIsValid: Bool
        if let linkID = receipt.linkID, let session = activeLinks[linkID] {
            proofIsValid = session.validatesProof(packet, packetHash: provedHash)
        } else if let discovery = discoveries.first(where: { $0.destinationHash == receipt.destinationHash }),
                  let publicKey = discovery.publicKey,
                  let identity = try? ReticulumIdentity(publicKey: publicKey) {
            proofIsValid = ReticulumProof.validates(packet, packetHash: provedHash, identity: identity)
        } else {
            proofIsValid = false
        }
        guard proofIsValid else { return }
        pendingReceipts.removeValue(forKey: matched.hash)
        receiptTimeoutTasks.removeValue(forKey: matched.hash)?.cancel()
        updateMessage(receipt.messageID, state: receipt.kind == .propagation ? .sent : .delivered)
        if receipt.kind != .propagation,
           let conversation = conversations.first(where: { $0.destinationHash == receipt.destinationHash }) {
            // Advance the bounded delivery window only after an authenticated
            // proof frees a slot. Successful delivery also resets the
            // per-destination fallback cycle for the next queued message.
            Task { await attemptDelivery(for: conversation.id) }
        }
        if receipt.kind == .propagation {
            propagationUploadsAccepted += 1
            UserDefaults.standard.set(propagationUploadsAccepted, forKey: "lxmfPropagationUploadsAccepted")
        }
    }

    private func scheduleReceiptTimeout(_ packetHash: String) async {
        receiptTimeoutTasks.removeValue(forKey: packetHash)?.cancel()
        guard let receipt = pendingReceipts[packetHash] else { return }
        let hops: UInt8?
        if receipt.kind == .opportunistic,
           let destination = Data(hexadecimal: receipt.destinationHash) {
            hops = await pathTable.path(to: destination)?.hops
        } else {
            hops = nil
        }
        let timeoutSeconds = Self.deliveryProofTimeoutSeconds(hops: hops)
        receiptTimeoutTasks[packetHash] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            await self?.expireReceipt(packetHash)
        }
    }

    static func deliveryProofTimeoutSeconds(hops: UInt8?) -> TimeInterval {
        // Mirror Reticulum PacketReceipt: one first-hop timeout plus one
        // DEFAULT_PER_HOP_TIMEOUT (six seconds) for every routed hop. Keep the
        // existing 30-second floor for normal Internet jitter and cap stale
        // routes so the durable outbox always makes progress.
        min(180, max(30, 6 + (Double(hops ?? 0) * 6)))
    }

    static func deliveryPassCanAdvance(
        hasReceiptInFlight: Bool,
        hasResourceInFlight: Bool,
        nextMessageHasAttachments: Bool
    ) -> Bool {
        // Text receipts use a sliding bounded window. An attachment at the
        // head of the queue waits for every earlier text proof, and no new
        // delivery may start while a resource is already transferring.
        !hasResourceInFlight && !(hasReceiptInFlight && nextMessageHasAttachments)
    }

    static func deliveryTrackingIsStale(lastAttemptAt: Date?, now: Date = .now) -> Bool {
        guard let lastAttemptAt else { return true }
        // Receipt timers are capped at 180 seconds. Allow one additional
        // maintenance interval before treating an in-memory receipt as
        // orphaned after suspension, clock churn or an interface transition.
        return now.timeIntervalSince(lastAttemptAt) >= 240
    }

    @discardableResult
    func recoverStaleSentMessages(now: Date = .now) -> Set<UUID> {
        var conversationsToRetry: Set<UUID> = []
        let activeResourceMessageIDs = Set(outgoingResources.values.map(\.messageID))
        let staleMessageIDs = messages.compactMap { message -> UUID? in
            guard message.direction == .outgoing,
                  message.state == .sent,
                  ownsOutbox(message),
                  !activeResourceMessageIDs.contains(message.id),
                  Self.deliveryTrackingIsStale(lastAttemptAt: message.lastDeliveryAttemptAt, now: now) else {
                return nil
            }
            return message.id
        }
        guard !staleMessageIDs.isEmpty else { return [] }
        for messageID in staleMessageIDs {
            removePendingReceipts(for: messageID)
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { continue }
            messages[index].state = .queued
            messages[index].lastDeliveryFailure = "Delivery tracking expired; retrying automatically."
            conversationsToRetry.insert(messages[index].conversationID)
        }
        save()
        return conversationsToRetry
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
            // Stock LXMF keeps an ordinary message opportunistic throughout
            // its retry lifecycle. Rediscover the path and try the durable
            // outbox again without coupling this message to another message's
            // attempts or forcing the entire peer onto link delivery.
            // Refresh this client's route before asking the network for the
            // peer again. This is essential after roaming or reconnecting
            // through a different gateway interface.
            if lastDeliveryAnnounceAt.map({ Date.now.timeIntervalSince($0) >= 5 }) ?? true {
                await announceLocalDeliveryDestination()
            }
            if let destination = Data(hexadecimal: destinationHash) {
                await pathTable.invalidate(destination)
                await refreshPathState()
            }
            pendingPathHashes.remove(destinationHash)
            await requestPath(to: destinationHash, surfaceErrors: false)
            if activeLinkHashes.contains(destinationHash),
               let conversation = conversations.first(where: { $0.destinationHash == destinationHash }) {
                // An attachment or an explicit link request may have activated
                // the secure session while the opportunistic receipts were
                // still waiting. In that case deferLinkRequest() is correctly
                // a no-op, but the newly requeued messages still need an
                // immediate delivery pass over the already-active link.
                await attemptDelivery(for: conversation.id)
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
            await requestPath(to: destinationHash, surfaceErrors: false)
            await requestLink(to: destinationHash)
            deferLinkRequest(to: destinationHash)
            if conversation.deliveryPreference == .propagationPreferred {
                await propagateQueued(for: conversation.id)
            }
        }
    }

    private func propagateQueued(for conversationID: UUID) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              Self.shouldUsePropagation(conversation.deliveryPreference),
              let destination = Data(hexadecimal: conversation.destinationHash),
              let discovery = discoveries.first(where: { $0.destinationHash == conversation.destinationHash }),
              let publicKey = discovery.publicKey,
              let recipient = try? ReticulumIdentity(publicKey: publicKey),
              let propagationSession = activeLinks.values.first(where: { $0.destinationHash.hex == propagationNodeHash }) else { return }
        let sourceNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        let sourceHash = ReticulumIdentity.truncatedHash(sourceNameHash + messagingIdentity.hash)
        for item in messages.filter({ $0.conversationID == conversationID && $0.direction == .outgoing && $0.state == .queued && ($0.scheduledFor ?? .distantPast) <= .now && $0.attachments.isEmpty && ownsOutbox($0) }) {
            do {
                let deliveryEpoch = deliveryConnectionEpoch
                let lxmf = try LXMFMessage(destinationHash: destination, sourceHash: sourceHash, sourceIdentity: messagingIdentity, timestamp: item.timestamp.timeIntervalSince1970, content: Data(item.body.utf8), fields: lxmfFields(for: item), encodedFields: lxmfEncodedFields(for: item))
                recordLXMFID(lxmf.messageID, for: item.id)
                let envelope = try lxmf.propagatedEnvelope(recipientIdentity: recipient, ratchet: discovery.ratchet)
                let raw = try propagationSession.encryptedPacket(envelope)
                let packetHash = try ReticulumPacket(raw: raw).packetHash.hex
                pendingReceipts[packetHash] = PendingReceipt(
                    messageID: item.id,
                    kind: .propagation,
                    destinationHash: propagationNodeHash,
                    linkID: propagationSession.linkID.hex
                )
                recordDeliveryAttempt(item.id, mode: .propagation)
                try await transmitLinkPacket(raw, session: propagationSession)
                guard deliveryEpoch == deliveryConnectionEpoch else {
                    removePendingReceipts(for: item.id)
                    updateMessage(item.id, state: .queued)
                    continue
                }
                updateMessage(item.id, state: .sent)
                await scheduleReceiptTimeout(packetHash)
            } catch {
                removePendingReceipts(for: item.id)
                recordDeliveryFailure(item.id, reason: "Propagation-node upload failed.")
                // Propagation is a background fallback. A transient interface
                // race must remain in delivery diagnostics instead of
                // interrupting the user with a modal alert.
            }
        }
    }

    static func shouldUsePropagation(_ preference: Conversation.DeliveryPreference) -> Bool {
        preference == .propagationPreferred
    }

    private func refreshPathState() async {
        let paths = await pathTable.all()
        let currentPaths = Set(paths.map { $0.destinationHash.hex })
        if currentPaths != knownPathHashes { knownPathHashes = currentPaths }
        var preferredPaths: [String: ReticulumPath] = [:]
        for path in paths {
            let hash = path.destinationHash.hex
            guard let current = preferredPaths[hash] else {
                preferredPaths[hash] = path
                continue
            }
            if path.hops < current.hops || (path.hops == current.hops && path.updatedAt > current.updatedAt) {
                preferredPaths[hash] = path
            }
        }
        let routes = preferredPaths.mapValues { path in
            let interfaceID = path.interfaceID
            let tcpInterface = interfaceID.flatMap { id in networkInterfaces.first(where: { $0.id == id }) }
            let rnodeInterface = interfaceID.flatMap { id in
                rnodeManager.snapshots.first(where: { "rnode:\($0.id.uuidString)" == id })
            }
            let interfaceName: String
            if let tcpInterface {
                interfaceName = tcpInterface.name
            } else if interfaceID == "auto" {
                interfaceName = "AutoInterface"
            } else if let rnodeInterface {
                interfaceName = rnodeInterface.name
            } else {
                interfaceName = "Reticulum"
            }
            let endpoint = tcpInterface.flatMap { snapshot -> String? in
                guard let host = snapshot.host else { return nil }
                return snapshot.port.map { "\(host):\($0)" } ?? host
            }
            return ConnectedRoute(
                interfaceName: interfaceName,
                endpoint: endpoint,
                interfaceID: interfaceID,
                nextHopHash: path.nextHop?.hex,
                hops: path.hops,
                updatedAt: path.updatedAt
            )
        }
        if routes != connectedRoutes { connectedRoutes = routes }
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

    private func handleIncomingCommands(_ commands: [LXMFCommand], conversationID: UUID, messageTimestamp: Date) async {
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
                let activeRoute: ReticulumPath?
                if let destination = Data(hexadecimal: conversation.destinationHash) {
                    activeRoute = await pathTable.path(to: destination)
                } else {
                    activeRoute = nil
                }
                var telemetrySummary: [String: String] = [:]
                if let latest = messages.lazy
                    .filter({ $0.conversationID == conversationID && $0.telemetry != nil })
                    .sorted(by: { $0.timestamp > $1.timestamp })
                    .first?.telemetry {
                    telemetrySummary["sensors"] = latest.sensorKinds.map(\.displayName).joined(separator: ", ")
                    telemetrySummary["captured"] = ISO8601DateFormatter().string(from: latest.capturedAt)
                    if let battery = latest.battery {
                        telemetrySummary["battery"] = "\(Int(battery.chargePercent.rounded()))%"
                    }
                }
                let context = SidebandPluginContext(
                    command: command,
                    arguments: arguments,
                    senderDestinationHash: conversation.destinationHash,
                    networkReady: networkState == .ready,
                    routeAvailable: hasPath(to: conversation.destinationHash),
                    routeHopCount: activeRoute?.hops,
                    routeInterface: activeRoute?.interfaceID,
                    conversationDisplayName: conversation.displayName,
                    messageDirection: .incoming,
                    messageTimestamp: messageTimestamp,
                    telemetrySummary: telemetrySummary
                )
                let execution = await pluginRegistry.execute(command: command, arguments: arguments, context: context)
                recordPluginAudit(command: command, conversationID: conversationID, pluginIdentifier: execution.pluginIdentifier, outcome: execution.outcome)
                guard let pluginResponse = execution.response else { continue }
                response = pluginResponse.renderedText
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
