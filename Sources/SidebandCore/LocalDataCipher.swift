import CryptoKit
import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
public final class AppPrivacyLock {
    public private(set) var isEnabled: Bool
    public private(set) var isUnlocked: Bool
    public private(set) var isAuthenticating = false
    public private(set) var lastError: String?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: "sidebandPrivacyLockEnabled")
        isEnabled = enabled
        isUnlocked = !enabled
    }

    public var availabilityDescription: String {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
            ? "Device authentication is available"
            : (error?.localizedDescription ?? "Device authentication is unavailable")
    }

    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        let success = await authenticate(reason: enabled ? "Enable Sideband app lock" : "Disable Sideband app lock")
        applyAuthenticationResult(success, enabling: enabled)
    }

    public func unlock() async {
        guard isEnabled, !isUnlocked, !isAuthenticating else { return }
        let success = await authenticate(reason: "Unlock Sideband")
        if success { isUnlocked = true; lastError = nil }
    }

    public func lock() {
        guard isEnabled else { return }
        isUnlocked = false
        lastError = nil
    }

    func applyAuthenticationResult(_ success: Bool, enabling: Bool) {
        guard success else {
            lastError = "Device authentication did not succeed. The app-lock setting was not changed."
            return
        }
        isEnabled = enabling
        isUnlocked = true
        lastError = nil
        defaults.set(enabling, forKey: "sidebandPrivacyLockEnabled")
    }

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            lastError = policyError?.localizedDescription ?? "Device authentication is unavailable."
            return false
        }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { lastError = error.localizedDescription; return false }
    }
}

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
