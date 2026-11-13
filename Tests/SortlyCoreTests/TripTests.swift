import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Trip detection")
struct TripTests {
    let detector = TripDetector(calendar: Fixture.calendar)

    /// Everyday life in Munich with three Rome trips in different years (Scenario B).
    func romeLibrary() -> (LibraryBuilder, [[AssetID]]) {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        let t1 = lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let t2 = lib.daily(from: "2025-09-03", to: "2025-09-08", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let t3 = lib.daily(from: "2026-06-14", to: "2026-06-21", at: Fixture.Places.rome, perDay: 6, hour: 10)
        return (lib, [t1, t2, t3])
    }

    @Test func repeatedVisitsBecomeSeparateTrips() {
        let (lib, expected) = romeLibrary()
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 3)
        for (trip, ids) in zip(trips, expected) {
            #expect(Set(trip.geotaggedAssetIDs) == Set(ids))
            #expect(trip.kind == .vacation)
            #expect(trip.maxDistanceFromHomeMeters > 600_000)
        }
        let de = DateRangeFormatter(language: .german, timeZone: Fixture.utc)
        #expect(de.format(start: trips[0].start, end: trips[0].end) == "12.05.–19.05.2024")
    }

    @Test func dayTripAndWeekendClassification() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2)
        // Sunday 2026-07-12 day trip to Tegernsee (~50 km)
        lib.daily(from: "2026-07-12", to: "2026-07-12", at: Fixture.Places.tegernsee, perDay: 8, hour: 9)
        // Weekend Fri–Sun at Lake Garda
        lib.daily(from: "2026-09-04", to: "2026-09-06", at: Fixture.Places.gardaLake, perDay: 8, hour: 9)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.map(\.kind) == [.dayTrip, .weekendTrip])
    }

    @Test func roadTripAcrossSeveralStops() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 8, skipping: [("2026-08-03", "2026-08-15")])
        lib.daily(from: "2026-08-03", to: "2026-08-05", at: Fixture.Places.florence, perDay: 4, hour: 19)
        lib.daily(from: "2026-08-06", to: "2026-08-09", at: Fixture.Places.rome, perDay: 4, hour: 19)
        lib.daily(from: "2026-08-10", to: "2026-08-13", at: Fixture.Places.naples, perDay: 4, hour: 19)
        lib.daily(from: "2026-08-14", to: "2026-08-15", at: Fixture.Places.gardaLake, perDay: 4, hour: 19)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 1)
        #expect(trips.first?.kind == .roadTrip)
        #expect((trips.first?.distinctStops ?? 0) >= 3)
    }

    @Test func movingHouseDoesNotCreateEndlessTrip() {
        var lib = LibraryBuilder()
        // Lived in Rome until mid 2023, then moved to Munich.
        lib.daily(from: "2022-01-01", to: "2023-06-30", at: Fixture.Places.rome, perDay: 2)
        lib.daily(from: "2023-07-01", to: "2024-12-31", at: Fixture.Places.munichHome, perDay: 2)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.isEmpty)
    }

    @Test func nonGeotaggedPhotosAreOnlyInferredAndScreenshotsNever() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, skipping: [("2026-05-12", "2026-05-19")])
        lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 5, hour: 10)
        let camera = lib.photo(at: Fixture.date("2026-05-15 13:00"), nil)
        let screenshot = lib.photo(at: Fixture.date("2026-05-15 13:05"), nil, subtypes: .screenshot)
        let messenger = lib.photo(at: Fixture.date("2026-05-15 13:10"), nil, filename: "IMG-20260515-WA0003.jpg")
        let outside = lib.photo(at: Fixture.date("2026-06-15 13:00"), nil)
        let trips = detector.detect(in: lib.assets, excludeFromInference: { $0.originalFilename?.contains("-WA") == true })
        let trip = trips.first { $0.geotaggedAssetIDs.count == 40 }
        #expect(trip?.inferredAssetIDs == [camera])
        #expect(trip?.geotaggedAssetIDs.contains(screenshot) == false)
        #expect(trip?.allAssetIDs.contains(messenger) == false)
        #expect(trip?.allAssetIDs.contains(outside) == false)
    }

    @Test func userCorrectionsSplitAndMergePersistByTime() {
        let (lib, _) = romeLibrary()
        // Split the first Rome trip in the middle.
        let split = detector.detect(in: lib.assets, corrections: .init(forcedBreaks: [Fixture.date("2024-05-16")]))
        #expect(split.count == 4)

        // Merge: two nearby trips separated by a short home stay.
        var lib2 = LibraryBuilder()
        lib2.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 8, skipping: [("2026-08-01", "2026-08-03"), ("2026-08-06", "2026-08-08")])
        lib2.daily(from: "2026-08-01", to: "2026-08-03", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        lib2.daily(from: "2026-08-06", to: "2026-08-08", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        #expect(detector.detect(in: lib2.assets).count == 2)
        let joined = detector.detect(in: lib2.assets, corrections: .init(forcedJoins: [DateInterval(start: Fixture.date("2026-08-01"), end: Fixture.date("2026-08-09"))]))
        #expect(joined.count == 1)
    }

    @Test func tripIdentityIsStableAcrossRuns() {
        let (lib, _) = romeLibrary()
        #expect(detector.detect(in: lib.assets).map(\.id) == detector.detect(in: lib.assets.reversed()).map(\.id))
    }
}

@Suite("Frequent places")
struct FrequentPlaceTests {
    @Test func detectsRecurringPlacesWithoutNamingThem() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 3)
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichWork, perDay: 1, everyNthDay: 7)
        lib.daily(from: "2026-03-01", to: "2026-03-02", at: Fixture.Places.rome, perDay: 10)
        let detector = FrequentPlaceDetector(calendar: Fixture.calendar)
        let places = detector.detect(in: lib.assets)
        #expect(places.count == 2)
        #expect(places[0].distinctDays == 181)
        #expect(places[0].userName == nil)
        #expect(places[1].distinctDays == 26)
        #expect(GeoMath.distance(places[1].centroid, Fixture.Places.munichWork) < 100)
    }

    @Test func mergeRadiusTreatsLargePremisesAsOnePlace() {
        var lib = LibraryBuilder()
        let a = Fixture.Places.munichHome
        let b = GeoCoordinate(latitude: a.latitude + 0.004, longitude: a.longitude) // ~450 m apart
        lib.daily(from: "2026-01-01", to: "2026-03-31", at: a, perDay: 2)
        lib.daily(from: "2026-01-01", to: "2026-03-31", at: b, perDay: 2)
        var config = FrequentPlaceDetector.Configuration()
        #expect(FrequentPlaceDetector(configuration: config, calendar: Fixture.calendar).detect(in: lib.assets).count == 2)
        config.mergeRadiusMeters = 600
        #expect(FrequentPlaceDetector(configuration: config, calendar: Fixture.calendar).detect(in: lib.assets).count == 1)
    }
}
