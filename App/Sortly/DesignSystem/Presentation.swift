import SwiftUI
import SortlyCore
import SortlyEngine

/// User-facing texts and symbols for core values. UI strings live in the app's string
/// catalog (German source, English translation); album titles come from the core.
extension OrganizationArea {
    /// Areas the app offers today. People and pets need identity grouping (opt-in), which
    /// ships in a later version (see docs/ROADMAP.md); until then the area is not shown.
    static var available: [OrganizationArea] { allCases.filter { $0 != .peopleAndPets } }

    var title: LocalizedStringKey {
        switch self {
        case .places: "Länder und Orte"
        case .trips: "Reisen"
        case .frequentPlaces: "Häufige Orte"
        case .peopleAndPets: "Personen und Tiere"
        case .messenger: "Messenger"
        case .screenshots: "Screenshots"
        case .imageCategories: "Themen"
        case .documents: "Dokumente"
        case .chronology: "Jahre und Monate"
        case .mediaTypes: "Medientypen"
        }
    }

    var symbol: String {
        switch self {
        case .places: "mappin.and.ellipse"
        case .trips: "airplane"
        case .frequentPlaces: "house"
        case .peopleAndPets: "pawprint"
        case .messenger: "bubble.left.and.bubble.right"
        case .screenshots: "rectangle.dashed"
        case .imageCategories: "square.grid.2x2"
        case .documents: "doc.text"
        case .chronology: "calendar"
        case .mediaTypes: "film.stack"
        }
    }

    var tint: Color {
        switch self {
        case .trips, .frequentPlaces: Theme.tint(for: .trips)
        case .places: Theme.tint(for: .places)
        case .documents, .screenshots, .messenger: Theme.tint(for: .documents)
        default: Theme.tint(for: .neutral)
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .places: "Alben für Länder und Städte, in denen du fotografiert hast."
        case .trips: "Erkennt Reisen und Ausflüge und trennt sie vom Alltag zu Hause."
        case .frequentPlaces: "Orte, an denen du oft fotografierst. Du gibst ihnen selbst einen Namen."
        case .peopleAndPets: "Haustiere und – nur wenn du es einschaltest – Gesichter."
        case .messenger: "Bilder aus WhatsApp, Signal und Co., nur mit klaren Hinweisen."
        case .screenshots: "Screenshots nach Inhalt: Bestellungen, Tickets, Rezepte …"
        case .imageCategories: "Themen wie Hunde, Strand, Essen oder Autos."
        case .documents: "Rechnungen, Verträge und Kassenbons. Sensible Dokumente nur auf Wunsch."
        case .chronology: "Alben nach Jahr und Monat."
        case .mediaTypes: "Videos, Live Photos, Panoramen, Zeitlupe und mehr."
        }
    }
}

extension MatchStatus {
    var label: LocalizedStringKey {
        switch self {
        case .alreadyComplete: "Schon vollständig vorhanden"
        case .extendable: "Vorhandenes Album wird ergänzt"
        case .possibleMatch: "Vorhandenes Album passt vermutlich"
        case .multipleMatches: "Mehrere passende Alben"
        case .nameConflict: "Gleicher Name, anderer Inhalt"
        case .newAlbumRequired: "Neues Album"
        case .ambiguous: "Nicht eindeutig"
        case .notEditable: "Album nicht bearbeitbar"
        }
    }

    var tint: Color {
        switch self {
        case .alreadyComplete, .extendable, .possibleMatch: Theme.accent
        case .newAlbumRequired: Theme.tint(for: .places)
        default: Theme.tint(for: .documents)
        }
    }
}

extension Reliability {
    var label: LocalizedStringKey {
        switch self {
        case .certain: "Sicher"
        case .likely: "Wahrscheinlich"
        case .plausible: "Möglich"
        case .uncertain: "Unsicher"
        }
    }
}

extension AnalysisPipeline.Stage {
    var label: LocalizedStringKey {
        switch self {
        case .inventory: "Mediathek wird gelesen"
        case .patterns: "Reisen werden erkannt"
        case .places: "Orte werden bestimmt"
        case .content: "Bildinhalte werden erkannt"
        case .text: "Text auf Screenshots wird gelesen"
        case .groups: "Gruppen werden gebildet"
        case .proposals: "Vorschläge werden erstellt"
        }
    }
}

