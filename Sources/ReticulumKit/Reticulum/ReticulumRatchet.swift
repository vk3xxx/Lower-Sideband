import CryptoKit
import Foundation

/// Retains rotating X25519 destination ratchets for forward-secret opportunistic delivery.
public struct ReticulumRatchetState: Codable, Sendable, Equatable {
    public static let defaultRetentionCount = 512
    public static let defaultRotationInterval: TimeInterval = 30 * 60

    public private(set) var privateKeys: [Data]
    public private(set) var lastRotation: Date
    public var retentionCount: Int
    public var rotationInterval: TimeInterval

    public init(retentionCount: Int = defaultRetentionCount, rotationInterval: TimeInterval = defaultRotationInterval, now: Date = .now) {
        self.privateKeys = [Curve25519.KeyAgreement.PrivateKey().rawRepresentation]
        self.lastRotation = now
        self.retentionCount = max(1, retentionCount)
        self.rotationInterval = max(1, rotationInterval)
    }

    public mutating func rotateIfNeeded(now: Date = .now, force: Bool = false) {
        guard force || now.timeIntervalSince(lastRotation) >= rotationInterval else { return }
        privateKeys.insert(Curve25519.KeyAgreement.PrivateKey().rawRepresentation, at: 0)
        privateKeys = Array(privateKeys.prefix(max(1, retentionCount)))
        lastRotation = now
    }

    public var currentPublicKey: Data? {
        guard let raw = privateKeys.first,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        return key.publicKey.rawRepresentation
    }

    public var currentID: Data? { currentPublicKey.map(ReticulumIdentity.truncatedHash) }
}

public extension ReticulumIdentity {
    func decrypt(_ ciphertext: Data, ratchets: [Data], enforceRatchets: Bool = false) throws -> Data {
        guard ciphertext.count > 32 else { throw IdentityError.invalidCiphertext }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ciphertext.prefix(32))
        for raw in ratchets {
            guard let ratchet = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { continue }
            if let plaintext = try? decrypt(ciphertext, peer: peer, privateKey: ratchet) { return plaintext }
        }
        guard !enforceRatchets else { throw IdentityError.ratchetRequired }
        return try decrypt(ciphertext)
    }

    private func decrypt(_ ciphertext: Data, peer: Curve25519.KeyAgreement.PublicKey, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let material = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: hash, info: Data(), outputByteCount: 64)
        let derived = key.withUnsafeBytes { Data($0) }
        return try ReticulumToken(key: derived).decrypt(Data(ciphertext.dropFirst(32)))
    }
}
