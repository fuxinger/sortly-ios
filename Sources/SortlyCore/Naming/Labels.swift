import Foundation

/// Localized names for generated album titles and folders. Album titles are data written
/// to the user's library, so they are produced here (in the chosen title language) and
/// not through the app's UI string catalog.
public struct Labels: Sendable {
    public var language: TitleLanguage
    public init(_ language: TitleLanguage) { self.language = language }

    private func t(_ de: String, _ en: String) -> String { language == .german ? de : en }

    public func folder(for area: OrganizationArea) -> String {
        switch area {
        case .places: t("Länder", "Countries")
        case .trips: t("Reisen", "Trips")
        case .frequentPlaces: t("Orte", "Places")
        case .peopleAndPets: t("Personen & Tiere", "People & Pets")
        case .messenger: t("Messenger", "Messengers")
        case .screenshots: t("Screenshots", "Screenshots")
        case .imageCategories: t("Themen", "Topics")
        case .documents: t("Dokumente", "Documents")
        case .chronology: t("Jahre", "Years")
        case .mediaTypes: t("Medientypen", "Media Types")
        }
    }

    public func name(_ c: MediaTypeCategory) -> String {
        switch c {
        case .photos: t("Fotos", "Photos")
        case .videos: t("Videos", "Videos")
        case .livePhotos: t("Live Photos", "Live Photos")
        case .screenshots: t("Bildschirmfotos", "Screenshots")
        case .screenRecordings: t("Bildschirmaufnahmen", "Screen Recordings")
        case .panoramas: t("Panoramen", "Panoramas")
        case .bursts: t("Serienaufnahmen", "Bursts")
        case .slowMotion: t("Zeitlupe", "Slo-mo")
        case .timelapse: t("Zeitraffer", "Time-lapse")
        case .raw: t("RAW", "RAW")
        case .hdr: t("HDR", "HDR")
        case .portraitMode: t("Porträtmodus", "Portrait Mode")
        case .spatial: t("Räumliche Medien", "Spatial")
        case .cinematic: t("Kinomodus", "Cinematic")
        case .portraitOrientation: t("Hochformat", "Portrait Orientation")
        case .landscapeOrientation: t("Querformat", "Landscape Orientation")
        case .square: t("Quadratisch", "Square")
        case .shortVideos: t("Kurze Videos", "Short Videos")
        case .longVideos: t("Lange Videos", "Long Videos")
        }
    }

    public func name(_ c: ScreenshotCategory) -> String {
        switch c {
        case .chat: t("Chats", "Chats")
        case .order: t("Bestellungen", "Orders")
        case .invoice: t("Rechnungen", "Invoices")
        case .ticket: t("Tickets", "Tickets")
        case .flight: t("Flugbuchungen", "Flight Bookings")
        case .hotel: t("Hotelbuchungen", "Hotel Bookings")
        case .recipe: t("Rezepte", "Recipes")
        case .product: t("Produkte", "Products")
        case .offer: t("Angebote", "Offers")
        case .coupon: t("Gutscheine", "Coupons")
        case .socialMedia: t("Social Media", "Social Media")
        case .news: t("Nachrichtenartikel", "News Articles")
        case .realEstate: t("Wohnungsanzeigen", "Property Listings")
        case .job: t("Stellenanzeigen", "Job Listings")
        case .manual: t("Anleitungen", "Instructions")
        case .qrCode: t("QR-Codes", "QR Codes")
        case .mapNavigation: t("Karten und Navigation", "Maps and Navigation")
        case .note: t("Notizen", "Notes")
        case .technical: t("Technische Informationen", "Technical Information")
        }
    }

    public func name(_ d: DocumentType) -> String {
        switch d {
        case .invoice: t("Rechnungen", "Invoices")
        case .receipt: t("Kassenbons", "Receipts")
        case .contract: t("Verträge", "Contracts")
        case .warranty: t("Garantien", "Warranties")
        case .order: t("Bestellungen", "Orders")
        case .ticket: t("Tickets", "Tickets")
        case .booking: t("Buchungsbestätigungen", "Booking Confirmations")
        case .letter: t("Briefe", "Letters")
        case .manual: t("Bedienungsanleitungen", "Manuals")
        case .offer: t("Angebote", "Quotes")
        case .craftsman: t("Handwerkerunterlagen", "Contractor Documents")
        case .vehicle: t("Fahrzeugunterlagen", "Vehicle Documents")
        case .other: t("Sonstige Dokumente", "Other Documents")
        }
    }

    public func name(_ m: MessengerApp, evidence: MessengerEvidence) -> String {
        let app = switch m {
        case .whatsApp: "WhatsApp"
        case .iMessage: "iMessage"
        case .telegram: "Telegram"
        case .signal: "Signal"
        case .unknown: "Messenger"
        }
        switch evidence {
        case .recognizedScreenshot: return t("\(app) – Chat-Screenshots", "\(app) – Chat Screenshots")
        case .existingAlbum: return t("\(app) – vorhandene Albuminhalte", "\(app) – Existing Album Items")
        case .plausibleHint: return t("\(app) – vermutete Medien", "\(app) – Probable Media")
        case .unknownOrigin: return t("Messenger – unbekannte Herkunft", "Messenger – Unknown Origin")
        }
    }

    public func name(_ category: ImageCategory) -> String { language == .german ? category.german : category.english }

    public func groupPlaceholder(_ kind: GroupKind, number: Int) -> String {
        switch kind {
        case .person: t("Person \(number)", "Person \(number)")
        case .dog: t("Hund \(number)", "Dog \(number)")
        case .cat: t("Katze \(number)", "Cat \(number)")
        case .otherAnimal: t("Tier \(number)", "Animal \(number)")
        }
    }

    public func frequentPlacePlaceholder(number: Int) -> String { t("Häufiger Ort \(number)", "Frequent Place \(number)") }
    public var roadTripSuffix: String { "Roadtrip" }
    public var unknownPlace: String { t("Unbekannter Aufnahmeort", "Unknown Location") }
}
