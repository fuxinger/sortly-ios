import Foundation
import Synchronization
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
        if ProcessInfo.processInfo.environment["SORTLY_LOAD_PROFILE"] != nil {
            let probe = try SortlyStore(url: dir.appendingPathComponent("probe.sqlite"))
            let t1 = try await clock.measure { _ = try await probe.upsertAssets(assets) }
            let t2 = try await clock.measure { _ = try await probe.upsertAssets(assets) }
            let t3 = try await clock.measure { _ = try await probe.removeAssets(notIn: Set(assets.map(\.id))) }
            let t4 = try await clock.measure { try await probe.saveInventory(CollectionInventory(albums)) }
            let t5 = try await clock.measure { try await probe.saveInventory(CollectionInventory(albums)) }
            let t6 = try await clock.measure { _ = try await probe.allAssets() }
            let all = try await probe.allAssets()
            let t7 = clock.measure { _ = TripDetector(configuration: OrganizationSettings().trips.advanced, calendar: Fixture.calendar).detect(in: all, corrections: TripCorrections()) }
            let t8 = clock.measure { _ = FrequentPlaceDetector(configuration: OrganizationSettings().frequentPlaces.advanced, calendar: Fixture.calendar).detect(in: all) }
            print("LOAD_PROFILE trips \(t7) frequent \(t8)")
            print("LOAD_PROFILE upsert1 \(t1) upsert2 \(t2) remove \(t3) inventory1 \(t4) inventory2 \(t5) allAssets \(t6)")
        }
        var report: AnalysisPipeline.Report?
        let firstMarks = Mutex<[(String, ContinuousClock.Instant)]>([(String, ContinuousClock.Instant)]())
        let started = ContinuousClock.now
        let full = try await clock.measure {
            report = try await pipeline.run { progress in
                let now = ContinuousClock.now
                firstMarks.withLock { m in
                    if m.last?.0 != "\(progress.stage)" { m.append(("\(progress.stage)", now)) } else { m[m.count - 1].1 = now }
                }
            }
        }
        let fm = firstMarks.withLock { $0 }
        print("LOAD_STAGES first run (end of stage): " + fm.map { "\($0.0)@\(($0.1 - started).components.seconds * 1000 + ($0.1 - started).components.attoseconds / 1_000_000_000_000_000)ms" }.joined(separator: " "))
        #expect(report?.isComplete == true)
        let marks = Mutex<[(String, ContinuousClock.Instant)]>([])
        let again = try await clock.measure {
            _ = try await pipeline.run { progress in
                let now = ContinuousClock.now
                marks.withLock { m in
                    if m.last?.0 != "\(progress.stage)" { m.append(("\(progress.stage)", now)) }
                }
            }
        }
        let stageMarks = marks.withLock { $0 }
        print("LOAD_STAGES second run: " + stageMarks.map { "\($0.0)@\(Int((($0.1 - stageMarks[0].1).components.attoseconds / 1_000_000_000_000_000) + ($0.1 - stageMarks[0].1).components.seconds * 1000))ms" }.joined(separator: " "))
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
        #expect(full < .seconds(120))
        #expect(again < .seconds(15)) // was 44 s before the grid DBSCAN
    }
}
