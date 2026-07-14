import Foundation
import Network
import Observation

public struct LANGateway: Identifiable, Hashable, @unchecked Sendable {
    public var id: String { "\(name)|\(type)|\(domain)" }
    public let name: String
    public let type: String
    public let domain: String
    public let endpoint: NWEndpoint
}

@MainActor @Observable
public final class LANGatewayDiscovery {
    public private(set) var gateways: [LANGateway] = []
    public private(set) var isSearching = false
    public private(set) var error: String?
    private var browsers: [NWBrowser] = []
    private var resultsByServiceType: [String: [String: LANGateway]] = [:]
    private var updateHandler: (@MainActor ([LANGateway]) -> Void)?
    private let serviceTypes = ["_reticulum._tcp", "_rns._tcp", "_sideband._tcp"]

    public init() {}

    public func setUpdateHandler(_ handler: @escaping @MainActor ([LANGateway]) -> Void) {
        updateHandler = handler
    }

    public func start() {
        guard browsers.isEmpty else { return }
        gateways.removeAll()
        error = nil
        isSearching = true
        for type in serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed(let failure) = state {
                    Task { @MainActor in self?.error = failure.localizedDescription }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.merge(results, serviceType: type) }
            }
            browsers.append(browser)
            browser.start(queue: DispatchQueue(label: "sideband.lan-discovery.\(type)"))
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resultsByServiceType.removeAll()
        gateways.removeAll()
        isSearching = false
    }

    private func merge(_ results: Set<NWBrowser.Result>, serviceType: String) {
        resultsByServiceType[serviceType] = Dictionary(uniqueKeysWithValues: results.compactMap { result in
            guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
            let gateway = LANGateway(name: name, type: type, domain: domain, endpoint: result.endpoint)
            return (gateway.id, gateway)
        })
        gateways = resultsByServiceType.values
            .flatMap(\.values)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
            }
        updateHandler?(gateways)
    }
}

public enum AutomaticGatewaySelector {
    public static func ordered(_ gateways: [LANGateway], preferredID: String?, excluding attemptedIDs: Set<String> = []) -> [LANGateway] {
        gateways
            .filter { !attemptedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsPreferred = lhs.id == preferredID
                let rhsPreferred = rhs.id == preferredID
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                let lhsType = servicePriority(lhs.type)
                let rhsType = servicePriority(rhs.type)
                if lhsType != rhsType { return lhsType < rhsType }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func servicePriority(_ type: String) -> Int {
        switch type {
        case "_reticulum._tcp.", "_reticulum._tcp": 0
        case "_rns._tcp.", "_rns._tcp": 1
        case "_sideband._tcp.", "_sideband._tcp": 2
        default: 3
        }
    }
}

public enum AutomaticGatewayFailoverPolicy {
    public static func shouldPreferDiscoveredLAN(activeInternetGatewayID: String?, discoveredGatewayCount: Int) -> Bool {
        activeInternetGatewayID != nil && discoveredGatewayCount > 0
    }

    public static func shouldRotateInternetGateway(activeInternetGatewayID: String?, hasPath: Bool, hasQueuedMessages: Bool) -> Bool {
        activeInternetGatewayID != nil && !hasPath && hasQueuedMessages
    }
}

public struct InternetGateway: Identifiable, Hashable, Sendable {
    public var id: String { "\(host.lowercased()):\(port)" }
    public let name: String
    public let host: String
    public let port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

public enum ConfiguredReticulumGateways {
    public static func ordered(
        ipv4Host: String,
        ipv6Host: String,
        port: Int,
        preferIPv6: Bool,
        supportsIPv6: Bool,
        excluding attemptedIDs: Set<String> = []
    ) -> [InternetGateway] {
        guard let port = UInt16(exactly: port), port > 0 else { return [] }
        let ipv4 = ipv4Host.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipv6 = ipv6Host.trimmingCharacters(in: .whitespacesAndNewlines)
        var gateways: [InternetGateway] = []
        if preferIPv6, supportsIPv6, !ipv6.isEmpty {
            gateways.append(InternetGateway(name: "Configured IPv6 gateway", host: ipv6, port: port))
        }
        if !ipv4.isEmpty {
            gateways.append(InternetGateway(name: "Configured gateway", host: ipv4, port: port))
        }
        if (!preferIPv6 || !supportsIPv6), !ipv6.isEmpty {
            gateways.append(InternetGateway(name: "Configured IPv6 gateway", host: ipv6, port: port))
        }
        var seen: Set<String> = []
        return gateways.filter { seen.insert($0.id).inserted && !attemptedIDs.contains($0.id) }
    }
}

public enum PublicReticulumGateways {
    public static let defaults: [InternetGateway] = [
        InternetGateway(name: "Sydney RNS", host: "sydney.reticulum.au", port: 4_242),
        InternetGateway(name: "Melbourne RNS", host: "mel.reticulum.net.nz", port: 4_242),
        InternetGateway(name: "Dismail RNS", host: "rns.dismail.de", port: 7_822),
        InternetGateway(name: "MobileFabrik", host: "phantom.mobilefabrik.com", port: 4_242)
    ]

    public static func ordered(customHost: String?, customPort: Int, preferredID: String?, excluding attemptedIDs: Set<String> = []) -> [InternetGateway] {
        var gateways: [InternetGateway] = []
        let normalizedHost = customHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedHost.isEmpty, let port = UInt16(exactly: customPort), port > 0 {
            gateways.append(InternetGateway(name: "Configured internet gateway", host: normalizedHost, port: port))
        }
        gateways.append(contentsOf: defaults)
        var seen: Set<String> = []
        let unique = gateways.filter { seen.insert($0.id).inserted && !attemptedIDs.contains($0.id) }
        return unique.sorted { lhs, rhs in
            let lhsPreferred = lhs.id == preferredID
            let rhsPreferred = rhs.id == preferredID
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return gateways.firstIndex(of: lhs)! < gateways.firstIndex(of: rhs)!
        }
    }
}
