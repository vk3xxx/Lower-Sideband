import SwiftUI
import SidebandCore
import CryptoKit
@preconcurrency import UserNotifications
#if os(iOS)
import UIKit
@preconcurrency import CallKit
@preconcurrency import AVFoundation
#endif

@main
struct SidebandApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = SidebandStore()
#if os(iOS)
    @UIApplicationDelegateAdaptor(SidebandAppDelegate.self) private var appDelegate
#endif

    init() {
        NotificationInteractionBridge.shared.activate()
    }

    @SceneBuilder
    var body: some Scene {
        #if os(macOS)
        WindowGroup("Lower Sideband") {
            protectedContent
                .frame(minWidth: 1_020, minHeight: 640)
                .task {
                    NotificationInteractionBridge.shared.install(store: store)
                    await startRootSoakIfRequested()
                    await store.notifications.prepare()
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        Window("Reticulum Network Map", id: "network-map") {
            NetworkMapView(store: store)
        }
        .defaultSize(width: 1_280, height: 820)
        .windowResizability(.contentMinSize)
        Settings {
            SidebandSettingsView(store: store, showsCloseButton: false)
                .frame(minWidth: 900, minHeight: 640)
        }
        #else
        WindowGroup("Lower Sideband") {
            protectedContent
                .task {
                    NotificationInteractionBridge.shared.install(store: store)
                    await startRootSoakIfRequested()
                    await store.notifications.prepare()
                    RemoteWakeBridge.shared.install(
                        wake: { [store] in await store.performRemoteWakeSync() },
                        memoryPressure: { [store] in store.handleMemoryPressure() },
                        deviceToken: { [store] token in await store.updateRemoteWakeDeviceToken(token) },
                        registrationFailure: { [store] message in store.remoteWakeRegistrationFailed(message) }
                    )
                    UIApplication.shared.registerForRemoteNotifications()
                }
        }
        #endif
    }

    @ViewBuilder private var protectedContent: some View {
        Group {
            if store.privacyLock.isUnlocked { ContentView(store: store) }
            else { PrivacyLockView(lock: store.privacyLock) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.privacyLock.lock() }
        }
    }

    /// Acceptance runs must not depend on the conversation view appearing.
    /// Privacy locking and scene restoration can legitimately keep that view
    /// out of the hierarchy while the network engine is otherwise available.
    @MainActor private func startRootSoakIfRequested() async {
        guard ProcessInfo.processInfo.environment["SIDEBAND_SOAK_DESTINATION"] != nil else { return }
        let environment = ProcessInfo.processInfo.environment
        let currentPrefixes = Set([
            environment["SIDEBAND_SOAK_OUTBOUND_PREFIX"],
            environment["SIDEBAND_SOAK_INBOUND_PREFIX"]
        ].compactMap { $0 })
        _ = await store.purgeDeliverySoakMessages(keepingPrefixes: currentPrefixes)
        DeliverySoakRunner.configureNetworkIfRequested(store)
        await store.startTransport()
        _ = await DeliverySoakRunner.startNetworkIfRequested(store)
        await DeliverySoakRunner.runIfRequested(store)
    }
}

private struct PrivacyLockView: View {
    @Bindable var lock: AppPrivacyLock

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Lower Sideband Locked").font(.title.bold())
            Text("Authenticate with your device passcode or biometrics to view encrypted conversations.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button {
                Task { await lock.unlock() }
            } label: {
                if lock.isAuthenticating { ProgressView().controlSize(.small) }
                else { Label("Unlock Lower Sideband", systemImage: "lock.open") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(lock.isAuthenticating)
            .keyboardShortcut(.defaultAction)
            if let error = lock.lastError { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
        }
        .padding(32)
        .task { await lock.unlock() }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private final class NotificationInteractionBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationInteractionBridge()
    private weak var store: SidebandStore?
    private var pendingResponse: (conversationID: UUID, markReadOnly: Bool, reply: String?)?

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func install(store: SidebandStore) {
        self.store = store
        activate()
        if let pendingResponse {
            route(pendingResponse.conversationID, markReadOnly: pendingResponse.markReadOnly, reply: pendingResponse.reply)
            self.pendingResponse = nil
        }
    }

    private func route(_ conversationID: UUID, markReadOnly: Bool, reply: String? = nil) {
        guard let store else {
            pendingResponse = (conversationID, markReadOnly, reply)
            return
        }
        if let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            Task { await store.send(reply, to: conversationID) }
            return
        }
        if markReadOnly {
            store.markConversationRead(conversationID)
        } else {
            store.openConversationFromNotification(conversationID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let value = response.notification.request.content.userInfo[LocalNotificationManager.conversationIDUserInfoKey] as? String
        let conversationID = value.flatMap(UUID.init(uuidString:))
        completionHandler()
        Task { @MainActor [weak self] in
            if let conversationID {
                self?.route(
                    conversationID,
                    markReadOnly: response.actionIdentifier == LocalNotificationManager.markReadActionIdentifier,
                    reply: (response as? UNTextInputNotificationResponse)?.userText
                )
            }
        }
    }
}

#if os(iOS)
@MainActor
final class CallKitCoordinator: NSObject, CXProviderDelegate {
    static let shared = CallKitCoordinator()

    private let provider: CXProvider
    private let callController = CXCallController()
    private weak var store: SidebandStore?
    private var reportedCallID: UUID?
    private var reportedState: VoiceCallState?
    let audioEngine = LiveVoiceAudioEngine()
    private var isStartingAudio = false
    private(set) var isAudioSessionActive = false

    override private init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        // Keep encrypted-call metadata out of the system-wide Recents database.
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    var hasManagedCall: Bool { reportedCallID != nil }

    func install(store: SidebandStore) {
        self.store = store
        audioEngine.onEncodedFrame = { [weak store] payload in
            Task { await store?.sendVoiceFrame(payload) }
        }
        store.setVoiceFrameHandler { [weak audioEngine] codec, payload in
            audioEngine?.play(payload, codec: codec)
        }
    }

    func synchronize(call: VoiceCall?, displayName: String?) {
        guard let call else {
            if let id = reportedCallID {
                let reason: CXCallEndedReason = reportedState == .active ? .remoteEnded : .failed
                provider.reportCall(with: id, endedAt: .now, reason: reason)
            }
            audioEngine.stop()
            clearReportedCall()
            return
        }

        if reportedCallID != call.id {
            if let previous = reportedCallID {
                provider.reportCall(with: previous, endedAt: .now, reason: .failed)
            }
            reportedCallID = call.id
            reportedState = call.state
            let handle = CXHandle(type: .generic, value: displayName ?? "Lower Sideband contact")
            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = displayName
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            update.hasVideo = false
            if call.direction == .incoming {
                provider.reportNewIncomingCall(with: call.id, update: update) { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in
                        await self?.store?.declineVoiceCall()
                        self?.clearReportedCall()
                    }
                }
            } else {
                request(CXTransaction(action: CXStartCallAction(call: call.id, handle: handle)))
                provider.reportOutgoingCall(with: call.id, startedConnectingAt: call.startedAt)
            }
        }

        if call.direction == .outgoing, call.state == .active, reportedState != .active {
            provider.reportOutgoingCall(with: call.id, connectedAt: call.connectedAt ?? .now)
        }
        reportedState = call.state
        if call.state == .active { startAudioIfNeeded() }
    }

    func requestAnswer() {
        guard let id = reportedCallID else { return }
        request(CXTransaction(action: CXAnswerCallAction(call: id)))
    }

    func requestEnd() {
        guard let id = reportedCallID else {
            Task { await store?.hangUpVoiceCall() }
            return
        }
        request(CXTransaction(action: CXEndCallAction(call: id)))
    }

    func requestMuted(_ muted: Bool) {
        guard let id = reportedCallID else { audioEngine.isMuted = muted; return }
        request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted)))
    }

    func waitForAudioActivation() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !isAudioSessionActive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func request(_ transaction: CXTransaction) {
        callController.request(transaction) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.store?.lastError = "System call action failed: \(error.localizedDescription)"
            }
        }
    }

    private func clearReportedCall() {
        audioEngine.stop()
        reportedCallID = nil
        reportedState = nil
        isAudioSessionActive = false
        isStartingAudio = false
        audioEngine.isMuted = false
    }

    private func startAudioIfNeeded() {
        guard store?.voiceCall?.state == .active, !audioEngine.isRunning, !isStartingAudio else { return }
        isStartingAudio = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isStartingAudio = false }
            do {
                try audioEngine.configure(profile: store?.voiceCall?.profile ?? .mediumQuality)
                try await audioEngine.start()
            }
            catch {
                store?.lastError = error.localizedDescription
                await store?.hangUpVoiceCall()
            }
        }
    }

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            await self?.store?.hangUpVoiceCall()
            self?.clearReportedCall()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            await store?.answerVoiceCall()
            if store?.voiceCall?.state == .active { action.fulfill() } else { action.fail() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            if store?.voiceCall?.direction == .incoming, store?.voiceCall?.state == .incoming {
                await store?.declineVoiceCall()
            } else {
                await store?.hangUpVoiceCall()
            }
            action.fulfill()
            clearReportedCall()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            self?.audioEngine.isMuted = action.isMuted
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.isAudioSessionActive = true
            self?.startAudioIfNeeded()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.isAudioSessionActive = false
            self?.audioEngine.stop()
        }
    }
}

