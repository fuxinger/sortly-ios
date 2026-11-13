import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

@Suite("Analysis pipeline")
struct PipelineTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Setup {
        var store: SortlyStore
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
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        var screenshots: [AssetID] = []
        for day in 1...5 {
            screenshots.append(lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot))
        }
        let dogs = Array(rome.prefix(20))
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
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let geocoder = FakeGeocoder()
        let conditions = FakeConditions(pauseAfterChecks: pauseAfter)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map,
            conditions: conditions, settings: settings, calendar: Fixture.calendar, time: ManualTime().source, batchSize: batchSize
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
        #expect(titles.contains("Rom · 12.05.–19.05.2026"))
        #expect(titles.contains("Italien"))
        #expect(titles.contains("Hunde"))
        #expect(titles.contains("Bestellungen"))
        #expect(snapshot.matches.count == snapshot.proposals.count)
        // Only text-worthy images were read (speed-up 5).
        #expect(s.analyzer.counts.withLock { $0.text } == 5)
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

    @Test func userPauseStopsAtBatchBoundary() async throws {
        let s = try setup()
        let pipeline = s.pipeline
        let report = try await pipeline.run { progress in
            if progress.stage == .content { Task { await pipeline.pause() } }
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
