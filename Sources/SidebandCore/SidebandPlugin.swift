import Foundation

public enum SidebandPluginPermission: String, Codable, Hashable, Sendable {
    case networkStatus
    case conversationMetadata
}

public struct SidebandPluginManifest: Codable, Hashable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    public let version: String
    public let commands: Set<String>
    public let permissions: Set<SidebandPluginPermission>
    public var id: String { identifier }

    public init(identifier: String, name: String, version: String, commands: Set<String>, permissions: Set<SidebandPluginPermission> = []) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.commands = commands
        self.permissions = permissions
    }
}

public struct SidebandPluginContext: Sendable {
    public let command: String
    public let arguments: [String]
    public let senderDestinationHash: String?
    public let networkReady: Bool?
    public let routeAvailable: Bool?

    public init(command: String, arguments: [String], senderDestinationHash: String? = nil, networkReady: Bool? = nil, routeAvailable: Bool? = nil) {
        self.command = command
        self.arguments = arguments
        self.senderDestinationHash = senderDestinationHash
        self.networkReady = networkReady
        self.routeAvailable = routeAvailable
    }
}

public struct SidebandPluginResponse: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = String(text.prefix(1_024)) }
}

public protocol SidebandCommandPlugin: Sendable {
    var manifest: SidebandPluginManifest { get }
    func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse
}

public enum SidebandPluginExecutionOutcome: String, Codable, Hashable, Sendable {
    case succeeded
    case unavailable
    case denied
    case failed
    case timedOut
}

public struct SidebandPluginExecution: Sendable, Equatable {
    public let pluginIdentifier: String?
    public let outcome: SidebandPluginExecutionOutcome
    public let response: SidebandPluginResponse?

    public init(pluginIdentifier: String?, outcome: SidebandPluginExecutionOutcome, response: SidebandPluginResponse? = nil) {
        self.pluginIdentifier = pluginIdentifier
        self.outcome = outcome
        self.response = response
    }
}

@MainActor public final class SidebandPluginRegistry {
    private var plugins: [String: any SidebandCommandPlugin] = [:]
    private var enabledIdentifiers: Set<String>
    private let executionTimeout: Duration
    private let persistsConfiguration: Bool
    public private(set) var rejectedPluginDescriptions: [String] = []

    public init(plugins: [any SidebandCommandPlugin] = [SidebandInfoPlugin()], executionTimeout: Duration = .seconds(3), enabledIdentifiers: Set<String>? = nil, persistsConfiguration: Bool = true) {
        self.executionTimeout = executionTimeout
        self.persistsConfiguration = persistsConfiguration
        var claimedCommands: Set<String> = []
        for plugin in plugins.sorted(by: { $0.manifest.identifier < $1.manifest.identifier }) {
            let manifest = plugin.manifest
            guard Self.isValid(manifest) else {
                rejectedPluginDescriptions.append("\(manifest.name): invalid manifest")
                continue
            }
            guard self.plugins[manifest.identifier] == nil else {
                rejectedPluginDescriptions.append("\(manifest.name): duplicate identifier")
                continue
            }
            guard claimedCommands.isDisjoint(with: manifest.commands) else {
                rejectedPluginDescriptions.append("\(manifest.name): command conflicts with another plugin")
                continue
            }
            self.plugins[manifest.identifier] = plugin
            claimedCommands.formUnion(manifest.commands)
        }
        let saved = persistsConfiguration ? UserDefaults.standard.stringArray(forKey: "sidebandEnabledPlugins") : nil
        self.enabledIdentifiers = (enabledIdentifiers ?? saved.map(Set.init) ?? Set(self.plugins.keys)).intersection(self.plugins.keys)
        persistEnabledIdentifiers()
    }

