import MapKit
import SidebandCore
import SwiftUI
import UniformTypeIdentifiers

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
            if let temperature = telemetry.temperatureCelsius {
                Label("\(temperature.formatted(.number.precision(.fractionLength(1)))) °C", systemImage: "thermometer.medium")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let humidity = telemetry.relativeHumidityPercent {
                Label("\(humidity.formatted(.number.precision(.fractionLength(0))))% humidity", systemImage: "humidity")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let link = telemetry.physicalLink {
                let quality = link.qualityPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "unknown quality"
                Label("\(quality) link · RSSI \(link.rssi?.formatted(.number.precision(.fractionLength(0))) ?? "—")", systemImage: "network")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let watts = telemetry.value(for: .powerConsumptionWatts) {
                Label("\(watts.formatted(.number.precision(.fractionLength(1)))) W consumption", systemImage: "bolt")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Label(telemetry.isFresh() ? "Current" : "Historical · \(telemetry.mostRecentSensorDate.formatted(.relative(presentation: .named)))", systemImage: telemetry.isFresh() ? "checkmark.circle.fill" : "clock")
                .font(.caption2)
                .foregroundStyle(telemetry.isFresh() ? Color.green : Color.secondary)
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

private struct TelemetryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .xml, .json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ConversationTelemetryMapView: View {
    let conversationName: String
    private let points: [TelemetryMapPoint]
    private let messages: [Message]
    private let summary: SidebandTelemetryHistorySummary
    @Environment(\.dismiss) private var dismiss
    @State private var exportDocument: TelemetryExportDocument?
    @State private var exportType: UTType = .commaSeparatedText
    @State private var exportExtension = "csv"
    @State private var showingExporter = false

    init(conversationName: String, messages: [Message]) {
        self.conversationName = conversationName
        self.messages = messages
        summary = SidebandTelemetryHistory.summary(messages: messages)
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
                if points.count > 1 {
                    MapPolyline(coordinates: points.map(\.coordinate))
                        .stroke(.blue.opacity(0.7), lineWidth: 3)
                }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(points.count) location \(points.count == 1 ? "update" : "updates") · blue sent, orange received")
                    if summary.distanceMeters > 0 {
                        Text("Track \(Measurement(value: summary.distanceMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))) · \(summary.duration.formattedDuration)")
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .padding()
            }
            .navigationTitle("\(conversationName) Telemetry")
            .toolbar {
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("CSV data") { prepareExport(.csv) }
                    Button("GPX track") { prepareExport(.gpx) }
                    Button("JSON telemetry") { prepareExport(.json) }
                    Button("GeoJSON features") { prepareExport(.geojson) }
                }
                Button("Done") { dismiss() }
            }
        }
        .platformTelemetryMapSize()
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: exportType, defaultFilename: "Lower-Sideband-\(safeFilename).\(exportExtension)") { _ in
            exportDocument = nil
        }
    }

    private var initialPosition: MapCameraPosition {
        guard let latest = points.last else { return .automatic }
        return .region(MKCoordinateRegion(center: latest.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000))
    }


    private var safeFilename: String {
        conversationName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private func prepareExport(_ format: SidebandTelemetryExportFormat) {
        guard let data = SidebandTelemetryHistory.export(messages: messages, contactName: conversationName, format: format) else { return }
        exportDocument = TelemetryExportDocument(data: data)
        exportExtension = format.rawValue
        switch format {
        case .csv: exportType = .commaSeparatedText
        case .gpx: exportType = UTType(filenameExtension: "gpx") ?? .xml
        case .json, .geojson: exportType = .json
        }
        showingExporter = true
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        Duration.seconds(self).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1)))
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
