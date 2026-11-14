import Foundation

/// The user's organization configuration (prompt §7, Schritt 5). Every area has its own
/// settings; advanced parameters live in the nested `advanced` structs (§28.8).
public struct OrganizationSettings: Hashable, Sendable, Codable {
    public var enabledAreas: Set<OrganizationArea>
    /// Areas that count as "main organization" for the inbox (prompt §6.1).
    public var primaryAreas: Set<OrganizationArea>
    public var rootFolderTitle: String
    public var titleLanguage: TitleLanguage
    /// May one photo appear in several albums of the same area hierarchy (country + city)?
    public var allowMultipleAssignments: Bool
    public var automation: AutomationPolicy

    public var places: PlaceSettings
    public var trips: TripSettings
    public var frequentPlaces: FrequentPlaceSettings
    public var chronology: ChronologySettings
    public var mediaTypes: MediaTypeSettings
    public var screenshots: ScreenshotSettings
    public var imageCategories: ImageCategorySettings
    public var documents: DocumentSettings
    public var messenger: MessengerSettings
    public var people: PeopleSettings
    public var privacy: PrivacySettings

    public init() {
        // Defaults avoid an album flood: years/months and media types are already shown by
        // the Photos app and are opt-in (decision 2026-11-13, docs/DECISIONS.md).
        enabledAreas = [.places, .trips, .frequentPlaces, .screenshots, .imageCategories, .documents]
        primaryAreas = [.trips, .places]
        rootFolderTitle = "Albumist"
        titleLanguage = .deviceDefault
        allowMultipleAssignments = true
        automation = AutomationPolicy(globalMode: .suggestOnly)
        places = PlaceSettings()
        trips = TripSettings()
        frequentPlaces = FrequentPlaceSettings()
        chronology = ChronologySettings()
        mediaTypes = MediaTypeSettings()
        screenshots = ScreenshotSettings()
        imageCategories = ImageCategorySettings()
        documents = DocumentSettings()
        messenger = MessengerSettings()
        people = PeopleSettings()
        privacy = PrivacySettings()
    }

    public static let `default` = OrganizationSettings()
}

public struct PlaceSettings: Hashable, Sendable, Codable {
    /// Levels that get albums. Presets map to prompt §4.1 options 1–6.
    public var levels: [PlaceLevel] = [.country, .locality]
    /// Nest lower levels inside folders of higher levels.
    public var hierarchical = true
    public var minPhotos = 10

    public enum Preset: String, CaseIterable, Sendable, Codable {
        case countries, countriesAndCities, countriesRegionsCities, withDistricts, withPlaceGroups
        public var levels: [PlaceLevel] {
            switch self {
            case .countries: [.country]
            case .countriesAndCities: [.country, .locality]
            case .countriesRegionsCities: [.country, .administrativeArea, .locality]
            case .withDistricts: [.country, .administrativeArea, .locality, .subLocality]
            case .withPlaceGroups: [.country, .administrativeArea, .locality, .subLocality, .pointOfInterest]
            }
        }
    }

    public init() {}
}

public struct TripSettings: Hashable, Sendable, Codable {
    public var template = NamingTemplate.tripDefault
    public var minPhotos = 10
    /// Put trips into one folder per year.
    public var folderPerYear = true
    public var includeDayTrips = true
    /// Add a permanent place album ("Rom") next to the individual trips (Scenario B).
    public var placeCollectionForRepeatedTrips = true
    public var advanced = TripDetector.Configuration()
    public init() {}
}

public struct FrequentPlaceSettings: Hashable, Sendable, Codable {
    public var advanced = FrequentPlaceDetector.Configuration()
    /// User-given names keyed by frequent place id.
    public var names: [SortlyID: String] = [:]
    public init() {}
}

public struct ChronologySettings: Hashable, Sendable, Codable {
    public var levels: [ChronologyGranularity] = [.year, .month]
    public var minPhotos = 1
    public var customPeriods: [CustomPeriod] = []
    public init() {}
}

public struct MediaTypeSettings: Hashable, Sendable, Codable {
    public var categories: Set<MediaTypeCategory> = [.videos, .livePhotos, .screenRecordings, .panoramas, .slowMotion, .timelapse, .raw, .portraitMode, .longVideos]
    public var minItems = 1
    public init() {}
}

public struct ScreenshotSettings: Hashable, Sendable, Codable {
    public var minItems = 3
    public var includeUncertain = false
    public init() {}
}

public struct ImageCategorySettings: Hashable, Sendable, Codable {
    public var minPhotos = 15
    public var minimumReliability: Reliability = .likely
    /// Only leaf categories become albums by default (Autos, Hunde, ...), parents become folders.
    public var leafCategoriesOnly = true
    public var disabledCategories: Set<String> = []
    public init() {}
}

public struct DocumentSettings: Hashable, Sendable, Codable {
    public var minItems = 1
    /// Sensitive documents (ID, medical, bank) are only exported after explicit selection (§4.8).
    public var includeSensitive = false
    public init() {}
}

public struct MessengerSettings: Hashable, Sendable, Codable {
    /// Include file-name hints ("vermutete Medien"). Off by default (§4.5).
    public var includeHints = false
    public var minItems = 3
    public init() {}
}

public struct PeopleSettings: Hashable, Sendable, Codable {
    /// Face grouping is opt-in: faces are special-category personal data under GDPR Art. 9.
    public var faceGroupingEnabled = false
    public var petGroupingEnabled = true
    public var advanced = ObservationGrouperSettings()
    public init() {}
}

public struct ObservationGrouperSettings: Hashable, Sendable, Codable {
    public var distanceThreshold: Float = 0.35
    public var minGroupSize = 3
    public init() {}
}

public struct PrivacySettings: Hashable, Sendable, Codable {
    public var includeHiddenAssets = false
    /// Allow downloading iCloud originals for analysis (default: only local data).
    public var allowNetworkForAnalysis = false
    public var allowCellularDownloads = false
    /// Reverse geocoding uses Apple's service; can be turned off (then only offline data).
    public var allowOnlineGeocoding = true
    public var excludedAlbumIDs: Set<CollectionID> = []
    public init() {}
}
