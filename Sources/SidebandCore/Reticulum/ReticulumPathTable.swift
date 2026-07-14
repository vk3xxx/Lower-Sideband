import Foundation

public struct ReticulumPath: Codable, Equatable, Sendable {
    public let destinationHash: Data
    public var nextHop: Data?
    public var hops: UInt8
    public var updatedAt: Date
    public var expiresAt: Date
    public var publicKey: Data
    public var appData: Data
    public var ratchet: Data?
    /// The concrete TCP reticule that supplied this route. Older persisted
    /// paths decode as nil and remain usable by single-interface clients.
    public var interfaceID: String?

    public var isExpired: Bool { expiresAt <= .now }
}

public actor ReticulumPathTable {
    public static let defaultLifetime: TimeInterval = 60 * 60 * 24 * 7
    private var paths: [Data: [String: ReticulumPath]] = [:]
    private var pendingRequests: [Data: Date] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = defaultLifetime) { self.lifetime = lifetime }

    @discardableResult
    public func ingest(_ announce: ReticulumAnnounce, packet: ReticulumPacket, interfaceID: String? = nil, now: Date = .now) -> Bool {
        guard announce.validate() else { return false }
        let wasRequested = pendingRequests[announce.destinationHash] != nil
        let candidate = ReticulumPath(
            destinationHash: announce.destinationHash,
            nextHop: packet.transportID,
            hops: packet.hops,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(lifetime),
            publicKey: announce.publicKey,
            appData: announce.appData,
            ratchet: announce.ratchet,
            interfaceID: interfaceID
        )
        let routeKey = interfaceID ?? ""
        if let existing = paths[announce.destinationHash]?[routeKey], !existing.isExpired, existing.hops < candidate.hops, !wasRequested {
            return false
        }
        paths[announce.destinationHash, default: [:]][routeKey] = candidate
        pendingRequests.removeValue(forKey: announce.destinationHash)
        return true
    }

    public func path(to destinationHash: Data, now: Date = .now) -> ReticulumPath? {
        guard var routes = paths[destinationHash] else { return nil }
        routes = routes.filter { $0.value.expiresAt > now }
        if routes.isEmpty { paths.removeValue(forKey: destinationHash); return nil }
        paths[destinationHash] = routes
        return routes.values.sorted {
            if $0.hops != $1.hops { return $0.hops < $1.hops }
            return $0.updatedAt > $1.updatedAt
        }.first
    }

    public func path(to destinationHash: Data, on interfaceID: String, now: Date = .now) -> ReticulumPath? {
        guard let path = paths[destinationHash]?[interfaceID], path.expiresAt > now else { return nil }
        return path
    }

    public func all(now: Date = .now) -> [ReticulumPath] {
        prune(now: now)
        return paths.values.flatMap(\.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func markRequested(_ destinationHash: Data, now: Date = .now) { pendingRequests[destinationHash] = now }
    public func invalidate(_ destinationHash: Data) {
        paths.removeValue(forKey: destinationHash)
        pendingRequests.removeValue(forKey: destinationHash)
    }
    public func isPending(_ destinationHash: Data, timeout: TimeInterval = 15, now: Date = .now) -> Bool {
        guard let requested = pendingRequests[destinationHash] else { return false }
        if now.timeIntervalSince(requested) >= timeout { pendingRequests.removeValue(forKey: destinationHash); return false }
        return true
    }

    public func prune(now: Date = .now) {
        paths = paths.compactMapValues { routes in
            let active = routes.filter { $0.value.expiresAt > now }
            return active.isEmpty ? nil : active
        }
        pendingRequests = pendingRequests.filter { now.timeIntervalSince($0.value) < 15 }
    }
}
