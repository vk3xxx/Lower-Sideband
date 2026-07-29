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
        }
    }

    public var isListener: Bool {
        switch self {
        case .tcpServer, .backboneServer, .webSocketServer, .httpServer: true
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
        virtualPorts: [RNodeVirtualPortConfiguration]? = nil
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
        case .tcpServer, .backboneServer, .udp:
            guard let port, port > 0 else { throw ValidationError.missingPort }
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
        case .auto, .rnode, .pipe:
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
            }
        }
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
