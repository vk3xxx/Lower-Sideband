import Foundation
import ReticulumKit

/// A signed, operator-controlled directory for Lower Sideband infrastructure.
///
/// The app never trusts the transport used to download this document. The
/// embedded Reticulum identity signature is the authority, which also makes a
/// cached manifest safe to use while the directory service is unavailable.
public struct ManagedInfrastructureManifest: Codable, Equatable, Sendable {
    public struct Gateway: Codable, Equatable, Sendable {
        public let name: String
        public let host: String
        public let port: UInt16
        public let priority: Int
        public let backboneTransportIdentity: String?

        public init(name: String, host: String, port: UInt16, priority: Int = 100, backboneTransportIdentity: String? = nil) {
            self.name = name
            self.host = host
            self.port = port
            self.priority = priority
            self.backboneTransportIdentity = backboneTransportIdentity
        }
    }

    public struct PropagationNode: Codable, Equatable, Sendable {
        public let name: String
        public let destinationHash: String
        public let priority: Int

        public init(name: String, destinationHash: String, priority: Int = 100) {
            self.name = name
            self.destinationHash = destinationHash
            self.priority = priority
        }
    }

    public let schemaVersion: Int
    public let issuedAt: Date
    public let expiresAt: Date
    public let gateways: [Gateway]
    public let propagationNodes: [PropagationNode]
    public let wakeRegistrationURL: URL?

    public init(
        schemaVersion: Int = 1,
        issuedAt: Date,
        expiresAt: Date,
        gateways: [Gateway],
        propagationNodes: [PropagationNode] = [],
        wakeRegistrationURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.gateways = gateways
        self.propagationNodes = propagationNodes
        self.wakeRegistrationURL = wakeRegistrationURL
    }
}

public struct SignedManagedInfrastructureManifest: Codable, Equatable, Sendable {
    public let manifest: ManagedInfrastructureManifest
    /// Reticulum Ed25519 signature encoded as lowercase hexadecimal.
    public let signature: String

    public init(manifest: ManagedInfrastructureManifest, signature: String) {
        self.manifest = manifest
        self.signature = signature
    }
}

