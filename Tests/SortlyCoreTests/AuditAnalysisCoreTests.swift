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

}
