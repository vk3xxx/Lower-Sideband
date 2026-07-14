import SwiftUI
import SidebandCore

@main
struct SidebandApp: App {
    @State private var store = SidebandStore()

    @SceneBuilder
    var body: some Scene {
        #if os(macOS)
        WindowGroup("Sideband") { ContentView(store: store).frame(minWidth: 850, minHeight: 560) }
        .defaultSize(width: 1080, height: 720)
        #else
        WindowGroup("Sideband") { ContentView(store: store) }
        #endif
    }
}

#if DEBUG
@MainActor
enum DeliverySoakRunner {
    private static let environment = ProcessInfo.processInfo.environment
    private static var hasStarted = false
    private static var deliveryTimeoutBaseline = 0

    static func configureNetworkIfRequested(_ store: SidebandStore) {
        guard let mode = environment["SIDEBAND_SOAK_NETWORK_MODE"] else { return }
        store.removeDeliverySoakMessages()
        deliveryTimeoutBaseline = store.deliveryTimeoutCount
        store.autoConnectEnabled = mode == "automatic"
        store.internetOnlyEnabled = mode == "public"
        store.preferIPv6 = true
        store.networkPort = Int(environment["SIDEBAND_SOAK_PORT"] ?? "4242") ?? 4_242
        store.networkInternetPort = Int(environment["SIDEBAND_SOAK_INTERNET_PORT"] ?? "4242") ?? 4_242
        switch mode {
        case "local":
            store.networkHost = environment["SIDEBAND_SOAK_HOST"] ?? "10.20.20.133"
            store.networkIPv6Host = environment["SIDEBAND_SOAK_IPV6_HOST"] ?? ""
            store.networkInternetHost = ""
        case "public":
            store.networkHost = ""
            store.networkIPv6Host = ""
            store.networkInternetHost = environment["SIDEBAND_SOAK_INTERNET_HOST"] ?? "sydney.reticulum.au"
        case "automatic":
            store.networkHost = ""
            store.networkIPv6Host = ""
            store.networkInternetHost = ""
        default:
            break
        }
        UserDefaults.standard.set(store.autoConnectEnabled, forKey: "reticulumAutoConnect")
        UserDefaults.standard.set(store.internetOnlyEnabled, forKey: "reticulumInternetOnly")
        UserDefaults.standard.set(store.networkHost, forKey: "reticulumHost")
        UserDefaults.standard.set(store.networkIPv6Host, forKey: "reticulumIPv6Host")
        UserDefaults.standard.set(store.networkInternetHost, forKey: "reticulumInternetHost")
        UserDefaults.standard.set(store.networkInternetPort, forKey: "reticulumInternetPort")
        UserDefaults.standard.set(store.networkPort, forKey: "reticulumPort")
        UserDefaults.standard.set(store.preferIPv6, forKey: "reticulumPreferIPv6")
    }

    static func startNetworkIfRequested(_ store: SidebandStore) async -> Bool {
        guard let mode = environment["SIDEBAND_SOAK_NETWORK_MODE"] else { return false }
        switch mode {
        case "local":
            await store.connectNetwork(
                explicitHost: environment["SIDEBAND_SOAK_HOST"] ?? "10.20.20.133",
                explicitPort: UInt16(environment["SIDEBAND_SOAK_PORT"] ?? "4242") ?? 4_242
            )
        case "public":
            let host = environment["SIDEBAND_SOAK_INTERNET_HOST"] ?? "sydney.reticulum.au"
            let port = UInt16(environment["SIDEBAND_SOAK_INTERNET_PORT"] ?? "4242") ?? 4_242
            await store.connectNetwork(explicitHost: host, explicitPort: port, internetGatewayID: "\(host.lowercased()):\(port)")
        case "automatic":
            await store.startAutomaticConnection()
        default:
            return false
        }
        return true
    }

    static func runIfRequested(_ store: SidebandStore) async {
        guard !hasStarted else { return }
        guard
            let destination = environment["SIDEBAND_SOAK_DESTINATION"],
            let outboundPrefix = environment["SIDEBAND_SOAK_OUTBOUND_PREFIX"],
            let inboundPrefix = environment["SIDEBAND_SOAK_INBOUND_PREFIX"],
            let count = Int(environment["SIDEBAND_SOAK_COUNT"] ?? ""), count > 0,
            let reportName = environment["SIDEBAND_SOAK_REPORT"]
        else { return }
        hasStarted = true

        let reportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SidebandSwift", directoryHint: .isDirectory)
            .appending(path: reportName)
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let startedAt = Date()
        var networkReadyDeadline = ContinuousClock.now + .seconds(90)
        while store.networkState != .ready, ContinuousClock.now < networkReadyDeadline {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "waiting-for-network")
            try? await Task.sleep(for: .seconds(1))
        }

