import SwiftUI
import SidebandCore
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
                    await store.notifications.prepare()
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        #else
        WindowGroup("Lower Sideband") {
            protectedContent
                .task {
                    NotificationInteractionBridge.shared.install(store: store)
                    await store.notifications.prepare()
                    RemoteWakeBridge.shared.install { [store] in await store.performRemoteWakeSync() }
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
        store.setVoiceFrameHandler { [weak audioEngine] payload in
            audioEngine?.play(opus: payload)
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
            do { try await audioEngine.start() }
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

    func install(_ handler: @escaping @MainActor () async -> Bool) { self.handler = handler }
    func perform() async -> Bool { await handler?() ?? false }
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
        UserDefaults.standard.set(deviceToken.map { String(format: "%02x", $0) }.joined(), forKey: "sidebandAPNsDeviceToken")
        UserDefaults.standard.removeObject(forKey: "sidebandAPNsRegistrationError")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "sidebandAPNsRegistrationError")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let success = await RemoteWakeBridge.shared.perform()
            completionHandler(success ? .newData : .failed)
        }
    }
}
#endif

#if DEBUG
@MainActor
enum DeliverySoakRunner {
    private static let environment = ProcessInfo.processInfo.environment
    private static var hasConfiguredNetwork = false
    private static var hasStartedNetwork = false
    private static var hasStarted = false
    private static var deliveryTimeoutBaseline = 0

    static func configureNetworkIfRequested(_ store: SidebandStore) {
        guard let mode = environment["SIDEBAND_SOAK_NETWORK_MODE"] else { return }
        guard !hasConfiguredNetwork else { return }
        hasConfiguredNetwork = true
        store.removeDeliverySoakMessages()
        deliveryTimeoutBaseline = store.deliveryTimeoutCount
        store.autoConnectEnabled = mode == "automatic" || environment["SIDEBAND_SOAK_AUTOCONNECT"] == "1"
        store.internetOnlyEnabled = mode == "public"
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
        case "automatic":
            store.networkHost = ""
            store.networkIPv6Host = ""
            store.networkInternetHost = ""
        default:
            break
        }
        UserDefaults.standard.set(store.autoConnectEnabled, forKey: "reticulumAutoConnect")
        UserDefaults.standard.set(store.internetOnlyEnabled, forKey: "reticulumInternetOnly")
        UserDefaults.standard.set(store.networkHost, forKey: "reticulumHost")
        UserDefaults.standard.set(store.networkIPv6Host, forKey: "reticulumIPv6Host")
        UserDefaults.standard.set(store.networkInternetHost, forKey: "reticulumInternetHost")
        UserDefaults.standard.set(store.networkInternetPort, forKey: "reticulumInternetPort")
        UserDefaults.standard.set(store.networkPort, forKey: "reticulumPort")
        UserDefaults.standard.set(store.preferIPv6, forKey: "reticulumPreferIPv6")
    }

    static func startNetworkIfRequested(_ store: SidebandStore) async -> Bool {
        guard let mode = environment["SIDEBAND_SOAK_NETWORK_MODE"] else { return false }
        guard !hasStartedNetwork else { return true }
        hasStartedNetwork = true
        // Scene restoration can start the normal automatic connector before
        // this DEBUG-only acceptance runner is invoked on macOS. Reset that
        // in-flight attempt so the requested test topology is deterministic.
        await store.disconnectNetwork()
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
        case "automatic":
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

        let reportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

        guard store.addConversation(destinationHash: destination, displayName: "Delivery soak", select: true) else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "invalid-destination")
            return
        }

        let existingBodies = Set(store.messages.map(\.body))
        for sequence in 1...count {
            let body = messageBody(prefix: outboundPrefix, sequence: sequence)
            if !existingBodies.contains(body) { await store.send(body) }
            try? await Task.sleep(for: .milliseconds(20))
        }

        networkReadyDeadline = ContinuousClock.now + .seconds(600)
        while ContinuousClock.now < networkReadyDeadline {
            let report = makeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, phase: "running")
            write(report, to: reportURL)
            if report.outboundDelivered == count,
               report.inboundReceived == count,
               report.outboundQueued == 0,
               report.outboundFailed == 0,
               report.missingOutbound.isEmpty,
               report.missingInbound.isEmpty,
               report.duplicateInbound.isEmpty,
               report.inboundInOrder {
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
        write(makeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, phase: phase), to: reportURL)
    }

    private static func makeReport(store: SidebandStore, destination: String, outboundPrefix: String, inboundPrefix: String, count: Int, startedAt: Date, phase: String) -> DeliverySoakReport {
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
        return DeliverySoakReport(
            phase: phase,
            networkMode: environment["SIDEBAND_SOAK_NETWORK_MODE"] ?? "unchanged",
            networkState: String(describing: store.networkState),
            automaticConnection: store.automaticConnectionDescription,
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
            knownPath: store.hasPath(to: destination),
            deliveryTimeouts: max(0, store.deliveryTimeoutCount - deliveryTimeoutBaseline),
            lastError: store.lastError
        )
    }

    private static func messageBody(prefix: String, sequence: Int) -> String {
        "\(prefix)-\(String(format: "%03d", sequence))"
    }

    private static func write(_ report: DeliverySoakReport, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
        if let line = String(data: data, encoding: .utf8) { print("SIDEBAND_SOAK_REPORT \(line)") }
    }
}

private struct DeliverySoakReport: Codable {
    var phase: String
    let networkMode: String
    let networkState: String
    let automaticConnection: String
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
    let knownPath: Bool
    let deliveryTimeouts: Int
    let lastError: String?
}
#endif
