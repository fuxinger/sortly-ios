import AppIntents
import SwiftUI
import SortlyCore

/// "Neue Fotos sortieren" for Shortcuts and Siri: opens SORTLY and checks for new photos.
/// Nothing in the library changes without the user's confirmation in the app.
struct SortNewPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Neue Fotos sortieren"
    static let description = IntentDescription("Öffnet SORTLY und sucht nach neuen Fotos, für die es Vorschläge gibt.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = await IntentData.readyModel() else {
            return .result(dialog: "Richte SORTLY zuerst in der App ein.")
        }
        model.startAnalysis()
        return .result(dialog: "SORTLY sucht nach neuen Fotos. Die Vorschläge findest du in der Übersicht.")
    }
}

/// "Was hat SORTLY für mich?": says how many suggestions are waiting, without opening the
/// app, and hands them to Shortcuts (for example to open one of them).
struct OpenSuggestionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Offene Vorschläge"
    static let description = IntentDescription("Sagt dir, wie viele Albumvorschläge auf dich warten, und gibt sie an Kurzbefehle weiter.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SuggestionEntity]> & ProvidesDialog {
        guard let model = await IntentData.readyModel() else {
            return .result(value: [], dialog: "Richte SORTLY zuerst in der App ein.")
        }
        let open = IntentData.suggestions(model)
        if open.isEmpty {
            return .result(value: [], dialog: "Alle Vorschläge sind entschieden.")
        }
        return .result(value: open, dialog: "\(open.count) Vorschläge warten auf dich.")
    }
}

/// Opens one suggestion. Also runs when a suggestion is tapped in Spotlight.
struct OpenSuggestionIntent: OpenIntent {
    static let title: LocalizedStringResource = "Vorschlag öffnen"
    static let description = IntentDescription("Öffnet einen Albumvorschlag in SORTLY.")

    @Parameter(title: "Vorschlag")
    var target: SuggestionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.route = .suggestion(SortlyID(target.id))
        return .result()
    }
}

/// "Zeig meine Fotos aus Italien": opens the photos of one country from the travel atlas.
/// Also runs when a country is tapped in Spotlight.
struct OpenCountryIntent: OpenIntent {
    static let title: LocalizedStringResource = "Fotos aus einem Land zeigen"
    static let description = IntentDescription("Zeigt in SORTLY alle Fotos, die in einem Land aufgenommen wurden.")

    @Parameter(title: "Land")
    var target: CountryEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.route = .country(target.id)
        return .result()
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
        AppShortcut(
            intent: OpenCountryIntent(),
            phrases: [
                "Fotos aus \(\.$target) in \(.applicationName)",
                "Zeig meine Fotos aus \(\.$target) in \(.applicationName)",
                "\(.applicationName) Fotos aus \(\.$target)",
                "Fotos aus einem Land in \(.applicationName)"
            ],
            shortTitle: "Fotos aus einem Land",
            systemImageName: "globe.europe.africa"
        )
        AppShortcut(
            intent: OpenSuggestionsIntent(),
            phrases: [
                "Offene Vorschläge in \(.applicationName)",
                "Was hat \(.applicationName) für mich",
                "\(.applicationName) Vorschläge"
            ],
            shortTitle: "Offene Vorschläge",
            systemImageName: "rectangle.stack"
        )
    }
}
