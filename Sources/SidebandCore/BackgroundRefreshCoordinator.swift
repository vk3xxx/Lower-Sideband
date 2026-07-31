import ReticulumKit
import Foundation
#if os(iOS)
import BackgroundTasks
#endif

public enum BackgroundRefreshSchedulePolicy {
    /// BGTaskScheduler accepts an earliest date, not a fixed alarm. Preserve a
    /// real scheduled-send deadline instead of imposing the old fifteen-minute
    /// application delay; iOS remains free to choose the actual execution time.
    public static func candidateDate(requested: Date?, now: Date = .now) -> Date {
        max(requested ?? Date(timeInterval: 15 * 60, since: now), Date(timeInterval: 5, since: now))
    }

    public static func shouldReplace(current: Date?, with candidate: Date) -> Bool {
        guard let current else { return true }
        return candidate.timeIntervalSince(current) < -1
    }
}

@MainActor
public final class BackgroundRefreshCoordinator {
    public static let identifier = "com.supes.MacSideband.refresh"
    public static let processingIdentifier = "com.supes.MacSideband.propagation-processing"
    private var isRegistered = false
    public private(set) var pendingEarliestDate: Date?

    public init() { }

    public func register(handler: @escaping @MainActor () async -> Bool) {
#if os(iOS)
        guard !isRegistered else { return }
        let register: (String, TimeInterval) -> Void = { identifier, timeout in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                let work = Task { @MainActor in
                    self.pendingEarliestDate = nil
                    self.schedule()
                    let succeeded = await withTaskGroup(of: Bool.self) { group in
                        group.addTask { await handler() }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(timeout))
                            return false
                        }
                        let result = await group.next() ?? false
                        group.cancelAll()
                        return result
                    }
                    task.setTaskCompleted(success: succeeded && !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
        register(Self.identifier, 25)
        register(Self.processingIdentifier, 55)
        isRegistered = true
#endif
    }

    public func schedule(earliest: Date? = nil) {
#if os(iOS)
        guard isRegistered else { return }
        let candidate = BackgroundRefreshSchedulePolicy.candidateDate(requested: earliest)
        guard BackgroundRefreshSchedulePolicy.shouldReplace(current: pendingEarliestDate, with: candidate) else { return }
        pendingEarliestDate = candidate
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = candidate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            pendingEarliestDate = nil
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.earliestBeginDate = candidate
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
#endif
    }
}
