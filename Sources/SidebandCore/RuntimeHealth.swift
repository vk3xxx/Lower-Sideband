import ReticulumKit
import Foundation
import Observation

@MainActor @Observable
public final class SidebandRuntimeHealth {
    public private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    public private(set) var thermalState = ProcessInfo.processInfo.thermalState
    public private(set) var memoryPressureEvents = 0
    public private(set) var updatedAt = Date()
    private var observers: [NSObjectProtocol] = []

    public init() {}

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
        memoryPressureEvents += 1; updatedAt = .now
    }

    public var shouldReduceBackgroundWork: Bool {
        isLowPowerModeEnabled || thermalState == .serious || thermalState == .critical
    }

    private func refresh() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = ProcessInfo.processInfo.thermalState
        updatedAt = .now
    }
}
