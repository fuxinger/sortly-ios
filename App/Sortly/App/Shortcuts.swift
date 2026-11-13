import AppIntents
import SwiftUI

/// "Neue Fotos sortieren" for Shortcuts and Siri: opens SORTLY and checks for new photos.
/// Nothing in the library changes without the user's confirmation in the app.
struct SortNewPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Neue Fotos sortieren"
    static let description = IntentDescription("Öffnet SORTLY und sucht nach neuen Fotos, für die es Vorschläge gibt.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        if model.phase == .loading { await model.bootstrap() }
        guard model.phase == .ready else {
            return .result(dialog: "Richte SORTLY zuerst in der App ein.")
        }
        model.startAnalysis()
        return .result(dialog: "SORTLY sucht nach neuen Fotos. Die Vorschläge findest du in der Übersicht.")
    }
}

struct SortlyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SortNewPhotosIntent(),
            phrases: [
                "Neue Fotos sortieren mit \(.applicationName)",
                "Fotos mit \(.applicationName) sortieren",
                "\(.applicationName) neue Fotos"
            ],
            shortTitle: "Neue Fotos sortieren",
            systemImageName: "rectangle.stack.badge.plus"
        )
    }
}