@MainActor
private final class RemoteWakeBridge {
    static let shared = RemoteWakeBridge()
    private var handler: (@MainActor () async -> Bool)?
    private var memoryPressureHandler: (@MainActor () -> Void)?
    private var deviceTokenHandler: (@MainActor (String) async -> Void)?
    private var registrationFailureHandler: (@MainActor (String) -> Void)?
    private var hasDeferredWake = false
    private var pendingDeviceToken: String?
    private var pendingRegistrationFailure: String?

    func install(
        wake handler: @escaping @MainActor () async -> Bool,
        memoryPressure: @escaping @MainActor () -> Void,
        deviceToken: @escaping @MainActor (String) async -> Void,
        registrationFailure: @escaping @MainActor (String) -> Void
    ) {
        self.handler = handler
        memoryPressureHandler = memoryPressure
        deviceTokenHandler = deviceToken
        registrationFailureHandler = registrationFailure
        if hasDeferredWake {
            hasDeferredWake = false
            Task { _ = await handler() }
        }
        if let pendingDeviceToken {
            self.pendingDeviceToken = nil
            Task { await deviceToken(pendingDeviceToken) }
        }
        if let pendingRegistrationFailure {
            self.pendingRegistrationFailure = nil
            registrationFailure(pendingRegistrationFailure)
        }
    }
    func perform() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while handler == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let handler else {
            hasDeferredWake = true
            return false
        }
        return await handler()
    }
    func handleMemoryPressure() { memoryPressureHandler?() }
    func receivedDeviceToken(_ token: String) {
        pendingDeviceToken = token
        guard let deviceTokenHandler else { return }
        pendingDeviceToken = nil
        Task { await deviceTokenHandler(token) }
    }
    func registrationFailed(_ message: String) {
        pendingRegistrationFailure = message
        guard let registrationFailureHandler else { return }
        pendingRegistrationFailure = nil
        registrationFailureHandler(message)
    }
}

