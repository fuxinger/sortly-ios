import Foundation

/// Structured search filter. Natural-language queries are translated into this filter
/// and the interpretation is shown to the user (prompt §10: verifiable interpretation).
public struct SearchFilter: Hashable, Sendable {
    public var countryCodes: Set<String> = []
    public var placeNames: Set<String> = []          // normalized city/region/water names
    public var years: Set<Int> = []
    public var months: Set<Int> = []
    public var dateRange: DateInterval?
    public var mediaKinds: Set<MediaKind> = []
    public var requiredSubtypes: MediaSubtypes = []
    public var categories: Set<String> = []
    public var documentTypes: Set<DocumentType> = []
    public var merchants: Set<String> = []           // normalized
    public var requiresOrderNumber = false
    public var requiresInvoiceNumber = false
    public var groupIDs: Set<SortlyID> = []
    public var albumIDs: Set<CollectionID> = []
    public var hasLocation: Bool?
    public var statuses: Set<OverallStatus> = []
    public var freeText: [String] = []

    public init() {}

    public var isEmpty: Bool { self == SearchFilter() }
}

/// One recognized piece of the query, for display ("Land: Italien", "Jahr: 2026").
public struct SearchToken: Hashable, Sendable {
    public enum Kind: String, Sendable { case country, place, year, month, mediaType, category, document, merchant, field, group, album, location, status, text }
    public var kind: Kind
    public var label: String
}

/// Names the parser can recognize, built from the user's own analysed library.
public struct SearchVocabulary: Sendable {
    public var countries: [String: String] = [:]        // normalized name → ISO code
    public var places: Set<String> = []                 // normalized city/region/water names
    public var albums: [String: CollectionID] = [:]     // normalized title → id
    public var groups: [String: SortlyID] = [:]         // normalized confirmed name → id
    public var groupKinds: [SortlyID: GroupKind] = [:]
    public var merchants: Set<String> = []              // normalized

    public init() {}

    public static func build(facts: [AssetFacts], inventory: CollectionInventory, groups: [ObservationGroup]) -> SearchVocabulary {
        var v = SearchVocabulary()
        for f in facts {
            guard let p = f.gpsPlace else { continue }
            if let c = p.country, let code = p.isoCountryCode { v.countries[PlaceKey.normalize(c)] = code }
            for name in [p.locality, p.administrativeArea, p.subAdministrativeArea, p.subLocality, p.inlandWater, p.areaOfInterest].compactMap({ $0 }) {
                v.places.insert(PlaceKey.normalize(name))
            }
            if let m = f.document?.merchant { v.merchants.insert(PlaceKey.normalize(m)) }
        }
        for album in inventory.albums { v.albums[AlbumTitle.normalized(album.title)] = album.id }
        for g in groups where g.isConfirmed {
            if let name = g.confirmedName { v.groups[PlaceKey.normalize(name)] = g.id }
            v.groupKinds[g.id] = g.kind
        }
        // Common country names in German and English even if not in the library, so
        // "Italien 2026" is understood (and simply returns nothing if there are no photos).
        for (name, code) in Self.commonCountries where v.countries[name] == nil { v.countries[name] = code }
        return v
    }

    static let commonCountries: [String: String] = [
        "deutschland": "DE", "germany": "DE", "osterreich": "AT", "austria": "AT", "schweiz": "CH", "switzerland": "CH",
        "italien": "IT", "italy": "IT", "frankreich": "FR", "france": "FR", "spanien": "ES", "spain": "ES", "portugal": "PT",
        "griechenland": "GR", "greece": "GR", "kroatien": "HR", "croatia": "HR", "niederlande": "NL", "netherlands": "NL",
        "england": "GB", "grossbritannien": "GB", "united-kingdom": "GB", "turkei": "TR", "turkey": "TR", "usa": "US",
        "vereinigte-staaten": "US", "united-states": "US", "danemark": "DK", "denmark": "DK", "schweden": "SE", "sweden": "SE",
        "norwegen": "NO", "norway": "NO", "polen": "PL", "poland": "PL", "tschechien": "CZ", "czechia": "CZ", "ungarn": "HU",
        "hungary": "HU", "agypten": "EG", "egypt": "EG", "thailand": "TH", "japan": "JP", "kanada": "CA", "canada": "CA",
    ]
}

