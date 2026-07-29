import Foundation

public struct DeliveryActivityItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case queued, awaitingProof, delivered, failed, diagnostic
    }

    public let id: String
    public let date: Date
    public let kind: Kind
    public let title: String
    public let detail: String
    public let conversationID: UUID?
    public let messageID: UUID?
    public let route: String?

    public init(
        id: String,
        date: Date,
        kind: Kind,
        title: String,
        detail: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        route: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.conversationID = conversationID
        self.messageID = messageID
        self.route = route
    }
}

public enum DeliveryActivityBuilder {
    public static func build(
        messages: [Message],
        conversations: [Conversation],
        diagnostics: [String],
        routes: [String: ConnectedRoute],
        limit: Int = 250
    ) -> [DeliveryActivityItem] {
        let names = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.displayName) })
        let messageItems = messages.lazy
            .filter { $0.direction == .outgoing }
            .map { message -> DeliveryActivityItem in
                let kind: DeliveryActivityItem.Kind
                switch message.state {
                case .queued: kind = .queued
                case .sent: kind = .awaitingProof
                case .delivered: kind = .delivered
                case .failed: kind = .failed
                }
                let name = names[message.conversationID] ?? "Unknown conversation"
                let attempts = max(message.deliveryAttemptCount, message.state == .queued ? 0 : 1)
                let detail = message.lastDeliveryFailure
                    ?? (attempts > 0 ? "\(attempts) delivery attempt\(attempts == 1 ? "" : "s")" : "Waiting for a usable route")
                let route = routes[conversations.first(where: { $0.id == message.conversationID })?.destinationHash ?? ""]
                    .map { route in
                        [route.interfaceName, route.endpoint, "\(route.hops) hop\(route.hops == 1 ? "" : "s")"]
                            .compactMap(\.self).joined(separator: " · ")
                    }
                return DeliveryActivityItem(
                    id: "message-\(message.id.uuidString)",
                    date: message.lastDeliveryAttemptAt ?? message.timestamp,
                    kind: kind,
                    title: "\(stateTitle(message.state)) · \(name)",
                    detail: detail,
                    conversationID: message.conversationID,
                    messageID: message.id,
                    route: route
                )
            }
        let formatter = ISO8601DateFormatter()
        let diagnosticItems = diagnostics.enumerated().map { index, entry -> DeliveryActivityItem in
            let parts = entry.components(separatedBy: " · ")
            let date = parts.first.flatMap(formatter.date(from:)) ?? .distantPast
            return DeliveryActivityItem(
                id: "diagnostic-\(index)-\(entry.hashValue)",
                date: date,
                kind: .diagnostic,
                title: "Network delivery event",
                detail: parts.dropFirst().joined(separator: " · ")
            )
        }
        return Array((Array(messageItems) + diagnosticItems)
            .sorted { $0.date > $1.date }
            .prefix(max(1, limit)))
    }

    private static func stateTitle(_ state: Message.DeliveryState) -> String {
        switch state {
        case .queued: "Queued"
        case .sent: "Awaiting proof"
        case .delivered: "Delivered"
        case .failed: "Needs attention"
        }
    }
}
