import SwiftUI
import SidebandCore
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
import AVFoundation
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

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: SidebandStore
    @State private var showingNewConversation = false
    @State private var showingNetwork = false
    @State private var conversationSearch = ""
    @State private var showingArchived = false
    @State private var renamingConversation: Conversation?
    @State private var renameDraft = ""
    @State private var deletingConversation: Conversation?
    @State private var clearingConversation: Conversation?
    @State private var backupDocument = SnapshotBackupDocument(data: Data())
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var pendingRestoreData: Data?

    var body: some View {
        VStack(spacing: 0) {
            localIdentityBar
            NavigationSplitView {
                List(selection: $store.selectedConversationID) {
                    Section("Conversations") { ForEach(filteredConversations) { conversation in
                        conversationRow(conversation)
                        .padding(.vertical, 4)
                        .tag(conversation.id)
                        .contextMenu { conversationMenu(conversation) }
                    } }
                    if !filteredDiscoveries.isEmpty {
                        Section("Discovered") {
                            ForEach(filteredDiscoveries) { discovery in
                                discoveryRow(discovery)
                            }
                        }
                    }
                }
                .searchable(text: $conversationSearch, prompt: "Search conversations")
                .navigationTitle("Sideband")
                .toolbar {
                    Button(action: { showingNetwork = true }) {
                        Label(networkToolbarLabel, systemImage: networkToolbarIcon)
                    }.help("Reticulum network status")
                    Button { showingArchived.toggle() } label: {
                        Label(showingArchived ? "Hide archived conversations" : "Show archived conversations", systemImage: showingArchived ? "archivebox.fill" : "archivebox")
                    }
                    .help(showingArchived ? "Hide archived conversations" : "Show archived conversations")
                    Button(action: exportBackup) { Label("Export backup", systemImage: "externaldrive.badge.plus") }
                        .help("Export Sideband backup")
                    Button { showingBackupImporter = true } label: { Label("Restore backup", systemImage: "externaldrive.badge.timemachine") }
                        .help("Restore Sideband backup")
                    Button(action: { showingNewConversation = true }) { Label("New conversation", systemImage: "square.and.pencil") }
                }
            } detail: {
                if let conversation = store.selectedConversation {
                    ConversationView(store: store, conversation: conversation)
                        .id(conversation.id)
                } else {
                    ContentUnavailableView("No Conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Create a conversation using an LXMF destination."))
                }
            }
        }
        .sheet(isPresented: $showingNewConversation) { NewConversationView(store: store) }
        .sheet(isPresented: $showingNetwork) { NetworkView(store: store) }
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument, contentType: .json, defaultFilename: "Sideband-Backup") { result in
            if case let .failure(error) = result { store.lastError = "Could not export backup: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { prepareRestore(from: url) }
            if case let .failure(error) = result { store.lastError = "Could not open backup: \(error.localizedDescription)" }
        }
        .alert("Sideband", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })) {
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
        .alert("Restore Sideband Backup?", isPresented: Binding(get: { pendingRestoreData != nil }, set: { if !$0 { pendingRestoreData = nil } })) {
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
        .task {
            #if DEBUG
            DeliverySoakRunner.configureNetworkIfRequested(store)
            #endif
            await store.startTransport()
            if store.autoConnectEnabled { await store.startAutomaticConnection() }
            if store.autoInterfaceEnabled { store.startAutoInterfaceDiscovery() }
            if store.iCloudSyncEnabled { await store.syncICloudNow() }
            #if DEBUG
            await DeliverySoakRunner.runIfRequested(store)
            #endif
        }
        .onOpenURL { url in
            _ = store.openContactLink(url)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await store.applicationDidBecomeActive() }
            case .background: store.applicationDidEnterBackground()
            case .inactive: store.applicationDidBecomeInactive()
            @unknown default: break
            }
        }
    }

    private var networkToolbarLabel: String {
        switch store.networkState {
        case .ready: "Online · \(store.knownPathCount) paths"
        case .connecting: "Connecting"
        case .failed: "Network error"
        case .stopped: "Offline"
        }
    }

    private var localIdentityBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("My LXMF ID")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.localDeliveryHash)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
                    .accessibilityLabel("Current LXMF ID \\(store.localDeliveryHash)")
            }
            Spacer(minLength: 4)
            Button {
                copyToSystemClipboard(store.localDeliveryHash)
            } label: {
                Label("Copy ID", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    @ViewBuilder private func conversationRow(_ conversation: Conversation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.displayName).font(.headline)
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
                    Spacer()
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
                Text(conversation.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
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
                }
            }
            Spacer()
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
    }

    @ViewBuilder private func discoveryRow(_ discovery: DiscoveredDestination) -> some View {
        Button { startConversation(with: discovery) } label: {
            DiscoveredDestinationRow(discovery: discovery)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { copyToSystemClipboard(discovery.destinationHash) } label: { Label("Copy Destination", systemImage: "number") }
            if let contactLink = SidebandContactLink(destinationHash: discovery.destinationHash, displayName: discovery.announcedDisplayName) {
                Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: { Label("Copy Contact Link", systemImage: "link") }
                ShareLink(item: contactLink.url) { Label("Share Contact Link", systemImage: "square.and.arrow.up") }
            }
            Button { startConversation(with: discovery) } label: { Label("Start Conversation", systemImage: "message") }
        }
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
        if let contactLink = SidebandContactLink(destinationHash: conversation.destinationHash, displayName: conversation.displayName) {
            Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: { Label("Copy Contact Link", systemImage: "link") }
        }
        if let contactCard = store.conversationContactCard(conversation.id) {
            ShareLink(item: contactCard, subject: Text("Sideband contact: \(conversation.displayName)")) {
                Label("Share Contact", systemImage: "person.crop.circle.badge.plus")
            }
        }
        Button { renameDraft = conversation.displayName; renamingConversation = conversation } label: { Label("Rename", systemImage: "pencil") }
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
        Button { store.setConversationBlocked(!conversation.isBlocked, conversationID: conversation.id) } label: {
            Label(conversation.isBlocked ? "Unblock Contact" : "Block Contact", systemImage: conversation.isBlocked ? "hand.raised.slash" : "hand.raised")
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
        Button(role: .destructive) { clearingConversation = conversation } label: { Label("Clear History", systemImage: "eraser") }
        Button(role: .destructive) { deletingConversation = conversation } label: { Label("Delete Conversation", systemImage: "trash") }
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
        let visible = store.conversations.filter { showingArchived || !$0.isArchived }
        guard !query.isEmpty else { return visible }
        return visible.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.destinationHash.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredDiscoveries: [DiscoveredDestination] {
        let query = conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.discoveries }
        return store.discoveries.filter {
            $0.destinationHash.localizedCaseInsensitiveContains(query)
                || ($0.announcedDisplayName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func messagePreview(_ message: Message) -> String {
        if !message.body.isEmpty { return message.body }
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
    @Bindable var store: SidebandStore
    @State private var showingLocalContactQR = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Network Status").font(.title2.bold())
                Spacer()
                Label(statusText, systemImage: statusIcon).foregroundStyle(statusColor)
            }
            Text("Connect to a Reticulum TCP Server Interface. Incoming packets and announces are parsed and cryptographically validated by the native Swift stack.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Interface") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Local name")
                    TextField("Sideband Swift", text: Binding(get: { store.localDisplayName }, set: { store.setLocalDisplayName($0) }))
                }
                GridRow { Text("Host"); TextField("Optional configured IPv4 or DNS hostname", text: $store.networkHost) }
                GridRow { Text("IPv6 host"); TextField("Optional configured IPv6 gateway", text: $store.networkIPv6Host) }
                GridRow { Text("Internet override"); TextField("Optional public IPv6 or DNS hostname", text: $store.networkInternetHost) }
                GridRow { Text("Internet port"); TextField("4242", value: $store.networkInternetPort, format: .number.grouping(.never)) }
                GridRow { Text("Port"); TextField("4242", value: $store.networkPort, format: .number.grouping(.never)) }
                GridRow { Text("Addressing"); Toggle("Prefer IPv6 with IPv4 fallback", isOn: Binding(get: { store.preferIPv6 }, set: { store.setPreferIPv6($0) })) }
                GridRow { Text("Reconnect"); Toggle("Connect automatically", isOn: Binding(get: { store.autoConnectEnabled }, set: { store.setAutoConnect($0) })) }
                GridRow { Text("Automatic connection"); Text(store.automaticConnectionDescription).foregroundStyle(.secondary) }
                GridRow { Text("Transport"); Text("TCP · HDLC" + (store.activeNetworkHost.map { " · \($0):\(store.activeNetworkPort ?? store.networkPort)" } ?? "")).foregroundStyle(.secondary) }
                GridRow { Text("System network"); Text(reachabilityText).foregroundStyle(.secondary) }
                GridRow {
                    Text("Last connected")
                    Text(store.lastNetworkReadyAt?.formatted(date: .abbreviated, time: .standard) ?? "Never")
                        .foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder).padding(6)
            }
            GroupBox("Routing") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { metric("Packets received", store.receivedPacketCount); metric("Known paths", store.knownPathCount) }
                    GridRow { metric("Validated announces", store.validatedDiscoveryCount); metric("Pending requests", store.pendingPathCount) }
                    GridRow { metric("Unverified announces", store.unverifiedDiscoveryCount); metric("LXMF deliveries", 0) }
                    GridRow { metric("Pending links", store.pendingLinkCount); metric("Active links", store.activeLinkCount) }
                    GridRow { metric("Encrypted packets", store.encryptedPacketsReceived); metric("Keepalives", store.keepalivesSent + store.keepalivesReceived) }
                    GridRow { metric("Propagation requests", store.propagationRequestsSent); metric("Propagation responses", store.propagationResponsesReceived) }
                    GridRow { metric("Messages available", store.propagationMessagesAvailable); metric("LXMF deliveries", 0) }
                    GridRow { metric("Uploads accepted", store.propagationUploadsAccepted); metric("Direct deliveries", store.messages.count(where: { $0.state == .delivered })) }
                    GridRow { metric("Delivery announces", store.deliveryAnnouncesSent); metric("Inbox messages", store.messages.count(where: { $0.direction == .incoming })) }
                    GridRow { metric("Inbound links", store.inboundLinksAccepted); metric("Active links", store.activeLinkCount + store.inboundLinksAccepted) }
                    GridRow { metric("Opportunistic received", store.opportunisticDeliveriesReceived); metric("Delivery announces", store.deliveryAnnouncesSent) }
                    GridRow { metric("Delivery timeouts", store.deliveryTimeoutCount); metric("Queued messages", store.messages.count(where: { $0.state == .queued })) }
                    GridRow { metric("Recovered outbox", store.recoveredOutboundCount); metric("Delivered messages", store.messages.count(where: { $0.state == .delivered })) }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("LXMF propagation") {
                VStack(alignment: .leading, spacing: 10) {
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
            GroupBox("Notifications") {
                HStack {
                    Toggle("Notify for verified incoming messages", isOn: Binding(
                        get: { store.notifications.isEnabled },
                        set: { enabled in Task { await store.notifications.setEnabled(enabled) } }
                    ))
                    Spacer()
                    Text(store.notifications.authorizationDescription).font(.caption).foregroundStyle(.secondary)
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
                    capability("Identity and announce validation", complete: true)
                    capability("Path discovery and route table", complete: true)
                    capability("AutoInterface discovery and UDP data plane", complete: true)
                    capability("Encrypted links and resources", complete: true)
                    capability("LXMF message delivery", complete: true)
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
        }
        .platformNetworkSheetSize()
        .sheet(isPresented: $showingLocalContactQR) {
            ContactQRCodeView(name: store.localDisplayName, link: store.localContactLink.url)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value.formatted()).font(.title3.monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(minWidth: 125, alignment: .leading)
    }
    private func capability(_ title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(complete ? Color.green : Color.secondary)
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
    private var statusText: String {
        switch store.networkState {
        case .stopped: "Disconnected"
        case .connecting: "Connecting"
        case .ready: "TCP connected"
        case .failed(let reason): store.reconnectDelaySeconds.map { "Retrying in \($0)s · \(reason)" } ?? "Failed: \(reason)"
        }
    }
    private var statusIcon: String {
        switch store.networkState { case .ready: "checkmark.circle.fill"; case .connecting: "arrow.triangle.2.circlepath"; case .failed: "exclamationmark.triangle.fill"; case .stopped: "circle" }
    }
    private var statusColor: Color {
        switch store.networkState { case .ready: .green; case .connecting: .orange; case .failed: .red; case .stopped: .secondary }
    }
}

private struct ConversationView: View {
    @Bindable var store: SidebandStore
    let conversation: Conversation
    @State private var draft = ""
    @State private var pendingAttachments: [Attachment] = []
    @State private var showingFileImporter = false
    @State private var messageSearch = ""
    @State private var previewAttachmentURL: URL?
    @State private var previewAttachment: Attachment?
    @State private var showingContactQR = false
    @State private var telemetryCapture = TelemetryCapture()
    @State private var voiceRecorder = VoiceMessageRecorder()
    @State private var showingTelemetryMap = false

    var body: some View {
        let conversationMessages = filteredMessages
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(conversation.displayName).font(.title2.bold())
                    if conversation.isTrusted { Label("Trusted", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green) }
                    Text(conversation.destinationHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .contextMenu {
                            Button { copyToSystemClipboard(conversation.destinationHash) } label: { Label("Copy Destination", systemImage: "number") }
                            if let contactLink = SidebandContactLink(destinationHash: conversation.destinationHash, displayName: conversation.displayName) {
                                Button { copyToSystemClipboard(contactLink.url.absoluteString) } label: { Label("Copy Contact Link", systemImage: "link") }
                            }
                        }
                }
                Spacer()
                TextField("Search messages", text: $messageSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                if !messageSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(conversationMessages.count) \(conversationMessages.count == 1 ? "result" : "results")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { messageSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear message search")
                        .accessibilityLabel("Clear message search")
                }
                if SidebandContactLink(destinationHash: conversation.destinationHash, displayName: conversation.displayName) != nil {
                    Button { showingContactQR = true } label: { Image(systemName: "qrcode") }
                        .help("Show contact QR code")
                }
                if !telemetryMessages.isEmpty {
                    Button { showingTelemetryMap = true } label: { Image(systemName: "map") }
                        .help("Show conversation telemetry map")
                }
                if let transcript = store.conversationTranscript(conversation.id) {
                    ShareLink(item: transcript, subject: Text("Sideband conversation with \(conversation.displayName)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export conversation transcript")
                }
                Label(routingStatus, systemImage: routingIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
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
                                    if !message.body.isEmpty { Text(message.body) }
                                    if let telemetry = message.telemetry {
                                        Button { showingTelemetryMap = true } label: { TelemetryMessageCard(telemetry: telemetry) }
                                            .buttonStyle(.plain)
                                            .help("Show telemetry on map")
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
                                    HStack { Text(message.timestamp, style: .time); Text(message.state.rawValue.capitalized) }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(message.timestamp.formatted(date: .long, time: .standard)), \(message.state.rawValue)")
                                        .help(message.timestamp.formatted(date: .long, time: .standard))
                                }
                                .padding(10)
                                .background(message.direction == .outgoing ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                .contextMenu {
                                    if !message.body.isEmpty {
                                        Button { copyToSystemClipboard(message.body) } label: { Label("Copy Message", systemImage: "doc.on.doc") }
                                    }
                                    Button { copyToSystemClipboard(messageMetadata(message)) } label: {
                                        Label("Copy Message Details", systemImage: "info.square")
                                    }
                                    if !message.attachments.isEmpty {
                                        Menu("Copy Attachment Details", systemImage: "paperclip") {
                                            ForEach(message.attachments) { attachment in
                                                Button(attachment.filename) { copyToSystemClipboard(attachmentMetadata(attachment)) }
                                            }
                                        }
                                    }
                                    if message.direction == .outgoing && (message.state == .failed || message.state == .queued) {
                                        Button { Task { await store.retryMessage(message.id) } } label: { Label("Retry Now", systemImage: "arrow.clockwise") }
                                    }
                                    if message.direction == .outgoing && message.state == .failed {
                                        Button(role: .destructive) { Task { await store.removeFailedMessage(message.id) } } label: { Label("Remove Failed Message", systemImage: "trash") }
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
                                    Button { pendingAttachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)
                                }.font(.caption).padding(6).background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                HStack {
                    Button(action: shareTelemetry) {
                        if telemetryCapture.isRequesting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "location.fill") }
                    }
                    .help("Share current location and device telemetry")
                    .disabled(telemetryCapture.isRequesting)
                    Button { showingFileImporter = true } label: { Image(systemName: "paperclip") }
                        .help("Attach files")
                        .disabled(pendingAttachments.count >= SidebandMessageLimits.maximumAttachments)
                    Button(action: toggleVoiceRecording) {
                        Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(voiceRecorder.isRecording ? .red : Color.accentColor)
                    }
                    .help(voiceRecorder.isRecording ? "Finish voice message" : "Record voice message")
                    .disabled(voiceRecorder.isPreparing || (!voiceRecorder.isRecording && pendingAttachments.count >= SidebandMessageLimits.maximumAttachments))
                    TextField("Message", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).onSubmit(send)
                        .disabled(voiceRecorder.isRecording)
                    Button(action: send) { Image(systemName: "paperplane.fill") }.buttonStyle(.borderedProminent).disabled(!canSend || voiceRecorder.isRecording)
                }
                HStack {
                    if voiceRecorder.isRecording {
                        Label(formatDuration(voiceRecorder.elapsed), systemImage: "waveform")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Recording voice message, \(formatDuration(voiceRecorder.elapsed))")
                        Button("Cancel recording", role: .destructive) { voiceRecorder.cancel() }
                            .font(.caption)
                    }
                    Spacer()
                    Text("\(draft.count)/\(SidebandMessageLimits.maximumTextCharacters)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(draft.count == SidebandMessageLimits.maximumTextCharacters ? .orange : .secondary)
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
        .onAppear {
            draft = store.draft(for: conversation.id)
            store.conversationDidAppear(conversation.id)
        }
        .onDisappear {
            voiceRecorder.cancel()
            store.conversationDidDisappear(conversation.id)
            if let previewAttachment {
                Task { await store.attachmentStore.removeMaterializedFile(for: previewAttachment) }
            }
        }
        .onChange(of: draft) { _, value in
            if value.count > SidebandMessageLimits.maximumTextCharacters {
                draft = String(value.prefix(SidebandMessageLimits.maximumTextCharacters))
            } else {
                store.updateDraft(value, for: conversation.id)
            }
        }
        .quickLookPreview($previewAttachmentURL)
        .onChange(of: previewAttachmentURL) { _, newValue in
            guard newValue == nil, let attachment = previewAttachment else { return }
            previewAttachment = nil
            Task { await store.attachmentStore.removeMaterializedFile(for: attachment) }
        }
        .sheet(isPresented: $showingContactQR) {
            if let contactLink = SidebandContactLink(destinationHash: conversation.destinationHash, displayName: conversation.displayName) {
                ContactQRCodeView(name: conversation.displayName, link: contactLink.url)
            }
        }
        .sheet(isPresented: $showingTelemetryMap) {
            ConversationTelemetryMapView(conversationName: conversation.displayName, messages: telemetryMessages)
        }
    }

    private var bottomAnchorID: String { "conversation-bottom-\(conversation.id.uuidString)" }

    private var filteredMessages: [Message] {
        let all = store.messages(for: conversation.id)
        let query = messageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { message in
            message.body.localizedCaseInsensitiveContains(query) || message.attachments.contains { $0.filename.localizedCaseInsensitiveContains(query) }
        }
    }

    private var telemetryMessages: [Message] {
        store.messages(for: conversation.id).filter { $0.telemetry?.location != nil }
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
        draft = ""
        store.updateDraft("", for: conversation.id)
        pendingAttachments = []
        Task { await store.send(text, attachments: attachments) }
    }

    private func shareTelemetry() {
        Task {
            if let telemetry = await telemetryCapture.requestTelemetry() {
                await store.send("Shared telemetry", attachments: [], telemetry: telemetry)
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
            let timestamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let attachment = try await store.attachmentStore.importFile(from: url, preferredName: "Voice message \(timestamp).m4a")
            if store.validateAttachmentIsUnique(attachment, among: pendingAttachments),
               store.validateAttachmentTotal(pendingAttachments + [attachment]) {
                pendingAttachments.append(attachment)
            } else {
                try? await store.attachmentStore.remove(attachment)
            }
        } catch {
            store.reportAttachmentImportFailure(filename: "Voice message.m4a", error: error)
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty }

    private func messageMetadata(_ message: Message) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Message ID: \(message.id.uuidString)",
            "Conversation: \(conversation.destinationHash)",
            "Direction: \(message.direction.rawValue)",
            "Delivery state: \(message.state.rawValue)",
            "Timestamp: \(formatter.string(from: message.timestamp))"
        ]
        if !message.attachments.isEmpty {
            lines.append("Attachments: \(message.attachments.count)")
            lines.append(contentsOf: message.attachments.map {
                "- \($0.filename) (\(ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file)), \($0.state.rawValue))"
            })
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
    private var routingIcon: String {
        if store.activeLinkHashes.contains(conversation.destinationHash) { return "lock.shield.fill" }
        if store.networkState == .ready { return "network" }
        return "arrow.triangle.2.circlepath"
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
}

private struct NewConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    @State private var address = ""
    @State private var name = ""
    #if os(iOS)
    @State private var showingContactScanner = false
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Conversation").font(.title2.bold())
            TextField("Display name (optional)", text: $name)
            TextField("LXMF destination or sideband:// contact link", text: $address).font(.body.monospaced())
            #if os(iOS)
            Button { showingContactScanner = true } label: {
                Label("Scan contact QR code", systemImage: "qrcode.viewfinder")
            }
            #endif
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create", action: create).buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder).padding(24).platformNewConversationSize()
        #if os(iOS)
        .sheet(isPresented: $showingContactScanner) {
            ContactQRScannerSheet { scannedValue in
                guard let contact = SidebandContactLink(string: scannedValue) else {
                    store.lastError = "That QR code is not a valid Sideband contact."
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

    private func create() {
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
                    Text("Place a Sideband contact QR code inside the frame")
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
                    else { self?.onError("Camera access is required to scan Sideband contact QR codes.") }
                }
            }
        case .denied, .restricted:
            onError("Camera access is disabled. Enable it for Sideband in Settings, or paste the contact link instead.")
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
