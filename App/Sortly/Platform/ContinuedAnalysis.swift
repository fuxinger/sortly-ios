import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// iOS 26 continued processing: a long analysis the user started keeps running after they
/// leave the app, and the system shows its progress on the Lock Screen and in the Dynamic
/// Island. When it ends while Albumist is in the background, a local notification says so.
@MainActor
enum ContinuedAnalysis {
    nonisolated static let taskID = AppInfo.continuedAnalysisTaskPrefix + ".continued"
    private static var registered = false
    private struct TaskBox: @unchecked Sendable { let task: BGContinuedProcessingTask }

    /// Call right after a user action that starts a long analysis (must be in the foreground).
    static func begin() {
        registerIfNeeded()
        let request = BGContinuedProcessingTaskRequest(
            identifier: taskID,
            title: String(localized: "Albumist analysiert deine Fotos"),
            subtitle: String(localized: "Läuft weiter, auch wenn du die App verlässt")
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not supported (simulator, older device) or already running: the analysis
            // simply pauses in the background and continues on the next launch.
        }
    }

    private static func registerIfNeeded() {
        guard !registered else { return }
        registered = register()
    }

    /// Nonisolated: the system calls the handler on a background queue.
    nonisolated private static func register() -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(task: continued)
            let monitor = Task { @MainActor in
                let model = AppModel.shared
                // The analysis may need a moment to start after the request.
                var idleChecks = 0
                while !Task.isCancelled {
                    if model.analysis.isRunning {
                        idleChecks = 0
                        let total = max(model.analysis.total, 1)
                        let done = min(model.analysis.completed, total)
                        box.task.progress.totalUnitCount = Int64(total)
                        box.task.progress.completedUnitCount = Int64(done)
                        box.task.updateTitle(String(localized: "Albumist analysiert deine Fotos"),
                                             subtitle: String(localized: "\(done) von \(total)"))
                    } else {
                        idleChecks += 1
                        if idleChecks > 3 { break }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                box.task.setTaskCompleted(success: !Task.isCancelled)
            }
            continued.expirationHandler = {
                monitor.cancel()
                Task { @MainActor in AppModel.shared.pauseAnalysis() }
            }
        }
    }

    // MARK: Notification

    /// Asked once, when the user starts the first analysis.
    static func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Only when the app is not on screen; inside the app the overview shows the result.
    static func notifyFinished(openSuggestions: Int) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Analyse fertig")
        content.body = openSuggestions > 0
            ? String(localized: "\(openSuggestions) Vorschläge warten auf dich.")
            : String(localized: "Deine Fotos sind analysiert.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "analysis.finished", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
