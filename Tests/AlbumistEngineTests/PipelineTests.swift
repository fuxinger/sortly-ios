import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

@Suite("Analysis pipeline")
struct PipelineTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Setup {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var analyzer: FakeContentAnalyzer
        var geocoder: FakeGeocoder
        var conditions: FakeConditions
        var pipeline: AnalysisPipeline
        var ids: (rome: [AssetID], screenshots: [AssetID], dogs: [AssetID])
    }

    /// Munich everyday life, a Rome trip with a dog, and screenshots (one only in iCloud).
    func setup(settings configure: (inout OrganizationSettings) -> Void = { _ in }, cloudOnly: Bool = true, pauseAfter: Int? = nil, batchSize: Int = 10) throws -> Setup {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        var screenshots: [AssetID] = []
        for day in 1...5 {
            screenshots.append(lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot))
        }
        // A dog in Rome and at home: a theme seen on one trip only would be that trip's album.
        let dogs = Array(rome.prefix(10)) + Array(home.suffix(10))
        let dogSet = Set(dogs)
        let shots = Set(screenshots)
        let analyzer = FakeContentAnalyzer(
            cloudOnly: cloudOnly ? [screenshots[0]] : [],
            labels: { asset in dogSet.contains(asset.id) ? [LabelScore("dog", 0.92)] : [] },
            text: { asset in shots.contains(asset.id) ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung Sendungsverfolgung" : "" }
        )
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.imageCategories.minPhotos = 10
        configure(&settings)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let geocoder = FakeGeocoder()
        let conditions = FakeConditions(pauseAfterChecks: pauseAfter)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map,
            conditions: conditions, settings: settings, calendar: Fixture.calendar, time: ManualTime().source, batchSize: batchSize,
            // A stop in the image step waits for the early set (see ImageStepStartTests for the
            // real half second), so tests that pause there do not depend on the machine's load.
            earlyGraceOnStop: .seconds(60)
        )
        return Setup(store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, conditions: conditions, pipeline: pipeline, ids: (rome, screenshots, dogs))
    }

    @Test func fullRunProducesProposalsForEveryArea() async throws {
        let s = try setup()
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(report.contentAnalyzed == 210)
        #expect(report.textRecognized == 4)
        #expect(report.textWaitingForOriginal == 1) // iCloud-only, network not allowed
        let snapshot = try #require(try await s.pipeline.latestProposals())
        let titles = Set(snapshot.proposals.map(\.title))
        #expect(titles.contains("Rom, Mai 2026"))
        // Italy was seen on this one trip only: the trip is its album.
        #expect(!titles.contains("Italien"))
        #expect(titles.contains("Hunde"))
        #expect(titles.contains("Bestellungen"))
        #expect(snapshot.matches.count == snapshot.proposals.count)
        // Only text-worthy images were read (speed-up 5).
        #expect(s.analyzer.counts.withLock { $0.text } == 5)
    }

    /// Returns no albums on the first read and the Rome album afterwards, like a plan that
    /// was applied while the analysis was running.
    actor AlbumAppearsDuringRun: PhotoLibraryReading {
        let assets: [AssetSnapshot]
        let later: CollectionInventory
        var reads = 0
        init(assets: [AssetSnapshot], later: CollectionInventory) { self.assets = assets; self.later = later }
        func access() async -> LibraryAccess { .full }
        func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] { assets }
        func currentInventory() async throws -> CollectionInventory {
            reads += 1
            return reads == 1 ? CollectionInventory() : later
        }
    }

    @Test func albumsCreatedDuringTheRunAreMatched() async throws {
        let s = try setup()
        let assets = try await s.reader.fetchAssets(includeHidden: false, knownDetails: [:])
        let album = CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(s.ids.rome))
        let reader = AlbumAppearsDuringRun(assets: assets, later: CollectionInventory([album]))
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: s.store, reader: reader, analyzer: s.analyzer, geocoder: s.geocoder, map: Self.map,
            conditions: s.conditions, settings: settings, calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        let snapshot = try #require(try await pipeline.latestProposals())
        let trip = try #require(snapshot.proposals.first { $0.title.hasPrefix("Rom,") })
        #expect(snapshot.matches[trip.id]?.best?.albumID == "rom")
        #expect(try await s.store.loadInventory()["rom"] != nil)
    }

    /// Reads its photos in parts and says so after each, like PhotoKit while it reads file
    /// details on a first run.
    actor ReaderInParts: PhotoLibraryReading {
        let assets: [AssetSnapshot]
        init(assets: [AssetSnapshot]) { self.assets = assets }
        func access() async -> LibraryAccess { .full }
        func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] { assets }
        func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                         progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> [AssetSnapshot] {
            for read in stride(from: 50, to: assets.count, by: 50) {
                // Like PhotoKitLibrary: a `false` ends the read with what was read until then.
                if !progress(read, assets.count) { throw LibraryReadPaused(read: Array(assets.prefix(read))) }
                if read == pauseAt { onPauseAt?() }
            }
            return assets
        }
        var pauseAt: Int?
        var onPauseAt: (@Sendable () -> Void)?
        func pause(at read: Int, _ action: @escaping @Sendable () -> Void) { pauseAt = read; onPauseAt = action }
        func currentInventory() async throws -> CollectionInventory { CollectionInventory() }
    }

    /// Stress run 43833158673: reading 50,000 photos took minutes with nothing moving on the
    /// card. The reader's progress reaches the card as the library step's count, rising, and
    /// the step ends with every photo counted.
    @Test func readingTheLibraryIsCountedAsItGoes() async throws {
        let s = try setup()
        let assets = try await s.reader.fetchAssets(includeHidden: false, knownDetails: [:])
        let pipeline = AnalysisPipeline(
            store: s.store, reader: ReaderInParts(assets: assets), analyzer: s.analyzer, geocoder: s.geocoder, map: Self.map,
            conditions: s.conditions, settings: OrganizationSettings(), calendar: Fixture.calendar, time: ManualTime().source
        )
        let seen = Locked<[Int]>([])
        _ = try await pipeline.run(onProgress: { p in
            if p.stage == .inventory { seen.withLock { $0.append(p.completed) } }
        })
        let counts = seen.withLock { $0 }
        #expect(counts.count >= assets.count / 50, "only \(counts.count) reports while reading")
        #expect(counts == counts.sorted())
        #expect(counts.last == assets.count)
    }

    /// Review of d612bc0: Pause during the library read waited for the whole read (minutes on a
    /// first read of 50,000 photos). It ends the read at the next report; the run ends paused,
    /// and nothing of the stopped read is stored (no photo is counted as deleted).
    @Test func pauseStopsTheLibraryRead() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        let stored = try await s.store.allAssets().count
        let assets = try await s.reader.fetchAssets(includeHidden: false, knownDetails: [:])
        let reader = ReaderInParts(assets: Array(assets.prefix(assets.count / 2)))
        let control = AnalysisRunControl()
        await reader.pause(at: 50) { control.pause() }
        let pipeline = AnalysisPipeline(
            store: s.store, reader: reader, analyzer: s.analyzer, geocoder: s.geocoder, map: Self.map,
            conditions: s.conditions, settings: OrganizationSettings(), calendar: Fixture.calendar, time: ManualTime().source
        )
        let reads = Locked<[Int]>([])
        let report = try await pipeline.run(control: control, onProgress: { p in
            if p.stage == .inventory { reads.withLock { $0.append(p.completed) } }
        })
        #expect(report.pausedBecause == .userPaused)
        #expect(reads.withLock { $0.max() ?? 0 } <= 100, "read on after Pause: \(reads.withLock { $0 })")
        // Half the library was "read" before the stop; none of the other half is gone.
        #expect(try await s.store.allAssets().count == stored)
    }

    /// Review of 9f0bc40 (D): a paused read threw away everything it had read, so a user who
    /// paused again and again never got further. The file details read until the Pause are
    /// kept (the next read skips them); nothing else changes.
    @Test func pausedReadKeepsWhatItRead() async throws {
        let s = try setup()
        let assets = try await s.reader.fetchAssets(includeHidden: false, knownDetails: [:]).map { a in
            var a = a
            a.uniformTypeIdentifier = "public.jpeg"
            return a
        }
        let reader = ReaderInParts(assets: assets)
        let control = AnalysisRunControl()
        await reader.pause(at: 100) { control.pause() }
        let pipeline = AnalysisPipeline(
            store: s.store, reader: reader, analyzer: s.analyzer, geocoder: s.geocoder, map: Self.map,
            conditions: s.conditions, settings: OrganizationSettings(), calendar: Fixture.calendar, time: ManualTime().source
        )
        let report = try await pipeline.run(control: control)
        #expect(report.pausedBecause == .userPaused)
        let known = try await s.store.assetsWithFileDetails()
        #expect(known.count == 150, "kept \(known.count) of the 150 read")
        #expect(Set(assets.prefix(150).map(\.id)) == Set(known.keys))
        #expect(try await s.store.allAssets().count == 150)
    }

    @Test func secondRunIsIncremental() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        let contentCalls = s.analyzer.counts.withLock { $0.content }
        let geocoderCalls = s.geocoder.calls.count
        let again = try await s.pipeline.run()
        #expect(again.isComplete)
        #expect(again.newOrChanged == 0)
        #expect(again.contentAnalyzed == 0)
        #expect(s.analyzer.counts.withLock { $0.content } == contentCalls)
        #expect(s.geocoder.calls.count == geocoderCalls)
    }

    @Test func pauseAndResumeLosesNothing() async throws {
        let s = try setup(pauseAfter: 4, batchSize: 10)
        let first = try await s.pipeline.run()
        #expect(first.pausedBecause == .thermal)
        #expect(!first.isComplete)
        s.conditions.set(pauseAfterChecks: nil)
        let second = try await s.pipeline.run()
        #expect(second.isComplete)
        #expect(first.contentAnalyzed + second.contentAnalyzed == 210)
        #expect(s.analyzer.counts.withLock { $0.content } == 210) // nothing analyzed twice
    }

    @Test func tripsAreOfferedBeforeTheImageAnalysis() async throws {
        let s = try setup(pauseAfter: 4, batchSize: 10)
        let first = try await s.pipeline.run()
        #expect(first.pausedBecause != nil)
        #expect(first.earlyProposals)
        let early = try #require(try await s.pipeline.latestProposals())
        #expect(early.proposals.contains { $0.title == "Rom, Mai 2026" })
        #expect(!early.proposals.contains { $0.title == "Hunde" }) // needs the image analysis
        s.conditions.set(pauseAfterChecks: nil)
        let second = try await s.pipeline.run()
        #expect(!second.earlyProposals)
        let full = try #require(try await s.pipeline.latestProposals())
        #expect(full.proposals.contains { $0.title == "Hunde" })
        // Same id before and after, so a decision made early still applies.
        let earlyTrip = early.proposals.first { $0.title.hasPrefix("Rom,") }?.id
        #expect(earlyTrip != nil && full.proposals.contains { $0.id == earlyTrip })
    }

    @Test func overallProgressNeverGoesBack() async throws {
        let s = try setup()
        let seen = Locked<[Double]>([])
        let report = try await s.pipeline.run { progress in
            let value = AnalysisPipeline.Progress.overall(stage: progress.stage, completed: progress.completed, total: progress.total)
            seen.withLock { $0.append(value) }
        }
        #expect(report.isComplete)
        let values = seen.withLock { $0 }
        #expect(!values.isEmpty)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(abs(AnalysisPipeline.Stage.allCases.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(AnalysisPipeline.Progress.overall(stage: .proposals, completed: 1, total: 1) > 0.999)
        #expect(AnalysisPipeline.Stage.content.number == 4)
    }

    /// Pause asked for once photos are counted. Asked at the report that starts the image
    /// step, it raced the first batch: run alone, this test failed on the code before the
    /// early suggestions moved beside the photos too (the run stopped before any photo).
    @Test func userPauseStopsAtBatchBoundary() async throws {
        let s = try setup()
        let pipeline = s.pipeline
        let report = try await pipeline.run { progress in
            if progress.stage == .content, progress.completed > 0 { Task { await pipeline.pause() } }
        }
        #expect(report.contentAnalyzed > 0)
        #expect(report.pausedBecause == .userPaused || report.isComplete) // the pause races the last batch
    }

    @Test func refinementReadsICloudOriginalsOnWiFiWithConsent() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        var settings = await s.pipeline.settings
        settings.privacy.allowNetworkForAnalysis = true
        await s.pipeline.update(settings: settings)
        let refined = try await s.pipeline.run(mode: .refinement)
        #expect(refined.textRecognized == 1)
        #expect(refined.textWaitingForOriginal == 0)
    }

    @Test func noICloudDownloadsOnCellularByDefault() async throws {
        let s = try setup { $0.privacy.allowNetworkForAnalysis = true }
        s.conditions.set(pauseAfterChecks: nil, wifi: false)
        let report = try await s.pipeline.run()
        #expect(report.textWaitingForOriginal == 1)
    }

    @Test func refinementUsesFinerTownCells() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        let before = s.geocoder.calls.count
        let places = try await s.store.places()
        #expect(places.values.contains { $0.precisionMeters == 5_000 })
        _ = try await s.pipeline.run(mode: .refinement)
        #expect(s.geocoder.calls.count > before)
        let refined = try await s.store.places()
        #expect(refined.values.allSatisfy { ($0.precisionMeters ?? 0) <= 1_000 })
    }

    @Test func deniedAccessStopsImmediately() async throws {
        let s = try setup()
        await s.reader.set(access: .denied)
        let report = try await s.pipeline.run()
        #expect(report.pausedBecause == .accessRevoked)
        #expect(try await s.store.assetCount() == 0)
    }

    @Test func removedAssetsDisappear() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        let remaining = await s.reader.assets.filter { !s.ids.screenshots.contains($0.id) }
        await s.reader.set(assets: remaining)
        let report = try await s.pipeline.run()
        #expect(report.removed == 5)
        let titles = try #require(try await s.pipeline.latestProposals()).proposals.map(\.title)
        #expect(!titles.contains("Bestellungen"))
    }

    @Test func trialScopeLimitsProposalsToOneYear() async throws {
        let s = try setup()
        _ = try await s.pipeline.run(scope: .year(2025))
        let empty = try #require(try await s.pipeline.latestProposals())
        #expect(empty.scope == .year(2025))
        #expect(empty.proposals.isEmpty)
        _ = try await s.pipeline.run(scope: .year(2026))
        #expect(try #require(try await s.pipeline.latestProposals()).proposals.isEmpty == false)
    }

    @Test func facesAreNeverRequestedWithoutOptIn() async throws {
        let s = try setup { $0.enabledAreas.insert(.peopleAndPets) }
        _ = try await s.pipeline.run()
        let facts = try await s.pipeline.currentFacts()
        #expect(facts.count == 210)
        #expect(facts.allSatisfy { $0.groupIDs.isEmpty })
    }
}