@MainActor
final class SidebandAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemoteWakeBridge.shared.receivedDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemoteWakeBridge.shared.registrationFailed(error.localizedDescription)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        RemoteWakeBridge.shared.handleMemoryPressure()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let aps = userInfo["aps"] as? [String: Any],
              (aps["content-available"] as? NSNumber)?.intValue == 1 else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let success = await RemoteWakeBridge.shared.perform()
            // A cold-launch wake can be safely deferred until SwiftUI installs
            // the store bridge. Reporting `.failed` would unnecessarily train
            // iOS to reduce future background delivery opportunities.
            completionHandler(success ? .newData : .noData)
        }
    }
}
#endif

@MainActor
enum DeliverySoakRunner {
    private static let environment = ProcessInfo.processInfo.environment
    private static let networkPreferenceKeys = [
        "reticulumAutoConnect", "reticulumInternetOnly", "reticulumHost",
        "reticulumIPv6Host", "reticulumInternetHost", "reticulumInternetPort",
        "reticulumPort", "reticulumPreferIPv6", "reticulumConnectionMode",
        "reticulumTransportInstanceEnabled"
    ]
    private static var savedNetworkPreferences: [String: Any] = [:]
    private static var missingNetworkPreferences: Set<String> = []
    private static var hasConfiguredNetwork = false
    private static var hasStartedNetwork = false
    private static var hasStarted = false
    private static var deliveryTimeoutBaseline = 0

