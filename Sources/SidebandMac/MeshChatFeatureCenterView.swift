import SwiftUI
import SidebandCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private func copyMeshFeatureText(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

struct MeshChatFeatureCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore

    var body: some View {
        NavigationStack {
            TabView {
                NomadPageBrowserView(store: store)
                    .tabItem { Label("Pages", systemImage: "doc.richtext") }
                IdentityProfilesView(store: store)
                    .tabItem { Label("Identities", systemImage: "person.2.badge.key") }
                TelephoneCenterView(store: store)
                    .tabItem { Label("Telephone", systemImage: "phone") }
                RelayChatView(store: store)
                    .tabItem { Label("Rooms", systemImage: "person.3") }
                HostedRelayView(store: store)
                    .tabItem { Label("Host", systemImage: "person.3.sequence.fill") }
                RemoteFilesView(store: store)
                    .tabItem { Label("Files", systemImage: "folder.badge.gearshape") }
                NomadServerView(store: store)
                    .tabItem { Label("Server", systemImage: "server.rack") }
                RemoteShellView(store: store)
                    .tabItem { Label("Shell", systemImage: "terminal") }
                RemoteToolsView(store: store)
                    .tabItem { Label("Remote", systemImage: "wrench.and.screwdriver") }
            }
            .navigationTitle("Mesh Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct HostedRelayView: View {
    @Bindable var store: SidebandStore
    @State private var configuration = HostedRelayHubConfiguration()
    @State private var roomName = ""
    @State private var roomTopic = ""
    @State private var roomKey = ""
    @State private var moderated = false
    @State private var voicedIdentities = ""
    @State private var banIdentity = ""

    var body: some View {
        Form {
            Section("Hosted RRC Hub") {
                Toggle("Host relay rooms on this device", isOn: $configuration.enabled)
                TextField("Hub name", text: $configuration.name)
                TextField("Welcome message", text: $configuration.greeting, axis: .vertical)
                LabeledContent("Hub destination") {
                    HStack {
                        Text(store.localRelayHubHash).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") { copyMeshFeatureText(store.localRelayHubHash) }
                    }
                }
                Button("Save and Announce", systemImage: "antenna.radiowaves.left.and.right") {
                    Task { await store.updateHostedRelayHub(configuration) }
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Rooms") {
                ForEach(configuration.rooms) { room in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(room.name)").font(.headline)
                            if room.accessKey != nil { Image(systemName: "key.fill").foregroundStyle(.orange) }
                            if room.isModerated { Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.blue) }
                            Spacer()
                            Button(role: .destructive) {
                                configuration.rooms.removeAll { $0.id == room.id }
                            } label: { Image(systemName: "trash") }
                        }
                        if !room.topic.isEmpty { Text(room.topic).font(.caption).foregroundStyle(.secondary) }
                        if room.isModerated {
                            Text("\(room.voicedIdentityHashes.count) identities may post")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("New room name", text: $roomName)
                TextField("Topic", text: $roomTopic)
                SecureField("Optional access key", text: $roomKey)
                Toggle("Moderated room", isOn: $moderated)
                if moderated {
                    TextField("Identity hashes allowed to post, separated by commas", text: $voicedIdentities, axis: .vertical)
                        .font(.caption.monospaced())
                }
                Button("Add Room", systemImage: "plus") {
                    let voiced = Set(
                        voicedIdentities
                            .split { $0 == "," || $0.isWhitespace }
                            .map { String($0).lowercased() }
                            .filter(DestinationHash.isValid)
                    )
                    let room = HostedRelayRoom(
                        name: roomName,
                        topic: roomTopic,
                        accessKey: roomKey,
                        isModerated: moderated,
                        voicedIdentityHashes: voiced
                    )
                    guard !room.name.isEmpty, !configuration.rooms.contains(where: { $0.name == room.name }) else { return }
                    configuration.rooms.append(room)
                    roomName = ""; roomTopic = ""; roomKey = ""; moderated = false; voicedIdentities = ""
                }
                .disabled(roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Connected Members") {
                if store.hostedRelayMembers.isEmpty {
                    Text("No members connected").foregroundStyle(.secondary)
                }
                ForEach(store.hostedRelayMembers) { member in
                    LabeledContent(member.nickname, value: "#\(member.room) · \(member.identityHash)")
                        .font(.caption)
                }
            }
            Section("Moderation") {
                HStack {
                    TextField("Identity hash to ban", text: $banIdentity).font(.caption.monospaced())
                    Button("Ban", role: .destructive) {
                        Task {
                            await store.banHostedRelayIdentity(banIdentity)
                            configuration = store.meshFeatures.relayHub
                            banIdentity = ""
                        }
                    }
                    .disabled(!DestinationHash.isValid(banIdentity.lowercased()))
                }
                ForEach(configuration.bannedIdentityHashes.sorted(), id: \.self) { identity in
                    HStack {
                        Text(identity).font(.caption.monospaced())
                        Spacer()
                        Button("Unban") {
                            Task {
                                await store.unbanHostedRelayIdentity(identity)
                                configuration = store.meshFeatures.relayHub
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hosted Relay")
        .onAppear { configuration = store.meshFeatures.relayHub }
    }
}

private struct RemoteFilesView: View {
    @Bindable var store: SidebandStore
    @State private var configuration = RemoteCopyConfiguration()
    @State private var allowedIdentities = ""
    @State private var destination = ""
    @State private var remotePath = ""
    @State private var importerMode: ImporterMode?

    private enum ImporterMode: Identifiable { case send, share; var id: Int { self == .send ? 0 : 1 } }

    var body: some View {
        Form {
            Section("Send or Fetch") {
                TextField("rncp.receive destination", text: $destination).font(.caption.monospaced())
                TextField("Remote filename", text: $remotePath)
                HStack {
                    Button("Send File", systemImage: "arrow.up.doc") { importerMode = .send }
                        .disabled(!DestinationHash.isValid(destination.lowercased()))
                    Button("Fetch File", systemImage: "arrow.down.doc") {
                        Task {
                            do { _ = try await store.fetchRemoteFile(destinationHash: destination, remotePath: remotePath) }
                            catch { store.lastError = error.localizedDescription }
                        }
                    }
                    .disabled(!DestinationHash.isValid(destination.lowercased()) || remotePath.isEmpty)
                }
            }
            Section("Receive Service") {
                Toggle("Accept authorised uploads", isOn: $configuration.receiverEnabled)
                Toggle("Serve shared files on request", isOn: $configuration.fetchEnabled)
                TextField("Allowed identity hashes, separated by commas", text: $allowedIdentities, axis: .vertical)
                    .font(.caption.monospaced())
                LabeledContent("Receiver destination", value: store.localRemoteCopyHash)
                    .font(.caption.monospaced())
                Button("Save and Announce") {
                    configuration.allowedIdentityHashes = Set(
                        allowedIdentities
                            .split { $0 == "," || $0.isWhitespace }
                            .map { String($0).lowercased() }
                            .filter(DestinationHash.isValid)
                    )
                    Task { await store.updateRemoteCopyConfiguration(configuration) }
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Shared Files") {
                Button("Add Shared File", systemImage: "folder.badge.plus") { importerMode = .share }
                ForEach(store.meshFeatures.remoteFileShares, id: \.id) { share in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(share.remotePath)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(share.attachment.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await store.removeRemoteFileShare(share) }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
            Section("Transfers") {
                ForEach(store.meshFeatures.remoteFileTransfers) { transfer in
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: transfer.direction == .sending ? "arrow.up.circle" : "arrow.down.circle")
                            Text(transfer.remotePath).font(.headline)
                            Spacer()
                            Text(transfer.state).foregroundStyle(.secondary)
                        }
                        ProgressView(value: transfer.progress)
                    }
                }
            }
        }
        .navigationTitle("Remote Files")
        .onAppear {
            configuration = store.meshFeatures.remoteCopy
            allowedIdentities = configuration.allowedIdentityHashes.sorted().joined(separator: ", ")
        }
        .fileImporter(isPresented: Binding(
            get: { importerMode != nil },
            set: { if !$0 { importerMode = nil } }
        ), allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result, let mode = importerMode else { importerMode = nil; return }
            importerMode = nil
            Task {
                do {
                    switch mode {
                    case .send:
                        _ = try await store.sendRemoteFile(destinationHash: destination, source: url)
                    case .share:
                        try await store.addRemoteFileShare(from: url)
                    }
                } catch { store.lastError = error.localizedDescription }
            }
        }
    }
}

private struct NomadServerView: View {
    @Bindable var store: SidebandStore
    @State private var configuration = NomadServerConfiguration()
    @State private var path = NomadNetworkProtocol.indexPath
    @State private var title = "Home"
    @State private var source = "# Welcome\n\nThis page is hosted by Lower Sideband."
    @State private var importingFile = false

    var body: some View {
        Form {
            Section("Nomad Mesh Server") {
                Toggle("Host pages and files", isOn: $configuration.enabled)
                TextField("Server name", text: $configuration.name)
                LabeledContent("Node destination", value: store.localNomadServerHash)
                    .font(.caption.monospaced())
                Button("Save and Announce") { Task { await store.updateNomadServer(configuration) } }
                    .buttonStyle(.borderedProminent)
            }
            Section("Publish Page") {
                TextField("/page/index.mu", text: $path).font(.caption.monospaced())
                TextField("Title", text: $title)
                TextEditor(text: $source).font(.body.monospaced()).frame(minHeight: 140)
                Button("Publish Page", systemImage: "network") {
                    Task {
                        await store.saveHostedNomadPage(
                            NomadHostedPage(path: path, title: title, source: source)
                        )
                    }
                }
            }
            Section("Published Pages") {
                ForEach(store.meshFeatures.hostedNomadPages) { page in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(page.title).font(.headline)
                            Text(page.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { store.removeHostedNomadPage(page) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            Section("Published Files") {
                Button("Add File", systemImage: "doc.badge.plus") { importingFile = true }
                ForEach(store.meshFeatures.hostedNomadFiles) { file in
                    HStack {
                        Text(file.path).font(.caption.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            Task { await store.removeHostedNomadFile(file) }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Nomad Server")
        .onAppear { configuration = store.meshFeatures.nomadServer }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            Task {
                do { try await store.addHostedNomadFile(from: url) }
                catch { store.lastError = error.localizedDescription }
            }
        }
    }
}

private struct RelayChatView: View {
    @Bindable var store: SidebandStore
    @State private var hub = ""
    @State private var roomName = "#general"
    @State private var nickname = "Sideband"
    @State private var accessKey = ""
    @State private var selectedRoomID: String?
    @State private var message = ""
    @State private var isWorking = false

    private var selectedRoom: RelayChatRoom? {
        store.meshFeatures.relayRooms.first { $0.id == selectedRoomID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoomID) {
                Section("Joined Rooms") {
                    ForEach(store.meshFeatures.relayRooms) { room in
                        VStack(alignment: .leading) {
                            Text(room.name).font(.headline)
                            Text("\(room.nickname) · \(room.members.count) present")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(room.id)
                        .contextMenu {
                            Button("Part Room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                Task { await store.partRelayChat(room) }
                            }
                        }
                    }
                }
                Section("Join a Hub") {
                    TextField("RRC hub destination", text: $hub).font(.caption.monospaced())
                    TextField("Room", text: $roomName)
                    TextField("Nickname", text: $nickname)
                    SecureField("Room access key (optional)", text: $accessKey)
                    Button("Join Room", systemImage: "person.3.fill") { Task { await join() } }
                        .disabled(isWorking || hub.isEmpty || roomName.isEmpty || nickname.isEmpty)
                }
            }
            .navigationTitle("Relay Chat")
        } detail: {
            if let room = selectedRoom {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(room.name).font(.title2.bold())
                            Text("Encrypted via \(room.hubDestinationHash)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label("\(room.members.count)", systemImage: "person.2")
                    }.padding()
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(store.meshFeatures.relayTranscript.filter { $0.roomID == room.id }) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.nickname ?? entry.source).font(.caption.bold())
                                    Text(entry.body).textSelection(.enabled)
                                    Text(entry.sentAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: entry.isOutgoing ? .trailing : .leading)
                            }
                        }.padding()
                    }
                    Divider()
                    HStack {
                        TextField("Message", text: $message)
                            .onSubmit { Task { await send(room) } }
                        Button("Send", systemImage: "paperplane.fill") { Task { await send(room) } }
                            .buttonStyle(.borderedProminent).disabled(message.isEmpty)
                    }.padding()
                }
            } else {
                ContentUnavailableView("Join a Relay Chat room", systemImage: "person.3", description: Text("Enter a validated rrc.hub destination, room and nickname."))
            }
        }
    }

    @MainActor private func join() async {
        isWorking = true; defer { isWorking = false }
        do {
            try await store.joinRelayChat(
                hubDestinationHash: hub,
                room: roomName,
                nickname: nickname,
                accessKey: accessKey
            )
            selectedRoomID = "\(hub.lowercased()):\(roomName)"
        } catch { store.lastError = error.localizedDescription }
    }

    @MainActor private func send(_ room: RelayChatRoom) async {
        let body = message; message = ""
        do { try await store.sendRelayChatMessage(room: room, text: body) }
        catch { message = body; store.lastError = error.localizedDescription }
    }
}

private struct RemoteShellView: View {
    @Bindable var store: SidebandStore
    @State private var destination = ""
    @State private var selectedID: UUID?
    @State private var input = ""
    @State private var showingConfirmation = false

    private var selected: RemoteShellSessionRecord? { store.meshFeatures.shellSessions.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Sessions") {
                    ForEach(store.meshFeatures.shellSessions) { session in
                        VStack(alignment: .leading) {
                            Text(session.title).font(.headline)
                            Text(session.state).font(.caption).foregroundStyle(session.state == "Connected" ? .green : .secondary)
                            Text(session.destinationHash).font(.caption2.monospaced()).lineLimit(1)
                        }.tag(session.id)
                    }
                }
                Section("New Session") {
                    TextField("RNSH destination", text: $destination).font(.caption.monospaced())
                    Button("Connect Securely", systemImage: "lock.terminal") { showingConfirmation = true }
                        .disabled(destination.isEmpty)
                }
            }.navigationTitle("Remote Shell")
        } detail: {
            if let session = selected {
                VStack(spacing: 0) {
                    HStack { Text(session.title).font(.title2.bold()); Spacer(); Text(session.state).foregroundStyle(.secondary) }.padding()
                    Divider()
                    ScrollView {
                        Text(session.transcript.isEmpty ? "Waiting for remote output…" : session.transcript)
                            .font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding()
                    }
                    Divider()
                    HStack {
                        TextField("Terminal input", text: $input).font(.body.monospaced())
                            .onSubmit { Task { await send(session.id) } }
                        Button("Send", systemImage: "return") { Task { await send(session.id) } }.disabled(input.isEmpty)
                    }.padding()
                }
            } else {
                ContentUnavailableView("No remote shell selected", systemImage: "terminal", description: Text("Connections are end-to-end encrypted and require explicit confirmation."))
            }
        }
        .confirmationDialog("Connect to this remote shell?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Connect") { Task { await connect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only connect to a destination you trust. Commands entered here execute on the remote system.")
        }
    }

    @MainActor private func connect() async {
        do { selectedID = try await store.openRemoteShell(destinationHash: destination) }
        catch { store.lastError = error.localizedDescription }
    }
    @MainActor private func send(_ id: UUID) async {
        let text = input + "\n"; input = ""
        do { try await store.sendRemoteShellInput(sessionID: id, text: text) }
        catch { store.lastError = error.localizedDescription }
    }
}

private struct RemoteToolsView: View {
    @Bindable var store: SidebandStore
    @State private var destination = ""
    @State private var command = ""
    @State private var showingConfirmation = false
    @State private var isRunning = false

    var body: some View {
        NavigationSplitView {
            Form {
                Section("RNX Remote Execution") {
                    TextField("rnx.execute destination", text: $destination).font(.caption.monospaced())
                    TextField("Command", text: $command).font(.body.monospaced())
                    Button("Review and Run", systemImage: "play.fill") { showingConfirmation = true }
                        .disabled(isRunning || destination.isEmpty || command.isEmpty)
                }
                Section("RNCP File Transfer") {
                    Label("Stock Reticulum resource transfers", systemImage: "doc.badge.arrow.up")
                    Text("RNCP upload and fetch framing, safe filenames, size limits and SHA-256 verification are provided by ReticulumKit. Transfers use the same encrypted Reticulum resource pipeline as chat attachments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Remote Tools")
        } detail: {
            List {
                ForEach(store.meshFeatures.remoteToolRuns) { run in
                    Section {
                        LabeledContent("Destination", value: run.destinationHash)
                        LabeledContent("State", value: run.state)
                        if let exit = run.exitCode { LabeledContent("Exit code", value: "\(exit)") }
                        if !run.stdout.isEmpty {
                            Text(String(data: run.stdout, encoding: .utf8) ?? run.stdout.map { String(format: "%02x", $0) }.joined())
                                .font(.body.monospaced()).textSelection(.enabled)
                        }
                        if !run.stderr.isEmpty {
                            Text(String(data: run.stderr, encoding: .utf8) ?? run.stderr.map { String(format: "%02x", $0) }.joined())
                                .font(.body.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                        }
                    } header: { Text(run.command) }
                }
            }.navigationTitle("Execution History")
        }
        .confirmationDialog("Run this command remotely?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Run Command", role: .destructive) { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(command)
        }
    }

    @MainActor private func run() async {
        isRunning = true; defer { isRunning = false }
        do { _ = try await store.executeRemoteCommand(destinationHash: destination, command: command) }
        catch { store.lastError = error.localizedDescription }
    }
}

private struct NomadPageBrowserView: View {
    @Bindable var store: SidebandStore
    @State private var selectedID: UUID?
    @State private var addressText = ""
    @State private var title = ""
    @State private var source = ""
    @State private var editingID: UUID?
    @State private var isLoading = false
    @State private var showArchive = false
    @State private var mode: EditorMode = .preview

    private enum EditorMode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case source = "Micron"
        var id: Self { self }
    }

    private var features: MeshChatFeatureStore { store.meshFeatures }
    private var listedPages: [NomadPageDocument] {
        features.pages.filter { showArchive || !$0.isArchived }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Saved Pages") {
                    ForEach(listedPages) { page in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(page.title.isEmpty ? "Untitled Page" : page.title).font(.headline)
                            Text(page.address?.string ?? "Local Micron document")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(page.id)
                        .contextMenu {
                            Button(page.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
                                features.archivePage(page.id, archived: !page.isArchived)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                features.deletePage(page.id)
                            }
                        }
                    }
                }
                if !features.bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(features.bookmarks, id: \.self) { address in
                            Button {
                                addressText = address.string
                                Task { await openRemotePage() }
                            } label: {
                                Label(address.path, systemImage: "bookmark.fill")
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if !features.history.isEmpty {
                    Section {
                        ForEach(features.history.prefix(20)) { visit in
                            Button {
                                addressText = visit.address.string
                                Task { await openRemotePage() }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(visit.title).lineLimit(1)
                                    Text(visit.visitedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Clear History", role: .destructive) { features.clearHistory() }
                    } header: { Text("History") }
                }
            }
            .navigationTitle("Nomad Pages")
            .toolbar {
                Button { newPage() } label: { Label("New Micron page", systemImage: "square.and.pencil") }
                Toggle(isOn: $showArchive) { Label("Archived pages", systemImage: "archivebox") }
            }
            .onChange(of: selectedID) { _, id in
                guard let page = features.pages.first(where: { $0.id == id }) else { return }
                load(page)
            }
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("nomadnet://destination/page/index.mu", text: $addressText)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .accessibilityLabel("Nomad Network page address")
                    Button {
                        Task { await openRemotePage() }
                    } label: {
                        if isLoading { ProgressView().controlSize(.small) }
                        else { Label("Open", systemImage: "arrow.right.circle") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || NomadPageAddress(string: addressText) == nil)
                    if let address = NomadPageAddress(string: addressText) {
                        Button {
                            features.toggleBookmark(address)
                        } label: {
                            Image(systemName: features.bookmarks.contains(address) ? "bookmark.fill" : "bookmark")
                        }
                        .help(features.bookmarks.contains(address) ? "Remove bookmark" : "Bookmark this page")
                    }
                }
                .padding()

                HStack {
                    TextField("Page title", text: $title)
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                    Picker("View", selection: $mode) {
                        ForEach(EditorMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 230)
                    Button("Save", systemImage: "square.and.arrow.down") { savePage() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.bottom, 10)

                Divider()
                if mode == .source {
                    TextEditor(text: $source)
                        .font(.body.monospaced())
                        .padding(8)
                        .accessibilityLabel("Micron page source editor")
                } else {
                    ScrollView {
                        MicronPreview(source: source)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
            }
            .navigationTitle(title.isEmpty ? "Page Browser" : title)
        }
    }

    private func newPage() {
        editingID = nil
        selectedID = nil
        addressText = ""
        title = "New Micron Page"
        source = "# New Micron Page\n\nWrite resilient, lightweight content here."
        mode = .source
    }

    private func load(_ page: NomadPageDocument) {
        editingID = page.id
        addressText = page.address?.string ?? ""
        title = page.title
        source = page.source
        mode = .preview
    }

    private func savePage() {
        let now = Date.now
        let existing = editingID.flatMap { id in features.pages.first { $0.id == id } }
        let page = NomadPageDocument(
            id: editingID ?? UUID(),
            title: title.isEmpty ? "Untitled Page" : title,
            address: NomadPageAddress(string: addressText),
            source: source,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            isArchived: existing?.isArchived ?? false
        )
        features.savePage(page)
        editingID = page.id
        selectedID = page.id
    }

    @MainActor private func openRemotePage() async {
        guard let address = NomadPageAddress(string: addressText) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            source = try await store.fetchNomadPage(address)
            title = address.path
            editingID = features.pages.first(where: { $0.address == address })?.id
            selectedID = editingID
            mode = .preview
        } catch {
            store.lastError = "Could not open Nomad page: \(error.localizedDescription)"
        }
    }
}

private struct MicronPreview: View {
    let source: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MicronParser.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(text).font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.bold() : .headline)
                        .textSelection(.enabled)
                case .paragraph(let text):
                    Text(text).font(.body).textSelection(.enabled)
                case .separator:
                    Divider()
                case .link(let label, let target):
                    Label(label, systemImage: "link")
                        .foregroundStyle(.tint)
                        .help(target)
                }
            }
        }
    }
}

private struct IdentityProfilesView: View {
    @Bindable var store: SidebandStore
    @State private var showingCreate = false
    @State private var showingImport = false
    @State private var newName = ""
    @State private var privateIdentity = ""
    @State private var isWorking = false

    var body: some View {
        List {
            Section {
                ForEach(store.identityProfiles) { profile in
                    HStack(spacing: 12) {
                        Image(systemName: profile.id == store.activeIdentityProfileID ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                            .font(.title2).foregroundStyle(profile.id == store.activeIdentityProfileID ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.headline)
                            Text(profile.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(profile.id == store.activeIdentityProfileID ? "Active now" : "Last used \(profile.lastUsedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id != store.activeIdentityProfileID {
                            Button("Switch") { Task { await switchTo(profile.id) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(isWorking)
                            Button(role: .destructive) {
                                do { try store.deleteIdentityProfile(profile.id) }
                                catch { store.lastError = error.localizedDescription }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                Text("Secure Identities")
            } footer: {
                Text("Each identity has its own encrypted conversations, drafts, call history and Reticulum destination. Private keys remain in Keychain and are never shown in this list.")
            }
            Section("Actions") {
                Button("Create Identity", systemImage: "person.crop.circle.badge.plus") { showingCreate = true }
                Button("Import Private Identity", systemImage: "square.and.arrow.down") { showingImport = true }
            }
        }
        .navigationTitle("Identity Profiles")
        .disabled(isWorking)
        .alert("Create Identity", isPresented: $showingCreate) {
            TextField("Profile name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createProfile() } }
        } message: {
            Text("A new Reticulum identity and isolated encrypted workspace will be created.")
        }
        .sheet(isPresented: $showingImport) {
            NavigationStack {
                Form {
                    TextField("Profile name", text: $newName)
                    TextEditor(text: $privateIdentity)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                    Text("Paste an RNS-PRIVATE-1 identity. It is moved directly into Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("Import Identity")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingImport = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { Task { await importProfile() } }
                            .disabled(privateIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 360)
        }
    }

    @MainActor private func createProfile() async {
        isWorking = true
        defer { isWorking = false; newName = "" }
        do { _ = try await store.createIdentityProfile(named: newName) }
        catch { store.lastError = error.localizedDescription }
    }

    @MainActor private func importProfile() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await store.importIdentityProfile(named: newName, privateIdentityText: privateIdentity)
            privateIdentity = ""
            newName = ""
            showingImport = false
        } catch { store.lastError = error.localizedDescription }
    }

    @MainActor private func switchTo(_ id: UUID) async {
        isWorking = true
        defer { isWorking = false }
        do { try await store.switchIdentityProfile(to: id) }
        catch { store.lastError = error.localizedDescription }
    }
}

private struct TelephoneCenterView: View {
    @Bindable var store: SidebandStore
    @State private var preferences = SidebandTelephonePreferences()
    @State private var search = ""

    private var contacts: [Conversation] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.conversations.filter {
            needle.isEmpty || $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.destinationHash.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        Form {
            Section("Phonebook") {
                TextField("Search contacts", text: $search)
                ForEach(contacts) { contact in
                    HStack {
                        Image(systemName: contact.appearanceSymbol.rawValue)
                            .foregroundStyle(contact.isBlocked ? Color.secondary : Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(contact.displayName)
                            Text(contact.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await store.startVoiceCall(conversationID: contact.id) }
                        } label: { Image(systemName: "phone.fill") }
                            .buttonStyle(.bordered)
                            .disabled(contact.isBlocked || store.voiceCall != nil || store.networkState != .ready)
                            .help("Start an end-to-end encrypted LXST call")
                        Button {
                            if let link = store.contactLink(for: contact.id) {
                                copyMeshFeatureText(link.url.absoluteString)
                            }
                        } label: { Image(systemName: "person.crop.circle.badge.checkmark") }
                            .buttonStyle(.bordered)
                            .help("Copy this contact card for sharing")
                    }
                }
            }
            Section("Incoming Calls") {
                Picker("Ringtone", selection: $preferences.ringtone) {
                    ForEach(SidebandRingtone.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Voicemail auto-response", isOn: $preferences.voicemailEnabled)
                if preferences.voicemailEnabled {
                    Stepper("Answer after \(preferences.ringTimeoutSeconds) seconds", value: $preferences.ringTimeoutSeconds, in: 10...90, step: 5)
                    TextEditor(text: $preferences.voicemailGreeting)
                        .frame(minHeight: 90)
                    Text("If an encrypted call is unanswered, Lower Sideband ends the call cleanly and sends this prompt so the caller can leave an LXMF voice message.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Voice Quality") {
                Picker("Preferred profile", selection: Binding(
                    get: { store.preferredVoiceProfile },
                    set: { store.setPreferredVoiceProfile($0) }
                )) {
                    ForEach(LXSTVoice.Profile.allCases.filter(\.isLocallySupported), id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Trusted contacts only", isOn: Binding(
                    get: { store.voiceTrustedOnly },
                    set: { store.setVoiceTrustedOnly($0) }
                ))
                Label("Calls use native ReticulumKit links and LXST signalling.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("LXST Telephone")
        .onAppear { preferences = store.meshFeatures.telephone }
        .onChange(of: preferences) { _, value in store.meshFeatures.updateTelephone(value) }
    }
}
