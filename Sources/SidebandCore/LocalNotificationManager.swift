import Foundation
import Observation
@preconcurrency import UserNotifications

@MainActor @Observable
public final class LocalNotificationManager {
    public private(set) var isEnabled: Bool
    public private(set) var authorizationDescription = "Not requested"
    public private(set) var scheduledCount = 0

    public init() {
        isEnabled = UserDefaults.standard.bool(forKey: "sidebandNotificationsEnabled")
        authorizationDescription = isEnabled ? "Enabled" : "Not requested"
    }

    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                isEnabled = granted
            } catch { isEnabled = false }
        } else { isEnabled = false }
        UserDefaults.standard.set(isEnabled, forKey: "sidebandNotificationsEnabled")
        await refreshAuthorization()
    }

    public func notifyIncoming(title: String, body: String) async {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            scheduledCount += 1
        } catch { }
    }

    public func setBadgeCount(_ count: Int) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do { try await UNUserNotificationCenter.current().setBadgeCount(max(0, count)) } catch { }
    }

    private func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorizationDescription = switch status {
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .ephemeral: "Ephemeral"
        @unknown default: "Unknown"
        }
    }
}
