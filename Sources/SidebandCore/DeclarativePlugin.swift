import Foundation

/// A data-only plugin format. It cannot load code, launch processes, access files,
/// or perform network requests, making imported extensions suitable for iOS.
public struct SidebandDeclarativePluginDefinition: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var identifier: String
    public var name: String
    public var version: String
    public var permissions: Set<SidebandPluginPermission>
    public var responses: [String: String]

    public init(identifier: String, name: String, version: String, permissions: Set<SidebandPluginPermission> = [], responses: [String: String]) {
        schemaVersion = Self.currentSchemaVersion; self.identifier = identifier; self.name = name
        self.version = version; self.permissions = permissions; self.responses = responses
    }

    public var manifest: SidebandPluginManifest {
        SidebandPluginManifest(identifier: identifier, name: name, version: version, commands: Set(responses.keys), permissions: permissions)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$"#, options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !version.isEmpty, version.count <= 32, !responses.isEmpty, responses.count <= 32,
              responses.allSatisfy({ SidebandPluginCommandLine.isValidCommand($0.key) && $0.value.utf8.count <= 4_096 }),
              permissions.isSubset(of: [.networkStatus, .conversationMetadata]) else { throw Error.invalidDefinition }
        for template in responses.values { try SidebandTemplate.validate(template) }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1_024 else { throw Error.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }

    public enum Error: Swift.Error { case tooLarge, invalidDefinition }
}

public struct SidebandDeclarativePlugin: SidebandCommandPlugin {
    public let definition: SidebandDeclarativePluginDefinition
    public var manifest: SidebandPluginManifest { definition.manifest }
    public init(definition: SidebandDeclarativePluginDefinition) throws { try definition.validate(); self.definition = definition }

    public func handle(_ context: SidebandPluginContext) async throws -> SidebandPluginResponse {
        guard let template = definition.responses[context.command] else { throw Error.unknownCommand }
        return SidebandPluginResponse(text: SidebandTemplate.render(template, context: context))
    }
    public enum Error: Swift.Error { case unknownCommand }
}

public enum SidebandTemplate {
    private static let tokenPattern = #"\{\{([A-Za-z0-9._-]+)\}\}"#
    private static let allowedStaticTokens: Set<String> = ["command", "network.state", "route.state", "sender", "sender.short"]

    public static func validate(_ template: String) throws {
        let expression = try NSRegularExpression(pattern: tokenPattern)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        for match in expression.matches(in: template, range: range) {
            guard let tokenRange = Range(match.range(at: 1), in: template) else { throw SidebandDeclarativePluginDefinition.Error.invalidDefinition }
            let token = String(template[tokenRange])
            let argument = token.hasPrefix("argument.") && Int(token.dropFirst(9)).map { (0..<SidebandPluginCommandLine.maximumArguments).contains($0) } == true
            guard allowedStaticTokens.contains(token) || argument else { throw SidebandDeclarativePluginDefinition.Error.invalidDefinition }
        }
        guard !template.contains("{{{") && !template.contains("}}}") else { throw SidebandDeclarativePluginDefinition.Error.invalidDefinition }
    }

    public static func render(_ template: String, context: SidebandPluginContext) -> String {
        guard (try? validate(template)) != nil else { return "Plugin response was invalid." }
        let expression = try! NSRegularExpression(pattern: tokenPattern)
        var output = template
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in expression.matches(in: output, range: range).reversed() {
            guard let whole = Range(match.range(at: 0), in: output), let tokenRange = Range(match.range(at: 1), in: output) else { continue }
            let token = String(output[tokenRange])
            let replacement: String
            switch token {
            case "command": replacement = context.command
            case "network.state": replacement = context.networkReady.map { $0 ? "ready" : "offline" } ?? "redacted"
            case "route.state": replacement = context.routeAvailable.map { $0 ? "available" : "unavailable" } ?? "redacted"
            case "sender": replacement = context.senderDestinationHash ?? "redacted"
            case "sender.short": replacement = context.senderDestinationHash.map { String($0.prefix(8)) } ?? "redacted"
            default:
                let index = Int(token.dropFirst(9)) ?? -1
                replacement = context.arguments.indices.contains(index) ? String(context.arguments[index].prefix(256)) : ""
            }
            output.replaceSubrange(whole, with: replacement)
        }
        return String(output.prefix(1_024))
    }
}
