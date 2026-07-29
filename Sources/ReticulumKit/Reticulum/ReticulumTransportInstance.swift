import Foundation

public struct ReticulumTransportInterfaceDescriptor: Equatable, Sendable {
    public let id: String
    public let mode: ReticulumInterfaceMode
    public init(id: String, mode: ReticulumInterfaceMode = .full) { self.id = id; self.mode = mode }
}

public struct ReticulumTransportForward: Equatable, Sendable {
    public let interfaceID: String
    public let rawPacket: Data
}

public struct ReticulumTransportResult: Equatable, Sendable {
    public let deliverLocally: Bool
    public let forwards: [ReticulumTransportForward]
}

public struct ReticulumTransportSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let knownRoutes: Int
    public let forwardedPackets: Int
    public let duplicatePackets: Int
    public let ignoredPackets: Int
    public let lastForwardedAt: Date?

    public init(
        enabled: Bool,
        knownRoutes: Int,
        forwardedPackets: Int,
        duplicatePackets: Int,
        ignoredPackets: Int,
        lastForwardedAt: Date?
    ) {
        self.enabled = enabled
        self.knownRoutes = knownRoutes
        self.forwardedPackets = forwardedPackets
        self.duplicatePackets = duplicatePackets
        self.ignoredPackets = ignoredPackets
        self.lastForwardedAt = lastForwardedAt
    }
}

