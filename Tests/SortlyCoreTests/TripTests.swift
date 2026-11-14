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

    /// Someone who mostly takes photos on holiday: a handful of photos at home per year and
    /// a few days of photos per trip (the simulator demo library has exactly this shape).
    /// A short burst of photo days somewhere must never make that place "home".
    @Test func sparseHomePhotographerStillGetsEveryTrip() {
        var lib = LibraryBuilder()
        let cal = Fixture.calendar
        func date(_ y: Int, _ m: Int, _ d: Int, plusDays: Int = 0, hour: Int) -> Date {
            cal.date(byAdding: .day, value: plusDays, to: cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!)!
        }
        let trips: [(GeoCoordinate, Int, Int, Int, Int, Int)] = [   // place, year, month, day, days, photos
            (GeoCoordinate(latitude: 48.8566, longitude: 2.3522), 2018, 10, 5, 3, 12),    // Paris
            (GeoCoordinate(latitude: 41.3874, longitude: 2.1686), 2019, 6, 20, 5, 14),    // Barcelona
            (GeoCoordinate(latitude: 40.7128, longitude: -74.0060), 2019, 11, 2, 6, 16),  // New York
            (GeoCoordinate(latitude: 48.2082, longitude: 16.3738), 2020, 2, 21, 2, 10),   // Wien
            (GeoCoordinate(latitude: 62.1008, longitude: 7.2059), 2021, 7, 12, 5, 14),    // Geiranger
            (GeoCoordinate(latitude: 43.5081, longitude: 16.4402), 2021, 8, 20, 7, 14),   // Split
            (GeoCoordinate(latitude: 38.7223, longitude: -9.1393), 2022, 4, 14, 4, 12),   // Lissabon
            (Fixture.Places.florence, 2022, 9, 3, 3, 11),
            (GeoCoordinate(latitude: 55.6761, longitude: 12.5683), 2023, 5, 18, 3, 10),   // Kopenhagen
            (GeoCoordinate(latitude: 64.1466, longitude: -21.9426), 2023, 8, 1, 4, 12),   // Reykjavík
            (GeoCoordinate(latitude: 63.4186, longitude: -19.0060), 2023, 8, 5, 3, 10),   // Vík, same Iceland trip
            (Fixture.Places.rome, 2024, 5, 10, 5, 20),
            (GeoCoordinate(latitude: 35.0116, longitude: 135.7681), 2024, 10, 8, 6, 16),  // Kyoto
        ]
        for i in 0..<45 {
            lib.photo(at: date(2018 + i % 7, 1 + (i * 5) % 12, 1 + (i * 7) % 27, hour: 10 + i % 9), Fixture.Places.munichHome, jitterMeters: 3_000)
        }
        for i in 0..<12 {
            lib.photo(at: date(2020 + i % 5, 1 + (i * 3) % 12, 5 + i, hour: 15), GeoCoordinate(latitude: 48.3520, longitude: 11.7930))
        }
        for (place, y, m, d, days, photos) in trips {
            for i in 0..<photos { lib.photo(at: date(y, m, d, plusDays: i % days, hour: 9 + i % 10), place, jitterMeters: 2_000) }
        }
        let found = detector.detect(in: lib.assets)
        #expect(found.count == 12)
        #expect(found.allSatisfy { $0.maxDistanceFromHomeMeters > 250_000 })
        #expect(found.map(\.allAssetIDs.count).reduce(0, +) == trips.map(\.5).reduce(0, +))
    }

    /// A brand-new library (two weeks at home, then a weekend away) keeps its home: the
    /// spread rule must not turn the first weeks into a trip.
    @Test func newLibraryKeepsItsHome() {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-03-01", to: "2026-03-14", at: Fixture.Places.munichHome, perDay: 3)
        let away = lib.daily(from: "2026-03-15", to: "2026-03-16", at: Fixture.Places.gardaLake, perDay: 5)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 1)
        #expect(Set(trips.first?.geotaggedAssetIDs ?? []) == Set(away))
    }

    /// Daily photos at home plus a three-week holiday at one place: still one trip.
    @Test func longHolidayAtOnePlaceIsATrip() {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: 2, skipping: [("2025-07-01", "2025-07-24")])
        let beach = lib.daily(from: "2025-07-02", to: "2025-07-23", at: Fixture.Places.naples, perDay: 4)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 1)
        #expect(Set(trips.first?.geotaggedAssetIDs ?? []) == Set(beach))
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
