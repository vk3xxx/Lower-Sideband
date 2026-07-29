import Foundation
import Observation

public enum SidebandAcceptanceScenario: String, CaseIterable, Codable, Identifiable, Sendable {
    case messaging
    case attachments
    case voice
    case telemetry
    case backgroundRecovery
    case capturePermissions
    case networkHandover

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .messaging: "Bidirectional messaging"
        case .attachments: "Images and 1 MiB files"
        case .voice: "Voice messages and calls"
        case .telemetry: "Telemetry and maps"
        case .backgroundRecovery: "Background recovery"
        case .capturePermissions: "Camera and microphone"
        case .networkHandover: "Wi-Fi and cellular handover"
        }
    }

    public var instructions: String {
        switch self {
        case .messaging: "Exchange at least ten messages in both directions and verify every delivery proof, ordering and duplicate count."
        case .attachments: "Send an inline image and a 1 MiB file in both directions; open each result and compare its size and digest."
        case .voice: "Record, send and play a voice message, then establish and end an encrypted call without stuck audio state."
        case .telemetry: "Share trusted telemetry, display it in the conversation and map, then export and reopen the history."
        case .backgroundRecovery: "Background the app, send from another client, return after several minutes and verify recovery without duplicate alerts."
        case .capturePermissions: "Exercise QR scanning, image selection, microphone denial and later permission recovery from System Settings."
        case .networkHandover: "Move between Wi-Fi and cellular or another Wi-Fi network and verify queued content resumes exactly once."
        }
    }
}

public enum SidebandAcceptanceOutcome: String, Codable, Sendable {
    case notRun
    case passed
    case failed
}

public struct SidebandAcceptanceResult: Codable, Sendable, Equatable {
    public var outcome: SidebandAcceptanceOutcome = .notRun
    public var testedAt: Date?
    public var notes = ""
}

public struct SidebandAcceptanceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let device: String
    public let operatingSystem: String
    public let isPhysicalDevice: Bool
    public let results: [String: SidebandAcceptanceResult]

    public var passedCount: Int { results.values.count { $0.outcome == .passed } }
    public var failedCount: Int { results.values.count { $0.outcome == .failed } }
}

@MainActor @Observable
public final class SidebandDeviceAcceptance {
    public private(set) var results: [SidebandAcceptanceScenario: SidebandAcceptanceResult] = [:]
    public let isPhysicalDevice: Bool
    public let deviceDescription: String
    private let defaults: UserDefaults
    private let defaultsKey = "deviceAcceptanceResults.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if targetEnvironment(simulator)
        isPhysicalDevice = false
        deviceDescription = "Apple Simulator"
        #elseif os(macOS)
        isPhysicalDevice = true
        deviceDescription = "Mac"
        #elseif os(iOS)
        isPhysicalDevice = true
        deviceDescription = "iPhone or iPad"
        #else
        isPhysicalDevice = false
        deviceDescription = "Unsupported environment"
        #endif
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([String: SidebandAcceptanceResult].self, from: data) {
            results = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                SidebandAcceptanceScenario(rawValue: key).map { ($0, value) }
            })
        }
    }

    public func result(for scenario: SidebandAcceptanceScenario) -> SidebandAcceptanceResult {
        results[scenario] ?? SidebandAcceptanceResult()
    }

    public func record(_ outcome: SidebandAcceptanceOutcome, for scenario: SidebandAcceptanceScenario, notes: String = "") {
        results[scenario] = SidebandAcceptanceResult(
            outcome: outcome,
            testedAt: outcome == .notRun ? nil : .now,
            notes: String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
        )
        persist()
    }

    public func reset() {
        results.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    public var completedCount: Int {
        SidebandAcceptanceScenario.allCases.count { result(for: $0).outcome != .notRun }
    }

    public func exportData(now: Date = .now) throws -> Data {
        let report = SidebandAcceptanceReport(
            schemaVersion: 1,
            generatedAt: now,
            device: deviceDescription,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            isPhysicalDevice: isPhysicalDevice,
            results: Dictionary(uniqueKeysWithValues: SidebandAcceptanceScenario.allCases.map {
                ($0.rawValue, result(for: $0))
            })
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: results.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
