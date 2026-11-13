import BackgroundTasks
import Foundation

/// Overnight refinement (speed-up 7): runs while the iPhone is charging, refines town
/// names, reads iCloud originals if allowed and refreshes proposals.
enum BackgroundWork {
    private struct TaskBox: @unchecked Sendable { let task: BGTask }

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppInfo.refinementTaskID, using: nil) { task in
            let box = TaskBox(task: task)
            let work = Task { @MainActor in
                let success = await AppModel.shared.runBackgroundRefinement()
                box.task.setTaskCompleted(success: success)
                scheduleRefinement()
            }
            box.task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleRefinement() {
        let request = BGProcessingTaskRequest(identifier: AppInfo.refinementTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not available in the simulator or when Background App Refresh is off;
            // the app then refines on the next launch instead.
        }
    }
}
