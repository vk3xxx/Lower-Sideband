import SwiftUI
import SidebandCore

struct RNodeEditorView: View {
    @State private var draft: RNodeConfiguration
    @State private var preset = 0
    let onSave: (RNodeConfiguration) -> Void
    let onCancel: () -> Void

    init(configuration: RNodeConfiguration, onSave: @escaping (RNodeConfiguration) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: configuration)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                radioSection
                airtimeSection
                stationSection
            }
            .formStyle(.grouped)
            .navigationTitle("RNode Configuration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).help("Discard these RNode configuration changes") }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(draft) }.buttonStyle(.borderedProminent).help("Validate, save and connect this RNode configuration") }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
    }

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $draft.name)
                .help("A private name used to identify this RNode in Lower Sideband")
            Picker("Transport", selection: $draft.transport) {
                Text("Bluetooth LE").tag(RNodeTransportKind.bluetoothLE)
                Text("Wi-Fi / TCP").tag(RNodeTransportKind.tcp)
                #if os(macOS)
                Text("USB serial").tag(RNodeTransportKind.serial)
                #endif
            }
            .help("Bluetooth uses an optional advertised name or peripheral UUID; TCP uses a host; USB serial uses a device path")
            TextField(targetPlaceholder, text: $draft.target).autocorrectionDisabled()
                .help(targetHelp)
            if draft.transport == .tcp {
                TextField("TCP port", value: $draft.tcpPort, format: .number.grouping(.never))
                    .help("RNode TCP service port. RNode firmware commonly uses 7633.")
            }
            Toggle("Enabled", isOn: $draft.enabled)
                .help(draft.enabled ? "This RNode will start with automatic network connection" : "This configuration is saved but will remain stopped")
            Toggle("Reconnect automatically", isOn: $draft.automaticallyReconnects)
                .help(draft.automaticallyReconnects ? "Reconnect this RNode after link loss" : "Leave this RNode stopped after link loss")
        }
    }

    private var radioSection: some View {
        Section("LoRa radio") {
            Picker("Preset", selection: $preset) {
                Text("Custom").tag(0)
                Text("Australia / New Zealand 915 MHz").tag(1)
                Text("Europe 868.2 MHz").tag(2)
                Text("Americas 915 MHz").tag(3)
                Text("70 cm 433.775 MHz").tag(4)
            }.onChange(of: preset) { _, value in applyPreset(value) }
                .help("Apply a starting frequency, bandwidth and power profile; confirm it is legal for your location and licence")
            TextField("Frequency (Hz)", value: $draft.frequency, format: .number.grouping(.never))
                .help("LoRa centre frequency: \(draft.frequency) Hz")
            TextField("Bandwidth (Hz)", value: $draft.bandwidth, format: .number.grouping(.never))
                .help("LoRa bandwidth: \(draft.bandwidth) Hz. Wider bandwidth increases speed and occupied spectrum.")
            Stepper("Transmit power: \(draft.txPower) dBm", value: $draft.txPower, in: 0...37)
                .help("Requested radio transmit power: \(draft.txPower) dBm, subject to hardware and firmware limits")
            Stepper("Spreading factor: \(draft.spreadingFactor)", value: $draft.spreadingFactor, in: 5...12)
                .help("Spreading factor \(draft.spreadingFactor). Higher values improve sensitivity but reduce data rate.")
            Stepper("Coding rate: \(draft.codingRate)", value: $draft.codingRate, in: 5...8)
                .help("Coding rate 4/\(draft.codingRate). More redundancy improves resilience but reduces throughput.")
        }
    }

    private var airtimeSection: some View {
        Section("Airtime protection") {
            TextField("Short-term limit (%)", value: Binding(get: { draft.shortTermAirtimeLimit ?? 0 }, set: { draft.shortTermAirtimeLimit = $0 }), format: .number)
                .help("Short-term channel airtime ceiling: \(draft.shortTermAirtimeLimit ?? 0)%")
            TextField("Long-term limit (%)", value: Binding(get: { draft.longTermAirtimeLimit ?? 0 }, set: { draft.longTermAirtimeLimit = $0 }), format: .number)
                .help("Long-term channel airtime ceiling: \(draft.longTermAirtimeLimit ?? 0)%")
            Text("Always choose frequencies, power and airtime limits permitted for your location and licence. Lower Sideband does not override RNode firmware safety limits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stationSection: some View {
        Section("Station identification and display") {
            TextField("Station ID / callsign", text: Binding(
                get: { draft.beaconCallsign ?? "" },
                set: { draft.beaconCallsign = $0.isEmpty ? nil : $0 }
            ))
            .help("Optional plain-text RNode station ID. It is transmitted over the radio and is therefore public; maximum 32 UTF-8 bytes.")
            if draft.beaconCallsign?.isEmpty == false {
                TextField("Station ID interval (seconds)", value: Binding(
                    get: { draft.beaconInterval ?? 600 },
                    set: { draft.beaconInterval = max(30, $0) }
                ), format: .number.grouping(.never))
                .help("Transmit the station ID after radio traffic at this interval; the minimum is 30 seconds.")
            }
            Toggle("Use external framebuffer", isOn: Binding(
                get: { draft.externalFramebufferEnabled ?? false },
                set: { draft.externalFramebufferEnabled = $0 }
            ))
            .help("Let Lower Sideband control the RNode's 64×64 monochrome framebuffer when supported by its display firmware.")
        }
    }

    private var targetPlaceholder: String {
        switch draft.transport {
        case .bluetoothLE: "Optional RNode name or peripheral UUID"
        case .tcp: "RNode hostname or IP address"
        case .serial: "Serial device path, for example /dev/cu.usbserial…"
        case .simulated: "Simulation"
        }
    }

    private var targetHelp: String {
        switch draft.transport {
        case .bluetoothLE: draft.target.isEmpty ? "Empty means automatically use the first compatible nearby RNode" : "Match Bluetooth RNode named or identified as \(draft.target)"
        case .tcp: "Connect to the RNode Wi-Fi/TCP service at \(draft.target.isEmpty ? "the entered hostname" : draft.target):\(draft.tcpPort)"
        case .serial: "macOS serial device path for the USB RNode"
        case .simulated: "Deterministic test transport; no physical radio is used"
        }
    }

    private func applyPreset(_ preset: Int) {
        switch preset {
        case 1: draft.frequency = 915_000_000; draft.bandwidth = 125_000; draft.txPower = 14
        case 2: draft.frequency = 868_200_000; draft.bandwidth = 125_000; draft.txPower = 14
        case 3: draft.frequency = 915_000_000; draft.bandwidth = 125_000; draft.txPower = 17
        case 4: draft.frequency = 433_775_000; draft.bandwidth = 125_000; draft.txPower = 10
        default: break
        }
    }
}
