import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Fake reverse geocoder for tests: maps fixture coordinates to address components.
enum FixtureGeocoder {
    static let table: [(GeoCoordinate, PlaceComponents)] = [
        (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München", timeZoneIdentifier: "Europe/Berlin")),
        (Fixture.Places.munichWork, .init(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München", timeZoneIdentifier: "Europe/Berlin")),
        (Fixture.Places.rome, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", timeZoneIdentifier: "Europe/Rome")),
        (Fixture.Places.florence, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Toskana", locality: "Florenz", timeZoneIdentifier: "Europe/Rome")),
        (Fixture.Places.naples, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Kampanien", locality: "Neapel", timeZoneIdentifier: "Europe/Rome")),
        (Fixture.Places.gardaLake, .init(isoCountryCode: "IT", country: "Italien", administrativeArea: "Venetien", locality: "Malcesine", inlandWater: "Gardasee", timeZoneIdentifier: "Europe/Rome")),
    ]

    static func facts(for assets: [AssetSnapshot]) -> [AssetFacts] {
        assets.map { a in
            guard let loc = a.usableLocation else { return AssetFacts(asset: a) }
            let nearest = table.min { GeoMath.distance(loc, $0.0) < GeoMath.distance(loc, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
    }
}

@Suite("Proposal engine")
struct ProposalEngineTests {
    func romeAnalysis() -> AnalysisSnapshot {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        lib.daily(from: "2025-09-03", to: "2025-09-08", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let trips = TripDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        return AnalysisSnapshot(facts: FixtureGeocoder.facts(for: lib.assets), trips: trips)
    }

    func engine(_ configure: (inout OrganizationSettings) -> Void = { _ in }) -> ProposalEngine {
        var s = OrganizationSettings()
        s.titleLanguage = .german
        configure(&s)
        return ProposalEngine(settings: s, calendar: Fixture.calendar)
    }

    @Test func tripsAreNamedAfterDominantCityAndFiledByYear() {
        let proposals = engine().proposals(for: romeAnalysis()).filter { $0.kind == .trip }
        #expect(proposals.count == 2)
        #expect(proposals.first?.title == "Rom · 12.05.–19.05.2024")
        #expect(proposals.first?.folderPath == ["Reisen", "2024"])
        #expect(proposals.allSatisfy { $0.reliability == .likely })
    }

    @Test func repeatedTripsGetPermanentPlaceCollection() {
        let analysis = romeAnalysis()
        let all = engine().proposals(for: analysis)
        let collection = all.first { if case .placeCollection = $0.kind, $0.folderPath == ["Reisen"] { return true } else { return false } }
        #expect(collection?.title == "Rom")
        let tripAssets = all.filter { $0.kind == .trip }.reduce(into: Set<AssetID>()) { $0.formUnion($1.assetIDs) }
        #expect(collection?.assetIDs == tripAssets)

        let without = engine { $0.trips.placeCollectionForRepeatedTrips = false }.proposals(for: analysis)
        #expect(!without.contains { $0.folderPath == ["Reisen"] })
    }

    /// Default: countries only, so a trip does not turn into four albums (usability test 14.11.2026).
    @Test func citiesAreOptInByDefault() {
        let places = engine().proposals(for: romeAnalysis()).filter { $0.kind.area == .places }
        #expect(places.contains { $0.title == "Italien" && $0.folderPath == ["Länder"] })
        #expect(!places.contains { $0.title == "München" })
        #expect(!places.contains { $0.folderPath == ["Länder", "Italien"] })
    }

    @Test func placeCollectionsAreHierarchical() {
        let places = engine { $0.places.levels = PlaceSettings.Preset.countriesAndCities.levels }
            .proposals(for: romeAnalysis()).filter { $0.kind.area == .places }
        let rome = places.first { $0.title == "Rom" }
        #expect(rome?.folderPath == ["Länder", "Italien"])
        #expect(places.contains { $0.title == "Italien" && $0.folderPath == ["Länder"] })
        #expect(places.contains { $0.title == "München" })
    }

    @Test func idsAreStableAcrossRuns() {
        let a = engine().proposals(for: romeAnalysis()).map(\.id)
        let b = engine().proposals(for: romeAnalysis()).map(\.id)
        #expect(a == b)
        #expect(Set(a).count == a.count)
    }

    @Test func disabledAreasAndRejectedProposalsProduceNothing() {
        let analysis = romeAnalysis()
        let onlyTrips = engine { $0.enabledAreas = [.trips] }.proposals(for: analysis)
        #expect(onlyTrips.allSatisfy { $0.kind.area == .trips || $0.folderPath.first == "Reisen" })
        let rejected = onlyTrips[0].id
        let filtered = engine { $0.enabledAreas = [.trips] }.proposals(
            for: analysis,
            overrides: OverrideSet([UserOverride(scope: .source(rejected), decision: .rejectProposal)])
        )
        #expect(!filtered.contains { $0.id == rejected })
    }

    @Test func peopleNeedOptInAndUnnamedGroupsNeedAName() {
        let person = ObservationGroup(id: .stable("g", "p"), kind: .person, observationIDs: ["a", "b", "c"], assetIDs: ["1", "2", "3"], confirmedName: nil, isConfirmed: false)
        let dog = ObservationGroup(id: .stable("g", "d"), kind: .dog, observationIDs: ["d", "e", "f"], assetIDs: ["4", "5", "6"], confirmedName: "Bello", isConfirmed: true)
        let analysis = AnalysisSnapshot(facts: [], groups: [person, dog])
        let defaults = engine { $0.enabledAreas = [.peopleAndPets] }.proposals(for: analysis)
        #expect(defaults.map(\.title) == ["Bello"])
        #expect(defaults[0].isSensitive && !defaults[0].requiresUserName)

        let optedIn = engine { $0.enabledAreas = [.peopleAndPets]; $0.people.faceGroupingEnabled = true }.proposals(for: analysis)
        let p = optedIn.first { $0.id == person.id }
        #expect(p?.title == "Person 1")
        #expect(p?.requiresUserName == true)
        #expect(p?.reliability == .uncertain)
    }

    @Test func frequentPlacesAreNeverNamedAutomatically() {
        let place = FrequentPlace(id: .stable("fp", "1"), centroid: Fixture.Places.munichHome, radiusMeters: 50, assetIDs: ["1", "2", "3"], distinctDays: 6, firstDate: Fixture.date("2026-01-01"), lastDate: Fixture.date("2026-03-01"), userName: nil)
        let proposals = engine { $0.enabledAreas = [.frequentPlaces] }.proposals(for: AnalysisSnapshot(facts: [], frequentPlaces: [place]))
        #expect(proposals.first?.title == "Häufiger Ort 1")
        #expect(proposals.first?.requiresUserName == true)
        #expect(proposals.first?.isSensitive == true)
    }

    @Test func englishTitles() {
        let proposals = engine { $0.titleLanguage = .english }.proposals(for: romeAnalysis())
        #expect(proposals.contains { $0.folderPath.first == "Trips" })
        #expect(proposals.contains { $0.folderPath == ["Countries"] })
    }
}

@Suite("Search")
struct SearchTests {
    func library() -> (facts: [AssetFacts], parser: QueryParser, dog: SortlyID) {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-12-01", to: "2025-12-03", at: Fixture.Places.munichHome, perDay: 2)
        lib.daily(from: "2026-05-12", to: "2026-05-14", at: Fixture.Places.rome, perDay: 3)
        _ = lib.photo(at: Fixture.date("2026-06-01 09:00"), nil, subtypes: .screenshot)
        _ = lib.photo(at: Fixture.date("2026-06-02 09:00"), Fixture.Places.gardaLake, kind: .video)
        var facts = FixtureGeocoder.facts(for: lib.assets)
        let dogID = SortlyID.stable("group", "dog")
        // A dog in two Rome photos; one invoice screenshot from Amazon.
        facts[6].categories = ["animal.dog": .likely]
        facts[6].groupIDs = [dogID]
        facts[7].categories = ["animal.dog": .plausible]
        facts[12].document = DocumentInfo(type: .invoice, typeReliability: .likely, documentDate: nil, merchant: "Amazon", orderNumber: "302-1234567", invoiceNumber: nil, totalAmount: nil, subject: nil, keywords: [], sensitivity: .normal)
        facts[12].recognizedText = "Rechnung Amazon Bestellnummer 302-1234567"
        let groups = [ObservationGroup(id: dogID, kind: .dog, observationIDs: ["o1", "o2", "o3"], assetIDs: [facts[6].id], confirmedName: "Bello", isConfirmed: true)]
        let vocabulary = SearchVocabulary.build(facts: facts, inventory: CollectionInventory([]), groups: groups)
        return (facts, QueryParser(vocabulary: vocabulary), dogID)
    }

    let engine = SearchEngine(calendar: Fixture.calendar)

    @Test func countryAndYear() {
        let (facts, parser, _) = library()
        let (filter, tokens) = parser.parse("Alle Fotos aus Italien 2026")
        #expect(filter.countryCodes == ["IT"])
        #expect(filter.years == [2026])
        #expect(tokens.map(\.kind) == [.country, .year])
        let hits = engine.search(filter, in: facts)
        #expect(hits.count == 10) // 9 Rome photos + Garda video
    }

    @Test func cityMonthAndMediaType() {
        let (facts, parser, _) = library()
        #expect(engine.search(parser.parse("Rom Mai").filter, in: facts).count == 9)
        #expect(engine.search(parser.parse("Videos vom Gardasee").filter, in: facts).count == 1)
        #expect(engine.search(parser.parse("Screenshots").filter, in: facts).count == 1)
    }

    @Test func namedGroupAndCategory() {
        let (facts, parser, dog) = library()
        let named = parser.parse("Fotos von Bello")
        #expect(named.filter.groupIDs == [dog])
        #expect(engine.search(named.filter, in: facts).count == 1)
        let category = parser.parse("Hunde in Rom")
        #expect(category.filter.categories == ["animal.dog"])
        #expect(engine.search(category.filter, in: facts).count == 2)
        let mine = parser.parse("Fotos meines Hundes")
        #expect(mine.filter.groupIDs == [dog])
    }

    @Test func documentsMerchantsAndFields() {
        let (facts, parser, _) = library()
        let q = parser.parse("Amazon Rechnungen mit Bestellnummer")
        #expect(q.filter.merchants == ["amazon"])
        #expect(q.filter.documentTypes == [.invoice])
        #expect(q.filter.requiresOrderNumber)
        #expect(engine.search(q.filter, in: facts).count == 1)
    }

    @Test func freeTextAndLocationAndStatus() {
        let (facts, parser, _) = library()
        let text = parser.parse("302-1234567")
        #expect(engine.search(text.filter, in: facts).count == 1)
        let noLocation = parser.parse("Fotos ohne Standort")
        #expect(noLocation.filter.hasLocation == false)
        #expect(engine.search(noLocation.filter, in: facts).count == 1)
        let unorganized = parser.parse("nicht organisiert")
        let statuses = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, OverallStatus.fullyOrganized) })
            .merging([facts[0].id: OverallStatus.unorganized]) { $1 }
        #expect(engine.search(unorganized.filter, in: facts, statuses: statuses) == [facts[0].id])
    }

    @Test func unknownValuesNeverMatch() {
        var facts = library().facts
        facts[0].asset.creationDate = nil
        var filter = SearchFilter()
        filter.years = [2025]
        #expect(!engine.search(filter, in: facts).contains(facts[0].id))
        #expect(SearchFilter().isEmpty)
    }
}
