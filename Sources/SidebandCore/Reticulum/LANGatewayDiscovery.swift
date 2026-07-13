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