/// Rule-based natural-language query parser (German and English). Deterministic, so the
/// displayed interpretation always matches what is searched.
public struct QueryParser: Sendable {
    public var vocabulary: SearchVocabulary

    public init(vocabulary: SearchVocabulary) {
        self.vocabulary = vocabulary
    }

    static let stopwords: Set<String> = [
        "alle", "aller", "alles", "fotos", "foto", "bilder", "bild", "aus", "im", "in", "am", "an", "der", "die", "das", "dem", "den",
        "des", "von", "vom", "mit", "einer", "einem", "eine", "ein", "meines", "meinem", "meinen", "meine", "mein", "unser", "unsere",
        "jahr", "jahre", "zeig", "zeige", "mir", "und", "oder", "all", "photos", "photo", "pictures", "from", "the", "of", "my", "with",
        "a", "an", "at", "year", "show", "me", "and", "ohne", "without", "bei", "zu", "zum", "zur", "auf",
    ]

    static let months: [String: Int] = [
        "januar": 1, "january": 1, "jan": 1, "februar": 2, "february": 2, "feb": 2, "marz": 3, "maerz": 3, "march": 3, "april": 4, "apr": 4,
        "mai": 5, "may": 5, "juni": 6, "june": 6, "juli": 7, "july": 7, "august": 8, "aug": 8, "september": 9, "sept": 9, "oktober": 10,
        "october": 10, "okt": 10, "november": 11, "nov": 11, "dezember": 12, "december": 12, "dez": 12,
    ]

    static let documentWords: [String: DocumentType] = [
        "rechnung": .invoice, "rechnungen": .invoice, "invoice": .invoice, "invoices": .invoice,
        "kassenbon": .receipt, "kassenbons": .receipt, "quittung": .receipt, "quittungen": .receipt, "receipt": .receipt, "receipts": .receipt,
        "vertrag": .contract, "vertrage": .contract, "contract": .contract, "contracts": .contract,
        "garantie": .warranty, "garantien": .warranty, "warranty": .warranty,
        "ticket": .ticket, "tickets": .ticket, "brief": .letter, "briefe": .letter, "letter": .letter, "letters": .letter,
        "bedienungsanleitung": .manual, "bedienungsanleitungen": .manual, "manual": .manual, "manuals": .manual,
        "angebot": .offer, "angebote": .offer, "buchung": .booking, "buchungen": .booking, "booking": .booking, "bookings": .booking,
    ]

