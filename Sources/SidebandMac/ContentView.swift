import SwiftUI

private extension Data {
    var sidebandHex: String { map { String(format: "%02x", $0) }.joined() }
}
import SidebandCore
import ReticulumKit
import UniformTypeIdentifiers
import ImageIO
import QuickLook
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
private typealias PlatformImage = NSImage
#else
import UIKit
@preconcurrency import AVFoundation
private typealias PlatformImage = UIImage
#endif

private func copyToSystemClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

private func paperMessageError(_ result: PaperMessageImportResult) -> String? {
    switch result {
    case .imported: nil
    case .duplicate: "This paper message has already been imported."
    case .notAddressedToThisIdentity: "This paper message was encrypted for a different LXMF identity."
    case .unknownSender: "The message decrypted, but its sender is unknown. Receive a validated announce from the sender, then scan it again."
    case .invalid: "The LXM link does not contain a valid encrypted LXMF paper message."
    }
}

private func appearanceColor(_ color: Conversation.AppearanceColor) -> Color {
    switch color {
    case .blue: .blue
    case .green: .green
    case .orange: .orange
    case .purple: .purple
    case .pink: .pink
    case .red: .red
    case .teal: .teal
    case .gray: .gray
    }
}

private extension View {
    @ViewBuilder
    func sidebandSidebarSizing() -> some View {
        #if os(macOS)
        navigationSplitViewColumnWidth(min: 310, ideal: 340, max: 440)
        #else
        self
        #endif
    }
}

private enum DiscoverySort: String, CaseIterable, Identifiable {
    case recent = "Most Recent"
    case hops = "Fewest Hops"
    case name = "Name"
    var id: Self { self }
}

private enum ConversationFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case pinned = "Pinned"
    case trusted = "Trusted"
    case muted = "Muted"
    case blocked = "Blocked"
    var id: Self { self }
}

private enum ConversationSort: String, CaseIterable, Identifiable {
    case activity = "Recent Activity"
    case name = "Name"
    case unread = "Unread First"
    var id: Self { self }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif
    @Bindable var store: SidebandStore
    @State private var showingNewConversation = false
    @State private var showingNetwork = false
    @State private var showingCallHistory = false
    @State private var showingNetworkMap = false
    @State private var showingSituationMap = false
    @State private var showingDeliveryActivity = false
    @State private var showingConversationOrganizer = false
    @State private var showingMeshTools = false
    @State private var conversationSearch = ""
    @State private var showingArchived = false
    @State private var conversationFilter: ConversationFilter = .all
    @State private var conversationSort: ConversationSort = .activity
    @State private var discoverySort: DiscoverySort = .recent
    @State private var renamingConversation: Conversation?
    @State private var renameDraft = ""
    @State private var notingConversation: Conversation?
    @State private var noteDraft = ""
    @State private var taggingConversation: Conversation?
    @State private var tagsDraft = ""
    @State private var deletingConversation: Conversation?
    @State private var clearingConversation: Conversation?
    @State private var clearingTelemetryConversation: Conversation?
    @State private var backupDocument = SnapshotBackupDocument(data: Data())
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var contactCollectionDocument = SnapshotBackupDocument(data: Data())
    @State private var showingContactCollectionExporter = false
    @State private var showingContactCollectionImporter = false
    @State private var showingConversationArchiveImporter = false
    @State private var showingLegacyDatabaseImporter = false
    @State private var pendingLegacyImportURL: URL?
    @State private var pendingLegacyImportPreview: LegacySidebandSQLiteImporter.Preview?
    @State private var legacyImportSelection = LegacySidebandSQLiteImporter.Selection.all
    @State private var legacyImportConflictPolicy = SidebandStore.LegacyImportConflictPolicy.mergeSafely
    @State private var showingLegacyMigrationCenter = false
    @State private var pendingRestoreData: Data?

