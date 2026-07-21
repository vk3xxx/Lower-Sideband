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
            }
            .formStyle(.grouped)
            .navigationTitle("RNode Configuration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(draft) }.buttonStyle(.borderedProminent) }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
    }

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $draft.name)
            Picker("Transport", selection: $draft.transport) {
                Text("Bluetooth LE").tag(RNodeTransportKind.bluetoothLE)
                Text("Wi-Fi / TCP").tag(RNodeTransportKind.tcp)
                #if os(macOS)
                Text("USB serial").tag(RNodeTransportKind.serial)
                #endif
            }
            TextField(targetPlaceholder, text: $draft.target).autocorrectionDisabled()
            if draft.transport == .tcp {
                TextField("TCP port", value: $draft.tcpPort, format: .number.grouping(.never))
            }
            Toggle("Enabled", isOn: $draft.enabled)
            Toggle("Reconnect automatically", isOn: $draft.automaticallyReconnects)
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
            TextField("Frequency (Hz)", value: $draft.frequency, format: .number.grouping(.never))
            TextField("Bandwidth (Hz)", value: $draft.bandwidth, format: .number.grouping(.never))
            Stepper("Transmit power: \(draft.txPower) dBm", value: $draft.txPower, in: 0...37)
            Stepper("Spreading factor: \(draft.spreadingFactor)", value: $draft.spreadingFactor, in: 5...12)
            Stepper("Coding rate: \(draft.codingRate)", value: $draft.codingRate, in: 5...8)
        }
    }

    private var airtimeSection: some View {
        Section("Airtime protection") {
            TextField("Short-term limit (%)", value: Binding(get: { draft.shortTermAirtimeLimit ?? 0 }, set: { draft.shortTermAirtimeLimit = $0 }), format: .number)
            TextField("Long-term limit (%)", value: Binding(get: { draft.longTermAirtimeLimit ?? 0 }, set: { draft.longTermAirtimeLimit = $0 }), format: .number)
            Text("Always choose frequencies, power and airtime limits permitted for your location and licence. Lower Sideband does not override RNode firmware safety limits.")
                .font(.caption).foregroundStyle(.secondary)
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
