import ReticulumKit
import Foundation

public enum LXMFCommand: Codable, Hashable, Sendable {
    case telemetryRequest(timebase: Date, collector: Bool)
    case ping
    case echo(String)
    case signalReport
    case plugin(command: String, arguments: [String])

    public static let maximumCommandsPerMessage = 8
    public static let maximumEchoCharacters = 256

    public var encoded: Data? {
        switch self {
        case .telemetryRequest(let timebase, let collector):
            return MessagePack.map([(0x01, MessagePack.array([
                MessagePack.unsigned(UInt64(max(0, Int64(timebase.timeIntervalSince1970)))),
                MessagePack.bool(collector)
            ]))])
        case .ping:
            return MessagePack.map([(0x02, MessagePack.bool(true))])
        case .echo(let value):
            return MessagePack.map([(0x03, MessagePack.binary(Data(value.utf8)))])
        case .signalReport:
            return MessagePack.map([(0x04, MessagePack.bool(true))])
        case .plugin(let command, let arguments):
            guard let line = SidebandPluginCommandLine.encode(command: command, arguments: arguments) else { return nil }
            return MessagePack.map([(0x00, MessagePack.string(line))])
        }
    }

    public static func encode(_ commands: [LXMFCommand]) -> Data? {
        guard !commands.isEmpty, commands.count <= maximumCommandsPerMessage else { return nil }
        let encoded = commands.compactMap(\.encoded)
        guard encoded.count == commands.count else { return nil }
        return MessagePack.array(encoded)
    }

    public static func decode(_ value: MessagePackValue?) -> [LXMFCommand] {
        guard case let .array(items) = value, items.count <= maximumCommandsPerMessage else { return [] }
        return items.compactMap { item in
            guard case let .map(entries) = item else { return nil }
            for (key, value) in entries {
                guard case let .unsigned(commandID) = key else { continue }
                switch commandID {
                case 0x01:
                    guard case let .array(parts) = value, parts.count == 2,
                          let seconds = parts[0].numberValue,
                          case let .bool(collector) = parts[1],
                          seconds >= 0 else { return nil }
                    return .telemetryRequest(timebase: Date(timeIntervalSince1970: seconds), collector: collector)
                case 0x00:
                    let line: String?
                    switch value {
                    case .string(let string): line = string
                    case .binary(let data): line = String(data: data, encoding: .utf8)
                    default: line = nil
                    }
                    guard let line, let parsed = SidebandPluginCommandLine.parse(line) else { return nil }
                    return .plugin(command: parsed.command, arguments: parsed.arguments)
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

private extension MessagePackValue {
    var numberValue: Double? {
        switch self {
        case .unsigned(let value): Double(value)
        case .signed(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
