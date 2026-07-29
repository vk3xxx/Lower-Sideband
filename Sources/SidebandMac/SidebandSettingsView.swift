import SwiftUI
import SidebandCore
import ReticulumKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case overview
    case connection
    case interfaces
    case delivery
    case syncPrivacy
    case notifications
    case voiceTelemetry
    case radios
    case plugins
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .connection: "Connection"
        case .interfaces: "Interfaces"
        case .delivery: "Delivery"
        case .syncPrivacy: "Sync & Privacy"
        case .notifications: "Notifications"
        case .voiceTelemetry: "Voice & Telemetry"
        case .radios: "Radios"
        case .plugins: "Plugins"
        case .advanced: "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Identity and current service health"
        case .connection: "Automatic discovery and gateways"
        case .interfaces: "Reticulum transports and listeners"
        case .delivery: "Message routing and attachments"
        case .syncPrivacy: "iCloud, authentication and content safety"
        case .notifications: "Alerts, previews and sounds"
        case .voiceTelemetry: "Calls, codecs and trusted telemetry"
        case .radios: "RNode interfaces and radio hardware"
        case .plugins: "App-bundled extensions and activity"
        case .advanced: "Routing, diagnostics and maintenance"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "checkmark.circle"
        case .connection: "network"
        case .interfaces: "point.3.connected.trianglepath.dotted"
        case .delivery: "paperplane"
        case .syncPrivacy: "lock.shield"
        case .notifications: "bell"
        case .voiceTelemetry: "waveform"
        case .radios: "antenna.radiowaves.left.and.right"
        case .plugins: "puzzlepiece.extension"
        case .advanced: "gearshape.2"
        }
    }

    var searchTerms: String { "\(title) \(subtitle)".lowercased() }
}

private enum SettingsConfirmation {
    case resetGatewayHealth
    case clearPluginHistory
    case removeRNode(UUID, String)
    case runStorageMaintenance

    var title: String {
        switch self {
        case .resetGatewayHealth: "Reset Gateway History?"
        case .clearPluginHistory: "Clear Plugin Activity?"
        case .removeRNode: "Remove RNode?"
        case .runStorageMaintenance: "Run Storage Maintenance?"
        }
    }

    var message: String {
        switch self {
        case .resetGatewayHealth:
            "Automatic connection will forget recent endpoint performance and begin ranking gateways from a clean state."
        case .clearPluginHistory:
            "This removes the local plugin command audit history. It does not change which plugins are enabled."
        case .removeRNode(_, let name):
            "\(name) will be removed from this device. The radio itself is not modified."
        case .runStorageMaintenance:
            "Lower Sideband will apply your retention and storage limits. Starred messages, scheduled messages, queued messages and active transfers are always preserved."
        }
    }

    var actionTitle: String {
        switch self {
        case .resetGatewayHealth: "Reset History"
        case .clearPluginHistory: "Clear Activity"
        case .removeRNode: "Remove RNode"
        case .runStorageMaintenance: "Run Maintenance"
        }
    }
}