public actor ManagedInfrastructureDirectory {
    public struct Snapshot: Equatable, Sendable {
        public let manifest: ManagedInfrastructureManifest
        public let gateways: [InternetGateway]
        public let refreshedAt: Date
    }

    public enum DirectoryError: LocalizedError, Equatable {
        case invalidURL
        case invalidResponse
        case unexpectedEndpoint
        case invalidPublicKey
        case invalidSignature
        case invalidManifest(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a valid HTTPS managed-infrastructure URL."
            case .invalidResponse: "The managed infrastructure service returned an invalid response."
            case .unexpectedEndpoint: "The managed infrastructure service redirected to an untrusted endpoint."
            case .invalidPublicKey: "Enter the trusted operator identity public key (128 hexadecimal characters)."
            case .invalidSignature: "The managed infrastructure manifest signature is invalid."
            case .invalidManifest(let reason): "The managed infrastructure manifest is invalid: \(reason)"
            }
        }
    }

    private let session: URLSession
    private var cached: Snapshot?
    private let cacheLifetime: TimeInterval

    public init(cacheLifetime: TimeInterval = 15 * 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
        self.cacheLifetime = cacheLifetime
    }

    public func snapshot(
        url: URL,
        trustedPublicKey: Data,
        forceRefresh: Bool = false,
        now: Date = .now
    ) async throws -> Snapshot {
        if !forceRefresh, let cached,
           now.timeIntervalSince(cached.refreshedAt) < cacheLifetime,
           cached.manifest.expiresAt > now {
            return cached
        }
        let refreshed = try await refresh(url: url, trustedPublicKey: trustedPublicKey, now: now)
        cached = refreshed
        return refreshed
    }

    public func refresh(url: URL, trustedPublicKey: Data, now: Date = .now) async throws -> Snapshot {
        guard url.scheme?.lowercased() == "https", let expectedHost = url.host?.lowercased() else {
            throw DirectoryError.invalidURL
        }
        guard trustedPublicKey.count == 64,
              (try? ReticulumIdentity(publicKey: trustedPublicKey)) != nil else {
            throw DirectoryError.invalidPublicKey
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lower-Sideband/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard data.count <= 64 * 1_024,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DirectoryError.invalidResponse
        }
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == expectedHost else {
            throw DirectoryError.unexpectedEndpoint
        }
        let envelope = try Self.decoder.decode(SignedManagedInfrastructureManifest.self, from: data)
        return try Self.verify(envelope, trustedPublicKey: trustedPublicKey, now: now)
    }

    public static func verify(
        _ envelope: SignedManagedInfrastructureManifest,
        trustedPublicKey: Data,
        now: Date = .now
    ) throws -> Snapshot {
        guard trustedPublicKey.count == 64,
              let identity = try? ReticulumIdentity(publicKey: trustedPublicKey) else {
            throw DirectoryError.invalidPublicKey
        }
        let payload = try Self.encoder.encode(envelope.manifest)
        guard let signature = Data(strictHex: envelope.signature),
              identity.validate(signature: signature, message: payload) else {
            throw DirectoryError.invalidSignature
        }
        let gateways = try Self.validate(envelope.manifest, now: now)
        return Snapshot(manifest: envelope.manifest, gateways: gateways, refreshedAt: now)
    }

    public static func signedEnvelope(
        manifest: ManagedInfrastructureManifest,
        identity: ReticulumIdentity
    ) throws -> SignedManagedInfrastructureManifest {
        let signature = try identity.sign(encoder.encode(manifest))
        return SignedManagedInfrastructureManifest(manifest: manifest, signature: signature.hex)
    }

    public static func encoded(_ envelope: SignedManagedInfrastructureManifest) throws -> Data {
        try encoder.encode(envelope)
    }

    private static func validate(_ manifest: ManagedInfrastructureManifest, now: Date) throws -> [InternetGateway] {
        guard manifest.schemaVersion == 1 else { throw DirectoryError.invalidManifest("unsupported schema version") }
        guard manifest.issuedAt <= now.addingTimeInterval(5 * 60) else { throw DirectoryError.invalidManifest("issued in the future") }
        guard manifest.expiresAt > now else { throw DirectoryError.invalidManifest("expired") }
        guard manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60 else {
            throw DirectoryError.invalidManifest("validity exceeds 31 days")
        }
        guard (2...16).contains(manifest.gateways.count) else {
            throw DirectoryError.invalidManifest("two to sixteen redundant gateways are required")
        }
        if let wakeURL = manifest.wakeRegistrationURL,
           wakeURL.scheme?.lowercased() != "https" || wakeURL.host == nil {
            throw DirectoryError.invalidManifest("wake registration must use HTTPS")
        }

        var seen: Set<String> = []
        let sorted = manifest.gateways.sorted {
            $0.priority == $1.priority ? $0.name < $1.name : $0.priority < $1.priority
        }
        let gateways = try sorted.map { entry -> InternetGateway in
            let host = entry.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isSafeHost(host), !entry.name.isEmpty, entry.name.count <= 80 else {
                throw DirectoryError.invalidManifest("gateway host or name is invalid")
            }
            let backboneIdentity = entry.backboneTransportIdentity.flatMap(Data.init(strictHex:))
            if entry.backboneTransportIdentity != nil, backboneIdentity?.count != 16 {
                throw DirectoryError.invalidManifest("backbone identity must be 32 hexadecimal characters")
            }
            return InternetGateway(
                name: entry.name,
                host: host,
                port: entry.port,
                backboneTransportIdentity: backboneIdentity
            )
        }
        guard gateways.allSatisfy({ seen.insert($0.id).inserted }) else {
            throw DirectoryError.invalidManifest("duplicate gateways")
        }
        guard manifest.propagationNodes.count <= 16,
              manifest.propagationNodes.allSatisfy({
                  !$0.name.isEmpty && $0.name.count <= 80 && DestinationHash.isValid($0.destinationHash)
              }) else {
            throw DirectoryError.invalidManifest("propagation-node entry is invalid")
        }
        return gateways
    }

    private static func isSafeHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.contains("/") && !host.contains("@") else { return false }
        return host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_")).contains($0)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct RemoteWakeRegistration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceToken: String
    public let apnsEnvironment: String
    public let deliveryDestination: String
    public let identityPublicKey: String
    public let issuedAt: Date
    public let nonce: String
    public let signature: String

    public static func create(
        deviceToken: String,
        apnsEnvironment: String,
        deliveryDestination: String,
        identity: ReticulumIdentity,
        issuedAt: Date = .now,
        nonce: UUID = UUID()
    ) throws -> Self {
        guard Data(strictHex: deviceToken)?.count == 32,
              ["sandbox", "production"].contains(apnsEnvironment),
              DestinationHash.isValid(deliveryDestination),
              deliveryDestination.lowercased() == deliveryDestinationHash(for: identity),
              issuedAt.timeIntervalSince1970 > 0 else {
            throw RegistrationError.invalidRegistration
        }
        let payload = Payload(
            schemaVersion: 1,
            deviceToken: deviceToken.lowercased(),
            apnsEnvironment: apnsEnvironment,
            deliveryDestination: deliveryDestination,
            identityPublicKey: identity.publicKey.hex,
            issuedAt: issuedAt,
            nonce: nonce.uuidString.lowercased()
        )
        let signature = try identity.sign(try encoder.encode(payload))
        return Self(
            schemaVersion: payload.schemaVersion,
            deviceToken: payload.deviceToken,
            apnsEnvironment: payload.apnsEnvironment,
            deliveryDestination: payload.deliveryDestination,
            identityPublicKey: payload.identityPublicKey,
            issuedAt: payload.issuedAt,
            nonce: payload.nonce,
            signature: signature.hex
        )
    }

    public func validates() -> Bool {
        guard let publicKey = Data(strictHex: identityPublicKey),
              let signatureData = Data(strictHex: signature),
              let identity = try? ReticulumIdentity(publicKey: publicKey),
              schemaVersion == 1,
              Data(strictHex: deviceToken)?.count == 32,
              ["sandbox", "production"].contains(apnsEnvironment),
              DestinationHash.isValid(deliveryDestination),
              deliveryDestination == Self.deliveryDestinationHash(for: identity),
              issuedAt.timeIntervalSince1970 > 0,
              UUID(uuidString: nonce) != nil else { return false }
        return identity.validate(signature: signatureData, message: (try? Self.encoder.encode(payload)) ?? Data())
    }

    public enum RegistrationError: LocalizedError {
        case invalidRegistration
        public var errorDescription: String? {
            "The APNs token, environment, or LXMF delivery identity is invalid."
        }
    }

    private static func deliveryDestinationHash(for identity: ReticulumIdentity) -> String {
        let nameHash = Data(ReticulumIdentity.fullHash(Data("lxmf.delivery".utf8)).prefix(10))
        return ReticulumIdentity.truncatedHash(nameHash + identity.hash).hex
    }

    fileprivate var payload: Payload {
        Payload(
            schemaVersion: schemaVersion,
            deviceToken: deviceToken,
            apnsEnvironment: apnsEnvironment,
            deliveryDestination: deliveryDestination,
            identityPublicKey: identityPublicKey,
            issuedAt: issuedAt,
            nonce: nonce
        )
    }

    fileprivate struct Payload: Codable {
        let schemaVersion: Int
        let deviceToken: String
        let apnsEnvironment: String
        let deliveryDestination: String
        let identityPublicKey: String
        let issuedAt: Date
        let nonce: String
    }

    fileprivate static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

public actor RemoteWakeRegistrationClient {
    public enum RegistrationError: LocalizedError {
        case invalidEndpoint
        case rejected(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Remote wake registration requires an HTTPS endpoint."
            case .rejected(let status): "Remote wake registration was rejected (HTTP \(status))."
            }
        }
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func register(_ registration: RemoteWakeRegistration, at url: URL) async throws {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw RegistrationError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lower-Sideband/1", forHTTPHeaderField: "User-Agent")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(registration)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegistrationError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == url.host?.lowercased() else {
            throw RegistrationError.invalidEndpoint
        }
    }
}

private extension Data {
    init?(strictHex string: String) {
        guard string.count.isMultiple(of: 2), !string.isEmpty else { return nil }
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
