import Foundation

/// A platform-neutral representation of the Reticulum topology visible to this
/// node. The graph deliberately describes observed paths, not geographic
/// proximity or an authoritative global topology.
public struct NetworkMapSnapshot: Equatable, Sendable {
    public var nodes: [NetworkMapNode]
    public var edges: [NetworkMapEdge]
    public var generatedAt: Date

    public init(nodes: [NetworkMapNode], edges: [NetworkMapEdge], generatedAt: Date = .now) {
        self.nodes = nodes
        self.edges = edges
        self.generatedAt = generatedAt
    }

    public static let empty = NetworkMapSnapshot(nodes: [], edges: [])
    public var onlineInterfaceCount: Int {
        nodes.count { $0.kind == .interface && $0.status == .online }
    }
    public var offlineInterfaceCount: Int {
        nodes.count { $0.kind == .interface && $0.status != .online }
    }
}

public struct NetworkMapNode: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case local
        case interface
        case transport
        case destination
        case propagationNode
    }

    public enum Status: String, Sendable {
        case online
        case connecting
        case stale
        case offline
    }

    public let id: String
    public var kind: Kind
    public var label: String
    public var detail: String
    public var destinationHash: String?
    public var status: Status
    public var hops: UInt8?
    public var lastSeen: Date?
    public var packetCount: Int
    public var isValidated: Bool

    public init(
        id: String,
        kind: Kind,
        label: String,
        detail: String = "",
        destinationHash: String? = nil,
        status: Status = .online,
        hops: UInt8? = nil,
        lastSeen: Date? = nil,
        packetCount: Int = 0,
        isValidated: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.destinationHash = destinationHash
        self.status = status
        self.hops = hops
        self.lastSeen = lastSeen
        self.packetCount = packetCount
        self.isValidated = isValidated
    }
}

public struct NetworkMapEdge: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case interface
        case direct
        case multiHop
    }

    public var id: String { "\(sourceID)|\(targetID)|\(kind.rawValue)" }
    public let sourceID: String
    public let targetID: String
    public let kind: Kind
    public let hops: UInt8
    public let lastSeen: Date?

    public init(sourceID: String, targetID: String, kind: Kind, hops: UInt8 = 0, lastSeen: Date? = nil) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.hops = hops
        self.lastSeen = lastSeen
    }
}

public struct NetworkMapInterface: Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let status: NetworkMapNode.Status
    public let lastSeen: Date?

    public init(id: String, name: String, detail: String, status: NetworkMapNode.Status, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.status = status
        self.lastSeen = lastSeen
    }
}

public struct NetworkMapRoute: Equatable, Sendable {
    public let destinationHash: String
    public let interfaceID: String?
    public let nextHopHash: String?
    public let hops: UInt8
    public let updatedAt: Date

    public init(destinationHash: String, interfaceID: String?, nextHopHash: String?, hops: UInt8, updatedAt: Date) {
        self.destinationHash = destinationHash.lowercased()
        self.interfaceID = interfaceID
        self.nextHopHash = nextHopHash?.lowercased()
        self.hops = hops
        self.updatedAt = updatedAt
    }
}

