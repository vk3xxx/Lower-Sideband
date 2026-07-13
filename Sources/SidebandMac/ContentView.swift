import SwiftUI
import SidebandCore
import UniformTypeIdentifiers
import ImageIO
#if os(macOS)
import AppKit
private typealias PlatformImage = NSImage
#else
import UIKit
private typealias PlatformImage = UIImage
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: SidebandStore
    @State private var showingNewConversation = false
    @State private var showingNetwork = false

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedConversationID) {
                Section("Conversations") { ForEach(store.conversations) { conversation in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.displayName).font(.headline)
                            Text(conversation.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if conversation.unreadCount > 0 {
                            Text(conversation.unreadCount, format: .number)
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                                .accessibilityLabel("\(conversation.unreadCount) unread messages")
                        }
                    }.padding(.vertical, 4).tag(conversation.id)
                } }
                if !store.discoveries.isEmpty {
                    Section("Discovered") {
                        ForEach(store.discoveries) { discovery in
                            Button { store.addConversation(from: discovery) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(discovery.announcedDisplayName ?? discovery.destinationHash).font(.caption.monospaced()).lineLimit(1)
                                    Text("\(discovery.hops) hops · \(discovery.isValidated ? "validated" : "unverified")").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Sideband")
            .toolbar {
                Button(action: { showingNetwork = true }) {
                    Label(networkToolbarLabel, systemImage: networkToolbarIcon)
                }.help("Reticulum network status")
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
        .sheet(isPresented: $showingNewConversation) { NewConversationView(store: store) }
        .sheet(isPresented: $showingNetwork) { NetworkView(store: store) }
        .alert("Sideband", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })) {
            Button("OK") { store.clearError() }
        } message: { Text(store.lastError ?? "") }
        .task {
            await store.startTransport()
            if store.autoConnectEnabled { await store.connectNetwork() }
            if store.autoInterfaceEnabled { store.startAutoInterfaceDiscovery() }
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
    private var networkToolbarIcon: String {
        switch store.networkState {
        case .ready: "network.badge.shield.half.filled"
        case .connecting: "network"
        case .failed: "network.slash"
        case .stopped: "network.slash"
        }
    }
}

private struct NetworkView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore

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
                GridRow { Text("Host"); TextField("127.0.0.1", text: $store.networkHost) }
                GridRow { Text("IPv6 host"); TextField("IPv6 gateway", text: $store.networkIPv6Host) }
                GridRow { Text("Port"); TextField("4242", value: $store.networkPort, format: .number.grouping(.never)) }
                GridRow { Text("Addressing"); Toggle("Prefer IPv6 with IPv4 fallback", isOn: Binding(get: { store.preferIPv6 }, set: { store.setPreferIPv6($0) })) }
                GridRow { Text("Reconnect"); Toggle("Connect automatically", isOn: Binding(get: { store.autoConnectEnabled }, set: { store.setAutoConnect($0) })) }
                GridRow { Text("Transport"); Text("TCP · HDLC" + (store.activeNetworkHost.map { " · \($0)" } ?? "")).foregroundStyle(.secondary) }
                GridRow { Text("System network"); Text(reachabilityText).foregroundStyle(.secondary) }
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
                        Text("Discovers Bonjour services: _reticulum._tcp, _rns._tcp and _sideband._tcp")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.lanDiscovery.isSearching {
                            Button("Stop") { store.stopGatewayDiscovery() }
                        } else {
                            Button("Discover") { store.startGatewayDiscovery() }
                        }
                    }
                    if store.lanDiscovery.gateways.isEmpty {
                        ContentUnavailableView("No advertised gateways", systemImage: "dot.radiowaves.left.and.right", description: Text(store.lanDiscovery.isSearching ? "Listening on the local network…" : "Start discovery or connect manually above."))
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
                    capability("Encrypted links and resources", complete: false)
                    capability("LXMF message delivery", complete: false)
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if isConnectedOrConnecting {
                    Button("Disconnect") { Task { await store.disconnectNetwork() } }
                } else {
                    Button("Connect") { Task { await store.connectNetwork() } }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(24)
        }.frame(width: 620, height: 760)
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

    var body: some View {
        let conversationMessages = store.messages(for: conversation.id)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(conversation.displayName).font(.title2.bold())
                    Text(conversation.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Label(routingStatus, systemImage: routingIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(conversationMessages) { message in
                            HStack {
                                if message.direction == .outgoing { Spacer(minLength: 80) }
                                VStack(alignment: .leading, spacing: 5) {
                                    if !message.body.isEmpty { Text(message.body) }
                                    ForEach(message.attachments) { attachment in
                                        if isImage(attachment) {
                                            InlineImageAttachmentView(store: store.attachmentStore, attachment: attachment, status: attachmentStatus(attachment), onRetry: { retry(message, attachment) }, onCancel: { cancel(message, attachment) })
                                        } else {
                                            Label {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(attachment.filename).lineLimit(1)
                                                    Text(attachmentStatus(attachment)).font(.caption2).foregroundStyle(.secondary)
                                                }
                                            } icon: { Image(systemName: "doc.fill") }
                                            attachmentControls(message, attachment)
                                        }
                                    }
                                    HStack { Text(message.timestamp, style: .time); Text(message.state.rawValue.capitalized) }
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(message.direction == .outgoing ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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
                                    Image(systemName: "paperclip")
                                    Text(attachment.filename).lineLimit(1)
                                    Button { pendingAttachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)
                                }.font(.caption).padding(6).background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                HStack {
                    Button { showingFileImporter = true } label: { Image(systemName: "paperclip") }.help("Attach files")
                    TextField("Message", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).onSubmit(send)
                    Button(action: send) { Image(systemName: "paperplane.fill") }.buttonStyle(.borderedProminent).disabled(!canSend)
                }
            }.padding()
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await importAttachments(urls) } }
        }
        .onAppear { store.conversationDidAppear(conversation.id) }
        .onDisappear { store.conversationDidDisappear(conversation.id) }
    }

    private var bottomAnchorID: String { "conversation-bottom-\(conversation.id.uuidString)" }

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
        pendingAttachments = []
        Task { await store.send(text, attachments: attachments) }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty }

    private func importAttachments(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let attachment = try? await store.attachmentStore.importFile(from: url) { pendingAttachments.append(attachment) }
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

    @ViewBuilder private func attachmentControls(_ message: Message, _ attachment: Attachment) -> some View {
        if attachment.state == .failed { Button("Retry") { retry(message, attachment) }.font(.caption) }
        else if attachment.state == .transferring { Button("Cancel") { cancel(message, attachment) }.font(.caption) }
    }
    private func retry(_ message: Message, _ attachment: Attachment) { Task { await store.retryAttachment(messageID: message.id, attachmentID: attachment.id) } }
    private func cancel(_ message: Message, _ attachment: Attachment) { Task { await store.cancelAttachment(messageID: message.id, attachmentID: attachment.id) } }

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
            }.padding().frame(minWidth: 320, minHeight: 420)
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

private struct NewConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    @State private var address = ""
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Conversation").font(.title2.bold())
            TextField("Display name (optional)", text: $name)
            TextField("32-character LXMF destination", text: $address).font(.body.monospaced())
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create") { if store.addConversation(destinationHash: address, displayName: name) { dismiss() } }.buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 470)
    }
}
