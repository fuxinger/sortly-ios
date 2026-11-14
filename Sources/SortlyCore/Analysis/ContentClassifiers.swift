import Foundation

// MARK: - Screenshots by content (prompt §4.6)

public enum ScreenshotCategory: String, Sendable, Codable, CaseIterable {
    case chat, order, invoice, ticket, flight, hotel, recipe, product, offer, coupon, socialMedia, news,
         realEstate, job, manual, qrCode, mapNavigation, note, technical
}

/// Multi-label keyword/structure classifier for screenshot text. Deterministic so that the
/// reason for each category can be shown ("enthält ‚Bestellnummer‘").
public struct ScreenshotClassifier: Sendable {
    public init() {}

    public struct Result: Hashable, Sendable {
        public var categories: [ScreenshotCategory: Reliability]
        public var matchedTerms: [ScreenshotCategory: [String]]
    }

    static let keywords: [ScreenshotCategory: [String]] = [
        .chat: ["online", "zuletzt online", "last seen", "tippt", "typing", "nachricht", "message", "gelesen", "read", "zugestellt", "delivered", "imessage", "heute", "gestern"],
        .order: ["bestellnummer", "bestellung", "order number", "your order", "versandt", "shipped", "lieferung", "zustellung", "sendungsverfolgung", "tracking"],
        .invoice: ["rechnung", "invoice", "rechnungsnummer", "zahlbar", "mwst", "ust", "vat"],
        .ticket: ["ticket", "fahrkarte", "eintritt", "einlass", "sitzplatz", "seat", "gleis", "platform", "qr-code", "barcode"],
        .flight: ["flug", "flight", "boarding", "gate", "abflug", "departure", "ankunft", "arrival", "terminal", "lufthansa", "ryanair", "eurowings"],
        .hotel: ["hotel", "check-in", "check-out", "zimmer", "room", "übernachtung", "nights", "booking.com", "airbnb", "unterkunft"],
        .recipe: ["zutaten", "ingredients", "zubereitung", "preparation", "esslöffel", "teelöffel", "tbsp", "tsp", "backofen", "oven", "minuten garen"],
        .product: ["in den warenkorb", "add to cart", "lieferbar", "in stock", "bewertungen", "reviews", "artikelnummer", "produktdetails"],
        .offer: ["angebot", "sale", "rabatt", "discount", "statt", "nur heute", "% off", "deal"],
        .coupon: ["gutschein", "coupon", "gutscheincode", "promo code", "rabattcode", "voucher", "einlösen", "redeem"],
        .socialMedia: ["gefällt", "likes", "follower", "folgen", "follow", "kommentare", "comments", "teilen", "share", "story", "repost"],
        .news: ["artikel", "redaktion", "eilmeldung", "breaking", "uhr aktualisiert", "updated", "minuten lesezeit", "min read"],
        .realEstate: ["kaltmiete", "warmmiete", "zimmer", "wohnfläche", "m²", "nebenkosten", "kaution", "provisionsfrei", "rent", "sqm"],
        .job: ["stellenangebot", "bewerbung", "vollzeit", "teilzeit", "gehalt", "job", "position", "apply", "karriere", "m/w/d"],
        .manual: ["schritt 1", "step 1", "anleitung", "einstellungen", "settings", "tippe auf", "tap", "so geht", "how to"],
        .mapNavigation: ["route", "km", "min", "abbiegen", "turn", "navigation", "ankunft", "eta", "fahrt starten", "directions"],
        .note: ["notiz", "notes", "erinnerung", "todo", "to-do", "einkaufsliste", "liste"],
        .technical: ["error", "fehler", "exception", "ip-adresse", "seriennummer", "serial", "firmware", "version", "wlan", "bluetooth", "http"],
    ]

    /// Minimum distinct hits for a category; chat UIs share words with other categories,
    /// so weak categories need two hits.
    static let minimumHits: [ScreenshotCategory: Int] = [.chat: 2, .mapNavigation: 3, .manual: 2, .technical: 2, .note: 1, .news: 2, .socialMedia: 2, .offer: 2, .realEstate: 3]

