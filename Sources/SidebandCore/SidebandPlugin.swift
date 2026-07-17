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
    public let senderDestinationHash: String
    public let networkReady: Bool
    public let routeAvailable: Bool
}

public struct SidebandPluginResponse: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = String(text.prefix(1_024)) }
}

public protocol SidebandCommandPlugin: Sendable {
    var manifest: SidebandPluginManifest { get }
    func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse
}

@MainActor public final class SidebandPluginRegistry {
    private var plugins: [String: any SidebandCommandPlugin] = [:]
    private var enabledIdentifiers: Set<String>

    public init(plugins: [any SidebandCommandPlugin] = [SidebandInfoPlugin()]) {
        let saved = UserDefaults.standard.stringArray(forKey: "sidebandEnabledPlugins")
        enabledIdentifiers = Set(saved ?? plugins.map(\.manifest.identifier))
        for plugin in plugins { self.plugins[plugin.manifest.identifier] = plugin }
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

    public func execute(command: String, arguments: [String], context: SidebandPluginContext) async -> SidebandPluginResponse? {
        guard let plugin = plugins.values.first(where: {
            enabledIdentifiers.contains($0.manifest.identifier) && $0.manifest.commands.contains(command)
        }) else { return nil }
        return await withTaskGroup(of: SidebandPluginResponse?.self) { group in
            group.addTask {
                do { return try await plugin.handle(context) }
                catch { return SidebandPluginResponse(text: "Plugin request failed safely.") }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return SidebandPluginResponse(text: "Plugin request timed out safely.")
            }
            let response = await group.next() ?? nil
            group.cancelAll()
            return response
        }
    }

    private func persistEnabledIdentifiers() {
        UserDefaults.standard.set(enabledIdentifiers.sorted(), forKey: "sidebandEnabledPlugins")
    }
}

public struct SidebandInfoPlugin: SidebandCommandPlugin {
    public let manifest = SidebandPluginManifest(
        identifier: "app.sideband.info",
        name: "Sideband Information",
        version: "1.0",
        commands: ["sideband-info", "route-status"],
        permissions: [.networkStatus]
    )

    public init() {}

    public func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse {
        switch context.command {
        case "route-status":
            return SidebandPluginResponse(text: "Route status: network \(context.networkReady ? "ready" : "offline"), route \(context.routeAvailable ? "available" : "unknown").")
        default:
            return SidebandPluginResponse(text: "Sideband Swift native plugin service is available.")
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

    private static func isValidCommand(_ command: String) -> Bool {
        !command.isEmpty && command.count <= 64 && command.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private static func quote(_ token: String) -> String {
        guard token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else { return token }
        return "\"" + token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
