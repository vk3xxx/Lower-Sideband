import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

public enum SidebandAcceptanceScenario: String, CaseIterable, Codable, Identifiable, Sendable {
    case messaging
    case attachments
    case voice
    case telemetry
    case backgroundRecovery
    case capturePermissions
    case networkHandover
    case accessibility
    case localization
    case endurance

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
        case .accessibility: "Accessibility and input"
        case .localization: "Language and layout"
        case .endurance: "Memory, power and endurance"
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
        case .accessibility: "Use VoiceOver, keyboard navigation, Dynamic Type, Increase Contrast and Reduce Motion; verify every core action remains labelled, reachable and understandable."
        case .localization: "Run with the system language and region changed, verify text expansion, dates, times and numbers, and confirm no controls clip or expose untranslated keys."
        case .endurance: "Leave the app connected for at least one hour while exchanging messages and attachments; verify stable memory, acceptable energy use and automatic recovery."
        }
    }
}

public enum SidebandAcceptancePlatform: String, Codable, Sendable {
    case mac
    case iPhone
    case iPad
    case simulator
    case unknown

    public var title: String {
        switch self {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .simulator: "Apple Simulator"
        case .unknown: "Unknown Apple platform"
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
    public var build: String?
    public var operatingSystem: String?
}

public struct SidebandAcceptanceReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let runID: UUID
    public let startedAt: Date
    public let generatedAt: Date
    public let device: String
    public let platform: SidebandAcceptancePlatform
    public let operatingSystem: String
    public let appBuild: String
    public let isPhysicalDevice: Bool
    public let isReadyForReleaseReview: Bool
    public let results: [String: SidebandAcceptanceResult]

    public var passedCount: Int { results.values.count { $0.outcome == .passed } }
    public var failedCount: Int { results.values.count { $0.outcome == .failed } }
}

@MainActor @Observable
public final class SidebandDeviceAcceptance {
    public private(set) var results: [SidebandAcceptanceScenario: SidebandAcceptanceResult] = [:]
    public private(set) var runID: UUID
    public private(set) var startedAt: Date
    public let isPhysicalDevice: Bool
    public let deviceDescription: String
    public let platform: SidebandAcceptancePlatform
    private let defaults: UserDefaults
    private let defaultsKey = "deviceAcceptanceResults.v1"
    private let runKey = "deviceAcceptanceRun.v2"

    private struct StoredRun: Codable {
        let id: UUID
        let startedAt: Date
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if targetEnvironment(simulator)
        isPhysicalDevice = false
        deviceDescription = "Apple Simulator"
        platform = .simulator
        #elseif os(macOS)
        isPhysicalDevice = true
        deviceDescription = "Mac"
        platform = .mac
        #elseif os(iOS)
        isPhysicalDevice = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            deviceDescription = "iPad"
            platform = .iPad
        } else {
            deviceDescription = "iPhone"
            platform = .iPhone
        }
        #else
        isPhysicalDevice = false
        deviceDescription = "Unsupported environment"
        platform = .unknown
        #endif
        if let data = defaults.data(forKey: runKey),
           let run = try? JSONDecoder().decode(StoredRun.self, from: data) {
            runID = run.id
            startedAt = run.startedAt
        } else {
            runID = UUID()
            startedAt = .now
        }
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([String: SidebandAcceptanceResult].self, from: data) {
            results = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                SidebandAcceptanceScenario(rawValue: key).map { ($0, value) }
            })
        }
        persistRun()
    }

    public func result(for scenario: SidebandAcceptanceScenario) -> SidebandAcceptanceResult {
        results[scenario] ?? SidebandAcceptanceResult()
    }

    public func record(_ outcome: SidebandAcceptanceOutcome, for scenario: SidebandAcceptanceScenario, notes: String = "") {
        results[scenario] = SidebandAcceptanceResult(
            outcome: outcome,
            testedAt: outcome == .notRun ? nil : .now,
            notes: String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000)),
            build: outcome == .notRun ? nil : appBuild,
            operatingSystem: outcome == .notRun ? nil : ProcessInfo.processInfo.operatingSystemVersionString
        )
        persist()
    }

    public func startNewRun(now: Date = .now) {
        results.removeAll()
        runID = UUID()
        startedAt = now
        defaults.removeObject(forKey: defaultsKey)
        persistRun()
    }

    public func reset() { startNewRun() }

    public var completedCount: Int {
        SidebandAcceptanceScenario.allCases.count { result(for: $0).outcome != .notRun }
    }

    public var isReadyForReleaseReview: Bool {
        isPhysicalDevice
            && completedCount == SidebandAcceptanceScenario.allCases.count
            && results.values.allSatisfy { $0.outcome == .passed }
    }

    public func exportData(now: Date = .now) throws -> Data {
        let report = SidebandAcceptanceReport(
            schemaVersion: 2,
            runID: runID,
            startedAt: startedAt,
            generatedAt: now,
            device: deviceDescription,
            platform: platform,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appBuild: appBuild,
            isPhysicalDevice: isPhysicalDevice,
            isReadyForReleaseReview: isReadyForReleaseReview,
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
        persistRun()
    }

    private func persistRun() {
        if let data = try? JSONEncoder().encode(StoredRun(id: runID, startedAt: startedAt)) {
            defaults.set(data, forKey: runKey)
        }
    }

    private var appBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "local"
        return "\(version) (\(build))"
    }
}
