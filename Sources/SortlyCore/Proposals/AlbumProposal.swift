import Foundation

/// What kind of album a proposal describes. The kind decides how existing albums are
/// compared (a country collection is not a trip album – prompt §5.2).
public enum ProposalKind: Hashable, Sendable, Codable {
    case trip
    case placeCollection(PlaceLevel)
    case frequentPlace
    case chronology(ChronologyGranularity)
    case customPeriod
    case imageCategory(String)
    case screenshotCategory(String)
    case documentCategory(String)
    case messenger(String)
    case mediaType(String)
    case personOrPet
    case personalCategory
    case rule

    public var area: OrganizationArea {
        switch self {
        case .trip: .trips
        case .placeCollection: .places
        case .frequentPlace: .frequentPlaces
        case .chronology, .customPeriod: .chronology
        case .imageCategory, .personalCategory: .imageCategories
        case .screenshotCategory: .screenshots
        case .documentCategory: .documents
        case .messenger: .messenger
        case .mediaType: .mediaTypes
        case .personOrPet: .peopleAndPets
        case .rule: .imageCategories
        }
    }

    /// Kinds that describe one bounded event rather than a long-running collection.
    public var isEventLike: Bool {
        switch self {
        case .trip, .customPeriod: true
        default: false
        }
    }

    /// Stable string used in identities and grouping of sibling proposals.
    public var familyKey: String {
        switch self {
        case .trip: "trip"
        case .placeCollection(let l): "place.\(l.rawValue)"
        case .frequentPlace: "frequent"
        case .chronology(let g): "chrono.\(g.rawValue)"
        case .customPeriod: "period"
        case .imageCategory: "category"
        case .screenshotCategory: "screenshot"
        case .documentCategory: "document"
        case .messenger: "messenger"
        case .mediaType: "mediatype"
        case .personOrPet: "person"
        case .personalCategory: "personal"
        case .rule: "rule"
        }
    }
}

/// Human-readable reason for a proposal. Rendered by the app in the user's language.
public enum ProposalReason: Hashable, Sendable, Codable {
    /// "286 Aufnahmen zwischen dem 12. und 19. Mai in Rom"
    case photosInPlaceDuringPeriod(count: Int, place: String, start: Date, end: Date)
    case photosInPlace(count: Int, place: String)
    case photosInPeriod(count: Int, start: Date, end: Date)
    case recurringPlace(count: Int, days: Int)
    case recognizedContent(count: Int, label: String)
    case recognizedText(count: Int, label: String)
    case mediaType(count: Int, label: String)
    case confirmedGroup(count: Int, name: String)
    case ruleMatched(count: Int, rule: String)
    case inferredWithoutLocation(count: Int)
}

/// One concrete album Albumist could create or extend (prompt §7, Schritt 6).
public struct AlbumProposal: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var kind: ProposalKind
    public var title: String
    /// Folder path below the Albumist root, e.g. ["Länder", "Italien"].
    public var folderPath: [String]
    /// Members backed by strong evidence.
    public var assetIDs: Set<AssetID>
    /// Members suggested with weaker evidence; never applied without confirmation.
    public var optionalAssetIDs: Set<AssetID>
    public var reliability: Reliability
    public var reasons: [ProposalReason]
    public var dateRange: DateInterval?
    public var placeKeys: [PlaceKey]
    /// Asset used as cover in previews.
    public var coverAssetID: AssetID?
    /// Personal or sensitive content: never automatic, extra care in export (§4.8, §8).
    public var isSensitive: Bool
    /// Personal places and groups must be named by the user before an album is created (§4.3, §4.4).
    public var requiresUserName: Bool

    public init(
        id: SortlyID,
        kind: ProposalKind,
        title: String,
        folderPath: [String] = [],
        assetIDs: Set<AssetID>,
        optionalAssetIDs: Set<AssetID> = [],
        reliability: Reliability = .likely,
        reasons: [ProposalReason] = [],
        dateRange: DateInterval? = nil,
        placeKeys: [PlaceKey] = [],
        coverAssetID: AssetID? = nil,
        isSensitive: Bool = false,
        requiresUserName: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.folderPath = folderPath
        self.assetIDs = assetIDs
        self.optionalAssetIDs = optionalAssetIDs.subtracting(assetIDs)
        self.reliability = reliability
        self.reasons = reasons
        self.dateRange = dateRange
        self.placeKeys = placeKeys
        self.coverAssetID = coverAssetID ?? assetIDs.min()
        self.isSensitive = isSensitive
        self.requiresUserName = requiresUserName
    }
}
