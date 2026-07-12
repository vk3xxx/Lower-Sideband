import Foundation
#if os(iOS)
import BackgroundTasks
#endif

@MainActor
public final class BackgroundRefreshCoordinator {
    public static let identifier = "io.unsigned.sideband.swift.refresh"
    private var isRegistered = false

    public init() { }

    public func register(handler: @escaping @MainActor () async -> Void) {
#if os(iOS)
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                await handler()
                refresh.setTaskCompleted(success: !Task.isCancelled)
            }
            refresh.expirationHandler = { work.cancel() }
        }
#endif
    }

    public func schedule() {
#if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
#endif
    }
}
