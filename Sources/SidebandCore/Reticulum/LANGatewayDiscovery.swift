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
    private let serviceTypes = ["_reticulum._tcp", "_rns._tcp", "_sideband._tcp"]

    public init() {}

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
                Task { @MainActor in self?.merge(results) }
            }
            browsers.append(browser)
            browser.start(queue: DispatchQueue(label: "sideband.lan-discovery.\(type)"))
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        isSearching = false
    }

    private func merge(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let gateway = LANGateway(name: name, type: type, domain: domain, endpoint: result.endpoint)
            if let index = gateways.firstIndex(where: { $0.id == gateway.id }) { gateways[index] = gateway }
            else { gateways.append(gateway) }
        }
        gateways.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
