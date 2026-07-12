import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Reticulum's timestamp-free Fernet variant for AES-256-CBC links.
public struct ReticulumToken: Sendable {
    public static let overhead = 48
    private let signingKey: Data
    private let encryptionKey: Data

    public init(key: Data) throws {
        guard key.count == 64 else { throw TokenError.invalidKey }
        signingKey = key.prefix(32)
        encryptionKey = key.suffix(32)
    }

    public func encrypt(_ plaintext: Data, iv: Data? = nil) throws -> Data {
        let iv = iv ?? randomData(count: kCCBlockSizeAES128)
        guard iv.count == kCCBlockSizeAES128 else { throw TokenError.invalidIV }
        let ciphertext = try crypt(operation: CCOperation(kCCEncrypt), input: plaintext, iv: iv)
        let signed = iv + ciphertext
        let mac = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: signingKey)))
        return signed + mac
    }

    public func decrypt(_ token: Data) throws -> Data {
        guard token.count > Self.overhead, token.count.isMultiple(of: kCCBlockSizeAES128) else { throw TokenError.invalidToken }
        let signed = token.dropLast(32)
        let receivedMAC = token.suffix(32)
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: signingKey)))
        guard Data(receivedMAC) == expectedMAC else { throw TokenError.invalidMAC }
        return try crypt(operation: CCOperation(kCCDecrypt), input: Data(signed.dropFirst(16)), iv: Data(signed.prefix(16)))
    }

    private func crypt(operation: CCOperation, input: Data, iv: Data) throws -> Data {
        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                encryptionKey.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, encryptionKey.count, ivBytes.baseAddress, inputBytes.baseAddress, input.count, outputBytes.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TokenError.cryptFailed(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }) }
        return Data(bytes)
    }
    public enum TokenError: Error { case invalidKey, invalidIV, invalidToken, invalidMAC, cryptFailed(CCCryptorStatus) }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data { var value = lhs; value.append(rhs); return value }
}
