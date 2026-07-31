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

public struct DeliveryReliabilitySnapshot: Equatable, Sendable {
    public enum Health: String, Sendable {
        case healthy, recovering, degraded, needsAttention, offline

        public var title: String {
            switch self {
            case .healthy: "Healthy"
            case .recovering: "Recovering"
            case .degraded: "Degraded"
            case .needsAttention: "Needs attention"
            case .offline: "Offline"
            }
        }
    }

    public struct Interface: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let endpoint: String?
        public let isReady: Bool
        public let connectedAt: Date?
        public let lastPacketAt: Date?

        public init(id: String, name: String, endpoint: String?, isReady: Bool, connectedAt: Date?, lastPacketAt: Date?) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.isReady = isReady
            self.connectedAt = connectedAt
            self.lastPacketAt = lastPacketAt
        }
    }

    public let health: Health
    public let summary: String
    public let recommendedAction: String?
    public let automaticRecoveryEnabled: Bool
    public let queuedCount: Int
    public let awaitingProofCount: Int
    public let deliveredCount: Int
    public let failedCount: Int
    public let deliveryTimeoutCount: Int
    public let recoveredOutboundCount: Int
    public let deferredKeepaliveCount: Int
    public let deferredTunnelCount: Int
    public let knownRouteCount: Int
    public let activeLinkCount: Int
    public let reconnectDelaySeconds: Int?
    public let lastNetworkReadyAt: Date?
    public let interfaces: [Interface]

    public init(
        networkReady: Bool,
        networkConnecting: Bool,
        automaticRecoveryEnabled: Bool,
        queuedCount: Int,
        awaitingProofCount: Int,
        deliveredCount: Int,
        failedCount: Int,
        deliveryTimeoutCount: Int,
        recoveredOutboundCount: Int,
        deferredKeepaliveCount: Int,
        deferredTunnelCount: Int,
        knownRouteCount: Int,
        activeLinkCount: Int,
        reconnectDelaySeconds: Int?,
        lastNetworkReadyAt: Date?,
        interfaces: [Interface]
    ) {
        self.automaticRecoveryEnabled = automaticRecoveryEnabled
        self.queuedCount = queuedCount
        self.awaitingProofCount = awaitingProofCount
        self.deliveredCount = deliveredCount
        self.failedCount = failedCount
        self.deliveryTimeoutCount = deliveryTimeoutCount
        self.recoveredOutboundCount = recoveredOutboundCount
        self.deferredKeepaliveCount = deferredKeepaliveCount
        self.deferredTunnelCount = deferredTunnelCount
        self.knownRouteCount = knownRouteCount
        self.activeLinkCount = activeLinkCount
        self.reconnectDelaySeconds = reconnectDelaySeconds
        self.lastNetworkReadyAt = lastNetworkReadyAt
        self.interfaces = interfaces

        if failedCount > 0 {
            health = .needsAttention
            summary = "(failedCount) message\(failedCount == 1 ? "" : "s") need recovery."
            recommendedAction = networkReady ? "Retry failed deliveries and refresh their routes." : "Reconnect, refresh routes and retry failed deliveries."
        } else if networkConnecting || reconnectDelaySeconds != nil {
            health = .recovering
            summary = reconnectDelaySeconds.map { "Automatic recovery will retry in \($0) seconds." } ?? "Lower Sideband is restoring network connectivity."
            recommendedAction = automaticRecoveryEnabled ? nil : "Enable automatic connection or reconnect now."
        } else if !networkReady {
            health = .offline
            summary = "No Reticulum transport is ready."
            recommendedAction = automaticRecoveryEnabled ? "Check available interfaces if reconnection does not complete." : "Enable automatic connection or reconnect now."
        } else if queuedCount > 0 || awaitingProofCount > 0 {
            health = .degraded
            summary = "Connected; (queuedCount) queued and (awaitingProofCount) awaiting proof."
            recommendedAction = queuedCount > 0 ? "Refresh routes and flush the delivery queue." : nil
        } else {
            health = .healthy
            summary = interfaces.count(where: \.isReady) > 1
                ? "Delivery is ready across multiple transports."
                : "Delivery is ready and no messages need attention."
            recommendedAction = nil
        }
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
