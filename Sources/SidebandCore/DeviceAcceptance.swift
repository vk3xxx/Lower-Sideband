import Foundation
import Observation
import ReticulumKit
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

public struct SidebandAcceptanceEnvironment: Codable, Sendable, Equatable {
    public let localeIdentifier: String
    public let preferredLanguages: [String]
    public let lowPowerModeEnabled: Bool
    public let thermalState: Int
    public let physicalMemoryBytes: UInt64
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
    public var environment: SidebandAcceptanceEnvironment? = nil

    public var passedCount: Int { results.values.count { $0.outcome == .passed } }
    public var failedCount: Int { results.values.count { $0.outcome == .failed } }
}

public struct SidebandAcceptanceCampaignAssessment: Sendable, Equatable {
    public let build: String
    public let blockingReasons: [String]

    public var isCertified: Bool { blockingReasons.isEmpty }
}

public struct SidebandSignedAcceptanceReport: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let report: SidebandAcceptanceReport
    public let signerPublicKey: Data
    public let signature: Data

    public var id: UUID { report.runID }
    public var signerFingerprint: String {
        ReticulumIdentity.fingerprint(of: signerPublicKey) ?? "Invalid signer"
    }

    public static func signed(
        report: SidebandAcceptanceReport,
        identity: ReticulumIdentity
    ) throws -> Self {
        let payload = try canonicalData(for: report)
        return Self(
            schemaVersion: 1,
            report: report,
            signerPublicKey: identity.publicKey,
            signature: try identity.sign(payload)
        )
    }

    public var isValid: Bool {
        guard schemaVersion == 1,
              let identity = try? ReticulumIdentity(publicKey: signerPublicKey),
              let payload = try? Self.canonicalData(for: report) else { return false }
        return identity.validate(signature: signature, message: payload)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    private static func canonicalData(for report: SidebandAcceptanceReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

public enum SidebandAcceptancePortfolioError: LocalizedError {
    case invalidSignature
    case incompatibleSchema

    public var errorDescription: String? {
        switch self {
        case .invalidSignature: "The acceptance report signature is invalid."
        case .incompatibleSchema: "This acceptance report format is not supported."
        }
    }
}

@MainActor @Observable
public final class SidebandAcceptancePortfolio {
    public private(set) var reports: [SidebandSignedAcceptanceReport] = []
    private let defaults: UserDefaults
    private let cipher: LocalDataCipher
    private let storageKey = "deviceAcceptancePortfolio.v1"
    private let context = "device-acceptance-portfolio-v1"

    init(defaults: UserDefaults = .standard, cipher: LocalDataCipher) {
        self.defaults = defaults
        self.cipher = cipher
        guard let encrypted = defaults.data(forKey: storageKey),
              let plaintext = try? cipher.open(encrypted, context: context),
              let decoded = try? Self.decoder.decode([SidebandSignedAcceptanceReport].self, from: plaintext) else {
            return
        }
        reports = Array(decoded.filter { $0.isValid }.prefix(1_000))
    }

    @discardableResult
    public func importReport(_ data: Data) throws -> SidebandSignedAcceptanceReport {
        let report = try SidebandSignedAcceptanceReport.decoded(from: data)
        return try importVerified(report)
    }

    /// Imports a portable campaign containing reports from several Apple
    /// devices. Every entry is independently verified before any state is
    /// changed, so a corrupt report cannot partially update the dashboard.
    @discardableResult
    public func importReports(_ data: Data) throws -> [SidebandSignedAcceptanceReport] {
        if let single = try? SidebandSignedAcceptanceReport.decoded(from: data) {
            return [try importVerified(single)]
        }
        let decoded = try Self.decoder.decode([SidebandSignedAcceptanceReport].self, from: data)
        guard !decoded.isEmpty, decoded.allSatisfy({ $0.schemaVersion == 1 && $0.isValid }) else {
            throw SidebandAcceptancePortfolioError.invalidSignature
        }
        for report in decoded.reversed() { _ = try importVerified(report, persistAfterImport: false) }
        persist()
        return decoded
    }

    public func exportReports(build: String? = nil) throws -> Data {
        let selected = build.map { value in reports.filter { $0.report.appBuild == value } } ?? reports
        return try Self.encoder.encode(selected)
    }

    public func removeAll() {
        reports.removeAll()
        defaults.removeObject(forKey: storageKey)
    }

    public var latestByPlatform: [SidebandAcceptancePlatform: SidebandSignedAcceptanceReport] {
        Dictionary(grouping: reports, by: \.report.platform).compactMapValues {
            $0.max { $0.report.generatedAt < $1.report.generatedAt }
        }
    }

    public var completeBuilds: [String] {
        Set(reports.map(\.report.appBuild))
            .filter { assessment(forBuild: $0).isCertified }
            .sorted(by: Self.compareBuilds)
    }

    public var latestCompleteBuild: String? { completeBuilds.last }

    public var allPrimaryPlatformsReady: Bool {
        latestCompleteBuild != nil
    }

    public func latestByPlatform(forBuild build: String) -> [SidebandAcceptancePlatform: SidebandSignedAcceptanceReport] {
        Dictionary(grouping: reports.filter { $0.report.appBuild == build }, by: \.report.platform).compactMapValues {
            $0.max { $0.report.generatedAt < $1.report.generatedAt }
        }
    }

    public func assessment(forBuild build: String) -> SidebandAcceptanceCampaignAssessment {
        let required: [SidebandAcceptancePlatform] = [.mac, .iPhone, .iPad]
        let latest = latestByPlatform(forBuild: build)
        var reasons: [String] = []
        let expectedScenarios = Set(SidebandAcceptanceScenario.allCases.map(\.rawValue))

        for platform in required {
            guard let signed = latest[platform] else {
                reasons.append("Missing signed physical \(platform.title) report.")
                continue
            }
            let report = signed.report
            if !signed.isValid { reasons.append("\(platform.title) report signature is invalid.") }
            if report.schemaVersion < 3 { reasons.append("\(platform.title) report predates environment-certified schema 3.") }
            if !report.isPhysicalDevice { reasons.append("\(platform.title) evidence came from a simulator or unsupported environment.") }
            if !report.isReadyForReleaseReview { reasons.append("\(platform.title) did not pass every acceptance scenario.") }
            if report.operatingSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("\(platform.title) operating-system evidence is missing.")
            }
            if report.generatedAt < report.startedAt {
                reasons.append("\(platform.title) report timestamps are inconsistent.")
            }
            if report.environment == nil {
                reasons.append("\(platform.title) environment evidence is missing.")
            }
            if Set(report.results.keys) != expectedScenarios {
                reasons.append("\(platform.title) scenario coverage is incomplete.")
            }
            for scenario in SidebandAcceptanceScenario.allCases {
                guard let result = report.results[scenario.rawValue] else { continue }
                if result.outcome != .passed
                    || result.build != build
                    || result.operatingSystem != report.operatingSystem
                    || result.testedAt == nil
                    || result.testedAt! < report.startedAt
                    || result.testedAt! > report.generatedAt {
                    reasons.append("\(platform.title) has invalid evidence for \(scenario.title).")
                }
            }
        }
        return SidebandAcceptanceCampaignAssessment(build: build, blockingReasons: reasons)
    }

    private func importVerified(
        _ report: SidebandSignedAcceptanceReport,
        persistAfterImport: Bool = true
    ) throws -> SidebandSignedAcceptanceReport {
        guard report.schemaVersion == 1 else { throw SidebandAcceptancePortfolioError.incompatibleSchema }
        guard report.isValid else { throw SidebandAcceptancePortfolioError.invalidSignature }
        reports.removeAll { $0.id == report.id }
        reports.insert(report, at: 0)
        reports = Array(reports.prefix(1_000))
        if persistAfterImport { persist() }
        return report
    }

    private static func compareBuilds(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    private func persist() {
        guard let plaintext = try? Self.encoder.encode(reports),
              let encrypted = try? cipher.seal(plaintext, context: context) else { return }
        defaults.set(encrypted, forKey: storageKey)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
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
        let report = makeReport(now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public func makeReport(now: Date = .now) -> SidebandAcceptanceReport {
        SidebandAcceptanceReport(
            schemaVersion: 3,
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
            }),
            environment: SidebandAcceptanceEnvironment(
                localeIdentifier: Locale.current.identifier,
                preferredLanguages: Array(Locale.preferredLanguages.prefix(10)),
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            )
        )
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
