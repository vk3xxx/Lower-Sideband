import Foundation
import Network
import Observation
import Darwin

/// Reticulum AutoInterface discovery constants and authenticated peer beacons.
public enum AutoInterfaceProtocol {
    public static let groupID = Data("reticulum".utf8)
    public static let discoveryPort: UInt16 = 29_716
    public static let unicastDiscoveryPort: UInt16 = 29_717
    public static let dataPort: UInt16 = 42_671
    public static let announceInterval: TimeInterval = 1.6
    public static let peerTimeout: TimeInterval = 22

    /// Default Reticulum temporary, link-scoped IPv6 multicast group.
    public static let multicastAddress: String = {
        let hash = ReticulumIdentity.fullHash(groupID)
        let words = stride(from: 2, through: 12, by: 2).map { index -> String in
            String(format: "%x", UInt16(hash[index]) << 8 | UInt16(hash[index + 1]))
        }
        return "ff12:0:" + words.joined(separator: ":")
    }()

    public static func discoveryToken(forIPv6Address address: String) -> Data {
        ReticulumIdentity.fullHash(groupID + Data(normalize(address).utf8))
    }

    public static func validate(token: Data, sourceIPv6Address address: String) -> Bool {
        token == discoveryToken(forIPv6Address: address)
    }

    public static func normalize(_ address: String) -> String {
        String(address.split(separator: "%", maxSplits: 1).first ?? Substring(address)).lowercased()
    }
}

public struct AutoInterfacePeer: Identifiable, Equatable, Sendable {
    public var id: String { address }
    public let address: String
    public var interfaceName: String?
    public var firstSeen: Date
    public var lastSeen: Date
}

public actor AutoInterfacePeerTable {
    private var peers: [String: AutoInterfacePeer] = [:]
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = AutoInterfaceProtocol.peerTimeout) { self.timeout = timeout }

    @discardableResult
    public func receive(token: Data, sourceAddress: String, interfaceName: String? = nil, now: Date = .now) -> Bool {
        let embeddedScope = sourceAddress.split(separator: "%", maxSplits: 1).dropFirst().first.map(String.init)
        let address = AutoInterfaceProtocol.normalize(sourceAddress)
        guard AutoInterfaceProtocol.validate(token: token, sourceIPv6Address: address) else { return false }
        if var peer = peers[address] {
            peer.lastSeen = now
            if interfaceName != nil || embeddedScope != nil { peer.interfaceName = interfaceName ?? embeddedScope }
            peers[address] = peer
        } else {
            peers[address] = AutoInterfacePeer(address: address, interfaceName: interfaceName ?? embeddedScope, firstSeen: now, lastSeen: now)
        }
        return true
    }

    public func activePeers(now: Date = .now) -> [AutoInterfacePeer] {
        peers = peers.filter { now.timeIntervalSince($0.value.lastSeen) <= timeout }
        return peers.values.sorted { $0.address < $1.address }
    }
}

@MainActor @Observable
public final class AutoInterfaceDiscovery {
    public private(set) var peers: [AutoInterfacePeer] = []
    public private(set) var isListening = false
    public private(set) var error: String?
    public private(set) var beaconsSent = 0
    public private(set) var dataPacketsReceived = 0
    public private(set) var dataPacketsSent = 0
    public private(set) var activeInterfaceNames: [String] = []
    private let peerTable = AutoInterfacePeerTable()
    private var group: NWConnectionGroup?
    private var pathMonitor: NWPathMonitor?
    private var networkInterfaces: [NWInterface] = []
    private var beaconTask: Task<Void, Never>?
    private var dataListener: NWListener?
    private var packetHandler: (@Sendable (ReticulumPacket) async -> Void)?

    public init() {}

