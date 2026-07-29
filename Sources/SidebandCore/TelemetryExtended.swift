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

public struct SidebandPhysicalLink: Codable, Hashable, Sendable {
    public var rssi: Double?
    public var snr: Double?
    public var qualityPercent: Double?
    public init(rssi: Double? = nil, snr: Double? = nil, qualityPercent: Double? = nil) {
        self.rssi = rssi; self.snr = snr; self.qualityPercent = qualityPercent
    }
}

public struct SidebandPowerEntry: Codable, Hashable, Sendable {
    public var label: String
    public var watts: Double
    public var icon: String?
    public init(label: String, watts: Double, icon: String? = nil) {
        self.label = String(label.prefix(80)); self.watts = watts; self.icon = icon.map { String($0.prefix(80)) }
    }
}

public struct SidebandProcessorEntry: Codable, Hashable, Sendable {
    public var label: String
    public var currentLoadPercent: Double
    public var loadAverages: [Double]
    public var clockMHz: Double?
    public init(label: String, currentLoadPercent: Double, loadAverages: [Double] = [], clockMHz: Double? = nil) {
        self.label = String(label.prefix(80)); self.currentLoadPercent = currentLoadPercent
        self.loadAverages = Array(loadAverages.prefix(3)); self.clockMHz = clockMHz
    }
}

public struct SidebandCapacityEntry: Codable, Hashable, Sendable {
    public var label: String
    public var capacity: Double
    public var used: Double
    public init(label: String, capacity: Double, used: Double) {
        self.label = String(label.prefix(80)); self.capacity = capacity; self.used = used
    }
    public var usedPercent: Double? { capacity > 0 ? min(100, max(0, used / capacity * 100)) : nil }
}

public struct SidebandTankEntry: Codable, Hashable, Sendable {
    public var label: String
    public var capacity: Double
    public var level: Double
    public var unit: String
    public var icon: String?
    public init(label: String, capacity: Double, level: Double, unit: String = "L", icon: String? = nil) {
        self.label = String(label.prefix(80)); self.capacity = capacity; self.level = level
        self.unit = String(unit.prefix(24)); self.icon = icon.map { String($0.prefix(80)) }
    }
    public var levelPercent: Double? { capacity > 0 ? min(100, max(0, level / capacity * 100)) : nil }
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
    var physicalLink: SidebandPhysicalLink? {
        guard let values = sensorArray(.physicalLink), values.count >= 3 else { return nil }
        let result = SidebandPhysicalLink(rssi: values[0].optionalNumber, snr: values[1].optionalNumber, qualityPercent: values[2].optionalNumber)
        guard [result.rssi, result.snr, result.qualityPercent].contains(where: { $0 != nil }) else { return nil }
        return result
    }
    var powerConsumption: [SidebandPowerEntry] { powerEntries(.powerConsumption) }
    var powerProduction: [SidebandPowerEntry] { powerEntries(.powerProduction) }
    var processors: [SidebandProcessorEntry] {
        labelledEntries(.processor).compactMap { label, value in
            guard case let .array(parts) = value, parts.count >= 3,
                  let load = parts[0].number, load.isFinite else { return nil }
            let averages: [Double]
            if case let .array(values) = parts[1] { averages = Array(values.compactMap(\.optionalNumber).prefix(3)) }
            else { averages = [] }
            return SidebandProcessorEntry(label: label, currentLoadPercent: load, loadAverages: averages, clockMHz: parts[2].optionalNumber)
        }
    }
    var memory: [SidebandCapacityEntry] { capacityEntries(.ram) }
    var storage: [SidebandCapacityEntry] { capacityEntries(.nonVolatileMemory) }
    var tanks: [SidebandTankEntry] { tankEntries(.tank, fallbackLabel: "Tank") }
    var fuel: [SidebandTankEntry] { tankEntries(.fuel, fallbackLabel: "Fuel") }

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

    mutating func setPhysicalLink(_ value: SidebandPhysicalLink?) {
        guard let value else { additionalSensors.removeValue(forKey: SensorKind.physicalLink.rawValue); return }
        let number: (Double?) -> Data = { $0.map(MessagePack.double) ?? MessagePack.null }
        additionalSensors[SensorKind.physicalLink.rawValue] = MessagePack.array([number(value.rssi), number(value.snr), number(value.qualityPercent)])
    }

