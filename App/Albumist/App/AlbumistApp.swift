import SwiftUI
import UIKit

/// The app's entry: launch set-up (background work, notifications, UI-run helpers), one
/// `AppModel` and `Purchases` for the window, and what happens when the app comes on screen or
/// goes to the background (the analysis goes on, the backup copy of the decisions is written).
@main
struct AlbumistApp: App {
    @State private var model = AppModel.shared
    @State private var purchases = Purchases.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // UI runs only: a full console pipe held the main thread (see the function).
        UITestSupport.moveConsoleToFile()
        BackgroundWork.register()
        UITestSupport.prepareLaunch()
        // Before launch ends, so the tap on "Analyse fertig" that opened the app arrives.
        NotificationRouter.register()
        // MetricKit's daily numbers and hang reports, for the diagnostic report.
        EnergyMetricsSubscriber.start()
        // Apple Intelligence's availability, asked off the main thread (views read it in `body`).
        SmartAssistant.watchAvailability()
        // UI runs only: says in the log when the main thread or the whole app stood still.
        MainThreadWatch.shared.start()
        // iOS warns that memory runs low: the caches go before iOS has to end the app, also
        // while the analysis goes on in the background (P4-06).
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.memoryWarning() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(purchases)
                .preferredColorScheme(UITestSupport.forcesDarkMode ? .dark : nil)
                .task {
                    purchases.start()
                    await model.bootstrap()
                    if model.access.canRead { LibraryChangeWatcher.shared.start() }
                    // Photos may have changed while Albumist was closed (albums made in Photos).
                    // (UI runs start it themselves, except the ones that rebuild the database or
                    // test a relaunch; a fast-started UI run creates its demo library first.)
                    if model.phase == .ready && model.access.canRead && (!UITestSupport.isRunning || UITestSupport.startsAnalysisAtLaunch) {
                        model.startAnalysis()
                    }
                    await UITestSupport.didLaunch(model)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    model.timeChanged()
                }
                .onChange(of: scenePhase) { _, phase in
                    ContinuedAnalysis.sceneChanged(onScreen: phase == .active)
                    model.sceneChanged(onScreen: phase == .active)
                    // Back on screen: an analysis that iOS ended goes on by itself, a running
                    // one asks for background time again.
                    if phase == .active {
                        model.sceneBecameActive()
                        // An approval or a purchase elsewhere whose update did not arrive.
                        Task { await purchases.becameActive() }
                    }
                    // The copy of the decisions for the iPhone backup is current before iOS may
                    // end the app (a background task keeps the app awake for the short write).
                    guard phase == .background else { return }
                    let assertion = BackgroundAssertion(name: "Albumist decisions copy")
                    Task {
                        await model.writeSafetyBackupNow()
                        assertion.end()
                    }
                }
        }
    }
}

/// Asks iOS for a little time in the background and gives it back when the work is done
/// (or when the time runs out).
@MainActor
final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
