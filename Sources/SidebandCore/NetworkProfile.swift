import Foundation

public struct SidebandNetworkProfile: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case builtIn, custom }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var connectionMode: NetworkConnectionMode
    public var autoConnect: Bool
    public var preferIPv6: Bool
    public var internetOnly: Bool
    public var autoInterface: Bool
    public var host: String
    public var ipv6Host: String
    public var port: Int

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind = .custom,
        connectionMode: NetworkConnectionMode,
        autoConnect: Bool = true,
        preferIPv6: Bool = true,
        internetOnly: Bool = false,
        autoInterface: Bool = false,
        host: String = "",
        ipv6Host: String = "",
        port: Int = 4_242
    ) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        self.kind = kind
        self.connectionMode = connectionMode
        self.autoConnect = autoConnect
        self.preferIPv6 = preferIPv6
        self.internetOnly = internetOnly
        self.autoInterface = autoInterface
        self.host = String(host.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
        self.ipv6Host = String(ipv6Host.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
        self.port = min(max(port, 1), 65_535)
    }

    public static let automatic = SidebandNetworkProfile(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
        name: "Automatic",
        kind: .builtIn,
        connectionMode: .automatic
    )
    public static let internet = SidebandNetworkProfile(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
        name: "Internet only",
        kind: .builtIn,
        connectionMode: .automatic,
        internetOnly: true
    )
    public static let localMesh = SidebandNetworkProfile(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
        name: "Local mesh",
        kind: .builtIn,
        connectionMode: .automatic,
        autoInterface: true
    )
    public static let builtIns = [automatic, internet, localMesh]
}