    mutating func setPowerEntries(_ entries: [SidebandPowerEntry], production: Bool) {
        let kind: SensorKind = production ? .powerProduction : .powerConsumption
        let bounded = Array(entries.filter { $0.watts.isFinite }.prefix(32))
        guard !bounded.isEmpty else { additionalSensors.removeValue(forKey: kind.rawValue); return }
        additionalSensors[kind.rawValue] = MessagePack.array(bounded.map {
            MessagePack.array([
                labelValue($0.label),
                MessagePack.array([MessagePack.double($0.watts), $0.icon.map(MessagePack.string) ?? MessagePack.null])
            ])
        })
    }

    mutating func setCapacityEntries(_ entries: [SidebandCapacityEntry], kind: SensorKind) {
        guard kind == .ram || kind == .nonVolatileMemory else { return }
        let bounded = Array(entries.filter { $0.capacity.isFinite && $0.used.isFinite && $0.capacity >= 0 && $0.used >= 0 }.prefix(32))
        guard !bounded.isEmpty else { additionalSensors.removeValue(forKey: kind.rawValue); return }
        additionalSensors[kind.rawValue] = MessagePack.array(bounded.map {
            MessagePack.array([labelValue($0.label), MessagePack.array([MessagePack.double($0.capacity), MessagePack.double($0.used)])])
        })
    }

    mutating func setTankEntries(_ entries: [SidebandTankEntry], kind: SensorKind) {
        guard kind == .tank || kind == .fuel else { return }
        let bounded = Array(entries.filter { $0.capacity.isFinite && $0.level.isFinite && $0.capacity >= 0 && $0.level >= 0 }.prefix(32))
        guard !bounded.isEmpty else { additionalSensors.removeValue(forKey: kind.rawValue); return }
        additionalSensors[kind.rawValue] = MessagePack.array(bounded.map {
            MessagePack.array([
                labelValue($0.label),
                MessagePack.array([
                    MessagePack.double($0.capacity), MessagePack.double($0.level),
                    MessagePack.string($0.unit), $0.icon.map(MessagePack.string) ?? MessagePack.null
                ])
            ])
        })
    }

    private func scalarSensor(_ kind: SensorKind) -> Double? {
        guard let encoded = additionalSensors[kind.rawValue], let value = try? MessagePackDecoder.decode(encoded) else { return nil }
        return value.number
    }

    private func vectorSensor(_ kind: SensorKind) -> SidebandVector3? { SidebandVector3(packed: additionalSensors[kind.rawValue]) }
    private func sensorArray(_ kind: SensorKind) -> [MessagePackValue]? {
        guard let encoded = additionalSensors[kind.rawValue],
              case let .array(values)? = try? MessagePackDecoder.decode(encoded) else { return nil }
        return values
    }
    private func labelledEntries(_ kind: SensorKind) -> [(String, MessagePackValue)] {
        (sensorArray(kind) ?? []).compactMap { entry in
            guard case let .array(parts) = entry, parts.count == 2 else { return nil }
            return (parts[0].label(default: kind.displayName), parts[1])
        }
    }
    private func powerEntries(_ kind: SensorKind) -> [SidebandPowerEntry] {
        labelledEntries(kind).compactMap { label, value in
            guard case let .array(parts) = value, let watts = parts.first?.number, watts.isFinite else { return nil }
            return SidebandPowerEntry(label: label, watts: watts, icon: parts.count > 1 ? parts[1].optionalString : nil)
        }
    }
    private func capacityEntries(_ kind: SensorKind) -> [SidebandCapacityEntry] {
        labelledEntries(kind).compactMap { label, value in
            guard case let .array(parts) = value, parts.count >= 2,
                  let capacity = parts[0].number, let used = parts[1].number,
                  capacity.isFinite, used.isFinite, capacity >= 0, used >= 0 else { return nil }
            return SidebandCapacityEntry(label: label, capacity: capacity, used: used)
        }
    }
    private func tankEntries(_ kind: SensorKind, fallbackLabel: String) -> [SidebandTankEntry] {
        labelledEntries(kind).compactMap { label, value in
            guard case let .array(parts) = value, parts.count >= 2,
                  let capacity = parts[0].number, let level = parts[1].number,
                  capacity.isFinite, level.isFinite, capacity >= 0, level >= 0 else { return nil }
            return SidebandTankEntry(
                label: label == kind.displayName ? fallbackLabel : label,
                capacity: capacity, level: level,
                unit: parts.count > 2 ? parts[2].optionalString ?? "L" : "L",
                icon: parts.count > 3 ? parts[3].optionalString : nil
            )
        }
    }
    private func labelValue(_ label: String) -> Data {
        let defaults = ["Power consumption", "Power production", "Processor", "Memory", "Storage", "Tank", "Fuel"]
        return defaults.contains(label) ? MessagePack.unsigned(0) : MessagePack.string(String(label.prefix(80)))
    }
}