public enum NetworkMapBuilder {
    public static func build(
        localHash: String,
        localName: String,
        interfaces: [NetworkMapInterface],
        routes: [NetworkMapRoute],
        discoveries: [DiscoveredDestination],
        conversations: [Conversation],
        propagationNodeHash: String?,
        generatedAt: Date = .now
    ) -> NetworkMapSnapshot {
        let localID = "local:\(localHash)"
        var nodes: [String: NetworkMapNode] = [
            localID: NetworkMapNode(
                id: localID, kind: .local, label: localName, detail: localHash,
                destinationHash: localHash, status: .online, hops: 0, lastSeen: generatedAt,
                isValidated: true
            )
        ]
        var edges = Set<NetworkMapEdge>()
        let interfaceByID = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.id, $0) })

        for interface in interfaces {
            let nodeID = "interface:\(interface.id)"
            nodes[nodeID] = NetworkMapNode(
                id: nodeID, kind: .interface, label: interface.name, detail: interface.detail,
                status: interface.status, lastSeen: interface.lastSeen
            )
            edges.insert(.init(sourceID: localID, targetID: nodeID, kind: .interface, lastSeen: interface.lastSeen))
        }

        let discoveriesByHash = discoveries.reduce(into: [String: DiscoveredDestination]()) { values, discovery in
            let hash = discovery.destinationHash.lowercased()
            if values[hash].map({ $0.lastSeen < discovery.lastSeen }) ?? true { values[hash] = discovery }
        }
        let conversationsByHash = conversations.reduce(into: [String: Conversation]()) { values, conversation in
            values[conversation.destinationHash.lowercased()] = conversation
        }
        let normalizedPropagation = propagationNodeHash?.lowercased()

        for route in routes.sorted(by: routePreference) {
            let hash = route.destinationHash
            guard hash != localHash.lowercased() else { continue }
            let discovery = discoveriesByHash[hash]
            let conversation = conversationsByHash[hash]
            let destinationID = "destination:\(hash)"
            let label = conversation?.displayName
                ?? discovery?.announcedDisplayName
                ?? String(hash.prefix(12))
            let kind: NetworkMapNode.Kind = hash == normalizedPropagation ? .propagationNode : .destination
            let status: NetworkMapNode.Status = generatedAt.timeIntervalSince(route.updatedAt) > 86_400 ? .stale : .online
            if let existing = nodes[destinationID] {
                if route.hops < (existing.hops ?? .max) {
                    nodes[destinationID]?.hops = route.hops
                    nodes[destinationID]?.detail = routeDetail(route, interfaceByID: interfaceByID)
                }
            } else {
                nodes[destinationID] = NetworkMapNode(
                    id: destinationID, kind: kind, label: label,
                    detail: routeDetail(route, interfaceByID: interfaceByID),
                    destinationHash: hash, status: status, hops: route.hops,
                    lastSeen: max(route.updatedAt, discovery?.lastSeen ?? .distantPast),
                    packetCount: discovery?.packetCount ?? 0,
                    isValidated: discovery?.isValidated ?? false
                )
            }

            let interfaceID: String
            if let routeInterfaceID = route.interfaceID {
                interfaceID = "interface:\(routeInterfaceID)"
                if nodes[interfaceID] == nil {
                    nodes[interfaceID] = NetworkMapNode(
                        id: interfaceID,
                        kind: .interface,
                        label: "Previously observed interface",
                        detail: routeInterfaceID,
                        status: .stale,
                        lastSeen: route.updatedAt
                    )
                    edges.insert(.init(
                        sourceID: localID,
                        targetID: interfaceID,
                        kind: .interface,
                        lastSeen: route.updatedAt
                    ))
                }
            } else {
                interfaceID = localID
            }
            if route.hops > 1, let nextHop = route.nextHopHash, nextHop != hash {
                let transportID = "transport:\(nextHop)"
                if nodes[transportID] == nil {
                    nodes[transportID] = NetworkMapNode(
                        id: transportID, kind: .transport, label: String(nextHop.prefix(12)),
                        detail: "Reticulum transport · \(route.hops) hops to destination",
                        destinationHash: nextHop, status: status, hops: max(1, route.hops - 1),
                        lastSeen: route.updatedAt, isValidated: true
                    )
                }
                edges.insert(.init(sourceID: interfaceID, targetID: transportID, kind: .multiHop, hops: route.hops, lastSeen: route.updatedAt))
                edges.insert(.init(sourceID: transportID, targetID: destinationID, kind: .multiHop, hops: route.hops, lastSeen: route.updatedAt))
            } else {
                edges.insert(.init(sourceID: interfaceID, targetID: destinationID, kind: .direct, hops: route.hops, lastSeen: route.updatedAt))
            }
        }

        // Keep known contacts and recently observed destinations visible even
        // when they currently have no usable route.
        let knownHashes = Set(discoveriesByHash.keys).union(conversationsByHash.keys)
        for hash in knownHashes where hash != localHash.lowercased() {
            let destinationID = "destination:\(hash)"
            guard nodes[destinationID] == nil else { continue }
            let discovery = discoveriesByHash[hash]
            let conversation = conversationsByHash[hash]
            nodes[destinationID] = NetworkMapNode(
                id: destinationID,
                kind: hash == normalizedPropagation ? .propagationNode : .destination,
                label: conversation?.displayName ?? discovery?.announcedDisplayName ?? String(hash.prefix(12)),
                detail: "No current path",
                destinationHash: hash,
                status: discovery.map { generatedAt.timeIntervalSince($0.lastSeen) > 86_400 ? .offline : .stale } ?? .offline,
                hops: discovery?.hops,
                lastSeen: discovery?.lastSeen,
                packetCount: discovery?.packetCount ?? 0,
                isValidated: discovery?.isValidated ?? false
            )
        }

        return NetworkMapSnapshot(
            nodes: nodes.values.sorted(by: nodeOrder),
            edges: edges.sorted { $0.id < $1.id },
            generatedAt: generatedAt
        )
    }

    private static func routePreference(_ lhs: NetworkMapRoute, _ rhs: NetworkMapRoute) -> Bool {
        if lhs.destinationHash != rhs.destinationHash { return lhs.destinationHash < rhs.destinationHash }
        if lhs.hops != rhs.hops { return lhs.hops < rhs.hops }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func routeDetail(_ route: NetworkMapRoute, interfaceByID: [String: NetworkMapInterface]) -> String {
        let interface = route.interfaceID.flatMap { interfaceByID[$0]?.name } ?? "Unspecified interface"
        return "\(route.hops) hop\(route.hops == 1 ? "" : "s") · \(interface)"
    }

    private static func nodeOrder(_ lhs: NetworkMapNode, _ rhs: NetworkMapNode) -> Bool {
        let order: [NetworkMapNode.Kind: Int] = [.local: 0, .interface: 1, .transport: 2, .propagationNode: 3, .destination: 4]
        let left = order[lhs.kind, default: 9], right = order[rhs.kind, default: 9]
        if left != right { return left < right }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}

public struct NetworkMapFilter: Equatable, Sendable {
    public var query: String
    public var maximumHops: UInt8?
    public var showOffline: Bool

    public init(query: String = "", maximumHops: UInt8? = 4, showOffline: Bool = true) {
        self.query = query
        self.maximumHops = maximumHops
        self.showOffline = showOffline
    }

    public func apply(to snapshot: NetworkMapSnapshot) -> NetworkMapSnapshot {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var retained = Set(snapshot.nodes.compactMap { node -> String? in
            if !showOffline && node.status == .offline { return nil }
            if let maximumHops, let hops = node.hops, hops > maximumHops { return nil }
            if normalizedQuery.isEmpty {
                return node.id
            } else {
                let haystack = [node.label, node.detail, node.destinationHash ?? ""].joined(separator: " ").lowercased()
                guard haystack.contains(normalizedQuery) else { return nil }
            }
            return node.id
        })

        // Preserve the full path from every matching destination to this node.
        if !normalizedQuery.isEmpty {
            var changed = true
            while changed {
                changed = false
                for edge in snapshot.edges where retained.contains(edge.targetID) && !retained.contains(edge.sourceID) {
                    retained.insert(edge.sourceID)
                    changed = true
                }
            }
        }
        let nodes = snapshot.nodes.filter { retained.contains($0.id) }
        let edges = snapshot.edges.filter { retained.contains($0.sourceID) && retained.contains($0.targetID) }
        return .init(nodes: nodes, edges: edges, generatedAt: snapshot.generatedAt)
    }
}

public struct NetworkMapPosition: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A deterministic, bounded-cost topology layout. Nodes are grouped by their
/// observed parent edge so refreshes do not randomly rearrange the entire map.
public enum NetworkMapLayout {
    public static func positions(for snapshot: NetworkMapSnapshot) -> [String: NetworkMapPosition] {
        guard !snapshot.nodes.isEmpty else { return [:] }
        let local = snapshot.nodes.first(where: { $0.kind == .local })
        var result: [String: NetworkMapPosition] = [:]
        if let local { result[local.id] = .init(x: 0.5, y: 0.5) }

        let interfaces = snapshot.nodes.filter { $0.kind == .interface }
        placeRing(interfaces, radius: 0.17, center: (0.5, 0.5), phase: -.pi / 2, in: &result)

        let parentByTarget = snapshot.edges.reduce(into: [String: String]()) { values, edge in
            values[edge.targetID] = values[edge.targetID] ?? edge.sourceID
        }
        let transports = snapshot.nodes.filter { $0.kind == .transport }
        for (index, transport) in transports.enumerated() {
            let parent = parentByTarget[transport.id].flatMap { result[$0] } ?? .init(x: 0.5, y: 0.5)
            let angle = angleFromCenter(parent) + spread(index: index, count: transports.count, width: 0.55)
            result[transport.id] = polar(center: parent, radius: 0.19, angle: angle)
        }

        let destinations = snapshot.nodes.filter { $0.kind == .destination || $0.kind == .propagationNode }
        let groups = Dictionary(grouping: destinations) { parentByTarget[$0.id] ?? local?.id ?? "" }
        for parentID in groups.keys.sorted() {
            let children = groups[parentID, default: []].sorted { $0.id < $1.id }
            let parent = result[parentID] ?? .init(x: 0.5, y: 0.5)
            let base = angleFromCenter(parent)
            for (index, child) in children.enumerated() {
                let angle: Double
                let radius: Double
                if children.count > 24 {
                    // A deterministic sunflower distribution remains legible
                    // for hundreds of destinations without an O(n²) physics
                    // simulation or collapsing every node onto one arc.
                    let progress = sqrt((Double(index) + 0.5) / Double(children.count))
                    angle = base + Double(index) * .pi * (3 - sqrt(5))
                    radius = progress * (parentID.hasPrefix("transport:") ? 0.25 : 0.38)
                } else {
                    angle = base + spread(
                        index: index,
                        count: children.count,
                        width: min(2.2, 0.18 * Double(max(children.count - 1, 1)))
                    )
                    radius = parentID.hasPrefix("transport:") ? 0.16 : 0.27
                }
                result[child.id] = clamped(polar(center: parent, radius: radius, angle: angle))
            }
        }
        return result
    }

    private static func placeRing(
        _ nodes: [NetworkMapNode],
        radius: Double,
        center: (Double, Double),
        phase: Double,
        in positions: inout [String: NetworkMapPosition]
    ) {
        for (index, node) in nodes.enumerated() {
            let angle = phase + 2 * .pi * Double(index) / Double(max(nodes.count, 1))
            positions[node.id] = polar(center: .init(x: center.0, y: center.1), radius: radius, angle: angle)
        }
    }

    private static func spread(index: Int, count: Int, width: Double) -> Double {
        guard count > 1 else { return 0 }
        return (Double(index) / Double(count - 1) - 0.5) * width
    }

    private static func angleFromCenter(_ point: NetworkMapPosition) -> Double {
        guard point.x != 0.5 || point.y != 0.5 else { return -.pi / 2 }
        return atan2(point.y - 0.5, point.x - 0.5)
    }

    private static func polar(center: NetworkMapPosition, radius: Double, angle: Double) -> NetworkMapPosition {
        .init(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private static func clamped(_ point: NetworkMapPosition) -> NetworkMapPosition {
        .init(x: min(0.95, max(0.05, point.x)), y: min(0.95, max(0.05, point.y)))
    }
}
