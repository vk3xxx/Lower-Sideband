import Foundation
import ReticulumKit
import SidebandCore
import SwiftUI

struct ReticulumInterfaceProfilesView: View {
    @Bindable var store: SidebandStore
    @State private var editingProfile: ReticulumInterfaceProfile?

    var body: some View {
        Form {
            Section {
                if store.reticulumInterfaceProfiles.isEmpty {
                    ContentUnavailableView(
                        "No Custom Interfaces",
                        systemImage: "network.slash",
                        description: Text("Automatic discovery and public gateways remain available. Add a profile only for a specific transport.")
                    )
                } else {
                    ForEach(store.reticulumInterfaceProfiles) { profile in
                        HStack {
                            Image(systemName: profile.kind.isListener ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right")
                                .foregroundStyle(profile.enabled ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text(profile.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let snapshot = store.configuredInterfaceSnapshots.first(where: { $0.id == profile.id }) {
                                    Text(stateDescription(snapshot.state))
                                        .font(.caption2)
                                        .foregroundStyle(stateColor(snapshot.state))
                                } else if profile.enabled {
                                    Text("Starts with the network engine")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { profile.enabled },
                                set: { try? store.setReticulumInterfaceProfileEnabled(id: profile.id, enabled: $0) }
                            ))
                            .labelsHidden()
                            Button("Edit") { editingProfile = profile }
                        }
                        .help("\(profile.kind.title). \(profile.enabled ? "Enabled" : "Disabled").")
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            try? store.removeReticulumInterfaceProfile(id: store.reticulumInterfaceProfiles[offset].id)
                        }
                    }
                }
            } header: {
                Text("Configured interfaces")
            } footer: {
                Text("Transport implementation and validation are provided exclusively by ReticulumKit. Listener conflicts are checked before saving.")
            }

            Section {
                Menu {
                    ForEach(availableKinds, id: \.self) { kind in
                        Button(kind.title) { editingProfile = defaultProfile(kind: kind) }
                    }
                } label: {
                    Label("Add Interface", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            ReticulumInterfaceEditorView(profile: profile) { updated in
                do {
                    try store.saveReticulumInterfaceProfile(updated)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
    }

    private var availableKinds: [ReticulumInterfaceKind] {
        #if os(macOS)
        [.tcpClient, .tcpServer, .backboneClient, .backboneServer, .i2p, .udp,
         .serial, .kiss, .ax25Kiss, .pipe, .webSocketClient, .webSocketServer,
         .httpClient, .httpServer, .weave]
        #else
        [.tcpClient, .backboneClient, .i2p, .udp, .webSocketClient, .httpClient, .weave]
        #endif
    }

    private func defaultProfile(kind: ReticulumInterfaceKind) -> ReticulumInterfaceProfile {
        var profile = ReticulumInterfaceProfile(name: kind.title, kind: kind)
        if kind.applicableFields.contains(.port) { profile.port = 4_242 }
        if kind.applicableFields.contains(.listenHost) { profile.listenHost = "0.0.0.0" }
        if kind == .webSocketClient { profile.url = URL(string: "ws://127.0.0.1:4242/") }
        if kind == .httpClient { profile.url = URL(string: "http://127.0.0.1:4242/") }
        if kind == .webSocketServer || kind == .httpServer { profile.url = URL(string: "/") }
        if kind == .udp { profile.forwardHost = "255.255.255.255"; profile.forwardPort = 4_242 }
        if kind == .weave {
            profile.switchID = Data(repeating: 0, count: 4)
            profile.localEndpointID = Data((0..<16).map(UInt8.init))
        }
        return profile
    }
}

private struct ReticulumInterfaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReticulumInterfaceProfile
    @State private var validationMessage: String?
    @State private var i2pTestMessage: String?
    @State private var isTestingI2P = false
    let save: (ReticulumInterfaceProfile) -> String?

    init(profile: ReticulumInterfaceProfile, save: @escaping (ReticulumInterfaceProfile) -> String?) {
        _draft = State(initialValue: profile)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Interface") {
                    TextField("Name", text: $draft.name)
                    Picker("Transport", selection: $draft.kind) {
                        ForEach(editorKinds, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Mode", selection: $draft.mode) {
                        Text("Full").tag(ReticulumInterfaceMode.full)
                        Text("Access point").tag(ReticulumInterfaceMode.accessPoint)
                        Text("Point to point").tag(ReticulumInterfaceMode.pointToPoint)
                        Text("Roaming").tag(ReticulumInterfaceMode.roaming)
                        Text("Boundary").tag(ReticulumInterfaceMode.boundary)
                        Text("Gateway").tag(ReticulumInterfaceMode.gateway)
                        Text("Internal").tag(ReticulumInterfaceMode.internalMode)
                    }
                    Toggle("Enabled", isOn: $draft.enabled)
                    if fields.contains(.reconnect) { Toggle("Reconnect automatically", isOn: $draft.reconnect) }
                }

                if fields.contains(.host) || fields.contains(.url) || fields.contains(.listenHost) {
                    Section("Endpoint") {
                        if fields.contains(.host) { TextField("Remote host or I2P destination", text: optional(\.host)) }
                        if fields.contains(.url) { TextField("URL", text: urlBinding) }
                        if fields.contains(.listenHost) { TextField("Listen address", text: optional(\.listenHost)) }
                        if fields.contains(.port) {
                            TextField("Port", value: $draft.port, format: .number.grouping(.never))
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                        if fields.contains(.forwardHost) { TextField("Forward address", text: optional(\.forwardHost)) }
                        if fields.contains(.forwardPort) {
                            TextField("Forward port", value: $draft.forwardPort, format: .number.grouping(.never))
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                        if fields.contains(.timeout) {
                            TextField("Connection timeout", value: $draft.connectTimeout, format: .number)
                        }
                        if fields.contains(.polling) {
                            TextField("Polling interval", value: $draft.pollInterval, format: .number)
                        }
                    }
                }

                if fields.contains(.device) || fields.contains(.bitrate) || fields.contains(.kissPort) {
                    Section("Hardware") {
                        if fields.contains(.device) {
                            TextField(draft.kind == .pipe ? "Executable path" : "Device", text: optional(\.device))
                        }
                        if fields.contains(.bitrate) { TextField("Bitrate / baud rate", value: $draft.bitrate, format: .number) }
                        if fields.contains(.kissPort) {
                            TextField("KISS port", value: $draft.kissPort, format: .number)
                            Toggle("KISS flow control", isOn: Binding(
                                get: { draft.flowControl ?? false },
                                set: { draft.flowControl = $0 }
                            ))
                        }
                        if fields.contains(.callsign) {
                            TextField("Callsign", text: optional(\.callsign))
                            TextField("SSID", value: $draft.ssid, format: .number)
                        }
                    }
                }

                if fields.contains(.pipeArguments) || fields.contains(.pipeEnvironment) {
                    Section {
                        if fields.contains(.pipeArguments) {
                            TextField("Arguments (one per line)", text: pipeArgumentsBinding, axis: .vertical)
                                .lineLimit(3...8)
                        }
                        if fields.contains(.pipeEnvironment) {
                            TextField("Environment (KEY=VALUE, one per line)", text: pipeEnvironmentBinding, axis: .vertical)
                                .lineLimit(3...8)
                        }
                    } header: {
                        Text("Pipe process")
                    } footer: {
                        Text("Lower Sideband launches only the absolute executable shown above. Shell expansion is never used.")
                    }
                }

                if fields.contains(.sam) {
                    Section("I2P SAM") {
                        TextField("SAM host", text: optional(\.samHost, default: "127.0.0.1"))
                        TextField("SAM port", value: $draft.samPort, format: .number.grouping(.never))
                        TextField("Session ID", text: optional(\.sessionID, default: "lower-sideband"))
                        Button {
                            testI2PBridge()
                        } label: {
                            if isTestingI2P {
                                Label("Testing SAM bridge…", systemImage: "hourglass")
                            } else {
                                Label("Test SAM Bridge", systemImage: "checkmark.circle")
                            }
                        }
                        .disabled(isTestingI2P)
                        if let i2pTestMessage {
                            Text(i2pTestMessage)
                                .font(.caption)
                                .foregroundStyle(i2pTestMessage.hasPrefix("Connected") ? Color.green : Color.orange)
                        }
                    }
                }

                if fields.contains(.switchID) {
                    Section("Weave") {
                        TextField("Switch ID (8 hex characters)", text: hex(\.switchID))
                        TextField("Local endpoint ID (32 hex characters)", text: hex(\.localEndpointID))
                        TextField("Remote endpoint ID (optional)", text: hex(\.remoteEndpointID))
                    }
                }

                Section("Interface authentication") {
                    TextField("Network name", text: optional(\.networkName))
                    SecureField("Passphrase", text: optional(\.passphrase))
                    TextField("IFAC bytes", value: $draft.ifacSize, format: .number)
                }

                Section("Limits") {
                    if fields.contains(.mtu) { TextField("Fixed MTU", value: $draft.fixedMTU, format: .number) }
                    if fields.contains(.transportIdentity) {
                        TextField("Transport identity (32 hex characters)", text: optional(\.transportIdentity))
                    }
                }

                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle(draft.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        validationMessage = save(draft)
                        if validationMessage == nil { dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private var fields: Set<ReticulumInterfaceField> { draft.kind.applicableFields }
    private var editorKinds: [ReticulumInterfaceKind] {
        #if os(macOS)
        [.tcpClient, .tcpServer, .backboneClient, .backboneServer, .i2p, .udp,
         .serial, .kiss, .ax25Kiss, .pipe, .webSocketClient, .webSocketServer,
         .httpClient, .httpServer, .weave]
        #else
        [.tcpClient, .backboneClient, .i2p, .udp, .webSocketClient, .httpClient, .weave]
        #endif
    }
    private func optional(_ path: WritableKeyPath<ReticulumInterfaceProfile, String?>, default value: String = "") -> Binding<String> {
        Binding(get: { draft[keyPath: path] ?? value }, set: { draft[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private var urlBinding: Binding<String> {
        Binding(get: { draft.url?.absoluteString ?? "" }, set: { draft.url = URL(string: $0) })
    }
    private var pipeArgumentsBinding: Binding<String> {
        Binding(
            get: { (draft.pipeArguments ?? []).joined(separator: "\n") },
            set: {
                let values = $0.split(whereSeparator: \.isNewline).map(String.init)
                draft.pipeArguments = values.isEmpty ? nil : values
            }
        )
    }
    private var pipeEnvironmentBinding: Binding<String> {
        Binding(
            get: {
                (draft.pipeEnvironment ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "\n")
            },
            set: {
                var values: [String: String] = [:]
                for line in $0.split(whereSeparator: \.isNewline) {
                    guard let separator = line.firstIndex(of: "=") else { continue }
                    values[String(line[..<separator])] = String(line[line.index(after: separator)...])
                }
                draft.pipeEnvironment = values.isEmpty ? nil : values
            }
        )
    }
    private func testI2PBridge() {
        isTestingI2P = true
        i2pTestMessage = nil
        let host = draft.samHost ?? "127.0.0.1"
        let port = draft.samPort ?? 7_656
        Task {
            do {
                let result = try await ReticulumI2PSAMDiagnostics.probe(
                    host: host,
                    port: port,
                    timeout: min(max(draft.connectTimeout, 1), 30)
                )
                await MainActor.run {
                    i2pTestMessage = "Connected · SAM \(result.samVersion)"
                    isTestingI2P = false
                }
            } catch {
                await MainActor.run {
                    i2pTestMessage = "Unavailable · \(error.localizedDescription)"
                    isTestingI2P = false
                }
            }
        }
    }
    private func hex(_ path: WritableKeyPath<ReticulumInterfaceProfile, Data?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: path]?.map { String(format: "%02x", $0) }.joined() ?? "" },
            set: { draft[keyPath: path] = Self.decodeHex($0) }
        )
    }
    private static func decodeHex(_ value: String) -> Data? {
        let clean = value.filter(\.isHexDigit)
        guard clean.count.isMultiple(of: 2) else { return nil }
        return Data(stride(from: 0, to: clean.count, by: 2).compactMap { index in
            let start = clean.index(clean.startIndex, offsetBy: index)
            return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)
        })
    }
}

private extension ReticulumInterfaceProfilesView {
    func stateDescription(_ state: ReticulumConfiguredInterfaceRuntime.State) -> String {
        switch state {
        case .starting: "Starting"
        case .ready: "Ready"
        case .failed(let reason): "Unavailable: \(reason)"
        case .stopped: "Stopped"
        }
    }

    func stateColor(_ state: ReticulumConfiguredInterfaceRuntime.State) -> Color {
        switch state {
        case .ready: .green
        case .failed: .red
        case .starting: .orange
        case .stopped: .secondary
        }
    }
}
