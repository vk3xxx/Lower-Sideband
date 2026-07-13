import Foundation
#if os(iOS) || os(macOS)
import Security
#endif

enum SecureIdentityStore {
    static func loadOrCreate(account: String, legacyDefaultsKey: String, synchronizable: Bool = false) -> Data {
#if os(iOS) || os(macOS)
        if let stored = readKeychain(account: account, synchronizable: synchronizable), stored.count == 64 { return stored }

        let localKeychainMaterial = synchronizable ? readKeychain(account: account, synchronizable: false) : nil
        let material = localKeychainMaterial
            ?? UserDefaults.standard.data(forKey: legacyDefaultsKey)
            ?? ReticulumIdentity().privateKey!
        if writeKeychain(material, account: account, synchronizable: synchronizable) {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            if synchronizable { deleteKeychain(account: account, synchronizable: false) }
            return material
        }
        // Unsigned developer builds may not have access to the data-protection or
        // synchronizable Keychain. Preserve a stable local identity in that case.
        UserDefaults.standard.set(material, forKey: legacyDefaultsKey)
        return material
#else
        let material = UserDefaults.standard.data(forKey: legacyDefaultsKey) ?? ReticulumIdentity().privateKey!
        UserDefaults.standard.set(material, forKey: legacyDefaultsKey)
        return material
#endif
    }

#if os(iOS) || os(macOS)
    private static let service = "com.supes.MacSideband.identities"

    private static func readKeychain(account: String, synchronizable: Bool) -> Data? {
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func writeKeychain(_ data: Data, account: String, synchronizable: Bool) -> Bool {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true
        ]
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
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
