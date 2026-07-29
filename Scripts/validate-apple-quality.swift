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
        "Remote message wakes", "Background delivery", "Register This Device"
    ] where strings[key] == nil {
        findings.append("Missing localisable critical string: \(key)")
    }
} catch {
    findings.append("String catalog validation failed: \(error)")
}

let content = try text("Sources/SidebandMac/ContentView.swift")
let map = try text("Sources/SidebandMac/NetworkMapView.swift")
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
