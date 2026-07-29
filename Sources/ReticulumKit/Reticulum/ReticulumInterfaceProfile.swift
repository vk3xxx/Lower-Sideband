import Foundation

/// User-configurable Reticulum interface types supported by the current
/// Reticulum reference implementation and MeshChatX.
public enum ReticulumInterfaceKind: String, Codable, CaseIterable, Sendable {
    case auto
    case tcpClient
    case tcpServer
    case backboneClient
    case backboneServer
    case i2p
    case udp
    case rnode
    case rnodeMulti
    case serial
    case kiss
    case ax25Kiss
    case pipe
    case webSocketClient
    case webSocketServer
    case httpClient
    case httpServer
    case weave

    public var title: String {
        switch self {
        case .auto: "AutoInterface"
        case .tcpClient: "TCP client"
        case .tcpServer: "TCP server"
        case .backboneClient: "Backbone connector"
        case .backboneServer: "Backbone listener"
        case .i2p: "I2P"
        case .udp: "UDP"
        case .rnode: "RNode"
        case .rnodeMulti: "RNode multi-interface"
        case .serial: "Serial"
        case .kiss: "KISS"
        case .ax25Kiss: "AX.25 KISS"
        case .pipe: "Pipe"
        case .webSocketClient: "WebSocket client"
        case .webSocketServer: "WebSocket server"
        case .httpClient: "HTTP tunnel client"
        case .httpServer: "HTTP tunnel server"
        case .weave: "Weave endpoint"
        }
    }

    public var isListener: Bool {
        switch self {
        case .tcpServer, .backboneServer, .udp, .webSocketServer, .httpServer: true
        default: false
        }
    }
}

