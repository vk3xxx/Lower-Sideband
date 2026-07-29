import CryptoKit
import Foundation

public struct SidebandSupportBundle: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let applicationVersion: String
    public let operatingSystem: String
    public let health: SidebandSupportHealth
    public let networkReport: String
    public let attachmentReport: String

    public init(
        generatedAt: Date = .now,
        applicationVersion: String,
        operatingSystem: String,
        health: SidebandSupportHealth,
        networkReport: String,
        attachmentReport: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.applicationVersion = applicationVersion
        self.operatingSystem = operatingSystem
        self.health = health
        self.networkReport = networkReport
        self.attachmentReport = attachmentReport
    }
}

public struct SidebandSupportHealth: Codable, Sendable, Equatable {
    public let networkState: String
    public let conversations: Int
    public let messages: Int
    public let queuedMessages: Int
    public let failedMessages: Int
    public let activeLinks: Int
    public let knownPaths: Int
    public let attachmentTransfers: Int
    public let memoryPressureEvents: Int
    public let backgroundWakeAttempts: Int
    public let backgroundWakeSuccesses: Int
    public let lowPowerMode: Bool
    public let thermalState: Int
}

/// Removes user content and linkable network identifiers from reports before
/// they leave the device. Replacements are stable within a report so support
/// can still correlate repeated identifiers without learning their values.
public enum SidebandSupportRedactor {
    public static func redact(_ input: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var output = input
        if !homeDirectory.isEmpty {
            output = output.replacingOccurrences(of: homeDirectory, with: "<home>")
        }
        output = replacing(pattern: #"(?i)\b[0-9a-f]{16,128}\b"#, in: output) { stableToken("id", $0) }
        output = replacing(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: output) { stableToken("ipv4", $0) }
        output = replacing(pattern: #"(?i)\b(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}\b"#, in: output) { stableToken("ipv6", $0) }
        output = replacing(pattern: #"(?i)\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|de|au|local)\b"#, in: output) {
            stableToken("host", $0.lowercased())
        }
        return output
    }

    private static func stableToken(_ kind: String, _ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "<\(kind)-\(digest.prefix(4).map { String(format: "%02x", $0) }.joined())>"
    }

    private static func replacing(
        pattern: String,
        in input: String,
        transform: (String) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
        let source = input as NSString
        let matches = expression.matches(in: input, range: NSRange(location: 0, length: source.length))
        var output = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: transform(String(output[range])))
        }
        return output
    }
}
