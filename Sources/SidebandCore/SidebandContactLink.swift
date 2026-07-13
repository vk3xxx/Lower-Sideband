import Foundation

public struct SidebandContactLink: Equatable, Sendable {
    public static let scheme = "sideband"

    public let destinationHash: String
    public let displayName: String?

    public init?(destinationHash: String, displayName: String? = nil) {
        let normalizedHash = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(normalizedHash) else { return nil }
        self.destinationHash = normalizedHash
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedName?.isEmpty == false ? normalizedName : nil
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "contact" else { return nil }
        let hash = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value
        self.init(destinationHash: hash, displayName: name)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "contact"
        components.path = "/\(destinationHash)"
        if let displayName { components.queryItems = [URLQueryItem(name: "name", value: displayName)] }
        return components.url!
    }
}