/// Portable interface configuration shared by macOS and iOS. Fields that do
/// not apply to the selected kind remain nil, keeping persisted profiles
/// forwards-compatible as additional transports are added.
public struct ReticulumInterfaceProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ReticulumInterfaceKind
    public var enabled: Bool
    public var mode: ReticulumInterfaceMode
    public var host: String?
    public var port: UInt16?
    public var url: URL?
    public var device: String?
    public var groupID: String?
    public var ignoredDevices: [String]
    public var connectTimeout: TimeInterval
    public var reconnect: Bool
    public var fixedMTU: Int?
    public var bitrate: Int?
    public var pollInterval: TimeInterval
    public var networkName: String?
    public var passphrase: String?
    public var ifacSize: Int
    public var transportIdentity: String?
    public var samHost: String?
    public var samPort: UInt16?
    public var sessionID: String?
    public var virtualPorts: [RNodeVirtualPortConfiguration]?
    public var listenHost: String?
    public var forwardHost: String?
    public var forwardPort: UInt16?
    public var callsign: String?
    public var ssid: UInt8?
    public var kissPort: UInt8?
    public var flowControl: Bool?
    public var switchID: Data?
    public var localEndpointID: Data?
    public var remoteEndpointID: Data?
    public var pipeArguments: [String]?
    public var pipeEnvironment: [String: String]?
    public var maximumClients: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ReticulumInterfaceKind,
        enabled: Bool = true,
        mode: ReticulumInterfaceMode = .full,
        host: String? = nil,
        port: UInt16? = nil,
        url: URL? = nil,
        device: String? = nil,
        groupID: String? = nil,
        ignoredDevices: [String] = [],
        connectTimeout: TimeInterval = 5,
        reconnect: Bool = true,
        fixedMTU: Int? = nil,
        bitrate: Int? = nil,
        pollInterval: TimeInterval = 0.1,
        networkName: String? = nil,
        passphrase: String? = nil,
        ifacSize: Int = 16,
        transportIdentity: String? = nil,
        samHost: String? = nil,
        samPort: UInt16? = nil,
        sessionID: String? = nil,
        virtualPorts: [RNodeVirtualPortConfiguration]? = nil,
        listenHost: String? = nil,
        forwardHost: String? = nil,
        forwardPort: UInt16? = nil,
        callsign: String? = nil,
        ssid: UInt8? = nil,
        kissPort: UInt8? = nil,
        flowControl: Bool? = nil,
        switchID: Data? = nil,
        localEndpointID: Data? = nil,
        remoteEndpointID: Data? = nil,
        pipeArguments: [String]? = nil,
        pipeEnvironment: [String: String]? = nil,
        maximumClients: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.mode = mode
        self.host = host
        self.port = port
        self.url = url
        self.device = device
        self.groupID = groupID
        self.ignoredDevices = ignoredDevices
        self.connectTimeout = connectTimeout
        self.reconnect = reconnect
        self.fixedMTU = fixedMTU
        self.bitrate = bitrate
        self.pollInterval = pollInterval
        self.networkName = networkName
        self.passphrase = passphrase
        self.ifacSize = ifacSize
        self.transportIdentity = transportIdentity
        self.samHost = samHost
        self.samPort = samPort
        self.sessionID = sessionID
        self.virtualPorts = virtualPorts
        self.listenHost = listenHost
        self.forwardHost = forwardHost
        self.forwardPort = forwardPort
        self.callsign = callsign
        self.ssid = ssid
        self.kissPort = kissPort
        self.flowControl = flowControl
        self.switchID = switchID
        self.localEndpointID = localEndpointID
        self.remoteEndpointID = remoteEndpointID
        self.pipeArguments = pipeArguments
        self.pipeEnvironment = pipeEnvironment
        self.maximumClients = maximumClients
    }

    public func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingName
        }
        guard connectTimeout > 0, connectTimeout <= 300 else {
            throw ValidationError.invalidConnectTimeout
        }
        guard pollInterval >= 0.05, pollInterval <= 60 else {
            throw ValidationError.invalidPollInterval
        }
        if let fixedMTU, !(256...262_144).contains(fixedMTU) {
            throw ValidationError.invalidMTU
        }
        if networkName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            passphrase?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            guard (1...64).contains(ifacSize) else { throw ValidationError.invalidIFACSize }
        }

        switch kind {
        case .tcpClient:
            try requireHostAndPort()
        case .backboneClient:
            try requireHostAndPort()
            if let transportIdentity, !transportIdentity.isEmpty {
                _ = try ReticulumBackboneTransportIdentity(hex: transportIdentity)
            }
        case .tcpServer, .backboneServer:
            guard let port, port > 0 else { throw ValidationError.missingPort }
            if kind == .tcpServer, let maximumClients, !(1...256).contains(maximumClients) {
                throw ValidationError.invalidMaximumClients
            }
        case .udp:
            guard let port, port > 0 else { throw ValidationError.missingPort }
            _ = try ReticulumUDPListenerConfiguration(
                listenHost: listenHost ?? "0.0.0.0",
                listenPort: port,
                forwardHost: forwardHost,
                forwardPort: forwardPort,
                allowBroadcast: forwardHost == "255.255.255.255"
            ).validated()
        case .webSocketClient:
            try requireURL(schemes: ["ws", "wss"])
        case .httpClient:
            try requireURL(schemes: ["http", "https"])
        case .webSocketServer, .httpServer:
            guard let port, port > 0 else { throw ValidationError.missingPort }
        case .serial, .kiss, .ax25Kiss:
            guard device?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ValidationError.missingDevice
            }
            var configuration = KISSModemConfiguration()
            configuration.name = name
            configuration.serialPath = device!
            configuration.baudRate = bitrate ?? 115_200
            configuration.port = kissPort ?? 0
            configuration.framing = kind == .serial ? .hdlc : (kind == .ax25Kiss ? .ax25Kiss : .kiss)
            configuration.callsign = callsign ?? ""
            configuration.ssid = ssid ?? 0
            configuration.flowControl = flowControl ?? false
            _ = try configuration.validated()
        case .i2p:
            guard host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw ValidationError.missingHost
            }
            _ = try ReticulumI2PConfiguration(
                samHost: samHost ?? "127.0.0.1",
                samPort: samPort ?? 7_656,
                sessionID: sessionID ?? "lower-sideband",
                role: .connect(destination: host!)
            ).validated()
        case .rnodeMulti:
            guard let virtualPorts, !virtualPorts.isEmpty else {
                throw ValidationError.missingVirtualPorts
            }
            _ = try RNodeMultiConfiguration(
                name: name,
                transport: .serial,
                target: device ?? "configured",
                ports: virtualPorts
            ).validated()
        case .weave:
            _ = try ReticulumWeaveConfiguration(
                host: host ?? "",
                port: port ?? 0,
                switchID: switchID ?? Data(),
                localEndpointID: localEndpointID ?? Data(),
                remoteEndpointID: remoteEndpointID,
                reconnect: reconnect
            ).validated()
        case .pipe:
            guard let executable = device?.trimmingCharacters(in: .whitespacesAndNewlines),
                  executable.hasPrefix("/") else {
                throw ValidationError.invalidPipeExecutable
            }
            let arguments = pipeArguments ?? []
            guard arguments.count <= 64,
                  arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4_096 }) else {
                throw ValidationError.invalidPipeArguments
            }
            let environment = pipeEnvironment ?? [:]
            guard environment.count <= 64,
                  environment.allSatisfy({
                      !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") &&
                      !$0.value.contains("\0") &&
                      $0.key.utf8.count <= 256 && $0.value.utf8.count <= 4_096
                  }) else {
                throw ValidationError.invalidPipeEnvironment
            }
        case .auto, .rnode:
            break
        }
        return self
    }

    public func makeIFAC() throws -> ReticulumIFAC? {
        let hasName = networkName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasPassphrase = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasName || hasPassphrase else { return nil }
        return try ReticulumIFAC(networkName: networkName, passphrase: passphrase, size: ifacSize)
    }

    private func requireHostAndPort() throws {
        guard host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ValidationError.missingHost
        }
        guard let port, port > 0 else { throw ValidationError.missingPort }
    }

    private func requireURL(schemes: Set<String>) throws {
        guard let url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme), url.host != nil else {
            throw ValidationError.invalidURL
        }
    }

    public enum ValidationError: LocalizedError, Equatable {
        case missingName
        case missingHost
        case missingPort
        case missingDevice
        case invalidURL
        case invalidConnectTimeout
        case invalidPollInterval
        case invalidMTU
        case invalidIFACSize
        case missingVirtualPorts
        case invalidPipeExecutable
        case invalidPipeArguments
        case invalidPipeEnvironment
        case invalidMaximumClients

        public var errorDescription: String? {
            switch self {
            case .missingName: "Enter an interface name."
            case .missingHost: "Enter a host or destination."
            case .missingPort: "Enter a valid port."
            case .missingDevice: "Select a device."
            case .invalidURL: "Enter a valid transport URL."
            case .invalidConnectTimeout: "Connection timeout must be between 0 and 300 seconds."
            case .invalidPollInterval: "Polling interval must be between 0.05 and 60 seconds."
            case .invalidMTU: "MTU must be between 256 and 262,144 bytes."
            case .invalidIFACSize: "IFAC size must be between 1 and 64 bytes."
            case .missingVirtualPorts: "Configure at least one RNode virtual port."
            case .invalidPipeExecutable: "Choose an executable using its absolute path."
            case .invalidPipeArguments: "Pipe arguments are invalid or exceed the safe limit."
            case .invalidPipeEnvironment: "Pipe environment entries are invalid or exceed the safe limit."
            case .invalidMaximumClients: "Maximum clients must be between 1 and 256."
            }
        }
    }
}