    public func parse(_ query: String) -> (filter: SearchFilter, tokens: [SearchToken]) {
        var filter = SearchFilter()
        var tokens: [SearchToken] = []
        var words = query.lowercased()
            .replacingOccurrences(of: "nicht organisiert", with: " __unorganized__ ")
            .replacingOccurrences(of: "not organized", with: " __unorganized__ ")
            .replacingOccurrences(of: "unorganisiert", with: " __unorganized__ ")
            .replacingOccurrences(of: "ohne standort", with: " __nolocation__ ")
            .replacingOccurrences(of: "ohne ort", with: " __nolocation__ ")
            .replacingOccurrences(of: "without location", with: " __nolocation__ ")
            .replacingOccurrences(of: "live photos", with: " __live__ ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
            .map { PlaceKey.normalize($0).isEmpty ? $0 : ($0.hasPrefix("__") ? $0 : PlaceKey.normalize($0)) }

        var consumed = Set<Int>()

        // Multi-word names first (longest match): places, countries, albums, groups.
        for length in stride(from: 4, through: 1, by: -1) where words.count >= length {
            for start in 0...(words.count - length) {
                let range = start..<(start + length)
                guard consumed.isDisjoint(with: range) else { continue }
                let phrase = words[range].joined(separator: "-")
                if let code = vocabulary.countries[phrase] {
                    filter.countryCodes.insert(code); tokens.append(.init(kind: .country, label: words[range].joined(separator: " ").capitalized))
                } else if vocabulary.places.contains(phrase) {
                    filter.placeNames.insert(phrase); tokens.append(.init(kind: .place, label: words[range].joined(separator: " ").capitalized))
                } else if let g = vocabulary.groups[phrase] {
                    filter.groupIDs.insert(g); tokens.append(.init(kind: .group, label: words[range].joined(separator: " ").capitalized))
                } else if let a = vocabulary.albums[phrase] {
                    filter.albumIDs.insert(a); tokens.append(.init(kind: .album, label: words[range].joined(separator: " ")))
                } else if length == 1, vocabulary.merchants.contains(phrase) {
                    filter.merchants.insert(phrase); tokens.append(.init(kind: .merchant, label: phrase.capitalized))
                } else {
                    continue
                }
                consumed.formUnion(range)
            }
        }

        for (i, word) in words.enumerated() where !consumed.contains(i) {
            var handled = true
            if word == "__unorganized__" {
                filter.statuses.formUnion([.unorganized, .partiallyOrganized]); tokens.append(.init(kind: .status, label: "nicht organisiert"))
            } else if word == "__nolocation__" {
                filter.hasLocation = false; tokens.append(.init(kind: .location, label: "ohne Standort"))
            } else if word == "__live__" {
                filter.requiredSubtypes.insert(.livePhoto); tokens.append(.init(kind: .mediaType, label: "Live Photos"))
            } else if let y = Int(word), (1900...2100).contains(y), word.count == 4 {
                filter.years.insert(y); tokens.append(.init(kind: .year, label: word))
            } else if let m = Self.months[word] {
                filter.months.insert(m); tokens.append(.init(kind: .month, label: word.capitalized))
            } else if ["video", "videos"].contains(word) {
                filter.mediaKinds.insert(.video); tokens.append(.init(kind: .mediaType, label: "Videos"))
            } else if ["screenshot", "screenshots", "bildschirmfoto", "bildschirmfotos"].contains(word) {
                filter.requiredSubtypes.insert(.screenshot); tokens.append(.init(kind: .mediaType, label: "Screenshots"))
            } else if ["panorama", "panoramen", "panoramas"].contains(word) {
                filter.requiredSubtypes.insert(.panorama); tokens.append(.init(kind: .mediaType, label: "Panoramen"))
            } else if let d = Self.documentWords[word] {
                filter.documentTypes.insert(d); tokens.append(.init(kind: .document, label: word.capitalized))
            } else if ["bestellnummer", "bestellnummern", "ordernumber"].contains(word) || (word == "order" && words.dropFirst(i + 1).first == "number") {
                filter.requiresOrderNumber = true; tokens.append(.init(kind: .field, label: "mit Bestellnummer"))
            } else if ["rechnungsnummer", "invoicenumber"].contains(word) {
                filter.requiresInvoiceNumber = true; tokens.append(.init(kind: .field, label: "mit Rechnungsnummer"))
            } else if let category = Self.category(for: word) {
                // "Hund" with exactly one confirmed dog group → that group ("meines Hundes").
                let kind: GroupKind? = category == "animal.dog" ? .dog : (category == "animal.cat" ? .cat : nil)
                let confirmed = vocabulary.groupKinds.filter { $0.value == kind }.map(\.key)
                if let kind, confirmed.count == 1, (words.contains("meines") || words.contains("meinem") || words.contains("my") || words.contains("unserem")) {
                    filter.groupIDs.insert(confirmed[0]); tokens.append(.init(kind: .group, label: Labels(.german).groupPlaceholder(kind, number: 1)))
                } else {
                    filter.categories.insert(category)
                    tokens.append(.init(kind: .category, label: ImageTaxonomy.byID[category]?.german ?? category))
                }
            } else {
                handled = false
            }
            if handled { consumed.insert(i) }
        }

        let leftovers = words.enumerated().filter { !consumed.contains($0.offset) && !Self.stopwords.contains($0.element) && $0.element.count >= 3 && !$0.element.hasPrefix("__") }
        for (_, word) in leftovers {
            filter.freeText.append(word)
            tokens.append(.init(kind: .text, label: "„\(word)“"))
        }
        words.removeAll()
        return (filter, tokens)
    }

    /// Matches category names in German/English, singular or plural.
    static func category(for word: String) -> String? {
        for c in ImageTaxonomy.all {
            let names = [c.german, c.english].map(PlaceKey.normalize)
            for n in names {
                if n == word || singular(n) == word || singular(word) == n || singular(word) == singular(n) { return c.id }
            }
            if c.visionIdentifiers.contains(word) || c.visionIdentifiers.contains(singular(word)) { return c.id }
        }
        return nil
    }

    static func singular(_ w: String) -> String {
        for suffix in ["es", "en", "s", "e", "n"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            return String(w.dropLast(suffix.count))
        }
        return w
    }
}

/// Evaluates filters against analysis facts. Never invents results: unknown values do not
/// match (an undated photo never matches a year filter).
public struct SearchEngine: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .sortlyDefault) { self.calendar = calendar }

    public func matches(_ f: SearchFilter, _ facts: AssetFacts, status: OverallStatus? = nil, textHits: Set<AssetID>? = nil) -> Bool {
        let a = facts.asset
        if !f.countryCodes.isEmpty {
            guard let code = facts.gpsPlace?.isoCountryCode, f.countryCodes.contains(code) else { return false }
        }
        if !f.placeNames.isEmpty {
            guard let p = facts.gpsPlace else { return false }
            let names = Set([p.locality, p.administrativeArea, p.subAdministrativeArea, p.subLocality, p.inlandWater, p.areaOfInterest].compactMap { $0 }.map(PlaceKey.normalize))
            guard !names.isDisjoint(with: f.placeNames) else { return false }
        }
        if !f.years.isEmpty || !f.months.isEmpty || f.dateRange != nil {
            guard let d = a.creationDate else { return false }
            if !f.years.isEmpty && !f.years.contains(calendar.component(.year, from: d)) { return false }
            if !f.months.isEmpty && !f.months.contains(calendar.component(.month, from: d)) { return false }
            if let r = f.dateRange, !r.contains(d) { return false }
        }
        if !f.mediaKinds.isEmpty && !f.mediaKinds.contains(a.kind) { return false }
        if !f.requiredSubtypes.isEmpty && !a.subtypes.contains(f.requiredSubtypes) { return false }
        for c in f.categories where !facts.hasCategory(c, minimum: .plausible) { return false }
        if !f.documentTypes.isEmpty {
            guard let t = facts.document?.type, f.documentTypes.contains(t) else { return false }
        }
        if !f.merchants.isEmpty {
            guard let m = facts.document?.merchant.map(PlaceKey.normalize), f.merchants.contains(m) else { return false }
        }
        if f.requiresOrderNumber && facts.document?.orderNumber == nil { return false }
        if f.requiresInvoiceNumber && facts.document?.invoiceNumber == nil { return false }
        if !f.groupIDs.isEmpty && facts.groupIDs.isDisjoint(with: f.groupIDs) { return false }
        if !f.albumIDs.isEmpty && facts.albumIDs.isDisjoint(with: f.albumIDs) { return false }
        if let hasLocation = f.hasLocation, (a.usableLocation != nil) != hasLocation { return false }
        if !f.statuses.isEmpty {
            guard let status, f.statuses.contains(status) else { return false }
        }
        if !f.freeText.isEmpty {
            if let textHits {
                if !textHits.contains(a.id) { return false }
            } else {
                let text = (facts.recognizedText ?? "").lowercased()
                for word in f.freeText where !text.contains(word) { return false }
            }
        }
        return true
    }

    public func search(_ f: SearchFilter, in facts: [AssetFacts], statuses: [AssetID: OverallStatus] = [:], textHits: Set<AssetID>? = nil) -> [AssetID] {
        facts
            .filter { matches(f, $0, status: statuses[$0.id], textHits: textHits) }
            .sorted { ($0.asset.creationDate ?? .distantPast, $0.id) > ($1.asset.creationDate ?? .distantPast, $1.id) }
            .map(\.id)
    }
}
