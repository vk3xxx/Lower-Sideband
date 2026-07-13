import Foundation
import Network
import Observation

@MainActor @Observable
public final class NetworkReachability {
    public enum Status: String, Sendable { case unknown, available, unavailable }

    public private(set) var status: Status = .unknown
    public private(set) var interfaceSummary = "Checking network…"
    public private(set) var supportsIPv4 = false
    public private(set) var supportsIPv6 = false
    public private(set) var isExpensive = false
    public private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sideband.network.path")
    private var statusHandler: (@MainActor (Status) -> Void)?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.update(path) }
        }
        monitor.start(queue: queue)
    }

    public func setStatusHandler(_ handler: @escaping @MainActor (Status) -> Void) {
        statusHandler = handler
    }

    private func update(_ path: NWPath) {
        let previousStatus = status
        status = path.status == .satisfied ? .available : .unavailable
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        let kinds: [(NWInterface.InterfaceType, String)] = [(.wifi, "Wi-Fi"), (.wiredEthernet, "Ethernet"), (.cellular, "Cellular"), (.loopback, "Loopback"), (.other, "Other")]
        let active = kinds.compactMap { path.usesInterfaceType($0.0) ? $0.1 : nil }
        interfaceSummary = active.isEmpty ? (status == .available ? "Network available" : "No network") : active.joined(separator: ", ")
        if status != previousStatus { statusHandler?(status) }
    }
}