    static func configureNetworkIfRequested(_ store: SidebandStore) {
        guard let mode = environment["SIDEBAND_SOAK_NETWORK_MODE"] else { return }
        guard !hasConfiguredNetwork else { return }
        hasConfiguredNetwork = true
        for key in networkPreferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedNetworkPreferences[key] = value }
            else { missingNetworkPreferences.insert(key) }
        }
        deliveryTimeoutBaseline = store.deliveryTimeoutCount
        // Acceptance runs exercise this app as an endpoint. Never inherit the
        // operator-only transport-router switch, since bridging several public
        // gateways changes the topology under test and can feed unrelated
        // network traffic back through the client.
        store.setTransportInstanceEnabled(false)
        store.autoConnectEnabled = mode == "automatic" || mode == "internet" || environment["SIDEBAND_SOAK_AUTOCONNECT"] == "1"
        store.internetOnlyEnabled = mode == "public" || mode == "internet"
        store.preferIPv6 = true
        store.networkPort = Int(environment["SIDEBAND_SOAK_PORT"] ?? "4242") ?? 4_242
        store.networkInternetPort = Int(environment["SIDEBAND_SOAK_INTERNET_PORT"] ?? "4242") ?? 4_242
        switch mode {
        case "local":
            store.networkHost = environment["SIDEBAND_SOAK_HOST"] ?? "10.20.20.133"
            store.networkIPv6Host = environment["SIDEBAND_SOAK_IPV6_HOST"] ?? ""
            store.networkInternetHost = ""
        case "public":
            store.networkHost = ""
            store.networkIPv6Host = ""
            store.networkInternetHost = environment["SIDEBAND_SOAK_INTERNET_HOST"] ?? "sydney.reticulum.au"
        case "automatic", "internet":
            store.networkHost = ""
            store.networkIPv6Host = ""
            store.networkInternetHost = ""
        default:
            break
        }
    }

    static func startNetworkIfRequested(_ store: SidebandStore) async -> Bool {
        guard let mode = environment["SIDEBAND_SOAK_NETWORK_MODE"] else { return false }
        guard !hasStartedNetwork else { return true }
        hasStartedNetwork = true
        // Scene restoration can start the normal automatic connector before
        // this DEBUG-only acceptance runner is invoked on macOS. Reset that
        // in-flight attempt so the requested test topology is deterministic.
        await store.disconnectNetwork()
        return await connect(store, mode: mode)
    }

    private static func connect(_ store: SidebandStore, mode: String) async -> Bool {
        switch mode {
        case "local":
            await store.connectNetwork(
                explicitHost: environment["SIDEBAND_SOAK_HOST"] ?? "10.20.20.133",
                explicitPort: UInt16(environment["SIDEBAND_SOAK_PORT"] ?? "4242") ?? 4_242
            )
        case "public":
            let host = environment["SIDEBAND_SOAK_INTERNET_HOST"] ?? "sydney.reticulum.au"
            let port = UInt16(environment["SIDEBAND_SOAK_INTERNET_PORT"] ?? "4242") ?? 4_242
            await store.connectNetwork(explicitHost: host, explicitPort: port, internetGatewayID: "\(host.lowercased()):\(port)")
        case "automatic", "internet":
            await store.startAutomaticConnection()
        default:
            return false
        }
        return true
    }

    static func runIfRequested(_ store: SidebandStore) async {
        guard !hasStarted else { return }
        guard
            let destination = environment["SIDEBAND_SOAK_DESTINATION"],
            let outboundPrefix = environment["SIDEBAND_SOAK_OUTBOUND_PREFIX"],
            let inboundPrefix = environment["SIDEBAND_SOAK_INBOUND_PREFIX"],
            let count = Int(environment["SIDEBAND_SOAK_COUNT"] ?? ""), count > 0,
            let reportName = environment["SIDEBAND_SOAK_REPORT"]
        else { return }
        hasStarted = true
        defer { restoreNetworkPreferences() }

        let reportURL = environment["SIDEBAND_SOAK_REPORT_PATH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "SidebandSwift", directoryHint: .isDirectory)
                .appending(path: reportName)
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let startedAt = Date()
        var networkReadyDeadline = ContinuousClock.now + .seconds(90)
        while store.networkState != .ready, ContinuousClock.now < networkReadyDeadline {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "waiting-for-network")
            try? await Task.sleep(for: .seconds(1))
        }

        guard store.networkState == .ready else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "network-timeout")
            return
        }

        if let releaseText = environment["SIDEBAND_SOAK_RELEASE_UTC"],
           !releaseText.isEmpty,
           let releaseDate = ISO8601DateFormatter().date(from: releaseText) {
            while Date() < releaseDate {
                await writeReport(
                    store: store,
                    destination: destination,
                    outboundPrefix: outboundPrefix,
                    inboundPrefix: inboundPrefix,
                    count: count,
                    startedAt: startedAt,
                    reportURL: reportURL,
                    phase: "waiting-for-release"
                )
                let remaining = max(0.05, min(1, releaseDate.timeIntervalSinceNow))
                try? await Task.sleep(for: .seconds(remaining))
            }
        }

        guard store.addConversation(destinationHash: destination, displayName: "Delivery soak", select: false) else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "invalid-destination")
            return
        }
        guard let conversationID = store.conversations.first(where: {
            $0.destinationHash == destination.lowercased()
        })?.id else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "missing-conversation")
            return
        }

        // Do not turn a start-up announce race into thousands of queued
        // messages. Both a current path and the recipient identity are needed
        // for authenticated LXMF encryption.
        let peerTimeout = max(
            30,
            Int(environment["SIDEBAND_SOAK_PEER_TIMEOUT_SECONDS"] ?? "")
                ?? ((environment["SIDEBAND_SOAK_NETWORK_MODE"] == "internet") ? 900 : 120)
        )
        guard await waitForPeer(store, destination: destination, timeout: peerTimeout) else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "peer-discovery-timeout")
            return
        }

        let jitterMinimum = max(0, Int(environment["SIDEBAND_SOAK_JITTER_MIN_MS"] ?? "5") ?? 5)
        let jitterMaximum = max(jitterMinimum, Int(environment["SIDEBAND_SOAK_JITTER_MAX_MS"] ?? "45") ?? 45)
        let attachmentInterval = max(0, Int(environment["SIDEBAND_SOAK_ATTACHMENT_INTERVAL"] ?? "0") ?? 0)
        let attachmentBytes = min(
            ReticulumResourceLimits.maximumAttachmentBytes,
            max(1, Int(environment["SIDEBAND_SOAK_ATTACHMENT_BYTES"] ?? "1048576") ?? 1_048_576)
        )
        let reconnectInterval = max(0, Int(environment["SIDEBAND_SOAK_RECONNECT_INTERVAL"] ?? "0") ?? 0)
        var randomState = UInt64(environment["SIDEBAND_SOAK_SEED"] ?? "") ?? 0x5B1D_BA5E_CAFE_F00D
        let existingBodies = Set(store.messages.map(\.body))
        for sequence in 1...count {
            let body = messageBody(prefix: outboundPrefix, sequence: sequence)
            if !existingBodies.contains(body) {
                var attachments: [Attachment] = []
                if attachmentInterval > 0, sequence.isMultiple(of: attachmentInterval) {
                    let attachmentOrdinal = sequence / attachmentInterval
                    let isImage = attachmentOrdinal.isMultiple(of: 2)
                    let payload = isImage
                        ? imagePayload(prefix: outboundPrefix, sequence: sequence, size: attachmentBytes)
                        : attachmentPayload(prefix: outboundPrefix, sequence: sequence, size: attachmentBytes)
                    if var attachment = try? await store.attachmentStore.save(
                        data: payload,
                        filename: "soak-\(sequence).\(isImage ? "bmp" : "bin")",
                        mimeType: isImage ? "image/bmp" : "application/octet-stream"
                    ) {
                        attachment.state = .local
                        attachment.progress = 0
                        attachments = [attachment]
                    }
                }
                _ = await store.send(body, to: conversationID, attachments: attachments)
            }
            if sequence.isMultiple(of: 25) {
                await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "enqueueing-\(sequence)-of-\(count)")
            }
            if reconnectInterval > 0, sequence < count, sequence.isMultiple(of: reconnectInterval) {
                await store.disconnectNetwork()
                _ = await connect(store, mode: environment["SIDEBAND_SOAK_NETWORK_MODE"] ?? "local")
                guard await waitForPeer(store, destination: destination, timeout: peerTimeout) else {
                    await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "reconnect-peer-timeout")
                    return
                }
            }
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let delayRange = UInt64(jitterMaximum - jitterMinimum + 1)
            let delay = jitterMinimum + Int(randomState % delayRange)
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
        }

        let deliveryDeadlineSeconds = max(30, Int(environment["SIDEBAND_SOAK_DEADLINE_SECONDS"] ?? "600") ?? 600)
        networkReadyDeadline = ContinuousClock.now + .seconds(deliveryDeadlineSeconds)
        while ContinuousClock.now < networkReadyDeadline {
            let report = await makeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, phase: "running")
            write(report, to: reportURL)
            if report.outboundDelivered == count,
               report.inboundReceived == count,
               report.outboundQueued == 0,
               report.outboundFailed == 0,
               report.missingOutbound.isEmpty,
               report.missingInbound.isEmpty,
               report.duplicateInbound.isEmpty,
               report.inboundInOrder,
               report.attachmentIntegrityFailures.isEmpty,
               report.inboundAttachmentsVerified == report.expectedAttachmentsEachDirection {
                var complete = report
                complete.phase = "complete"
                complete.completedAt = .now
                write(complete, to: reportURL)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "delivery-timeout")
    }

    private static func writeReport(store: SidebandStore, destination: String, outboundPrefix: String, inboundPrefix: String, count: Int, startedAt: Date, reportURL: URL, phase: String) async {
        write(await makeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, phase: phase), to: reportURL)
    }

    private static func makeReport(store: SidebandStore, destination: String, outboundPrefix: String, inboundPrefix: String, count: Int, startedAt: Date, phase: String) async -> DeliverySoakReport {
        let conversationID = store.conversations.first(where: { $0.destinationHash == destination.lowercased() })?.id
        let relevant = store.messages.filter { $0.conversationID == conversationID }
        let outbound = relevant.filter { $0.direction == .outgoing && $0.body.hasPrefix(outboundPrefix + "-") }
        let inbound = relevant.filter { $0.direction == .incoming && $0.body.hasPrefix(inboundPrefix + "-") }
        let outboundBodies = Set(outbound.map(\.body))
        let inboundBodies = inbound.map(\.body)
        let inboundBodySet = Set(inboundBodies)
        let expectedOutbound = (1...count).map { messageBody(prefix: outboundPrefix, sequence: $0) }
        let expectedInbound = (1...count).map { messageBody(prefix: inboundPrefix, sequence: $0) }
        let duplicateInbound = Dictionary(grouping: inboundBodies, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        let receivedInOrder = inbound.sorted(by: { $0.timestamp < $1.timestamp }).map(\.body)
        let attachmentInterval = max(0, Int(environment["SIDEBAND_SOAK_ATTACHMENT_INTERVAL"] ?? "0") ?? 0)
        let expectedAttachmentSequences = attachmentInterval > 0
            ? Array(stride(from: attachmentInterval, through: count, by: attachmentInterval))
            : []
        var inboundAttachmentsVerified = 0
        var attachmentIntegrityFailures: [String] = []
        for sequence in expectedAttachmentSequences {
            let body = messageBody(prefix: inboundPrefix, sequence: sequence)
            // A progress report must not classify a future attachment as
            // corrupt simply because its message has not arrived yet. Missing
            // messages are already represented by `missingInbound`; attachment
            // integrity becomes evaluable only after the envelope is present.
            guard let message = inbound.first(where: { $0.body == body }) else { continue }
            guard message.attachments.count == 1 else {
                attachmentIntegrityFailures.append("\(body): missing attachment metadata")
                continue
            }
            let attachmentBytes = min(
                ReticulumResourceLimits.maximumAttachmentBytes,
                max(1, Int(environment["SIDEBAND_SOAK_ATTACHMENT_BYTES"] ?? "1048576") ?? 1_048_576)
            )
            let attachmentOrdinal = sequence / attachmentInterval
            let attachmentPayloadPrefix = environment["SIDEBAND_SOAK_ATTACHMENTS_ARE_ECHOED"] == "1"
                ? outboundPrefix
                : inboundPrefix
            let expected = attachmentOrdinal.isMultiple(of: 2)
                ? imagePayload(prefix: attachmentPayloadPrefix, sequence: sequence, size: attachmentBytes)
                : attachmentPayload(prefix: attachmentPayloadPrefix, sequence: sequence, size: attachmentBytes)
            guard let received = try? await store.attachmentStore.read(message.attachments[0]),
                  received == expected,
                  message.attachments[0].contentHash == Data(SHA256.hash(data: expected)) else {
                attachmentIntegrityFailures.append("\(body): content or SHA-256 mismatch")
                continue
            }
            inboundAttachmentsVerified += 1
        }
        return DeliverySoakReport(
            phase: phase,
            networkMode: environment["SIDEBAND_SOAK_NETWORK_MODE"] ?? "unchanged",
            networkState: String(describing: store.networkState),
            automaticConnection: store.automaticConnectionDescription,
            localDestination: store.localDeliveryHash,
            destination: destination,
            startedAt: startedAt,
            completedAt: nil,
            expectedEachDirection: count,
            outboundQueued: outbound.count(where: { $0.state == .queued }),
            outboundSent: outbound.count(where: { $0.state == .sent }),
            outboundDelivered: outbound.count(where: { $0.state == .delivered }),
            outboundFailed: outbound.count(where: { $0.state == .failed }),
            inboundReceived: inbound.count,
            missingOutbound: expectedOutbound.filter { !outboundBodies.contains($0) },
            missingInbound: expectedInbound.filter { !inboundBodySet.contains($0) },
            duplicateInbound: duplicateInbound,
            inboundInOrder: receivedInOrder == expectedInbound,
            expectedAttachmentsEachDirection: expectedAttachmentSequences.count,
            inboundAttachmentsVerified: inboundAttachmentsVerified,
            attachmentIntegrityFailures: attachmentIntegrityFailures,
            knownPath: store.hasPath(to: destination),
            deliveryTimeouts: max(0, store.deliveryTimeoutCount - deliveryTimeoutBaseline),
            lastError: store.lastError
        )
    }

    private static func messageBody(prefix: String, sequence: Int) -> String {
        "\(prefix)-\(String(format: "%03d", sequence))"
    }

    private static func attachmentPayload(prefix: String, sequence: Int, size: Int) -> Data {
        let seed = Data(SHA256.hash(data: Data("\(prefix):\(sequence)".utf8)))
        return Data((0..<size).map { index in seed[index % seed.count] ^ UInt8(truncatingIfNeeded: index &+ sequence) })
    }

    /// A valid 24-bit BMP padded to the requested byte count. The deterministic
    /// pixels and exact length let a remote soak peer verify both image decoding
    /// and byte-for-byte attachment integrity without checking in a fixture.
    private static func imagePayload(prefix: String, sequence: Int, size: Int) -> Data {
        guard size >= 58 else { return attachmentPayload(prefix: prefix, sequence: sequence, size: size) }
        let width = 512
        let rowBytes = ((width * 3 + 3) / 4) * 4
        let height = max(1, min(Int(Int32.max), (size - 54) / rowBytes))
        let pixelBytes = rowBytes * height
        var data = Data(repeating: 0, count: size)
        func write16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(truncatingIfNeeded: value)
            data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func write32(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8)) }
        }
        data[0] = 0x42; data[1] = 0x4d
        write32(UInt32(size), at: 2); write32(54, at: 10); write32(40, at: 14)
        write32(UInt32(width), at: 18); write32(UInt32(height), at: 22)
        write16(1, at: 26); write16(24, at: 28); write32(UInt32(pixelBytes), at: 34)
        let seed = Data(SHA256.hash(data: Data("image:\(prefix):\(sequence)".utf8)))
        for index in 0..<pixelBytes { data[54 + index] = seed[index % seed.count] ^ UInt8(truncatingIfNeeded: index &+ sequence) }
        return data
    }

    private static func waitForPeer(_ store: SidebandStore, destination: String, timeout: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var nextRequest = ContinuousClock.now
        while ContinuousClock.now < deadline {
            if store.networkState == .ready,
               store.hasPath(to: destination),
               store.hasValidatedDiscovery(to: destination) { return true }
            if store.networkState == .ready, ContinuousClock.now >= nextRequest {
                await store.requestPath(to: destination, surfaceErrors: false)
                nextRequest = ContinuousClock.now + .seconds(4)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private static func restoreNetworkPreferences() {
        for key in networkPreferenceKeys {
            if missingNetworkPreferences.contains(key) { UserDefaults.standard.removeObject(forKey: key) }
            else if let value = savedNetworkPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    private static func write(_ report: DeliverySoakReport, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
        print(
            "SIDEBAND_SOAK_REPORT phase=\(report.phase) " +
            "out=\(report.outboundDelivered)/\(report.expectedEachDirection) " +
            "queued=\(report.outboundQueued) sent=\(report.outboundSent) failed=\(report.outboundFailed) " +
            "in=\(report.inboundReceived)/\(report.expectedEachDirection) " +
            "attachments=\(report.inboundAttachmentsVerified)/\(report.expectedAttachmentsEachDirection) " +
            "timeouts=\(report.deliveryTimeouts)"
        )
        if report.phase == "complete" ||
            report.phase.hasSuffix("timeout") ||
            report.phase == "invalid-destination" {
            // A sandboxed distributed app may write its report inside a
            // container the invoking terminal cannot traverse. Emit the final
            // evidence once so the launcher can recover the exact JSON without
            // weakening the sandbox or requesting extra filesystem access.
            print("SIDEBAND_SOAK_FINAL_JSON \(data.base64EncodedString())")
        }
    }
}

private struct DeliverySoakReport: Codable {
    var phase: String
    let networkMode: String
    let networkState: String
    let automaticConnection: String
    let localDestination: String
    let destination: String
    let startedAt: Date
    var completedAt: Date?
    let expectedEachDirection: Int
    let outboundQueued: Int
    let outboundSent: Int
    let outboundDelivered: Int
    let outboundFailed: Int
    let inboundReceived: Int
    let missingOutbound: [String]
    let missingInbound: [String]
    let duplicateInbound: [String]
    let inboundInOrder: Bool
    let expectedAttachmentsEachDirection: Int
    let inboundAttachmentsVerified: Int
    let attachmentIntegrityFailures: [String]
    let knownPath: Bool
    let deliveryTimeouts: Int
    let lastError: String?
}
