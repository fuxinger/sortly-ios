import Foundation

/// The ten organization areas of the product scope (Master prompt §4).
public enum OrganizationArea: String, Sendable, Codable, CaseIterable, Identifiable {
    case places          // 4.1 countries, regions, cities
    case trips           // 4.2 trips with date range
    case frequentPlaces  // 4.3 recurring places
    case peopleAndPets   // 4.4
    case messenger       // 4.5
    case screenshots     // 4.6
    case imageCategories // 4.7
    case documents       // 4.8
    case chronology      // 4.9 years, months, periods
    case mediaTypes      // 4.10 videos, live photos, formats

    public var id: String { rawValue }

    /// Areas whose results are personal or uncertain by nature never run in automatic
    /// mode without an explicit confirmation of each group/category (prompt §8, Modus C).
    public var isSensitive: Bool {
        switch self {
        case .peopleAndPets, .documents, .messenger: true
        default: false
        }
    }
}

/// How a piece of information was obtained (prompt §17). Ordered from strongest to weakest
/// *except* for `userConfirmed`, which always wins.
public enum EvidenceSource: String, Sendable, Codable, Comparable {
    case userConfirmed
    case metadata          // deterministic: PhotoKit subtype, date, ...
    case geocoded          // GPS + reverse geocoding
    case existingAlbum     // membership in an album the user created
    case ruleBased         // keyword rules on recognized text etc.
    case modelBased        // image classifier output
    case similarity        // embedding similarity / clustering
    case contentInferred   // e.g. location guessed from image content

    private var rank: Int {
        switch self {
        case .userConfirmed: 0
        case .metadata: 1
        case .geocoded: 2
        case .existingAlbum: 3
        case .ruleBased: 4
        case .modelBased: 5
        case .similarity: 6
        case .contentInferred: 7
        }
    }

    public static func < (lhs: EvidenceSource, rhs: EvidenceSource) -> Bool { lhs.rank < rhs.rank }
}

/// Qualitative reliability. SORTLY deliberately shows no uncalibrated percentages (§17).
public enum Reliability: Int, Sendable, Codable, Comparable, CaseIterable {
    case uncertain = 0
    case plausible = 1
    case likely = 2
    case certain = 3

    public static func < (lhs: Reliability, rhs: Reliability) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The user-facing automation modes (prompt §8).
public enum AutomationMode: String, Sendable, Codable, CaseIterable {
    /// Modus A – only suggestions, every change needs confirmation.
    case suggestOnly
    /// Modus B – confirmed albums may be extended with clearly matching media.
    case semiAutomatic
    /// Modus C – approved rules may also create new albums.
    case automatic
}

/// Per-area organization state of a single asset (prompt §6.1).
public enum AreaStatus: String, Sendable, Codable, CaseIterable {
    case preExisting          // already organized before SORTLY by a matching user album
    case organized            // SORTLY assignment applied and verified
    case proposed             // assignment suggested
    case pendingConfirmation  // part of a plan waiting for confirmation
    case ignored              // user chose not to organize
    case excluded             // excluded from analysis/management
    case analysisPending
    case analysisImpossible   // e.g. no GPS for places, iCloud original unavailable
    case notApplicable        // area does not apply (e.g. trips for a screenshot)
    case unorganized
}

/// The inbox buckets of the SORTLY library view (prompt §6).
public enum InboxBucket: String, Sendable, Codable, CaseIterable {
    case all, unorganized, suggestions, organized, uncertain, ignored, excluded
}

/// Aggregated status of an asset across the user's primary areas.
public enum OverallStatus: String, Sendable, Codable {
    case fullyOrganized, partiallyOrganized, unorganized, ignored, excluded, pending
}
