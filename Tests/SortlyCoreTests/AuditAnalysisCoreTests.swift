import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Core-level regression tests for the analysis findings of the cross-review of 14.11.2026
/// (docs/review/AUDIT_2026-11-14.md, group 2).
@Suite("Audit 14.11.2026: analysis rules")
struct AuditAnalysisCoreTests {
    // MARK: 2.1 trip identity

    @Test func splitTripKeepsItsIdOnTheBiggerPart() {
        func trip(_ id: String, _ members: [AssetID]) -> Trip {
            Trip(id: SortlyID(id), start: Date(), end: Date(), geotaggedAssetIDs: members, inferredAssetIDs: [],
                 centroid: GeoCoordinate(latitude: 0, longitude: 0), maxDistanceFromHomeMeters: 0, distinctStops: 1, kind: .vacation)
        }
        let all = (0..<10).map { AssetID("a\($0)") }
        let known = [TripIdentity(id: SortlyID("trip-old"), members: all)]
        // The first three photos become a trip of their own (the user split it).
        let split = TripIdentity.carryOver([trip("t-a0", Array(all.prefix(3))), trip("t-a3", Array(all.dropFirst(3)))], from: known)
        #expect(split[1].id.rawValue == "trip-old")
        #expect(split[0].id.rawValue != "trip-old")
        // A trip that shares too little keeps its own id.
        let other = TripIdentity.carryOver([trip("t-x", [all[0], "b1", "b2", "b3"])], from: known)
        #expect(other[0].id.rawValue == "t-x")
        // An id that would collide with a carried-over one is made unique.
        let collide = TripIdentity.carryOver([trip("trip-old", ["c1", "c2"]), trip("t-a1", Array(all.dropFirst()))], from: known)
        #expect(collide[1].id.rawValue == "trip-old")
        #expect(collide[0].id.rawValue != "trip-old")
    }


    // MARK: 5.2 matcher with one big shared album

    @Test func matcherLargeSharedAlbumScalesWithMemberships() {
        // 400 trips of 100 photos each, all in one "Reisen" album of 40,000 photos.
        var proposals: [AlbumProposal] = []
        var all = Set<AssetID>()
        for t in 0..<400 {
            let ids = Set((0..<100).map { AssetID("t\(t)-\($0)") })
            all.formUnion(ids)
            proposals.append(AlbumProposal(id: SortlyID("trip-\(t)"), kind: .trip, title: "Reise \(t)", assetIDs: ids))
        }
        let inventory = CollectionInventory([CollectionSnapshot(id: "reisen", title: "Reisen", assetIDs: all)])
        let clock = ContinuousClock()
        var results: [SortlyID: MatchResult] = [:]
        let elapsed = clock.measure { results = AlbumMatcher().match(proposals, against: inventory) }
        #expect(results.count == 400)
        // The big album spans all trips: a broader collection, never a trip's album.
        #expect(results.values.allSatisfy { $0.best?.albumID != "reisen" })
        #expect(elapsed < .seconds(3)) // before: every trip read all 40,000 photos again
    }

    // MARK: 2.6 uncertainty counted once

    @Test func areaOverviewCountsUncertainProposalOnlyOnce() {
        let proposal = AlbumProposal(id: SortlyID("p"), kind: .trip, title: "Irgendwo", assetIDs: ["a", "b"], reliability: .plausible)
        let match = MatchResult(proposalID: proposal.id, status: .ambiguous, best: nil, alternatives: [], sameNameAlbums: [], reasons: [])
        let overview = AreaOverview.make(proposals: [proposal], matches: [proposal.id: match])
        #expect(overview.first?.uncertain == 1)
        #expect(overview.first?.proposalCount == 1)
    }

    // MARK: 2.7 trip days in the destination's time zone

    @Test func dayTripUsesDestinationCalendarAcrossMidnight() {
        // New York, 10:00 to 23:30 local time (UTC−5): in UTC that is 15:00 to 04:30 next day.
        let newYork = GeoCoordinate(latitude: 40.7128, longitude: -74.0060)
        let assets = (0..<8).map { i in
            AssetSnapshot(id: AssetID("ny\(i)"), creationDate: Fixture.date("2026-01-17 15:00").addingTimeInterval(Double(i) * 6_900), location: newYork)
        }
        let utc = Fixture.calendar
        let inUTC = TripDetector.classify(dates: assets.map { $0.creationDate! }, coordinates: assets.map { $0.location! }, calendar: utc)
        #expect(inUTC.kind != .dayTrip)
        let trip = Trip(id: SortlyID("t"), start: assets.first!.creationDate!, end: assets.last!.creationDate!, geotaggedAssetIDs: assets.map(\.id),
                        inferredAssetIDs: [], centroid: newYork, maxDistanceFromHomeMeters: 6_000_000, distinctStops: inUTC.stops, kind: inUTC.kind)
        let zones = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, "America/New_York") })
        let local = TripDetector.inDestinationTime([trip], assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }), timeZones: zones, calendar: utc)
        #expect(local[0].kind == .dayTrip)
        #expect(local[0].id == trip.id)
        // Without a known time zone nothing changes.
        #expect(TripDetector.inDestinationTime([trip], assets: [:], timeZones: [:], calendar: utc) == [trip])
    }
}
