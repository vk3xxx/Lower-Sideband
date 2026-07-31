import SwiftUI
import SidebandCore

struct DeliveryActivityView: View {
    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case attention = "Attention"
        case proofs = "Proofs"
        case network = "Network"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    @State private var filter: ActivityFilter = .all
    @State private var recoveryRunning = false

    private var reliability: DeliveryReliabilitySnapshot { store.deliveryReliability }

    private var items: [DeliveryActivityItem] {
        switch filter {
        case .all: store.deliveryActivity
        case .attention: store.deliveryActivity.filter { $0.kind == .failed || $0.kind == .queued }
        case .proofs: store.deliveryActivity.filter { $0.kind == .awaitingProof || $0.kind == .delivered }
        case .network: store.deliveryActivity.filter { $0.kind == .diagnostic }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    reliabilityHeader
                    metrics
                    recoveryControls
                } header: {
                    Text("Current health")
                }

                Section("Connected transports") {
                    if reliability.interfaces.isEmpty {
                        Label("No TCP transports are active", systemImage: "network.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(reliability.interfaces) { interface in
                            interfaceRow(interface)
                        }
                    }
                    LabeledContent("Known routes", value: reliability.knownRouteCount.formatted())
                    LabeledContent("Active encrypted links", value: reliability.activeLinkCount.formatted())
                    if let lastReady = reliability.lastNetworkReadyAt {
                        LabeledContent("Last network ready") {
                            Text(lastReady, format: .relative(presentation: .named))
                        }
                    }
                }

                Section {
                    Picker("Activity filter", selection: $filter) {
                        ForEach(ActivityFilter.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    if items.isEmpty {
                        ContentUnavailableView(
                            "No Matching Activity",
                            systemImage: filter == .attention ? "checkmark.circle" : "tray",
                            description: Text(emptyDescription)
                        )
                    }
                    ForEach(items) { item in activityRow(item) }
                } header: {
                    Text("Delivery and proof history")
                } footer: {
                    Text("A message is only marked Delivered after Lower Sideband receives its Reticulum/LXMF delivery proof. Sent means it is still waiting for that proof.")
                }

                Section("Recovery history") {
                    LabeledContent("Proof timeouts", value: reliability.deliveryTimeoutCount.formatted())
                    LabeledContent("Recovered outbound messages", value: reliability.recoveredOutboundCount.formatted())
                    LabeledContent("Deferred keepalives", value: reliability.deferredKeepaliveCount.formatted())
                    LabeledContent("Deferred tunnel operations", value: reliability.deferredTunnelCount.formatted())
                }
            }
            .navigationTitle("Reliability Centre")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 760)
        #endif
    }

    private var reliabilityHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: healthIcon)
                .font(.title2)
                .foregroundStyle(healthColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(reliability.health.title).font(.headline)
                Text(reliability.summary).foregroundStyle(.secondary)
                if let action = reliability.recommendedAction {
                    Text(action).font(.caption).foregroundStyle(healthColor)
                }
            }
            Spacer()
            Label(
                reliability.automaticRecoveryEnabled ? "Automatic recovery on" : "Automatic recovery off",
                systemImage: reliability.automaticRecoveryEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle"
            )
            .font(.caption)
            .foregroundStyle(reliability.automaticRecoveryEnabled ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
            metric("Queued", reliability.queuedCount, .orange)
            metric("Awaiting proof", reliability.awaitingProofCount, .blue)
            metric("Delivered", reliability.deliveredCount, .green)
            metric("Failed", reliability.failedCount, .red)
        }
        .accessibilityElement(children: .contain)
    }

    private var recoveryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    recoveryRunning = true
                    Task {
                        await store.recoverMessageDelivery()
                        recoveryRunning = false
                    }
                } label: {
                    Label(recoveryRunning ? "Recovering…" : "Recover Delivery", systemImage: "cross.case")
                }
                .buttonStyle(.borderedProminent)
                .disabled(recoveryRunning)
                .help("Reconnect if required, refresh affected routes, retry failed messages and flush the queue")

                Button("Reconnect") { Task { await store.reconnectNetwork() } }
                    .buttonStyle(.bordered)
                    .disabled(recoveryRunning)
                    .help("Restart automatic transport discovery and reconnect all configured interfaces")

                Button("Flush Queue") { Task { await store.flushQueuedMessagesOnThisDevice() } }
                    .buttonStyle(.bordered)
                    .disabled(reliability.queuedCount == 0 || recoveryRunning)
                    .help("Take over eligible queued messages on this device, reconnect if needed, refresh routes and resume delivery")
            }
            if let status = store.queueFlushStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func interfaceRow(_ interface: DeliveryReliabilitySnapshot.Interface) -> some View {
        HStack(spacing: 12) {
            Image(systemName: interface.isReady ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(interface.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(interface.name).font(.headline)
                if let endpoint = interface.endpoint {
                    Text(endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let lastPacket = interface.lastPacketAt {
                    Text("Last traffic \(lastPacket.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(interface.isReady ? "Ready" : "Recovering")
                .font(.caption.weight(.semibold))
                .foregroundStyle(interface.isReady ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
    }

    private func activityRow(_ item: DeliveryActivityItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item.kind))
                .foregroundStyle(color(item.kind))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.detail).foregroundStyle(.secondary)
                if let route = item.route {
                    Label(route, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(item.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if item.kind == .failed, let id = item.messageID {
                Button("Retry") { Task { await store.retryMessage(id) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 3)
    }

    private func metric(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.title2.bold()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyDescription: String {
        switch filter {
        case .all: "Queued sends, delivery proofs, retries and failures will appear here."
        case .attention: "No queued or failed messages need attention."
        case .proofs: "No recent proof activity is available."
        case .network: "No recent network recovery events are available."
        }
    }

    private var healthIcon: String {
        switch reliability.health {
        case .healthy: "checkmark.shield.fill"
        case .recovering: "arrow.triangle.2.circlepath.circle.fill"
        case .degraded: "clock.badge.exclamationmark"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .offline: "network.slash"
        }
    }

    private var healthColor: Color {
        switch reliability.health {
        case .healthy: .green
        case .recovering: .blue
        case .degraded: .orange
        case .needsAttention: .red
        case .offline: .secondary
        }
    }

    private func icon(_ kind: DeliveryActivityItem.Kind) -> String {
        switch kind {
        case .queued: "clock"
        case .awaitingProof: "checkmark.circle.badge.questionmark"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .diagnostic: "waveform.path.ecg"
        }
    }

    private func color(_ kind: DeliveryActivityItem.Kind) -> Color {
        switch kind {
        case .queued: .orange
        case .awaitingProof: .blue
        case .delivered: .green
        case .failed: .red
        case .diagnostic: .secondary
        }
    }
}
