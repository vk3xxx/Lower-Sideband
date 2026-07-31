import Foundation

public struct ReticulumServiceLink: Codable, Hashable, Sendable {
    public static let scheme = "sideband"

    public let kind: ReticulumApplicationServiceKind
    public let destinationHash: String
    public let name: String?
    public let path: String?
    public let room: String?

    public init?(
        kind: ReticulumApplicationServiceKind,
        destinationHash: String,
        name: String? = nil,
        path: String? = nil,
        room: String? = nil
    ) {
        let destination = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(destination) else { return nil }
        self.kind = kind
        self.destinationHash = destination
        self.name = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        self.path = path.map { String($0.prefix(1_024)) }
        self.room = room.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128)) }
    }

    public init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "nomadnet", let address = NomadPageAddress(string: url.absoluteString) {
            self.init(kind: .nomad, destinationHash: address.destinationHash, path: address.path)
            return
        }
        if scheme == "rrc", let invitation = RelayRoomInvitation(string: url.absoluteString) {
            self.init(kind: .relay, destinationHash: invitation.hubDestinationHash, room: invitation.room)
            return
        }
        guard scheme == Self.scheme,
              url.host?.lowercased() == "service" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count >= 2,
              let kind = ReticulumApplicationServiceKind(rawValue: segments[0]) else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        self.init(
            kind: kind,
            destinationHash: segments[1],
            name: query.first { $0.name == "name" }?.value,
            path: query.first { $0.name == "path" }?.value,
            room: query.first { $0.name == "room" }?.value
        )
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "service"
        components.path = "/\(kind.rawValue)/\(destinationHash)"
        components.queryItems = [
            name.map { URLQueryItem(name: "name", value: $0) },
            path.map { URLQueryItem(name: "path", value: $0) },
            room.map { URLQueryItem(name: "room", value: $0) }
        ].compactMap(\.self)
        return components.url!
    }
}

public enum ApplicationServicePermission: String, Codable, CaseIterable, Sendable, Identifiable {
    case browsePages
    case joinRooms
    case openShell
    case executeCommands
    case sendFiles
    case fetchFiles

    public var id: Self { self }
    public var title: String {
        switch self {
        case .browsePages: "Browse pages"
        case .joinRooms: "Join room invitations"
        case .openShell: "Open a remote shell"
        case .executeCommands: "Execute remote commands"
        case .sendFiles: "Send files"
        case .fetchFiles: "Fetch files"
        }
    }
    public var systemImage: String {
        switch self {
        case .browsePages: "doc.richtext"
        case .joinRooms: "person.3"
        case .openShell: "terminal"
        case .executeCommands: "play.rectangle"
        case .sendFiles: "arrow.up.doc"
        case .fetchFiles: "arrow.down.doc"
        }
    }
    public static func permissions(for kind: ReticulumApplicationServiceKind) -> [Self] {
        switch kind {
        case .nomad: [.browsePages]
        case .relay: [.joinRooms]
        case .shell: [.openShell]
        case .execution: [.executeCommands]
        case .copy: [.sendFiles, .fetchFiles]
        }
    }
}

public struct ApplicationServiceAuthorization: Codable, Hashable, Sendable, Identifiable {
    public var id: String { destinationHash }
    public let destinationHash: String
    public var permissions: Set<ApplicationServicePermission>
    public var updatedAt: Date

    public init(destinationHash: String, permissions: Set<ApplicationServicePermission>, updatedAt: Date = .now) {
        self.destinationHash = destinationHash.lowercased()
        self.permissions = permissions
        self.updatedAt = updatedAt
    }
}

public struct ApplicationServiceAcceptanceStage: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case passed, failed, skipped }
    public let name: String
    public let state: State
    public let durationMilliseconds: Int?
    public let detail: String
    public var id: String { name }
}

public struct ApplicationServiceAcceptanceReport: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let generatedAt: Date
    public let kind: ReticulumApplicationServiceKind
    public let destinationReference: String
    public let stages: [ApplicationServiceAcceptanceStage]

    public init(
        id: UUID = UUID(),
        generatedAt: Date = .now,
        kind: ReticulumApplicationServiceKind,
        destinationReference: String,
        stages: [ApplicationServiceAcceptanceStage]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.kind = kind
        self.destinationReference = destinationReference
        self.stages = stages
    }

    public var passed: Bool { !stages.contains { $0.state == .failed } }

    public var redactedText: String {
        let timestamp = ISO8601DateFormatter().string(from: generatedAt)
        let lines = stages.map {
            "[\($0.state.rawValue.uppercased())] \($0.name)"
                + ($0.durationMilliseconds.map { " · \($0) ms" } ?? "")
                + " · \($0.detail)"
        }
        return SidebandSupportRedactor.redact(
            ([
                "Lower Sideband service acceptance report",
                "Generated: \(timestamp)",
                "Service: \(kind.title)",
                "Destination: \(destinationReference)",
                "Result: \(passed ? "PASS" : "FAIL")"
            ] + lines).joined(separator: "\n")
        )
    }
}
