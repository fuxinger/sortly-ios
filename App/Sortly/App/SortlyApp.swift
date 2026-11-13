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
                .task {
                    purchases.start()
                    await model.bootstrap()
                }
        }
    }
}
