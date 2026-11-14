import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional help from Apple's on-device language model (Apple Intelligence).
/// Everything here is a bonus: when the model is unavailable (older iPhone, feature off,
/// unsupported language) the app works exactly as without it. Nothing leaves the device.
enum SmartAssistant {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Turns a sentence like "Fotos vom Grillen bei Oma letzten Sommer" into the keywords
    /// Albumist's search understands ("Grillen Sommer 2025"). Returns nil when unavailable.
    static func searchKeywords(for sentence: String, now: Date = Date()) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let year = Calendar.current.component(.year, from: now)
        let session = LanguageModelSession(instructions: """
        Du zerlegst Suchanfragen für eine Fotomediathek in Suchbegriffe. Heute ist \(now.formatted(date: .long, time: .omitted)), das aktuelle Jahr ist \(year).
        Rechne relative Zeitangaben ("letzten Sommer", "vor zwei Jahren") in Jahreszahlen und Monatsnamen um.
        Gib nur Begriffe zurück, die in der Anfrage gemeint sind. Erfinde nichts.
        """)
        do {
            let response = try await session.respond(to: sentence, generating: SearchKeywords.self)
            let k = response.content
            let parts = k.places + k.years.map(String.init) + k.months + k.topics + k.mediaTypes
            let joined = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// A short, warm story (3–4 sentences) about the user's photos, built only from the given facts.
    static func travelStory(facts: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable, !facts.isEmpty else { return nil }
        // The story follows the app's language (German or English); the facts themselves are German.
        let language = Bundle.main.preferredLocalizations.first == "de" ? "auf Deutsch" : "auf Englisch"
        let session = LanguageModelSession(instructions: """
        Du schreibst eine kurze, warme Geschichte über die Fotos eines Menschen in der Du-Form \(language), drei bis vier Sätze.
        Verwende ausschließlich die gegebenen Fakten. Erfinde keine Orte, Personen, Erlebnisse oder Zahlen.
        Keine Aufzählung, keine Überschrift, keine Emojis.
        """)
        do {
            let response = try await session.respond(to: "Fakten:\n" + facts.joined(separator: "\n"))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Suggests a short, natural album title for a trip ("Toskana-Rundreise"), without date.
    static func tripTitle(currentTitle: String, details: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        Du schlägst kurze, natürliche deutsche Albumtitel für Reisefotos vor.
        Höchstens vier Wörter, ohne Datum, ohne Emojis, ohne Anführungszeichen.
        Verwende nur Orte, die in den Angaben vorkommen.
        """)
        let prompt = "Bisheriger Titel: \(currentTitle)\nAngaben:\n" + details.joined(separator: "\n")
        do {
            let response = try await session.respond(to: prompt, generating: TitleSuggestion.self)
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"„“")))
            return title.isEmpty || title.count > 60 ? nil : title
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct SearchKeywords {
    @Guide(description: "Länder, Städte oder Orte aus der Anfrage, auf Deutsch")
    var places: [String]
    @Guide(description: "Gemeinte Jahreszahlen, z. B. 2023")
    var years: [Int]
    @Guide(description: "Gemeinte Monate als deutsche Monatsnamen, z. B. Juli")
    var months: [String]
    @Guide(description: "Motive oder Themen als einzelne deutsche Substantive, z. B. Strand, Hund, Essen, Rechnung")
    var topics: [String]
    @Guide(description: "Medientypen wie Video, Screenshot, Live Photo, Panorama, falls genannt")
    var mediaTypes: [String]
}

@Generable
struct TitleSuggestion {
    @Guide(description: "Kurzer Albumtitel, höchstens vier Wörter, ohne Datum")
    var title: String
}
#endif
