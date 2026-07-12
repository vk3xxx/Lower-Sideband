import Foundation

public enum DestinationHash {
    public static let byteCount = 16

    public static func isValid(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == byteCount * 2 else { return false }
        return normalized.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
