import Foundation
import Testing
@testable import SortlyCore

@Suite("Country photos (atlas detail)")
struct CountryPhotosTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func photo(_ id: String, _ country: String?, _ city: String?, year: Int?, day: Int = 1, trip: SortlyID? = nil) -> AssetFacts {
        let date = year.flatMap { utc.date(from: DateComponents(year: $0, month: 6, day: day, hour: 12)) }
        return AssetFacts(
            asset: AssetSnapshot(id: AssetID(id), creationDate: date),
            place: country.map { PlaceComponents(isoCountryCode: $0, country: $0, locality: city) },
            tripID: trip
        )
    }

    @Test func groupsByYearNewestFirstWithPlacesAndTrips() {
        let rome = SortlyID("rome"), venice = SortlyID("venice")
        let facts = [
            photo("r1", "IT", "Rom", year: 2023, day: 2, trip: rome),
            photo("r2", "IT", "Rom", year: 2023, day: 5, trip: rome),
            photo("r3", "IT", "Rom", year: 2023, day: 3, trip: rome),
            photo("v1", "IT", "Venedig", year: 2025, day: 9, trip: venice),
            photo("m1", "DE", "München", year: 2025),
            photo("x1", nil, nil, year: 2025),
            photo("n1", "it", "Rom", year: nil),
        ]
        let italy = CountryPhotos.collect(countryCode: "IT", facts: facts, calendar: utc)
        #expect(italy.photoCount == 5)
        #expect(italy.years.map(\.year) == [2025, 2023, nil])
        #expect(italy.years[1].photos.map(\.id) == ["r2", "r3", "r1"])
        #expect(italy.topPlaces == ["Rom", "Venedig"])
        #expect(italy.tripCount == 2)
        #expect(italy.firstVisit == utc.date(from: DateComponents(year: 2023, month: 6, day: 2, hour: 12)))
        #expect(italy.lastVisit == utc.date(from: DateComponents(year: 2025, month: 6, day: 9, hour: 12)))
        #expect(italy.assetIDs == ["r1", "r2", "r3", "v1", "n1"])
    }

    @Test func yearFilterMatchesTheAtlasYear() {
        let facts = [
            photo("a", "FR", "Paris", year: 2022),
            photo("b", "FR", "Paris", year: 2024),
            photo("c", "FR", "Nizza", year: 2024),
            photo("d", "FR", nil, year: nil),
        ]
        let year = CountryPhotos.collect(countryCode: "FR", facts: facts, year: 2024, calendar: utc)
        #expect(year.photoCount == 2)
        #expect(year.years.map(\.year) == [2024])
        #expect(Set(year.topPlaces) == ["Paris", "Nizza"])
        #expect(CountryPhotos.collect(countryCode: "ES", facts: facts, calendar: utc).years.isEmpty)
    }
}
