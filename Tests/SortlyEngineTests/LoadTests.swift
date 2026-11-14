import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// 20,000 photos over five years: everyday life, 30 trips, screenshots and 150 existing albums.
/// Vision is faked, so this measures everything SORTLY itself does (clustering, trips, places,
/// proposals, matching, database, status, atlas). Run with SORTLY_LOAD_TEST=1.
@Suite("Load test", .enabled(if: ProcessInfo.processInfo.environment["SORTLY_LOAD_TEST"] != nil))
struct LoadTests {
    static let destinations: [GeoCoordinate] = [
        Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake,
        Fixture.Places.sydney, GeoCoordinate(latitude: 48.8566, longitude: 2.3522), // Paris
        GeoCoordinate(latitude: 41.3874, longitude: 2.1686), // Barcelona
        GeoCoordinate(latitude: 38.7223, longitude: -9.1393), // Lisbon
        GeoCoordinate(latitude: 40.7128, longitude: -74.0060), // New York
        GeoCoordinate(latitude: 35.6762, longitude: 139.6503), // Tokyo
        GeoCoordinate(latitude: 64.1466, longitude: -21.9426), // Reykjavik
        GeoCoordinate(latitude: 37.9838, longitude: 23.7275), // Athens
    ]

    @Test func twentyThousandPhotos() async throws {
        var lib = LibraryBuilder()
        var tripRanges: [(String, String)] = []
        var tripPlans: [(String, String, GeoCoordinate)] = []
        for year in 2021...2025 {
            for (i, month) in [3, 5, 7, 8, 10, 12].enumerated() {
                let start = String(format: "%d-%02d-10", year, month)
                let end = String(format: "%d-%02d-15", year, month)
                tripRanges.append((start, end))
                tripPlans.append((start, end, Self.destinations[(year * 7 + i) % Self.destinations.count]))
            }
        }
        lib.daily(from: "2021-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: 8, skipping: tripRanges)
        for (start, end, place) in tripPlans {
            lib.daily(from: start, to: end, at: place, perDay: 22, hour: 9)
        }
        var shotIDs: Set<AssetID> = []
        var day = 0
        while lib.assets.count < 20_000 {
            let date = Fixture.date("2021-01-01").addingTimeInterval(Double(day) * 86_400 * 1.9 + 72_000)
            shotIDs.insert(lib.photo(at: date, nil, subtypes: .screenshot))
            day += 1
        }
        let assets = lib.assets
        #expect(assets.count == 20_000)

        // 150 existing albums with random members.
        var rng = SystemRandomNumberGenerator()
        var albums: [CollectionSnapshot] = []
        for i in 0..<150 {
            let start = Int.random(in: 0..<(assets.count - 400), using: &rng)
            let members = Set(assets[start..<(start + Int.random(in: 20...400, using: &rng))].map(\.id))
            albums.append(CollectionSnapshot(id: CollectionID("album-\(i)"), title: "Album \(i)", assetIDs: members))
        }
        let shots = shotIDs
        let analyzer = FakeContentAnalyzer(
            labels: { asset in asset.id.rawValue.hasSuffix("7") ? [LabelScore("dog", 0.9)] : [LabelScore("food", 0.6)] },
            text: { asset in shots.contains(asset.id) ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung" : "" }
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sortly-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SortlyStore(url: dir.appendingPathComponent("sortly.sqlite"))
        let reader = InMemoryLibraryReader(assets: assets, inventory: CollectionInventory(albums))
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: try WorldMapResource.load(),
            conditions: FakeConditions(), settings: OrganizationSettings(), calendar: Fixture.calendar, time: ManualTime().source
        )

        let clock = ContinuousClock()
        var report: AnalysisPipeline.Report?
        let full = try await clock.measure { report = try await pipeline.run() }
        #expect(report?.isComplete == true)
        let again = try await clock.measure { _ = try await pipeline.run() }
        var facts: [AssetFacts] = []
        let factsTime = try await clock.measure { facts = try await pipeline.currentFacts() }
        let snapshot = try await pipeline.latestProposals()
        var states: [AssetID: AssetOrganizationState] = [:]
        let statusTime = clock.measure {
            states = LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: OrganizationSettings(), contentAnalyzed: Set(assets.map(\.id)))
        }
        var atlas = TravelAtlas()
        let atlasTime = clock.measure { atlas = TravelAtlas.compute(facts: facts) }
        let overlapTime = clock.measure { _ = AlbumOverlapAnalyzer().suggestions(in: CollectionInventory(albums)) }
        let searchTime = clock.measure {
            let parser = QueryParser(vocabulary: SearchVocabulary.build(facts: facts, inventory: CollectionInventory(albums), groups: []))
            _ = SearchEngine().search(parser.parse("Rom 2023").filter, in: facts, statuses: [:], textHits: nil)
        }

        func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        print("LOAD_TIMING photos \(assets.count) proposals \(snapshot?.proposals.count ?? 0) countries \(atlas.countryCodes.count) trips \(atlas.tripCount) states \(states.count)")
        print("LOAD_TIMING first-run \(ms(full)) ms | second-run \(ms(again)) ms | facts \(ms(factsTime)) ms | status \(ms(statusTime)) ms | atlas \(ms(atlasTime)) ms | overlap \(ms(overlapTime)) ms | search \(ms(searchTime)) ms")
        #expect(atlas.tripCount >= 25)
        #expect(full < .seconds(300))
        #expect(again < .seconds(30))
    }
}
