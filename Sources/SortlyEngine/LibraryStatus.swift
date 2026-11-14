import Foundation
import SortlyCore

/// Derives each asset's per-area status from facts, proposals and matches (prompt §6.1).
/// Only areas that actually apply to an asset count: a home photo is not "unsorted" just
/// because it belongs to no trip, and a screenshot never needs a place.
public enum LibraryStatus {
    public static func compute(
        facts: [AssetFacts],
        snapshot: ProposalSnapshot?,
        settings: OrganizationSettings,
        overrides: OverrideSet = OverrideSet(),
        contentAnalyzed: Set<AssetID>,
        organizedBySortly: [OrganizationArea: Set<AssetID>] = [:]
    ) -> [AssetID: AssetOrganizationState] {
        var proposedIn: [OrganizationArea: Set<AssetID>] = [:]
        var uncertainIn: [OrganizationArea: Set<AssetID>] = [:]
        var existingAlbumFor: [OrganizationArea: [AssetID: Set<CollectionID>]] = [:]
        for p in snapshot?.proposals ?? [] {
            let area = p.kind.area
            proposedIn[area, default: []].formUnion(p.assetIDs)
            if p.reliability < .likely || p.requiresUserName { uncertainIn[area, default: []].formUnion(p.assetIDs) }
            if let match = snapshot?.matches[p.id], let best = match.best,
               [.alreadyComplete, .extendable, .possibleMatch].contains(match.status) {
                for id in p.assetIDs { existingAlbumFor[area, default: [:]][id, default: []].insert(best.albumID) }
            }
        }
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        let mediaTypes = MediaTypeClassifier()
        var result: [AssetID: AssetOrganizationState] = [:]
        result.reserveCapacity(facts.count)

        for f in facts {
            let analyzed = contentAnalyzed.contains(f.id)
            var areas: [OrganizationArea: AreaFacts] = [:]
            for area in settings.enabledAreas {
                var a = AreaFacts()
                switch area {
                case .places:
                    a.applicable = !f.asset.isScreenshotLike
                    a.analysisImpossible = f.asset.usableLocation == nil
                    a.analyzed = f.asset.usableLocation == nil || f.gpsPlace != nil
                case .trips: a.applicable = f.tripID != nil
                case .frequentPlaces: a.applicable = f.frequentPlaceID != nil
                case .chronology: a.applicable = f.asset.creationDate != nil
                case .mediaTypes: a.applicable = !mediaTypes.categories(for: f.asset).isDisjoint(with: settings.mediaTypes.categories)
                case .screenshots:
                    a.applicable = f.asset.isScreenshotLike
                    a.analyzed = analyzed
                case .imageCategories:
                    a.applicable = !analyzed || !f.categories.isEmpty
                    a.analyzed = analyzed
                case .documents:
                    a.applicable = f.document != nil
                case .messenger:
                    a.applicable = f.messenger != nil
                case .peopleAndPets:
                    a.applicable = !f.groupIDs.isEmpty
                }
                a.proposed = proposedIn[area]?.contains(f.id) ?? false
                a.uncertain = uncertainIn[area]?.contains(f.id) ?? false
                if let albums = existingAlbumFor[area]?[f.id], !albums.isDisjoint(with: f.albumIDs) { a.inMatchingExistingAlbum = true }
                a.organizedBySortly = organizedBySortly[area]?.contains(f.id) ?? false
                areas[area] = a
            }
            result[f.id] = resolver.state(for: f.id, facts: areas, ignored: overrides.isIgnored(f.id), excluded: overrides.isExcluded(f.id))
        }
        return result
    }
}
