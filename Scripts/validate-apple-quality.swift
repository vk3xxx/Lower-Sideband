#!/usr/bin/env swift

import Foundation

enum AuditFailure: Error, CustomStringConvertible {
    case failed([String])
    var description: String {
        switch self { case .failed(let findings): findings.joined(separator: "\n") }
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func data(_ path: String) throws -> Data { try Data(contentsOf: root.appending(path: path)) }
func text(_ path: String) throws -> String { String(decoding: try data(path), as: UTF8.self) }
var findings: [String] = []

do {
    let object = try JSONSerialization.jsonObject(with: data("Support/Localizable.xcstrings"))
    guard let catalog = object as? [String: Any],
          catalog["sourceLanguage"] as? String == "en",
          let strings = catalog["strings"] as? [String: Any] else {
        throw AuditFailure.failed(["The shared string catalog is not a valid English-source catalog."])
    }
    for key in [
        "Lower Sideband", "New conversation", "Message", "Send message",
        "Settings", "Network Settings", "Connecting securely", "Current route: %@",
        "Import Python Sideband Database", "Undo Last Python Import",
        "Remote message wakes", "Background delivery", "Register This Device",
        "Migration & Restore", "Export Redacted Support Report",
        "Apple device acceptance", "Export Acceptance Report",
        "Release evidence", "Start New Acceptance Run",
        "Accessibility and input", "Assistive technology",
        "Keyboard and pointer", "Adaptive layout and appearance", "Language and layout",
        "Memory, power and endurance"
    ] where strings[key] == nil {
        findings.append("Missing localisable critical string: \(key)")
    }
    if strings.keys.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        findings.append("String catalog contains an empty or whitespace-only key.")
    }
} catch {
    findings.append("String catalog validation failed: \(error)")
}

let content = try text("Sources/SidebandMac/ContentView.swift")
let map = try text("Sources/SidebandMac/NetworkMapView.swift")
let settings = try text("Sources/SidebandMac/SidebandSettingsView.swift")
for identifier in [
    "app-settings", "new-conversation", "new-conversation-address",
    "create-conversation", "message-search", "message-composer", "send-message"
] where !content.contains("accessibilityIdentifier(\"\(identifier)\")") {
    findings.append("Missing critical accessibility identifier: \(identifier)")
}
for identifier in ["network-map-full-screen", "network-map-toggle-destinations"]
where !map.contains("accessibilityIdentifier(\"\(identifier)\")") {
    findings.append("Missing network-map accessibility identifier: \(identifier)")
}
for identifier in [
    "settings-navigation", "export-redacted-support-report",
    "export-device-acceptance-report"
] where !settings.contains("accessibilityIdentifier(\"\(identifier)\")") {
    findings.append("Missing settings accessibility identifier: \(identifier)")
}
for identifier in ["legacy-migration-centre", "legacy-migration-import"]
where !content.contains("accessibilityIdentifier(\"\(identifier)\")") {
    findings.append("Missing migration accessibility identifier: \(identifier)")
}
if !map.contains("@Environment(\\.accessibilityReduceMotion)") {
    findings.append("Network map does not respect Reduce Motion.")
}
if !map.contains("@Environment(\\.accessibilityDifferentiateWithoutColor)") {
    findings.append("Network map does not support Differentiate Without Color.")
}
let acceptanceSource = try text("Sources/SidebandCore/DeviceAcceptance.swift")
for scenario in [
    "messaging", "attachments", "voice", "telemetry", "backgroundRecovery",
    "capturePermissions", "networkHandover", "accessibility", "localization", "endurance"
] + [
    "assistiveTechnology", "keyboardAndPointer", "adaptiveLayout"
] where !acceptanceSource.contains("case \(scenario)") {
    findings.append("Acceptance workflow is missing the \(scenario) scenario.")
}

do {
    let policyObject = try JSONSerialization.jsonObject(with: data("Support/AppleExperienceCertification.json"))
    guard let policy = policyObject as? [String: Any],
          policy["schemaVersion"] as? Int == 1,
          Set(policy["requiredPlatforms"] as? [String] ?? []) == Set(["mac", "iPhone", "iPad"]),
          let accessibility = policy["accessibility"] as? [String: Any],
          Set(accessibility["assistiveTechnologies"] as? [String] ?? []) == Set(["VoiceOver", "Voice Control", "Switch Control"]),
          (accessibility["dynamicTypeSizes"] as? [String] ?? []).contains("AX5"),
          Set(accessibility["inputMethods"] as? [String] ?? []).isSuperset(of: ["touch", "pointer", "hardwareKeyboard"]),
          let localization = policy["localization"] as? [String: Any],
          Set(localization["requiredLocales"] as? [String] ?? []).isSuperset(of: ["en-AU", "de-DE", "ar"]),
          let endurance = policy["endurance"] as? [String: Any],
          (endurance["minimumHours"] as? Int ?? 0) >= 8,
          (endurance["minimumMessages"] as? Int ?? 0) >= 10_000,
          (endurance["minimumAttachments"] as? Int ?? 0) >= 100,
          (endurance["maximumMemoryGrowthPercent"] as? Int ?? 100) <= 15,
          endurance["requiresZeroCrashes"] as? Bool == true,
          endurance["requiresZeroMemoryWarnings"] as? Bool == true else {
        throw AuditFailure.failed(["Apple experience certification policy is incomplete or below its production thresholds."])
    }
} catch {
    findings.append("Apple experience certification policy validation failed: \(error)")
}
if !settings.contains("accessibilityIdentifier(\"acceptance-\\(scenario.rawValue)\")") {
    findings.append("Acceptance workflow does not expose stable per-scenario accessibility identifiers.")
}

do {
    let manifestObject = try JSONSerialization.jsonObject(with: data("Support/UpstreamCompatibility.json"))
    guard let manifest = manifestObject as? [String: Any],
          manifest["schema"] as? Int == 1,
          let references = manifest["references"] as? [[String: Any]],
          Set(references.compactMap { $0["name"] as? String }) == Set(["Reticulum", "LXMF", "Sideband"]),
          references.allSatisfy({
              ($0["version"] as? String)?.isEmpty == false
                  && ($0["commit"] as? String)?.count == 40
          }) else {
        throw AuditFailure.failed(["Upstream compatibility manifest is incomplete or invalid."])
    }
} catch {
    findings.append("Upstream compatibility manifest validation failed: \(error)")
}

let workflow = try text(".github/workflows/upstream-compatibility.yml")
if workflow.contains("push:") || workflow.contains("pull_request:") {
    findings.append("Upstream compatibility workflow must remain scheduled/manual and must not build every commit.")
}

let info = try PropertyListSerialization.propertyList(
    from: data("Support/Sideband-iOS-Info.plist"), options: [], format: nil
) as? [String: Any]
for key in [
    "NSBluetoothAlwaysUsageDescription", "NSCameraUsageDescription",
    "NSLocalNetworkUsageDescription", "NSLocationWhenInUseUsageDescription",
    "NSMicrophoneUsageDescription"
] where (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
    findings.append("Missing iOS privacy purpose string: \(key)")
}
let backgroundModes = Set(info?["UIBackgroundModes"] as? [String] ?? [])
for mode in ["bluetooth-central", "fetch", "processing", "remote-notification"]
where !backgroundModes.contains(mode) {
    findings.append("Missing required iOS background mode: \(mode)")
}

let entitlements = try PropertyListSerialization.propertyList(
    from: data("Support/Sideband-iOS.entitlements"), options: [], format: nil
) as? [String: Any]
if entitlements?["aps-environment"] == nil { findings.append("Push notification entitlement is missing.") }
if (entitlements?["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") != true {
    findings.append("CloudKit entitlement is missing.")
}

let appSource = try text("Sources/SidebandMac/SidebandMacApp.swift")
for marker in ["MetricKitMonitor.shared.install", "applicationDidReceiveMemoryWarning", "didReceiveRemoteNotification"]
where !appSource.contains(marker) {
    findings.append("Missing production lifecycle integration: \(marker)")
}

guard findings.isEmpty else { throw AuditFailure.failed(findings) }
print("Apple quality audit passed: localisation, accessibility, privacy, background, CloudKit and MetricKit gates are present.")