extension PauseReason {
    var label: LocalizedStringKey {
        switch self {
        case .userPaused: "Pausiert"
        case .thermal: "Pausiert, weil das iPhone warm ist"
        case .lowPower: "Pausiert im Stromsparmodus"
        case .batteryLow: "Pausiert bei niedrigem Akku"
        case .timeBudget: "Wird später fortgesetzt"
        case .accessRevoked: "Kein Zugriff auf die Fotos"
        }
    }
}

extension InboxBucket {
    var label: LocalizedStringKey {
        switch self {
        case .all: "Alle"
        case .unorganized: "Nicht sortiert"
        case .suggestions: "Vorschläge"
        case .organized: "Sortiert"
        case .uncertain: "Unsicher"
        case .ignored: "Ignoriert"
        case .excluded: "Ausgeschlossen"
        }
    }
}

enum ReasonText {
    static func text(_ reason: ProposalReason) -> String {
        let dates = Date.FormatStyle(date: .numeric, time: .omitted)
        switch reason {
        case .photosInPlaceDuringPeriod(let count, let place, let start, let end):
            return String(localized: "\(count) Aufnahmen zwischen \(start.formatted(dates)) und \(end.formatted(dates)) in \(place).")
        case .photosInPlace(let count, let place):
            return String(localized: "\(count) Aufnahmen in \(place).")
        case .photosInPeriod(let count, let start, let end):
            return String(localized: "\(count) Aufnahmen zwischen \(start.formatted(dates)) und \(end.formatted(dates)).")
        case .recurringPlace(let count, let days):
            return String(localized: "\(count) Aufnahmen an \(days) verschiedenen Tagen am selben Ort.")
        case .recognizedContent(let count, let label):
            return String(localized: "\(count) Bilder zeigen „\(label)“.")
        case .recognizedText(let count, let label):
            return String(localized: "\(count) Bilder enthalten Text zu „\(label)“.")
        case .mediaType(let count, let label):
            return String(localized: "\(count) Medien: \(label).")
        case .confirmedGroup(let count, let name):
            return String(localized: "\(count) Bilder von \(name).")
        case .ruleMatched(let count, let rule):
            return String(localized: "\(count) Bilder passen zur Regel „\(rule)“.")
        case .inferredWithoutLocation(let count):
            return String(localized: "\(count) Fotos ohne Ort passen zeitlich dazu und sind nur vorgeschlagen.")
        }
    }

    static func text(_ reason: MatchReason) -> String {
        switch reason {
        case .albumContains(let album, let contained, let total):
            return String(localized: "Dein Album „\(album)“ enthält schon \(contained) von \(total) Aufnahmen.")
        case .missingItems(let count):
            return String(localized: "\(count) passende Aufnahmen fehlen noch und werden ergänzt.")
        case .albumHasOtherItems(let album, let count):
            return String(localized: "„\(album)“ enthält \(count) weitere Aufnahmen, die nicht dazugehören. Sie bleiben unverändert.")
        case .albumIsBroaderCollection(let album, let siblings):
            return String(localized: "„\(album)“ ist eine größere Sammlung über \(siblings) Ereignisse und wird nicht als Reisealbum verwendet.")
        case .sameNameDifferentContent(let album, let shared):
            return String(localized: "Es gibt schon ein Album „\(album)“, aber mit anderem Inhalt (\(shared) gemeinsame Aufnahmen).")
        case .albumNotEditable(let album):
            return String(localized: "„\(album)“ kann nicht bearbeitet werden (z. B. geteiltes Album).")
        case .severalAlbumsMatch(let count):
            return String(localized: "\(count) vorhandene Alben passen. Bitte wähle eines aus.")
        case .weakOverlapOnly(let album, let shared):
            return String(localized: "„\(album)“ hat nur \(shared) gemeinsame Aufnahmen.")
        case .noExistingAlbum:
            return String(localized: "Es gibt noch kein passendes Album.")
        }
    }
}

extension ProposalDecision {
    var isCreatingNew: Bool {
        if case .createNew = self { return true }
        return false
    }
}
