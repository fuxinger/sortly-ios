import Foundation
import SortlyCore

/// Result of the text stage for one asset (stored as analysis result kind "text").
public struct TextResult: Hashable, Sendable, Codable {
    public var text: TextAnalysis?
    public var document: DocumentInfo?
    public var screenshotCategories: [String]
    /// The original is only in iCloud and downloading was not allowed: read later.
    public var waitingForOriginal: Bool

    public init(text: TextAnalysis? = nil, document: DocumentInfo? = nil, screenshotCategories: [String] = [], waitingForOriginal: Bool = false) {
        self.text = text
        self.document = document
        self.screenshotCategories = screenshotCategories
        self.waitingForOriginal = waitingForOriginal
    }
}

/// Scope of a trial run ("Probelauf"): the first organization covers only one year or one
/// album, so the user can check the result calmly before organizing everything.
public enum OrganizationScope: Hashable, Sendable, Codable {
    case all
    case year(Int)
    case album(CollectionID)

    public func includes(_ facts: AssetFacts, calendar: Calendar) -> Bool {
        switch self {
        case .all: true
        case .year(let y): facts.asset.creationDate.map { calendar.component(.year, from: $0) == y } ?? false
        case .album(let id): facts.albumIDs.contains(id)
        }
    }
}

/// Joins stored analysis results into the per-asset facts the proposal engine, status
/// resolver and search work on.
public enum FactsAssembler {
    public static func assemble(
        assets: [AssetSnapshot],
        places: [AssetID: ResolvedPlace],
        contents: [AssetID: ContentAnalysis],
        texts: [AssetID: TextResult],
        trips: [Trip],
        frequentPlaces: [FrequentPlace],
        groups: [ObservationGroup],
        inventory: CollectionInventory
    ) -> [AssetFacts] {
        var tripOf: [AssetID: SortlyID] = [:]
        for trip in trips { for id in trip.geotaggedAssetIDs { tripOf[id] = trip.id } }
        var frequentOf: [AssetID: SortlyID] = [:]
        for place in frequentPlaces { for id in place.assetIDs { frequentOf[id] = place.id } }
        var groupsOf: [AssetID: Set<SortlyID>] = [:]
        for group in groups where group.isConfirmed { for id in group.assetIDs { groupsOf[id, default: []].insert(group.id) } }
        let membership = inventory.albumMembershipIndex()
        let titles = inventory.collections.mapValues(\.title)
        let messenger = MessengerClassifier()

        return assets.map { asset in
            let place = places[asset.id]
            let content = contents[asset.id]
            let text = texts[asset.id]
            let albums = membership[asset.id] ?? []
            let recognized = text?.text?.text
            let assessment = messenger.assess(asset: asset, recognizedText: recognized, albumTitles: albums.compactMap { titles[$0] })
            let categories = content.map { ImageTaxonomy.categories(from: $0.labels.map { ($0.identifier, $0.confidence) }) } ?? [:]
            return AssetFacts(
                asset: asset,
                place: place?.components,
                placeSource: place?.source,
                frequentPlaceID: frequentOf[asset.id],
                tripID: tripOf[asset.id],
                categories: categories,
                textCategories: Set(text?.screenshotCategories ?? []),
                document: text?.document,
                messenger: assessment.evidence > .unknownOrigin ? assessment : nil,
                groupIDs: groupsOf[asset.id] ?? [],
                albumIDs: Set(albums),
                recognizedText: recognized,
                keywords: Set(content?.labels.filter { $0.confidence >= 0.5 }.map(\.identifier) ?? [])
            )
        }
    }
}
