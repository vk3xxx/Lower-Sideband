import Foundation

public struct SidebandContactLink: Equatable, Sendable {
    public static let scheme = "sideband"
    private static let deliveryNameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))

    public let destinationHash: String
    public let displayName: String?
    /// The Reticulum identity public key bound to `destinationHash`, when supplied by the contact.
    public let publicKey: Data?

    public init?(destinationHash: String, displayName: String? = nil, publicKey: Data? = nil) {
        let normalizedHash = destinationHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DestinationHash.isValid(normalizedHash) else { return nil }
        if let publicKey {
            guard let identity = try? ReticulumIdentity(publicKey: publicKey),
                  ReticulumIdentity.truncatedHash(Self.deliveryNameHash + identity.hash).map({ String(format: "%02x", $0) }).joined() == normalizedHash else { return nil }
        }
        self.destinationHash = normalizedHash
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedName?.isEmpty == false ? normalizedName : nil
        self.publicKey = publicKey
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "contact" else { return nil }
        let hash = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let name = queryItems?.first(where: { $0.name == "name" })?.value
        let encodedKey = queryItems?.first(where: { $0.name == "key" })?.value
        let publicKey: Data?
        if let encodedKey {
            guard let decoded = Self.decodeBase64URL(encodedKey) else { return nil }
            publicKey = decoded
        } else {
            publicKey = nil
        }
        self.init(destinationHash: hash, displayName: name, publicKey: publicKey)
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
        var queryItems: [URLQueryItem] = []
        if let displayName { queryItems.append(URLQueryItem(name: "name", value: displayName)) }
        if let publicKey { queryItems.append(URLQueryItem(name: "key", value: Self.encodeBase64URL(publicKey))) }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return components.url!
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Creates a user-initiated abuse report without attaching message content,
/// attachments, telemetry, contact notes, or cryptographic key material.
public enum SidebandSafetyReport {
    public static let supportEmail = "sepus@hotmail.com"

    public static func emailURL(for conversation: Conversation, message: Message? = nil) -> URL? {
        var lines = [
            "I want to report objectionable or abusive activity in Lower Sideband.",
            "",
            "Reason (please describe):",
            "",
            "Contact destination: \(conversation.destinationHash)",
        ]
        if let message {
            lines.append("Message reference: \(message.lxmfID.map(hex) ?? message.id.uuidString.lowercased())")
            lines.append("Message received/sent: \(message.timestamp.formatted(.iso8601))")
        }
        lines += [
            "",
            "No message text, attachment, telemetry, private key, or contact note was attached automatically. Add only information you are comfortable sharing.",
        ]

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: message == nil ? "Lower Sideband contact report" : "Lower Sideband content report"),
            URLQueryItem(name: "body", value: lines.joined(separator: "\n")),
        ]
        return components.url
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