    var body: some View {
        VStack(spacing: 0) {
            localIdentityBar
            NavigationSplitView {
                List(selection: $store.selectedConversationID) {
                    Section {
                        ForEach(filteredConversations) { conversation in
                            conversationRow(conversation)
                                .padding(.vertical, 4)
                                .tag(conversation.id)
                                .contextMenu { conversationMenu(conversation) }
                        }
                    } header: {
                        HStack {
                            Text("Conversations")
                            Spacer()
                            Button { showingNewConversation = true } label: {
                                Label("New", systemImage: "square.and.pencil")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                            .accessibilityLabel("New conversation")
                            .accessibilityHint("Start a conversation using an LXMF ID or contact link")
                            .help("Start a conversation using an LXMF ID or contact link (Command-N)")
                        }
                    }
                    if !filteredDiscoveries.isEmpty {
                        Section("Discovered") {
                            ForEach(filteredDiscoveries) { discovery in
                                discoveryRow(discovery)
                            }
                        }
                    }
                }
                .searchable(text: $conversationSearch, prompt: "Search conversations")
                .navigationTitle("Lower Sideband")
                .toolbar {
                    Button { showingNetwork = true } label: {
                        Label("Network Connections", systemImage: networkToolbarIcon)
                    }
                    .accessibilityIdentifier("network-connections-toolbar")
                    .accessibilityHint(networkToolbarHelp)
                    .help("Network Connections · \(networkToolbarLabel). \(networkToolbarHelp)")
                    Button(action: openAppSettings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("app-settings")
                    .help("Open Lower Sideband settings. Current network state: \(networkToolbarLabel). \(networkToolbarHelp)")
                    Button { showingSituationMap = true } label: {
                        Label("Situation map", systemImage: "map")
                    }.help("Show the latest trusted telemetry from every contact and any installed offline GeoJSON overlay")
                    Button { showingDeliveryActivity = true } label: {
                        Label("Delivery activity", systemImage: "checkmark.circle.badge.questionmark")
                    }
                    .help("Review queued, delivered and failed messages, delivery proofs, retries and active routes")
                    Button { showingConversationOrganizer = true } label: {
                        Label("Organize conversations", systemImage: "square.grid.2x2")
                    }
                    .help("Use smart collections, tags and bulk conversation actions")
                    Button { showingMeshTools = true } label: {
                        Label("Mesh tools", systemImage: "rectangle.3.group.bubble")
                    }
                    .help("Open Nomad pages, secure identity profiles and the LXST telephone")
                    Button {
                        #if os(macOS)
                        openWindow(id: "network-map")
                        #else
                        showingNetworkMap = true
                        #endif
                    } label: {
                        Label("Network map", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    #if os(macOS)
                    .help("Open the Reticulum network map in its own resizable, full-screen-capable window")
                    #else
                    .help("Visualise this Reticulum node, active interfaces, next-hop transports and observed destinations")
                    #endif
                    #if os(macOS)
                    Button { showingArchived.toggle() } label: {
                        Label(showingArchived ? "Hide archived conversations" : "Show archived conversations", systemImage: showingArchived ? "archivebox.fill" : "archivebox")
                    }
                    .help(showingArchived ? "Hide archived conversations" : "Show archived conversations")
                    Menu {
                        Picker("Filter", selection: $conversationFilter) {
                            ForEach(ConversationFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                        }
                        Picker("Sort", selection: $conversationSort) {
                            ForEach(ConversationSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
                        }
                        Divider()
                        Button("Mark All Read", systemImage: "envelope.open") { _ = store.markAllConversationsRead() }
                            .disabled(store.totalUnreadCount == 0)
                        Button("Archive Read Conversations", systemImage: "archivebox") { _ = store.archiveReadConversations() }
                        Button("Unarchive All", systemImage: "tray.and.arrow.up") { _ = store.unarchiveAllConversations() }
                            .disabled(!store.conversations.contains(where: \.isArchived))
                    } label: {
                        Label("Filter conversations", systemImage: conversationFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help("Filter, sort, or organize conversations")
                    Menu {
                        Picker("Discovery sorting", selection: $discoverySort) {
                            ForEach(DiscoverySort.allCases) { option in Text(option.rawValue).tag(option) }
                        }
                        Divider()
                        Menu("Remove stale discoveries") {
                            Button("Older than 1 day") { pruneDiscoveries(days: 1) }
                            Button("Older than 7 days") { pruneDiscoveries(days: 7) }
                            Button("Older than 30 days") { pruneDiscoveries(days: 30) }
                        }
                    } label: {
                        Label("Sort discoveries", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort discovered LXMF destinations")
                    Button(action: exportBackup) { Label("Export backup", systemImage: "externaldrive.badge.plus") }
                        .help("Export Lower Sideband backup")
                    Button { showingBackupImporter = true } label: { Label("Restore backup", systemImage: "externaldrive.badge.timemachine") }
                        .help("Restore Lower Sideband backup")
                    Menu {
                        Button(action: exportContacts) { Label("Export Contacts", systemImage: "person.2.badge.gearshape") }
                        Button { showingContactCollectionImporter = true } label: { Label("Import Contacts", systemImage: "person.crop.circle.badge.plus") }
                        Divider()
                        Button { showingConversationArchiveImporter = true } label: { Label("Import Conversation Archive", systemImage: "bubble.left.and.text.bubble.right") }
                        Button { showingLegacyDatabaseImporter = true } label: { Label("Import Python Sideband Database", systemImage: "cylinder.split.1x2") }
                        Button("Undo Last Python Import", systemImage: "arrow.uturn.backward.circle") {
                            rollbackLegacyImport()
                        }
                        .disabled(!store.canRollbackLegacyImport)
                    } label: { Label("Contacts", systemImage: "person.2") }
                    .help("Import contacts or conversation archives")
                    #else
                    Menu {
                        Section("Conversations") {
                            Picker("Filter", selection: $conversationFilter) {
                                ForEach(ConversationFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                            }
                            Picker("Sort", selection: $conversationSort) {
                                ForEach(ConversationSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
                            }
                            Button(showingArchived ? "Hide Archived" : "Show Archived", systemImage: showingArchived ? "archivebox.fill" : "archivebox") {
                                showingArchived.toggle()
                            }
                            Button("Mark All Read", systemImage: "envelope.open") { _ = store.markAllConversationsRead() }
                                .disabled(store.totalUnreadCount == 0)
                        }
                        Section("Data") {
                            Button(action: exportBackup) { Label("Export Backup", systemImage: "externaldrive.badge.plus") }
                            Button { showingBackupImporter = true } label: { Label("Restore Backup", systemImage: "externaldrive.badge.timemachine") }
                            Button(action: exportContacts) { Label("Export Contacts", systemImage: "person.2.badge.gearshape") }
                            Button { showingContactCollectionImporter = true } label: { Label("Import Contacts", systemImage: "person.crop.circle.badge.plus") }
                            Button { showingConversationArchiveImporter = true } label: { Label("Import Conversation Archive", systemImage: "bubble.left.and.text.bubble.right") }
                            Button { showingLegacyDatabaseImporter = true } label: { Label("Import Python Sideband Database", systemImage: "cylinder.split.1x2") }
                            Button("Undo Last Python Import", systemImage: "arrow.uturn.backward.circle") {
                                rollbackLegacyImport()
                            }
                            .disabled(!store.canRollbackLegacyImport)
                        }
                    } label: {
                        Label("More actions", systemImage: "ellipsis.circle")
                    }
                    .help("Filter conversations or manage app data")
                    #endif
                    Button(action: { showingNewConversation = true }) { Label("New conversation", systemImage: "square.and.pencil") }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("Start a conversation using an LXMF destination address or contact link")
                        .accessibilityIdentifier("new-conversation")
                }
                .sidebandSidebarSizing()
            } detail: {
                if let conversation = store.selectedConversation {
                    ConversationView(store: store, conversation: conversation)
                        .id(conversation.id)
                } else {
                    ContentUnavailableView {
                        Label("No Conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a secure conversation using an LXMF ID or contact link.")
                    } actions: {
                        Button("New Conversation", systemImage: "square.and.pencil") {
                            showingNewConversation = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewConversation) { NewConversationView(store: store) }
        .sheet(isPresented: $showingNetwork) { NetworkView(store: store) }
        .sheet(isPresented: $showingDeliveryActivity) { DeliveryActivityView(store: store) }
        .sheet(isPresented: $showingConversationOrganizer) { ConversationOrganizerView(store: store) }
        .sheet(isPresented: $showingMeshTools) { MeshChatFeatureCenterView(store: store) }
        .sheet(isPresented: $showingCallHistory) { CallHistoryView(store: store) }
        #if os(macOS)
        .sheet(isPresented: $showingNetworkMap) { NetworkMapView(store: store) }
        #else
        .fullScreenCover(isPresented: $showingNetworkMap) { NetworkMapView(store: store) }
        #endif
        .sheet(isPresented: $showingSituationMap) { SituationMapView(store: store) }
        .sheet(isPresented: Binding(
            get: { store.voiceCall != nil },
            set: { presented in if !presented, store.voiceCall != nil { endVoiceCall() } }
        )) { VoiceCallView(store: store) }
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument, contentType: .json, defaultFilename: "Lower-Sideband-Backup") { result in
            if case let .failure(error) = result { store.lastError = "Could not export backup: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { prepareRestore(from: url) }
            if case let .failure(error) = result { store.lastError = "Could not open backup: \(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $showingContactCollectionExporter, document: contactCollectionDocument, contentType: .json, defaultFilename: "Lower-Sideband-Contacts") { result in
            if case let .failure(error) = result { store.lastError = "Could not export contacts: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showingContactCollectionImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importContacts(from: url)
            case .failure(let error): store.lastError = "Could not open contacts: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showingConversationArchiveImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importConversationArchive(from: url)
            case .failure(let error): store.lastError = "Could not open conversation archive: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showingLegacyDatabaseImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): prepareLegacyDatabaseImport(from: url)
            case .failure(let error): store.lastError = "Could not open legacy database: \(error.localizedDescription)"
            }
        }
        .alert("Lower Sideband", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })) {
            Button("OK") { store.clearError() }
        } message: { Text(store.lastError ?? "") }
        .alert("Rename Conversation", isPresented: Binding(get: { renamingConversation != nil }, set: { if !$0 { renamingConversation = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingConversation = nil }
            Button("Save") {
                if let id = renamingConversation?.id { _ = store.renameConversation(id, to: renameDraft) }
                renamingConversation = nil
            }
        }
        .alert("Contact Note", isPresented: Binding(get: { notingConversation != nil }, set: { if !$0 { notingConversation = nil } })) {
            TextField("Private note", text: $noteDraft)
            Button("Cancel", role: .cancel) { notingConversation = nil }
            Button("Save") {
                if let conversation = notingConversation {
                    store.setConversationAppearance(conversationID: conversation.id, note: noteDraft, color: conversation.appearanceColor, symbol: conversation.appearanceSymbol)
                }
                notingConversation = nil
            }
        } message: {
            Text("This note stays in your encrypted Lower Sideband data and is never sent in messages or announces.")
        }
        .alert("Contact Tags", isPresented: Binding(get: { taggingConversation != nil }, set: { if !$0 { taggingConversation = nil } })) {
            TextField("team, field, priority", text: $tagsDraft)
            Button("Cancel", role: .cancel) { taggingConversation = nil }
            Button("Save") {
                if let id = taggingConversation?.id { store.setConversationTags(tagsDraft.split(separator: ",").map(String.init), conversationID: id) }
                taggingConversation = nil
            }
        } message: { Text("Enter up to eight comma-separated tags. Tags stay in your encrypted Lower Sideband data.") }
        .alert("Delete Conversation?", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } })) {
            Button("Cancel", role: .cancel) { deletingConversation = nil }
            Button("Delete", role: .destructive) {
                if let id = deletingConversation?.id { Task { await store.deleteConversation(id) } }
                deletingConversation = nil
            }
        } message: {
            Text("This removes the conversation and its locally stored messages and attachments.")
        }
        .alert("Clear Conversation History?", isPresented: Binding(get: { clearingConversation != nil }, set: { if !$0 { clearingConversation = nil } })) {
            Button("Cancel", role: .cancel) { clearingConversation = nil }
            Button("Clear", role: .destructive) {
                if let id = clearingConversation?.id { Task { await store.clearConversationHistory(id) } }
                clearingConversation = nil
            }
        } message: {
            Text("This permanently removes locally stored messages and attachments while keeping the contact.")
        }
        .alert("Clear Telemetry History?", isPresented: Binding(get: { clearingTelemetryConversation != nil }, set: { if !$0 { clearingTelemetryConversation = nil } })) {
            Button("Cancel", role: .cancel) { clearingTelemetryConversation = nil }
            Button("Clear Telemetry", role: .destructive) {
                if let id = clearingTelemetryConversation?.id { _ = store.clearTelemetryHistory(id) }
                clearingTelemetryConversation = nil
            }
        } message: {
            Text("This removes stored location and battery readings from this conversation while retaining its messages and attachments.")
        }
        .alert("Restore Lower Sideband Backup?", isPresented: Binding(get: { pendingRestoreData != nil }, set: { if !$0 { pendingRestoreData = nil } })) {
            Button("Cancel", role: .cancel) { pendingRestoreData = nil }
            Button("Restore", role: .destructive) {
                if let data = pendingRestoreData {
                    do { try store.restoreSnapshotData(data) }
                    catch { store.lastError = "Could not restore backup: \(error.localizedDescription)" }
                }
                pendingRestoreData = nil
            }
        } message: {
            Text("Current conversations, messages, discoveries, and drafts will be replaced with the validated backup contents.")
        }
        .sheet(isPresented: $showingLegacyMigrationCenter, onDismiss: {
            pendingLegacyImportPreview = nil
            pendingLegacyImportURL = nil
        }) {
            if let preview = pendingLegacyImportPreview {
                LegacyMigrationCenterView(
                    preview: preview,
                    selection: $legacyImportSelection,
                    conflictPolicy: $legacyImportConflictPolicy,
                    onCancel: { showingLegacyMigrationCenter = false },
                    onImport: {
                        if let url = pendingLegacyImportURL { importLegacyDatabase(from: url) }
                        showingLegacyMigrationCenter = false
                    }
                )
            }
        }
        .task {
            #if os(iOS)
            CallKitCoordinator.shared.install(store: store)
            synchronizeCallKit(store.voiceCall)
            #endif
            DeliverySoakRunner.configureNetworkIfRequested(store)
            await store.startTransport()
            let startedSoakNetwork = await DeliverySoakRunner.startNetworkIfRequested(store)
            if !startedSoakNetwork, store.autoConnectEnabled { await store.startAutomaticConnection() }
            if store.autoInterfaceEnabled { store.startAutoInterfaceDiscovery() }
            if store.iCloudSyncEnabled { await store.syncICloudNow() }
            await DeliverySoakRunner.runIfRequested(store)
        }
        .onOpenURL { url in
            if store.handleServiceURL(url) {
                showingMeshTools = true
            } else if url.scheme?.lowercased() == LXMURI.scheme {
                let result = store.ingestPaperMessageURI(url.absoluteString)
                if let error = paperMessageError(result) { store.lastError = error }
            } else {
                _ = store.openContactLink(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await store.applicationDidBecomeActive() }
            case .background: store.applicationDidEnterBackground()
            case .inactive: store.applicationDidBecomeInactive()
            @unknown default: break
            }
        }
        .onChange(of: store.voiceCall) { _, call in synchronizeCallKit(call) }
    }

    private func openAppSettings() {
        #if os(macOS)
        openSettings()
        #else
        showingNetwork = true
        #endif
    }

    private func synchronizeCallKit(_ call: VoiceCall?) {
        #if os(iOS)
        let name = call.flatMap { activeCall in store.conversations.first { $0.id == activeCall.conversationID }?.displayName }
        CallKitCoordinator.shared.synchronize(call: call, displayName: name)
        #endif
    }

    private func endVoiceCall() {
        #if os(iOS)
        CallKitCoordinator.shared.requestEnd()
        #else
        Task { await store.hangUpVoiceCall() }
        #endif
    }

    private var networkToolbarLabel: String {
        switch store.networkState {
        case .ready: "Online · \(store.knownPathCount) paths"
        case .connecting: "Connecting"
        case .failed: "Network error"
        case .stopped: "Offline"
        }
    }

    private var networkToolbarHelp: String {
        switch store.networkState {
        case .ready:
            return "Reticulum is online with \(store.knownPathCount) known path\(store.knownPathCount == 1 ? "" : "s"). Open Network Status for active TCP, AutoInterface and RNode connections."
        case .connecting:
            return "Reticulum is connecting automatically. Open Network Status to see the current discovery and fallback stage."
        case .failed(let reason):
            return "Reticulum connection needs attention: \(reason). Open Network Status for diagnostics and retry controls."
        case .stopped:
            return "Reticulum is offline. Open Network Status to connect or configure automatic discovery."
        }
    }

    private var missedCallCount: Int {
        store.voiceCallHistory.count { $0.historyOutcome == .missed }
    }

    private var localIdentityBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeIdentityProfile?.name ?? "My LXMF ID")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.localDeliveryHash)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
                    .help("Your current LXMF delivery destination: \(store.localDeliveryHash)")
                    .accessibilityLabel("Current LXMF ID \\(store.localDeliveryHash)")
            }
            Spacer(minLength: 4)
            Button {
                showingNetwork = true
            } label: {
                if horizontalSizeClass == .compact {
                    Image(systemName: networkToolbarIcon)
                } else {
                    Label("Connections", systemImage: networkToolbarIcon)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .layoutPriority(2)
            .accessibilityIdentifier("network-connections")
            .accessibilityLabel("Network Connections, \(networkToolbarLabel)")
            .accessibilityHint(networkToolbarHelp)
            .help("Network Connections · \(networkToolbarLabel). \(networkToolbarHelp)")
            Menu {
                Button("Network Connections", systemImage: networkToolbarIcon) { showingNetwork = true }
                Button("Settings", systemImage: "gearshape", action: openAppSettings)
                Divider()
                Button("New Conversation", systemImage: "square.and.pencil") { showingNewConversation = true }
                Button("Delivery Activity", systemImage: "checkmark.circle.badge.questionmark") { showingDeliveryActivity = true }
                Button("Organize Conversations", systemImage: "square.grid.2x2") { showingConversationOrganizer = true }
                Divider()
                Button("Situation Map", systemImage: "map") { showingSituationMap = true }
                Button("Reticulum Network Map", systemImage: "point.3.connected.trianglepath.dotted") {
                    #if os(macOS)
                    openWindow(id: "network-map")
                    #else
                    showingNetworkMap = true
                    #endif
                }
                Button("Mesh Tools", systemImage: "rectangle.3.group.bubble") { showingMeshTools = true }
                Button("Identity Profiles", systemImage: "person.2.badge.key") { showingMeshTools = true }
                Button("Call History", systemImage: "phone.badge.clock") { showingCallHistory = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("all-features")
            .accessibilityLabel("All Features")
            .accessibilityHint("Open every major Lower Sideband feature from one menu")
            .help("All Features · Network, maps, messaging, identities, calls and settings")
            Button {
                showingMeshTools = true
            } label: {
                Image(systemName: "person.2.badge.key")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Manage secure identities. Current profile: \(store.activeIdentityProfile?.name ?? "Default")")
            .accessibilityLabel("Manage identity profiles")
            Button {
                showingCallHistory = true
            } label: {
                Image(systemName: "phone.badge.clock")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .layoutPriority(1)
            .help(missedCallCount > 0 ? "Call history · \(missedCallCount) missed" : "Call history")
            .accessibilityLabel(missedCallCount > 0 ? "Call history, \(missedCallCount) missed" : "Call history")
            Button {
                copyToSystemClipboard(store.localDeliveryHash)
            } label: {
                if horizontalSizeClass == .compact {
                    Image(systemName: "doc.on.doc")
                } else {
                    Label("Copy ID", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .layoutPriority(1)
            .help("Copy current LXMF ID")
            .accessibilityLabel("Copy current LXMF ID")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func exportBackup() {
        do {
            backupDocument = SnapshotBackupDocument(data: try store.exportSnapshotData())
            showingBackupExporter = true
        } catch {
            store.lastError = "Could not prepare backup: \(error.localizedDescription)"
        }
    }

    private func exportContacts() {
        do {
            contactCollectionDocument = SnapshotBackupDocument(data: try store.exportContactCollectionData())
            showingContactCollectionExporter = true
        } catch {
            store.lastError = "Could not prepare contacts: \(error.localizedDescription)"
        }
    }

    private func importContacts(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try store.importContactCollectionData(Data(contentsOf: url))
            store.lastError = "Imported \(count) contact\(count == 1 ? "" : "s"). Re-verify fingerprints after transferring contacts."
        } catch {
            store.lastError = "Could not import contacts: \(error.localizedDescription)"
        }
    }

    private func importConversationArchive(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try store.importConversationData(Data(contentsOf: url))
            store.lastError = count == 0 ? "The conversation archive contained no new messages." : "Imported \(count) archived message\(count == 1 ? "" : "s"). Attachment metadata was retained, but archive files do not contain attachment payloads."
        } catch {
            store.lastError = "Could not import conversation archive: \(error.localizedDescription)"
        }
    }

    private func importLegacyDatabase(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let report = try store.importLegacySidebandDatabase(
                at: url,
                selection: legacyImportSelection,
                conflictPolicy: legacyImportConflictPolicy
            )
            let conversationCount = report.snapshot.conversations.count
            let messageCount = report.snapshot.messages.count
            let warningSummary = report.warnings.isEmpty ? "" : " \(report.warnings.joined(separator: " "))"
            store.lastError = "Imported \(conversationCount) conversation\(conversationCount == 1 ? "" : "s"), \(messageCount) message\(messageCount == 1 ? "" : "s") (\(report.importedRichMessages) with rich LXMF fields), \(report.importedTelemetry) telemetry record\(report.importedTelemetry == 1 ? "" : "s") and \(report.importedAnnounces) announce\(report.importedAnnounces == 1 ? "" : "s") from the read-only Python database.\(warningSummary)"
        } catch {
            store.lastError = "Could not import Python Sideband database: \(error.localizedDescription)"
        }
    }

    private func prepareLegacyDatabaseImport(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            pendingLegacyImportPreview = try store.previewLegacySidebandDatabase(at: url)
            pendingLegacyImportURL = url
            legacyImportSelection = .all
            legacyImportConflictPolicy = .mergeSafely
            showingLegacyMigrationCenter = true
        } catch {
            store.lastError = "Could not inspect Python Sideband database: \(error.localizedDescription)"
        }
    }

private struct LegacyMigrationCenterView: View {
    let preview: LegacySidebandSQLiteImporter.Preview
    @Binding var selection: LegacySidebandSQLiteImporter.Selection
    @Binding var conflictPolicy: SidebandStore.LegacyImportConflictPolicy
    let onCancel: () -> Void
    let onImport: () -> Void
    @State private var searchText = ""

    private var selectedDestinations: Set<String> {
        selection.selectedDestinations ?? Set(preview.conversationCandidates.map(\.destinationHash))
    }

    private var filteredCandidates: [LegacySidebandSQLiteImporter.ConversationCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return preview.conversationCandidates }
        return preview.conversationCandidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.destinationHash.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Source validation") {
                    LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: Int64(preview.sourceBytes), countStyle: .file))
                    LabeledContent("Supported tables", value: preview.availableTables.joined(separator: ", "))
                    Label("Opened read-only; the source file will not be modified", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
                Section("Content") {
                    Toggle("Messages (\(preview.messages.formatted()))", isOn: $selection.includesMessages)
                    Toggle("Telemetry (\(preview.telemetryRecords.formatted()))", isOn: $selection.includesTelemetry)
                        .disabled(!selection.includesMessages)
                    Toggle("Announces (\(preview.announces.formatted()))", isOn: $selection.includesAnnounces)
                }
                Section("Conflict handling") {
                    Picker("Existing conversations", selection: $conflictPolicy) {
                        ForEach(SidebandStore.LegacyImportConflictPolicy.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    Text(conflictPolicy == .mergeSafely
                         ? "Existing data is retained and imported history is deduplicated."
                         : "Any destination already present in Lower Sideband is skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Select All") { selection.selectedDestinations = nil }
                        Button("Select None") { selection.selectedDestinations = [] }
                        Spacer()
                        Text("\(selectedDestinations.count) selected").foregroundStyle(.secondary)
                    }
                    ForEach(filteredCandidates) { candidate in
                        Toggle(isOn: Binding(
                            get: { selectedDestinations.contains(candidate.destinationHash) },
                            set: { selected in
                                var values = selectedDestinations
                                if selected { values.insert(candidate.destinationHash) }
                                else { values.remove(candidate.destinationHash) }
                                selection.selectedDestinations = values
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(candidate.displayName)
                                Text(candidate.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Conversations")
                }
            }
            .searchable(text: $searchText, prompt: "Search imported conversations")
            .navigationTitle("Migration & Restore")
            .accessibilityIdentifier("legacy-migration-centre")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport).disabled(selectedDestinations.isEmpty)
                        .accessibilityIdentifier("legacy-migration-import")
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #else
        .presentationDetents([.large])
        #endif
    }
}

    private func rollbackLegacyImport() {
        do {
            if try store.rollbackLastLegacyImport() {
                store.lastError = "The last Python Sideband import was undone."
            }
        } catch {
            store.lastError = "Could not undo the Python Sideband import: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private func conversationRow(_ conversation: Conversation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: conversation.appearanceSymbol.rawValue)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(appearanceColor(conversation.appearanceColor), in: Circle())
                .accessibilityLabel("\(conversation.appearanceColor.rawValue) \(conversation.appearanceSymbol.rawValue) contact icon")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(2)
                    Spacer(minLength: 4)
                    let failedCount = store.failedMessageCount(for: conversation.id)
                    if failedCount > 0 {
                        Label(String(failedCount), systemImage: "exclamationmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                            .accessibilityLabel("\(failedCount) failed messages")
                    }
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount, format: .number)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .accessibilityLabel("\(conversation.unreadCount) unread messages")
                    }
                }
                HStack(spacing: 6) {
                    Text(conversation.destinationHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if conversation.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                    if conversation.isArchived { Image(systemName: "archivebox.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Archived") }
                    if conversation.notificationsMuted { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Notifications muted") }
                    if conversation.isBlocked { Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.red).accessibilityLabel("Blocked") }
                    Image(systemName: sidebarRouteIcon(for: conversation))
                        .font(.caption)
                        .foregroundStyle(sidebarRouteColor(for: conversation))
                        .accessibilityLabel(sidebarRouteLabel(for: conversation))
                    if conversation.isTrusted {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).accessibilityLabel("Trusted contact")
                    }
                    if store.isConversationIdentityVerified(conversation.id) {
                        Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.green).accessibilityLabel("Identity fingerprint verified")
                    }
                    if let message = store.latestMessage(for: conversation.id) {
                        if message.direction == .outgoing {
                            Image(systemName: deliveryStateIcon(message.state))
                                .font(.caption2)
                                .foregroundStyle(message.state == .failed ? .red : .secondary)
                                .accessibilityLabel("Latest message \(message.state.rawValue)")
                        }
                        Text(message.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !conversation.tags.isEmpty {
                    Text(conversation.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel("Tags: \(conversation.tags.joined(separator: ", "))")
                }
                if !store.draft(for: conversation.id).isEmpty {
                    Text("Draft: \(store.draft(for: conversation.id))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let message = store.latestMessage(for: conversation.id) {
                    Text(messagePreview(message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !conversation.contactNote.isEmpty {
                    Text(conversation.contactNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(conversationAccessibilityLabel(conversation))
        .accessibilityHint("Opens this encrypted conversation")
        .accessibilityAction(named: conversation.unreadCount > 0 ? "Mark Read" : "Mark Unread") {
            if conversation.unreadCount > 0 {
                store.markConversationRead(conversation.id)
            } else {
                store.markConversationUnread(conversation.id)
            }
        }
        .accessibilityAction(named: conversation.isPinned ? "Unpin Conversation" : "Pin Conversation") {
            store.setConversationPinned(!conversation.isPinned, conversationID: conversation.id)
        }
        .accessibilityAction(named: conversation.isArchived ? "Unarchive Conversation" : "Archive Conversation") {
            store.setConversationArchived(!conversation.isArchived, conversationID: conversation.id)
        }
        .accessibilityIdentifier("conversation-\(conversation.id.uuidString)")
        .help(conversationHoverHelp(conversation))
    }

    private func conversationAccessibilityLabel(_ conversation: Conversation) -> String {
        var parts = [conversation.displayName]
        if conversation.unreadCount > 0 {
            parts.append(String(localized: "\(conversation.unreadCount) unread messages"))
        }
        if let message = store.latestMessage(for: conversation.id) {
            parts.append(message.direction == .incoming
                ? String(localized: "Latest incoming message: \(messagePreview(message))")
                : String(localized: "Latest outgoing message: \(messagePreview(message))"))
            parts.append(message.state.rawValue)
        }
        if conversation.isPinned { parts.append(String(localized: "Pinned")) }
        if conversation.notificationsMuted { parts.append(String(localized: "Notifications muted")) }
        if conversation.isBlocked { parts.append(String(localized: "Blocked")) }
        parts.append(sidebarRouteLabel(for: conversation))
        return parts.joined(separator: ". ")
    }

    @ViewBuilder private func discoveryRow(_ discovery: DiscoveredDestination) -> some View {
        Button { startConversation(with: discovery) } label: {
            DiscoveredDestinationRow(discovery: discovery)
        }
        .buttonStyle(.plain)
        .help("\(discovery.announcedDisplayName ?? discovery.destinationHash) — \(discovery.hops) hop\(discovery.hops == 1 ? "" : "s"), \(discovery.isValidated ? "cryptographically validated" : "not yet validated"), last seen \(discovery.lastSeen.formatted(date: .omitted, time: .standard)). Select to start or open a conversation.")
        .contextMenu {
            Button { copyToSystemClipboard(discovery.destinationHash) } label: { Label("Copy Destination", systemImage: "number") }
            if let contactLink = SidebandContactLink(destinationHash: discovery.destinationHash, displayName: discovery.announcedDisplayName, publicKey: discovery.isValidated ? discovery.publicKey : nil) {
                Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: { Label("Copy Contact Link", systemImage: "link") }
                ShareLink(item: contactLink.url) { Label("Share Contact Link", systemImage: "square.and.arrow.up") }
            }
            Button { startConversation(with: discovery) } label: { Label("Start Conversation", systemImage: "message") }
            if !store.conversations.contains(where: { $0.destinationHash == discovery.destinationHash }) {
                Button(role: .destructive) { _ = store.forgetDiscovery(discovery.destinationHash) } label: {
                    Label("Forget Discovery", systemImage: "trash")
                }
            }
        }
    }

    private func pruneDiscoveries(days: Double) {
        let removed = store.pruneDiscoveries(olderThan: days * 24 * 60 * 60)
        if removed == 0 { store.lastError = "No unreferenced discoveries were old enough to remove." }
    }

    private func startConversation(with discovery: DiscoveredDestination) {
        conversationSearch = ""
        showingArchived = false
        guard store.addConversation(from: discovery),
              let conversationID = store.conversations.first(where: { $0.destinationHash == discovery.destinationHash.lowercased() })?.id else { return }
        Task { @MainActor in
            await Task.yield()
            store.selectedConversationID = conversationID
        }
    }

    @ViewBuilder private func conversationMenu(_ conversation: Conversation) -> some View {
        Button { copyToSystemClipboard(conversation.destinationHash) } label: { Label("Copy Destination", systemImage: "number") }
        if let contactLink = store.contactLink(for: conversation.id) {
            Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: { Label("Copy Contact Link", systemImage: "link") }
        }
        if let contactCard = store.conversationContactCard(conversation.id) {
            ShareLink(item: contactCard, subject: Text("Lower Sideband contact: \(conversation.displayName)")) {
                Label("Share Contact", systemImage: "person.crop.circle.badge.plus")
            }
        }
        if let diagnostics = store.conversationDeliveryDiagnostics(conversation.id) {
            Button { copyToSystemClipboard(diagnostics) } label: { Label("Copy Delivery Diagnostics", systemImage: "stethoscope") }
        }
        Button { renameDraft = conversation.displayName; renamingConversation = conversation } label: { Label("Rename", systemImage: "pencil") }
        Button { noteDraft = conversation.contactNote; notingConversation = conversation } label: { Label("Edit Private Note", systemImage: "note.text") }
        Button { tagsDraft = conversation.tags.joined(separator: ", "); taggingConversation = conversation } label: { Label("Edit Tags", systemImage: "tag") }
        Menu("Contact Icon", systemImage: conversation.appearanceSymbol.rawValue) {
            ForEach(Conversation.AppearanceSymbol.allCases, id: \.self) { symbol in
                Button {
                    store.setConversationAppearance(conversationID: conversation.id, note: conversation.contactNote, color: conversation.appearanceColor, symbol: symbol)
                } label: {
                    Label(symbolLabel(symbol), systemImage: symbol.rawValue)
                }
            }
        }
        Menu("Contact Color", systemImage: "paintpalette") {
            ForEach(Conversation.AppearanceColor.allCases, id: \.self) { color in
                Button(color.rawValue.capitalized) {
                    store.setConversationAppearance(conversationID: conversation.id, note: conversation.contactNote, color: color, symbol: conversation.appearanceSymbol)
                }
            }
        }
        Button { store.setConversationTrusted(!conversation.isTrusted, conversationID: conversation.id) } label: {
            Label(conversation.isTrusted ? "Remove Trust" : "Mark as Trusted", systemImage: conversation.isTrusted ? "shield.slash" : "checkmark.shield")
        }
        Button { store.setConversationPinned(!conversation.isPinned, conversationID: conversation.id) } label: {
            Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
        }
        Button {
            store.setConversationArchived(!conversation.isArchived, conversationID: conversation.id)
            if !showingArchived && !conversation.isArchived { store.selectedConversationID = store.conversations.first(where: { !$0.isArchived })?.id }
        } label: { Label(conversation.isArchived ? "Unarchive" : "Archive", systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox") }
        Button {
            if conversation.unreadCount > 0 { store.markConversationRead(conversation.id) }
            else { store.markConversationUnread(conversation.id) }
        } label: { Label(conversation.unreadCount > 0 ? "Mark as Read" : "Mark as Unread", systemImage: conversation.unreadCount > 0 ? "envelope.open" : "envelope.badge") }
        Button { store.setConversationNotificationsMuted(!conversation.notificationsMuted, conversationID: conversation.id) } label: {
            Label(conversation.notificationsMuted ? "Unmute Notifications" : "Mute Notifications", systemImage: conversation.notificationsMuted ? "bell" : "bell.slash")
        }
        Menu("Notification Preview", systemImage: "eye") {
            Button("Use Global Setting") { store.setConversationNotificationPreview(nil, conversationID: conversation.id) }
            Button("Always Show Preview") { store.setConversationNotificationPreview(true, conversationID: conversation.id) }
            Button("Always Hide Preview") { store.setConversationNotificationPreview(false, conversationID: conversation.id) }
        }
        Button { store.setConversationTelemetrySharing(!conversation.telemetrySharingEnabled, conversationID: conversation.id) } label: {
            Label(conversation.telemetrySharingEnabled ? "Disable Telemetry Sharing" : "Enable Telemetry Sharing", systemImage: conversation.telemetrySharingEnabled ? "location.slash" : "location")
        }
        Button { store.setConversationPluginCommands(!conversation.pluginCommandsEnabled, conversationID: conversation.id) } label: {
            Label(conversation.pluginCommandsEnabled ? "Disable Plugin Requests" : "Allow Plugin Requests", systemImage: conversation.pluginCommandsEnabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
        }
        .disabled(!conversation.isTrusted || !store.isConversationIdentityVerified(conversation.id))
        Button {
            let preference: Conversation.DeliveryPreference = conversation.deliveryPreference == .automatic ? .propagationPreferred : .automatic
            store.setConversationDeliveryPreference(preference, conversationID: conversation.id)
        } label: {
            Label(
                conversation.deliveryPreference == .propagationPreferred ? "Use Automatic Delivery" : "Prefer Propagation Node",
                systemImage: conversation.deliveryPreference == .propagationPreferred ? "arrow.triangle.branch" : "shippingbox"
            )
        }
        Button { store.setConversationBlocked(!conversation.isBlocked, conversationID: conversation.id) } label: {
            Label(conversation.isBlocked ? "Unblock Contact" : "Block Contact", systemImage: conversation.isBlocked ? "hand.raised.slash" : "hand.raised")
        }
        if let reportURL = SidebandSafetyReport.emailURL(for: conversation) {
            Link(destination: reportURL) {
                Label("Report Contact", systemImage: "exclamationmark.bubble")
            }
        }
        Button { Task { await store.requestPath(to: conversation.destinationHash) } } label: {
            Label(store.isPathPending(to: conversation.destinationHash) ? "Finding Route" : "Request Path", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(store.networkState != .ready || store.isPathPending(to: conversation.destinationHash))
        Button { Task { await store.requestLink(to: conversation.destinationHash) } } label: {
            Label(store.activeLinkHashes.contains(conversation.destinationHash) ? "Encrypted Link Active" : (store.pendingLinkHashes.contains(conversation.destinationHash) ? "Establishing Link" : "Establish Encrypted Link"), systemImage: "lock.shield")
        }
        .disabled(!store.hasPath(to: conversation.destinationHash) || store.activeLinkHashes.contains(conversation.destinationHash) || store.pendingLinkHashes.contains(conversation.destinationHash))
        if store.failedMessageCount(for: conversation.id) > 0 {
            Button { Task { await store.retryAllFailedMessages(in: conversation.id) } } label: { Label("Retry All Failed", systemImage: "arrow.clockwise") }
        }
        if store.telemetryMessageCount(for: conversation.id) > 0 {
            Button(role: .destructive) { clearingTelemetryConversation = conversation } label: {
                Label("Clear Telemetry History", systemImage: "location.slash")
            }
        }
        Button(role: .destructive) { clearingConversation = conversation } label: { Label("Clear History", systemImage: "eraser") }
        Button(role: .destructive) { deletingConversation = conversation } label: { Label("Delete Conversation", systemImage: "trash") }
    }

    private func symbolLabel(_ symbol: Conversation.AppearanceSymbol) -> String {
        switch symbol {
        case .person: "Person"
        case .radio: "Radio"
        case .antenna: "Antenna"
        case .vehicle: "Vehicle"
        case .home: "Home"
        case .favorite: "Favorite"
        case .team: "Team"
        case .work: "Work"
        }
    }

    private func prepareRestore(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try store.validatedSnapshot(from: data)
            pendingRestoreData = data
        } catch {
            store.lastError = "Could not validate backup: \(error.localizedDescription)"
        }
    }

    private var filteredConversations: [Conversation] {
        let query = conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        var visible = store.conversations.filter { conversation in
            guard showingArchived || !conversation.isArchived else { return false }
            switch conversationFilter {
            case .all: return true
            case .unread: return conversation.unreadCount > 0
            case .pinned: return conversation.isPinned
            case .trusted: return conversation.isTrusted
            case .muted: return conversation.notificationsMuted
            case .blocked: return conversation.isBlocked
            }
        }
        if !query.isEmpty {
            visible = visible.filter { store.conversationMatchesSearch($0.id, query: query) }
        }
        return visible.sorted { left, right in
            if left.isPinned != right.isPinned { return left.isPinned }
            switch conversationSort {
            case .activity:
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            case .name:
                let order = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            case .unread:
                if left.unreadCount != right.unreadCount { return left.unreadCount > right.unreadCount }
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            }
            return left.destinationHash < right.destinationHash
        }
    }

    private var filteredDiscoveries: [DiscoveredDestination] {
        let query = conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversationFilter == .unread { return [] }
        let messageDestinations = store.discoveries.filter { !$0.isLXSTVoiceDestination }
        let matching = query.isEmpty ? messageDestinations : messageDestinations.filter {
            $0.destinationHash.localizedCaseInsensitiveContains(query)
                || ($0.announcedDisplayName?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return matching.sorted { left, right in
            switch discoverySort {
            case .recent:
                if left.lastSeen != right.lastSeen { return left.lastSeen > right.lastSeen }
            case .hops:
                if left.hops != right.hops { return left.hops < right.hops }
                if left.lastSeen != right.lastSeen { return left.lastSeen > right.lastSeen }
            case .name:
                let leftName = left.announcedDisplayName ?? left.destinationHash
                let rightName = right.announcedDisplayName ?? right.destinationHash
                let order = leftName.localizedCaseInsensitiveCompare(rightName)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return left.destinationHash < right.destinationHash
        }
    }

    private func messagePreview(_ message: Message) -> String {
        if !message.body.isEmpty { return message.body }
        if message.voiceAudio != nil { return "Voice message" }
        if message.telemetry?.location != nil { return "Location telemetry" }
        if message.attachments.count == 1, let attachment = message.attachments.first { return "Attachment: \(attachment.filename)" }
        return "\(message.attachments.count) attachments"
    }

    private func deliveryStateIcon(_ state: Message.DeliveryState) -> String {
        switch state {
        case .queued: "clock"
        case .sent: "checkmark"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func sidebarRouteIcon(for conversation: Conversation) -> String {
        if store.activeLinkHashes.contains(conversation.destinationHash) { return "lock.shield.fill" }
        if store.hasPath(to: conversation.destinationHash) { return "network" }
        if store.isPathPending(to: conversation.destinationHash) { return "ellipsis.circle" }
        return "network.slash"
    }

    private func sidebarRouteColor(for conversation: Conversation) -> Color {
        if store.activeLinkHashes.contains(conversation.destinationHash) || store.hasPath(to: conversation.destinationHash) { return .green }
        if store.isPathPending(to: conversation.destinationHash) { return .orange }
        return .secondary
    }

    private func sidebarRouteLabel(for conversation: Conversation) -> String {
        if store.activeLinkHashes.contains(conversation.destinationHash) { return "Encrypted link active" }
        if store.hasPath(to: conversation.destinationHash) { return "Route available" }
        if store.isPathPending(to: conversation.destinationHash) { return "Finding route" }
        return "No known route"
    }
    private func conversationHoverHelp(_ conversation: Conversation) -> String {
        var state = [sidebarRouteLabel(for: conversation)]
        if conversation.unreadCount > 0 { state.append("\(conversation.unreadCount) unread") }
        if conversation.isPinned { state.append("pinned") }
        if conversation.notificationsMuted { state.append("notifications muted") }
        if conversation.isBlocked { state.append("blocked") }
        if conversation.isTrusted { state.append("trusted") }
        if let message = store.latestMessage(for: conversation.id) {
            state.append("latest message \(message.state.rawValue)")
        }
        return "\(conversation.displayName) — \(state.joined(separator: ", ")). Select to open; right-click for conversation actions."
    }
    private var networkToolbarIcon: String {
        switch store.networkState {
        case .ready: "network.badge.shield.half.filled"
        case .connecting: "network"
        case .failed: "network.slash"
        case .stopped: "network.slash"
        }
    }
}

private struct DiscoveredDestinationRow: View {
    let discovery: DiscoveredDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(discovery.announcedDisplayName ?? discovery.destinationHash)
                .font(.caption.monospaced())
                .lineLimit(1)
            Text("\(discovery.hops) hops · \(discovery.isValidated ? "validated" : "unverified") · \(discovery.packetCount) packets")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) { Text("Last seen"); Text(discovery.lastSeen, style: .relative) }
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct SnapshotBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct NetworkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var store: SidebandStore
    @State private var showingLocalContactQR = false
    @State private var editingRNode: RNodeConfiguration?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Network Status").font(.title2.bold())
                    Spacer()
                    Label(statusText, systemImage: statusIcon).foregroundStyle(statusColor)
                        .help("Overall Reticulum state: \(statusText). Active transport: \(transportSummary).")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Network Status").font(.title2.bold())
                    Label(statusText, systemImage: statusIcon).foregroundStyle(statusColor)
                        .help("Overall Reticulum state: \(statusText). Active transport: \(transportSummary).")
                }
            }
            Text("Connect automatically over TCP, Bluetooth, USB serial or Wi-Fi RNode interfaces. Incoming packets and announces are parsed and cryptographically validated by the native Swift stack.")
                .font(.callout).foregroundStyle(.secondary)
                .help("Current state: \(statusText). Lower Sideband can keep IP and radio interfaces active at the same time.")
            GroupBox("Interface") {
                if horizontalSizeClass == .compact {
                    compactInterfaceSettings
                } else {
                    regularInterfaceSettings
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(6)
            GroupBox("Identity announcement") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        announceStatus
                        Spacer()
                        announceButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        announceStatus
                        announceButton
                    }
                }
                .padding(6)
            }
            GroupBox("Delivery diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticRow("Messaging identity", store.messagingIdentityHash, monospaced: true)
                    diagnosticRow("Active LXMF destination", store.localDeliveryHash, monospaced: true)
                    diagnosticRow(
                        "Last announced",
                        store.lastAnnouncedDeliveryHash.map {
                            "\($0) · \(store.lastDeliveryAnnounceAt?.formatted(date: .abbreviated, time: .standard) ?? "time unavailable")"
                        } ?? "Not announced during this session",
                        monospaced: store.lastAnnouncedDeliveryHash != nil
                    )
                    diagnosticRow(
                        "Last inbound packet",
                        store.lastInboundDeliveryPacketAt.map {
                            "\(store.lastInboundDeliveryDestination ?? "unknown") · \(store.lastInboundDeliveryMatched == true ? "matched" : "mismatch") · \(store.lastInboundDeliveryInterface ?? "unknown interface") · \($0.formatted(date: .abbreviated, time: .standard))"
                        } ?? "No delivery packet recorded"
                    )
                    diagnosticRow(
                        "Last inbound message",
                        store.lastInboundMessageAt.map {
                            "\(store.lastInboundMessageResult ?? "unknown") · source \(store.lastInboundMessageSource ?? "unknown") · \($0.formatted(date: .abbreviated, time: .standard))"
                        } ?? "No LXMF message recorded"
                    )
                    diagnosticRow(
                        "Last delivery proof",
                        store.lastDeliveryProofSentAt.map {
                            "sent \(store.lastDeliveryProofKind ?? "unknown") via \(store.lastDeliveryProofInterface ?? "automatic route") · \($0.formatted(date: .abbreviated, time: .standard))"
                        } ?? "No delivery proof recorded"
                    )
                    if let failure = store.lastDeliveryProofFailure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(store.inboundMessagesAccepted) accepted · \(store.inboundMessagesRejected) rejected · \(store.deliveryProofsSent) proofs sent · \(store.deliveryProofsDeferred) deferred")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Routing") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { metric("Packets received", store.receivedPacketCount); metric("Known paths", store.knownPathCount) }
                    GridRow { metric("Validated announces", store.validatedDiscoveryCount); metric("Pending requests", store.pendingPathCount) }
                    GridRow { metric("Unverified announces", store.unverifiedDiscoveryCount); metric("Delivered messages", store.deliveredMessageCount) }
                    GridRow { metric("Pending links", store.pendingLinkCount); metric("Active links", store.activeLinkCount) }
                    GridRow { metric("Encrypted packets", store.encryptedPacketsReceived); metric("Keepalives", store.keepalivesSent + store.keepalivesReceived) }
                    GridRow { metric("Deferred keepalives", store.deferredKeepalives); metric("Deferred tunnel setup", store.deferredTunnelSyntheses) }
                    GridRow { metric("Propagation requests", store.propagationRequestsSent); metric("Propagation responses", store.propagationResponsesReceived) }
                    GridRow { metric("Messages available", store.propagationMessagesAvailable); metric("Sent awaiting proof", store.sentMessageCount) }
                    GridRow { metric("Uploads accepted", store.propagationUploadsAccepted); metric("Direct deliveries", store.deliveredMessageCount) }
                    GridRow { metric("Delivery announces", store.deliveryAnnouncesSent); metric("Inbox messages", store.incomingMessageCount) }
                    GridRow { metric("Inbound links", store.inboundLinksAccepted); metric("Active links", store.activeLinkCount + store.inboundLinksAccepted) }
                    GridRow { metric("Opportunistic received", store.opportunisticDeliveriesReceived); metric("Delivery announces", store.deliveryAnnouncesSent) }
                    GridRow { metric("Delivery timeouts", store.deliveryTimeoutCount); metric("Queued messages", store.queuedMessageCount) }
                    GridRow { metric("Recovered outbox", store.recoveredOutboundCount); metric("Failed messages", store.failedMessageCount) }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(macOS)
            GroupBox("Reticulum Transport Instance") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Route packets between this Mac's interfaces", isOn: Binding(
                        get: { store.transportInstanceEnabled },
                        set: { store.setTransportInstanceEnabled($0) }
                    ))
                    .help(store.transportInstanceEnabled
                          ? "Transport Instance is active. This Mac validates announces and forwards eligible packets between TCP, RNode and AutoInterface links while suppressing loops."
                          : "Transport Instance is off. Lower Sideband behaves only as an endpoint and does not route packets for other Reticulum nodes.")
                    Text("Use this only on a Mac intended to remain online as a router. Interface modes prevent prohibited announce crossings, and duplicate packet hashes are suppressed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow { Text("State"); Text(store.transportInstanceEnabled ? "Routing" : "Endpoint only") }
                        GridRow { Text("Transport identity"); Text(store.transportInstanceSnapshot.enabled ? "Active" : "Inactive") }
                        GridRow { Text("Learned routes"); Text(store.transportInstanceSnapshot.knownRoutes.formatted()) }
                        GridRow { Text("Forwarded"); Text(store.transportInstanceSnapshot.forwardedPackets.formatted()) }
                        GridRow { Text("Duplicates blocked"); Text(store.transportInstanceSnapshot.duplicatePackets.formatted()) }
                        GridRow { Text("Packets ignored"); Text(store.transportInstanceSnapshot.ignoredPackets.formatted()) }
                    }.font(.caption)
                }.padding(6)
            }
            #endif
            GroupBox("Delivery health") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(deliveryHealthText, systemImage: deliveryHealthIcon)
                            .foregroundStyle(deliveryHealthColor)
                        Spacer()
                        Text(store.deliverySuccessRate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "No completed sends")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: store.deliverySuccessRate ?? 0)
                    HStack(spacing: 18) {
                        Text("\(store.outgoingMessageCount) outgoing")
                        Text("\(store.reactionCount) reactions")
                        Text("\(store.activeAttachmentTransferCount) file transfers")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Flush queued") { Task { await store.flushQueuedMessages() } }
                            .disabled(store.queuedMessageCount == 0 || store.networkState != .ready)
                        Button("Retry failed") { Task { await store.retryAllFailedMessages() } }
                            .disabled(store.failedMessageCount == 0)
                    }
                }.padding(6)
            }
            GroupBox("Attachment storage") {
                VStack(alignment: .leading, spacing: 10) {
                    if let report = store.attachmentStorageReport {
                        Label(report.isHealthy ? "Storage healthy" : "Storage needs attention", systemImage: report.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(report.isHealthy ? .green : .orange)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow { Text("Attachments"); Text(report.attachmentCount.formatted()) }
                            GridRow { Text("Logical size"); Text(ByteCountFormatter.string(fromByteCount: Int64(report.logicalBytes), countStyle: .file)) }
                            GridRow { Text("Encrypted files"); Text(ByteCountFormatter.string(fromByteCount: Int64(report.storedBytes), countStyle: .file)) }
                            GridRow { Text("Missing / corrupt"); Text("\(report.missingCount) / \(report.corruptCount)") }
                            GridRow { Text("Orphans"); Text("\(report.orphanCount) · \(ByteCountFormatter.string(fromByteCount: Int64(report.orphanBytes), countStyle: .file))") }
                        }
                    } else {
                        Text("Inspect attachment storage to calculate encrypted disk usage and integrity.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Inspect") { Task { await store.refreshAttachmentStorageReport() } }
                        Button("Remove Orphans") { Task { _ = await store.cleanupOrphanedAttachmentFiles() } }
                            .disabled(store.attachmentStorageReport?.orphanCount == 0)
                        Button("Remove Failed Metadata") { Task { _ = await store.removeFailedAttachmentMetadata() } }
                            .disabled(!store.messages.contains { $0.attachments.contains { $0.state == .failed } })
                        Button("Copy Report") { copyToSystemClipboard(store.attachmentStorageDiagnostics) }
                    }
                }.padding(6)
            }
            GroupBox("Gateway health") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.gatewayHealth.isEmpty ? "No endpoint history recorded yet." : "\(store.gatewayHealth.count) endpoint\(store.gatewayHealth.count == 1 ? "" : "s") tracked. Repeated failures temporarily lower an endpoint's automatic priority.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Health Report") { copyToSystemClipboard(store.gatewayHealthDiagnostics) }
                            .disabled(store.gatewayHealth.isEmpty)
                        Button("Reset Health History", role: .destructive) { store.resetGatewayHealth() }
                            .disabled(store.gatewayHealth.isEmpty)
                    }
                }.padding(6)
            }
            GroupBox("LXMF propagation") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Select a propagation node automatically", isOn: Binding(
                        get: { store.propagationNodeIsAutomatic },
                        set: { store.setAutomaticPropagationNode($0) }
                    ))
                    Text("\(store.discoveredPropagationNodeCount) propagation node\(store.discoveredPropagationNodeCount == 1 ? "" : "s") discovered")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Local address")
                        Text(store.localDeliveryHash).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { copyToSystemClipboard(store.localContactLink.url.absoluteString) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy local contact link")
                        ShareLink(item: store.localContactLink.url) { Image(systemName: "square.and.arrow.up") }
                            .help("Share local contact link")
                        Button { showingLocalContactQR = true } label: { Image(systemName: "qrcode") }
                            .help("Show local contact QR code")
                    }
                    HStack {
                        TextField("Propagation-node destination", text: Binding(get: { store.propagationNodeHash }, set: { store.setPropagationNode($0) }))
                            .font(.body.monospaced()).textFieldStyle(.roundedBorder)
                            .disabled(store.propagationNodeIsAutomatic)
                        Button("Request path") { Task { await store.requestPropagationNodePath() } }
                            .disabled(store.networkState != .ready || store.propagationNodePathPending)
                    }
                    Label(propagationStatus, systemImage: propagationIcon)
                        .font(.caption).foregroundStyle(store.propagationNodeHasPath ? Color.green : Color.secondary)
                    HStack {
                        Text(store.lastPropagationSync.map { "Last sync: \($0.formatted(date: .omitted, time: .standard))" } ?? "Not synced this session")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync now") { Task { await store.syncPropagationNow() } }
                            .disabled(store.networkState != .ready || !store.propagationNodeHasPath)
                    }
                }.padding(6)
            }
            GroupBox("Telemetry service") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Answer telemetry requests from trusted contacts", isOn: Binding(
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
                    )).disabled(!store.telemetryCollectorEnabled)
                    TextField("Preferred collector LXMF destination", text: Binding(
                        get: { store.telemetryCollectorHash },
                        set: { store.setTelemetryCollectorHash($0) }
                    )).font(.body.monospaced()).textFieldStyle(.roundedBorder)
                    Text("Requests are authenticated by the LXMF sender identity. Collector responses include telemetry from trusted contacts only and never include message text.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("iCloud device sync") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Sync identity, conversations and messages", isOn: Binding(
                        get: { store.iCloudSyncEnabled },
                        set: { enabled in Task { await store.setICloudSyncEnabled(enabled) } }
                    ))
                    Text("Uses your private iCloud database. Reticulum gateways and live routing remain specific to each device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(store.iCloudSyncStatus.description, systemImage: iCloudStatusIcon)
                            .font(.caption)
                            .foregroundStyle(iCloudStatusColor)
                        Spacer()
                        Button("Sync now") { Task { await store.syncICloudNow() } }
                            .disabled(!store.iCloudSyncEnabled || store.iCloudSyncStatus == .syncing)
                    }
                }.padding(6)
            }
            GroupBox("Message security") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Require device authentication to open Lower Sideband", isOn: Binding(
                        get: { store.privacyLock.isEnabled },
                        set: { enabled in Task { await store.privacyLock.setEnabled(enabled) } }
                    ))
                    .disabled(store.privacyLock.isAuthenticating)
                    Text(store.privacyLock.availabilityDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = store.privacyLock.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                    Toggle("Render rich text only from trusted or verified contacts", isOn: Binding(
                        get: { store.richTextTrustedOnly },
                        set: { store.setRichTextTrustedOnly($0) }
                    ))
                    Text("Unknown senders' Markdown is shown as literal text by default, preventing disguised links from becoming interactive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("Native plugins") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.pluginRegistry.manifests) { manifest in
                        Toggle(isOn: Binding(
                            get: { store.isPluginEnabled(manifest.identifier) },
                            set: { store.setPluginEnabled($0, identifier: manifest.identifier) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manifest.name)
                                Text("v\(manifest.version) · \(manifest.commands.sorted().joined(separator: ", "))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(pluginPermissionSummary(manifest.permissions))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    ForEach(store.pluginRegistry.rejectedPluginDescriptions, id: \.self) { description in
                        Label(description, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Plugins are app-bundled Swift components. A contact must also be trusted, fingerprint-verified and explicitly authorized before plugin requests can run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !store.pluginAuditEvents.isEmpty {
                        Divider()
                        HStack {
                            Text("Recent activity").font(.caption.bold())
                            Spacer()
                            Button("Clear history", role: .destructive) { store.clearPluginAuditHistory() }
                                .font(.caption)
                        }
                        ForEach(store.pluginAuditEvents.prefix(10)) { event in
                            HStack(spacing: 8) {
                                Image(systemName: pluginAuditIcon(event.outcome))
                                    .foregroundStyle(pluginAuditColor(event.outcome))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.command).font(.caption.monospaced()).lineLimit(1)
                                    Text(event.pluginIdentifier ?? "No enabled plugin")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(event.timestamp, style: .relative)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Plugin command \(event.command), \(event.outcome.rawValue)")
                        }
                        Text("Activity records contain only the command name and outcome. Arguments and message content are never logged.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
            GroupBox("Notifications") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Notify for verified incoming messages", isOn: Binding(
                            get: { store.notifications.isEnabled },
                            set: { enabled in Task { await store.notifications.setEnabled(enabled) } }
                        ))
                        Spacer()
                        Text(store.notifications.authorizationDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Show sender and message previews", isOn: Binding(
                        get: { store.notifications.showPreviews },
                        set: { store.notifications.setShowPreviews($0) }
                    ))
                    .disabled(!store.notifications.isEnabled)
                    Toggle("Play notification sounds", isOn: Binding(
                        get: { store.notifications.playSounds },
                        set: { store.notifications.setPlaySounds($0) }
                    ))
                    .disabled(!store.notifications.isEnabled)
                    Text("Notification taps open the matching conversation. Muted conversations and the conversation currently on screen do not produce alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = store.notifications.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }.padding(6)
            }
            GroupBox("Secure voice calls") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Accept calls from trusted contacts only", isOn: Binding(
                        get: { store.voiceTrustedOnly },
                        set: { store.setVoiceTrustedOnly($0) }
                    ))
                    Picker("Voice profile", selection: Binding(
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
                        Text("Opus 8 kbps").tag(LXMFVoiceMessageAudio.Mode.opusOgg)
                        Text("Codec2 2.4 kbps").tag(LXMFVoiceMessageAudio.Mode.codec2_2400)
                        Text("Codec2 1.2 kbps").tag(LXMFVoiceMessageAudio.Mode.codec2_1200)
                        Text("Codec2 700 bps").tag(LXMFVoiceMessageAudio.Mode.codec2_700C)
                    }
                    HStack {
                        Text("LXST address")
                        Text(store.localVoiceHash).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { copyToSystemClipboard(store.localVoiceHash) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy LXST voice address")
                    }
                    Text("Calls use the messaging identity and an end-to-end encrypted Reticulum link. Native Opus and Codec2 profiles interoperate with Python Sideband/LXST.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !store.voiceCallHistory.isEmpty {
                        Divider()
                        Text("Recent calls").font(.caption.bold())
                        ForEach(store.voiceCallHistory.prefix(5)) { call in
                            HStack {
                                Image(systemName: call.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                                Text(store.conversations.first(where: { $0.id == call.conversationID })?.displayName ?? "Unknown contact")
                                Spacer()
                                Text(call.startedAt, style: .relative).foregroundStyle(.secondary)
                                if call.failureReason != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                            }.font(.caption)
                        }
                    }
                }.padding(6)
            }
            if !store.incomingResourceProgress.isEmpty {
                GroupBox("Incoming Resources") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.incomingResourceProgress.keys.sorted(), id: \.self) { hash in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text("\(hash.prefix(12))…").font(.caption.monospaced()); Spacer(); Text("\(Int((store.incomingResourceProgress[hash] ?? 0) * 100))%") }
                                ProgressView(value: store.incomingResourceProgress[hash] ?? 0)
                            }
                        }
                    }.padding(6)
                }
            }
            GroupBox("RNode radio interfaces") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Discover and reconnect Bluetooth RNodes automatically", isOn: Binding(
                        get: { store.rnodeManager.automaticDiscoveryEnabled },
                        set: { store.rnodeManager.setAutomaticDiscovery($0) }
                    ))
                    .help(store.rnodeManager.automaticDiscoveryEnabled ? "Automatic RNode discovery is on. The app scans for compatible Bluetooth LE radios and reconnects in the background when permitted." : "Automatic RNode discovery is off. Add a Bluetooth, Wi-Fi/TCP or USB serial RNode manually.")
                    Text("Uses native RNode KISS control and Reticulum packets over Bluetooth LE, Wi-Fi/TCP, or USB serial on Mac. Radio and IP interfaces can remain active together.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.rnodeManager.configurations.isEmpty {
                        ContentUnavailableView("No RNodes configured", systemImage: "antenna.radiowaves.left.and.right", description: Text("Automatic discovery will attach a nearby BLE RNode, or add one manually."))
                            .frame(maxHeight: 100)
                    }
                    ForEach(store.rnodeManager.configurations) { configuration in
                        let snapshot = store.rnodeManager.snapshots.first { $0.id == configuration.id }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(configuration.name, systemImage: rnodeIcon(configuration.transport))
                                    .font(.headline)
                                Spacer()
                                Label(rnodeStateText(snapshot?.state ?? .stopped), systemImage: rnodeStateIcon(snapshot?.state ?? .stopped))
                                    .font(.caption)
                                    .foregroundStyle(snapshot?.state == .ready ? Color.green : Color.secondary)
                                    .help("\(configuration.name): \(rnodeStateText(snapshot?.state ?? .stopped)). \(rnodeConfigurationSummary(configuration))")
                            }
                            Text(rnodeConfigurationSummary(configuration))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let metrics = snapshot?.metrics {
                                HStack(spacing: 14) {
                                    if let major = metrics.firmwareMajor, let minor = metrics.firmwareMinor { Text("Firmware \(major).\(minor)") }
                                    if let board = metrics.board { Text("Board 0x\(String(board, radix: 16))") }
                                    if let rssi = metrics.rssi { Text("RSSI \(rssi) dBm") }
                                    if let snr = metrics.snr { Text("SNR \(snr.formatted(.number.precision(.fractionLength(1)))) dB") }
                                    if let battery = metrics.batteryPercent { Text("Battery \(battery)%") }
                                    if let airtime = metrics.airtimeLong { Text("Airtime \(airtime.formatted(.number.precision(.fractionLength(1))))%") }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            if let snapshot {
                                HStack(spacing: 14) {
                                    if let framebuffer = snapshot.framebuffer { Text("Framebuffer \(framebuffer.count) B") }
                                    if let display = snapshot.displaySnapshot { Text("Display \(display.count) B") }
                                    if let rom = snapshot.romSnapshot { Text("ROM \(rom.count) B") }
                                    if let beacon = snapshot.lastBeaconAt { Text("Station ID sent \(beacon, style: .relative)") }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            if let error = snapshot?.lastError {
                                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Button("Edit") { editingRNode = configuration }
                                    .help("Edit the transport and LoRa radio parameters for \(configuration.name)")
                                Button("Blink") { Task { await store.rnodeManager.blink(configuration.id) } }
                                    .disabled(snapshot?.state != .ready)
                                    .help(snapshot?.state == .ready ? "Blink \(configuration.name) to identify the physical radio" : "Blink is unavailable because \(configuration.name) is not connected")
                                Menu("Hardware") {
                                    Button("Write display test pattern") {
                                        Task { try? await store.rnodeManager.writeFramebuffer(RNodeFramebuffer.testPattern().bytes, on: configuration.id) }
                                    }
                                    Button("Read framebuffer") { Task { try? await store.rnodeManager.requestFramebuffer(on: configuration.id) } }
                                    Button("Read complete display") { Task { try? await store.rnodeManager.requestDisplaySnapshot(on: configuration.id) } }
                                    Button("Inspect ROM") { Task { try? await store.rnodeManager.requestROMSnapshot(on: configuration.id) } }
                                }
                                .disabled(snapshot?.state != .ready)
                                .help(snapshot?.state == .ready ? "Test and inspect the RNode framebuffer, display and EEPROM without changing radio settings" : "Hardware tools require a ready RNode connection")
                                Button(configuration.enabled ? "Disable" : "Enable") {
                                    var changed = configuration; changed.enabled.toggle()
                                    Task { try? await store.rnodeManager.upsert(changed) }
                                }
                                .help(configuration.enabled ? "Stop and disable automatic reconnection for \(configuration.name)" : "Enable and connect \(configuration.name)")
                                Spacer()
                                Button("Remove", role: .destructive) { Task { await store.rnodeManager.remove(configuration.id) } }
                                    .help("Remove \(configuration.name) from this device")
                            }.font(.caption)
                        }
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Button { editingRNode = RNodeConfiguration() } label: { Label("Add RNode", systemImage: "plus") }
                            .help("Add a Bluetooth LE, Wi-Fi/TCP or USB serial RNode")
                        Button("Start radios") { Task { await store.rnodeManager.startAll() } }
                            .help("Start every enabled RNode interface; current ready count: \(store.rnodeManager.readyInterfaceIDs.count)")
                        Button("Run self-test") { Task { await store.rnodeManager.runSelfTest() } }
                            .help("Run a deterministic 100-packet RNode protocol loopback without requiring radio hardware")
                        Spacer()
                        if let result = store.rnodeManager.selfTestResult { Text(result).font(.caption).foregroundStyle(result.hasPrefix("Passed") ? Color.green : Color.secondary) }
                    }
                }.padding(6)
            }
            GroupBox("LAN gateways") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Automatic Bonjour discovery: _reticulum._tcp, _rns._tcp and _sideband._tcp")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.lanDiscovery.isSearching {
                            Button("Stop") { store.stopGatewayDiscovery() }
                        } else {
                            Button("Discover") { store.startGatewayDiscovery() }
                        }
                    }
                    if store.lanDiscovery.gateways.isEmpty {
                        ContentUnavailableView("No advertised gateways", systemImage: "dot.radiowaves.left.and.right", description: Text(store.lanDiscovery.isSearching ? "Listening automatically; public Internet gateways will be tried if no LAN gateway appears." : "Start discovery or connect automatically."))
                            .frame(maxHeight: 95)
                    } else {
                        ForEach(store.lanDiscovery.gateways) { gateway in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(gateway.name)
                                    Text("\(gateway.type) · \(gateway.domain)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Connect") { Task { await store.connect(to: gateway) } }
                            }
                        }
                    }
                }.padding(6)
            }
            GroupBox("Reticulum AutoInterface") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Protocol-native IPv6 multicast peer discovery")
                            Text("\(AutoInterfaceProtocol.multicastAddress):\(AutoInterfaceProtocol.discoveryPort)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.autoInterfaceDiscovery.isListening {
                            Button("Stop") { store.stopAutoInterfaceDiscovery() }
                        } else {
                            Button("Listen") { store.startAutoInterfaceDiscovery() }
                        }
                    }
                    if let error = store.autoInterfaceDiscovery.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    }
                    if store.autoInterfaceDiscovery.peers.isEmpty {
                        Text(store.autoInterfaceDiscovery.isListening ? "Listening for authenticated AutoInterface peers…" : "Listener stopped")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.autoInterfaceDiscovery.peers) { peer in
                            Label(peer.address, systemImage: "dot.radiowaves.left.and.right").font(.body.monospaced())
                        }
                    }
                    HStack(spacing: 18) {
                        Text("Beacons sent: \(store.autoInterfaceDiscovery.beaconsSent)")
                        Text("Interfaces: \(store.autoInterfaceDiscovery.activeInterfaceNames.joined(separator: ", "))")
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Text("UDP received: \(store.autoInterfaceDiscovery.dataPacketsReceived)")
                        Text("UDP sent: \(store.autoInterfaceDiscovery.dataPacketsSent)")
                        Text("Data port: \(AutoInterfaceProtocol.dataPort)")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("Native engine") {
                VStack(alignment: .leading, spacing: 7) {
                    capability("TCP/HDLC interface", complete: true)
                    capability("RNode Bluetooth, TCP and USB serial interfaces", complete: true)
                    capability("Identity and announce validation", complete: true)
                    capability("Path discovery and route table", complete: true)
                    capability("AutoInterface discovery and UDP data plane", complete: true)
                    capability("Encrypted links and resources", complete: true)
                    capability("LXMF message delivery", complete: true)
                    capability("LXST encrypted voice calls", complete: true)
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Close") { dismiss() }
                Button { copyToSystemClipboard(store.networkDiagnosticsReport) } label: {
                    Label("Copy Diagnostics", systemImage: "stethoscope")
                }
                Spacer()
                if isConnectedOrConnecting {
                    if store.networkState == .ready {
                        Button("Reconnect") { Task { await store.reconnectNetwork() } }
                    }
                    Button("Disconnect") { Task { await store.disconnectNetwork() } }
                } else {
                    Button("Connect") { Task { await store.startAutomaticConnection() } }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(24)
        .accessibilityIdentifier("network-connections-screen")
        }
        .platformNetworkSheetSize()
        .sheet(isPresented: $showingLocalContactQR) {
            ContactQRCodeView(name: store.localDisplayName, link: store.localContactLink.url)
        }
        .sheet(item: $editingRNode) { configuration in
            RNodeEditorView(configuration: configuration) { saved in
                Task {
                    do { try await store.rnodeManager.upsert(saved); editingRNode = nil }
                    catch { store.lastError = error.localizedDescription }
                }
            } onCancel: { editingRNode = nil }
        }
    }

    private var announceStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("My LXMF destination")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(store.localDeliveryHash)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(store.lastDeliveryAnnounceAt.map { "Last announced \($0.formatted(date: .abbreviated, time: .standard))" }
                 ?? "Not announced during this session")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var announceButton: some View {
        Button {
            Task { _ = await store.announceDeliveryDestinationNow() }
        } label: {
            Label("Announce Now", systemImage: "antenna.radiowaves.left.and.right")
        }
        .disabled(store.networkState != .ready)
        .help(store.networkState == .ready
              ? "Broadcast your LXMF delivery and voice destinations on every ready Reticulum interface now."
              : "Connect to Reticulum before announcing your destinations.")
    }

    private var compactInterfaceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            compactSetting("Local name") {
                TextField("Lower Sideband", text: Binding(get: { store.localDisplayName }, set: { store.setLocalDisplayName($0) }))
            }
            compactSetting("Host") {
                TextField("Optional configured IPv4 or DNS hostname", text: $store.networkHost)
            }
            compactSetting("IPv6 host") {
                TextField("Optional configured IPv6 gateway", text: $store.networkIPv6Host)
            }
            compactSetting("Internet override") {
                TextField("Optional TCP host, WebSocket or HTTP URL", text: $store.networkInternetHost)
            }
            compactSetting("Internet port") {
                TextField("4242", value: $store.networkInternetPort, format: .number.grouping(.never))
            }
            compactSetting("Port") {
                TextField("4242", value: $store.networkPort, format: .number.grouping(.never))
            }
            compactSetting("Connection mode") {
                connectionModePicker
                    .pickerStyle(.menu)
            }
            compactSetting("Addressing") {
                Toggle("Prefer IPv6 with IPv4 fallback", isOn: Binding(get: { store.preferIPv6 }, set: { store.setPreferIPv6($0) }))
            }
            compactSetting("Connection policy") {
                Toggle("Internet only — disable LAN gateways", isOn: Binding(get: { store.internetOnlyEnabled }, set: { store.setInternetOnly($0) }))
            }
            compactSetting("Reconnect") {
                Toggle("Connect automatically", isOn: Binding(get: { store.autoConnectEnabled }, set: { store.setAutoConnect($0) }))
            }
            compactSetting("Automatic connection") {
                secondarySettingText(store.automaticConnectionDescription)
            }
            if store.connectionMode == .automatic {
                compactSetting("Discovery order") {
                    secondarySettingText("Local Bonjour gateways, authenticated on-network interfaces, then healthy public gateways")
                }
            }
            compactSetting("Transport") {
                secondarySettingText(transportSummary)
            }
            ForEach(store.networkInterfaces) { interface in
                compactSetting(interface.name + (interface.isBootstrap ? " (bootstrap)" : "")) {
                    Label(interfaceStateText(interface.state), systemImage: interfaceStateIcon(interface.state))
                        .font(.caption)
                        .foregroundStyle(interface.state == .ready ? Color.green : Color.secondary)
                }
            }
            compactSetting("System network") {
                secondarySettingText(reachabilityText)
            }
            compactSetting("Discovered interfaces") {
                secondarySettingText("\(store.discoveredNetworkInterfaces.count) authenticated")
            }
            compactSetting("Last connected") {
                secondarySettingText(store.lastNetworkReadyAt?.formatted(date: .abbreviated, time: .standard) ?? "Never")
            }
            compactSetting("Background refresh") {
                secondarySettingText(backgroundRefreshSummary)
            }
        }
    }

    private var regularInterfaceSettings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("Local name")
                TextField("Lower Sideband", text: Binding(get: { store.localDisplayName }, set: { store.setLocalDisplayName($0) }))
            }
            GridRow { Text("Host"); TextField("Optional configured IPv4 or DNS hostname", text: $store.networkHost) }
            GridRow { Text("IPv6 host"); TextField("Optional configured IPv6 gateway", text: $store.networkIPv6Host) }
            GridRow { Text("Internet override"); TextField("Optional TCP host, WebSocket or HTTP URL", text: $store.networkInternetHost) }
            GridRow { Text("Internet port"); TextField("4242", value: $store.networkInternetPort, format: .number.grouping(.never)) }
            GridRow { Text("Port"); TextField("4242", value: $store.networkPort, format: .number.grouping(.never)) }
            GridRow {
                Text("Connection mode")
                connectionModePicker
            }
            GridRow { Text("Addressing"); Toggle("Prefer IPv6 with IPv4 fallback", isOn: Binding(get: { store.preferIPv6 }, set: { store.setPreferIPv6($0) })) }
            GridRow { Text("Connection policy"); Toggle("Internet only — disable LAN gateways", isOn: Binding(get: { store.internetOnlyEnabled }, set: { store.setInternetOnly($0) })) }
            GridRow { Text("Reconnect"); Toggle("Connect automatically", isOn: Binding(get: { store.autoConnectEnabled }, set: { store.setAutoConnect($0) })) }
            GridRow { Text("Automatic connection"); Text(store.automaticConnectionDescription).foregroundStyle(.secondary) }
            if store.connectionMode == .automatic {
                GridRow {
                    Text("Discovery order")
                    Text("Local Bonjour gateways, authenticated on-network interfaces, then healthy public gateways")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow { Text("Transport"); Text(transportSummary).foregroundStyle(.secondary) }
            ForEach(store.networkInterfaces) { interface in
                GridRow {
                    Text(interface.name + (interface.isBootstrap ? " (bootstrap)" : "")).font(.caption)
                    Label(interfaceStateText(interface.state), systemImage: interfaceStateIcon(interface.state))
                        .font(.caption).foregroundStyle(interface.state == .ready ? Color.green : Color.secondary)
                }
            }
            GridRow { Text("System network"); Text(reachabilityText).foregroundStyle(.secondary) }
            GridRow { Text("Discovered interfaces"); Text("\(store.discoveredNetworkInterfaces.count) authenticated").foregroundStyle(.secondary) }
            GridRow {
                Text("Last connected")
                Text(store.lastNetworkReadyAt?.formatted(date: .abbreviated, time: .standard) ?? "Never")
                    .foregroundStyle(.secondary)
            }
            GridRow { Text("Background refresh"); Text(backgroundRefreshSummary).foregroundStyle(.secondary) }
        }
    }

    private var connectionModePicker: some View {
        Picker("Connection mode", selection: Binding(
            get: { store.connectionMode },
            set: { store.setConnectionMode($0) }
        )) {
            ForEach(NetworkConnectionMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
    }

    private func compactSetting<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(networkSettingHelp(title))
    }

    private func secondarySettingText(_ value: String) -> some View {
        Text(value)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func diagnosticRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("\(title): \(value)")
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value.formatted()).font(.title3.monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }
            .frame(minWidth: 125, alignment: .leading)
            .help("\(title): \(value.formatted())")
    }
    private func capability(_ title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle.dotted")
            .foregroundStyle(complete ? Color.green : Color.secondary)
            .help("\(title): \(complete ? "implemented in the native Swift engine" : "not yet implemented")")
    }
    private func networkSettingHelp(_ title: String) -> String {
        switch title {
        case "Local name": "The display name included in your signed LXMF announce."
        case "Host": "Optional configured IPv4 address or DNS hostname. Automatic mode can discover local gateways without this."
        case "IPv6 host": "Optional configured IPv6 Reticulum gateway, preferred when IPv6 is available."
        case "Internet override": "Optional public Reticulum TCP host, WebSocket URL or HTTP tunnel URL used before built-in public fallbacks."
        case "Internet port", "Port": "TCP port used by the configured Reticulum server; port formatting never changes its numeric value."
        case "Connection mode": "Automatic discovers local interfaces first and then uses public fallbacks; Configured prioritises entered addresses."
        case "Addressing": "Prefer native IPv6 where reachable and fall back to IPv4 automatically."
        case "Connection policy": "Internet-only mode skips local Bonjour gateway discovery."
        case "Reconnect": "Automatically restore Reticulum connections after launch, wake or network changes."
        case "Automatic connection": "The current stage of automatic gateway discovery and connection."
        case "Discovery order": "The order used to find a usable Reticulum interface without user intervention."
        case "Transport": "The currently active Reticulum transport types and endpoints."
        case "System network": "The network path and IP families currently reported by the operating system."
        case "Discovered interfaces": "Authenticated Reticulum interfaces learned from signed network announces."
        case "Last connected": "The last time any Reticulum TCP or RNode interface became ready."
        case "Background refresh": "The most recent background propagation synchronisation attempt."
        default: "Current state for \(title)."
        }
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
    private var propagationStatus: String {
        if store.propagationNodeHasPath { return "Propagation node reachable" }
        if store.propagationNodePathPending { return "Propagation-node path requested" }
        return "Propagation-node path unknown"
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
            value += " · \(store.networkInterfaces.count) concurrent gateways"
        } else if let host = store.activeNetworkHost {
            value += " · \(host)"
            if let port = store.activeNetworkPort { value += ":\(port)" }
        }
        return value
    }
    private var backgroundRefreshSummary: String {
        guard let date = store.lastBackgroundRefreshAt else { return "Not run yet" }
        let result = store.lastBackgroundRefreshSucceeded == true ? "succeeded" : "incomplete"
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(result)"
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
        let target = configuration.target.isEmpty ? "any nearby RNode" : configuration.target
        let mhz = String(format: "%.4f", Double(configuration.frequency) / 1_000_000)
        return "\(configuration.transport.title) · \(target) · \(mhz) MHz · BW \(configuration.bandwidth) · SF\(configuration.spreadingFactor) · CR\(configuration.codingRate) · \(configuration.txPower) dBm"
    }
    private var statusText: String {
        switch store.networkState {
        case .stopped: "Disconnected"
        case .connecting: "Connecting"
        case .ready:
            if store.rnodeManager.hasReadyInterface && !store.networkInterfaces.contains(where: { $0.state == .ready }) { "RNode connected" }
            else if store.rnodeManager.hasReadyInterface { "TCP and RNode connected" }
            else { "TCP connected" }
        case .failed(let reason): store.reconnectDelaySeconds.map { "Retrying in \($0)s · \(reason)" } ?? "Failed: \(reason)"
        }
    }
    private var statusIcon: String {
        switch store.networkState { case .ready: "checkmark.circle.fill"; case .connecting: "arrow.triangle.2.circlepath"; case .failed: "exclamationmark.triangle.fill"; case .stopped: "circle" }
    }
    private var statusColor: Color {
        switch store.networkState { case .ready: .green; case .connecting: .orange; case .failed: .red; case .stopped: .secondary }
    }
    private var deliveryHealthText: String {
        if store.failedMessageCount > 0 { return "Delivery attention needed" }
        if store.queuedMessageCount > 0 || store.sentMessageCount > 0 { return "Messages in progress" }
        if store.deliveredMessageCount > 0 { return "Delivery healthy" }
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
        if store.queuedMessageCount > 0 || store.sentMessageCount > 0 { return .secondary }
        if store.deliveredMessageCount > 0 { return .green }
        return .secondary
    }
}

