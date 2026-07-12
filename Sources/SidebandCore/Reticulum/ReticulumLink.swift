import CryptoKit
import Foundation

public struct ReticulumLinkRequest: Sendable {
    public static let mtu = 500
    public static let modeAES256CBC: UInt8 = 1
    public let destinationHash: Data
    public let publicKey: Data
    public let signingPublicKey: Data
    public let rawPacket: Data
    public let linkID: Data
    public let createdAt: Date
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(destinationHash: Data) throws {
        try self.init(destinationHash: destinationHash, keyAgreementPrivateKey: Data(Curve25519.KeyAgreement.PrivateKey().rawRepresentation), signingPrivateKey: Data(Curve25519.Signing.PrivateKey().rawRepresentation))
    }

    public init(destinationHash: Data, keyAgreementPrivateKey: Data, signingPrivateKey: Data) throws {
        guard destinationHash.count == 16 else { throw LinkError.invalidDestination }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyAgreementPrivateKey)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        self.destinationHash = destinationHash
        createdAt = .now
        self.privateKey = privateKey
        publicKey = privateKey.publicKey.rawRepresentation
        signingPublicKey = signingKey.publicKey.rawRepresentation
        let requestData = publicKey + signingPublicKey + Self.signallingBytes(mtu: Self.mtu, mode: Self.modeAES256CBC)
        rawPacket = Data([0x02, 0x00]) + destinationHash + Data([0x00]) + requestData
        linkID = ReticulumIdentity.truncatedHash(Data([0x02]) + destinationHash + Data([0x00]) + publicKey + signingPublicKey)
    }

    public func deriveKey(peerPublicKey: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let material = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: linkID, info: Data(), outputByteCount: 64)
        return key.withUnsafeBytes { Data($0) }
    }

    public func validateProof(_ packet: ReticulumPacket, destinationPublicKey: Data) throws -> ReticulumLinkSession {
        guard packet.packetType == .proof, packet.context == 0xff, packet.destinationHash == linkID else { throw LinkError.invalidProof }
        guard packet.data.count == 64 + 32 + 3, destinationPublicKey.count == 64 else { throw LinkError.invalidProof }
        let signature = packet.data.prefix(64)
        let peerPublicKey = packet.data.subdata(in: 64..<96)
        let signalling = packet.data.suffix(3)
        guard signalling == Self.signallingBytes(mtu: Self.mtu, mode: Self.modeAES256CBC) else { throw LinkError.invalidProof }
        let identity = try ReticulumIdentity(publicKey: destinationPublicKey)
        let signedData = linkID + peerPublicKey + destinationPublicKey.suffix(32) + signalling
        guard identity.validate(signature: Data(signature), message: signedData) else { throw LinkError.invalidProof }
        return ReticulumLinkSession(linkID: linkID, destinationHash: destinationHash, peerPublicKey: peerPublicKey, derivedKey: try deriveKey(peerPublicKey: peerPublicKey), mtu: Self.mtu, rtt: max(0.001, Date().timeIntervalSince(createdAt)))
    }

    public static func signallingBytes(mtu: Int, mode: UInt8) -> Data {
        let value = (mtu & 0x1f_ffff) + (Int((mode << 5) & 0xe0) << 16)
        return Data([UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }
    public enum LinkError: Error { case invalidDestination, invalidProof }
}

public struct ReticulumLinkSession: Sendable {
    public let linkID: Data
    public let destinationHash: Data
    public let peerPublicKey: Data
    public let derivedKey: Data
    public let mtu: Int
    public let rtt: Double

    public init(linkID: Data, destinationHash: Data, peerPublicKey: Data, derivedKey: Data, mtu: Int, rtt: Double = 0.1) {
        self.linkID = linkID
        self.destinationHash = destinationHash
        self.peerPublicKey = peerPublicKey
        self.derivedKey = derivedKey
        self.mtu = mtu
        self.rtt = rtt
    }

    public func encryptedPacket(_ plaintext: Data, context: UInt8 = 0, iv: Data? = nil) throws -> Data {
        let ciphertext = try ReticulumToken(key: derivedKey).encrypt(plaintext, iv: iv)
        return Data([0x0c, 0x00]) + linkID + Data([context]) + ciphertext
    }

    public func decrypt(_ packet: ReticulumPacket) throws -> Data {
        guard packet.destinationType == .link, packet.destinationHash == linkID else { throw SessionError.wrongLink }
        return try ReticulumToken(key: derivedKey).decrypt(packet.data)
    }

    public func keepalivePacket() -> Data {
        Data([0x0c, 0x00]) + linkID + Data([0xfa, 0xff])
    }

    public func resourceAdvertisementPacket(_ advertisement: ReticulumResourceAdvertisement, hashMapSegment: Int = 0, iv: Data? = nil) throws -> Data {
        try encryptedPacket(advertisement.encode(hashMapSegment: hashMapSegment), context: 0x02, iv: iv)
    }

    public func resourceRequestPacket(_ request: ReticulumResourceRequest, iv: Data? = nil) throws -> Data {
        try encryptedPacket(request.encode(), context: 0x03, iv: iv)
    }

    public func resourceHashMapUpdatePacket(_ update: ReticulumResourceHashMapUpdate, iv: Data? = nil) throws -> Data {
        try encryptedPacket(update.encode(), context: 0x04, iv: iv)
    }

    public func resourceCancelPacket(resourceHash: Data, initiatedBySender: Bool, iv: Data? = nil) throws -> Data {
        guard resourceHash.count == 32 else { throw SessionError.invalidResource }
        return try encryptedPacket(resourceHash, context: initiatedBySender ? 0x06 : 0x07, iv: iv)
    }

    public func encryptResourcePayload(_ data: Data, iv: Data? = nil, payloadRandomHash: Data? = nil) throws -> Data {
        let prefix = payloadRandomHash ?? Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
        guard prefix.count == 4 else { throw SessionError.invalidResource }
        return try ReticulumToken(key: derivedKey).encrypt(prefix + data, iv: iv)
    }

    public func decryptResourcePayload(_ data: Data) throws -> Data {
        let plaintext = try ReticulumToken(key: derivedKey).decrypt(data)
        guard plaintext.count >= 4 else { throw SessionError.invalidResource }
        return Data(plaintext.dropFirst(4))
    }

    public func resourcePartPacket(_ part: Data) -> Data {
        Data([0x0c, 0x00]) + linkID + Data([0x01]) + part
    }

    public enum SessionError: Error { case wrongLink, invalidResource }
}

public struct ReticulumIncomingLink: Sendable {
    public let session: ReticulumLinkSession
    public let proofPacket: Data
    public let initiatorSigningPublicKey: Data

    public init(request: ReticulumPacket, localIdentity: ReticulumIdentity, responderPrivateKey: Data? = nil) throws {
        guard request.packetType == .linkRequest, request.data.count == 67 else { throw IncomingError.invalidRequest }
        let initiatorPublic = request.data.subdata(in: 0..<32)
        initiatorSigningPublicKey = request.data.subdata(in: 32..<64)
        let signalling = request.data.suffix(3)
        let linkID = ReticulumIdentity.truncatedHash(Data(request.hashablePart.dropLast(3)))
        let privateKey = try responderPrivateKey.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) } ?? Curve25519.KeyAgreement.PrivateKey()
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorPublic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let material = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: linkID, info: Data(), outputByteCount: 64)
        let derived = key.withUnsafeBytes { Data($0) }
        session = ReticulumLinkSession(linkID: linkID, destinationHash: request.destinationHash, peerPublicKey: initiatorPublic, derivedKey: derived, mtu: 500)
        let signed = linkID + privateKey.publicKey.rawRepresentation + localIdentity.publicKey.suffix(32) + signalling
        let proofData = try localIdentity.sign(signed) + privateKey.publicKey.rawRepresentation + signalling
        proofPacket = Data([0x0f, 0x00]) + linkID + Data([0xff]) + proofData
    }

    public enum IncomingError: Error { case invalidRequest }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
