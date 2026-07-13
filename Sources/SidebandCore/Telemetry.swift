import Foundation

public struct SidebandTelemetry: Codable, Hashable, Sendable {
    public struct Location: Codable, Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double
        public var speed: Double
        public var bearing: Double
        public var accuracy: Double
        public var updatedAt: Date

        public init(latitude: Double, longitude: Double, altitude: Double = 0, speed: Double = 0, bearing: Double = 0, accuracy: Double = 0, updatedAt: Date = .now) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.speed = speed
            self.bearing = bearing
            self.accuracy = accuracy
            self.updatedAt = updatedAt
        }
    }

    public struct Battery: Codable, Hashable, Sendable {
        public var chargePercent: Double
        public var isCharging: Bool
        public var temperature: Double?

        public init(chargePercent: Double, isCharging: Bool, temperature: Double? = nil) {
            self.chargePercent = chargePercent
            self.isCharging = isCharging
            self.temperature = temperature
        }
    }

    public var capturedAt: Date
    public var location: Location?
    public var battery: Battery?

    public init(capturedAt: Date = .now, location: Location? = nil, battery: Battery? = nil) {
        self.capturedAt = capturedAt
        self.location = location
        self.battery = battery
    }

    public func packed() -> Data {
        var sensors: [(UInt64, Data)] = [(SensorID.time, MessagePack.unsigned(UInt64(max(0, Int64(capturedAt.timeIntervalSince1970)))))]
        if let location {
            let values = [
                MessagePack.binary(Self.signed32(location.latitude * 1_000_000)),
                MessagePack.binary(Self.signed32(location.longitude * 1_000_000)),
                MessagePack.binary(Self.signed32(location.altitude * 100)),
                MessagePack.binary(Self.unsigned32(max(0, location.speed) * 100)),
                MessagePack.binary(Self.signed32(location.bearing * 100)),
                MessagePack.binary(Self.unsigned16(max(0, location.accuracy) * 100)),
                MessagePack.unsigned(UInt64(max(0, Int64(location.updatedAt.timeIntervalSince1970))))
            ]
            sensors.append((SensorID.location, MessagePack.array(values)))
        }
        if let battery {
            sensors.append((SensorID.battery, MessagePack.array([
                MessagePack.double(battery.chargePercent),
                MessagePack.bool(battery.isCharging),
                battery.temperature.map(MessagePack.double) ?? MessagePack.null
            ])))
        }
        return MessagePack.map(sensors)
    }

    public init(packed: Data) throws {
        guard case let .map(entries) = try MessagePackDecoder.decode(packed) else { throw DecodeError.invalidPayload }
        var timestamp: Date?
        var decodedLocation: Location?
        var decodedBattery: Battery?
        for (key, value) in entries {
            guard let sensorID = key.unsignedValue else { continue }
            switch sensorID {
            case SensorID.time:
                guard let seconds = value.numberValue else { throw DecodeError.invalidTime }
                timestamp = Date(timeIntervalSince1970: seconds)
            case SensorID.location:
                decodedLocation = try Self.decodeLocation(value)
            case SensorID.battery:
                decodedBattery = try Self.decodeBattery(value)
            default:
                continue
            }
        }
        capturedAt = timestamp ?? decodedLocation?.updatedAt ?? .distantPast
        location = decodedLocation
        battery = decodedBattery
    }

    private enum SensorID {
        static let time: UInt64 = 0x01
        static let location: UInt64 = 0x02
        static let battery: UInt64 = 0x04
    }

    private static func decodeLocation(_ value: MessagePackValue) throws -> Location {
        guard case let .array(parts) = value, parts.count >= 7,
              case let .binary(latitudeData) = parts[0],
              case let .binary(longitudeData) = parts[1],
              case let .binary(altitudeData) = parts[2],
              case let .binary(speedData) = parts[3],
              case let .binary(bearingData) = parts[4],
              case let .binary(accuracyData) = parts[5],
              let updated = parts[6].numberValue else { throw DecodeError.invalidLocation }
        let latitude = Double(try signed32(latitudeData)) / 1_000_000
        let longitude = Double(try signed32(longitudeData)) / 1_000_000
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw DecodeError.invalidLocation }
        return Location(
            latitude: latitude,
            longitude: longitude,
            altitude: Double(try signed32(altitudeData)) / 100,
            speed: Double(try unsigned32(speedData)) / 100,
            bearing: Double(try signed32(bearingData)) / 100,
            accuracy: Double(try unsigned16(accuracyData)) / 100,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private static func decodeBattery(_ value: MessagePackValue) throws -> Battery {
        guard case let .array(parts) = value, parts.count >= 2,
              let percent = parts[0].numberValue,
              case let .bool(charging) = parts[1] else { throw DecodeError.invalidBattery }
        let temperature: Double?
        if parts.count < 3 || parts[2] == .null { temperature = nil }
        else if let value = parts[2].numberValue { temperature = value }
        else { throw DecodeError.invalidBattery }
        guard (0...100).contains(percent) else { throw DecodeError.invalidBattery }
        return Battery(chargePercent: percent, isCharging: charging, temperature: temperature)
    }

    private static func signed32(_ scaledValue: Double) -> Data {
        var value = Int32(clamping: Int64(scaledValue.rounded())).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func unsigned32(_ scaledValue: Double) -> Data {
        var value = UInt32(clamping: UInt64(scaledValue.rounded())).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func unsigned16(_ scaledValue: Double) -> Data {
        var value = UInt16(clamping: UInt64(scaledValue.rounded())).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func signed32(_ data: Data) throws -> Int32 {
        guard data.count == 4 else { throw DecodeError.invalidLocation }
        return Int32(bitPattern: UInt32(data.reduce(0) { ($0 << 8) | UInt32($1) }))
    }
    private static func unsigned32(_ data: Data) throws -> UInt32 {
        guard data.count == 4 else { throw DecodeError.invalidLocation }
        return data.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func unsigned16(_ data: Data) throws -> UInt16 {
        guard data.count == 2 else { throw DecodeError.invalidLocation }
        return data.reduce(0) { ($0 << 8) | UInt16($1) }
    }

    public enum DecodeError: Error { case invalidPayload, invalidTime, invalidLocation, invalidBattery }
}

private extension MessagePackValue {
    var unsignedValue: UInt64? {
        if case let .unsigned(value) = self { return value }
        return nil
    }
    var numberValue: Double? {
        switch self {
        case let .unsigned(value): Double(value)
        case let .signed(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }
}
