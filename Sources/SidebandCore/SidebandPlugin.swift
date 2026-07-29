import ReticulumKit
import Foundation

public enum SidebandPluginPermission: String, Codable, Hashable, Sendable {
    case networkStatus
    case conversationMetadata
    case messageMetadata
    case telemetryRead
    case telemetryWrite
    case serviceLifecycle
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
    public let routeHopCount: UInt8?
    public let routeInterface: String?
    public let conversationDisplayName: String?
    public let messageDirection: Message.Direction?
    public let messageTimestamp: Date?
    /// Bounded, display-safe sensor summaries. Raw telemetry and location
    /// coordinates are never provided to command plugins.
    public let telemetrySummary: [String: String]

    public init(
        command: String,
        arguments: [String],
        senderDestinationHash: String? = nil,
        networkReady: Bool? = nil,
        routeAvailable: Bool? = nil,
        routeHopCount: UInt8? = nil,
        routeInterface: String? = nil,
        conversationDisplayName: String? = nil,
        messageDirection: Message.Direction? = nil,
        messageTimestamp: Date? = nil,
        telemetrySummary: [String: String] = [:]
    ) {
        self.command = command
        self.arguments = arguments
        self.senderDestinationHash = senderDestinationHash
        self.networkReady = networkReady
        self.routeAvailable = routeAvailable
        self.routeHopCount = routeHopCount
        self.routeInterface = routeInterface.map { String($0.prefix(128)) }
        self.conversationDisplayName = conversationDisplayName.map { String($0.prefix(80)) }
        self.messageDirection = messageDirection
        self.messageTimestamp = messageTimestamp
        self.telemetrySummary = Dictionary(
            uniqueKeysWithValues: telemetrySummary.sorted(by: { $0.key < $1.key }).prefix(16).map {
                (String($0.key.prefix(48)), String($0.value.prefix(128)))
            }
        )
    }
}

public enum SidebandPluginPresentation: String, Codable, Sendable {
    case text
    case status
    case metricList
}

public struct SidebandPluginResponse: Sendable, Equatable {
    public let text: String
    public let presentation: SidebandPluginPresentation
    public let details: [String: String]

    public init(text: String, presentation: SidebandPluginPresentation = .text, details: [String: String] = [:]) {
        self.text = String(text.prefix(1_024))
        self.presentation = presentation
        self.details = Dictionary(
            uniqueKeysWithValues: details.sorted(by: { $0.key < $1.key }).prefix(12).map {
                (String($0.key.prefix(48)), String($0.value.prefix(256)))
            }
        )
    }

    /// Portable fallback used when the recipient does not render structured
    /// native plugin cards.
    public var renderedText: String {
        guard !details.isEmpty else { return text }
        let rows = details.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
        return String(([text] + rows).joined(separator: "\n").prefix(4_096))
    }
}

public protocol SidebandCommandPlugin: Sendable {
    var manifest: SidebandPluginManifest { get }
    func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse
}

public protocol SidebandServicePlugin: Sendable {
    var manifest: SidebandPluginManifest { get }
    func start() async throws
    func stop() async
    func status() async -> String
}

public protocol SidebandTelemetryPlugin: Sendable {
    var manifest: SidebandPluginManifest { get }
    func sample() async throws -> [UInt8: Data]
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

public struct SidebandPluginRuntimeStatus: Sendable, Equatable {
    public let invocationCount: Int
    public let lastOutcome: SidebandPluginExecutionOutcome?
    public let lastRunAt: Date?
}

@MainActor public final class SidebandPluginRegistry {
    private var plugins: [String: any SidebandCommandPlugin] = [:]
    private var services: [String: any SidebandServicePlugin] = [:]
    private var telemetry: [String: any SidebandTelemetryPlugin] = [:]
    private var enabledIdentifiers: Set<String>
    private let executionTimeout: Duration
    private let persistsConfiguration: Bool
    public private(set) var rejectedPluginDescriptions: [String] = []
    public private(set) var runtimeStatuses: [String: SidebandPluginRuntimeStatus] = [:]

    public init(plugins: [any SidebandCommandPlugin] = [SidebandInfoPlugin()], services: [any SidebandServicePlugin] = [], telemetry: [any SidebandTelemetryPlugin] = [SystemTelemetryPlugin()], executionTimeout: Duration = .seconds(3), enabledIdentifiers: Set<String>? = nil, persistsConfiguration: Bool = true) {
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
        for plugin in services where Self.isValid(plugin.manifest) && plugin.manifest.permissions.contains(.serviceLifecycle) {
            self.services[plugin.manifest.identifier] = plugin
        }
        for plugin in telemetry where Self.isValid(plugin.manifest) && plugin.manifest.permissions.contains(.telemetryWrite) {
            self.telemetry[plugin.manifest.identifier] = plugin
        }
        let saved = persistsConfiguration ? UserDefaults.standard.stringArray(forKey: "sidebandEnabledPlugins") : nil
        let identifiers = Set(self.plugins.keys).union(self.services.keys).union(self.telemetry.keys)
        self.enabledIdentifiers = (enabledIdentifiers ?? saved.map(Set.init) ?? identifiers).intersection(identifiers)
        persistEnabledIdentifiers()
    }

