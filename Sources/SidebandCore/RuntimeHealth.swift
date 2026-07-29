import ReticulumKit
import Foundation
import Observation

@MainActor @Observable
public final class SidebandRuntimeHealth {
    public private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    public private(set) var thermalState = ProcessInfo.processInfo.thermalState
    public private(set) var memoryPressureEvents = 0
    public private(set) var foregroundTransitions = 0
    public private(set) var backgroundTransitions = 0
    public private(set) var reachabilityTransitions = 0
    public private(set) var backgroundWakeAttempts = 0
    public private(set) var backgroundWakeSuccesses = 0
    public private(set) var metricPayloadsReceived = 0
    public private(set) var diagnosticPayloadsReceived = 0
    public private(set) var cumulativeForegroundSeconds: TimeInterval = 0
    public private(set) var lastForegroundAt: Date?
    public private(set) var lastBackgroundAt: Date?
    public private(set) var lastReachabilityChangeAt: Date?
    public private(set) var lastBackgroundWakeDuration: TimeInterval?
    public private(set) var lastMetricPayloadAt: Date?
    public private(set) var updatedAt = Date()
    private var observers: [NSObjectProtocol] = []
    private var foregroundStartedAt: Date?

    public init() {
        let defaults = UserDefaults.standard
        memoryPressureEvents = defaults.integer(forKey: "runtime.memoryPressureEvents")
        foregroundTransitions = defaults.integer(forKey: "runtime.foregroundTransitions")
        backgroundTransitions = defaults.integer(forKey: "runtime.backgroundTransitions")
        reachabilityTransitions = defaults.integer(forKey: "runtime.reachabilityTransitions")
        backgroundWakeAttempts = defaults.integer(forKey: "runtime.backgroundWakeAttempts")
        backgroundWakeSuccesses = defaults.integer(forKey: "runtime.backgroundWakeSuccesses")
        metricPayloadsReceived = defaults.integer(forKey: "runtime.metricPayloadsReceived")
        diagnosticPayloadsReceived = defaults.integer(forKey: "runtime.diagnosticPayloadsReceived")
        cumulativeForegroundSeconds = defaults.double(forKey: "runtime.cumulativeForegroundSeconds")
        lastForegroundAt = defaults.object(forKey: "runtime.lastForegroundAt") as? Date
        lastBackgroundAt = defaults.object(forKey: "runtime.lastBackgroundAt") as? Date
        lastReachabilityChangeAt = defaults.object(forKey: "runtime.lastReachabilityChangeAt") as? Date
        lastBackgroundWakeDuration = defaults.object(forKey: "runtime.lastBackgroundWakeDuration") as? TimeInterval
        lastMetricPayloadAt = defaults.object(forKey: "runtime.lastMetricPayloadAt") as? Date
    }

    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    public func recordMemoryPressure() {
        memoryPressureEvents += 1
        persist("runtime.memoryPressureEvents", memoryPressureEvents)
    }

    public func recordForeground(at date: Date = .now) {
        guard foregroundStartedAt == nil else { return }
        foregroundStartedAt = date
        foregroundTransitions += 1
        lastForegroundAt = date
        persist("runtime.foregroundTransitions", foregroundTransitions)
        persist("runtime.lastForegroundAt", date)
    }

    public func recordBackground(at date: Date = .now) {
        if let foregroundStartedAt {
            cumulativeForegroundSeconds += max(0, date.timeIntervalSince(foregroundStartedAt))
            self.foregroundStartedAt = nil
            persist("runtime.cumulativeForegroundSeconds", cumulativeForegroundSeconds)
        }
        backgroundTransitions += 1
        lastBackgroundAt = date
        persist("runtime.backgroundTransitions", backgroundTransitions)
        persist("runtime.lastBackgroundAt", date)
    }

    public func recordReachabilityTransition(at date: Date = .now) {
        reachabilityTransitions += 1
        lastReachabilityChangeAt = date
        persist("runtime.reachabilityTransitions", reachabilityTransitions)
        persist("runtime.lastReachabilityChangeAt", date)
    }

    public func recordBackgroundWake(succeeded: Bool, duration: TimeInterval) {
        backgroundWakeAttempts += 1
        if succeeded { backgroundWakeSuccesses += 1 }
        lastBackgroundWakeDuration = max(0, duration)
        persist("runtime.backgroundWakeAttempts", backgroundWakeAttempts)
        persist("runtime.backgroundWakeSuccesses", backgroundWakeSuccesses)
        persist("runtime.lastBackgroundWakeDuration", lastBackgroundWakeDuration)
    }

    /// Records only aggregate MetricKit delivery counts. Payload content
    /// remains in Apple's MetricKit pipeline and is never mixed with messages,
    /// attachments, identities, or application analytics.
    public func recordMetricKitPayloads(metrics: Int, diagnostics: Int, at date: Date = .now) {
        guard metrics >= 0, diagnostics >= 0, metrics > 0 || diagnostics > 0 else { return }
        metricPayloadsReceived += metrics
        diagnosticPayloadsReceived += diagnostics
        lastMetricPayloadAt = date
        persist("runtime.metricPayloadsReceived", metricPayloadsReceived)
        persist("runtime.diagnosticPayloadsReceived", diagnosticPayloadsReceived)
        persist("runtime.lastMetricPayloadAt", date)
    }

    public var shouldReduceBackgroundWork: Bool {
        isLowPowerModeEnabled || thermalState == .serious || thermalState == .critical
    }

    public var backgroundWakeSuccessRate: Double? {
        guard backgroundWakeAttempts > 0 else { return nil }
        return Double(backgroundWakeSuccesses) / Double(backgroundWakeAttempts)
    }

    public var currentForegroundSeconds: TimeInterval {
        cumulativeForegroundSeconds + (foregroundStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
    }

    private func refresh() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = ProcessInfo.processInfo.thermalState
        updatedAt = .now
    }

    private func persist(_ key: String, _ value: Any?) {
        UserDefaults.standard.set(value, forKey: key)
        updatedAt = .now
    }
}
