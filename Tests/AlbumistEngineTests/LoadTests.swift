import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// 20,000 and 100,000 photos over five years: everyday life, 30 trips, screenshots and existing albums.
/// Vision is faked, so this measures everything Albumist itself does (clustering, trips, places,
/// proposals, matching, database, status, atlas). Run with ALBUMIST_LOAD_TEST=1.
@Suite("Load test", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ALBUMIST_LOAD_TEST"] != nil))
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
        try await run(photos: 20_000, perDay: 8, tripPerDay: 22, albumCount: 150, cloudShare: 0,
                      limits: (first: .seconds(120), second: .seconds(15), peakMB: nil))
    }

    /// Audit 14.11.2026, 8.1: the promised 100,000 photos, 80 % of them only in iCloud
    /// ("Optimize iPhone Storage"), with time and memory limits.
    @Test func hundredThousandPhotosMostlyInICloud() async throws {
        try await run(photos: 100_000, perDay: 45, tripPerDay: 60, albumCount: 500, cloudShare: 0.8,
                      limits: (first: .seconds(300), second: .seconds(60), peakMB: 1_500)) // measured: 54 s, 12 s, 563 MB
    }

    /// Highest resident memory of this process so far (Linux), in MB.
    static func peakMemoryMB() -> Int? {
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
              let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmHWM:") }),
              let kb = Int(line.split(separator: " ").dropFirst().first ?? "") else { return nil }
        return kb / 1024
    }

    func run(photos target: Int, perDay: Int, tripPerDay: Int, albumCount: Int, cloudShare: Double,
             limits: (first: Duration, second: Duration, peakMB: Int?)) async throws {
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
        lib.daily(from: "2021-01-01", to: "2025-12-31", at: Fixture.Places.munichHome, perDay: perDay, skipping: tripRanges)
        for (start, end, place) in tripPlans {
            lib.daily(from: start, to: end, at: place, perDay: tripPerDay, hour: 9)
        }
        var shotIDs: Set<AssetID> = []
        var day = 0
        let spacing = max(1.0, 5 * 365 / Double(max(1, target - lib.assets.count)))
        while lib.assets.count < target {
            let date = Fixture.date("2021-01-01").addingTimeInterval(Double(day) * 86_400 * spacing + 72_000)
            shotIDs.insert(lib.photo(at: date, nil, subtypes: .screenshot))
            day += 1
        }
        let assets = lib.assets
        #expect(assets.count == target)

        // Existing albums with random members, the same in every run unless ALBUMIST_LOAD_SEED says
        // otherwise; the seed is in the log, so a red run can be repeated (review P5-14 c).
        print("LOAD_SEED \(Self.seed) (ALBUMIST_LOAD_SEED=\(Self.seed) repeats this library)")
        let albums = Self.albums(albumCount, of: assets, seed: Self.seed)
        // Originals only in iCloud: text from them waits for the network.
        let cloudOnly = Set(assets.enumerated().compactMap { index, asset in
            Double(index % 100) < cloudShare * 100 ? asset.id : nil
        })
        let shots = shotIDs
        let analyzer = FakeContentAnalyzer(
            cloudOnly: cloudOnly,
            labels: { asset in asset.id.rawValue.hasSuffix("7") ? [LabelScore("dog", 0.9)] : [LabelScore("food", 0.6)] },
            text: { asset in shots.contains(asset.id) ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung" : "" }
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AlbumistStore(url: dir.appendingPathComponent("albumist.sqlite"))
        let reader = InMemoryLibraryReader(assets: assets, inventory: CollectionInventory(albums))
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: try WorldMapResource.load(),
            conditions: FakeConditions(), settings: OrganizationSettings(), calendar: Fixture.calendar, time: ManualTime().source
        )

        let clock = ContinuousClock()
        if ProcessInfo.processInfo.environment["ALBUMIST_LOAD_PROFILE"] != nil {
            let probe = try AlbumistStore(url: dir.appendingPathComponent("probe.sqlite"))
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
        let firstMarks = Locked<[(String, ContinuousClock.Instant)]>([(String, ContinuousClock.Instant)]())
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
        let marks = Locked<[(String, ContinuousClock.Instant)]>([])
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
        // What refreshDerived works out off the main actor now (review of d612bc0: it was
        // main-thread work), with every photo analysed.
        let contents = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, ContentAnalysis(labels: [])) })
        var derived = DerivedLibraryStatus()
        let derivedTime = clock.measure {
            derived = DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: OrganizationSettings(), overrides: OverrideSet(),
                                                  contents: contents, managed: [], inventory: CollectionInventory(albums), scope: .all)
        }
        #expect(derived.analyzed == assets.count)
        var atlas = TravelAtlas()
        let atlasTime = clock.measure { atlas = TravelAtlas.compute(facts: facts) }
        let overlapTime = clock.measure { _ = AlbumOverlapAnalyzer().suggestions(in: CollectionInventory(albums)) }
        let searchTime = clock.measure {
            _ = SearchIndex(facts: facts, inventory: CollectionInventory(albums)).search("Rom 2023")
        }

        func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        print("LOAD_TIMING photos \(assets.count) proposals \(snapshot?.proposals.count ?? 0) countries \(atlas.countryCodes.count) trips \(atlas.tripCount) states \(states.count)")
        print("LOAD_TIMING first-run \(ms(full)) ms | second-run \(ms(again)) ms | facts \(ms(factsTime)) ms | status \(ms(statusTime)) ms | derived (off main) \(ms(derivedTime)) ms | atlas \(ms(atlasTime)) ms | overlap \(ms(overlapTime)) ms | search \(ms(searchTime)) ms")
        let peak = Self.peakMemoryMB()
        print("LOAD_MEMORY photos \(assets.count) peak \(peak.map { "\($0) MB" } ?? "unknown")")
        #expect(atlas.tripCount >= 25)
        #expect(full < limits.first)
        #expect(again < limits.second) // 20,000 photos: was 44 s before the grid DBSCAN
        if let limit = limits.peakMB, let peak { #expect(peak < limit) }
    }

    /// The seed of the random albums: ALBUMIST_LOAD_SEED, else a fixed one.
    static let seed = ProcessInfo.processInfo.environment["ALBUMIST_LOAD_SEED"].flatMap(UInt64.init) ?? 20_261_118

    /// `count` existing albums, each a random run of 20 to 400 of `assets`, the same for the same seed.
    static func albums(_ count: Int, of assets: [AssetSnapshot], seed: UInt64) -> [CollectionSnapshot] {
        var rng = RandomLibraryTests.Seeded(state: seed &* 0x2545F4914F6CDD1D)
        var albums: [CollectionSnapshot] = []
        for i in 0..<count {
            let start = Int.random(in: 0..<(assets.count - 400), using: &rng)
            let members = Set(assets[start..<(start + Int.random(in: 20...400, using: &rng))].map(\.id))
            albums.append(CollectionSnapshot(id: CollectionID("album-\(i)"), title: "Album \(i)", assetIDs: members))
        }
        return albums
    }

    // MARK: The image step's first count (stress run 44116350940)

    /// The stress run's library (`UITestLargeLibrary.item`): 25 photos per trip over five days
    /// in one of 40 cities, every fifth trip at home in Munich, all with a location.
    static func stressLibrary(_ count: Int) -> [AssetSnapshot] {
        let cities: [(Double, Double)] = [
            (48.8566, 2.3522), (41.3874, 2.1686), (40.7128, -74.0060), (48.2082, 16.3738), (62.1008, 7.2059),
            (43.5081, 16.4402), (38.7223, -9.1393), (43.7696, 11.2558), (55.6761, 12.5683), (64.1466, -21.9426),
            (41.8902, 12.4922), (35.0116, 135.7681), (51.5072, -0.1276), (52.5200, 13.4050), (45.4408, 12.3155),
            (37.9838, 23.7275), (50.0755, 14.4378), (47.4979, 19.0402), (59.3293, 18.0686), (60.1699, 24.9384),
            (53.3498, -6.2603), (55.9533, -3.1883), (40.4168, -3.7038), (37.3891, -5.9845), (43.2965, 5.3698),
            (45.7640, 4.8357), (46.2044, 6.1432), (47.3769, 8.5417), (50.8503, 4.3517), (52.3676, 4.9041),
            (34.0522, -118.2437), (37.7749, -122.4194), (25.7617, -80.1918), (19.4326, -99.1332), (-33.8688, 151.2093),
            (-37.8136, 144.9631), (1.3521, 103.8198), (13.7563, 100.5018), (22.3193, 114.1694), (35.6762, 139.6503),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return (0..<count).map { index in
            let trip = index / 25
            let spot = trip % 5 == 4 ? (48.1374, 11.5755) : cities[trip % cities.count]
            let start = calendar.date(from: DateComponents(year: 2010 + trip % 15, month: 1 + (trip * 7) % 12, day: 1 + (trip * 3) % 25,
                                                           hour: 9 + index % 10, minute: (index * 13) % 60))!
            let date = calendar.date(byAdding: .day, value: (index % 25) / 5, to: start)!
            let dLat = Double((index * 7_919) % 400) / 10_000 - 0.02, dLon = Double((index * 104_729) % 400) / 10_000 - 0.02
            return AssetSnapshot(id: AssetID(String(format: "large-%06d", index)), kind: .image, creationDate: date,
                                 location: GeoCoordinate(latitude: spot.0 + dLat, longitude: spot.1 + dLon),
                                 pixelWidth: 192, pixelHeight: 144, originalFilename: "IMG_\(20_000 + index).JPG")
        }
    }

    /// Half a second per photo (the simulator takes about 2 s; the time per photo only sets the
    /// rhythm of the counts here).
    final class TimedAnalyzer: ContentAnalyzing, @unchecked Sendable {
        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            try await Task.sleep(for: .milliseconds(500))
            return ContentAnalysis(labels: [LabelScore("outdoor", 0.8)], source: .localPreview)
        }
        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            TextAnalysis(text: "", source: .original)
        }
    }

    struct OfflineGeocoder: ReverseGeocoding {
        func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? { throw GeocodingError.offline }
    }

    /// The stress run's 50,000 photos, offline, with the overview's refresh after the early
    /// suggestions (as `AppModel.refreshDerived` does it). The early suggestions take about
    /// 2.8 s here and stood between "0 von 50.000" and the first photo until now (measured
    /// before the change: first count 4.1 s after the step began, 1.0 s over 500 photos).
    /// Now the first count comes after the first photos at any size, and the count keeps its
    /// rhythm while the early suggestions are made.
    @Test func stressLibraryImageStepCountsAtOnce() async throws {
        let assets = Self.stressLibrary(50_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AlbumistStore(url: dir.appendingPathComponent("albumist.sqlite"))
        let pipeline = AnalysisPipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: TimedAnalyzer(),
                                        geocoder: OfflineGeocoder(), map: try WorldMapResource.load(), conditions: FakeConditions(),
                                        settings: OrganizationSettings(), foregroundOnlineBudget: 60)
        let control = AnalysisRunControl()
        let reports = Locked<[(at: ContinuousClock.Instant, progress: AnalysisPipeline.Progress)]>([])
        let refreshed = Locked<ContinuousClock.Instant?>(nil)
        let report = try await pipeline.run(control: control) { progress in
            guard progress.stage == .content else { return }
            let count = reports.withLock { $0.append((.now, progress)); return $0.count }
            if progress.earlyProposals {
                Task {
                    _ = try? await pipeline.refreshMatchesIfOutdated()
                    let facts = (try? await pipeline.currentFacts()) ?? []
                    let contents = (try? await store.results(ContentAnalysis.self, kind: "content")) ?? [:]
                    let snapshot = try? await pipeline.latestProposals()
                    _ = await Task.detached {
                        DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: OrganizationSettings(), overrides: OverrideSet(),
                                                    contents: contents, managed: [], inventory: CollectionInventory(), scope: .all)
                    }.value
                    refreshed.withLock { $0 = .now }
                }
            }
            // A while after the early suggestions and the refresh: enough to see the rhythm (at
            // the latest after 60 reports, so a refresh that never ends does not run all photos).
            if count >= 12, refreshed.withLock({ $0 }) != nil || count >= 60 { control.pause() }
        }
        #expect(report.pausedBecause == .userPaused)
        #expect(report.earlyProposals)
        #expect(refreshed.withLock { $0 } != nil, "the overview's refresh after the early suggestions did not end")
        let seen = reports.withLock { $0 }
        func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        let start = try #require(seen.first)
        print("LOAD_IMAGE_STEP " + seen.map { "\(ms($0.at - start.at)) ms \($0.progress.completed)\($0.progress.earlyProposals ? " early" : "")" }.joined(separator: " | "))
        let firstCount = try #require(seen.first { $0.progress.completed > start.progress.completed })
        let early = try #require(seen.first { $0.progress.earlyProposals })
        #expect(early.at - start.at < .seconds(5), "early suggestions \(ms(early.at - start.at)) ms after the step began")
        #expect(firstCount.at - start.at < .seconds(2), "first count \(ms(firstCount.at - start.at)) ms after the step began")
        let gaps = zip(seen, seen.dropFirst()).map { $1.at - $0.at }
        #expect(gaps.allSatisfy { $0 < .seconds(3) }, "longest gap \(ms(gaps.max() ?? .zero)) ms")
    }

    /// Review of 9ff0dfc: Pause while the early suggestions are made (2.8 s over these 50,000
    /// photos) waited for them: 1.6 s at the first counted photo. Pause takes effect within a
    /// second, at the report that starts the image step and at the first counted photo; the
    /// early suggestions not done by then are dropped and made again by the next run.
    @Test(arguments: [false, true]) func stressLibraryPauseDuringTheEarlySuggestions(atFirstCount: Bool) async throws {
        let assets = Self.stressLibrary(50_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AlbumistStore(url: dir.appendingPathComponent("albumist.sqlite"))
        let pipeline = AnalysisPipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: TimedAnalyzer(),
                                        geocoder: OfflineGeocoder(), map: try WorldMapResource.load(), conditions: FakeConditions(),
                                        settings: OrganizationSettings(), foregroundOnlineBudget: 60)
        let control = AnalysisRunControl()
        let pausedAt = Locked<(at: ContinuousClock.Instant, completed: Int)?>(nil)
        let start = Locked<Int?>(nil)
        let report = try await pipeline.run(control: control) { progress in
            guard progress.stage == .content, pausedAt.withLock({ $0 }) == nil else { return }
            let first = start.withLock { s -> Int in
                if s == nil { s = progress.completed }
                return s!
            }
            if !atFirstCount || progress.completed > first {
                pausedAt.withLock { $0 = (.now, progress.completed) }
                control.pause()
            }
        }
        let ended = ContinuousClock.now
        let paused = try #require(pausedAt.withLock { $0 })
        let took = ended - paused.at
        print("LOAD_PAUSE_EARLY \(atFirstCount ? "first count" : "step start") at \(paused.completed): \(took), early \(report.earlyProposals)")
        #expect(report.pausedBecause == .userPaused)
        #expect(took < .seconds(1), "Pause took \(took)")
        await pipeline.waitForEarlyLeftBehind()
        if !report.earlyProposals { #expect(try await pipeline.latestProposals() == nil) }
    }
}

/// Review P5-14 (c): the load test's library is the same in every run, so a red run can be
/// repeated with the same albums. Not gated by ALBUMIST_LOAD_TEST: it builds no store and takes
/// milliseconds.
@Suite("Load test library")
struct LoadTestLibraryTests {
    @Test func theAlbumsAreTheSameInEveryRun() {
        let assets = LoadTests.stressLibrary(2_000)
        // An album is a run of photos: its first photo and its size say which.
        func runs(_ albums: [CollectionSnapshot]) -> [String] {
            albums.map { "\($0.assetIDs.map(\.rawValue).min() ?? "-") +\($0.assetIDs.count)" }
        }
        let first = runs(LoadTests.albums(30, of: assets, seed: LoadTests.seed))
        #expect(first == runs(LoadTests.albums(30, of: assets, seed: LoadTests.seed)))
        // Another seed, other albums: the seed decides.
        #expect(first != runs(LoadTests.albums(30, of: assets, seed: LoadTests.seed + 1)))
    }
}
