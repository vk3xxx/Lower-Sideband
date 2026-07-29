import ReticulumKit
import Foundation

public struct SidebandVector3: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public var packed: Data { MessagePack.array([MessagePack.double(x), MessagePack.double(y), MessagePack.double(z)]) }
    public init?(packed: Data?) {
        guard let packed, case let .array(values) = try? MessagePackDecoder.decode(packed), values.count == 3,
              let x = values[0].number, let y = values[1].number, let z = values[2].number,
              x.isFinite, y.isFinite, z.isFinite else { return nil }
        self.init(x: x, y: y, z: z)
    }
}

public extension SidebandTelemetry {
    var pressureMillibars: Double? { scalarSensor(.pressure) }
    var temperatureCelsius: Double? { scalarSensor(.temperature) }
    var relativeHumidityPercent: Double? { scalarSensor(.humidity) }
    var ambientLightLux: Double? { scalarSensor(.ambientLight) }
    var acceleration: SidebandVector3? { vectorSensor(.acceleration) }
    var magneticField: SidebandVector3? { vectorSensor(.magneticField) }
    var gravity: SidebandVector3? { vectorSensor(.gravity) }
    var angularVelocity: SidebandVector3? { vectorSensor(.angularVelocity) }

    mutating func setScalarSensor(_ kind: SensorKind, value: Double?) {
        guard kind != .time, kind != .location, kind != .battery else { return }
        if let value, value.isFinite { additionalSensors[kind.rawValue] = MessagePack.double(value) }
        else { additionalSensors.removeValue(forKey: kind.rawValue) }
    }

    mutating func setVectorSensor(_ kind: SensorKind, value: SidebandVector3?) {
        guard kind == .acceleration || kind == .magneticField || kind == .gravity || kind == .angularVelocity else { return }
        if let value { additionalSensors[kind.rawValue] = value.packed }
        else { additionalSensors.removeValue(forKey: kind.rawValue) }
    }

    private func scalarSensor(_ kind: SensorKind) -> Double? {
        guard let encoded = additionalSensors[kind.rawValue], let value = try? MessagePackDecoder.decode(encoded) else { return nil }
        return value.number
    }

    private func vectorSensor(_ kind: SensorKind) -> SidebandVector3? { SidebandVector3(packed: additionalSensors[kind.rawValue]) }
}

public struct SidebandTelemetrySchedule: Codable, Hashable, Sendable {
    public var interval: TimeInterval
    public var requestInterval: TimeInterval?
    public var propagationOnly: Bool
    public var excludedDestinationHashes: Set<String>

    public init(interval: TimeInterval = 60 * 60, requestInterval: TimeInterval? = nil, propagationOnly: Bool = false, excludedDestinationHashes: Set<String> = []) {
        self.interval = min(max(interval, 60), 7 * 24 * 60 * 60)
        self.requestInterval = requestInterval.map { min(max($0, 60), 7 * 24 * 60 * 60) }
        self.propagationOnly = propagationOnly
        self.excludedDestinationHashes = Set(excludedDestinationHashes.filter(DestinationHash.isValid))
    }

    public func shouldSend(lastSent: Date?, now: Date = .now, destinationHash: String) -> Bool {
        !excludedDestinationHashes.contains(destinationHash) && now.timeIntervalSince(lastSent ?? .distantPast) >= interval
    }
}

public enum SidebandTelemetryMQTT {
    /// Produces retained MQTT topic/value pairs without embedding broker credentials.
    public static func records(_ telemetry: SidebandTelemetry, root: String, source: String) -> [(topic: String, value: String)] {
        let safeRoot = topicComponent(root), safeSource = topicComponent(source)
        let prefix = "\(safeRoot)/\(safeSource)"
        var values = [("\(prefix)/time", ISO8601DateFormatter().string(from: telemetry.capturedAt))]
        if let location = telemetry.location {
            values += [("\(prefix)/location/latitude", String(location.latitude)), ("\(prefix)/location/longitude", String(location.longitude)), ("\(prefix)/location/altitude", String(location.altitude))]
        }
        if let battery = telemetry.battery { values.append(("\(prefix)/battery/percent", String(battery.chargePercent))) }
        if let pressure = telemetry.pressureMillibars { values.append(("\(prefix)/pressure/mbar", String(pressure))) }
        if let temperature = telemetry.temperatureCelsius { values.append(("\(prefix)/temperature/celsius", String(temperature))) }
        if let humidity = telemetry.relativeHumidityPercent { values.append(("\(prefix)/humidity/percent", String(humidity))) }
        return values
    }

    private static func topicComponent(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) ? Character($0) : "_" }.prefix(80))
    }
}

private extension MessagePackValue {
    var number: Double? {
        switch self { case .unsigned(let v): Double(v); case .signed(let v): Double(v); case .double(let v): v; default: nil }
    }
}
