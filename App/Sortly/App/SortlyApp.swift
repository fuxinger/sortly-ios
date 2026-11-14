import SwiftUI

@main
struct SortlyApp: App {
    @State private var model = AppModel.shared
    @State private var purchases = Purchases.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundWork.register()
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
                    // (UI runs start it themselves, except the one that rebuilds the database.)
                    if model.phase == .ready && model.access.canRead && (!UITestSupport.isRunning || UITestSupport.rebuildsDatabase) {
                        model.startAnalysis()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
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
