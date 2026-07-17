import SwiftUI

private extension Data {
    var sidebandHex: String { map { String(format: "%02x", $0) }.joined() }
}
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

private enum DiscoverySort: String, CaseIterable, Identifiable {
    case recent = "Most Recent"
    case hops = "Fewest Hops"
    case name = "Name"
    var id: Self { self }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var store: SidebandStore
    @State private var showingNewConversation = false
    @State private var showingNetwork = false
    @State private var showingCallHistory = false
    @State private var conversationSearch = ""
    @State private var showingArchived = false
    @State private var showingUnreadOnly = false
    @State private var discoverySort: DiscoverySort = .recent
    @State private var renamingConversation: Conversation?
    @State private var renameDraft = ""
    @State private var deletingConversation: Conversation?
    @State private var clearingConversation: Conversation?
    @State private var clearingTelemetryConversation: Conversation?
    @State private var backupDocument = SnapshotBackupDocument(data: Data())
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var contactCollectionDocument = SnapshotBackupDocument(data: Data())
    @State private var showingContactCollectionExporter = false
    @State private var showingContactCollectionImporter = false
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
                    Button { showingUnreadOnly.toggle() } label: {
                        Label(showingUnreadOnly ? "Show all conversations" : "Show unread conversations", systemImage: showingUnreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .help(showingUnreadOnly ? "Show all conversations" : "Show unread conversations only")
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
                        .help("Export Sideband backup")
                    Button { showingBackupImporter = true } label: { Label("Restore backup", systemImage: "externaldrive.badge.timemachine") }
                        .help("Restore Sideband backup")
                    Menu {
                        Button(action: exportContacts) { Label("Export Contacts", systemImage: "person.2.badge.gearshape") }
                        Button { showingContactCollectionImporter = true } label: { Label("Import Contacts", systemImage: "person.crop.circle.badge.plus") }
                    } label: { Label("Contacts", systemImage: "person.2") }
                    .help("Import or export contacts")
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
        .sheet(isPresented: $showingCallHistory) { CallHistoryView(store: store) }
        .sheet(isPresented: Binding(
            get: { store.voiceCall != nil },
            set: { presented in if !presented, store.voiceCall != nil { endVoiceCall() } }
        )) { VoiceCallView(store: store) }
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument, contentType: .json, defaultFilename: "Sideband-Backup") { result in
            if case let .failure(error) = result { store.lastError = "Could not export backup: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { prepareRestore(from: url) }
            if case let .failure(error) = result { store.lastError = "Could not open backup: \(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $showingContactCollectionExporter, document: contactCollectionDocument, contentType: .json, defaultFilename: "Sideband-Contacts") { result in
            if case let .failure(error) = result { store.lastError = "Could not export contacts: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showingContactCollectionImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importContacts(from: url)
            case .failure(let error): store.lastError = "Could not open contacts: \(error.localizedDescription)"
            }
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
        .alert("Clear Telemetry History?", isPresented: Binding(get: { clearingTelemetryConversation != nil }, set: { if !$0 { clearingTelemetryConversation = nil } })) {
            Button("Cancel", role: .cancel) { clearingTelemetryConversation = nil }
            Button("Clear Telemetry", role: .destructive) {
                if let id = clearingTelemetryConversation?.id { _ = store.clearTelemetryHistory(id) }
                clearingTelemetryConversation = nil
            }
        } message: {
            Text("This removes stored location and battery readings from this conversation while retaining its messages and attachments.")
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
            #if os(iOS)
            CallKitCoordinator.shared.install(store: store)
            synchronizeCallKit(store.voiceCall)
            #endif
            #if DEBUG
            DeliverySoakRunner.configureNetworkIfRequested(store)
            #endif
            await store.startTransport()
            #if DEBUG
            let startedSoakNetwork = await DeliverySoakRunner.startNetworkIfRequested(store)
            #else
            let startedSoakNetwork = false
            #endif
            if !startedSoakNetwork, store.autoConnectEnabled { await store.startAutomaticConnection() }
            if store.autoInterfaceEnabled { store.startAutoInterfaceDiscovery() }
            if store.iCloudSyncEnabled { await store.syncICloudNow() }
            #if DEBUG
            await DeliverySoakRunner.runIfRequested(store)
            #endif
        }
        .onOpenURL { url in
            if url.scheme?.lowercased() == LXMURI.scheme {
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

    private var missedCallCount: Int {
        store.voiceCallHistory.count { $0.historyOutcome == .missed }
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
                    if store.isConversationIdentityVerified(conversation.id) {
                        Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.green).accessibilityLabel("Identity fingerprint verified")
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
            ShareLink(item: contactCard, subject: Text("Sideband contact: \(conversation.displayName)")) {
                Label("Share Contact", systemImage: "person.crop.circle.badge.plus")
            }
        }
        if let diagnostics = store.conversationDeliveryDiagnostics(conversation.id) {
            Button { copyToSystemClipboard(diagnostics) } label: { Label("Copy Delivery Diagnostics", systemImage: "stethoscope") }
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
        Button { store.setConversationTelemetrySharing(!conversation.telemetrySharingEnabled, conversationID: conversation.id) } label: {
            Label(conversation.telemetrySharingEnabled ? "Disable Telemetry Sharing" : "Enable Telemetry Sharing", systemImage: conversation.telemetrySharingEnabled ? "location.slash" : "location")
        }
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
        let visible = store.conversations.filter {
            (showingArchived || !$0.isArchived) && (!showingUnreadOnly || $0.unreadCount > 0)
        }
        guard !query.isEmpty else { return visible }
        return visible.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.destinationHash.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredDiscoveries: [DiscoveredDestination] {
        let query = conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if showingUnreadOnly { return [] }
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
                GridRow { Text("Connection policy"); Toggle("Internet only — disable LAN gateways", isOn: Binding(get: { store.internetOnlyEnabled }, set: { store.setInternetOnly($0) })) }
                GridRow { Text("Reconnect"); Toggle("Connect automatically", isOn: Binding(get: { store.autoConnectEnabled }, set: { store.setAutoConnect($0) })) }
                GridRow { Text("Automatic connection"); Text(store.automaticConnectionDescription).foregroundStyle(.secondary) }
                GridRow { Text("Transport"); Text(transportSummary).foregroundStyle(.secondary) }
                ForEach(store.networkInterfaces) { interface in
                    GridRow {
                        Text(interface.name + (interface.isBootstrap ? " (bootstrap)" : "")).font(.caption)
                        Label(interfaceStateText(interface.state), systemImage: interfaceStateIcon(interface.state))
                            .font(.caption).foregroundStyle(interface.state == .ready ? Color.green : Color.secondary)
                    }
                }
                GridRow { Text("System network"); Text(reachabilityText).foregroundStyle(.secondary) }
                GridRow {
                    Text("Discovered interfaces")
                    Text("\(store.discoveredNetworkInterfaces.count) authenticated")
                        .foregroundStyle(.secondary)
                }
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
                    HStack {
                        Text("LXST address")
                        Text(store.localVoiceHash).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { copyToSystemClipboard(store.localVoiceHash) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy LXST voice address")
                    }
                    Text("Calls use the messaging identity and an end-to-end encrypted Reticulum link. The medium-quality Opus profile is compatible with Python Sideband/LXST.")
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
    private var transportSummary: String {
        var value = "TCP · HDLC"
        if store.networkInterfaces.count > 1 {
            value += " · \(store.networkInterfaces.count) concurrent gateways"
        } else if let host = store.activeNetworkHost {
            value += " · \(host)"
            if let port = store.activeNetworkPort { value += ":\(port)" }
        }
        return value
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
    @State private var messagePendingDeletion: Message?
    @State private var inspectedMessage: Message?
    @State private var messageToForward: Message?

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
                            if let contactLink = store.contactLink(for: conversation.id) {
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
                if let transcript = store.conversationTranscript(conversation.id) {
                    ShareLink(item: transcript, subject: Text("Sideband conversation with \(conversation.displayName)")) {
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
                Label(routingStatus, systemImage: routingIcon)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Routing status: \(routingStatus)")
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
                                    if let replyQuote = message.replyQuote {
                                        HStack(spacing: 5) {
                                            Rectangle().fill(Color.accentColor).frame(width: 3)
                                            Text(replyQuote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        .padding(.bottom, 2)
                                        .accessibilityLabel("Replying to: \(replyQuote)")
                                    }
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
                                    if message.lxmfID != nil {
                                        Button { replyingTo = message } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                    }
                                    Button { messageToForward = message } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                                    Button { copyToSystemClipboard(messageMetadata(message)) } label: {
                                        Label("Copy Message Details", systemImage: "info.square")
                                    }
                                    Button { inspectedMessage = message } label: {
                                        Label("Show Message Details", systemImage: "info.circle")
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
        .fileExporter(
            isPresented: $showingConversationExporter,
            document: conversationExportDocument,
            contentType: .json,
            defaultFilename: "Sideband-\(conversation.displayName.replacingOccurrences(of: "/", with: "-"))"
        ) { result in
            if case let .failure(error) = result { store.lastError = "Could not export conversation: \(error.localizedDescription)" }
            conversationExportDocument = nil
        }
        .onAppear {
            draft = store.draft(for: conversation.id)
            store.conversationDidAppear(conversation.id)
        }
        .onDisappear {
            draftSaveTask?.cancel()
            store.updateDraft(draft, for: conversation.id)
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
            Text("This removes the message and its attachments from your synced Sideband history. It cannot recall copies already delivered to another device.")
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
        let repliedMessage = replyingTo
        draftSaveTask?.cancel()
        draft = ""
        store.updateDraft("", for: conversation.id)
        pendingAttachments = []
        replyingTo = nil
        Task { await store.send(text, attachments: attachments, replyingTo: repliedMessage) }
    }

    private func replyPreview(_ message: Message) -> String {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(280)) }
        if let attachment = message.attachments.first { return "Attachment: \(attachment.filename)" }
        if message.telemetry != nil { return "Shared telemetry" }
        return "Message"
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
            "Local record ID: \(message.id.uuidString)",
            "Conversation: \(conversation.destinationHash)",
            "Direction: \(message.direction.rawValue)",
            "Delivery state: \(message.state.rawValue)",
            "Timestamp: \(formatter.string(from: message.timestamp))"
        ]
        if let lxmfID = message.lxmfID { lines.append("LXMF message hash: \(lxmfID.sidebandHex)") }
        if let replyTo = message.replyTo { lines.append("Reply to LXMF hash: \(replyTo.sidebandHex)") }
        if let replyQuote = message.replyQuote { lines.append("Reply quote: \(replyQuote)") }
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
                        description: Text("Scan the contact's keyed Sideband QR code or receive a validated announce before verifying them.")
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
        store.setVoiceFrameHandler { payload in audio.play(opus: payload) }
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
            do { try await audio.start() }
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
            TextField("LXMF destination, contact link or lxm:// paper message", text: $address).font(.body.monospaced())
            #if os(iOS)
            Button { showingContactScanner = true } label: {
                Label("Scan contact or paper message", systemImage: "qrcode.viewfinder")
            }
            #endif
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create", action: create).buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder).padding(24).platformNewConversationSize()
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
                    store.lastError = "That QR code is not a valid Sideband contact or LXM paper message."
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
                    Text("Place a Sideband contact or LXM paper-message QR code inside the frame")
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
