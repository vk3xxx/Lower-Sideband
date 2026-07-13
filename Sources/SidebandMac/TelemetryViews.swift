import MapKit
import SidebandCore
import SwiftUI

struct TelemetryMessageCard: View {
    let telemetry: SidebandTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Telemetry", systemImage: "location.fill").font(.caption.bold())
            if let location = telemetry.location {
                Text("\(location.latitude.formatted(.number.precision(.fractionLength(5)))), \(location.longitude.formatted(.number.precision(.fractionLength(5))))")
                    .font(.caption.monospacedDigit())
                HStack(spacing: 10) {
                    Label("±\(location.accuracy.formatted(.number.precision(.fractionLength(0)))) m", systemImage: "scope")
                    if location.speed > 0.1 {
                        Label("\(location.speed.formatted(.number.precision(.fractionLength(1)))) km/h", systemImage: "speedometer")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let battery = telemetry.battery {
                Label("\(battery.chargePercent.formatted(.number.precision(.fractionLength(0))))%\(battery.isCharging ? " · charging" : "")", systemImage: battery.isCharging ? "battery.100percent.bolt" : "battery.100percent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

private struct TelemetryMapPoint: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let outgoing: Bool
}

struct ConversationTelemetryMapView: View {
    let conversationName: String
    private let points: [TelemetryMapPoint]
    @Environment(\.dismiss) private var dismiss

    init(conversationName: String, messages: [Message]) {
        self.conversationName = conversationName
        points = messages.compactMap { message in
            guard let location = message.telemetry?.location else { return nil }
            return TelemetryMapPoint(
                id: message.id,
                coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                timestamp: location.updatedAt,
                outgoing: message.direction == .outgoing
            )
        }
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: initialPosition) {
                ForEach(points) { point in
                    Marker(point.timestamp.formatted(date: .abbreviated, time: .shortened), coordinate: point.coordinate)
                        .tint(point.outgoing ? .blue : .orange)
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
                MapUserLocationButton()
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(points.count) location \(points.count == 1 ? "update" : "updates") · blue sent, orange received")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
            .navigationTitle("\(conversationName) Telemetry")
            .toolbar { Button("Done") { dismiss() } }
        }
        .platformTelemetryMapSize()
    }

    private var initialPosition: MapCameraPosition {
        guard let latest = points.last else { return .automatic }
        return .region(MKCoordinateRegion(center: latest.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000))
    }
}

private extension View {
    @ViewBuilder func platformTelemetryMapSize() -> some View {
        #if os(macOS)
        frame(minWidth: 620, minHeight: 440)
        #else
        self
        #endif
    }
}