/// A compact native Reticulum transport plane for bridging interfaces owned by
/// the macOS app. It preserves packet hashes, validates announces before route
/// learning, suppresses loops and honours the reference interface-mode borders.
public actor ReticulumTransportInstance {
    private struct Route: Sendable {
        var interfaceID: String
        var interfaceMode: ReticulumInterfaceMode
        var nextHop: Data?
        var hops: UInt8
        var expiresAt: Date
    }

    private let identityHash: Data
    private let routeLifetime: TimeInterval
    private let hashLifetime: TimeInterval
    private var enabled: Bool
    private var routes: [Data: Route] = [:]
    private var reverseRoutes: [Data: String] = [:]
    private var linkRoutes: [Data: String] = [:]
    private var seenHashes: [Data: Date] = [:]
    private var forwardedPackets = 0
    private var duplicatePackets = 0
    private var ignoredPackets = 0
    private var lastForwardedAt: Date?

    public init(identityHash: Data, enabled: Bool = false, routeLifetime: TimeInterval = 7 * 86_400, hashLifetime: TimeInterval = 60) {
        precondition(identityHash.count == ReticulumPacket.truncatedHashBytes)
        self.identityHash = identityHash
        self.enabled = enabled
        self.routeLifetime = routeLifetime
        self.hashLifetime = hashLifetime
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { reverseRoutes.removeAll(); linkRoutes.removeAll(); seenHashes.removeAll() }
    }

    public func snapshot(now: Date = .now) -> ReticulumTransportSnapshot {
        prune(now: now)
        return ReticulumTransportSnapshot(enabled: enabled, knownRoutes: routes.count,
                                           forwardedPackets: forwardedPackets, duplicatePackets: duplicatePackets,
                                           ignoredPackets: ignoredPackets, lastForwardedAt: lastForwardedAt)
    }

    public func process(
        _ packet: ReticulumPacket,
        from source: ReticulumTransportInterfaceDescriptor,
        available interfaces: [ReticulumTransportInterfaceDescriptor],
        localDestinations: Set<Data> = [],
        now: Date = .now
    ) -> ReticulumTransportResult {
        guard enabled else { return ReticulumTransportResult(deliverLocally: true, forwards: []) }
        prune(now: now)

        let local = localDestinations.contains(packet.destinationHash)
        if packet.headerType == .transport, packet.packetType != .announce, packet.transportID != identityHash {
            ignoredPackets += 1
            return ReticulumTransportResult(deliverLocally: false, forwards: [])
        }
        if seenHashes[packet.packetHash] != nil, packet.packetType != .announce {
            duplicatePackets += 1
            return ReticulumTransportResult(deliverLocally: local, forwards: [])
        }
        seenHashes[packet.packetHash] = now

        if packet.packetType == .announce,
           let announce = try? ReticulumAnnounce(packet: packet), announce.validate() {
            let receivedHops = packet.hops == .max ? UInt8.max : packet.hops + 1
            if routes[announce.destinationHash].map({ $0.hops >= receivedHops || $0.expiresAt <= now }) ?? true {
                routes[announce.destinationHash] = Route(
                    interfaceID: source.id, interfaceMode: source.mode, nextHop: packet.transportID,
                    hops: receivedHops, expiresAt: now.addingTimeInterval(routeLifetime)
                )
            }
            let outgoing = interfaces.filter { modeAllowsAnnounce(from: source, to: $0) }.compactMap { interface -> ReticulumTransportForward? in
                guard let raw = rewrite(packet, hops: receivedHops, nextHop: identityHash, stripTransport: false) else { return nil }
                return ReticulumTransportForward(interfaceID: interface.id, rawPacket: raw)
            }
            recordForward(outgoing.count, now: now)
            return ReticulumTransportResult(deliverLocally: true, forwards: outgoing)
        }

        if packet.destinationType == .plain || packet.destinationType == .group {
            guard packet.hops <= 1 else { ignoredPackets += 1; return ReticulumTransportResult(deliverLocally: true, forwards: []) }
            let outgoing = interfaces.filter { $0.id != source.id }.compactMap { interface -> ReticulumTransportForward? in
                guard let raw = rewrite(packet, hops: increment(packet.hops), nextHop: nil, stripTransport: true) else { return nil }
                return ReticulumTransportForward(interfaceID: interface.id, rawPacket: raw)
            }
            recordForward(outgoing.count, now: now)
            return ReticulumTransportResult(deliverLocally: true, forwards: outgoing)
        }

        if packet.packetType == .linkRequest {
            linkRoutes[Data(packet.packetHash.prefix(ReticulumPacket.truncatedHashBytes))] = source.id
        }
        reverseRoutes[Data(packet.packetHash.prefix(ReticulumPacket.truncatedHashBytes))] = source.id

        let destinationInterface = linkRoutes[packet.destinationHash]
            ?? reverseRoutes[packet.destinationHash]
            ?? routes[packet.destinationHash]?.interfaceID
        guard !local, let destinationInterface, destinationInterface != source.id,
              interfaces.contains(where: { $0.id == destinationInterface }) else {
            return ReticulumTransportResult(deliverLocally: local, forwards: [])
        }

        let route = routes[packet.destinationHash]
        let nextHop = route?.nextHop
        let strip = route?.hops ?? 1 <= 1 || nextHop == nil
        guard let raw = rewrite(packet, hops: increment(packet.hops), nextHop: nextHop, stripTransport: strip) else {
            ignoredPackets += 1
            return ReticulumTransportResult(deliverLocally: local, forwards: [])
        }
        let outgoing = [ReticulumTransportForward(interfaceID: destinationInterface, rawPacket: raw)]
        recordForward(1, now: now)
        return ReticulumTransportResult(deliverLocally: local, forwards: outgoing)
    }

    private func rewrite(_ packet: ReticulumPacket, hops: UInt8, nextHop: Data?, stripTransport: Bool) -> Data? {
        var result = Data()
        let lowFlags = packet.raw[0] & 0x2F
        if !stripTransport, let nextHop, nextHop.count == ReticulumPacket.truncatedHashBytes {
            result.append(lowFlags | 0x50)
            result.append(hops)
            result.append(nextHop)
            if packet.headerType == .transport { result.append(packet.raw.dropFirst(18)) }
            else { result.append(packet.raw.dropFirst(2)) }
        } else {
            result.append(lowFlags)
            result.append(hops)
            if packet.headerType == .transport { result.append(packet.raw.dropFirst(18)) }
            else { result.append(packet.raw.dropFirst(2)) }
        }
        return (try? ReticulumPacket(raw: result)) == nil ? nil : result
    }

    private func modeAllowsAnnounce(from source: ReticulumTransportInterfaceDescriptor, to destination: ReticulumTransportInterfaceDescriptor) -> Bool {
        guard source.id != destination.id else { return false }
        if destination.mode == .accessPoint { return false }
        if source.mode == .internalMode && destination.mode == .boundary { return false }
        if destination.mode == .internalMode && source.mode == .boundary { return false }
        if destination.mode == .roaming && (source.mode == .roaming || source.mode == .boundary) { return false }
        if destination.mode == .boundary && source.mode == .roaming { return false }
        return true
    }

    private func recordForward(_ count: Int, now: Date) {
        guard count > 0 else { return }
        forwardedPackets += count
        lastForwardedAt = now
    }

    private func increment(_ hops: UInt8) -> UInt8 { hops == .max ? .max : hops + 1 }
    private func prune(now: Date) {
        routes = routes.filter { $0.value.expiresAt > now }
        seenHashes = seenHashes.filter { now.timeIntervalSince($0.value) <= hashLifetime }
        if reverseRoutes.count > 4_096 { reverseRoutes.removeAll(keepingCapacity: true) }
        if linkRoutes.count > 1_024 { linkRoutes.removeAll(keepingCapacity: true) }
    }
}
