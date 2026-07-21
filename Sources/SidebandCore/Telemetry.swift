import Foundation

public struct SidebandTelemetry: Codable, Hashable, Sendable {
    public enum SensorKind: UInt8, CaseIterable, Codable, Hashable, Sendable {
        case time = 0x01, location = 0x02, pressure = 0x03, battery = 0x04
        case physicalLink = 0x05, acceleration = 0x06, temperature = 0x07, humidity = 0x08
        case magneticField = 0x09, ambientLight = 0x0A, gravity = 0x0B, angularVelocity = 0x0C
        case proximity = 0x0E, information = 0x0F, received = 0x10
        case powerConsumption = 0x11, powerProduction = 0x12, processor = 0x13
        case ram = 0x14, nonVolatileMemory = 0x15, tank = 0x16, fuel = 0x17
        case lxmfPropagation = 0x18, rnsTransport = 0x19, connectionMap = 0x1A, custom = 0xFF

        public var displayName: String {
            switch self {
            case .time: "Timestamp"
            case .location: "Location"
            case .pressure: "Ambient pressure"
            case .battery: "Battery"
            case .physicalLink: "Physical link"
            case .acceleration: "Acceleration"
            case .temperature: "Temperature"
            case .humidity: "Humidity"
            case .magneticField: "Magnetic field"
            case .ambientLight: "Ambient light"
            case .gravity: "Gravity"
            case .angularVelocity: "Angular velocity"
            case .proximity: "Proximity"
            case .information: "Information"
            case .received: "Received"
            case .powerConsumption: "Power consumption"
            case .powerProduction: "Power production"
            case .processor: "Processor"
            case .ram: "Memory"
            case .nonVolatileMemory: "Storage"
            case .tank: "Tank"
            case .fuel: "Fuel"
            case .lxmfPropagation: "LXMF propagation"
            case .rnsTransport: "Reticulum transport"
            case .connectionMap: "Connection map"
            case .custom: "Custom"
            }
        }
    }

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
    /// Canonical MessagePack values for every upstream telemetry sensor not
    /// represented by a strongly typed property. Keeping the encoded value
    /// makes the Swift client lossless when relaying newer or plugin sensors.
    public var additionalSensors: [UInt8: Data]

    public init(capturedAt: Date = .now, location: Location? = nil, battery: Battery? = nil, additionalSensors: [UInt8: Data] = [:]) {
        self.capturedAt = capturedAt
        self.location = location
        self.battery = battery
        self.additionalSensors = additionalSensors
    }

    public var sensorKinds: [SensorKind] {
        var kinds: Set<SensorKind> = [.time]
        if location != nil { kinds.insert(.location) }
        if battery != nil { kinds.insert(.battery) }
        kinds.formUnion(additionalSensors.keys.compactMap(SensorKind.init(rawValue:)))
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    public var mostRecentSensorDate: Date { max(capturedAt, location?.updatedAt ?? capturedAt) }

    public func isFresh(relativeTo date: Date = .now, maximumAge: TimeInterval = 15 * 60) -> Bool {
        let age = date.timeIntervalSince(mostRecentSensorDate)
        return age >= -5 * 60 && age <= maximumAge
    }

    public var validationError: String? {
        let supportedDates = Date(timeIntervalSince1970: 946_684_800)...Date(timeIntervalSince1970: 4_102_444_800)
        guard supportedDates.contains(capturedAt) else { return "Telemetry timestamp is outside the supported range." }
        if let location {
            guard location.latitude.isFinite, location.longitude.isFinite,
                  (-90...90).contains(location.latitude), (-180...180).contains(location.longitude) else { return "Telemetry coordinates are invalid." }
            guard location.altitude.isFinite, (-20_000...100_000).contains(location.altitude),
                  location.speed.isFinite, (0...2_000).contains(location.speed),
                  location.bearing.isFinite, (-360...360).contains(location.bearing),
                  location.accuracy.isFinite, (0...100_000).contains(location.accuracy),
                  supportedDates.contains(location.updatedAt) else { return "Telemetry location metadata is invalid." }
        }
        if let battery {
            guard battery.chargePercent.isFinite, (0...100).contains(battery.chargePercent),
                  battery.temperature.map({ $0.isFinite && (-100...200).contains($0) }) ?? true else { return "Telemetry battery data is invalid." }
        }
        return nil
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
        for (identifier, encoded) in additionalSensors.sorted(by: { $0.key < $1.key })
            where UInt64(identifier) != SensorID.time && UInt64(identifier) != SensorID.location && UInt64(identifier) != SensorID.battery {
            guard encoded.count <= 65_536, (try? MessagePackDecoder.decode(encoded)) != nil else { continue }
            sensors.append((UInt64(identifier), encoded))
        }
        return MessagePack.map(sensors)
    }

    public init(packed: Data) throws {
        guard case let .map(entries) = try MessagePackDecoder.decode(packed) else { throw DecodeError.invalidPayload }
        var timestamp: Date?
        var decodedLocation: Location?
        var decodedBattery: Battery?
        var decodedAdditional: [UInt8: Data] = [:]
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
                guard sensorID <= UInt64(UInt8.max), decodedAdditional.count < 64 else { continue }
                let encoded = MessagePack.encode(value)
                guard encoded.count <= 65_536 else { continue }
                decodedAdditional[UInt8(sensorID)] = encoded
            }
        }
        capturedAt = timestamp ?? decodedLocation?.updatedAt ?? .distantPast
        location = decodedLocation
        battery = decodedBattery
        additionalSensors = decodedAdditional
        guard validationError == nil else { throw DecodeError.invalidPayload }
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

public enum SidebandTelemetryExportFormat: String, CaseIterable, Sendable {
    case csv
    case gpx
}

public struct SidebandTelemetryStreamEntry: Codable, Hashable, Sendable {
    public var sourceHash: Data
    public var timestamp: Date
    public var telemetry: SidebandTelemetry
    public var encodedAppearance: Data?

