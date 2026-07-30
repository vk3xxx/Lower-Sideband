import Foundation
import Observation
import ReticulumKit

// MARK: - Nomad Network pages

public struct NomadPageAddress: Codable, Hashable, Sendable {
    public static let defaultPath = "/page/index.mu"

    public let destinationHash: String
    public let path: String
    public let query: [String: String]

    public init?(destinationHash: String, path: String = defaultPath, query: [String: String] = [:]) {
        let destination = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(destination) else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard normalizedPath.utf8.count <= 1_024, query.count <= 64,
              query.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4_096 }) else { return nil }
        self.destinationHash = destination
        self.path = normalizedPath
        self.query = query
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("nomadnet://") ? String(trimmed.dropFirst("nomadnet://".count)) : trimmed
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let destination = parts.first else { return nil }
        let pathAndQuery = parts.count > 1 ? "/" + parts[1] : Self.defaultPath
        let urlParts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(urlParts[0])
        var query: [String: String] = [:]
        if urlParts.count > 1 {
            for pair in urlParts[1].split(separator: "&") {
                let values = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = values.first?.removingPercentEncoding, !key.isEmpty else { continue }
                query[key] = values.count > 1 ? (values[1].removingPercentEncoding ?? String(values[1])) : ""
            }
        }
        self.init(destinationHash: String(destination), path: path, query: query)
    }

    public var string: String {
        let encoded = query.sorted(by: { $0.key < $1.key }).map {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&="))
            return "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
        }.joined(separator: "&")
        return "nomadnet://\(destinationHash)\(path)" + (encoded.isEmpty ? "" : "?\(encoded)")
    }
}

public struct NomadPageDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var address: NomadPageAddress?
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        address: NomadPageAddress? = nil,
        source: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.address = address
        self.source = String(source.prefix(1_048_576))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}

public struct NomadPageVisit: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let address: NomadPageAddress
    public let title: String
    public let visitedAt: Date

    public init(id: UUID = UUID(), address: NomadPageAddress, title: String, visitedAt: Date = .now) {
        self.id = id
        self.address = address
        self.title = String(title.prefix(160))
        self.visitedAt = visitedAt
    }
}

public enum MicronBlock: Identifiable, Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case separator
    case link(label: String, target: String)

    public var id: String {
        switch self {
        case .heading(let level, let text): "h\(level):\(text)"
        case .paragraph(let text): "p:\(text)"
        case .separator: "separator"
        case .link(let label, let target): "l:\(label):\(target)"
        }
    }
}

/// A deliberately bounded native parser for the common Micron page primitives.
/// Unknown formatting control sequences are stripped instead of executed.
public enum MicronParser {
    public static func parse(_ source: String) -> [MicronBlock] {
        var blocks: [MicronBlock] = []
        var paragraph: [String] = []
        func flush() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(sanitized(text))) }
            paragraph.removeAll(keepingCapacity: true)
        }
        for rawLine in source.prefix(1_048_576).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "===" { flush(); blocks.append(.separator); continue }
            if line.hasPrefix("#") {
                flush()
                let level = min(3, line.prefix(while: { $0 == "#" }).count)
                blocks.append(.heading(level: level, text: sanitized(line.dropFirst(level).trimmingCharacters(in: .whitespaces))))
                continue
            }
            if let link = parseLink(line) {
                flush(); blocks.append(link); continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func parseLink(_ line: String) -> MicronBlock? {
        // Common Micron links: `[Label`destination:/path`query]
        guard let labelStart = line.firstIndex(of: "["),
              let separator = line[labelStart...].firstIndex(of: "`"),
              let end = line[separator...].lastIndex(of: "]"),
              separator < end else { return nil }
        let label = sanitized(line[line.index(after: labelStart)..<separator])
        let target = String(line[line.index(after: separator)..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard !label.isEmpty, target.utf8.count <= 4_096 else { return nil }
        return .link(label: label, target: target)
    }

    private static func sanitized<S: StringProtocol>(_ value: S) -> String {
        var output = "", escaping = false
        for character in value {
            if escaping { output.append(character); escaping = false; continue }
            if character == "\\" { escaping = true; continue }
            if character == "`" { continue }
            output.append(character)
        }
        return String(output.prefix(16_384))
    }
}

// MARK: - Identities and telephone preferences

public struct SidebandIdentityProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let destinationHash: String
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), name: String, destinationHash: String, createdAt: Date = .now, lastUsedAt: Date = .now) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.destinationHash = destinationHash.lowercased()
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public enum SidebandRingtone: String, Codable, CaseIterable, Sendable, Identifiable {
    case soft, signal, beacon, classic, silent
    public var id: Self { self }
    public var title: String {
        switch self {
        case .soft: "Soft"
        case .signal: "Signal"
        case .beacon: "Beacon"
        case .classic: "Classic"
        case .silent: "Silent"
        }
    }
    public var systemSoundName: String? {
        switch self {
        case .soft: "default"
        case .signal: "default"
        case .beacon: "default"
        case .classic: "default"
        case .silent: nil
        }
    }
}

