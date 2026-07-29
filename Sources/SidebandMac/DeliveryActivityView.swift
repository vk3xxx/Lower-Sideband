import SwiftUI
import SidebandCore

struct DeliveryActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    @State private var failuresOnly = false

    private var items: [DeliveryActivityItem] {
        failuresOnly ? store.deliveryActivity.filter { $0.kind == .failed } : store.deliveryActivity
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        metric("Queued", store.queuedMessageCount, .orange)
                        metric("Awaiting proof", store.sentMessageCount, .blue)
                        metric("Delivered", store.deliveredMessageCount, .green)
                        metric("Failed", store.failedMessageCount, .red)
                    }
                    .accessibilityElement(children: .contain)
                    HStack {
                        Button("Flush Queue") { Task { await store.flushQueuedMessages() } }
                            .disabled(store.queuedMessageCount == 0 || store.networkState != .ready)
                        Button("Retry Failed") { Task { await store.retryAllFailedMessages() } }
                            .disabled(store.failedMessageCount == 0)
                        Toggle("Failures only", isOn: $failuresOnly)
                            .toggleStyle(.switch)
                    }
                } header: { Text("Delivery health") }

                Section("Activity") {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "No Delivery Activity",
                            systemImage: "checkmark.circle",
                            description: Text("Queued sends, delivery proofs, retries and failures will appear here.")
                        )
                    }
                    ForEach(items) { item in
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
                }
            }
            .navigationTitle("Delivery Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private func metric(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(value.formatted()).font(.title2.bold()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