    public func start() {
        guard group == nil else { return }
        error = nil
        do {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(AutoInterfaceProtocol.multicastAddress), port: NWEndpoint.Port(rawValue: AutoInterfaceProtocol.discoveryPort)!)
            let descriptor = try NWMulticastGroup(for: [endpoint])
            let parameters = NWParameters.udp
            // AutoInterface listeners intentionally share the standard discovery
            // port. This is required when Reticulum or Sideband is already running.
            parameters.allowLocalEndpointReuse = true
            let group = NWConnectionGroup(with: descriptor, using: parameters)
            self.group = group
            group.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isListening = true; self?.error = nil
                    case .failed(let failure): self?.isListening = false; self?.error = failure.localizedDescription
                    case .cancelled: self?.isListening = false
                    default: break
                    }
                }
            }
            group.setReceiveHandler(maximumMessageSize: 1_024, rejectOversizedMessages: true) { [weak self] message, content, _ in
                guard let self, let content, case let .hostPort(host, _) = message.remoteEndpoint else { return }
                let address = String(describing: host)
                Task {
                    let accepted = await self.peerTable.receive(token: content, sourceAddress: address)
                    if accepted { await self.refreshPeers() }
                }
            }
            group.start(queue: DispatchQueue(label: "sideband.reticulum.auto-interface"))
            startDataListener()
            let pathMonitor = NWPathMonitor()
            self.pathMonitor = pathMonitor
            pathMonitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    let addresses = Self.linkLocalIPv6Addresses()
                    var seen = Set<String>()
                    self?.networkInterfaces = path.availableInterfaces.filter {
                        $0.type != .loopback && addresses[$0.name] != nil && seen.insert($0.name).inserted
                    }
                    self?.activeInterfaceNames = self?.networkInterfaces.map(\.name).sorted() ?? []
                }
            }
            pathMonitor.start(queue: DispatchQueue(label: "sideband.reticulum.interfaces"))
            beaconTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sendBeacons()
                    try? await Task.sleep(for: .seconds(AutoInterfaceProtocol.announceInterval))
                }
            }
        } catch {
            self.error = error.localizedDescription
            isListening = false
        }
    }

    public func stop() {
        group?.cancel()
        group = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        beaconTask?.cancel()
        beaconTask = nil
        dataListener?.cancel()
        dataListener = nil
        isListening = false
        error = nil
    }

    private func refreshPeers() async { peers = await peerTable.activePeers() }

    public func setPacketHandler(_ handler: @escaping @Sendable (ReticulumPacket) async -> Void) {
        packetHandler = handler
    }

    public func send(rawPacket: Data, to peer: AutoInterfacePeer) {
        let host = peer.interfaceName.map { "\(peer.address)%\($0)" } ?? peer.address
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: AutoInterfaceProtocol.dataPort)!)
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if let name = peer.interfaceName, let interface = networkInterfaces.first(where: { $0.name == name }) { parameters.requiredInterface = interface }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                connection.send(content: rawPacket, completion: .contentProcessed { error in
                    Task { @MainActor in
                        if let error { self?.error = error.localizedDescription }
                        else { self?.dataPacketsSent += 1 }
                        connection.cancel()
                    }
                })
            case .failed(let failure):
                Task { @MainActor in self?.error = failure.localizedDescription }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "sideband.reticulum.auto-data-send"))
    }

    private func startDataListener() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: AutoInterfaceProtocol.dataPort)!)
            dataListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: DispatchQueue(label: "sideband.reticulum.auto-data-receive"))
                self?.receiveDatagrams(on: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let failure) = state { Task { @MainActor in self?.error = failure.localizedDescription } }
            }
            listener.start(queue: DispatchQueue(label: "sideband.reticulum.auto-data-listener"))
        } catch { self.error = error.localizedDescription }
    }

    private nonisolated func receiveDatagrams(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, let packet = try? ReticulumPacket(raw: content) {
                Task { @MainActor in
                    self.dataPacketsReceived += 1
                    if let packetHandler = self.packetHandler { await packetHandler(packet) }
                }
            }
            if error == nil { self.receiveDatagrams(on: connection) } else { connection.cancel() }
        }
    }

    private func sendBeacons() {
        let addresses = Self.linkLocalIPv6Addresses()
        for interface in networkInterfaces {
            guard let address = addresses[interface.name] else { continue }
            let token = AutoInterfaceProtocol.discoveryToken(forIPv6Address: address)
            let parameters = NWParameters.udp
            parameters.requiredInterface = interface
            parameters.allowLocalEndpointReuse = true
            // Link-local multicast destinations must carry an interface scope.
            let scopedAddress = "\(AutoInterfaceProtocol.multicastAddress)%\(interface.name)"
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(scopedAddress), port: NWEndpoint.Port(rawValue: AutoInterfaceProtocol.discoveryPort)!)
            let connection = NWConnection(to: endpoint, using: parameters)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                switch state {
                case .ready:
                    connection.send(content: token, completion: .contentProcessed { error in
                        Task { @MainActor in
                            if let error { self?.error = error.localizedDescription }
                            else { self?.beaconsSent += 1; self?.error = nil }
                            connection.cancel()
                        }
                    })
                case .failed(let failure):
                    Task { @MainActor in self?.error = failure.localizedDescription }
                    connection.cancel()
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "sideband.reticulum.beacon.\(interface.name)"))
        }
    }

    private static func linkLocalIPv6Addresses() -> [String: String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [:] }
        defer { freeifaddrs(pointer) }
        var output: [String: String] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current?.pointee {
            defer { current = item.ifa_next }
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let terminator = host.firstIndex(of: 0) ?? host.endIndex
            let value = String(decoding: host[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard value.lowercased().hasPrefix("fe80:") else { continue }
            output[String(cString: item.ifa_name)] = AutoInterfaceProtocol.normalize(value)
        }
        return output
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