    public var manifests: [SidebandPluginManifest] {
        plugins.values.map(\.manifest).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func isEnabled(_ identifier: String) -> Bool { enabledIdentifiers.contains(identifier) }

    public func setEnabled(_ enabled: Bool, identifier: String) {
        guard plugins[identifier] != nil else { return }
        if enabled { enabledIdentifiers.insert(identifier) }
        else { enabledIdentifiers.remove(identifier) }
        persistEnabledIdentifiers()
    }

    public func execute(command: String, arguments: [String], context: SidebandPluginContext) async -> SidebandPluginExecution {
        guard let plugin = plugins.values.first(where: {
            enabledIdentifiers.contains($0.manifest.identifier) && $0.manifest.commands.contains(command)
        }) else { return SidebandPluginExecution(pluginIdentifier: nil, outcome: .unavailable) }
        let permissions = plugin.manifest.permissions
        let authorizedContext = SidebandPluginContext(
            command: command,
            arguments: arguments,
            senderDestinationHash: permissions.contains(.conversationMetadata) ? context.senderDestinationHash : nil,
            networkReady: permissions.contains(.networkStatus) ? context.networkReady : nil,
            routeAvailable: permissions.contains(.networkStatus) ? context.routeAvailable : nil
        )
        enum Result: Sendable {
            case response(SidebandPluginResponse)
            case failed
            case timedOut
        }
        let timeout = executionTimeout
        let result = await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do { return .response(try await plugin.handle(authorizedContext)) }
                catch { return .failed }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let result = await group.next() ?? .failed
            group.cancelAll()
            return result
        }
        switch result {
        case .response(let response):
            return SidebandPluginExecution(pluginIdentifier: plugin.manifest.identifier, outcome: .succeeded, response: response)
        case .failed:
            return SidebandPluginExecution(pluginIdentifier: plugin.manifest.identifier, outcome: .failed, response: SidebandPluginResponse(text: "Plugin request failed safely."))
        case .timedOut:
            return SidebandPluginExecution(pluginIdentifier: plugin.manifest.identifier, outcome: .timedOut, response: SidebandPluginResponse(text: "Plugin request timed out safely."))
        }
    }

    private func persistEnabledIdentifiers() {
        guard persistsConfiguration else { return }
        UserDefaults.standard.set(enabledIdentifiers.sorted(), forKey: "sidebandEnabledPlugins")
    }

    private static func isValid(_ manifest: SidebandPluginManifest) -> Bool {
        !manifest.identifier.isEmpty && manifest.identifier.count <= 128 &&
        !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && manifest.name.count <= 80 &&
        !manifest.version.isEmpty && manifest.version.count <= 32 &&
        !manifest.commands.isEmpty && manifest.commands.count <= 32 &&
        manifest.commands.allSatisfy(SidebandPluginCommandLine.isValidCommand)
    }
}

public struct SidebandInfoPlugin: SidebandCommandPlugin {
    public let manifest = SidebandPluginManifest(
        identifier: "app.sideband.info",
        name: "Lower Sideband Information",
        version: "1.0",
        commands: ["sideband-info", "route-status"],
        permissions: [.networkStatus]
    )

    public init() {}

    public func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse {
        switch context.command {
        case "route-status":
            let network = context.networkReady.map { $0 ? "ready" : "offline" } ?? "not permitted"
            let route = context.routeAvailable.map { $0 ? "available" : "unknown" } ?? "not permitted"
            return SidebandPluginResponse(text: "Route status: network \(network), route \(route).")
        default:
            return SidebandPluginResponse(text: "Lower Sideband native plugin service is available.")
        }
    }
}

public enum SidebandPluginCommandLine {
    public static let maximumBytes = 512
    public static let maximumArguments = 8

    public static func encode(command: String, arguments: [String]) -> String? {
        guard isValidCommand(command), arguments.count <= maximumArguments else { return nil }
        let tokens = [command] + arguments
        let line = tokens.map(quote).joined(separator: " ")
        return line.utf8.count <= maximumBytes ? line : nil
    }

    public static func parse(_ line: String) -> (command: String, arguments: [String])? {
        guard !line.isEmpty, line.utf8.count <= maximumBytes else { return nil }
        var tokens: [String] = [], token = "", quoted = false, escaping = false
        for character in line {
            if escaping { token.append(character); escaping = false; continue }
            if character == "\\" { escaping = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(character) }
        }
        guard !quoted, !escaping else { return nil }
        if !token.isEmpty { tokens.append(token) }
        guard let command = tokens.first, isValidCommand(command), tokens.count - 1 <= maximumArguments else { return nil }
        return (command, Array(tokens.dropFirst()))
    }

    fileprivate static func isValidCommand(_ command: String) -> Bool {
        !command.isEmpty && command.count <= 64 && command.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private static func quote(_ token: String) -> String {
        guard token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else { return token }
        return "\"" + token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
