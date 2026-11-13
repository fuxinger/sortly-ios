import Foundation
import Testing
@testable import SortlyCore

@Suite("Travel atlas")
struct TravelAtlasTests {
    func fact(_ n: Int, country: String, city: String?, day: Int, trip: SortlyID?) -> AssetFacts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2023, month: 7, day: day, hour: 12))!
        return AssetFacts(
            asset: AssetSnapshot(id: AssetID("a\(n)"), creationDate: date),
            place: PlaceComponents(isoCountryCode: country, country: country, locality: city),
            tripID: trip
        )
    }

    @Test func countsCountriesCitiesAndTrips() {
        let rome = SortlyID("trip-rome"), paris = SortlyID("trip-paris")
        var facts: [AssetFacts] = []
        for i in 0..<5 { facts.append(fact(i, country: "DE", city: "München", day: 1, trip: nil)) }
        for i in 5..<15 { facts.append(fact(i, country: "IT", city: "Rom", day: 3 + (i - 5) % 6, trip: rome)) }
        for i in 15..<19 { facts.append(fact(i, country: "FR", city: "Paris", day: 20, trip: paris)) }
        facts.append(fact(99, country: "AT", city: "Wien", day: 25, trip: nil)) // below minimum
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let atlas = TravelAtlas.compute(facts: facts, calendar: utc)
        #expect(atlas.countryCodes == ["DE", "IT", "FR"])
        #expect(atlas.cityCount == 4)
        #expect(atlas.tripCount == 2)
        #expect(atlas.sinceYear == 2023)
        #expect(atlas.longestTripDays == 6)
        #expect(atlas.favoriteTripCity == "Rom")
        #expect(atlas.countriesByFirstVisit == ["DE", "IT", "FR"])
        #expect(atlas.continents == [.europe])
        #expect(TravelAtlas.flag("it") == "🇮🇹")
        #expect(atlas.trips.map(\.place) == ["Rom", "Paris"])
        #expect(atlas.trips.first?.days == 6)
        #expect(TravelAtlas.flag("X") == "")
    }
}