    public func classify(text: String, barcodePayloads: [String] = [], imageLabels: Set<String> = []) -> Result {
        let lower = text.lowercased()
        var categories: [ScreenshotCategory: Reliability] = [:]
        var terms: [ScreenshotCategory: [String]] = [:]
        for (category, words) in Self.keywords {
            let hits = words.filter { lower.contains($0) }
            let needed = Self.minimumHits[category] ?? 1
            guard hits.count >= needed else { continue }
            terms[category] = hits
            categories[category] = hits.count >= needed + 2 ? .likely : .plausible
        }
        if !barcodePayloads.isEmpty {
            categories[.qrCode] = .certain
            terms[.qrCode] = ["QR/Barcode"]
        }
        if imageLabels.contains("map") {
            categories[.mapNavigation] = max(categories[.mapNavigation] ?? .plausible, .likely)
        }
        // A flight is also a ticket (prompt example: flight booking appears in several places).
        if categories[.flight] != nil, categories[.ticket] == nil, lower.contains("boarding") {
            categories[.ticket] = .plausible
        }
        return Result(categories: categories, matchedTerms: terms)
    }
}

// MARK: - Messenger hints (prompt §4.5)

public enum MessengerApp: String, Sendable, Codable, CaseIterable {
    case whatsApp, iMessage, telegram, signal, unknown
}

/// Strength of evidence for a messenger origin. Ordered weakest → strongest.
public enum MessengerEvidence: Int, Sendable, Codable, Comparable {
    case unknownOrigin = 0        // nothing points to a messenger
    case plausibleHint = 1        // file name or format pattern
    case existingAlbum = 2        // asset is in a user album named after the messenger
    case recognizedScreenshot = 3 // screenshot showing the messenger UI

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MessengerAssessment: Hashable, Sendable, Codable {
    public var app: MessengerApp
    public var evidence: MessengerEvidence
    public var signals: [String]

    /// Uncertain origins are never applied automatically (prompt §4.5).
    public var allowsAutomaticAssignment: Bool { evidence >= .existingAlbum }
}

public struct MessengerClassifier: Sendable {
    public init() {}

    static let uiTerms: [MessengerApp: [String]] = [
        .whatsApp: ["whatsapp", "ende-zu-ende-verschlüsselt", "end-to-end encrypted", "zuletzt online", "last seen", "sprachnachricht"],
        .iMessage: ["imessage", "textnachricht", "text message", "zugestellt", "delivered", "gelesen"],
        .telegram: ["telegram", "abonnenten", "subscribers", "zuletzt kürzlich", "last seen recently"],
        .signal: ["signal", "sicherheitsnummer", "safety number", "verschwindende nachrichten", "disappearing messages"],
    ]

    public func assess(asset: AssetSnapshot, recognizedText: String?, albumTitles: [String]) -> MessengerAssessment {
        var best = MessengerAssessment(app: .unknown, evidence: .unknownOrigin, signals: [])

        func consider(_ app: MessengerApp, _ evidence: MessengerEvidence, _ signal: String) {
            if evidence > best.evidence || (evidence == best.evidence && best.app == .unknown) {
                best = MessengerAssessment(app: app, evidence: evidence, signals: best.signals + [signal])
            } else {
                best.signals.append(signal)
            }
        }

        // 1. Screenshot with messenger UI text (strongest).
        if asset.subtypes.contains(.screenshot), let text = recognizedText?.lowercased() {
            for (app, words) in Self.uiTerms {
                let hits = words.filter { text.contains($0) }
                if hits.count >= 2 || (hits.contains(app.rawValue.lowercased()) && hits.count >= 1) {
                    consider(app, .recognizedScreenshot, "ui:\(hits.joined(separator: ","))")
                }
            }
        }
        // 2. Existing album named after a messenger.
        for title in albumTitles {
            let t = title.lowercased()
            if t.contains("whatsapp") { consider(.whatsApp, .existingAlbum, "album:\(title)") }
            else if t.contains("telegram") { consider(.telegram, .existingAlbum, "album:\(title)") }
            else if t.contains("signal") { consider(.signal, .existingAlbum, "album:\(title)") }
        }
        // 3. File name patterns – only a hint (Scenario H).
        if let name = asset.originalFilename {
            if name.range(of: #"^(IMG|VID|AUD)-\d{8}-WA\d{4}"#, options: .regularExpression) != nil
                || name.hasPrefix("WhatsApp Image") || name.hasPrefix("WhatsApp Video") {
                consider(.whatsApp, .plausibleHint, "filename")
            } else if name.hasPrefix("photo_") && name.range(of: #"photo_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                consider(.telegram, .plausibleHint, "filename")
            } else if name.hasPrefix("signal-") {
                consider(.signal, .plausibleHint, "filename")
            }
        }
        // Missing GPS or a small JPEG alone is deliberately *not* used as evidence.
        return best
    }
}

// MARK: - Image category taxonomy (prompt §4.7)

/// Hierarchical image categories with German and English names and the Vision
/// classification identifiers that map to them. Identifiers are validated against
/// `ClassifyImageRequest.supportedIdentifiers` by an on-device test in the app target;
/// unknown identifiers are ignored at runtime, never guessed.
public struct ImageCategory: Hashable, Sendable, Codable, Identifiable {
    public var id: String          // "vehicle.car"
    public var german: String
    public var english: String
    public var visionIdentifiers: [String]
    /// Minimum classifier confidence to accept. Tuned per category, documented in AI_PIPELINE.md.
    public var minimumConfidence: Double

