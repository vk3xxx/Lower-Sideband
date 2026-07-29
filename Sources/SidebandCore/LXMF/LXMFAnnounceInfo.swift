import ReticulumKit
import Foundation

public struct LXMFAnnounceInfo: Equatable, Sendable {
    public let displayName: String?
    public let stampCost: UInt8?

    public init?(appData: Data) {
        guard case let .array(values)? = try? MessagePackDecoder.decode(appData), values.count >= 2 else { return nil }
        switch values[0] {
        case let .binary(data): displayName = String(data: data, encoding: .utf8)
        case let .string(value): displayName = value
        default: displayName = nil
        }
        if case let .unsigned(value) = values[1], value > 0, value < 255 { stampCost = UInt8(value) }
        else { stampCost = nil }
    }
}
