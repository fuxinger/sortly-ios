import AppIntents
import CoreSpotlight
import SortlyCore

/// An open album suggestion, for Siri, Shortcuts and Spotlight.
struct SuggestionEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Albumvorschlag" }
    static var defaultQuery: SuggestionQuery { SuggestionQuery() }

    var id: String
    var title: String
    var photoCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(photoCount) Fotos",
            image: DisplayRepresentation.Image(systemName: "rectangle.stack.badge.plus")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.keywords = [String(localized: "Album"), String(localized: "Vorschlag"), String(localized: "Fotos")]
        return attributes
    }
}

struct SuggestionQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SuggestionEntity] {
        guard let model = await IntentData.readyModel() else { return [] }
        let wanted = Set(identifiers)
        return IntentData.suggestions(model).filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SuggestionEntity] {
        guard let model = await IntentData.readyModel() else { return [] }
        return IntentData.suggestions(model).filter { $0.title.localizedStandardContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SuggestionEntity] {
        guard let model = await IntentData.readyModel() else { return [] }
        return IntentData.suggestions(model)
    }
}

/// A country of the travel atlas ("Fotos aus Italien"), for Siri, Shortcuts and Spotlight.
struct CountryEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Land" }
    static var defaultQuery: CountryQuery { CountryQuery() }

    /// ISO country code, for example "IT".
    var id: String
    var name: String
    var photoCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(TravelAtlas.flag(id)) \(name)",
            subtitle: "\(photoCount) Fotos"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.keywords = [id, String(localized: "Reise"), String(localized: "Urlaub"), String(localized: "Fotos")]
        return attributes
    }
}

struct CountryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CountryEntity] {
        guard let model = await IntentData.readyModel() else { return [] }
        let wanted = Set(identifiers.map { $0.uppercased() })
        return IntentData.countries(model).filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [CountryEntity] {
        guard let model = await IntentData.readyModel() else { return [] }
        let text = string.trimmingCharacters(in: .whitespaces)
        return IntentData.countries(model).filter {
            $0.name.localizedStandardContains(text) || $0.id.caseInsensitiveCompare(text) == .orderedSame
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [CountryEntity] {
        guard let model = await IntentData.readyModel() else { return [] }
        return IntentData.countries(model)
    }
}

/// What Siri, Shortcuts and Spotlight can see: the open suggestions and the countries
/// with photos. Everything stays on the device; Spotlight's index is local.
@MainActor
enum IntentData {
    /// The app state, loaded if an intent runs before the app was opened.
    /// `nil` while Albumist is not set up yet.
    static func readyModel() async -> AppModel? {
        let model = AppModel.shared
        if model.phase == .loading { await model.bootstrap() }
        return model.phase == .ready ? model : nil
    }

    static func suggestions(_ model: AppModel) -> [SuggestionEntity] {
        model.openProposals.map {
            SuggestionEntity(id: $0.id.rawValue, title: model.userTitles[$0.id] ?? $0.title, photoCount: $0.assetIDs.count)
        }
    }

    /// Countries with photos, most photographed first.
    static func countries(_ model: AppModel) -> [CountryEntity] {
        var counts: [String: Int] = [:]
        for facts in model.facts {
            guard let code = facts.place?.isoCountryCode?.uppercased(), code.count == 2 else { continue }
            counts[code, default: 0] += 1
        }
        return counts
            .map { CountryEntity(id: $0.key, name: AtlasStyle.countryName($0.key), photoCount: $0.value) }
            .sorted { ($0.photoCount, $1.name) > ($1.photoCount, $0.name) }
    }
}

/// Keeps Spotlight and the Siri phrases ("Fotos aus Italien") in step with the library.
@MainActor
enum SpotlightIndex {
    private static var pending: Task<Void, Never>?

    /// Called after every analysis or decision; bundled so a burst of changes indexes once.
    static func scheduleUpdate(_ model: AppModel) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, model.phase == .ready else { return }
            let suggestions = IntentData.suggestions(model)
            let countries = IntentData.countries(model)
            await replace(suggestions: suggestions, countries: countries)
            SortlyShortcuts.updateAppShortcutParameters()
        }
    }

    private nonisolated static func replace(suggestions: [SuggestionEntity], countries: [CountryEntity]) async {
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: SuggestionEntity.self)
        try? await index.deleteAppEntities(ofType: CountryEntity.self)
        if !suggestions.isEmpty { try? await index.indexAppEntities(suggestions) }
        if !countries.isEmpty { try? await index.indexAppEntities(countries) }
    }
}