public enum SidebandTelemetryMetric: String, Codable, CaseIterable, Sendable {
    case batteryPercent, pressureMillibars, temperatureCelsius, humidityPercent, ambientLightLux
    case linkRSSI, linkSNR, linkQualityPercent, processorLoadPercent
    case memoryUsedPercent, storageUsedPercent, tankLevelPercent, fuelLevelPercent
    case powerConsumptionWatts, powerProductionWatts
}

public enum SidebandTelemetryComparison: String, Codable, Sendable { case above, below }
public enum SidebandTelemetryAlertSeverity: String, Codable, Sendable { case information, warning, critical }

public struct SidebandTelemetryAlert: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let ruleID: UUID
    public let metric: SidebandTelemetryMetric
    public let value: Double
    public let threshold: Double
    public let severity: SidebandTelemetryAlertSeverity
    public let message: String
    public let capturedAt: Date
}

public struct SidebandTelemetryAlertRule: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var metric: SidebandTelemetryMetric
    public var comparison: SidebandTelemetryComparison
    public var threshold: Double
    public var severity: SidebandTelemetryAlertSeverity
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, metric: SidebandTelemetryMetric, comparison: SidebandTelemetryComparison, threshold: Double, severity: SidebandTelemetryAlertSeverity = .warning, isEnabled: Bool = true) {
        self.id = id; self.name = String(name.prefix(80)); self.metric = metric
        self.comparison = comparison; self.threshold = threshold; self.severity = severity; self.isEnabled = isEnabled
    }

    public func evaluate(_ telemetry: SidebandTelemetry) -> SidebandTelemetryAlert? {
        guard isEnabled, threshold.isFinite, let value = telemetry.value(for: metric), value.isFinite else { return nil }
        let triggered = comparison == .above ? value > threshold : value < threshold
        guard triggered else { return nil }
        let relation = comparison == .above ? "above" : "below"
        return SidebandTelemetryAlert(
            id: UUID(), ruleID: id, metric: metric, value: value, threshold: threshold,
            severity: severity, message: "\(name): \(value.formatted()) is \(relation) \(threshold.formatted()).",
            capturedAt: telemetry.capturedAt
        )
    }
}

public extension SidebandTelemetry {
    func value(for metric: SidebandTelemetryMetric) -> Double? {
        switch metric {
        case .batteryPercent: battery?.chargePercent
        case .pressureMillibars: pressureMillibars
        case .temperatureCelsius: temperatureCelsius
        case .humidityPercent: relativeHumidityPercent
        case .ambientLightLux: ambientLightLux
        case .linkRSSI: physicalLink?.rssi
        case .linkSNR: physicalLink?.snr
        case .linkQualityPercent: physicalLink?.qualityPercent
        case .processorLoadPercent: processors.first?.currentLoadPercent
        case .memoryUsedPercent: memory.first?.usedPercent
        case .storageUsedPercent: storage.first?.usedPercent
        case .tankLevelPercent: tanks.first?.levelPercent
        case .fuelLevelPercent: fuel.first?.levelPercent
        case .powerConsumptionWatts:
            powerConsumption.isEmpty ? nil : powerConsumption.reduce(0) { $0 + $1.watts }
        case .powerProductionWatts:
            powerProduction.isEmpty ? nil : powerProduction.reduce(0) { $0 + $1.watts }
        }
    }
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
    var optionalNumber: Double? { self == .null ? nil : number }
    var optionalString: String? {
        switch self {
        case .string(let value): value
        case .binary(let value): String(data: value, encoding: .utf8)
        default: nil
        }
    }
    func label(default fallback: String) -> String {
        switch self {
        case .unsigned(0), .signed(0): fallback
        default: optionalString.map { String($0.prefix(80)) } ?? fallback
        }
    }
}
