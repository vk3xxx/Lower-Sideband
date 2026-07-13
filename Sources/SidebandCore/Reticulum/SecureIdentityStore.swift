import Foundation
#if os(iOS)
import Security
#endif

enum SecureIdentityStore {
    static func loadOrCreate(account: String, legacyDefaultsKey: String) -> Data {
#if os(iOS)
        if let stored = readKeychain(account: account), stored.count == 64 { return stored }
        let material = UserDefaults.standard.data(forKey: legacyDefaultsKey) ?? ReticulumIdentity().privateKey!
        if writeKeychain(material, account: account) {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        return material
#else
        // Preserve the prototype's existing macOS identity and LXMF address.
        let material = UserDefaults.standard.data(forKey: legacyDefaultsKey) ?? ReticulumIdentity().privateKey!
        UserDefaults.standard.set(material, forKey: legacyDefaultsKey)
        return material
#endif
    }

#if os(iOS)
    private static let service = "com.supes.MacSideband.identities"

    private static func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func writeKeychain(_ data: Data, account: String) -> Bool {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
#endif
}
