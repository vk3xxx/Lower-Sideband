import Foundation

public enum LXMFCommand: Codable, Hashable, Sendable {
    case ping
    case echo(String)
    case signalReport

    public static let maximumCommandsPerMessage = 8
    public static let maximumEchoCharacters = 256

    public var encoded: Data {
        switch self {
        case .ping:
            MessagePack.map([(0x02, MessagePack.bool(true))])
        case .echo(let value):
            MessagePack.map([(0x03, MessagePack.binary(Data(value.utf8)))])
        case .signalReport:
            MessagePack.map([(0x04, MessagePack.bool(true))])
        }
    }

    public static func encode(_ commands: [LXMFCommand]) -> Data? {
        guard !commands.isEmpty, commands.count <= maximumCommandsPerMessage else { return nil }
        return MessagePack.array(commands.map(\.encoded))
    }

    public static func decode(_ value: MessagePackValue?) -> [LXMFCommand] {
        guard case let .array(items) = value, items.count <= maximumCommandsPerMessage else { return [] }
        return items.compactMap { item in
            guard case let .map(entries) = item else { return nil }
            for (key, value) in entries {
                guard case let .unsigned(commandID) = key else { continue }
                switch commandID {
                case 0x02:
                    guard case .bool(true) = value else { return nil }
                    return .ping
                case 0x03:
                    guard case let .binary(data) = value,
                          data.count <= maximumEchoCharacters * 4,
                          let echo = String(data: data, encoding: .utf8),
                          !echo.isEmpty,
                          echo.count <= maximumEchoCharacters else { return nil }
                    return .echo(echo)
                case 0x04:
                    guard case .bool(true) = value else { return nil }
                    return .signalReport
                default:
                    // Plugin commands and future unknown commands are intentionally never executed.
                    continue
                }
            }
            return nil
        }
    }
}
