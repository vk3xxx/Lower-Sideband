import Foundation

public struct SidebandContinuityDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let lastSeen: Date
    public let isCurrent: Bool
    public let queuedMessageCount: Int

    public init(id: String, name: String, lastSeen: Date, isCurrent: Bool, queuedMessageCount: Int) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
        self.isCurrent = isCurrent
        self.queuedMessageCount = queuedMessageCount
    }
}

public enum ContinuityDeviceBuilder {
    public static func build(
        currentID: String,
        knownDevices: [String: Date],
        messages: [Message]
    ) -> [SidebandContinuityDevice] {
        var sightings = knownDevices
        sightings[currentID] = max(sightings[currentID] ?? .distantPast, .now)
        for message in messages {
            if let owner = message.outboxOwnerID {
                sightings[owner] = max(sightings[owner] ?? .distantPast, message.outboxOwnerUpdatedAt ?? message.timestamp)
            }
        }
        return sightings.map { id, seen in
            let suffix = id.replacingOccurrences(of: "-", with: "").suffix(6).uppercased()
            return SidebandContinuityDevice(
                id: id,
                name: id == currentID ? "This device" : "Synced device \(suffix)",
                lastSeen: seen,
                isCurrent: id == currentID,
                queuedMessageCount: messages.count {
                    $0.direction == .outgoing && $0.outboxOwnerID == id && ($0.state == .queued || $0.state == .failed)
                }
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.lastSeen > $1.lastSeen
        }
    }
}
