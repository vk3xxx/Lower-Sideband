import Foundation
import Observation
@preconcurrency import UserNotifications

@MainActor @Observable
public final class LocalNotificationManager {
    public nonisolated static let messageCategoryIdentifier = "SIDEBAND_MESSAGE"
    public nonisolated static let markReadActionIdentifier = "SIDEBAND_MARK_READ"
    public nonisolated static let replyActionIdentifier = "SIDEBAND_REPLY"
    public nonisolated static let conversationIDUserInfoKey = "sidebandConversationID"
    public nonisolated static let messageIDUserInfoKey = "sidebandMessageID"

    public private(set) var isEnabled: Bool
    public private(set) var showPreviews: Bool
    public private(set) var playSounds: Bool
    public private(set) var authorizationDescription = "Not requested"
    public private(set) var scheduledCount = 0
    public private(set) var lastError: String?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "sidebandNotificationsEnabled")
        showPreviews = defaults.object(forKey: "sidebandNotificationPreviews") as? Bool ?? false
        playSounds = defaults.object(forKey: "sidebandNotificationSounds") as? Bool ?? true
        authorizationDescription = isEnabled ? "Enabled" : "Not requested"
    }

    public func prepare() async {
        let markRead = UNNotificationAction(
            identifier: Self.markReadActionIdentifier,
            title: "Mark as Read",
            options: [.authenticationRequired]
        )
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let category = UNNotificationCategory(
            identifier: Self.messageCategoryIdentifier,
            actions: [reply, markRead],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        await refreshAuthorization()
    }

    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                isEnabled = granted
                lastError = granted ? nil : "Notifications were not authorized in System Settings."
            } catch {
                isEnabled = false
                lastError = error.localizedDescription
            }
        } else { isEnabled = false }
        defaults.set(isEnabled, forKey: "sidebandNotificationsEnabled")
        await refreshAuthorization()
    }

    public func setShowPreviews(_ enabled: Bool) {
        showPreviews = enabled
        defaults.set(enabled, forKey: "sidebandNotificationPreviews")
    }

    public func setPlaySounds(_ enabled: Bool) {
        playSounds = enabled
        defaults.set(enabled, forKey: "sidebandNotificationSounds")
    }

    public func notifyIncoming(
        conversationID: UUID,
        messageID: UUID,
        title: String,
        body: String,
        isAttachment: Bool = false,
        showPreview: Bool? = nil
    ) async {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        if showPreview ?? showPreviews {
            content.title = title
            content.body = body.isEmpty && isAttachment ? "Sent an attachment" : body
        } else {
            content.title = "New Lower Sideband message"
            content.body = "Open Lower Sideband to view it."
        }
        content.sound = playSounds ? .default : nil
        content.categoryIdentifier = Self.messageCategoryIdentifier
        content.threadIdentifier = conversationID.uuidString
        content.targetContentIdentifier = conversationID.uuidString
        content.userInfo = [
            Self.conversationIDUserInfoKey: conversationID.uuidString,
            Self.messageIDUserInfoKey: messageID.uuidString
        ]
        let request = UNNotificationRequest(identifier: messageID.uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            scheduledCount += 1
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func notifyIncomingCall(conversationID: UUID, callerName: String) async {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = showPreviews ? callerName : "Incoming Lower Sideband call"
        content.body = showPreviews ? "Incoming encrypted voice call" : "Open Lower Sideband to answer."
        content.sound = playSounds ? .default : nil
        content.categoryIdentifier = Self.messageCategoryIdentifier
        content.threadIdentifier = conversationID.uuidString
        content.targetContentIdentifier = conversationID.uuidString
        content.userInfo = [Self.conversationIDUserInfoKey: conversationID.uuidString]
        let request = UNNotificationRequest(identifier: "voice-call-\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            scheduledCount += 1
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    public func removeNotifications(for conversationID: UUID) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let conversationValue = conversationID.uuidString
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.compactMap { notification in
            notification.request.content.userInfo[Self.conversationIDUserInfoKey] as? String == conversationValue
                ? notification.request.identifier
                : nil
        }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.compactMap { request in
            request.content.userInfo[Self.conversationIDUserInfoKey] as? String == conversationValue
                ? request.identifier
                : nil
        }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
    }

    public func setBadgeCount(_ count: Int) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do { try await UNUserNotificationCenter.current().setBadgeCount(max(0, count)) } catch { }
    }

    public func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorizationDescription = switch status {
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .ephemeral: "Ephemeral"
        @unknown default: "Unknown"
        }
        if status == .denied {
            isEnabled = false
            defaults.set(false, forKey: "sidebandNotificationsEnabled")
        }
    }
}