private struct SupportBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SidebandSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var store: SidebandStore
    let showsCloseButton: Bool

    @State private var selection: SettingsDestination? = .overview
    @State private var searchText = ""
    @State private var editingRNode: RNodeConfiguration?
    @State private var confirmation: SettingsConfirmation?
    @State private var supportBundleDocument: SupportBundleDocument?
    @State private var showingSupportBundleExporter = false
    @State private var exportFilename = "Lower-Sideband-Support"
    @State private var networkProfileName = ""

    var body: some View {
        Group {
            #if os(macOS)
            macSettings
            #else
            mobileSettings
            #endif
        }
        .fileExporter(
            isPresented: $showingSupportBundleExporter,
            document: supportBundleDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { store.lastError = "Support report export failed: \(error.localizedDescription)" }
            supportBundleDocument = nil
        }
    }

    #if os(macOS)
    private var macSettings: some View {
        NavigationSplitView {
            List(filteredDestinations, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .help(destination.subtitle)
                    .accessibilityHint(destination.subtitle)
            }
            .navigationTitle("Settings")
            .searchable(text: $searchText, prompt: "Search settings")
            .accessibilityIdentifier("settings-navigation")
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detailPage(selection ?? .overview)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .settingsSheetsAndConfirmation(
            store: store,
            editingRNode: $editingRNode,
            confirmation: $confirmation,
            performConfirmation: performConfirmation
        )
    }
    #endif

    #if !os(macOS)
    private var mobileSettings: some View {
        Group {
            if horizontalSizeClass == .regular {
                tabletSettings
            } else {
                phoneSettings
            }
        }
        .settingsSheetsAndConfirmation(
            store: store,
            editingRNode: $editingRNode,
            confirmation: $confirmation,
            performConfirmation: performConfirmation
        )
    }

    private var phoneSettings: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: SettingsDestination.overview) {
                        SettingsStatusSummary(store: store)
                    }
                }
                Section {
                    ForEach(filteredDestinations.filter { $0 != .overview }) { destination in
                        NavigationLink(value: destination) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.title)
                                    Text(destination.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: destination.systemImage)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .accessibilityHint(destination.subtitle)
                    }
                }
            }
            .navigationTitle("Settings")
            .searchable(text: $searchText, prompt: "Search settings")
            .accessibilityIdentifier("settings-navigation")
            .navigationDestination(for: SettingsDestination.self) { destination in
                detailPage(destination)
            }
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private var tabletSettings: some View {
        NavigationSplitView {
            List(filteredDestinations, selection: $selection) { destination in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.title)
                        Text(destination.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: destination.systemImage)
                        .foregroundStyle(.tint)
                }
                .tag(destination)
                .accessibilityHint(destination.subtitle)
            }
            .navigationTitle("Settings")
            .searchable(text: $searchText, prompt: "Search settings")
            .accessibilityIdentifier("settings-navigation")
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        } detail: {
            detailPage(selection ?? .overview)
        }
        .navigationSplitViewStyle(.balanced)
    }
    #endif

    private var filteredDestinations: [SettingsDestination] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? SettingsDestination.allCases : SettingsDestination.allCases.filter { $0.searchTerms.contains(query) }
    }

    @ViewBuilder
    private func detailPage(_ destination: SettingsDestination) -> some View {
        SettingsDetailContainer(destination: destination) {
            switch destination {
            case .overview: overviewSettings
            case .connection: connectionSettings
            case .interfaces: ReticulumInterfaceProfilesView(store: store)
            case .delivery: deliverySettings
            case .syncPrivacy: syncPrivacySettings
            case .notifications: notificationSettings
            case .voiceTelemetry: voiceTelemetrySettings
            case .radios: radioSettings
            case .plugins: pluginSettings
            case .advanced: advancedSettings
            }
        }
    }

    private var overviewSettings: some View {
        Form {
            Section {
                SettingsStatusSummary(store: store, expanded: true)
                ViewThatFits(in: .horizontal) {
                    HStack { connectionActions; Spacer(); diagnosticsButton }
                    VStack(alignment: .leading, spacing: 10) { connectionActions; diagnosticsButton }
                }
            }

            Section {
                LabeledContent("Display name") {
                    TextField("Your display name", text: Binding(
                        get: { store.localDisplayName },
                        set: { store.setLocalDisplayName($0) }
                    ))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Local display name")
                }
                LabeledContent("LXMF address") {
                    HStack {
                        Text(store.localDeliveryHash)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Button { settingsCopy(store.localDeliveryHash) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .labelStyle(.iconOnly)
                        .help("Copy your LXMF address: \(store.localDeliveryHash)")
                    }
                }
                LabeledContent("Contact link") {
                    HStack {
                        Button { settingsCopy(store.localContactLink.url.absoluteString) } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: store.localContactLink.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("Your display name is included in signed announces. Your LXMF address identifies this messaging identity.")
            }

            Section("Service health") {
                SettingsStateRow(title: "Connection", value: statusText, icon: statusIcon, tint: statusColor)
                SettingsStateRow(title: "Delivery", value: deliveryHealthText, icon: deliveryHealthIcon, tint: deliveryHealthColor)
                SettingsStateRow(title: "iCloud", value: store.iCloudSyncStatus.description, icon: iCloudStatusIcon, tint: iCloudStatusColor)
                SettingsStateRow(
                    title: "Radios",
                    value: store.rnodeManager.hasReadyInterface ? "RNode ready" : "No connected RNode",
                    icon: store.rnodeManager.hasReadyInterface ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right",
                    tint: store.rnodeManager.hasReadyInterface ? .green : .secondary
                )
                LabeledContent("Last background refresh", value: backgroundRefreshSummary)
                LabeledContent(
                    "Background wake success",
                    value: store.runtimeHealth.backgroundWakeSuccessRate?.formatted(.percent.precision(.fractionLength(1))) ?? "No wake attempts"
                )
                LabeledContent("Memory warnings", value: store.runtimeHealth.memoryPressureEvents.formatted())
                LabeledContent("MetricKit reports", value: store.runtimeHealth.metricPayloadsReceived.formatted())
                LabeledContent("MetricKit diagnostics", value: store.runtimeHealth.diagnosticPayloadsReceived.formatted())
                if let metricDate = store.runtimeHealth.lastMetricPayloadAt {
                    LabeledContent("Last MetricKit report", value: metricDate.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Network changes", value: store.runtimeHealth.reachabilityTransitions.formatted())
                LabeledContent(
                    "Foreground runtime",
                    value: "\(Int(store.runtimeHealth.currentForegroundSeconds / 3_600)) hr \(Int(store.runtimeHealth.currentForegroundSeconds / 60) % 60) min"
                )
                SettingsStateRow(
                    title: "Workload",
                    value: store.runtimeHealth.shouldReduceBackgroundWork ? "Energy-conserving" : "Normal",
                    icon: store.runtimeHealth.shouldReduceBackgroundWork ? "leaf.fill" : "gauge.with.dots.needle.50percent",
                    tint: store.runtimeHealth.shouldReduceBackgroundWork ? .green : .secondary
                )
            }
        }
    }

    private var connectionSettings: some View {
        Form {
            Section {
                Picker("Active profile", selection: Binding(
                    get: { store.activeNetworkProfileID },
                    set: { id in if let id { store.applyNetworkProfile(id) } }
                )) {
                    Text("Current settings").tag(Optional<UUID>.none)
                    ForEach(store.networkProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                HStack {
                    TextField("New profile name", text: $networkProfileName)
                    Button("Save Current") {
                        if store.saveCurrentNetworkProfile(named: networkProfileName) != nil {
                            networkProfileName = ""
                        }
                    }
                    .disabled(networkProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let active = store.networkProfiles.first(where: { $0.id == store.activeNetworkProfileID }),
                   active.kind == .custom {
                    Button("Delete \(active.name)", role: .destructive) {
                        store.deleteNetworkProfile(active.id)
                    }
                }
            } header: {
                Text("Network profiles")
            } footer: {
                Text("Switch between complete connection configurations without changing Reticulum identity or message data.")
            }

            Section {
                Picker("Connection mode", selection: Binding(
                    get: { store.connectionMode },
                    set: { store.setConnectionMode($0) }
                )) {
                    ForEach(NetworkConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .help("Automatic finds local gateways first and then tries healthy public gateways. Current mode: \(store.connectionMode.title).")

                Toggle("Connect automatically", isOn: Binding(
                    get: { store.autoConnectEnabled },
                    set: { store.setAutoConnect($0) }
                ))
                .help(store.autoConnectEnabled ? "Automatic reconnection is enabled." : "The app will remain offline until you connect manually.")

                Toggle("Prefer IPv6 when available", isOn: Binding(
                    get: { store.preferIPv6 },
                    set: { store.setPreferIPv6($0) }
                ))
                .help(store.preferIPv6 ? "IPv6 is preferred with automatic IPv4 fallback." : "IPv4 is preferred.")

                Toggle("Internet gateways only", isOn: Binding(
                    get: { store.internetOnlyEnabled },
                    set: { store.setInternetOnly($0) }
                ))
                .help(store.internetOnlyEnabled ? "Local Bonjour gateways are skipped." : "Local gateways are preferred before public gateways.")
            } header: {
                Text("Connection behavior")
            } footer: {
                Text(store.connectionMode == .automatic
                     ? "Recommended. Lower Sideband tries configured preferences, local discovery, authenticated interfaces, and then healthy public gateways."
                     : "Configured mode prioritizes the addresses below. Automatic fallback remains available when automatic reconnection is enabled.")
            }

            Section {
                SettingsTextFieldRow(title: "Host", prompt: "IPv4 address or hostname", text: $store.networkHost)
                SettingsTextFieldRow(title: "IPv6 host", prompt: "IPv6 address", text: $store.networkIPv6Host)
                LabeledContent("Port") {
                    TextField("4242", value: $store.networkPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 160)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .accessibilityLabel("Configured gateway port")
                }
                if !configuredPortIsValid {
                    Label("Enter a port from 1 to 65535.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Configured gateway")
            } footer: {
                Text("Leave both host fields empty to rely entirely on automatic discovery.")
            }

            Section {
                SettingsTextFieldRow(title: "Preferred interface", prompt: "TCP host, WebSocket or HTTP URL", text: $store.networkInternetHost)
                LabeledContent("Port") {
                    TextField("4242", value: $store.networkInternetPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 160)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .accessibilityLabel("Public gateway port")
                }
                if !internetPortIsValid {
                    Label("Enter a port from 1 to 65535.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Public gateway preference")
            } footer: {
                Text("This optional endpoint is tried before the built-in public pool. Lower Sideband never changes system DNS settings.")
            }

            Section {
                Toggle("Use managed infrastructure", isOn: Binding(
                    get: { store.managedInfrastructureEnabled },
                    set: {
                        store.configureManagedInfrastructure(
                            enabled: $0,
                            url: store.managedInfrastructureURL,
                            publicKey: store.managedInfrastructurePublicKey
                        )
                    }
                ))
                SettingsTextFieldRow(
                    title: "Signed directory",
                    prompt: "https://service.example/manifest.json",
                    text: $store.managedInfrastructureURL
                )
                .disabled(!store.managedInfrastructureEnabled)
                SettingsTextFieldRow(
                    title: "Operator public key",
                    prompt: "128 hexadecimal characters",
                    text: $store.managedInfrastructurePublicKey,
                    monospaced: true
                )
                .disabled(!store.managedInfrastructureEnabled)
                SettingsStateRow(
                    title: "Verification",
                    value: store.managedInfrastructureStatus,
                    icon: store.managedInternetGateways.count >= 2 ? "checkmark.seal.fill" : "shield.slash",
                    tint: store.managedInternetGateways.count >= 2 ? .green : .secondary
                )
                LabeledContent("Verified gateways", value: store.managedInternetGateways.count.formatted())
                LabeledContent("Managed propagation nodes", value: store.managedPropagationNodeCount.formatted())
                LabeledContent(
                    "Last refresh",
                    value: store.managedInfrastructureLastRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
                )
                Button("Verify and Refresh") {
                    store.configureManagedInfrastructure(
                        enabled: store.managedInfrastructureEnabled,
                        url: store.managedInfrastructureURL,
                        publicKey: store.managedInfrastructurePublicKey
                    )
                    Task { await store.refreshManagedInfrastructure() }
                }
                .disabled(!store.managedInfrastructureEnabled)
            } header: {
                Text("Managed connectivity")
            } footer: {
                Text("A signed directory can provision redundant gateways, propagation nodes and a wake service without trusting DNS or the download server. Your configured endpoint remains first priority.")
            }

            Section("Current connection") {
                SettingsStateRow(title: "Status", value: statusText, icon: statusIcon, tint: statusColor)
                LabeledContent("Transport", value: transportSummary)
                LabeledContent("System network", value: reachabilityText)
                LabeledContent("Automatic connection", value: store.automaticConnectionDescription)
                LabeledContent("Last connected", value: store.lastNetworkReadyAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                LabeledContent("Last announced", value: store.lastDeliveryAnnounceAt?.formatted(date: .abbreviated, time: .standard) ?? "Not this session")
                ForEach(store.networkInterfaces) { interface in
                    SettingsStateRow(
                        title: interface.name + (interface.isBootstrap ? " (bootstrap)" : ""),
                        value: interfaceStateText(interface.state),
                        icon: interfaceStateIcon(interface.state),
                        tint: interface.state == .ready ? .green : .secondary
                    )
                }
                Button {
                    Task { _ = await store.announceDeliveryDestinationNow() }
                } label: {
                    Label("Announce Now", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(store.networkState != .ready)
                .help(store.networkState == .ready
                      ? "Broadcast your LXMF delivery and voice destinations on every ready Reticulum interface now."
                      : "Connect to Reticulum before announcing your destinations.")
                connectionActions
            }

            Section {
                Toggle("Discover LAN gateways automatically", isOn: Binding(
                    get: { store.lanDiscovery.isSearching },
                    set: { $0 ? store.startGatewayDiscovery() : store.stopGatewayDiscovery() }
                ))
                .disabled(store.internetOnlyEnabled)
                if store.lanDiscovery.gateways.isEmpty {
                    Text(store.internetOnlyEnabled ? "Disabled by Internet gateways only." : "No advertised gateways found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.lanDiscovery.gateways) { gateway in
                        LabeledContent {
                            Button("Connect") { Task { await store.connect(to: gateway) } }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(gateway.name)
                                Text("\(gateway.type) · \(gateway.domain)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Local discovery")
            } footer: {
                Text("Uses Bonjour service discovery for Reticulum and Sideband gateways on the current local network.")
            }
        }
    }

    private var deliverySettings: some View {
        Form {
            Section("Message delivery") {
                SettingsStateRow(title: "Health", value: deliveryHealthText, icon: deliveryHealthIcon, tint: deliveryHealthColor)
                LabeledContent("Success rate", value: store.deliverySuccessRate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "No completed sends")
                ProgressView(value: store.deliverySuccessRate ?? 0)
                    .accessibilityLabel("Message delivery success rate")
                LabeledContent("Queued", value: store.queuedMessageCount.formatted())
                LabeledContent("Awaiting proof", value: store.sentMessageCount.formatted())
                LabeledContent("Delivered", value: store.deliveredMessageCount.formatted())
                LabeledContent("Failed", value: store.failedMessageCount.formatted())
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Flush Queue") { Task { await store.flushQueuedMessages() } }
                            .disabled(store.queuedMessageCount == 0 || store.networkState != .ready)
                        Button("Retry Failed") { Task { await store.retryAllFailedMessages() } }
                            .disabled(store.failedMessageCount == 0)
                    }
                    VStack(alignment: .leading) {
                        Button("Flush Queue") { Task { await store.flushQueuedMessages() } }
                            .disabled(store.queuedMessageCount == 0 || store.networkState != .ready)
                        Button("Retry Failed") { Task { await store.retryAllFailedMessages() } }
                            .disabled(store.failedMessageCount == 0)
                    }
                }
            }

            Section {
                Toggle("Choose propagation node automatically", isOn: Binding(
                    get: { store.propagationNodeIsAutomatic },
                    set: { store.setAutomaticPropagationNode($0) }
                ))
                SettingsTextFieldRow(
                    title: "Destination",
                    prompt: "Propagation-node LXMF destination",
                    text: Binding(get: { store.propagationNodeHash }, set: { store.setPropagationNode($0) }),
                    monospaced: true
                )
                .disabled(store.propagationNodeIsAutomatic)
                SettingsStateRow(title: "Route", value: propagationStatus, icon: propagationIcon, tint: store.propagationNodeHasPath ? .green : .secondary)
                LabeledContent("Discovered nodes", value: store.discoveredPropagationNodeCount.formatted())
                LabeledContent("Last sync", value: store.lastPropagationSync?.formatted(date: .abbreviated, time: .shortened) ?? "Not synced this session")
                HStack {
                    Button("Request Path") { Task { await store.requestPropagationNodePath() } }
                        .disabled(store.networkState != .ready || store.propagationNodePathPending)
                    Button("Sync Now") { Task { await store.syncPropagationNow() } }
                        .disabled(store.networkState != .ready || !store.propagationNodeHasPath)
                }
            } header: {
                Text("LXMF propagation")
            } footer: {
                Text("Propagation nodes store encrypted LXMF messages for delayed delivery when direct delivery is unavailable.")
            }

            Section {
                Toggle("Remote message wakes", isOn: Binding(
                    get: { store.remoteWakeEnabled },
                    set: { store.setRemoteWakeEnabled($0) }
                ))
                SettingsStateRow(
                    title: "Registration",
                    value: store.remoteWakeStatus,
                    icon: store.remoteWakeStatus == "Registered securely" ? "bell.badge.fill" : "bell.slash",
                    tint: store.remoteWakeStatus == "Registered securely" ? .green : .secondary
                )
                Button("Register This Device") {
                    Task { await store.registerRemoteWake(force: true) }
                }
                .disabled(!store.remoteWakeEnabled)
                if let registered = store.remoteWakeLastRegisteredAt {
                    LabeledContent("Last registered", value: registered.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Background delivery")
            } footer: {
                Text("The verified managed service receives only a signed device token and your LXMF delivery identity. Message content and keys never leave Reticulum.")
            }

            Section("Attachment storage") {
                if let report = store.attachmentStorageReport {
                    SettingsStateRow(
                        title: "Integrity",
                        value: report.isHealthy ? "Storage healthy" : "Storage needs attention",
                        icon: report.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: report.isHealthy ? .green : .orange
                    )
                    LabeledContent("Attachments", value: report.attachmentCount.formatted())
                    LabeledContent("Logical size", value: ByteCountFormatter.string(fromByteCount: Int64(report.logicalBytes), countStyle: .file))
                    LabeledContent("Encrypted files", value: ByteCountFormatter.string(fromByteCount: Int64(report.storedBytes), countStyle: .file))
                    LabeledContent("Missing or corrupt", value: "\(report.missingCount + report.corruptCount)")
                    LabeledContent("Orphaned files", value: report.orphanCount.formatted())
                } else {
                    Text("Inspect storage to calculate encrypted disk use and verify attachment integrity.")
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { attachmentActions }
                    VStack(alignment: .leading) { attachmentActions }
                }
            }

            Section {
                Toggle("Automatic maintenance", isOn: Binding(
                    get: { store.storagePolicy.automaticCleanupEnabled },
                    set: { value in updateStoragePolicy { $0.automaticCleanupEnabled = value } }
                ))
                Picker("Keep messages", selection: Binding(
                    get: { store.storagePolicy.messageRetentionDays },
                    set: { value in updateStoragePolicy { $0.messageRetentionDays = value } }
                )) {
                    ForEach(SidebandStoragePolicy.retentionChoices, id: \.self) { days in
                        Text(retentionLabel(days)).tag(days)
                    }
                }
                Picker("Keep attachments", selection: Binding(
                    get: { store.storagePolicy.attachmentRetentionDays },
                    set: { value in updateStoragePolicy { $0.attachmentRetentionDays = value } }
                )) {
                    ForEach(SidebandStoragePolicy.retentionChoices, id: \.self) { days in
                        Text(retentionLabel(days)).tag(days)
                    }
                }
                Picker("Attachment storage limit", selection: Binding(
                    get: { store.storagePolicy.maximumAttachmentStorageMB },
                    set: { value in updateStoragePolicy { $0.maximumAttachmentStorageMB = value } }
                )) {
                    ForEach(SidebandStoragePolicy.storageChoicesMB, id: \.self) { megabytes in
                        Text(storageLimitLabel(megabytes)).tag(megabytes)
                    }
                }
                if let result = store.lastStorageCleanupResult {
                    LabeledContent("Last maintenance", value: result.performedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(result.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Run Maintenance Now") { confirmation = .runStorageMaintenance }
                        Button("Release Temporary Caches") { _ = store.releasePerformanceCaches() }
                    }
                    VStack(alignment: .leading) {
                        Button("Run Maintenance Now") { confirmation = .runStorageMaintenance }
                        Button("Release Temporary Caches") { _ = store.releasePerformanceCaches() }
                    }
                }
            } header: {
                Text("Storage management")
            } footer: {
                Text("Limits apply oldest-first. Starred content, scheduled or queued messages, and active attachment transfers are never removed. Temporary caches can always be rebuilt from encrypted storage.")
            }
            .accessibilityIdentifier("settings.storage.management")

            if !store.incomingResourceProgress.isEmpty {
                Section("Active transfers") {
                    ForEach(store.incomingResourceProgress.keys.sorted(), id: \.self) { hash in
                        VStack(alignment: .leading, spacing: 5) {
                            LabeledContent("\(hash.prefix(12))…", value: "\(Int((store.incomingResourceProgress[hash] ?? 0) * 100))%")
                                .font(.caption.monospaced())
                            ProgressView(value: store.incomingResourceProgress[hash] ?? 0)
                        }
                    }
                }
            }
        }
    }

    private var syncPrivacySettings: some View {
        Form {
            Section {
                Toggle("Sync identity, conversations and messages", isOn: Binding(
                    get: { store.iCloudSyncEnabled },
                    set: { enabled in Task { await store.setICloudSyncEnabled(enabled) } }
                ))
                SettingsStateRow(title: "Status", value: store.iCloudSyncStatus.description, icon: iCloudStatusIcon, tint: iCloudStatusColor)
                Button("Sync Now") { Task { await store.syncICloudNow() } }
                    .disabled(!store.iCloudSyncEnabled || store.iCloudSyncStatus == .syncing)
            } header: {
                Text("iCloud device sync")
            } footer: {
                Text("Data is encrypted by Lower Sideband before it enters your private iCloud database. Gateway choices remain local to each device.")
            }

            Section {
                ForEach(store.continuityDevices) { device in
                    HStack {
                        Image(systemName: device.isCurrent ? "laptopcomputer.and.iphone" : "desktopcomputer")
                            .foregroundStyle(device.isCurrent ? .blue : .secondary)
                        VStack(alignment: .leading) {
                            Text(device.name).fontWeight(device.isCurrent ? .semibold : .regular)
                            Text("Last seen \(device.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.queuedMessageCount > 0 {
                            Text("\(device.queuedMessageCount) pending")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !device.isCurrent {
                            Button("Forget") { store.forgetContinuityDevice(device.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Continue Pending Messages on This Device") {
                    Task { await store.continueOutboxOnThisDevice() }
                }
                .disabled(!store.messages.contains {
                    $0.direction == .outgoing && ($0.state == .queued || $0.state == .failed)
                })
            } header: {
                Text("Multi-device continuity")
            } footer: {
                Text("Pending-message ownership prevents duplicate sends. Taking over moves all queued work to this device and resumes delivery.")
            }

            Section("App access") {
                Toggle("Require device authentication", isOn: Binding(
                    get: { store.privacyLock.isEnabled },
                    set: { enabled in Task { await store.privacyLock.setEnabled(enabled) } }
                ))
                .disabled(store.privacyLock.isAuthenticating)
                Text(store.privacyLock.availabilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = store.privacyLock.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Render rich text only from trusted contacts", isOn: Binding(
                    get: { store.richTextTrustedOnly },
                    set: { store.setRichTextTrustedOnly($0) }
                ))
            } header: {
                Text("Message content")
            } footer: {
                Text("When enabled, Markdown from unknown senders appears as literal text so disguised links don’t become interactive.")
            }
        }
    }

    private var notificationSettings: some View {
        Form {
            Section {
                Toggle("Allow notifications", isOn: Binding(
                    get: { store.notifications.isEnabled },
                    set: { enabled in Task { await store.notifications.setEnabled(enabled) } }
                ))
                LabeledContent("System permission", value: store.notifications.authorizationDescription)
                Toggle("Show sender and message previews", isOn: Binding(
                    get: { store.notifications.showPreviews },
                    set: { store.notifications.setShowPreviews($0) }
                ))
                .disabled(!store.notifications.isEnabled)
                Toggle("Play sounds", isOn: Binding(
                    get: { store.notifications.playSounds },
                    set: { store.notifications.setPlaySounds($0) }
                ))
                .disabled(!store.notifications.isEnabled)
                if let error = store.notifications.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Message notifications")
            } footer: {
                Text("Notifications are created only for verified incoming messages. Muted conversations and the conversation currently open do not alert.")
            }
        }
    }

    private var voiceTelemetrySettings: some View {
        Form {
            Section {
                Toggle("Accept calls from trusted contacts only", isOn: Binding(
                    get: { store.voiceTrustedOnly },
                    set: { store.setVoiceTrustedOnly($0) }
                ))
                Picker("Call quality", selection: Binding(
                    get: { store.preferredVoiceProfile },
                    set: { store.setPreferredVoiceProfile($0) }
                )) {
                    ForEach(LXSTVoice.Profile.allCases.filter(\.isLocallySupported), id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                Picker("Voice message codec", selection: Binding(
                    get: { store.preferredVoiceMessageMode },
                    set: { store.setPreferredVoiceMessageMode($0) }
                )) {
                    Text("Opus · 8 kbps").tag(LXMFVoiceMessageAudio.Mode.opusOgg)
                    Text("Codec2 · 2.4 kbps").tag(LXMFVoiceMessageAudio.Mode.codec2_2400)
                    Text("Codec2 · 1.2 kbps").tag(LXMFVoiceMessageAudio.Mode.codec2_1200)
                    Text("Codec2 · 700 bps").tag(LXMFVoiceMessageAudio.Mode.codec2_700C)
                }
                LabeledContent("LXST address") {
                    HStack {
                        Text(store.localVoiceHash).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                        Button { settingsCopy(store.localVoiceHash) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .labelStyle(.iconOnly)
                    }
                }
            } header: {
                Text("Secure voice")
            } footer: {
                Text("Calls use an authenticated, end-to-end encrypted Reticulum link. Lower bitrates trade audio quality for radio efficiency.")
            }

            Section {
                Toggle("Answer requests from trusted contacts", isOn: Binding(
                    get: { store.telemetryRespondToTrustedRequests },
                    set: { store.setTelemetryRespondToTrustedRequests($0) }
                ))
                Toggle("Act as a telemetry collector", isOn: Binding(
                    get: { store.telemetryCollectorEnabled },
                    set: { store.setTelemetryCollectorEnabled($0) }
                ))
                Toggle("Return only the newest reading per source", isOn: Binding(
                    get: { store.telemetryCollectorLatestOnly },
                    set: { store.setTelemetryCollectorLatestOnly($0) }
                ))
                .disabled(!store.telemetryCollectorEnabled)
                SettingsTextFieldRow(
                    title: "Preferred collector",
                    prompt: "LXMF destination",
                    text: Binding(get: { store.telemetryCollectorHash }, set: { store.setTelemetryCollectorHash($0) }),
                    monospaced: true
                )
            } header: {
                Text("Telemetry service")
            } footer: {
                Text("Requests are authenticated. Collector responses include telemetry from trusted contacts only and never include message text.")
            }
        }
    }

    private var radioSettings: some View {
        Form {
            Section {
                Toggle("Discover and reconnect Bluetooth RNodes", isOn: Binding(
                    get: { store.rnodeManager.automaticDiscoveryEnabled },
                    set: { store.rnodeManager.setAutomaticDiscovery($0) }
                ))
                HStack {
                    Button { editingRNode = RNodeConfiguration() } label: { Label("Add RNode", systemImage: "plus") }
                    Button("Start Enabled Radios") { Task { await store.rnodeManager.startAll() } }
                    Button("Run Protocol Self-Test") { Task { await store.rnodeManager.runSelfTest() } }
                }
                if let result = store.rnodeManager.selfTestResult {
                    Label(result, systemImage: result.hasPrefix("Passed") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.hasPrefix("Passed") ? .green : .orange)
                        .font(.caption)
                }
            } header: {
                Text("RNode discovery")
            } footer: {
                Text("Radio and Internet interfaces can remain active together. Bluetooth and Wi-Fi are available on iPhone and iPad; USB serial is available on Mac.")
            }

            if store.rnodeManager.configurations.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No RNodes Configured",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add a radio manually or enable Bluetooth discovery.")
                    )
                }
            } else {
                Section("Configured radios") {
                    ForEach(store.rnodeManager.configurations) { configuration in
                        rnodeRow(configuration)
                    }
                }
            }
        }
    }

    private var pluginSettings: some View {
        Form {
            Section {
                if store.pluginRegistry.manifests.isEmpty {
                    ContentUnavailableView("No Plugins", systemImage: "puzzlepiece.extension", description: Text("No app-bundled plugins are installed."))
                }
                ForEach(store.pluginRegistry.manifests) { manifest in
                    Toggle(isOn: Binding(
                        get: { store.isPluginEnabled(manifest.identifier) },
                        set: { store.setPluginEnabled($0, identifier: manifest.identifier) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(manifest.name)
                            Text("Version \(manifest.version) · \(manifest.commands.sorted().joined(separator: ", "))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(pluginPermissionSummary(manifest.permissions))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let runtime = store.pluginRegistry.runtimeStatuses[manifest.identifier] {
                                Text("\(runtime.invocationCount) run\(runtime.invocationCount == 1 ? "" : "s") · last \(runtime.lastOutcome?.rawValue ?? "unknown")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .help("\(manifest.name) is \(store.isPluginEnabled(manifest.identifier) ? "enabled" : "disabled"). \(pluginPermissionSummary(manifest.permissions))")
                }
                ForEach(store.pluginRegistry.rejectedPluginDescriptions, id: \.self) { description in
                    Label(description, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Installed plugins")
            } footer: {
                Text("Plugins are app-bundled and permission-scoped. Contacts must also be trusted, fingerprint-verified and explicitly authorized before plugin requests can run.")
            }

            Section {
                if store.pluginAuditEvents.isEmpty {
                    Text("No plugin commands have run on this device.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.pluginAuditEvents.prefix(10)) { event in
                        HStack {
                            Image(systemName: pluginAuditIcon(event.outcome))
                                .foregroundStyle(pluginAuditColor(event.outcome))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(event.command).font(.callout.monospaced()).lineLimit(1)
                                Text(event.pluginIdentifier ?? "No enabled plugin")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(event.timestamp, style: .relative).font(.caption).foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Plugin command \(event.command), \(event.outcome.rawValue)")
                    }
                    Button("Clear Activity", role: .destructive) { confirmation = .clearPluginHistory }
                }
            } header: {
                Text("Recent activity")
            } footer: {
                Text("Activity stores command names and outcomes only. Arguments and message content are never logged.")
            }
        }
    }

    private var advancedSettings: some View {
        Form {
            #if os(macOS)
            Section {
                Toggle("Route packets between this Mac’s interfaces", isOn: Binding(
                    get: { store.transportInstanceEnabled },
                    set: { store.setTransportInstanceEnabled($0) }
                ))
                SettingsStateRow(
                    title: "Mode",
                    value: store.transportInstanceEnabled ? "Routing" : "Endpoint only",
                    icon: store.transportInstanceEnabled ? "arrow.triangle.branch" : "desktopcomputer",
                    tint: store.transportInstanceEnabled ? .green : .secondary
                )
                LabeledContent("Learned routes", value: store.transportInstanceSnapshot.knownRoutes.formatted())
                LabeledContent("Forwarded packets", value: store.transportInstanceSnapshot.forwardedPackets.formatted())
                LabeledContent("Duplicates blocked", value: store.transportInstanceSnapshot.duplicatePackets.formatted())
            } header: {
                Text("Reticulum Transport Instance")
            } footer: {
                Text("Enable only on a Mac intended to remain online as a Reticulum router. Loop suppression and interface modes remain enforced.")
            }
            #endif

            Section {
                Toggle("Listen for authenticated peers", isOn: Binding(
                    get: { store.autoInterfaceDiscovery.isListening },
                    set: { $0 ? store.startAutoInterfaceDiscovery() : store.stopAutoInterfaceDiscovery() }
                ))
                LabeledContent("Multicast address", value: "\(AutoInterfaceProtocol.multicastAddress):\(AutoInterfaceProtocol.discoveryPort)")
                LabeledContent("Authenticated peers", value: store.autoInterfaceDiscovery.peers.count.formatted())
                LabeledContent("Beacons sent", value: store.autoInterfaceDiscovery.beaconsSent.formatted())
                LabeledContent("UDP packets", value: "\(store.autoInterfaceDiscovery.dataPacketsReceived) received · \(store.autoInterfaceDiscovery.dataPacketsSent) sent")
                if let error = store.autoInterfaceDiscovery.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            } header: {
                Text("AutoInterface")
            } footer: {
                Text("Uses authenticated IPv6 multicast peer discovery. Availability on iPhone and iPad depends on network conditions and Apple platform entitlements.")
            }

            Section("Routing statistics") {
                LabeledContent("Packets received", value: store.receivedPacketCount.formatted())
                LabeledContent("Known paths", value: store.knownPathCount.formatted())
                LabeledContent("Validated announces", value: store.validatedDiscoveryCount.formatted())
                LabeledContent("Unverified announces", value: store.unverifiedDiscoveryCount.formatted())
                LabeledContent("Pending requests", value: store.pendingPathCount.formatted())
                LabeledContent("Active links", value: store.activeLinkCount.formatted())
                LabeledContent("Encrypted packets", value: store.encryptedPacketsReceived.formatted())
                LabeledContent("Delivery timeouts", value: store.deliveryTimeoutCount.formatted())
            }

            Section("Gateway health") {
                Text(store.gatewayHealth.isEmpty
                     ? "No endpoint history has been recorded."
                     : "\(store.gatewayHealth.count) endpoints are ranked using recent reachability and delivery results.")
                    .foregroundStyle(.secondary)
                Button("Copy Gateway Health Report") { settingsCopy(store.gatewayHealthDiagnostics) }
                    .disabled(store.gatewayHealth.isEmpty)
                Button("Reset Gateway Health History", role: .destructive) { confirmation = .resetGatewayHealth }
                    .disabled(store.gatewayHealth.isEmpty)
            }

            Section {
                diagnosticsButton
                Button {
                    exportSupportBundle()
                } label: {
                    Label("Export Redacted Support Report", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export-redacted-support-report")
                Button("Copy Attachment Report") { settingsCopy(store.attachmentStorageDiagnostics) }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The exported support report contains health counters and redacted technical state. It never includes message content, private keys, exact identities, addresses, or attachment payloads.")
            }

            Section {
                SettingsStateRow(
                    title: "Environment",
                    value: store.deviceAcceptance.deviceDescription,
                    icon: store.deviceAcceptance.isPhysicalDevice ? "checkmark.seal.fill" : "simulator",
                    tint: store.deviceAcceptance.isPhysicalDevice ? .green : .orange
                )
                ProgressView(
                    value: Double(store.deviceAcceptance.completedCount),
                    total: Double(SidebandAcceptanceScenario.allCases.count)
                ) {
                    Text("Acceptance progress")
                } currentValueLabel: {
                    Text("\(store.deviceAcceptance.completedCount) of \(SidebandAcceptanceScenario.allCases.count)")
                }
                ForEach(SidebandAcceptanceScenario.allCases) { scenario in
                    acceptanceScenarioRow(scenario)
                }
                Button {
                    exportAcceptanceReport()
                } label: {
                    Label("Export Acceptance Report", systemImage: "doc.badge.arrow.up")
                }
                .accessibilityIdentifier("export-device-acceptance-report")
                Button("Reset Acceptance Results", role: .destructive) {
                    store.deviceAcceptance.reset()
                }
                .disabled(store.deviceAcceptance.completedCount == 0)
            } header: {
                Text("Apple device acceptance")
            } footer: {
                Text(store.deviceAcceptance.isPhysicalDevice
                     ? "Record evidence on this device after completing each guided scenario. Radio hardware certification is tracked separately."
                     : "Simulator results are useful for development but do not certify camera, microphone, background scheduling, cellular handover or physical-device behaviour.")
            }
        }
    }

    @ViewBuilder
    private var connectionActions: some View {
        if isConnectedOrConnecting {
            if store.networkState == .ready {
                Button("Reconnect") { Task { await store.reconnectNetwork() } }
                    .disabled(!configuredPortIsValid || !internetPortIsValid)
            }
            Button("Disconnect", role: .destructive) { Task { await store.disconnectNetwork() } }
        } else {
            Button("Connect") { Task { await store.startAutomaticConnection() } }
                .buttonStyle(.borderedProminent)
                .disabled(!configuredPortIsValid || !internetPortIsValid)
        }
    }

    private var diagnosticsButton: some View {
        Button { settingsCopy(store.networkDiagnosticsReport) } label: {
            Label("Copy Diagnostics", systemImage: "stethoscope")
        }
        .help("Copy the current connection, routing and runtime state for troubleshooting.")
    }

    private func exportSupportBundle() {
        do {
            supportBundleDocument = SupportBundleDocument(data: try store.exportRedactedSupportBundleData())
            exportFilename = "Lower-Sideband-Support-\(Date.now.formatted(.iso8601.year().month().day()))"
            showingSupportBundleExporter = true
        } catch {
            store.lastError = "Support report export failed: \(error.localizedDescription)"
        }
    }

    private func exportAcceptanceReport() {
        do {
            supportBundleDocument = SupportBundleDocument(data: try store.deviceAcceptance.exportData())
            exportFilename = "Lower-Sideband-Device-Acceptance-\(Date.now.formatted(.iso8601.year().month().day()))"
            showingSupportBundleExporter = true
        } catch {
            store.lastError = "Acceptance report export failed: \(error.localizedDescription)"
        }
    }

    private func acceptanceScenarioRow(_ scenario: SidebandAcceptanceScenario) -> some View {
        let result = store.deviceAcceptance.result(for: scenario)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(scenario.title, systemImage: acceptanceIcon(result.outcome))
                    .foregroundStyle(acceptanceColor(result.outcome))
                Spacer()
                if let testedAt = result.testedAt {
                    Text(testedAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Menu("Result") {
                    Button("Pass", systemImage: "checkmark.circle") {
                        store.deviceAcceptance.record(.passed, for: scenario, notes: result.notes)
                    }
                    Button("Fail", systemImage: "xmark.circle") {
                        store.deviceAcceptance.record(.failed, for: scenario, notes: result.notes)
                    }
                    Button("Not Run", systemImage: "circle") {
                        store.deviceAcceptance.record(.notRun, for: scenario)
                    }
                }
            }
            Text(scenario.instructions).font(.caption).foregroundStyle(.secondary)
            TextField("Optional evidence or notes", text: Binding(
                get: { store.deviceAcceptance.result(for: scenario).notes },
                set: { store.deviceAcceptance.record(result.outcome, for: scenario, notes: $0) }
            ), axis: .vertical)
            .lineLimit(1...3)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(scenario.title), \(acceptanceOutcomeDescription(result.outcome))")
        .accessibilityHint(scenario.instructions)
    }

    private func acceptanceIcon(_ outcome: SidebandAcceptanceOutcome) -> String {
        switch outcome {
        case .notRun: "circle"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func acceptanceColor(_ outcome: SidebandAcceptanceOutcome) -> Color {
        switch outcome {
        case .notRun: .secondary
        case .passed: .green
        case .failed: .red
        }
    }

    private func acceptanceOutcomeDescription(_ outcome: SidebandAcceptanceOutcome) -> String {
        switch outcome {
        case .notRun: "not run"
        case .passed: "passed"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var attachmentActions: some View {
        Button("Inspect") { Task { await store.refreshAttachmentStorageReport() } }
        Button("Remove Orphans") { Task { _ = await store.cleanupOrphanedAttachmentFiles() } }
            .disabled(store.attachmentStorageReport?.orphanCount == 0)
        Button("Remove Failed Records") { Task { _ = await store.removeFailedAttachmentMetadata() } }
            .disabled(!store.messages.contains { $0.attachments.contains { $0.state == .failed } })
    }

    private func rnodeRow(_ configuration: RNodeConfiguration) -> some View {
        let snapshot = store.rnodeManager.snapshots.first { $0.id == configuration.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(configuration.name, systemImage: rnodeIcon(configuration.transport))
                    .font(.headline)
                Spacer()
                Label(rnodeStateText(snapshot?.state ?? .stopped), systemImage: rnodeStateIcon(snapshot?.state ?? .stopped))
                    .font(.caption)
                    .foregroundStyle(snapshot?.state == .ready ? .green : .secondary)
            }
            Text(rnodeConfigurationSummary(configuration))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let metrics = snapshot?.metrics {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { rnodeMetricSummary(metrics) }
                    VStack(alignment: .leading, spacing: 3) { rnodeMetricSummary(metrics) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let error = snapshot?.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack { rnodeActions(configuration, snapshot: snapshot) }
                VStack(alignment: .leading) { rnodeActions(configuration, snapshot: snapshot) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rnodeMetricSummary(_ metrics: RNodeMetrics) -> some View {
        if let major = metrics.firmwareMajor, let minor = metrics.firmwareMinor { Text("Firmware \(major).\(minor)") }
        if let rssi = metrics.rssi { Text("RSSI \(rssi) dBm") }
        if let snr = metrics.snr { Text("SNR \(snr.formatted(.number.precision(.fractionLength(1)))) dB") }
        if let battery = metrics.batteryPercent { Text("Battery \(battery)%") }
    }

    @ViewBuilder
    private func rnodeActions(_ configuration: RNodeConfiguration, snapshot: RNodeInterface.Snapshot?) -> some View {
        Button("Edit") { editingRNode = configuration }
        Button("Blink") { Task { await store.rnodeManager.blink(configuration.id) } }
            .disabled(snapshot?.state != .ready)
        Menu("Hardware") {
            Button("Write Display Test Pattern") {
                Task { try? await store.rnodeManager.writeFramebuffer(RNodeFramebuffer.testPattern().bytes, on: configuration.id) }
            }
            Button("Read Framebuffer") { Task { try? await store.rnodeManager.requestFramebuffer(on: configuration.id) } }
            Button("Read Display") { Task { try? await store.rnodeManager.requestDisplaySnapshot(on: configuration.id) } }
            Button("Inspect ROM") { Task { try? await store.rnodeManager.requestROMSnapshot(on: configuration.id) } }
        }
        .disabled(snapshot?.state != .ready)
        Button(configuration.enabled ? "Disable" : "Enable") {
            var changed = configuration
            changed.enabled.toggle()
            Task { try? await store.rnodeManager.upsert(changed) }
        }
        Button("Remove", role: .destructive) { confirmation = .removeRNode(configuration.id, configuration.name) }
    }

    private func performConfirmation() {
        guard let confirmation else { return }
        switch confirmation {
        case .resetGatewayHealth:
            store.resetGatewayHealth()
        case .clearPluginHistory:
            store.clearPluginAuditHistory()
        case .removeRNode(let id, _):
            Task { await store.rnodeManager.remove(id) }
        case .runStorageMaintenance:
            Task { _ = await store.performStorageMaintenance() }
        }
        self.confirmation = nil
    }

    private func updateStoragePolicy(_ update: (inout SidebandStoragePolicy) -> Void) {
        var policy = store.storagePolicy
        update(&policy)
        store.setStoragePolicy(policy)
    }

    private func retentionLabel(_ days: Int) -> String {
        days == 0 ? "Forever" : "\(days) days"
    }

    private func storageLimitLabel(_ megabytes: Int) -> String {
        megabytes == 0
            ? "No limit"
            : ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_000_000, countStyle: .file)
    }

    private var configuredPortIsValid: Bool { (1...65_535).contains(store.networkPort) }
    private var internetPortIsValid: Bool { (1...65_535).contains(store.networkInternetPort) }

    private var isConnectedOrConnecting: Bool {
        if case .ready = store.networkState { return true }
        if case .connecting = store.networkState { return true }
        return false
    }

    private var reachabilityText: String {
        let protocols = [store.reachability.supportsIPv4 ? "IPv4" : nil, store.reachability.supportsIPv6 ? "IPv6" : nil].compactMap { $0 }.joined(separator: "/")
        let flags = [store.reachability.isExpensive ? "metered" : nil, store.reachability.isConstrained ? "constrained" : nil].compactMap { $0 }
        return ([store.reachability.interfaceSummary, protocols] + flags).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var transportSummary: String {
        var components: [String] = []
        if !store.networkInterfaces.isEmpty { components.append("TCP · HDLC") }
        let readyRNodes = store.rnodeManager.snapshots.filter { $0.state == .ready }
        if !readyRNodes.isEmpty {
            let kinds = Set(readyRNodes.map { $0.transport.title }).sorted().joined(separator: "/")
            components.append("RNode \(kinds)")
        }
        if components.isEmpty { components.append("No active transport") }
        var value = components.joined(separator: " · ")
        if store.networkInterfaces.count > 1 {
            value += " · \(store.networkInterfaces.count) gateways"
        } else if let host = store.activeNetworkHost {
            value += " · \(host)"
            if let port = store.activeNetworkPort { value += ":\(port)" }
        }
        return value
    }

    private var backgroundRefreshSummary: String {
        guard let date = store.lastBackgroundRefreshAt else { return "Not run yet" }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(store.lastBackgroundRefreshSucceeded == true ? "succeeded" : "incomplete")"
    }

    private var statusText: String {
        switch store.networkState {
        case .stopped: "Disconnected"
        case .connecting: "Connecting"
        case .ready:
            if store.rnodeManager.hasReadyInterface && !store.networkInterfaces.contains(where: { $0.state == .ready }) { "RNode connected" }
            else if store.rnodeManager.hasReadyInterface { "TCP and RNode connected" }
            else { "TCP connected" }
        case .failed(let reason): store.reconnectDelaySeconds.map { "Retrying in \($0)s · \(reason)" } ?? "Connection failed · \(reason)"
        }
    }

    private var statusIcon: String {
        switch store.networkState {
        case .ready: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "circle"
        }
    }

    private var statusColor: Color {
        switch store.networkState {
        case .ready: .green
        case .connecting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var deliveryHealthText: String {
        if store.failedMessageCount > 0 { return "Attention needed" }
        if store.queuedMessageCount > 0 || store.sentMessageCount > 0 { return "Messages in progress" }
        if store.deliveredMessageCount > 0 { return "Healthy" }
        return "No delivery history"
    }

    private var deliveryHealthIcon: String {
        if store.failedMessageCount > 0 { return "exclamationmark.triangle.fill" }
        if store.queuedMessageCount > 0 || store.sentMessageCount > 0 { return "clock.arrow.circlepath" }
        if store.deliveredMessageCount > 0 { return "checkmark.circle.fill" }
        return "chart.bar"
    }

    private var deliveryHealthColor: Color {
        if store.failedMessageCount > 0 { return .orange }
        if store.deliveredMessageCount > 0 && store.queuedMessageCount == 0 && store.sentMessageCount == 0 { return .green }
        return .secondary
    }

    private var propagationStatus: String {
        if store.propagationNodeHasPath { return "Propagation node reachable" }
        if store.propagationNodePathPending { return "Path requested" }
        return "Route unknown"
    }

    private var propagationIcon: String {
        if store.propagationNodeHasPath { return "checkmark.circle.fill" }
        if store.propagationNodePathPending { return "clock" }
        return "questionmark.circle"
    }

    private var iCloudStatusIcon: String {
        switch store.iCloudSyncStatus {
        case .disabled: "icloud.slash"
        case .checkingAccount, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .ready: "icloud"
        case .synced: "checkmark.icloud.fill"
        case .unavailable, .failed: "exclamationmark.icloud"
        }
    }

    private var iCloudStatusColor: Color {
        switch store.iCloudSyncStatus {
        case .synced: .green
        case .unavailable, .failed: .orange
        default: .secondary
        }
    }

    private func interfaceStateText(_ state: ReticulumTCPInterface.State) -> String {
        switch state {
        case .stopped: "Stopped"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .failed(let reason): "Unavailable · \(reason)"
        }
    }

    private func interfaceStateIcon(_ state: ReticulumTCPInterface.State) -> String {
        switch state {
        case .stopped: "circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func rnodeIcon(_ transport: RNodeTransportKind) -> String {
        switch transport {
        case .bluetoothLE: "wave.3.right"
        case .tcp: "wifi"
        case .serial: "cable.connector"
        case .simulated: "testtube.2"
        }
    }

    private func rnodeStateText(_ state: RNodeInterface.State) -> String {
        switch state {
        case .stopped: "Stopped"
        case .searching: "Searching"
        case .connecting: "Connecting"
        case .detecting: "Detecting"
        case .configuring: "Configuring"
        case .ready: "Radio ready"
        case .failed(let reason): "Unavailable · \(reason)"
        }
    }

    private func rnodeStateIcon(_ state: RNodeInterface.State) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .searching, .connecting, .detecting, .configuring: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        case .stopped: "circle"
        }
    }

    private func rnodeConfigurationSummary(_ configuration: RNodeConfiguration) -> String {
        let target = configuration.target.isEmpty ? "Any nearby RNode" : configuration.target
        let mhz = String(format: "%.4f", Double(configuration.frequency) / 1_000_000)
        return "\(configuration.transport.title) · \(target) · \(mhz) MHz · BW \(configuration.bandwidth) · SF\(configuration.spreadingFactor) · CR\(configuration.codingRate) · \(configuration.txPower) dBm"
    }

    private func pluginPermissionSummary(_ permissions: Set<SidebandPluginPermission>) -> String {
        guard !permissions.isEmpty else { return "Permissions: none" }
        let names = permissions.sorted { $0.rawValue < $1.rawValue }.map {
            switch $0 {
            case .networkStatus: "network status"
            case .conversationMetadata: "contact identifier"
            case .messageMetadata: "message metadata"
            case .telemetryRead: "telemetry summary"
            case .telemetryWrite: "telemetry provider"
            case .serviceLifecycle: "background service"
            }
        }
        return "Permissions: " + names.joined(separator: ", ")
    }

    private func pluginAuditIcon(_ outcome: SidebandPluginExecutionOutcome) -> String {
        switch outcome {
        case .succeeded: "checkmark.circle.fill"
        case .denied: "lock.fill"
        case .unavailable: "puzzlepiece.extension"
        case .failed: "exclamationmark.triangle.fill"
        case .timedOut: "clock.badge.exclamationmark"
        }
    }

    private func pluginAuditColor(_ outcome: SidebandPluginExecutionOutcome) -> Color {
        switch outcome {
        case .succeeded: .green
        case .denied: .orange
        case .unavailable: .secondary
        case .failed, .timedOut: .red
        }
    }
}

private struct SettingsDetailContainer<Content: View>: View {
    let destination: SettingsDestination
    @ViewBuilder let content: Content

    init(destination: SettingsDestination, @ViewBuilder content: () -> Content) {
        self.destination = destination
        self.content = content()
    }

    var body: some View {
        content
            .formStyle(.grouped)
            .navigationTitle(destination.title)
            #if os(macOS)
            .frame(minWidth: 580, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
            #endif
    }
}

private struct SettingsStatusSummary: View {
    @Bindable var store: SidebandStore
    var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if expanded {
                    Text(store.automaticConnectionDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network status: \(title). \(detail)")
    }

    private var title: String {
        switch store.networkState {
        case .ready: "Connected securely"
        case .connecting: "Connecting"
        case .failed: "Connection needs attention"
        case .stopped: "Offline"
        }
    }

    private var detail: String {
        switch store.networkState {
        case .ready:
            if let host = store.activeNetworkHost { "Reticulum is ready through \(host)." }
            else if store.rnodeManager.hasReadyInterface { "Reticulum is ready through an RNode radio." }
            else { "Reticulum is ready." }
        case .connecting: "Lower Sideband is finding the best available interface."
        case .failed(let reason): reason
        case .stopped: "Connect automatically or choose a connection in Settings."
        }
    }

    private var icon: String {
        switch store.networkState {
        case .ready: "checkmark.shield.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "network.slash"
        }
    }

    private var tint: Color {
        switch store.networkState {
        case .ready: .green
        case .connecting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

private struct SettingsStateRow: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        LabeledContent(title) {
            Label(value, systemImage: icon)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var monospaced = false

    var body: some View {
        LabeledContent(title) {
            TextField(prompt, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .settingsTextInputBehavior()
                .font(monospaced ? Font.callout.monospaced() : Font.body)
                .accessibilityLabel(title)
        }
    }
}

private extension View {
    @ViewBuilder
    func settingsTextInputBehavior() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    func settingsSheetsAndConfirmation(
        store: SidebandStore,
        editingRNode: Binding<RNodeConfiguration?>,
        confirmation: Binding<SettingsConfirmation?>,
        performConfirmation: @escaping () -> Void
    ) -> some View {
        sheet(item: editingRNode) { configuration in
            RNodeEditorView(configuration: configuration) { saved in
                Task {
                    do {
                        try await store.rnodeManager.upsert(saved)
                        editingRNode.wrappedValue = nil
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            } onCancel: {
                editingRNode.wrappedValue = nil
            }
        }
        .confirmationDialog(
            confirmation.wrappedValue?.title ?? "Confirm Action",
            isPresented: Binding(
                get: { confirmation.wrappedValue != nil },
                set: { if !$0 { confirmation.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = confirmation.wrappedValue {
                Button(pending.actionTitle, role: .destructive, action: performConfirmation)
            }
            Button("Cancel", role: .cancel) { confirmation.wrappedValue = nil }
        } message: {
            Text(confirmation.wrappedValue?.message ?? "")
        }
    }
}

private func settingsCopy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
