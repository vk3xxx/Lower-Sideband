import MapKit
import SidebandCore
import SwiftUI
import UniformTypeIdentifiers

private struct SituationPoint: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let updatedAt: Date
    let sensors: [SidebandTelemetry.SensorKind]
}

private struct OfflineMapLine: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
}

struct SituationMapView: View {
    @Bindable var store: SidebandStore
    @Environment(\.dismiss) private var dismiss
    @State private var importingOverlay = false
    @State private var offlineLines: [OfflineMapLine] = []
    @State private var overlayName: String?

    var body: some View {
        NavigationStack {
            Map(initialPosition: .automatic) {
                ForEach(offlineLines) { line in
                    MapPolyline(coordinates: line.coordinates).stroke(.secondary.opacity(0.75), lineWidth: 2)
                }
                ForEach(points) { point in
                    Annotation(point.name, coordinate: point.coordinate) {
                        VStack(spacing: 2) {
                            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                                .font(.title).foregroundStyle(point.updatedAt.timeIntervalSinceNow > -900 ? .green : .orange)
                            Text(point.name).font(.caption2.bold()).padding(3).background(.regularMaterial, in: Capsule())
                        }.help("\(point.name) · \(point.sensors.map(\.displayName).joined(separator: ", ")) · updated \(point.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(points.count) tracked object\(points.count == 1 ? "" : "s")")
                    if let overlayName { Text("Offline overlay: \(overlayName)") }
                    Text("Green: updated within 15 minutes · Orange: historical")
                }.font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding()
            }
            .navigationTitle("Situation Map")
            .toolbar {
                Button("Offline overlay", systemImage: "map.fill") { importingOverlay = true }
                    .help("Import a locally stored GeoJSON map overlay. It remains available without a network connection.")
                if !offlineLines.isEmpty {
                    Button("Remove overlay", systemImage: "trash", role: .destructive) { removeOverlay() }
                }
                Button("Done") { dismiss() }
            }
        }
        .onAppear { loadPersistedOverlay() }
        .fileImporter(isPresented: $importingOverlay, allowedContentTypes: [.json, UTType(filenameExtension: "geojson") ?? .data]) { result in
            switch result {
            case .success(let url): importOverlay(url)
            case .failure(let error): store.lastError = "Could not open offline map: \(error.localizedDescription)"
            }
        }
        .platformSituationMapSize()
    }

    private var points: [SituationPoint] {
        let names = Dictionary(uniqueKeysWithValues: store.conversations.map { ($0.destinationHash, $0.displayName) })
        var newest: [String: SituationPoint] = [:]
        for message in store.messages {
            let source = message.direction == .incoming
                ? store.conversations.first(where: { $0.id == message.conversationID })?.destinationHash
                : store.localDeliveryHash
            if let source, let telemetry = message.telemetry, let location = telemetry.location {
                retain(.init(id: source, name: names[source] ?? (source == store.localDeliveryHash ? "This device" : String(source.prefix(8))),
                             coordinate: .init(latitude: location.latitude, longitude: location.longitude),
                             updatedAt: location.updatedAt, sensors: telemetry.sensorKinds), in: &newest)
            }
            for entry in message.telemetryStream where entry.telemetry.location != nil {
                let source = entry.sourceHash.map { String(format: "%02x", $0) }.joined()
                let location = entry.telemetry.location!
                retain(.init(id: source, name: names[source] ?? String(source.prefix(8)),
                             coordinate: .init(latitude: location.latitude, longitude: location.longitude),
                             updatedAt: entry.timestamp, sensors: entry.telemetry.sensorKinds), in: &newest)
            }
        }
        return newest.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func retain(_ point: SituationPoint, in values: inout [String: SituationPoint]) {
        if values[point.id].map({ $0.updatedAt < point.updatedAt }) ?? true { values[point.id] = point }
    }

    private var storedOverlayURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SidebandSwift/OfflineMap.geojson")
    }

    private func importOverlay(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 50 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
            let lines = try decodeGeoJSON(data)
            guard !lines.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: storedOverlayURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storedOverlayURL, options: .atomic)
            offlineLines = lines; overlayName = url.lastPathComponent
            UserDefaults.standard.set(overlayName, forKey: "offlineMapOverlayName")
        } catch { store.lastError = "The offline map could not be imported: \(error.localizedDescription)" }
    }

    private func loadPersistedOverlay() {
        guard let data = try? Data(contentsOf: storedOverlayURL), let lines = try? decodeGeoJSON(data) else { return }
        offlineLines = lines
        overlayName = UserDefaults.standard.string(forKey: "offlineMapOverlayName") ?? "OfflineMap.geojson"
    }

    private func removeOverlay() {
        try? FileManager.default.removeItem(at: storedOverlayURL)
        UserDefaults.standard.removeObject(forKey: "offlineMapOverlayName")
        offlineLines = []; overlayName = nil
    }

    private func decodeGeoJSON(_ data: Data) throws -> [OfflineMapLine] {
        let objects = try MKGeoJSONDecoder().decode(data)
        var result: [OfflineMapLine] = []
        func append(_ shape: MKMultiPoint) {
            let points = shape.points()
            result.append(OfflineMapLine(coordinates: (0..<shape.pointCount).map { points[$0].coordinate }))
        }
        func process(_ geometry: Any) {
            if let line = geometry as? MKPolyline { append(line) }
            if let multi = geometry as? MKMultiPolyline { multi.polylines.forEach(append) }
            if let polygon = geometry as? MKPolygon { append(polygon) }
            if let multi = geometry as? MKMultiPolygon { multi.polygons.forEach { append($0) } }
        }
        for object in objects {
            if let feature = object as? MKGeoJSONFeature { feature.geometry.forEach(process) }
            else { process(object) }
        }
        return Array(result.prefix(20_000))
    }
}

private extension View {
    @ViewBuilder func platformSituationMapSize() -> some View {
        #if os(macOS)
        frame(minWidth: 760, minHeight: 560)
        #else
        self
        #endif
    }
}