    public var manifests: [SidebandPluginManifest] {
        (plugins.values.map(\.manifest) + services.values.map(\.manifest) + telemetry.values.map(\.manifest))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func isEnabled(_ identifier: String) -> Bool { enabledIdentifiers.contains(identifier) }

    public func setEnabled(_ enabled: Bool, identifier: String) {
        guard plugins[identifier] != nil || services[identifier] != nil || telemetry[identifier] != nil else { return }
        if enabled { enabledIdentifiers.insert(identifier) }
        else { enabledIdentifiers.remove(identifier) }
        persistEnabledIdentifiers()
    }

    @discardableResult public func registerDeclarative(_ definition: SidebandDeclarativePluginDefinition, enabled: Bool = false) -> Bool {
        do {
            let plugin = try SidebandDeclarativePlugin(definition: definition)
            let manifest = plugin.manifest
            guard Self.isValid(manifest), plugins[manifest.identifier] == nil,
                  Set(plugins.values.flatMap(\.manifest.commands)).isDisjoint(with: manifest.commands) else {
                rejectedPluginDescriptions.append("\(manifest.name): duplicate identifier or command")
                return false
            }
            plugins[manifest.identifier] = plugin
            if enabled { enabledIdentifiers.insert(manifest.identifier) }
            persistEnabledIdentifiers()
            return true
        } catch {
            rejectedPluginDescriptions.append("\(definition.name): invalid declarative plugin")
            return false
        }
    }

    @discardableResult public func unregisterDeclarative(_ identifier: String) -> Bool {
        guard plugins[identifier] is SidebandDeclarativePlugin else { return false }
        plugins.removeValue(forKey: identifier); enabledIdentifiers.remove(identifier); persistEnabledIdentifiers(); return true
    }

    public func startEnabledServices() async {
        for (identifier, service) in services where enabledIdentifiers.contains(identifier) { try? await service.start() }
    }

    public func stopServices() async { for service in services.values { await service.stop() } }

    public func serviceStatuses() async -> [String: String] {
        var result: [String: String] = [:]
        for (identifier, service) in services { result[identifier] = await service.status() }
        return result
    }

    public func collectTelemetry() async -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        for (identifier, provider) in telemetry where enabledIdentifiers.contains(identifier) {
            guard let sample = try? await provider.sample() else { continue }
            for (sensor, encoded) in sample where result[sensor] == nil && encoded.count <= 65_536 && (try? MessagePackDecoder.decode(encoded)) != nil {
                result[sensor] = encoded
            }
        }
        return result
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
            routeAvailable: permissions.contains(.networkStatus) ? context.routeAvailable : nil,
            routeHopCount: permissions.contains(.networkStatus) ? context.routeHopCount : nil,
            routeInterface: permissions.contains(.networkStatus) ? context.routeInterface : nil,
            conversationDisplayName: permissions.contains(.conversationMetadata) ? context.conversationDisplayName : nil,
            messageDirection: permissions.contains(.messageMetadata) ? context.messageDirection : nil,
            messageTimestamp: permissions.contains(.messageMetadata) ? context.messageTimestamp : nil,
            telemetrySummary: permissions.contains(.telemetryRead) ? context.telemetrySummary : [:]
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
            recordRuntime(identifier: plugin.manifest.identifier, outcome: .succeeded)
            return SidebandPluginExecution(pluginIdentifier: plugin.manifest.identifier, outcome: .succeeded, response: response)
        case .failed:
            recordRuntime(identifier: plugin.manifest.identifier, outcome: .failed)
            return SidebandPluginExecution(pluginIdentifier: plugin.manifest.identifier, outcome: .failed, response: SidebandPluginResponse(text: "Plugin request failed safely."))
        case .timedOut:
            recordRuntime(identifier: plugin.manifest.identifier, outcome: .timedOut)
            return SidebandPluginExecution(pluginIdentifier: plugin.manifest.identifier, outcome: .timedOut, response: SidebandPluginResponse(text: "Plugin request timed out safely."))
        }
    }

    private func recordRuntime(identifier: String, outcome: SidebandPluginExecutionOutcome) {
        let existing = runtimeStatuses[identifier]
        runtimeStatuses[identifier] = SidebandPluginRuntimeStatus(
            invocationCount: (existing?.invocationCount ?? 0) + 1,
            lastOutcome: outcome,
            lastRunAt: .now
        )
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
            var details = ["Network": network, "Route": route]
            if let hops = context.routeHopCount { details["Hops"] = String(hops) }
            if let interface = context.routeInterface { details["Interface"] = interface }
            return SidebandPluginResponse(text: "Route status", presentation: .status, details: details)
        default:
            return SidebandPluginResponse(text: "Lower Sideband native plugin service is available.")
        }
    }
}

public struct SystemTelemetryPlugin: SidebandTelemetryPlugin {
    public let manifest = SidebandPluginManifest(
        identifier: "app.sideband.system-telemetry", name: "System Telemetry", version: "1.0",
        commands: ["system-telemetry"], permissions: [.telemetryWrite]
    )
    public init() {}
    public func sample() async throws -> [UInt8: Data] {
        let info = ProcessInfo.processInfo
        return [
            SidebandTelemetry.SensorKind.processor.rawValue: MessagePack.map([
                ("logical_cores", MessagePack.unsigned(UInt64(info.processorCount))),
                ("active_cores", MessagePack.unsigned(UInt64(info.activeProcessorCount)))
            ]),
            SidebandTelemetry.SensorKind.ram.rawValue: MessagePack.map([
                ("capacity", MessagePack.unsigned(info.physicalMemory))
            ])
        ]
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

    public static func isValidCommand(_ command: String) -> Bool {
        !command.isEmpty && command.count <= 64 && command.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private static func quote(_ token: String) -> String {
        guard token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else { return token }
        return "\"" + token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
