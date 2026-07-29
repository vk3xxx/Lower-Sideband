import ReticulumKit
import CryptoKit
import Foundation

public enum ReticulumIdentityText {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encodePrivate(_ identity: ReticulumIdentity) throws -> String {
        guard let key = identity.privateKey else { throw ArchiveError.privateIdentityRequired }
        return "RNS-PRIVATE-1:" + base32Encode(key)
    }

    public static func decodePrivate(_ text: String) throws -> ReticulumIdentity {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = compact.hasPrefix("RNS-PRIVATE-1:") ? String(compact.dropFirst(14)) : compact
        guard let data = base32Decode(encoded), data.count == 64 else { throw ArchiveError.invalidIdentity }
        return try ReticulumIdentity(privateKey: data)
    }

    public static func base32Encode(_ data: Data) -> String {
        var output = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; output.append(alphabet[(buffer >> bits) & 31]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    public static func base32Decode(_ text: String) -> Data? {
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
        var output = Data(), buffer = 0, bits = 0
        for character in text.uppercased() where character != "=" && character != "-" && character != " " {
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | value; bits += 5
            if bits >= 8 { bits -= 8; output.append(UInt8((buffer >> bits) & 0xff)); buffer &= (1 << bits) - 1 }
        }
        return output
    }

    public enum ArchiveError: Error { case privateIdentityRequired, invalidIdentity }
}

public struct SidebandProfileArchive: Sendable {
    public static let currentVersion = 1
    public static let maximumPlaintextBytes = 256 * 1_024 * 1_024
    private static let magic = Data("LSBP1".utf8)

    public struct Payload: Codable, Sendable {
        public let version: Int
        public let exportedAt: Date
        public let messagingIdentity: Data
        public let applicationSnapshot: Data
        public let ratchets: ReticulumRatchetState?

        public init(messagingIdentity: Data, applicationSnapshot: Data, ratchets: ReticulumRatchetState? = nil, exportedAt: Date = .now) throws {
            guard messagingIdentity.count == 64, applicationSnapshot.count <= SidebandProfileArchive.maximumPlaintextBytes else { throw ArchiveError.invalidPayload }
            version = SidebandProfileArchive.currentVersion
            self.exportedAt = exportedAt
            self.messagingIdentity = messagingIdentity
            self.applicationSnapshot = applicationSnapshot
            self.ratchets = ratchets
        }
    }

    public static func seal(_ payload: Payload, passphrase: String, salt: Data? = nil, nonce: AES.GCM.Nonce? = nil) throws -> Data {
        guard passphrase.count >= 12 else { throw ArchiveError.weakPassphrase }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(payload)
        guard plaintext.count <= maximumPlaintextBytes else { throw ArchiveError.invalidPayload }
        let salt = salt ?? randomBytes(count: 32)
        guard salt.count == 32 else { throw ArchiveError.invalidPayload }
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: magic + salt)
        guard let combined = sealed.combined else { throw ArchiveError.invalidPayload }
        return magic + salt + combined
    }

    public static func open(_ archive: Data, passphrase: String) throws -> Payload {
        guard archive.starts(with: magic), archive.count > magic.count + 32,
              archive.count <= maximumPlaintextBytes + 1_024 else { throw ArchiveError.invalidArchive }
        let saltRange = magic.count..<(magic.count + 32)
        let salt = archive.subdata(in: saltRange)
        let box = try AES.GCM.SealedBox(combined: archive.dropFirst(magic.count + 32))
        let plaintext: Data
        do { plaintext = try AES.GCM.open(box, using: deriveKey(passphrase: passphrase, salt: salt), authenticating: magic + salt) }
        catch { throw ArchiveError.authenticationFailed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: plaintext)
        guard payload.version <= currentVersion, payload.messagingIdentity.count == 64,
              payload.applicationSnapshot.count <= maximumPlaintextBytes else { throw ArchiveError.invalidPayload }
        return payload
    }

    /// Imports the raw 64-byte `primary_identity` written by Python Reticulum.
    public static func importPythonIdentity(_ data: Data) throws -> ReticulumIdentity {
        guard data.count == 64 else { throw ArchiveError.invalidPayload }
        return try ReticulumIdentity(privateKey: data)
    }

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var material = Data(passphrase.utf8) + salt
        for round in 0..<100_000 {
            var counter = UInt32(round).bigEndian
            material = Data(SHA256.hash(data: material + withUnsafeBytes(of: &counter) { Data($0) } + salt))
        }
        return SymmetricKey(data: material)
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public enum ArchiveError: LocalizedError {
        case weakPassphrase, invalidArchive, authenticationFailed, invalidPayload
        public var errorDescription: String? {
            switch self {
            case .weakPassphrase: "Use a passphrase of at least 12 characters."
            case .invalidArchive: "This is not a Lower Sideband encrypted profile archive."
            case .authenticationFailed: "The profile passphrase is incorrect or the archive was modified."
            case .invalidPayload: "The profile archive contains invalid or unsupported data."
            }
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
