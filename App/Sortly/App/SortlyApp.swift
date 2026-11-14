import SwiftUI

@main
struct SortlyApp: App {
    @State private var model = AppModel.shared
    @State private var purchases = Purchases.shared

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
                    if model.phase == .ready && model.access.canRead && !UITestSupport.isRunning { model.startAnalysis() }
                }
        }
    }
}
