import Foundation

/// Reads the public community-interface directory used by MeshChatX.
///
/// Directory data is discovery input, never trusted configuration: only
/// enabled TCP client entries with valid DNS/IP hosts and ports are returned.
/// A previously validated result is retained when a refresh fails.
public actor CommunityInterfaceDirectory {
    public struct Snapshot: Sendable, Equatable {
        public let gateways: [InternetGateway]
        public let refreshedAt: Date
    }

    public enum DirectoryError: LocalizedError {
        case invalidResponse
        case unexpectedEndpoint
        case noUsableInterfaces

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: "The community directory returned invalid data."
            case .unexpectedEndpoint: "The community directory redirected to an untrusted endpoint."
            case .noUsableInterfaces: "The community directory did not contain usable TCP interfaces."
            }
        }
    }

    public static let submittedURL = URL(string: "https://directory.rns.recipes/api/directory/submitted?status=online")!
    public static let discoveredURL = URL(string: "https://directory.rns.recipes/api/directory/discovered?status=online")!

    private let session: URLSession
    private var cached: Snapshot?
    private let cacheLifetime: TimeInterval

    public init(cacheLifetime: TimeInterval = 6 * 60 * 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
        self.cacheLifetime = cacheLifetime
    }

    public func gateways(forceRefresh: Bool = false, now: Date = .now) async -> [InternetGateway] {
        if !forceRefresh, let cached, now.timeIntervalSince(cached.refreshedAt) < cacheLifetime {
            return cached.gateways
        }
        do {
            let refreshed = try await refresh(now: now)
            cached = refreshed
            return refreshed.gateways
        } catch {
            return cached?.gateways ?? []
        }
    }

    public func refresh(now: Date = .now) async throws -> Snapshot {
        async let submittedData = fetchData(Self.submittedURL)
        async let discoveredData = fetchData(Self.discoveredURL)
        let (submitted, discovered) = try await (submittedData, discoveredData)
        let rows = try parseRows(from: submitted) + parseRows(from: discovered)
        let gateways = Self.parseGateways(from: rows)
        guard !gateways.isEmpty else { throw DirectoryError.noUsableInterfaces }
        return Snapshot(gateways: gateways, refreshedAt: now)
    }

    private func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lower-Sideband/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DirectoryError.invalidResponse
        }
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == "directory.rns.recipes" else {
            throw DirectoryError.unexpectedEndpoint
        }
        return data
    }

    private func parseRows(from data: Data) throws -> [Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        if let rows = value as? [Any] { return rows }
        if let object = value as? [String: Any], let rows = object["data"] as? [Any] { return rows }
        throw DirectoryError.invalidResponse
    }

    static func parseGateways(from rows: [Any]) -> [InternetGateway] {
        var gateways: [InternetGateway] = []
        var seen: Set<String> = []
        for case let row as [String: Any] in rows {
            let config = row["config"] as? [String: Any] ?? [:]
            let configText = row["config"] as? String ?? ""
            let enabled = bool(row["enabled"]) ?? bool(config["enabled"]) ?? true
            guard enabled else { continue }
            let type = string(row["type"])
                ?? string(row["typeName"])
                ?? string(config["type"])
                ?? string(config["typeName"])
                ?? configValue("type", in: configText)
                ?? ""
            let normalizedType = type.lowercased()
            let isBackbone = normalizedType.contains("backbone") || configText.localizedCaseInsensitiveContains("BackboneInterface")
            guard normalizedType.contains("tcp") || isBackbone else { continue }
            // A Backbone entry with a transport identity is not ordinary TCP.
            // Ignore it until native Backbone authentication is implemented.
            let transportIdentity = string(row["transportId"])
                ?? string(config["transport_identity"])
                ?? configValue("transport_identity", in: configText)
            if isBackbone, transportIdentity?.isEmpty == false { continue }
            let host = (
                string(row["host"])
                ?? string(row["address"])
                ?? string(config["target_host"])
                ?? string(config["host"])
                ?? string(config["address"])
                ?? configValue("target_host", in: configText)
                ?? configValue("remote", in: configText)
                ?? configValue("host", in: configText)
                ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeHost(host) else { continue }
            guard let port = uint16(
                row["port"]
                ?? config["target_port"]
                ?? config["port"]
                ?? configValue("target_port", in: configText)
                ?? configValue("port", in: configText)
            ) else { continue }
            let name = (
                string(row["name"])
                ?? string(config["name"])
                ?? "Community RNS"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let gateway = InternetGateway(
                name: name.isEmpty ? "Community RNS" : String(name.prefix(80)),
                host: host,
                port: port
            )
            if seen.insert(gateway.id).inserted {
                gateways.append(gateway)
            }
        }
        return gateways
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String:
            switch value.lowercased() {
            case "true", "yes", "1", "on": true
            case "false", "no", "0", "off": false
            default: nil
            }
        default: nil
        }
    }

    private static func uint16(_ value: Any?) -> UInt16? {
        if let value = value as? NSNumber, let port = UInt16(exactly: value.intValue), port > 0 { return port }
        if let value = value as? String, let port = UInt16(value), port > 0 { return port }
        return nil
    }

    private static func configValue(_ key: String, in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let separator = line.firstIndex(of: "=") else { continue }
            let candidate = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.caseInsensitiveCompare(key) == .orderedSame else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func isSafeHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253,
              !host.contains("/"), !host.contains("@"), !host.contains(" ") else { return false }
        if host.first == "[", host.last == "]" { return host.count > 2 }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_"))
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }
}