public struct SidebandTelephonePreferences: Codable, Equatable, Sendable {
    public var ringtone: SidebandRingtone
    public var voicemailEnabled: Bool
    public var voicemailGreeting: String
    public var ringTimeoutSeconds: Int

    public init(
        ringtone: SidebandRingtone = .soft,
        voicemailEnabled: Bool = false,
        voicemailGreeting: String = "I cannot answer this encrypted call. Please leave a voice message.",
        ringTimeoutSeconds: Int = 30
    ) {
        self.ringtone = ringtone
        self.voicemailEnabled = voicemailEnabled
        self.voicemailGreeting = String(voicemailGreeting.prefix(512))
        self.ringTimeoutSeconds = min(90, max(10, ringTimeoutSeconds))
    }
}

@MainActor @Observable
public final class MeshChatFeatureStore {
    public private(set) var pages: [NomadPageDocument] = []
    public private(set) var bookmarks: [NomadPageAddress] = []
    public private(set) var history: [NomadPageVisit] = []
    public private(set) var telephone = SidebandTelephonePreferences()

    private struct Payload: Codable {
        var pages: [NomadPageDocument]
        var bookmarks: [NomadPageAddress]
        var history: [NomadPageVisit]
        var telephone: SidebandTelephonePreferences
    }

    private let cipher: LocalDataCipher
    private let defaults: UserDefaults
    private let storageKey = "meshChatApplicationFeatures.v1"
    private let cipherContext = "meshchat-application-features-v1"

    init(cipher: LocalDataCipher, defaults: UserDefaults = .standard) {
        self.cipher = cipher
        self.defaults = defaults
        load()
    }

    public func savePage(_ page: NomadPageDocument) {
        if let index = pages.firstIndex(where: { $0.id == page.id }) { pages[index] = page }
        else { pages.insert(page, at: 0) }
        pages = Array(pages.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
        persist()
    }

    public func deletePage(_ id: UUID) {
        pages.removeAll { $0.id == id }
        persist()
    }

    public func archivePage(_ id: UUID, archived: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].isArchived = archived
        pages[index].updatedAt = .now
        persist()
    }

    public func recordVisit(address: NomadPageAddress, title: String, source: String) {
        let page = NomadPageDocument(
            title: title.isEmpty ? address.path : title,
            address: address,
            source: source,
            isArchived: false
        )
        savePage(page)
        history.removeAll { $0.address == address }
        history.insert(NomadPageVisit(address: address, title: page.title), at: 0)
        history = Array(history.prefix(250))
        persist()
    }

    public func toggleBookmark(_ address: NomadPageAddress) {
        if let index = bookmarks.firstIndex(of: address) { bookmarks.remove(at: index) }
        else { bookmarks.insert(address, at: 0) }
        bookmarks = Array(bookmarks.prefix(250))
        persist()
    }

    public func clearHistory() { history.removeAll(); persist() }

    public func updateTelephone(_ preferences: SidebandTelephonePreferences) {
        telephone = SidebandTelephonePreferences(
            ringtone: preferences.ringtone,
            voicemailEnabled: preferences.voicemailEnabled,
            voicemailGreeting: preferences.voicemailGreeting,
            ringTimeoutSeconds: preferences.ringTimeoutSeconds
        )
        persist()
    }

    private func load() {
        guard let encrypted = defaults.data(forKey: storageKey),
              let data = try? cipher.open(encrypted, context: cipherContext),
              let payload = try? decoder.decode(Payload.self, from: data) else { return }
        pages = Array(payload.pages.prefix(500))
        bookmarks = Array(payload.bookmarks.prefix(250))
        history = Array(payload.history.prefix(250))
        telephone = payload.telephone
    }

    private func persist() {
        let payload = Payload(pages: pages, bookmarks: bookmarks, history: history, telephone: telephone)
        guard let data = try? encoder.encode(payload),
              let encrypted = try? cipher.seal(data, context: cipherContext) else { return }
        defaults.set(encrypted, forKey: storageKey)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