private struct ConversationView: View {
    private enum FocusTarget: Hashable { case search, composer }
    private enum SearchScope: String, CaseIterable { case all = "All", text = "Text", attachments = "Files", telemetry = "Telemetry", reactions = "Reactions" }
    private struct ReactionSummary: Identifiable {
        let content: String
        let count: Int
        var id: String { content }
    }

    @Bindable var store: SidebandStore
    let conversation: Conversation
    @State private var draft = ""
    @State private var pendingAttachments: [Attachment] = []
    @State private var pendingVoiceAudio: LXMFVoiceMessageAudio?
    @State private var showingFileImporter = false
    @State private var messageSearch = ""
    @State private var messageSearchScope: SearchScope = .all
    @State private var showStarredOnly = false
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var previewAttachmentURL: URL?
    @State private var previewAttachment: Attachment?
    @State private var showingContactQR = false
    @State private var showingIdentityVerification = false
    @State private var conversationExportDocument: SnapshotBackupDocument?
    @State private var showingConversationExporter = false
    @State private var telemetryCapture = TelemetryCapture()
    @State private var voiceRecorder = VoiceMessageRecorder()
    @State private var showingTelemetryMap = false
    @State private var paperMessageURI: String?
    @State private var replyingTo: Message?
    @State private var composeAsMarkdown = false
    @State private var scheduledFor: Date?
    @State private var messagePendingDeletion: Message?
    @State private var inspectedMessage: Message?
    @State private var messageToForward: Message?
    @State private var showingRename = false
    @State private var showingMediaBrowser = false
    @State private var renameDraft = ""
    @State private var isVisible = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var focusedField: FocusTarget?

