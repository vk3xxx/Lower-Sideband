import Foundation
#if os(iOS) || os(macOS)
import Security
#endif

enum SecureIdentityStore {
    enum StoreError: Error, Equatable {
        case readFailed(Int32)
        case writeFailed(Int32)
        case invalidStoredMaterial
    }

    static func loadOrCreate(account: String, legacyDefaultsKey: String, synchronizable: Bool = false) -> Result<Data, StoreError> {
#if os(iOS) || os(macOS)
        let result = resolveKeychainRead(readKeychain(account: account, synchronizable: synchronizable)) {
            let localKeychainMaterial: Data?
            if synchronizable {
                switch readKeychain(account: account, synchronizable: false) {
                case .success(let value): localKeychainMaterial = value
                case .failure(let error): return .failure(error)
                }
            } else {
                localKeychainMaterial = nil
            }
            let material = localKeychainMaterial
                ?? UserDefaults.standard.data(forKey: legacyDefaultsKey)
                ?? ReticulumIdentity().privateKey!
            guard material.count == 64 else { return .failure(.invalidStoredMaterial) }
            switch writeKeychain(material, account: account, synchronizable: synchronizable) {
            case .success:
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                if synchronizable { deleteKeychain(account: account, synchronizable: false) }
                return .success(material)
            case .failure(let error):
                // Never copy private keys or data-encryption keys back into UserDefaults.
                // A transient Keychain failure must not be mistaken for a missing key.
                return .failure(error)
            }
        }
#if DEBUG
        if case .failure = result { return .success(debugProcessMaterial(account: account)) }
#endif
        return result
#else
        let material = UserDefaults.standard.data(forKey: legacyDefaultsKey) ?? ReticulumIdentity().privateKey!
        UserDefaults.standard.set(material, forKey: legacyDefaultsKey)
        return .success(material)
#endif
    }

#if DEBUG && (os(iOS) || os(macOS))
    private static let debugLock = NSLock()
    nonisolated(unsafe) private static var debugProcessMaterials: [String: Data] = [:]

    private static func debugProcessMaterial(account: String) -> Data {
        debugLock.lock()
        defer { debugLock.unlock() }
        if let existing = debugProcessMaterials[account] { return existing }
        let material = ReticulumIdentity().privateKey!
        debugProcessMaterials[account] = material
        return material
    }
#endif

    static func resolveKeychainRead(
        _ read: Result<Data?, StoreError>,
        whenMissing: () -> Result<Data, StoreError>
    ) -> Result<Data, StoreError> {
        switch read {
        case .failure(let error): return .failure(error)
        case .success(let stored):
            guard let stored else { return whenMissing() }
            return stored.count == 64 ? .success(stored) : .failure(.invalidStoredMaterial)
        }
    }

#if os(iOS) || os(macOS)
    private static let service = "com.supes.MacSideband.identities"

    private static func readKeychain(account: String, synchronizable: Bool) -> Result<Data?, StoreError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess else { return .failure(.readFailed(status)) }
        guard let data = result as? Data else { return .failure(.invalidStoredMaterial) }
        return .success(data)
    }

    private static func writeKeychain(_ data: Data, account: String, synchronizable: Bool) -> Result<Void, StoreError> {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true
        ]
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return .success(()) }
        guard update == errSecItemNotFound else { return .failure(.writeFailed(update)) }
        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        return status == errSecSuccess ? .success(()) : .failure(.writeFailed(status))
    }

    private static func deleteKeychain(account: String, synchronizable: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }
#endif
}
