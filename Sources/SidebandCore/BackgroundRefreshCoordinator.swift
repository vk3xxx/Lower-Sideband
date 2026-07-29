import ReticulumKit
import Foundation
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
public final class BackgroundRefreshCoordinator {
    public static let identifier = "com.supes.MacSideband.refresh"
    public static let processingIdentifier = "com.supes.MacSideband.propagation-processing"
    private var isRegistered = false

    public init() { }

    public func register(handler: @escaping @MainActor () async -> Bool) {
#if os(iOS)
        guard !isRegistered else { return }
        let register: (String, TimeInterval) -> Void = { identifier, timeout in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                let work = Task { @MainActor in
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
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = max(earliest ?? .distantPast, Date(timeIntervalSinceNow: 15 * 60))
        try? BGTaskScheduler.shared.submit(request)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.earliestBeginDate = request.earliestBeginDate
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
#endif
    }
}
