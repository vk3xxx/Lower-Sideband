import Foundation
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
public final class BackgroundRefreshCoordinator {
    public static let identifier = "com.supes.MacSideband.refresh"
    private var isRegistered = false

    public init() { }

    public func register(handler: @escaping @MainActor () async -> Bool) {
#if os(iOS)
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                self.schedule()
                let succeeded = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await handler() }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(25))
                        return false
                    }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
                refresh.setTaskCompleted(success: succeeded && !Task.isCancelled)
            }
            refresh.expirationHandler = { work.cancel() }
        }
#endif
    }

    public func schedule() {
#if os(iOS)
        guard isRegistered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
#endif
    }
}