        guard store.networkState == .ready else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "network-timeout")
            return
        }

        guard store.addConversation(destinationHash: destination, displayName: "Delivery soak", select: true) else {
            await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "invalid-destination")
            return
        }

        let existingBodies = Set(store.messages.map(\.body))
        for sequence in 1...count {
            let body = messageBody(prefix: outboundPrefix, sequence: sequence)
            if !existingBodies.contains(body) { await store.send(body) }
            try? await Task.sleep(for: .milliseconds(20))
        }

        networkReadyDeadline = ContinuousClock.now + .seconds(600)
        while ContinuousClock.now < networkReadyDeadline {
            let report = makeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, phase: "running")
            write(report, to: reportURL)
            if report.outboundDelivered == count,
               report.inboundReceived == count,
               report.outboundQueued == 0,
               report.outboundFailed == 0,
               report.missingOutbound.isEmpty,
               report.missingInbound.isEmpty,
               report.duplicateInbound.isEmpty,
               report.inboundInOrder {
                var complete = report
                complete.phase = "complete"
                complete.completedAt = .now
                write(complete, to: reportURL)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await writeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, reportURL: reportURL, phase: "delivery-timeout")
    }

    private static func writeReport(store: SidebandStore, destination: String, outboundPrefix: String, inboundPrefix: String, count: Int, startedAt: Date, reportURL: URL, phase: String) async {
        write(makeReport(store: store, destination: destination, outboundPrefix: outboundPrefix, inboundPrefix: inboundPrefix, count: count, startedAt: startedAt, phase: phase), to: reportURL)
    }

    private static func makeReport(store: SidebandStore, destination: String, outboundPrefix: String, inboundPrefix: String, count: Int, startedAt: Date, phase: String) -> DeliverySoakReport {
        let conversationID = store.conversations.first(where: { $0.destinationHash == destination.lowercased() })?.id
        let relevant = store.messages.filter { $0.conversationID == conversationID }
        let outbound = relevant.filter { $0.direction == .outgoing && $0.body.hasPrefix(outboundPrefix + "-") }
        let inbound = relevant.filter { $0.direction == .incoming && $0.body.hasPrefix(inboundPrefix + "-") }
        let outboundBodies = Set(outbound.map(\.body))
        let inboundBodies = inbound.map(\.body)
        let inboundBodySet = Set(inboundBodies)
        let expectedOutbound = (1...count).map { messageBody(prefix: outboundPrefix, sequence: $0) }
        let expectedInbound = (1...count).map { messageBody(prefix: inboundPrefix, sequence: $0) }
        let duplicateInbound = Dictionary(grouping: inboundBodies, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        let receivedInOrder = inbound.sorted(by: { $0.timestamp < $1.timestamp }).map(\.body)
        return DeliverySoakReport(
            phase: phase,
            networkMode: environment["SIDEBAND_SOAK_NETWORK_MODE"] ?? "unchanged",
            networkState: String(describing: store.networkState),
            automaticConnection: store.automaticConnectionDescription,
            destination: destination,
            startedAt: startedAt,
            completedAt: nil,
            expectedEachDirection: count,
            outboundQueued: outbound.count(where: { $0.state == .queued }),
            outboundSent: outbound.count(where: { $0.state == .sent }),
            outboundDelivered: outbound.count(where: { $0.state == .delivered }),
            outboundFailed: outbound.count(where: { $0.state == .failed }),
            inboundReceived: inbound.count,
            missingOutbound: expectedOutbound.filter { !outboundBodies.contains($0) },
            missingInbound: expectedInbound.filter { !inboundBodySet.contains($0) },
            duplicateInbound: duplicateInbound,
            inboundInOrder: receivedInOrder == expectedInbound,
            knownPath: store.hasPath(to: destination),
            deliveryTimeouts: max(0, store.deliveryTimeoutCount - deliveryTimeoutBaseline),
            lastError: store.lastError
        )
    }

    private static func messageBody(prefix: String, sequence: Int) -> String {
        "\(prefix)-\(String(format: "%03d", sequence))"
    }

    private static func write(_ report: DeliverySoakReport, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
        if let line = String(data: data, encoding: .utf8) { print("SIDEBAND_SOAK_REPORT \(line)") }
    }
}

private struct DeliverySoakReport: Codable {
    var phase: String
    let networkMode: String
    let networkState: String
    let automaticConnection: String
    let destination: String
    let startedAt: Date
    var completedAt: Date?
    let expectedEachDirection: Int
    let outboundQueued: Int
    let outboundSent: Int
    let outboundDelivered: Int
    let outboundFailed: Int
    let inboundReceived: Int
    let missingOutbound: [String]
    let missingInbound: [String]
    let duplicateInbound: [String]
    let inboundInOrder: Bool
    let knownPath: Bool
    let deliveryTimeouts: Int
    let lastError: String?
}
#endif
