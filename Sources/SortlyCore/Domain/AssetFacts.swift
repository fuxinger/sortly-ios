import Foundation

/// Everything SORTLY knows about one asset after analysis. Input for rules, search,
/// status and proposals. Built from persisted analysis results.
public struct AssetFacts: Hashable, Sendable, Identifiable {
    public var asset: AssetSnapshot
    public var place: PlaceComponents?
    public var placeSource: PlaceSource?
    public var frequentPlaceID: SortlyID?
    public var tripID: SortlyID?
    /// Image category id → reliability (only categories at or above "plausible").
    public var categories: [String: Reliability]
    /// Screenshot content categories.
    public var textCategories: Set<String>
    public var document: DocumentInfo?
    public var messenger: MessengerAssessment?
    /// Confirmed person/pet group ids.
    public var groupIDs: Set<SortlyID>
    public var albumIDs: Set<CollectionID>
    /// Recognized text, kept only on device for search.
    public var recognizedText: String?
    public var keywords: Set<String>

    public init(
        asset: AssetSnapshot,
        place: PlaceComponents? = nil,
        placeSource: PlaceSource? = nil,
        frequentPlaceID: SortlyID? = nil,
        tripID: SortlyID? = nil,
        categories: [String: Reliability] = [:],
        textCategories: Set<String> = [],
        document: DocumentInfo? = nil,
        messenger: MessengerAssessment? = nil,
        groupIDs: Set<SortlyID> = [],
        albumIDs: Set<CollectionID> = [],
        recognizedText: String? = nil,
        keywords: Set<String> = []
    ) {
        self.asset = asset
        self.place = place
        self.placeSource = placeSource
        self.frequentPlaceID = frequentPlaceID
        self.tripID = tripID
        self.categories = categories
        self.textCategories = textCategories
        self.document = document
        self.messenger = messenger
        self.groupIDs = groupIDs
        self.albumIDs = albumIDs
        self.recognizedText = recognizedText
        self.keywords = keywords
    }

    public var id: AssetID { asset.id }

    /// Place usable for geographic organization: GPS-based only. Content guesses are
    /// shown separately and never used here (prompt §4.1).
    public var gpsPlace: PlaceComponents? {
        placeSource == .gpsReverseGeocoded || placeSource == .userAssigned ? place : nil
    }

    public func hasCategory(_ id: String, minimum: Reliability = .likely) -> Bool {
        if let r = categories[id], r >= minimum { return true }
        // Parent categories match their children: "vehicle" matches "vehicle.car".
        let prefix = id + "."
        return categories.contains { $0.key.hasPrefix(prefix) && $0.value >= minimum }
    }
}
