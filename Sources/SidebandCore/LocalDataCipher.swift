import CryptoKit
import Foundation

enum LocalDataCipherError: Error {
    case invalidCiphertext
}

struct LocalDataCipher: Sendable {
    private static let magic = Data("SBL1".utf8)
    private let key: SymmetricKey

    init() {
        let material = SecureIdentityStore.loadOrCreate(
            account: "local.data.encryption",
            legacyDefaultsKey: "localDataEncryptionKey"
        )
        self.init(keyMaterial: material)
    }

    init(keyMaterial: Data) {
        key = SymmetricKey(data: SHA256.hash(
            data: Data("Sideband local data encryption key v1".utf8) + keyMaterial
        ))
    }

    func seal(_ plaintext: Data, context: String) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(context.utf8)
        )
        guard let combined = sealed.combined else { throw LocalDataCipherError.invalidCiphertext }
        return Self.magic + combined
    }

    func open(_ storedData: Data, context: String) throws -> Data {
        guard isEncrypted(storedData) else { return storedData }
        let ciphertext = storedData.dropFirst(Self.magic.count)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }

    func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: Self.magic)
    }
}
