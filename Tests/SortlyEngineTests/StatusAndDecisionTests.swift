import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyTestSupport

@Suite("Status and recommended decisions")
struct StatusAndDecisionTests {
    let proposal = AlbumProposal(id: SortlyID("p"), kind: .trip, title: "Rom · 2026", assetIDs: ["1", "2", "3"])

    func match(_ status: MatchStatus, editable: Bool = true) -> MatchResult {
        MatchResult(
            proposalID: SortlyID("p"), status: status,
            best: MatchCandidate(albumID: "album", albumTitle: "Rom", metrics: OverlapMetrics(proposalCount: 3, albumCount: 3, intersection: 3), relation: .equivalent, nameSimilarity: 1, score: 1, isEditable: editable),
            alternatives: [], sameNameAlbums: [], reasons: []
        )
    }

    @Test func recommendations() {
        #expect(ProposalDecision.recommended(for: proposal, match: match(.alreadyComplete)) == .keepExisting("album"))
        #expect(ProposalDecision.recommended(for: proposal, match: match(.extendable)) == .extendExisting("album"))
        #expect(ProposalDecision.recommended(for: proposal, match: match(.extendable, editable: false)) == .createNew(title: nil, folderPath: nil))
        #expect(ProposalDecision.recommended(for: proposal, match: match(.multipleMatches)) == .undecided)
        #expect(ProposalDecision.recommended(for: proposal, match: nil) == .createNew(title: nil, folderPath: nil))
        var personal = proposal
        personal.requiresUserName = true
        #expect(ProposalDecision.recommended(for: personal, match: nil) == .undecided)
        #expect(ProposalDecision.recommended(for: personal, match: nil, userTitle: " Garten ") == .createNew(title: "Garten", folderPath: nil))
        #expect(!ProposalDecision.reject.isAccepted)
    }

    @Test func homePhotosAreNotUnsortedJustBecauseTheyAreNoTrip() {
        var lib = LibraryBuilder()
        let home = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let trip = lib.photo(at: Fixture.date("2026-05-12 10:00"), Fixture.Places.rome)
        let place = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", locality: "München")
        let facts = [
            AssetFacts(asset: lib.assets[0], place: place, placeSource: .gpsReverseGeocoded),
            AssetFacts(asset: lib.assets[1], place: PlaceComponents(isoCountryCode: "IT", country: "Italien", locality: "Rom"), placeSource: .gpsReverseGeocoded, tripID: SortlyID("t"), albumIDs: ["album"]),
        ]
        let snapshot = ProposalSnapshot(
            generatedAt: Date(), scope: .all,
            proposals: [
                AlbumProposal(id: SortlyID("p"), kind: .trip, title: "Rom", assetIDs: [trip]),
                AlbumProposal(id: SortlyID("c"), kind: .placeCollection(.country), title: "Deutschland", assetIDs: [home]),
            ],
            matches: [SortlyID("p"): match(.alreadyComplete)]
        )
        var settings = OrganizationSettings()
        settings.primaryAreas = [.trips, .places]
        let states = LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings, contentAnalyzed: [home, trip])
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        #expect(states[home]?.areas[.trips] == .notApplicable)
        #expect(states[home]?.areas[.places] == .proposed)
        #expect(resolver.overall(states[home]!) == .unorganized)
        #expect(states[trip]?.areas[.trips] == .preExisting)
        #expect(resolver.overall(states[trip]!) == .partiallyOrganized) // places still open
        let ignored = LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings,
                                            overrides: OverrideSet([UserOverride(scope: .asset(home), decision: .ignoreAsset)]), contentAnalyzed: [])
        #expect(resolver.overall(ignored[home]!) == .ignored)
    }
}