    var body: some View {
        let conversationMessages = filteredMessages
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact {
                compactConversationHeader
            } else {
                HStack {
                Image(systemName: conversation.appearanceSymbol.rawValue)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(appearanceColor(conversation.appearanceColor), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    renameConversationButton(font: .title2.bold())
                    if conversation.isTrusted { Label("Trusted", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green) }
                    if !conversation.contactNote.isEmpty {
                        Text(conversation.contactNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(conversation.destinationHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .contextMenu {
                            Button { copyToSystemClipboard(conversation.destinationHash) } label: { Label("Copy Destination", systemImage: "number") }
                            if let contactLink = store.contactLink(for: conversation.id) {
                                Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: { Label("Copy Contact Link", systemImage: "link") }
                            }
                        }
                }
                Spacer()
                TextField("Search messages", text: $messageSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($focusedField, equals: .search)
                    .help(messageSearch.isEmpty ? "Search message text, attachment names and metadata in this conversation" : "Showing \(conversationMessages.count) matching message\(conversationMessages.count == 1 ? "" : "s")")
                    .accessibilityIdentifier("message-search")
                if !messageSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Picker("Search scope", selection: $messageSearchScope) {
                        ForEach(SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("Limit message search")
                    Text("\(conversationMessages.count) \(conversationMessages.count == 1 ? "result" : "results")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { messageSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear message search")
                        .accessibilityLabel("Clear message search")
                }
                if store.contactLink(for: conversation.id) != nil {
                    Button { showingContactQR = true } label: { Image(systemName: "qrcode") }
                        .help("Show contact QR code")
                        .accessibilityLabel("Show contact QR code")
                }
                Button { showingIdentityVerification = true } label: {
                    Image(systemName: store.isConversationIdentityVerified(conversation.id) ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(store.isConversationIdentityVerified(conversation.id) ? .green : .secondary)
                }
                .help(store.isConversationIdentityVerified(conversation.id) ? "Identity verified" : "Verify contact identity")
                .accessibilityLabel(store.isConversationIdentityVerified(conversation.id) ? "Contact identity verified" : "Verify contact identity")
                if !telemetryMessages.isEmpty {
                    Button { showingTelemetryMap = true } label: { Image(systemName: "map") }
                        .help("Show conversation telemetry map")
                }
                if !store.starredMessages(for: conversation.id).isEmpty {
                    Button { showStarredOnly.toggle() } label: {
                        Image(systemName: showStarredOnly ? "star.fill" : "star")
                    }
                    .foregroundStyle(showStarredOnly ? .yellow : .secondary)
                    .help(showStarredOnly ? "Show all messages" : "Show starred messages")
                    .accessibilityLabel(showStarredOnly ? "Show all messages" : "Show starred messages")
                }
                if let transcript = store.conversationTranscript(conversation.id) {
                    ShareLink(item: transcript, subject: Text("Lower Sideband conversation with \(conversation.displayName)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export conversation transcript")
                    .accessibilityLabel("Share conversation transcript")
                }
                Button {
                    do {
                        conversationExportDocument = SnapshotBackupDocument(data: try store.exportConversationData(conversation.id))
                        showingConversationExporter = true
                    } catch {
                        store.lastError = "Could not export conversation: \(error.localizedDescription)"
                    }
                } label: { Image(systemName: "doc.badge.arrow.up") }
                .help("Export structured conversation archive")
                .accessibilityLabel("Export structured conversation archive")
                Button { Task { await store.startVoiceCall(conversationID: conversation.id) } } label: {
                    Image(systemName: "phone.fill")
                }
                .buttonStyle(.plain)
                .disabled(store.voiceCall != nil || conversation.isBlocked || store.networkState != .ready)
                .help(conversation.isBlocked ? "Unblock this contact before calling" : "Start encrypted voice call")
                .accessibilityLabel("Start encrypted voice call")
                Menu {
                    Button("Rename Conversation", systemImage: "pencil") { beginRename() }
                    Button("Media, Links & Files", systemImage: "photo.on.rectangle.angled") { showingMediaBrowser = true }
                    Divider()
                    Button("Search Messages", systemImage: "magnifyingglass") { focusedField = .search }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Focus Message Composer", systemImage: "text.cursor") { focusedField = .composer }
                        .keyboardShortcut("m", modifiers: [.command, .option])
                    Divider()
                    Button { Task { await store.sendCommand(.ping, conversationID: conversation.id) } } label: {
                        Label("Ping contact", systemImage: "wave.3.right")
                    }
                    Button { Task { await store.sendCommand(.signalReport, conversationID: conversation.id) } } label: {
                        Label("Request signal report", systemImage: "chart.bar")
                    }
                    Button { Task { await store.requestTelemetry(conversationID: conversation.id, since: .now.addingTimeInterval(-604_800)) } } label: {
                        Label("Request telemetry", systemImage: "location.viewfinder")
                    }
                    Menu("Plugin request", systemImage: "puzzlepiece.extension") {
                        ForEach(store.pluginRegistry.manifests) { manifest in
                            if store.isPluginEnabled(manifest.identifier) {
                                ForEach(manifest.commands.sorted(), id: \.self) { command in
                                    Button(command) { Task { await store.sendPluginCommand(command, conversationID: conversation.id) } }
                                }
                            }
                        }
                    }
                    Divider()
                    if let reportURL = SidebandSafetyReport.emailURL(for: conversation) {
                        Link(destination: reportURL) {
                            Label("Report Contact", systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("Interoperable LXMF requests")
                Label(routingStatus, systemImage: routingIcon)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Routing status: \(routingStatus)")
                    .help(routingHelp)
                Label(connectedRouteText, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(connectedRouteHelp)
                    .accessibilityLabel("Current route: \(connectedRouteHelp)")
                }.padding()
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if conversationMessages.isEmpty {
                            ContentUnavailableView(
                                messageSearch.isEmpty ? "No Messages Yet" : "No Matching Messages",
                                systemImage: messageSearch.isEmpty ? "bubble.left" : "magnifyingglass",
                                description: Text(messageSearch.isEmpty ? "Send a message to start this conversation." : "Try a different search term.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 260)
                        }
                        ForEach(Array(conversationMessages.enumerated()), id: \.element.id) { index, message in
                            let reactionSummaries = reactionSummaries(for: message)
                            if index == 0 || !Calendar.current.isDate(message.timestamp, inSameDayAs: conversationMessages[index - 1].timestamp) {
                                Text(message.timestamp.formatted(date: .long, time: .omitted))
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            HStack {
                                if message.direction == .outgoing { Spacer(minLength: 80) }
                                VStack(alignment: .leading, spacing: 5) {
                                    if let replyQuote = message.replyQuote {
                                        HStack(spacing: 5) {
                                            Rectangle().fill(Color.accentColor).frame(width: 3)
                                            Text(replyQuote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        .padding(.bottom, 2)
                                        .accessibilityLabel("Replying to: \(replyQuote)")
                                    }
                                    if !message.body.isEmpty { renderedBody(message) }
                                    if let voiceAudio = message.voiceAudio {
                                        InlineLXMFVoiceMessageView(audio: voiceAudio)
                                    }
                                    if let telemetry = message.telemetry {
                                        Button { showingTelemetryMap = true } label: { TelemetryMessageCard(telemetry: telemetry) }
                                            .buttonStyle(.plain)
                                            .help("Show telemetry on map")
                                    }
                                    if !message.telemetryStream.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Label("Telemetry stream", systemImage: "point.3.connected.trianglepath.dotted")
                                                .font(.caption.bold())
                                            Text("\(message.telemetryStream.count) source update\(message.telemetryStream.count == 1 ? "" : "s")")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(Array(Set(message.telemetryStream.flatMap { $0.telemetry.sensorKinds.map(\.displayName) })).sorted().joined(separator: " · "))
                                                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    ForEach(message.attachments) { attachment in
                                        if isImage(attachment) {
                                            InlineImageAttachmentView(store: store.attachmentStore, attachment: attachment, status: attachmentStatus(attachment), onRetry: { retry(message, attachment) }, onCancel: { cancel(message, attachment) })
                                        } else if isAudio(attachment) {
                                            InlineAudioAttachmentView(store: store.attachmentStore, attachment: attachment, status: attachmentStatus(attachment), onRetry: { retry(message, attachment) }, onCancel: { cancel(message, attachment) })
                                        } else {
                                            Button { preview(attachment) } label: {
                                                Label {
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(attachment.filename).lineLimit(1)
                                                        Text(attachmentStatus(attachment)).font(.caption2).foregroundStyle(.secondary)
                                                        if attachment.state == .transferring {
                                                            ProgressView(value: attachment.progress)
                                                                .accessibilityLabel("Attachment transfer progress")
                                                                .accessibilityValue("\(Int(attachment.progress * 100)) percent")
                                                        }
                                                    }
                                                } icon: { Image(systemName: "doc.fill") }
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(attachment.state == .transferring || attachment.state == .queued || attachment.state == .failed)
                                            attachmentControls(message, attachment)
                                        }
                                        if attachment.state == .available || attachment.state == .local {
                                            AttachmentShareButton(store: store.attachmentStore, attachment: attachment)
                                        }
                                    }
                                    if !reactionSummaries.isEmpty {
                                        HStack(spacing: 5) {
                                            ForEach(reactionSummaries) { reaction in
                                                Text(reaction.count > 1 ? "\(reaction.content) \(reaction.count)" : reaction.content)
                                                    .font(.caption)
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 3)
                                                    .background(.thinMaterial, in: Capsule())
                                                    .accessibilityLabel("Reaction \(reaction.content), \(reaction.count) \(reaction.count == 1 ? "person" : "people")")
                                            }
                                        }
                                    }
                                    HStack {
                                        if message.isStarred {
                                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                                                .accessibilityLabel("Starred")
                                        }
                                        Text(message.timestamp, style: .time)
                                        Text(message.state.rawValue.capitalized)
                                        if message.deliveryAttemptCount > 1 {
                                            Text("· \(message.deliveryAttemptCount) attempts")
                                        }
                                        if let failure = message.lastDeliveryFailure {
                                            Image(systemName: "exclamationmark.circle.fill")
                                                .foregroundStyle(.orange)
                                                .help(failure)
                                                .accessibilityLabel("Last delivery issue: \(failure)")
                                        }
                                    }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(message.timestamp.formatted(date: .long, time: .standard)), \(message.state.rawValue)")
                                        .help(message.timestamp.formatted(date: .long, time: .standard))
                                }
                                .padding(10)
                                .background(message.direction == .outgoing ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(messageAccessibilityLabel(message, summaries: reactionSummaries))
                                .help(messageHoverHelp(message))
                                .contextMenu {
                                    Button { store.setMessageStarred(!message.isStarred, messageID: message.id) } label: {
                                        Label(message.isStarred ? "Remove Star" : "Star Message", systemImage: message.isStarred ? "star.slash" : "star")
                                    }
                                    if !message.body.isEmpty {
                                        Button { copyToSystemClipboard(message.body) } label: { Label("Copy Message", systemImage: "doc.on.doc") }
                                    }
                                    if message.lxmfID != nil {
                                        Button { replyingTo = message } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                        Menu("React", systemImage: "face.smiling") {
                                            ForEach(["👍", "❤️", "😂", "😮", "😢", "👎"], id: \.self) { reaction in
                                                Button(reaction) { Task { await store.sendReaction(reaction, to: message) } }
                                            }
                                        }
                                    }
                                    Button { messageToForward = message } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                                    Button { copyToSystemClipboard(messageMetadata(message)) } label: {
                                        Label("Copy Message Details", systemImage: "info.square")
                                    }
                                    Button { inspectedMessage = message } label: {
                                        Label("Show Message Details", systemImage: "info.circle")
                                    }
                                    if message.direction == .incoming,
                                       let reportURL = SidebandSafetyReport.emailURL(for: conversation, message: message) {
                                        Link(destination: reportURL) {
                                            Label("Report Message", systemImage: "exclamationmark.bubble")
                                        }
                                    }
                                    if !message.attachments.isEmpty {
                                        Menu("Copy Attachment Details", systemImage: "paperclip") {
                                            ForEach(message.attachments) { attachment in
                                                Button(attachment.filename) { copyToSystemClipboard(attachmentMetadata(attachment)) }
                                            }
                                        }
                                    }
                                    if message.direction == .outgoing && (message.state == .failed || (message.state == .queued && message.scheduledFor == nil)) {
                                        Button { Task { await store.retryMessage(message.id) } } label: { Label("Retry Now", systemImage: "arrow.clockwise") }
                                    }
                                    if message.direction == .outgoing && message.state == .queued && message.scheduledFor != nil {
                                        Button { Task { await store.sendScheduledMessageNow(message.id) } } label: { Label("Send Scheduled Message Now", systemImage: "paperplane") }
                                        Button(role: .destructive) { Task { await store.cancelScheduledMessage(message.id) } } label: { Label("Cancel Scheduled Message", systemImage: "calendar.badge.minus") }
                                    }
                                    if message.direction == .outgoing {
                                        Button { presentPaperMessage(message) } label: { Label("Show Paper Message QR", systemImage: "qrcode") }
                                    }
                                    if message.direction == .outgoing && message.state == .failed {
                                        Button(role: .destructive) { Task { await store.removeFailedMessage(message.id) } } label: { Label("Remove Failed Message", systemImage: "trash") }
                                    }
                                    Button(role: .destructive) { messagePendingDeletion = message } label: {
                                        Label("Delete Message", systemImage: "trash")
                                    }
                                }
                                if message.direction == .incoming { Spacer(minLength: 80) }
                            }
                        }
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                    }.padding()
                }
                .onAppear { scrollToBottom(using: proxy) }
                .onChange(of: conversation.id) { _, _ in scrollToBottom(using: proxy) }
                .onChange(of: conversationMessages.last?.id) { _, _ in scrollToBottom(using: proxy) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let replyingTo {
                    HStack(spacing: 8) {
                        Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Replying to \(replyingTo.direction == .incoming ? conversation.displayName : "yourself")")
                                .font(.caption.bold())
                            Text(replyPreview(replyingTo)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { self.replyingTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Cancel reply")
                            .help("Cancel this reply and return to a normal message")
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if !pendingAttachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(pendingAttachments) { attachment in
                                HStack(spacing: 5) {
                                    Image(systemName: isAudio(attachment) ? "waveform" : "paperclip")
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(attachment.filename).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Button { discardPendingAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(attachment.filename)")
                                        .help("Remove \(attachment.filename) from this outgoing message")
                                }.font(.caption).padding(6).background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                if let pendingVoiceAudio {
                    HStack {
                        Label("\(pendingVoiceAudio.mode.isCodec2 ? "Codec2" : "Opus") voice message · \(ByteCountFormatter.string(fromByteCount: Int64(pendingVoiceAudio.encodedAudio.count), countStyle: .file))", systemImage: "waveform")
                        Spacer()
                        Button { self.pendingVoiceAudio = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Remove voice message")
                    }
                    .font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if let scheduledFor {
                    HStack {
                        Label("Scheduled", systemImage: "calendar.badge.clock")
                        DatePicker("Delivery time", selection: Binding(get: { scheduledFor }, set: { self.scheduledFor = $0 }), in: Date.now.addingTimeInterval(60)...Date.now.addingTimeInterval(366 * 24 * 60 * 60))
                            .labelsHidden()
                        Spacer()
                        Button("Cancel", role: .cancel) { self.scheduledFor = nil }
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button(action: shareTelemetry) {
                        if telemetryCapture.isRequesting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "location.fill") }
                    }
                    .help("Share current location and device telemetry")
                    .disabled(telemetryCapture.isRequesting || !conversation.telemetrySharingEnabled)
                    Button { showingFileImporter = true } label: { Image(systemName: "paperclip") }
                        .help("Attach files")
                        .disabled(pendingAttachments.count >= SidebandMessageLimits.maximumAttachments)
                    Button(action: toggleVoiceRecording) {
                        Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(voiceRecorder.isRecording ? .red : Color.accentColor)
                    }
                    .help(voiceRecorder.isRecording ? "Finish voice message" : "Record voice message")
                    .disabled(voiceRecorder.isPreparing || (!voiceRecorder.isRecording && pendingAttachments.count >= SidebandMessageLimits.maximumAttachments))
                    Button { composeAsMarkdown.toggle() } label: {
                        Image(systemName: "textformat")
                            .foregroundStyle(composeAsMarkdown ? Color.accentColor : .secondary)
                    }
                    .help(composeAsMarkdown ? "Markdown formatting enabled" : "Enable Markdown formatting")
                    .accessibilityLabel(composeAsMarkdown ? "Disable Markdown formatting" : "Enable Markdown formatting")
                    Button { scheduledFor = scheduledFor == nil ? Date.now.addingTimeInterval(60 * 60) : nil } label: {
                        Image(systemName: scheduledFor == nil ? "calendar.badge.clock" : "calendar.badge.checkmark")
                    }
                    .help(scheduledFor == nil ? "Schedule message" : "Cancel scheduled delivery")
                    TextField("Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .composer)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .disabled(voiceRecorder.isRecording)
                        .help(voiceRecorder.isRecording ? "Finish or cancel the voice recording before entering text" : "Compose a message for \(conversation.displayName). \(remainingDraftCharacters) characters remain.")
                        .accessibilityIdentifier("message-composer")
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend || voiceRecorder.isRecording)
                        .help(sendButtonHelp)
                        .accessibilityLabel("Send message")
                        .accessibilityIdentifier("send-message")
                }
                HStack {
                    if voiceRecorder.isRecording {
                        Label(formatDuration(voiceRecorder.elapsed), systemImage: "waveform")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Recording voice message, \(formatDuration(voiceRecorder.elapsed))")
                        Button("Cancel recording", role: .destructive) { voiceRecorder.cancel() }
                            .font(.caption)
                            .help("Discard the current \(formatDuration(voiceRecorder.elapsed)) voice recording")
                    }
                    Spacer()
                    Text("\(remainingDraftCharacters.formatted()) characters remaining")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(remainingDraftCharacters <= 256 ? .orange : .secondary)
                        .accessibilityLabel("\(remainingDraftCharacters) message characters remaining")
                }
            }.padding()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await importAttachments(urls) }
            return true
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await importAttachments(urls) } }
        }
        .fileExporter(
            isPresented: $showingConversationExporter,
            document: conversationExportDocument,
            contentType: .json,
            defaultFilename: "Lower-Sideband-\(conversation.displayName.replacingOccurrences(of: "/", with: "-"))"
        ) { result in
            if case let .failure(error) = result { store.lastError = "Could not export conversation: \(error.localizedDescription)" }
            conversationExportDocument = nil
        }
        .onAppear {
            isVisible = true
            draft = store.draft(for: conversation.id)
            store.conversationDidAppear(conversation.id)
            #if os(macOS)
            focusedField = .composer
            #endif
        }
        .onDisappear {
            isVisible = false
            draftSaveTask?.cancel()
            store.updateDraft(draft, for: conversation.id)
            voiceRecorder.cancel()
            discardAllPendingAttachments()
            store.conversationDidDisappear(conversation.id)
            if let previewAttachment {
                Task { await store.attachmentStore.removeMaterializedFile(for: previewAttachment) }
            }
        }
        .onChange(of: draft) { _, value in
            if value.count > SidebandMessageLimits.maximumTextCharacters {
                draft = String(value.prefix(SidebandMessageLimits.maximumTextCharacters))
            } else {
                guard value != store.draft(for: conversation.id) else { return }
                draftSaveTask?.cancel()
                draftSaveTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    store.updateDraft(value, for: conversation.id)
                }
            }
        }
        .quickLookPreview($previewAttachmentURL)
        .onChange(of: previewAttachmentURL) { _, newValue in
            guard newValue == nil, let attachment = previewAttachment else { return }
            previewAttachment = nil
            Task { await store.attachmentStore.removeMaterializedFile(for: attachment) }
        }
        .sheet(isPresented: $showingContactQR) {
            if let contactLink = store.contactLink(for: conversation.id) {
                ContactQRCodeView(name: conversation.displayName, link: contactLink.url)
            }
        }
        .sheet(isPresented: $showingMediaBrowser) {
            ConversationMediaView(store: store, conversation: conversation)
        }
        .sheet(isPresented: $showingIdentityVerification) {
            ContactIdentityVerificationView(store: store, conversation: conversation)
        }
        .sheet(isPresented: $showingTelemetryMap) {
            ConversationTelemetryMapView(conversationName: conversation.displayName, messages: telemetryMessages)
        }
        .sheet(isPresented: Binding(
            get: { paperMessageURI != nil },
            set: { if !$0 { paperMessageURI = nil } }
        )) {
            if let paperMessageURI {
                PaperMessageQRCodeView(recipientName: conversation.displayName, uri: paperMessageURI)
            }
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(get: { messagePendingDeletion != nil }, set: { if !$0 { messagePendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Message", role: .destructive) {
                guard let message = messagePendingDeletion else { return }
                messagePendingDeletion = nil
                Task { await store.deleteMessage(message.id) }
            }
            Button("Cancel", role: .cancel) { messagePendingDeletion = nil }
        } message: {
            Text("This removes the message and its attachments from your synced Lower Sideband history. It cannot recall copies already delivered to another device.")
        }
        .sheet(item: $inspectedMessage) { message in
            MessageDetailsView(
                conversationName: conversation.displayName,
                destinationHash: conversation.destinationHash,
                message: message,
                details: messageMetadata(message)
            )
        }
        .sheet(item: $messageToForward) { message in
            ForwardMessageView(store: store, sourceConversationID: conversation.id, message: message)
        }
        .alert("Rename Conversation", isPresented: $showingRename) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { }
            Button("Save") { _ = store.renameConversation(conversation.id, to: renameDraft) }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose the private name shown for this chat on your synced devices.")
        }
    }

    private var compactConversationHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: conversation.appearanceSymbol.rawValue)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(appearanceColor(conversation.appearanceColor), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    renameConversationButton(font: .headline)
                    if conversation.isTrusted {
                        Label("Trusted", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if !conversation.contactNote.isEmpty {
                        Text(conversation.contactNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(conversation.destinationHash)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            Button { copyToSystemClipboard(conversation.destinationHash) } label: {
                                Label("Copy Destination", systemImage: "number")
                            }
                            if let contactLink = store.contactLink(for: conversation.id) {
                                Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: {
                                    Label("Copy Contact Link", systemImage: "link")
                                }
                            }
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Label(routingStatus, systemImage: routingIcon)
                        .accessibilityLabel("Routing status: \(routingStatus)")
                    Label(connectedRouteText, systemImage: "point.3.connected.trianglepath.dotted")
                        .help(connectedRouteHelp)
                        .accessibilityLabel("Current route: \(connectedRouteHelp)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 12) {
                TextField("Search messages", text: $messageSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .focused($focusedField, equals: .search)
                    .accessibilityIdentifier("message-search")
                    .help(messageSearch.isEmpty ? "Search messages in this conversation" : "Search is active with \(filteredMessages.count) result\(filteredMessages.count == 1 ? "" : "s")")
                if store.contactLink(for: conversation.id) != nil {
                    Button { showingContactQR = true } label: { Image(systemName: "qrcode") }
                        .buttonStyle(.plain)
                        .help("Show the contact link for \(conversation.displayName) as a QR code")
                        .accessibilityLabel("Show contact QR code")
                }
                Button { showingIdentityVerification = true } label: {
                    Image(systemName: store.isConversationIdentityVerified(conversation.id) ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(store.isConversationIdentityVerified(conversation.id) ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(store.isConversationIdentityVerified(conversation.id) ? "Identity fingerprint verified for \(conversation.displayName)" : "Compare and verify \(conversation.displayName)'s identity fingerprint")
                .accessibilityLabel(store.isConversationIdentityVerified(conversation.id) ? "Contact identity verified" : "Verify contact identity")
                Button { Task { await store.startVoiceCall(conversationID: conversation.id) } } label: {
                    Image(systemName: "phone.fill")
                }
                .buttonStyle(.plain)
                .disabled(store.voiceCall != nil || conversation.isBlocked || store.networkState != .ready)
                .help(conversation.isBlocked ? "Voice calling is unavailable because this contact is blocked" : (store.networkState == .ready ? "Start an end-to-end encrypted LXST voice call" : "Voice calling requires an active Reticulum connection"))
                .accessibilityLabel("Start encrypted voice call")
                compactConversationMenu
            }

            if !messageSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Picker("Search scope", selection: $messageSearchScope) {
                        ForEach(SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("\(filteredMessages.count) \(filteredMessages.count == 1 ? "result" : "results")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { messageSearch = "" } label: { Label("Clear", systemImage: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var compactConversationMenu: some View {
        Menu {
            Button("Rename Conversation", systemImage: "pencil") { beginRename() }
            Divider()
            if !telemetryMessages.isEmpty {
                Button("Show telemetry map", systemImage: "map") { showingTelemetryMap = true }
            }
            if !store.starredMessages(for: conversation.id).isEmpty {
                Button(showStarredOnly ? "Show all messages" : "Show starred messages", systemImage: showStarredOnly ? "star.fill" : "star") {
                    showStarredOnly.toggle()
                }
            }
            if let transcript = store.conversationTranscript(conversation.id) {
                ShareLink(item: transcript, subject: Text("Lower Sideband conversation with \(conversation.displayName)")) {
                    Label("Share transcript", systemImage: "square.and.arrow.up")
                }
            }
            Button("Export conversation archive", systemImage: "doc.badge.arrow.up") {
                do {
                    conversationExportDocument = SnapshotBackupDocument(data: try store.exportConversationData(conversation.id))
                    showingConversationExporter = true
                } catch {
                    store.lastError = "Could not export conversation: \(error.localizedDescription)"
                }
            }
            Divider()
            Button("Search Messages", systemImage: "magnifyingglass") { focusedField = .search }
            Button("Focus Message Composer", systemImage: "text.cursor") { focusedField = .composer }
            Button { Task { await store.sendCommand(.ping, conversationID: conversation.id) } } label: {
                Label("Ping contact", systemImage: "wave.3.right")
            }
            Button { Task { await store.sendCommand(.signalReport, conversationID: conversation.id) } } label: {
                Label("Request signal report", systemImage: "chart.bar")
            }
            Button { Task { await store.requestTelemetry(conversationID: conversation.id, since: .now.addingTimeInterval(-604_800)) } } label: {
                Label("Request telemetry", systemImage: "location.viewfinder")
            }
            Menu("Plugin request", systemImage: "puzzlepiece.extension") {
                ForEach(store.pluginRegistry.manifests) { manifest in
                    if store.isPluginEnabled(manifest.identifier) {
                        ForEach(manifest.commands.sorted(), id: \.self) { command in
                            Button(command) { Task { await store.sendPluginCommand(command, conversationID: conversation.id) } }
                        }
                    }
                }
            }
            Divider()
            if let reportURL = SidebandSafetyReport.emailURL(for: conversation) {
                Link(destination: reportURL) {
                    Label("Report Contact", systemImage: "exclamationmark.bubble")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.plain)
        .help("More actions for \(conversation.displayName), including export, search, LXMF commands and reporting")
        .accessibilityLabel("More conversation actions")
    }

    private func beginRename() {
        renameDraft = conversation.displayName
        showingRename = true
    }

    private func renameConversationButton(font: Font) -> some View {
        Button(action: beginRename) {
            HStack(spacing: 6) {
                Text(conversation.displayName)
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Rename conversation")
        .accessibilityLabel("Rename conversation \(conversation.displayName)")
    }

    private var bottomAnchorID: String { "conversation-bottom-\(conversation.id.uuidString)" }

    private var filteredMessages: [Message] {
        let visible = store.messages(for: conversation.id).filter { $0.reactionTo == nil && $0.commands.isEmpty }
        let all = showStarredOnly ? visible.filter(\.isStarred) : visible
        let query = messageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { message in
            let textMatch = message.body.localizedCaseInsensitiveContains(query) || (message.replyQuote?.localizedCaseInsensitiveContains(query) ?? false)
            let attachmentMatch = message.attachments.contains { $0.filename.localizedCaseInsensitiveContains(query) || ($0.mimeType?.localizedCaseInsensitiveContains(query) ?? false) }
            let telemetryMatch = message.telemetry.map { telemetry in
                String(describing: telemetry).localizedCaseInsensitiveContains(query)
            } ?? false
            let reactionMatch = store.reactionCounts(for: message.lxmfID, in: conversation.id).keys.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
            switch messageSearchScope {
            case .all: return textMatch || attachmentMatch || telemetryMatch || reactionMatch
            case .text: return textMatch
            case .attachments: return attachmentMatch
            case .telemetry: return telemetryMatch
            case .reactions: return reactionMatch
            }
        }
    }

    private func reactionSummaries(for message: Message) -> [ReactionSummary] {
        let counts = store.reactionCounts(for: message.lxmfID, in: conversation.id)
        return counts.keys.sorted().map { ReactionSummary(content: $0, count: counts[$0] ?? 0) }
    }

    private var telemetryMessages: [Message] {
        store.messages(for: conversation.id).filter { $0.telemetry?.location != nil }
    }

    private func presentPaperMessage(_ message: Message) {
        do { paperMessageURI = try store.paperMessageURI(for: message.id) }
        catch { store.lastError = error.localizedDescription }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func send() {
        let text = draft
        let attachments = pendingAttachments
        let voiceAudio = pendingVoiceAudio
        let repliedMessage = replyingTo
        let deliveryDate = scheduledFor
        draftSaveTask?.cancel()
        draft = ""
        store.updateDraft("", for: conversation.id)
        pendingAttachments = []
        pendingVoiceAudio = nil
        replyingTo = nil
        scheduledFor = nil
        let renderer: Message.Renderer = composeAsMarkdown ? .markdown : .plain
        Task {
            let accepted = await store.send(text, attachments: attachments, voiceAudio: voiceAudio, replyingTo: repliedMessage, renderer: renderer, scheduledFor: deliveryDate)
            guard !accepted else { return }
            guard isVisible else {
                for attachment in attachments { try? await store.attachmentStore.remove(attachment) }
                return
            }
            if draft.isEmpty {
                draft = text
                store.updateDraft(text, for: conversation.id)
            }
            for attachment in attachments where !pendingAttachments.contains(where: { $0.id == attachment.id }) {
                pendingAttachments.append(attachment)
            }
            if pendingVoiceAudio == nil { pendingVoiceAudio = voiceAudio }
            if replyingTo == nil { replyingTo = repliedMessage }
            if scheduledFor == nil { scheduledFor = deliveryDate }
        }
    }

    private func discardPendingAttachment(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        Task { try? await store.attachmentStore.remove(attachment) }
    }

    private func discardAllPendingAttachments() {
        let discarded = pendingAttachments
        pendingAttachments.removeAll()
        Task {
            for attachment in discarded { try? await store.attachmentStore.remove(attachment) }
        }
    }

    @ViewBuilder private func renderedBody(_ message: Message) -> some View {
        if message.renderer != .plain,
           store.shouldRenderRichText(message, conversationID: conversation.id),
           let attributed = SidebandRichTextRenderer.attributed(message.body, renderer: message.renderer) {
            Text(attributed)
        } else {
            Text(message.body)
        }
    }

    private func replyPreview(_ message: Message) -> String {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(280)) }
        if message.voiceAudio != nil { return "Voice message" }
        if let attachment = message.attachments.first { return "Attachment: \(attachment.filename)" }
        if message.telemetry != nil { return "Shared telemetry" }
        return "Message"
    }

    private func shareTelemetry() {
        Task {
            if let telemetry = await telemetryCapture.requestTelemetry() {
                let pluginSensors = await store.pluginRegistry.collectTelemetry()
                let enriched = SidebandTelemetry(capturedAt: telemetry.capturedAt, location: telemetry.location,
                                                  battery: telemetry.battery, additionalSensors: pluginSensors)
                await store.send("Shared telemetry", attachments: [], telemetry: enriched)
            } else if let error = telemetryCapture.lastError {
                store.lastError = error
            }
        }
    }

    private func toggleVoiceRecording() {
        if voiceRecorder.isRecording {
            let duration = voiceRecorder.elapsed
            guard let url = voiceRecorder.stop() else { return }
            guard duration >= 0.6 else {
                try? FileManager.default.removeItem(at: url)
                store.lastError = "Voice messages must be at least one second long."
                return
            }
            Task { await importVoiceRecording(url) }
        } else {
            Task {
                do { try await voiceRecorder.start() }
                catch { store.lastError = error.localizedDescription }
            }
        }
    }

    private func importVoiceRecording(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard store.validateAttachmentSelection(currentCount: pendingAttachments.count, adding: 1) else { return }
        do {
            if let mode = store.preferredVoiceMessageMode.codec2Mode {
                pendingVoiceAudio = try VoiceMessageCodec2Transcoder.encode(from: url, mode: mode)
            } else {
                pendingVoiceAudio = try VoiceMessageOpusEncoder.encodeOgg(from: url)
            }
        } catch {
            store.lastError = "Could not encode the voice message: \(error.localizedDescription)"
        }
    }

    private var remainingDraftCharacters: Int {
        max(0, SidebandMessageLimits.maximumTextCharacters - draft.count)
    }

    private var canSend: Bool {
        !conversation.isBlocked &&
        draft.count <= SidebandMessageLimits.maximumTextCharacters &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty || pendingVoiceAudio != nil)
    }

    private func messageAccessibilityLabel(_ message: Message, summaries precomputedSummaries: [ReactionSummary]? = nil) -> String {
        var parts = [
            message.direction == .outgoing ? "You" : conversation.displayName,
            message.body.isEmpty ? "Message" : message.body
        ]
        if let quote = message.replyQuote { parts.append("Replying to \(quote)") }
        if message.isStarred { parts.append("Starred") }
        if !message.attachments.isEmpty {
            parts.append("Attachments: \(message.attachments.map(\.filename).joined(separator: ", "))")
        }
        if message.telemetry != nil { parts.append("Includes telemetry") }
        if message.voiceAudio != nil { parts.append("Includes a low-bandwidth voice message") }
        let summaries = precomputedSummaries ?? reactionSummaries(for: message)
        if !summaries.isEmpty {
            parts.append("Reactions: " + summaries.map { "\($0.content) \($0.count)" }.joined(separator: ", "))
        }
        parts.append(message.state.rawValue)
        parts.append(message.timestamp.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: ", ")
    }

    private func messageMetadata(_ message: Message) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Local record ID: \(message.id.uuidString)",
            "Conversation: \(conversation.destinationHash)",
            "Direction: \(message.direction.rawValue)",
            "Delivery state: \(message.state.rawValue)",
            "Timestamp: \(formatter.string(from: message.timestamp))"
        ]
        if let lxmfID = message.lxmfID { lines.append("LXMF message hash: \(lxmfID.sidebandHex)") }
        if message.deliveryAttemptCount > 0 { lines.append("Delivery attempts: \(message.deliveryAttemptCount)") }
        if let attempt = message.lastDeliveryAttemptAt { lines.append("Last delivery attempt: \(formatter.string(from: attempt))") }
        if let mode = message.lastDeliveryMode { lines.append("Last delivery mode: \(mode.rawValue)") }
        if let failure = message.lastDeliveryFailure { lines.append("Last delivery issue: \(failure)") }
        if let scheduledFor = message.scheduledFor { lines.append("Scheduled for: \(formatter.string(from: scheduledFor))") }
        lines.append("Starred: \(message.isStarred ? "yes" : "no")")
        if let replyTo = message.replyTo { lines.append("Reply to LXMF hash: \(replyTo.sidebandHex)") }
        if let replyQuote = message.replyQuote { lines.append("Reply quote: \(replyQuote)") }
        if !message.attachments.isEmpty {
            lines.append("Attachments: \(message.attachments.count)")
            lines.append(contentsOf: message.attachments.map {
                "- \($0.filename) (\(ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file)), \($0.state.rawValue))"
            })
        }
        if let voice = message.voiceAudio {
            lines.append("LXMF audio mode: 0x\(String(format: "%02x", voice.mode.rawValue))")
            lines.append("Voice bytes: \(voice.encodedAudio.count)")
        }
        if let telemetry = message.telemetry {
            lines.append("Telemetry captured: \(formatter.string(from: telemetry.capturedAt))")
            if let location = telemetry.location {
                lines.append("Location: \(location.latitude), \(location.longitude)")
                lines.append("Accuracy: ±\(location.accuracy) m")
                lines.append("Altitude: \(location.altitude) m")
                lines.append("Speed: \(location.speed) km/h")
                lines.append("Bearing: \(location.bearing)°")
                lines.append("Location updated: \(formatter.string(from: location.updatedAt))")
            }
            if let battery = telemetry.battery {
                lines.append("Battery: \(battery.chargePercent)%\(battery.isCharging ? " (charging)" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func attachmentMetadata(_ attachment: Attachment) -> String {
        var lines = [
            "Attachment ID: \(attachment.id.uuidString)",
            "Filename: \(attachment.filename)",
            "MIME type: \(attachment.mimeType ?? "unknown")",
            "Size: \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))",
            "Transfer state: \(attachment.state.rawValue)"
        ]
        if let contentHash = attachment.contentHash {
            lines.append("SHA-256: \(contentHash.map { String(format: "%02x", $0) }.joined())")
        }
        return lines.joined(separator: "\n")
    }

    private func importAttachments(_ urls: [URL]) async {
        guard store.validateAttachmentSelection(currentCount: pendingAttachments.count, adding: urls.count) else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let attachment = try await store.attachmentStore.importFile(from: url)
                if store.validateAttachmentIsUnique(attachment, among: pendingAttachments),
                   store.validateAttachmentTotal(pendingAttachments + [attachment]) {
                    pendingAttachments.append(attachment)
                } else {
                    try? await store.attachmentStore.remove(attachment)
                }
            } catch {
                store.reportAttachmentImportFailure(filename: url.lastPathComponent, error: error)
            }
        }
    }

    private func attachmentStatus(_ attachment: Attachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
        if attachment.state == .local || attachment.state == .queued { return "\(size) · Queued for Resource transfer" }
        if attachment.state == .transferring { return "\(size) · \(Int(attachment.progress * 100))%" }
        return "\(size) · \(attachment.state.rawValue.capitalized)"
    }

    private func isImage(_ attachment: Attachment) -> Bool {
        if let mimeType = attachment.mimeType, UTType(mimeType: mimeType)?.conforms(to: .image) == true { return true }
        guard let ext = attachment.filename.split(separator: ".").last else { return false }
        return UTType(filenameExtension: String(ext))?.conforms(to: .image) == true
    }

    private func isAudio(_ attachment: Attachment) -> Bool {
        if let mimeType = attachment.mimeType, UTType(mimeType: mimeType)?.conforms(to: .audio) == true { return true }
        guard let ext = attachment.filename.split(separator: ".").last else { return false }
        return UTType(filenameExtension: String(ext))?.conforms(to: .audio) == true
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder private func attachmentControls(_ message: Message, _ attachment: Attachment) -> some View {
        if attachment.state == .failed { Button("Retry") { retry(message, attachment) }.font(.caption) }
        else if attachment.state == .transferring { Button("Cancel") { cancel(message, attachment) }.font(.caption) }
    }
    private func retry(_ message: Message, _ attachment: Attachment) { Task { await store.retryAttachment(messageID: message.id, attachmentID: attachment.id) } }
    private func cancel(_ message: Message, _ attachment: Attachment) { Task { await store.cancelAttachment(messageID: message.id, attachmentID: attachment.id) } }
    private func preview(_ attachment: Attachment) {
        Task {
            if let previous = previewAttachment {
                await store.attachmentStore.removeMaterializedFile(for: previous)
            }
            do {
                previewAttachment = attachment
                previewAttachmentURL = try await store.attachmentStore.materializedURL(for: attachment)
            } catch {
                previewAttachment = nil
                previewAttachmentURL = nil
            }
        }
    }

    private var routingStatus: String {
        if store.activeLinkHashes.contains(conversation.destinationHash) { return "Encrypted" }
        if store.pendingLinkHashes.contains(conversation.destinationHash) { return "Connecting securely" }
        if store.isPathPending(to: conversation.destinationHash) { return "Finding route" }
        if store.hasPath(to: conversation.destinationHash) { return "Route available" }
        return store.networkState == .ready ? "Ready" : "Connecting"
    }
    private var routingHelp: String {
        if store.activeLinkHashes.contains(conversation.destinationHash) { return "An authenticated encrypted Reticulum link to \(conversation.displayName) is active." }
        if store.pendingLinkHashes.contains(conversation.destinationHash) { return "An encrypted link to \(conversation.displayName) is being established." }
        if store.isPathPending(to: conversation.destinationHash) { return "Reticulum is currently searching all active interfaces for a path to \(conversation.displayName)." }
        if store.hasPath(to: conversation.destinationHash) { return "A Reticulum route to \(conversation.displayName) is available; messages can be sent." }
        return store.networkState == .ready ? "The network is ready, but no route to \(conversation.displayName) is known yet." : "The app is connecting to Reticulum before it can find this contact."
    }
    private var connectedRouteText: String {
        if let route = store.connectedRoute(to: conversation.destinationHash) {
            let hopText = route.hops == 1 ? "1 hop" : "\(route.hops) hops"
            return "Via \(route.interfaceName) · \(hopText)"
        }
        let readyInterfaces = store.networkInterfaces.filter { $0.state == .ready }
        if readyInterfaces.count == 1, let interface = readyInterfaces.first {
            return "Connected: \(interface.name)"
        }
        if readyInterfaces.count > 1 {
            return "Connected: \(readyInterfaces.count) routes"
        }
        if store.autoInterfaceEnabled, !store.autoInterfaceDiscovery.peers.isEmpty {
            return "Connected: AutoInterface"
        }
        if store.rnodeManager.hasReadyInterface {
            return "Connected: RNode"
        }
        return store.networkState == .ready ? "Route pending" : "No active route"
    }
    private var connectedRouteHelp: String {
        if let route = store.connectedRoute(to: conversation.destinationHash) {
            let hopText = route.hops == 1 ? "1 Reticulum hop" : "\(route.hops) Reticulum hops"
            let endpointText = route.endpoint.map { " at \($0)" } ?? ""
            return "Messages to \(conversation.displayName) currently use \(route.interfaceName)\(endpointText), \(hopText)."
        }
        let readyInterfaces = store.networkInterfaces.filter { $0.state == .ready }
        if !readyInterfaces.isEmpty {
            let names = readyInterfaces.map(\.name).joined(separator: ", ")
            return "Connected interfaces: \(names). A destination-specific route has not been discovered yet."
        }
        if store.autoInterfaceEnabled, !store.autoInterfaceDiscovery.peers.isEmpty {
            return "Connected to nearby Reticulum peers through AutoInterface; a destination-specific route is pending."
        }
        if store.rnodeManager.hasReadyInterface {
            return "Connected through an RNode radio; a destination-specific route is pending."
        }
        return "No Reticulum route is currently connected."
    }
    private var sendButtonHelp: String {
        if voiceRecorder.isRecording { return "Finish or cancel the voice recording before sending" }
        if conversation.isBlocked { return "Unblock \(conversation.displayName) before sending a message" }
        if draft.count > SidebandMessageLimits.maximumTextCharacters { return "The message exceeds the maximum length" }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty { return "Enter a message or add an attachment before sending" }
        if let scheduledFor { return "Queue this message for \(scheduledFor.formatted(date: .abbreviated, time: .shortened))" }
        return "Send this message to \(conversation.displayName); it will remain queued until Reticulum accepts it"
    }
    private func messageHoverHelp(_ message: Message) -> String {
        var text = message.direction == .outgoing ? "Outgoing message" : "Incoming message from \(conversation.displayName)"
        text += " — \(message.state.rawValue), \(message.timestamp.formatted(date: .abbreviated, time: .standard))"
        if message.deliveryAttemptCount > 1 { text += ", \(message.deliveryAttemptCount) delivery attempts" }
        if let failure = message.lastDeliveryFailure { text += ". Last issue: \(failure)" }
        else if message.state == .queued { text += ". Waiting for a usable route or scheduled delivery time." }
        return text + " Right-click for message actions."
    }
    private var routingIcon: String {
        if store.activeLinkHashes.contains(conversation.destinationHash) { return "lock.shield.fill" }
        if store.networkState == .ready { return "network" }
        return "arrow.triangle.2.circlepath"
    }
}

private struct ContactIdentityVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    let conversation: Conversation

    private var isVerified: Bool { store.isConversationIdentityVerified(conversation.id) }
    private var fingerprint: String? { store.identityFingerprint(for: conversation.id) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label(isVerified ? "Identity verified" : "Identity not verified", systemImage: isVerified ? "checkmark.shield.fill" : "shield")
                    .font(.title2.bold())
                    .foregroundStyle(isVerified ? .green : .secondary)
                Text("Compare this fingerprint with \(conversation.displayName) over a separate trusted channel or in person. A matching fingerprint confirms the public key used to authenticate encrypted LXMF messages.")
                    .foregroundStyle(.secondary)
                if let fingerprint {
                    Text(fingerprint)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Identity fingerprint \(fingerprint)")
                    Button { copyToSystemClipboard(fingerprint) } label: { Label("Copy Fingerprint", systemImage: "doc.on.doc") }
                        .accessibilityHint("Copies the full identity fingerprint for comparison on a trusted channel")
                    Button(isVerified ? "Remove Verification" : "Mark Fingerprint Verified") {
                        _ = store.setConversationIdentityVerified(!isVerified, conversationID: conversation.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isVerified ? .orange : .accentColor)
                    .accessibilityHint(isVerified ? "Removes the locally pinned identity verification" : "Pins this exact public identity key as verified")
                } else {
                    ContentUnavailableView(
                        "Public Identity Unknown",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Scan the contact's keyed Lower Sideband QR code or receive a validated announce before verifying them.")
                    )
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Verify Contact")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 450)
        #endif
    }
}

private struct MessageDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let conversationName: String
    let destinationHash: String
    let message: Message
    let details: String

    var body: some View {
        NavigationStack {
            List {
                Section("Message") {
                    detail("Conversation", conversationName)
                    detail("Direction", message.direction.rawValue.capitalized)
                    detail("State", message.state.rawValue.capitalized)
                    detail("Sent", message.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                Section("Protocol identifiers") {
                    detail("Destination", destinationHash, monospaced: true)
                    detail("Local record", message.id.uuidString.lowercased(), monospaced: true)
                    if let lxmfID = message.lxmfID { detail("LXMF hash", lxmfID.sidebandHex, monospaced: true) }
                    if let replyTo = message.replyTo { detail("Replies to", replyTo.sidebandHex, monospaced: true) }
                }
                if let replyQuote = message.replyQuote {
                    Section("Quoted message") { Text(replyQuote).textSelection(.enabled) }
                }
                if !message.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(message.attachments) { attachment in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attachment.filename)
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)) · \(attachment.state.rawValue.capitalized)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Message Details")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { copyToSystemClipboard(details) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }

    @ViewBuilder private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if monospaced { Text(value).font(.callout.monospaced()).textSelection(.enabled) }
            else { Text(value).textSelection(.enabled) }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ForwardMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    let sourceConversationID: UUID
    let message: Message
    @State private var query = ""
    @State private var isForwarding = false

    private var destinations: [Conversation] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.conversations.filter {
            $0.id != sourceConversationID && !$0.isArchived && !$0.isBlocked &&
                (normalized.isEmpty || $0.displayName.localizedCaseInsensitiveContains(normalized) || $0.destinationHash.localizedCaseInsensitiveContains(normalized))
        }
    }

    var body: some View {
        NavigationStack {
            List(destinations) { conversation in
                Button {
                    isForwarding = true
                    Task {
                        if await store.forwardMessage(message.id, to: conversation.id) { dismiss() }
                        isForwarding = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.displayName).font(.headline)
                        Text(conversation.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .disabled(isForwarding)
            }
            .overlay {
                if destinations.isEmpty {
                    ContentUnavailableView("No Other Conversations", systemImage: "arrowshape.turn.up.right", description: Text("Start another conversation before forwarding this message."))
                }
            }
            .searchable(text: $query, prompt: "Find a conversation")
            .navigationTitle("Forward Message")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }
}

private struct CallHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore

    var body: some View {
        NavigationStack {
            Group {
                if store.voiceCallHistory.isEmpty {
                    ContentUnavailableView("No Calls", systemImage: "phone", description: Text("Encrypted voice calls will appear here."))
                } else {
                    List(store.voiceCallHistory) { call in
                        callRow(call)
                    }
                }
            }
            .navigationTitle("Calls")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    @ViewBuilder private func callRow(_ call: VoiceCall) -> some View {
        let conversation = store.conversations.first { $0.id == call.conversationID }
        HStack(spacing: 12) {
            Image(systemName: callIcon(call))
                .foregroundStyle(callColor(call))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation?.displayName ?? "Unknown contact").font(.headline)
                HStack(spacing: 5) {
                    Text(outcomeText(call))
                    if let duration = call.connectedDuration {
                        Text("· \(durationText(duration))")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Text(call.startedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
                if let failure = call.failureReason, call.historyOutcome != .missed {
                    Text(failure).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            if let conversation {
                Button {
                    dismiss()
                    Task { await store.startVoiceCall(conversationID: conversation.id) }
                } label: {
                    Label(call.direction == .incoming ? "Call back" : "Call again", systemImage: "phone.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!canCall(conversation))
            }
        }
        .padding(.vertical, 4)
    }

    private func canCall(_ conversation: Conversation) -> Bool {
        store.voiceCall == nil && !conversation.isBlocked && store.networkState == .ready &&
            store.discoveries.contains { $0.destinationHash == conversation.destinationHash && $0.publicKey != nil }
    }

    private func callIcon(_ call: VoiceCall) -> String {
        switch call.historyOutcome {
        case .missed: "phone.down.fill"
        case .failed: "exclamationmark.circle.fill"
        case .declined: "phone.down"
        case .completed, .cancelled: call.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right"
        }
    }

    private func callColor(_ call: VoiceCall) -> Color {
        switch call.historyOutcome {
        case .missed: .red
        case .failed: .orange
        case .completed: .green
        case .declined, .cancelled: .secondary
        }
    }

    private func outcomeText(_ call: VoiceCall) -> String {
        switch call.historyOutcome {
        case .completed: call.direction == .incoming ? "Incoming" : "Outgoing"
        case .missed: "Missed"
        case .declined: "Declined"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceCallView: View {
    @Bindable var store: SidebandStore
    #if os(iOS)
    private var audio: LiveVoiceAudioEngine { CallKitCoordinator.shared.audioEngine }
    #else
    @State private var audio = LiveVoiceAudioEngine()
    #endif
    @State private var elapsed = 0
    @State private var timerTask: Task<Void, Never>?

    private var call: VoiceCall? { store.voiceCall }
    private var conversation: Conversation? {
        guard let call else { return nil }
        return store.conversations.first { $0.id == call.conversationID }
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: call?.direction == .incoming && call?.state == .incoming ? "phone.arrow.down.left.fill" : "waveform.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(call?.state == .active ? .green : Color.accentColor)
            VStack(spacing: 6) {
                Text(conversation?.displayName ?? "Voice Call").font(.title2.bold())
                Text(statusText).foregroundStyle(.secondary)
                if call?.state == .active {
                    Text(callDuration).font(.title3.monospacedDigit())
                    #if os(iOS)
                    Label(audio.audioRouteName, systemImage: audio.isSpeakerEnabled ? "speaker.wave.2.fill" : "airplayaudio")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    if audio.isPlaybackRecovering || audio.droppedPlaybackFrames > 0 {
                        Label(callQualityText, systemImage: "waveform.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Label("End-to-end encrypted LXST call", systemImage: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if call?.direction == .incoming, call?.state == .incoming {
                HStack(spacing: 26) {
                    callButton("Decline", systemImage: "phone.down.fill", color: .red) { declineCall() }
                    callButton("Answer", systemImage: "phone.fill", color: .green) { answerCall() }
                }
            } else {
                HStack(spacing: 20) {
                    callButton(audio.isMuted ? "Unmute" : "Mute", systemImage: audio.isMuted ? "mic.slash.fill" : "mic.fill", color: .secondary) {
                        setMuted(!audio.isMuted)
                    }
                    #if os(iOS)
                    callButton(audio.isSpeakerEnabled ? "Speaker" : "Audio", systemImage: audio.isSpeakerEnabled ? "speaker.wave.2.fill" : "airplayaudio", color: .secondary) {
                        audio.toggleSpeakerRoute()
                    }
                    #endif
                    callButton("Hang Up", systemImage: "phone.down.fill", color: .red) { endCall() }
                }
            }
        }
        .padding(36)
        .frame(minWidth: 340, minHeight: 390)
        .interactiveDismissDisabled(call != nil)
        .onAppear { configureAudio(for: call?.state) }
        .onChange(of: call?.state) { _, state in configureAudio(for: state) }
        .onDisappear {
            timerTask?.cancel()
            #if os(macOS)
            audio.stop()
            store.setVoiceFrameHandler(nil)
            #endif
        }
    }

    @ViewBuilder private func callButton(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2).frame(width: 54, height: 54).background(color, in: Circle()).foregroundStyle(.white)
                Text(title).font(.caption)
            }
        }.buttonStyle(.plain)
    }

    private var statusText: String {
        switch call?.state {
        case .findingRoute: "Finding a secure route…"
        case .connecting: "Connecting securely…"
        case .ringing: "Ringing…"
        case .incoming: "Incoming encrypted call"
        case .active: call?.profile.displayName ?? "Connected"
        case .ending: "Ending call…"
        case .failed: "Call failed"
        case .idle, nil: "Call ended"
        }
    }

    private var callDuration: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var callQualityText: String {
        if audio.droppedPlaybackFrames > 0 { return "Network congestion detected" }
        return "Audio connection recovering"
    }

    private func configureAudio(for state: VoiceCallState?) {
        guard state == .active, !audio.isRunning else { return }
        #if os(macOS)
        audio.onEncodedFrame = { payload in Task { await store.sendVoiceFrame(payload) } }
        store.setVoiceFrameHandler { codec, payload in audio.play(payload, codec: codec) }
        #endif
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                elapsed = Int(Date.now.timeIntervalSince(call?.connectedAt ?? .now))
                #if os(iOS)
                audio.refreshAudioRoute()
                audio.recoverAudioIfNeeded()
                #endif
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #if os(macOS)
        Task {
            do {
                try audio.configure(profile: call?.profile ?? .mediumQuality)
                try await audio.start()
            }
            catch { store.lastError = error.localizedDescription; await store.hangUpVoiceCall() }
        }
        #endif
    }

    private func answerCall() {
        #if os(iOS)
        CallKitCoordinator.shared.requestAnswer()
        #else
        Task { await store.answerVoiceCall() }
        #endif
    }

    private func declineCall() {
        #if os(iOS)
        CallKitCoordinator.shared.requestEnd()
        #else
        Task { await store.declineVoiceCall() }
        #endif
    }

    private func endCall() {
        #if os(iOS)
        CallKitCoordinator.shared.requestEnd()
        #else
        Task { await store.hangUpVoiceCall() }
        #endif
    }

    private func setMuted(_ muted: Bool) {
        #if os(iOS)
        CallKitCoordinator.shared.requestMuted(muted)
        #else
        audio.isMuted = muted
        #endif
    }
}

private struct ContactQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let link: URL

    var body: some View {
        VStack(spacing: 16) {
            HStack { Text(name).font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            if let image = qrImage {
                platformImage(image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel("Contact QR code for \(name)")
            } else {
                ContentUnavailableView("QR Code Unavailable", systemImage: "qrcode")
            }
            Text(link.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
        }
        .padding(24)
        .platformContactSheetSize()
    }

    private var qrImage: PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
#if os(macOS)
        return NSImage(cgImage: cgImage, size: .zero)
#else
        return UIImage(cgImage: cgImage)
#endif
    }

    private func platformImage(_ image: PlatformImage) -> Image {
#if os(macOS)
        Image(nsImage: image)
#else
        Image(uiImage: image)
#endif
    }
}

private struct PaperMessageQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let recipientName: String
    let uri: String

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Encrypted Paper Message").font(.title2.bold())
                    Text("For \(recipientName)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            if let image = qrImage {
                platformImage(image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel("Encrypted LXMF paper message QR code for \(recipientName)")
            } else {
                ContentUnavailableView("QR Code Unavailable", systemImage: "qrcode")
            }
            Text("The message content and signature are encrypted for the recipient's LXMF identity.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { copyToSystemClipboard(uri) } label: { Label("Copy LXM Link", systemImage: "doc.on.doc") }
                ShareLink(item: uri) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Text(uri).font(.caption2.monospaced()).lineLimit(3).textSelection(.enabled)
        }
        .padding(24)
        .platformContactSheetSize()
    }

    private var qrImage: PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: .zero)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

private struct AttachmentShareButton: View {
    let store: AttachmentStore
    let attachment: Attachment
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").font(.caption) }
            }
        }
        .task(id: attachment.relativePath) {
            url = try? await store.materializedURL(for: attachment)
        }
        .onDisappear {
            url = nil
            Task { await store.removeMaterializedFile(for: attachment) }
        }
    }
}

private struct InlineLXMFVoiceMessageView: View {
    let audio: LXMFVoiceMessageAudio
    @State private var player = AudioAttachmentPlayer()
    @State private var temporaryURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain).disabled(!player.isReady)
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(0.1, player.duration))
                    .frame(minWidth: 120).disabled(!player.isReady)
                Text("\(format(player.currentTime))/\(format(player.duration))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Label("LXMF voice · \(audio.mode == .opusOgg ? "Opus 8 kbps" : "Codec2") · \(ByteCountFormatter.string(fromByteCount: Int64(audio.encodedAudio.count), countStyle: .file))", systemImage: "waveform")
                .font(.caption)
        }
        .frame(maxWidth: 340)
        .task(id: audio.encodedAudio) {
            let fileExtension = audio.mode.isOggOpus ? "ogg" : "caf"
            let url = FileManager.default.temporaryDirectory.appending(path: "Sideband-LXMF-\(UUID().uuidString).\(fileExtension)")
            do {
                if audio.mode.isOggOpus {
                    try audio.encodedAudio.write(to: url, options: .atomic)
                } else {
                    try VoiceMessageCodec2Transcoder.decode(audio, to: url)
                }
                temporaryURL = url
                player.load(url)
            } catch { try? FileManager.default.removeItem(at: url) }
        }
        .onDisappear {
            player.stop()
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            temporaryURL = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("LXMF low-bandwidth voice message")
    }

    private func format(_ duration: TimeInterval) -> String {
        let total = duration.isFinite ? max(0, Int(duration.rounded(.down))) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct InlineAudioAttachmentView: View {
    let store: AttachmentStore
    let attachment: Attachment
    let status: String
    let onRetry: () -> Void
    let onCancel: () -> Void
    @State private var player = AudioAttachmentPlayer()
    @State private var materializedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!player.isReady)
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(0.1, player.duration)
                )
                .frame(minWidth: 120)
                .disabled(!player.isReady)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(format(player.currentTime)) of \(format(player.duration))")
                Text("\(format(player.currentTime))/\(format(player.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Label(attachment.filename, systemImage: "waveform")
                .font(.caption)
                .lineLimit(1)
            Text(status).font(.caption2).foregroundStyle(.secondary)
            if attachment.state == .failed { Button("Retry", action: onRetry).font(.caption) }
            else if attachment.state == .transferring { Button("Cancel", action: onCancel).font(.caption) }
        }
        .frame(maxWidth: 340)
        .task(id: attachment.id) {
            guard attachment.state == .available || attachment.state == .local else { return }
            guard let url = try? await store.materializedURL(for: attachment) else { return }
            materializedURL = url
            player.load(url)
        }
        .onDisappear {
            player.stop()
            materializedURL = nil
            Task { await store.removeMaterializedFile(for: attachment) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio attachment \(attachment.filename)")
    }

    private func format(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "0:00" }
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct InlineImageAttachmentView: View {
    let store: AttachmentStore
    let attachment: Attachment
    let status: String
    let onRetry: () -> Void
    let onCancel: () -> Void
    @State private var image: PlatformImage?
    @State private var showingPreview = false
    @State private var fullImage: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image {
                    swiftUIImage(image)
                        .resizable().scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        ProgressView()
                    }
                }
            }
            .frame(maxWidth: 320, maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Image attachment \(attachment.filename)")
            .accessibilityAddTraits(image == nil ? [] : .isButton)
            .accessibilityHint(image == nil ? "Image is loading" : "Opens a full-size preview")
            .contentShape(Rectangle())
            .onTapGesture { if image != nil { showingPreview = true } }
            Text(attachment.filename).font(.caption).lineLimit(1)
            Text(status).font(.caption2).foregroundStyle(.secondary)
            if attachment.state == .failed { Button("Retry", action: onRetry).font(.caption) }
            else if attachment.state == .transferring { Button("Cancel", action: onCancel).font(.caption) }
        }
        .task(id: attachment.id) {
            guard let data = try? await store.read(attachment) else { return }
            image = thumbnail(from: data, maximumPixelSize: 640)
        }
        .sheet(isPresented: $showingPreview) {
            VStack(spacing: 12) {
                HStack { Text(attachment.filename).font(.headline); Spacer(); Button("Close") { showingPreview = false } }
                if let preview = fullImage ?? image { swiftUIImage(preview).resizable().scaledToFit() }
            }.padding().platformPreviewSheetSize()
                .task {
                    if let data = try? await store.read(attachment) { fullImage = PlatformImage(data: data) }
                }
        }
    }

    private func swiftUIImage(_ image: PlatformImage) -> Image {
#if os(macOS)
        Image(nsImage: image)
#else
        Image(uiImage: image)
#endif
    }

    private func thumbnail(from data: Data, maximumPixelSize: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else { return nil }
#if os(macOS)
        return NSImage(cgImage: cgImage, size: .zero)
#else
        return UIImage(cgImage: cgImage)
#endif
    }
}

private extension View {
    @ViewBuilder func platformNetworkSheetSize() -> some View {
        #if os(macOS)
        frame(width: 620, height: 760)
        #else
        self
        #endif
    }

    @ViewBuilder func platformContactSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 360, minHeight: 430)
        #else
        self
        #endif
    }

    @ViewBuilder func platformPreviewSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 320, minHeight: 420)
        #else
        self
        #endif
    }

    @ViewBuilder func platformNewConversationSize() -> some View {
        #if os(macOS)
        frame(width: 470)
        #else
        self
        #endif
    }

    @ViewBuilder func destinationInputBehavior() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
        #else
        self
        #endif
    }
}

private struct NewConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    @State private var address = ""
    @State private var name = ""
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, address }
    #if os(iOS)
    @State private var showingContactScanner = false
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New Conversation").font(.title2.bold())
                Text("Enter the person’s LXMF ID, paste their contact link, or scan their QR code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("LXMF ID or contact link")
                    .font(.headline)
                HStack {
                    TextField("32-character LXMF ID or lxmf:// link", text: $address)
                        .font(.body.monospaced())
                        .focused($focusedField, equals: .address)
                        .destinationInputBehavior()
                        .onSubmit(create)
                        .accessibilityIdentifier("new-conversation-address")
                    Button("Paste", systemImage: "doc.on.clipboard", action: pasteAddress)
                        .labelStyle(.iconOnly)
                        .help("Paste an LXMF ID or contact link")
                }
                Text("You can copy an ID from a message, contact card, or another Lower Sideband device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.headline)
                TextField("Optional name for this chat", text: $name)
                    .focused($focusedField, equals: .name)
                    .textContentType(.name)
            }
            #if os(iOS)
            Button { showingContactScanner = true } label: {
                Label("Scan contact or paper message", systemImage: "qrcode.viewfinder")
            }
            #endif
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("create-conversation")
            }
        }.textFieldStyle(.roundedBorder).padding(24).platformNewConversationSize()
        .onAppear { focusedField = .address }
        #if os(iOS)
        .sheet(isPresented: $showingContactScanner) {
            ContactQRScannerSheet { scannedValue in
                if scannedValue.lowercased().hasPrefix("\(LXMURI.scheme)://") {
                    let result = store.ingestPaperMessageURI(scannedValue)
                    showingContactScanner = false
                    if let error = paperMessageError(result) { store.lastError = error }
                    else { dismiss() }
                    return
                }
                guard let contact = SidebandContactLink(string: scannedValue) else {
                    store.lastError = "That QR code is not a valid Lower Sideband contact or LXM paper message."
                    showingContactScanner = false
                    return
                }
                address = contact.url.absoluteString
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = contact.displayName ?? ""
                }
                showingContactScanner = false
            }
        }
        #endif
    }

    private func pasteAddress() {
        #if os(macOS)
        address = NSPasteboard.general.string(forType: .string) ?? address
        #else
        address = UIPasteboard.general.string ?? address
        #endif
    }

    private func create() {
        if address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("\(LXMURI.scheme)://") {
            let result = store.ingestPaperMessageURI(address)
            if let error = paperMessageError(result) { store.lastError = error }
            else { dismiss() }
            return
        }
        let contact = SidebandContactLink(string: address)
        let destination = contact?.destinationHash ?? address
        let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = enteredName.isEmpty ? (contact?.displayName ?? "") : enteredName
        if store.addConversation(destinationHash: destination, displayName: displayName) { dismiss() }
    }
}

#if os(iOS)
private struct ContactQRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ContactQRScannerView(onScan: onScan, onError: { errorMessage = $0 })
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                VStack {
                    Spacer()
                    Text("Place a Lower Sideband contact or LXM paper-message QR code inside the frame")
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 36)
                }
            }
            .navigationTitle("Scan Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Camera Unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Close") { dismiss() }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct ContactQRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ContactQRScannerController {
        ContactQRScannerController(onScan: onScan, onError: onError)
    }

    func updateUIViewController(_ uiViewController: ContactQRScannerController, context: Context) {}
}

private final class ContactQRScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let onScan: (String) -> Void
    private let onError: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var deliveredResult = false

    init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onScan = onScan
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
    }

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureCapture() }
                    else { self?.onError("Camera access is required to scan Lower Sideband contact QR codes.") }
                }
            }
        case .denied, .restricted:
            onError("Camera access is disabled. Enable it for Lower Sideband in Settings, or paste the contact link instead.")
        @unknown default:
            onError("The camera authorization state is unavailable.")
        }
    }

    private func configureCapture() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            onError("No camera is available on this device.")
            return
        }
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            onError("The camera cannot scan QR codes on this device.")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        DispatchQueue.global(qos: .userInitiated).async { [captureSession] in captureSession.startRunning() }
    }

    private func stopCapture() {
        guard captureSession.isRunning else { return }
        DispatchQueue.global(qos: .utility).async { [captureSession] in captureSession.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !deliveredResult,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        deliveredResult = true
        stopCapture()
        onScan(value)
    }
}
#endif
