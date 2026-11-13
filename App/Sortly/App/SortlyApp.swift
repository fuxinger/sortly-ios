import SwiftUI

@main
struct SortlyApp: App {
    @State private var model = AppModel.shared

    init() {
        BackgroundWork.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
    }
}
