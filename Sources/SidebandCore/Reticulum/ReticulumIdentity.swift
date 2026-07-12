import CryptoKit
import Foundation

/// Reticulum-compatible identity key layout: X25519 key followed by Ed25519 key.
public struct ReticulumIdentity: Sendable {
    private let encryptionKey: Curve25519.KeyAgreement.PrivateKey?
    private let signingKey: Curve25519.Signing.PrivateKey?
    public let publicKey: Data

    public var hash: Data { Data(SHA256.hash(data: publicKey).prefix(16)) }

    public init() {
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        encryptionKey = encryption
        signingKey = signing
        publicKey = encryption.publicKey.rawRepresentation + signing.publicKey.rawRepresentation
    }

    public init(privateKey: Data) throws {
        guard privateKey.count == 64 else { throw IdentityError.invalidKeyLength }
        let encryption = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey.prefix(32))
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey.suffix(32))
        encryptionKey = encryption
        signingKey = signing
        publicKey = encryption.publicKey.rawRepresentation + signing.publicKey.rawRepresentation
    }

    public init(publicKey: Data) throws {
        guard publicKey.count == 64 else { throw IdentityError.invalidKeyLength }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey.prefix(32))
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey.suffix(32))
        encryptionKey = nil
        signingKey = nil
        self.publicKey = publicKey
    }

    public var privateKey: Data? {
        guard let encryptionKey, let signingKey else { return nil }
        return encryptionKey.rawRepresentation + signingKey.rawRepresentation
    }

    public func sign(_ message: Data) throws -> Data {
        guard let signingKey else { throw IdentityError.privateKeyRequired }
        return try signingKey.signature(for: message)
    }

    public func validate(signature: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey.suffix(32)) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    public func encrypt(_ plaintext: Data, ephemeralPrivateKey: Data? = nil, iv: Data? = nil, ratchet: Data? = nil) throws -> Data {
        let ephemeral = try ephemeralPrivateKey.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) } ?? Curve25519.KeyAgreement.PrivateKey()
        let targetBytes = ratchet ?? publicKey.prefix(32)
        let target = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: targetBytes)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: target)
        let material = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: hash, info: Data(), outputByteCount: 64)
        let derived = key.withUnsafeBytes { Data($0) }
        return ephemeral.publicKey.rawRepresentation + (try ReticulumToken(key: derived).encrypt(plaintext, iv: iv))
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard let encryptionKey, ciphertext.count > 32 else { throw IdentityError.privateKeyRequired }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ciphertext.prefix(32))
        let shared = try encryptionKey.sharedSecretFromKeyAgreement(with: peer)
        let material = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: hash, info: Data(), outputByteCount: 64)
        let derived = key.withUnsafeBytes { Data($0) }
        return try ReticulumToken(key: derived).decrypt(Data(ciphertext.dropFirst(32)))
    }

    public static func fullHash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public static func truncatedHash(_ data: Data) -> Data { Data(SHA256.hash(data: data).prefix(16)) }

    public enum IdentityError: Error { case invalidKeyLength, privateKeyRequired }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