    public init(sourceHash: Data, timestamp: Date, telemetry: SidebandTelemetry, encodedAppearance: Data? = nil) {
        self.sourceHash = sourceHash
        self.timestamp = timestamp
        self.telemetry = telemetry
        self.encodedAppearance = encodedAppearance
    }

    public var encoded: Data? {
        guard sourceHash.count == 16, telemetry.validationError == nil else { return nil }
        return MessagePack.array([
            MessagePack.binary(sourceHash), MessagePack.double(timestamp.timeIntervalSince1970),
            MessagePack.binary(telemetry.packed()), encodedAppearance ?? MessagePack.null
        ])
    }

    public static func encode(_ entries: [Self]) -> Data? {
        guard entries.count <= 512 else { return nil }
        let encoded = entries.compactMap(\.encoded)
        return encoded.count == entries.count ? MessagePack.array(encoded) : nil
    }

    public static func decode(_ value: MessagePackValue?) -> [Self] {
        guard case let .array(entries) = value, entries.count <= 512 else { return [] }
        return entries.compactMap { entry in
            guard case let .array(parts) = entry, parts.count == 4,
                  case let .binary(source) = parts[0], source.count == 16,
                  let timestamp = parts[1].numberValue,
                  case let .binary(packed) = parts[2], packed.count <= 65_536,
                  let telemetry = try? SidebandTelemetry(packed: packed) else { return nil }
            return Self(sourceHash: source, timestamp: Date(timeIntervalSince1970: timestamp), telemetry: telemetry,
                        encodedAppearance: parts[3] == .null ? nil : MessagePack.encode(parts[3]))
        }
    }
}

public struct SidebandTelemetryHistorySummary: Equatable, Sendable {
    public let sampleCount: Int
    public let locationCount: Int
    public let firstAt: Date?
    public let lastAt: Date?
    public let distanceMeters: Double

    public var duration: TimeInterval { max(0, (lastAt ?? .distantPast).timeIntervalSince(firstAt ?? .distantPast)) }
}

public enum SidebandTelemetryHistory {
    public static func summary(messages: [Message]) -> SidebandTelemetryHistorySummary {
        let samples = messages.compactMap(\.telemetry).sorted { $0.mostRecentSensorDate < $1.mostRecentSensorDate }
        let locations = samples.compactMap(\.location)
        let distance = zip(locations, locations.dropFirst()).reduce(0.0) { total, pair in
            total + distanceMeters(from: pair.0, to: pair.1)
        }
        return SidebandTelemetryHistorySummary(
            sampleCount: samples.count,
            locationCount: locations.count,
            firstAt: samples.first?.mostRecentSensorDate,
            lastAt: samples.last?.mostRecentSensorDate,
            distanceMeters: distance
        )
    }

    public static func export(messages: [Message], contactName: String, format: SidebandTelemetryExportFormat) -> Data? {
        let records = messages.compactMap { message -> (Message, SidebandTelemetry.Location, SidebandTelemetry.Battery?)? in
            guard let telemetry = message.telemetry, let location = telemetry.location, telemetry.validationError == nil else { return nil }
            return (message, location, telemetry.battery)
        }.sorted { $0.1.updatedAt < $1.1.updatedAt }
        guard !records.isEmpty, records.count <= 10_000 else { return nil }
        switch format {
        case .csv:
            var lines = ["timestamp,direction,latitude,longitude,altitude_m,speed_kmh,bearing_deg,accuracy_m,battery_percent,charging"]
            lines += records.map { message, location, battery in
                [
                    iso8601(location.updatedAt), message.direction.rawValue,
                    String(location.latitude), String(location.longitude), String(location.altitude),
                    String(location.speed), String(location.bearing), String(location.accuracy),
                    battery.map { String($0.chargePercent) } ?? "", battery.map { String($0.isCharging) } ?? ""
                ].joined(separator: ",")
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .gpx:
            let trackPoints = records.map { _, location, _ in
                "<trkpt lat=\"\(location.latitude)\" lon=\"\(location.longitude)\"><ele>\(location.altitude)</ele><time>\(iso8601(location.updatedAt))</time><hdop>\(location.accuracy)</hdop></trkpt>"
            }.joined()
            let name = xmlEscaped(String(contactName.prefix(80)))
            return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Lower Sideband\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(name)</name><trkseg>\(trackPoints)</trkseg></trk></gpx>".utf8)
        }
    }

    private static func distanceMeters(from lhs: SidebandTelemetry.Location, to rhs: SidebandTelemetry.Location) -> Double {
        let radius = 6_371_000.0
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let lhsLatitude = lhs.latitude * .pi / 180
        let rhsLatitude = rhs.latitude * .pi / 180
        let a = pow(sin(latitudeDelta / 2), 2) + cos(lhsLatitude) * cos(rhsLatitude) * pow(sin(longitudeDelta / 2), 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
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