    public var parentID: String? {
        guard let dot = id.lastIndex(of: ".") else { return nil }
        return String(id[..<dot])
    }
}

/// Vision identifiers verified against `VNClassifyImageRequest.supportedIdentifiers` (iOS 26 simulator, 1303 labels).
public enum ImageTaxonomy {
    public static let all: [ImageCategory] = {
        func c(_ id: String, _ de: String, _ en: String, _ ids: [String] = [], _ min: Double = 0.35) -> ImageCategory {
            ImageCategory(id: id, german: de, english: en, visionIdentifiers: ids, minimumConfidence: min)
        }
        return [
            c("vehicle", "Fahrzeuge", "Vehicles", ["vehicle"]),
            c("vehicle.car", "Autos", "Cars", ["car", "automobile", "sportscar", "convertible", "suv"]),
            c("vehicle.motorcycle", "Motorräder", "Motorcycles", ["motorcycle", "scooter"]),
            c("vehicle.bicycle", "Fahrräder", "Bicycles", ["bicycle"]),
            c("vehicle.airplane", "Flugzeuge", "Airplanes", ["airplane", "aircraft"]),
            c("vehicle.train", "Züge", "Trains", ["train", "train_real", "train_station", "tramway", "railroad", "monorail"]),
            c("vehicle.boat", "Boote", "Boats", ["boat", "sailboat", "speedboat", "rowboat", "cruise_ship", "yacht", "kayak", "canoe"]),
            c("animal", "Tiere", "Animals", ["animal"]),
            c("animal.dog", "Hunde", "Dogs", ["dog"]),
            c("animal.cat", "Katzen", "Cats", ["cat", "kitten"]),
            c("animal.horse", "Pferde", "Horses", ["horse"]),
            c("animal.bird", "Vögel", "Birds", ["bird", "parrot", "gull", "swan", "hummingbird"]),
            c("animal.wildlife", "Wildtiere", "Wildlife", ["deer", "fox", "bear", "elephant", "giraffe", "zebra", "lion", "squirrel"]),
            c("food", "Essen", "Food", ["food"]),
            c("food.restaurant", "Restaurantbesuche", "Restaurants", ["restaurant", "dining_room"]),
            c("food.dish", "Gerichte", "Dishes", ["pizza", "pasta", "hamburger", "salad", "sushi", "steak", "soup", "sandwich", "cake", "dessert"]),
            c("food.drink", "Getränke", "Drinks", ["drink", "coffee", "wine", "beer", "cocktail", "tea_drink"]),
            c("nature", "Natur", "Nature", []),
            c("nature.mountain", "Berge", "Mountains", ["mountain", "hill", "cliff", "glacier"]),
            c("nature.lake", "Seen", "Lakes", ["lake"]),
            c("nature.sea", "Meer", "Sea", ["ocean", "beach", "shore"]),
            c("nature.forest", "Wald", "Forest", ["forest", "jungle"]),
            c("nature.flower", "Blumen", "Flowers", ["flower", "blossom", "rose", "tulip", "sunflower"]),
            c("nature.sunset", "Sonnenuntergänge", "Sunsets", ["sunset_sunrise"]),
            c("nature.landscape", "Landschaften", "Landscapes", ["grass", "rice_field", "desert"]),
            c("sport", "Sport", "Sports", ["sport"]),
            c("sport.football", "Fußball", "Football", ["soccer", "football"]),
            c("sport.fitness", "Fitness", "Fitness", ["dumbbell", "treadmill", "yoga", "gymnastics"]),
            c("sport.hiking", "Wandern", "Hiking", ["hiking", "trail", "backpack"]),
            c("sport.winter", "Wintersport", "Winter sports", ["skiing", "snowboarding", "ski_equipment", "snow"]),
            c("sport.motorsport", "Motorsport", "Motorsport", ["motorsport", "formula_one_car", "nascar"]),
            c("home", "Wohnen", "Home", []),
            c("home.furniture", "Möbel", "Furniture", ["furniture", "sofa", "chair", "table", "bed", "bookshelf"]),
            c("home.interior", "Einrichtung", "Interior", ["interior_room", "living_room", "kitchen", "bedroom", "bathroom"]),
            c("home.garden", "Garten", "Garden", ["garden", "plant", "decorative_plant", "greenhouse"]),
            c("home.renovation", "Renovierung", "Renovation", ["paintbrush", "toolbox", "power_saw", "brick"]),
            c("home.realEstate", "Immobilien", "Real estate", ["house_single", "building", "apartment"]),
            c("work", "Beruf und Projekte", "Work and projects", []),
            c("work.construction", "Baustellen", "Construction sites", ["crane_construction", "bulldozer", "tractor"]),
            c("work.tools", "Werkzeuge", "Tools", ["tool", "hammer", "screwdriver", "wrench", "chainsaw", "power_saw", "toolbox"]),
            c("work.documentation", "Technische Dokumentationen", "Technical documentation", ["document", "diagram", "whiteboard"]),
            c("misc", "Weitere Bereiche", "More", []),
            c("misc.clothing", "Kleidung", "Clothing", ["clothing", "jacket", "shoes", "wedding_dress", "scarf"]),
            c("misc.shopping", "Shopping", "Shopping", ["storefront", "interior_shop", "shopping_cart"]),
            c("misc.technology", "Technik", "Technology", ["computer", "laptop", "phone", "television", "camera", "consumer_electronics"]),
            c("misc.event", "Veranstaltungen", "Events", ["concert", "wedding", "fireworks", "carnival", "parade", "celebration"]),
            c("misc.architecture", "Architektur", "Architecture", ["skyscraper", "bridge", "tower", "castle", "fountain"]),
            c("misc.landmark", "Sehenswürdigkeiten", "Landmarks", ["monument", "statue", "ruins"]),
            c("misc.art", "Kunst", "Art", ["art", "painting", "museum", "graffiti"]),
            c("misc.collection", "Sammlungen", "Collections", ["watch", "coin", "figurine", "toy"]),
        ]
    }()

    public static let byID: [String: ImageCategory] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Reverse index Vision identifier → category ids.
    public static let byVisionIdentifier: [String: [String]] = {
        var index: [String: [String]] = [:]
        for category in all {
            for identifier in category.visionIdentifiers { index[identifier, default: []].append(category.id) }
        }
        return index
    }()

    /// Maps raw classifier observations to Albumist categories (multi-label, §4.7).
    /// Confidence → Reliability bands are explicit and conservative.
    public static func categories(from observations: [(identifier: String, confidence: Double)]) -> [String: Reliability] {
        var result: [String: Reliability] = [:]
        for observation in observations {
            for categoryID in byVisionIdentifier[observation.identifier] ?? [] {
                guard let category = byID[categoryID], observation.confidence >= category.minimumConfidence else { continue }
                let reliability: Reliability = observation.confidence >= 0.8 ? .likely : (observation.confidence >= 0.55 ? .plausible : .uncertain)
                result[categoryID] = max(result[categoryID] ?? .uncertain, reliability)
                if let parent = category.parentID {
                    result[parent] = max(result[parent] ?? .uncertain, reliability)
                }
            }
        }
        return result
    }
}
