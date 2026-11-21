import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Findings of the first test on a real iPhone (Fuchs, 15.11.): the analysis ended for good
/// when the phone got warm, every new run counted from zero again, and "nur 2026" at the
/// start was forgotten after the first run.
@Suite("First device test")
struct FirstDeviceTestTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Setup {
        var store: AlbumistStore
        var analyzer: FakeContentAnalyzer
        var conditions: FakeConditions
        var time: ManualTime
        var pipeline: AnalysisPipeline
        var year2025: [AssetID]
        var year2026: [AssetID]
    }

    /// 2025: everyday Munich and a Rome trip. 2026: everyday Munich and a Lake Garda trip.
    func setup(batchSize: Int = 10) throws -> Setup {
        var lib = LibraryBuilder()
        var old = lib.daily(from: "2025-03-01", to: "2025-04-30", at: Fixture.Places.munichHome, perDay: 1)
        old += lib.daily(from: "2025-05-12", to: "2025-05-17", at: Fixture.Places.rome, perDay: 4, hour: 10)
        var new = lib.daily(from: "2026-03-01", to: "2026-04-30", at: Fixture.Places.munichHome, perDay: 1)
        new += lib.daily(from: "2026-05-12", to: "2026-05-17", at: Fixture.Places.gardaLake, perDay: 4, hour: 10)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try AlbumistStore(url: nil)
        let analyzer = FakeContentAnalyzer(cloudOnly: [], labels: { _ in [] }, text: { _ in "" })
        let conditions = FakeConditions()
        let time = ManualTime()
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer, geocoder: FakeGeocoder(),
            map: Self.map, conditions: conditions, settings: settings, calendar: Fixture.calendar, time: time.source, batchSize: batchSize
        )
        return Setup(store: store, analyzer: analyzer, conditions: conditions, time: time, pipeline: pipeline, year2025: old, year2026: new)
    }

    // MARK: Heat slows down or waits, it does not end the run

    @Test func hotDeviceWaitsAndGoesOnByItself() async throws {
        let s = try setup()
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 30) + Array(repeating: .wait(.thermal), count: 5) + [.normal] }
        let waits = Locked<[PauseReason?]>([])
        let report = try await s.pipeline.run(onWaiting: { reason in waits.withLock { $0.append(reason) } })
        #expect(report.isComplete)
        #expect(report.pausedBecause == nil)
        #expect(report.contentAnalyzed == s.year2025.count + s.year2026.count)
        // Told once that it waits, once that it goes on.
        #expect(waits.withLock { $0 } == [.thermal, nil])
        // It waited on the clock instead of ending: 5 checks, each followed by a break.
        #expect(s.time.now.withLock { $0 } >= AnalysisPipeline.waitCheck * 5)
    }

    @Test func warmDeviceTakesBreaksButFinishes() async throws {
        let s = try setup()
        s.conditions.paces.withLock { $0 = [.gentle] }
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        let photos = s.year2025.count + s.year2026.count
        #expect(report.contentAnalyzed == photos)
        #expect(s.time.now.withLock { $0 } >= AnalysisPipeline.gentleBreak * photos)
    }

    @Test func pauseWhileWaitingEndsTheRun() async throws {
        let s = try setup()
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 20) + [.wait(.batteryLow)] }
        let pipeline = s.pipeline
        let report = try await pipeline.run(onWaiting: { reason in
            if reason != nil { Task { await pipeline.pause() } }
        })
        #expect(report.pausedBecause == .userPaused)
        #expect(!report.isComplete)
    }

    @Test func overnightRefinementStillStopsWhenHot() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        s.conditions.set(pauseAfterChecks: 0)
        let report = try await s.pipeline.run(mode: .refinement)
        #expect(report.pausedBecause == .thermal)
    }

    // MARK: Counting goes on from the real state

    @Test func secondRunCountsOnFromWhatIsDone() async throws {
        let s = try setup(batchSize: 10)
        let pipeline = s.pipeline
        // The device ends the first run part way through the image analysis.
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 40) + [.stop(.thermal)] }
        let first = try await pipeline.run()
        #expect(first.pausedBecause == .thermal)
        s.conditions.paces.withLock { $0 = [.normal] }
        let done = first.contentAnalyzed
        #expect(done > 0)
        let seen = Locked<[AnalysisPipeline.Progress]>([])
        let second = try await pipeline.run(onProgress: { progress in seen.withLock { $0.append(progress) } })
        #expect(second.isComplete)
        let content = seen.withLock { $0 }.filter { $0.stage == .content }
        let all = s.year2025.count + s.year2026.count
        // Starts at what the first run did, not at zero, and over the whole library.
        #expect(content.first?.completed == done)
        #expect(content.allSatisfy { $0.total == all })
        #expect(content.last?.completed == all)
        let counts = content.map(\.completed)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 })
        // Places: every photo with a location was resolved by the first run already.
        let places = seen.withLock { $0 }.filter { $0.stage == .places }
        #expect(places.allSatisfy { $0.completed == $0.total })
    }

    // MARK: The trial year is kept and limits the analysis

    @Test func trialYearIsKeptForLaterRuns() async throws {
        let s = try setup()
        try await s.pipeline.setScope(.year(2026))
        _ = try await s.pipeline.run()
        // A later run without a scope (app start, new photos, "Neu prüfen") keeps the year.
        _ = try await s.pipeline.run()
        let snapshot = try #require(try await s.pipeline.latestProposals())
        #expect(snapshot.scope == .year(2026))
        let in2026 = Set(s.year2026)
        #expect(snapshot.proposals.allSatisfy { Set($0.assetIDs).isSubset(of: in2026) })
        // The Lake Garda trip (the fake geocoder knows the town, Malcesine); Italy was seen on
        // that trip only, so the trip is its album.
        #expect(snapshot.proposals.contains { $0.kind == .trip && $0.title.hasPrefix("Malcesine") })
        #expect(!snapshot.proposals.contains { $0.title.hasPrefix("Rom") })
        #expect(try await s.pipeline.storedScope() == .year(2026))
    }

    @Test func trialYearAnalysesOnlyItsPhotos() async throws {
        let s = try setup()
        try await s.pipeline.setScope(.year(2026))
        let seen = Locked<[AnalysisPipeline.Progress]>([])
        let report = try await s.pipeline.run(onProgress: { progress in seen.withLock { $0.append(progress) } })
        #expect(report.isComplete)
        #expect(report.contentAnalyzed == s.year2026.count)
        #expect(s.analyzer.counts.withLock { $0.content } == s.year2026.count)
        let content = seen.withLock { $0 }.filter { $0.stage == .content }
        #expect(content.last?.total == s.year2026.count)
        // Taking in the whole library later analyses the rest, nothing twice.
        try await s.pipeline.setScope(.all)
        let rest = try await s.pipeline.run()
        #expect(rest.isComplete)
        #expect(rest.contentAnalyzed == s.year2025.count)
        #expect(s.analyzer.counts.withLock { $0.content } == s.year2025.count + s.year2026.count)
        let snapshot = try #require(try await s.pipeline.latestProposals())
        #expect(snapshot.scope == .all)
    }

    @Test func trialYearRangeMatchesTheYearFilter() {
        let range = AnalysisPipeline.dateRange(of: .year(2026), calendar: Fixture.calendar)
        #expect(range?.contains(Fixture.date("2026-01-01 00:00")) == true)
        #expect(range?.contains(Fixture.date("2026-12-31 23:59")) == true)
        #expect(range?.contains(Fixture.date("2025-12-31 23:59")) == false)
        #expect(range?.contains(Fixture.date("2027-01-01 00:00")) == false)
        #expect(AnalysisPipeline.dateRange(of: .all, calendar: Fixture.calendar) == nil)
    }

    // MARK: Place lookups report their progress

    @Test func placeResolutionReportsProgressUpToAllRequests() async throws {
        let requests: [PlaceResolutionService.Request] = (0..<40).map { i in
            .init(assetID: AssetID("r-\(i)"), coordinate: Fixture.jitter(i < 20 ? Fixture.Places.rome : Fixture.Places.munichHome, seed: i, meters: 300))
        }
        let service = PlaceResolutionService(
            map: Self.map, geocoder: FakeGeocoder(), cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german),
            time: ManualTime().source
        )
        let seen = Locked<[Int]>([])
        _ = try await service.resolve(requests, progress: { n in seen.withLock { $0.append(n) } }) { _ in }
        let values = seen.withLock { $0 }
        #expect(!values.isEmpty)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == requests.count)
    }

    // MARK: Every stage is shown, Pause holds before the last steps (device test 15.11.)

    /// "Jetzt hängt es hier": the card showed "Orte werden bestimmt · 1.600 von 1.600" while
    /// the run went on through stages that said nothing, and Pause was only seen at the end.
    @Test func everyStageSaysWhenItBeginsAndPauseHoldsBeforeTheLastSteps() async throws {
        let s = try setup()
        let seen = Locked<[AnalysisPipeline.Stage]>([])
        let full = try await s.pipeline.run(onProgress: { progress in
            seen.withLock { if $0.last != progress.stage { $0.append(progress.stage) } }
        })
        #expect(full.isComplete)
        #expect(seen.withLock { $0 } == AnalysisPipeline.Stage.allCases)

        // Pause while the texts are read: the run ends before groups and suggestions.
        let control = AnalysisRunControl()
        let paused = try await s.pipeline.run(control: control, onProgress: { progress in
            if progress.stage == .text { control.pause() }
        })
        #expect(paused.pausedBecause == .userPaused)
        #expect(!paused.completedStages.contains(.groups))
        #expect(!paused.completedStages.contains(.proposals))
    }
}
