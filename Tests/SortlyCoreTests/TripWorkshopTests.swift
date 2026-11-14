import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Reise-Werkstatt (I07): split a trip at a day, merge two neighbours, go back to automatic.
@Suite("Trip workshop")
struct TripWorkshopTests {
    let detector = TripDetector(calendar: Fixture.calendar)

    /// Munich every second day, Rome 12.–19. May 2024 (8 days, 6 photos a day).
    func library() -> LibraryBuilder {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2024-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        return lib
    }

    func dates(_ lib: LibraryBuilder) -> [AssetID: Date] {
        Dictionary(uniqueKeysWithValues: lib.assets.compactMap { a in a.creationDate.map { (a.id, $0) } })
    }

    @Test func splittingAtADayMakesTwoTripsThatStaySplit() throws {
        let lib = library()
        let trip = try #require(detector.detect(in: lib.assets).first)
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: dates(lib), calendar: Fixture.calendar)
        #expect(days.count == 8)
        #expect(days.allSatisfy { $0.count == 6 })

        // The first day cannot start a new trip; day 4 (15 May) can.
        #expect(TripWorkshop.split(days, before: 0, dates: dates(lib)) == nil)
        let preview = try #require(TripWorkshop.split(days, before: 3, dates: dates(lib)))
        #expect(preview.first.count == 18)
        #expect(preview.second.count == 30)

        let corrections = TripCorrections().splitting(at: TripWorkshop.splitInstant(before: days[3]))
        let parts = detector.detect(in: lib.assets, corrections: corrections)
        #expect(parts.count == 2)
        #expect(parts.map(\.geotaggedAssetIDs.count) == [18, 30])
        #expect(Fixture.calendar.startOfDay(for: parts[1].start) == days[3].start)
        // Splitting twice at the same day stores one split.
        #expect(corrections.splitting(at: days[3].start).forcedBreaks.count == 1)
        #expect(corrections.changeCount == 1)
    }

    @Test func mergingTwoNeighboursMakesOneTripAndUndoesASplitInside() throws {
        let lib = library()
        let all = dates(lib)
        let trip = try #require(detector.detect(in: lib.assets).first)
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: all, calendar: Fixture.calendar)
        let split = TripCorrections().splitting(at: days[3].start)
        let parts = detector.detect(in: lib.assets, corrections: split)
        #expect(parts.count == 2)

        // Neighbours: the second part follows the first right away.
        let spans = parts.map { DateInterval(start: $0.start, end: $0.end) }
        let around = TripWorkshop.neighbours(of: spans[0], among: spans)
        #expect(around.before == nil)
        #expect(around.after == 1)
        #expect(TripWorkshop.neighbours(of: spans[1], among: spans).before == 0)

        let interval = TripWorkshop.mergeInterval(spans[0], spans[1],
                                                  members: parts[0].geotaggedAssetIDs + parts[1].geotaggedAssetIDs, dates: all)
        let merged = split.merging(interval)
        #expect(merged.forcedBreaks.isEmpty) // the split inside is gone, or it would still cut
        let again = detector.detect(in: lib.assets, corrections: merged)
        #expect(again.count == 1)
        #expect(again.first?.geotaggedAssetIDs.count == 48)
    }

    @Test func mergingKeepsTwoTripsWithAHomeStayTogether() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 8,
                  skipping: [("2026-08-01", "2026-08-03"), ("2026-08-06", "2026-08-08")])
        lib.daily(from: "2026-08-01", to: "2026-08-03", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        lib.daily(from: "2026-08-06", to: "2026-08-08", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 2)
        let spans = trips.map { DateInterval(start: $0.start, end: $0.end) }
        let interval = TripWorkshop.mergeInterval(spans[0], spans[1], members: trips.flatMap(\.geotaggedAssetIDs), dates: dates(lib))
        let joined = detector.detect(in: lib.assets, corrections: TripCorrections().merging(interval))
        #expect(joined.count == 1)
        #expect(joined.first?.geotaggedAssetIDs.count == 30)
    }

    @Test func neighboursFurtherThanTwoWeeksAwayAreNotOffered() {
        let day: TimeInterval = 86_400
        let base = Fixture.date("2026-03-01")
        let trip = DateInterval(start: base, duration: 3 * day)
        let close = DateInterval(start: base.addingTimeInterval(10 * day), duration: 2 * day)
        let far = DateInterval(start: base.addingTimeInterval(-40 * day), duration: 2 * day)
        let around = TripWorkshop.neighbours(of: trip, among: [far, trip, close])
        #expect(around.before == nil)
        #expect(around.after == 2)
    }

    @Test func resetKeepsPhotosTakenOutOfTrips() {
        let photo = AssetID("p1")
        let corrections = TripCorrections(forcedBreaks: [Fixture.date("2026-01-01")],
                                          forcedJoins: [DateInterval(start: Fixture.date("2026-02-01"), duration: 86_400)],
                                          excludedAssets: [photo])
        #expect(corrections.changeCount == 2)
        let reset = corrections.withoutSplitsAndMerges()
        #expect(reset.changeCount == 0)
        #expect(reset.excludedAssets == [photo])
    }
}