public enum ReticulumInterfaceField: String, CaseIterable, Sendable {
    case name, enabled, mode, host, port, url, device, groupID, timeout, reconnect
    case mtu, bitrate, polling, ifac, transportIdentity, sam, virtualPorts
    case listenHost, forwardHost, forwardPort, callsign, ssid, kissPort, flowControl
    case switchID, localEndpointID, remoteEndpointID
    case pipeArguments, pipeEnvironment
    case maximumClients
}

public extension ReticulumInterfaceKind {
    var applicableFields: Set<ReticulumInterfaceField> {
        var fields: Set<ReticulumInterfaceField> = [.name, .enabled, .mode, .ifac]
        switch self {
        case .auto: fields.formUnion([.groupID])
        case .tcpClient: fields.formUnion([.host, .port, .timeout, .reconnect, .mtu])
        case .tcpServer: fields.formUnion([.listenHost, .port, .mtu, .maximumClients])
        case .backboneClient: fields.formUnion([.host, .port, .timeout, .reconnect, .transportIdentity])
        case .backboneServer: fields.formUnion([.listenHost, .port, .transportIdentity])
        case .i2p: fields.formUnion([.host, .sam, .timeout, .reconnect])
        case .udp: fields.formUnion([.listenHost, .port, .forwardHost, .forwardPort, .mtu])
        case .rnode: fields.formUnion([.device, .bitrate])
        case .rnodeMulti: fields.formUnion([.device, .virtualPorts])
        case .serial: fields.formUnion([.device, .bitrate])
        case .kiss: fields.formUnion([.device, .bitrate, .kissPort, .flowControl])
        case .ax25Kiss: fields.formUnion([.device, .bitrate, .kissPort, .flowControl, .callsign, .ssid])
        case .pipe: fields.formUnion([.device, .reconnect, .pipeArguments, .pipeEnvironment])
        case .webSocketClient, .httpClient: fields.formUnion([.url, .timeout, .reconnect, .mtu, .polling])
        case .webSocketServer, .httpServer: fields.formUnion([.listenHost, .port, .mtu, .polling])
        case .weave: fields.formUnion([.host, .port, .switchID, .localEndpointID, .remoteEndpointID, .reconnect])
        }
        return fields
    }
}

/// Detects listener conflicts before Network.framework returns an opaque
/// address-in-use error.
public enum ReticulumInterfacePreflight {
    public struct Listener: Hashable, Sendable {
        public let transport: String
        public let port: UInt16

        public init(transport: String, port: UInt16) {
            self.transport = transport.lowercased()
            self.port = port
        }
    }

    public static func conflictingProfileIDs(in profiles: [ReticulumInterfaceProfile]) -> Set<UUID> {
        var owners: [Listener: UUID] = [:]
        var conflicts: Set<UUID> = []
        for profile in profiles where profile.enabled && profile.kind.isListener {
            guard let port = profile.port else { continue }
            let transport: String
            switch profile.kind {
            case .tcpServer, .backboneServer, .webSocketServer, .httpServer:
                transport = "tcp"
            default:
                transport = profile.kind.rawValue
            }
            let listener = Listener(transport: transport, port: port)
            if let existing = owners[listener] {
                conflicts.insert(existing)
                conflicts.insert(profile.id)
            } else {
                owners[listener] = profile.id
            }
        }
        return conflicts
    }
}
