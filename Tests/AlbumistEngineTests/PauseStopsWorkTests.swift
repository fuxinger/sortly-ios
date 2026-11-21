import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Review P4-07: "Pause in unter 1 Sekunde" held for the card, not for the work. The card said
/// "Wird angehalten" at once, but the run asked for the Pause only before each photo and between
/// steps: the photos in work were finished first (an iCloud original up to 180 s), and the
/// trips step and the suggestions (3.5 to 7.8 s over 50,000 to 100,000 photos) were never
/// interrupted. Counted here is the work done after the Pause, not the time it takes.
///
/// Each test case is held to 10 minutes: a test that waits for ever fails here instead of
/// holding the whole job until its 30-minute timeout. The slowest, `pauseRacingTheEndOfThePhotos`,
/// took 81 s for its twelve cases in CI and 202 s inside a full `swift test --parallel` on a
/// 4-core machine with a load of 20 (20.11.); its cases run side by side, each about as long.
@Suite("Pause stops the work, not only the card", .timeLimit(.minutes(10)))
struct PauseStopsWorkTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    /// The pipeline's "now". Not the wall clock: the image step ends a batch early once a second
    /// of `now` has passed (saved and shown at least once a second), and on a busy machine a
    /// second of wall clock passed before the second photo was handed out. Only one photo was
    /// then in work, and `pauseRacingTheEndOfThePhotos`, which waits for two, waited for ever
    /// (both Linux core jobs of b38dfdc on 20.11. ran into their 30-minute timeout).
    static let today = Fixture.date("2026-07-01 08:00")

    /// Analyses that wait at a gate until the test opens it (or until they are cancelled, like
    /// the app's image requests). Every analysis that ends normally is counted.
    final class GatedAnalyzer: ContentAnalyzing, @unchecked Sendable {
        let gateContent: Bool
        let gateText: Bool
        /// Wall-clock time each `willAnalyze` takes while the gate is shut: a machine so busy
        /// that a second passes between two photos handed out.
        let slowMachine: Duration
        let open = Locked(false)
        /// Analyses begun and analyses that ran to their end.
        let counts = Locked<(started: Int, finished: Int)>((0, 0))

        init(gateContent: Bool = false, gateText: Bool = false, slowMachine: Duration = .zero) {
            self.gateContent = gateContent
            self.gateText = gateText
            self.slowMachine = slowMachine
        }

        func willAnalyze(_ upcoming: [AssetSnapshot]) async {
            guard slowMachine > .zero, !open.withLock({ $0 }) else { return }
            try? await Task.sleep(for: slowMachine)
        }

        private func pass(_ gated: Bool) async throws {
            guard gated else { return }
            counts.withLock { $0.started += 1 }
            while !open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
            counts.withLock { $0.finished += 1 }
        }

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            try await pass(gateContent)
            return ContentAnalysis(labels: [], source: .localPreview)
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            try await pass(gateText)
            return TextAnalysis(text: "Ihre Bestellung Bestellnummer 302-1234567", source: .original)
        }
    }

    /// A home, a week in Rome and a few screenshots (trips, places, image and text steps).
    func pipeline(analyzer: any ContentAnalyzing = FakeContentAnalyzer()) throws -> (AlbumistStore, AnalysisPipeline) {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for day in 1...5 { lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        let store = try AlbumistStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer,
            geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(), settings: OrganizationSettings(),
            calendar: Fixture.calendar, time: ManualTime().source, batchSize: 10, now: { Self.today },
            earlyGraceOnStop: .seconds(60)
        )
        return (store, pipeline)
    }

    /// Pause while the trips are detected: no later step begins (before, the places step ran
    /// and the run asked for the Pause only after it).
    @Test func pauseInTheTripsStepBeginsNoLaterStep() async throws {
        let (_, pipeline) = try pipeline()
        let control = AnalysisRunControl()
        let afterPause = Locked<[AnalysisPipeline.Stage]>([])
        let report = try await pipeline.run(control: control) { progress in
            if control.isPaused {
                afterPause.withLock { $0.append(progress.stage) }
            } else if progress.stage == .patterns, progress.total > 0 {
                control.pause()
            }
        }
        #expect(control.isPaused, "the trips step said no count")
        #expect(report.pausedBecause == .userPaused)
        #expect(report.completedStages == [.inventory])
        let later = afterPause.withLock { $0 }.filter { $0 != .patterns }
        #expect(later.isEmpty, "steps begun after the Pause: \(later)")
    }

    /// Pause while the suggestions are made (the facts of every photo, then the suggestions,
    /// then the matching, each off the actor): none of that work begins after the Pause, and
    /// nothing is saved.
    @Test func pauseWhileTheSuggestionsAreMadeBeginsNoMoreOfTheirWork() async throws {
        let (_, pipeline) = try pipeline()
        let control = AnalysisRunControl()
        let inProposals = Locked(false)
        let begunAfterPause = Locked(0)
        await pipeline.setOffActorProbe {
            guard inProposals.withLock({ $0 }) else { return }
            if control.isPaused { begunAfterPause.withLock { $0 += 1 } } else { control.pause() }
        }
        let report = try await pipeline.run(control: control) { progress in
            if progress.stage == .proposals { inProposals.withLock { $0 = true } }
        }
        #expect(control.isPaused, "the suggestions did no work off the actor")
        #expect(begunAfterPause.withLock { $0 } == 0, "work of the suggestions begun after the Pause")
        #expect(report.pausedBecause == .userPaused)
        #expect(!report.completedStages.contains(.proposals))
        #expect(try await pipeline.latestProposals()?.isEarly != false, "the full set was saved after the Pause")
    }

    /// Runs `pipeline` with `control`, pauses once the analyzer has begun its first gated
    /// analysis, waits up to `grace` for the run to end, then opens the gate. `grace` is only a
    /// fallback for the old behaviour (the run waited for the gate); a run that cancels its
    /// photos ends long before it, also on a busy test machine.
    func runAndPauseInWork(_ pipeline: AnalysisPipeline, _ analyzer: GatedAnalyzer,
                           grace: Duration = .seconds(10)) async throws -> AnalysisPipeline.Report {
        let control = AnalysisRunControl()
        let ended = Locked(false)
        let run = Task {
            defer { ended.withLock { $0 = true } }
            return try await pipeline.run(control: control)
        }
        let clock = ContinuousClock()
        // No deadline: a run that never reaches the gate ends by itself.
        while analyzer.counts.withLock({ $0.started }) == 0, !ended.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(analyzer.counts.withLock { $0.started } > 0, "no analysis began")
        control.pause()
        // Only a fallback: the run that waits for the photos in work ends when the gate opens.
        let deadline = clock.now + grace
        while !ended.withLock({ $0 }), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        analyzer.open.withLock { $0 = true }
        return try await run.value
    }

    /// Pause while photos are in the image step: they are cancelled, not finished first.
    @Test func pauseCancelsThePhotosInWork() async throws {
        let analyzer = GatedAnalyzer(gateContent: true)
        let (_, pipeline) = try pipeline(analyzer: analyzer)
        let report = try await runAndPauseInWork(pipeline, analyzer)
        #expect(report.pausedBecause == .userPaused)
        #expect(analyzer.counts.withLock { $0.finished } == 0, "photos finished after the Pause")
        #expect(report.contentAnalyzed == 0)
    }

    /// Pause while a text is read (an iCloud original can take minutes): the read is cancelled.
    @Test func pauseCancelsTheTextReadsInWork() async throws {
        let analyzer = GatedAnalyzer(gateText: true)
        let (_, pipeline) = try pipeline(analyzer: analyzer)
        let report = try await runAndPauseInWork(pipeline, analyzer)
        #expect(report.pausedBecause == .userPaused)
        #expect(analyzer.counts.withLock { $0.finished } == 0, "texts finished after the Pause")
        #expect(report.textRecognized == 0)
    }

    // MARK: Second review: what is counted and what is stored stays right

    static func needing(_ store: AlbumistStore) async throws -> Int {
        try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion)
    }

    /// Photos cancelled for the Pause are neither done nor failed: the paused run says exactly
    /// the photos it finished ("x von y"), "Fortsetzen" starts the count there and analyses each
    /// remaining photo once.
    @Test func resumeAfterCancelledPhotosCountsOnExactly() async throws {
        let analyzer = GatedAnalyzer(gateContent: true)
        let (store, pipeline) = try pipeline(analyzer: analyzer)
        let said = Locked<[[AnalysisPipeline.Progress]]>([[], []])
        let control = AnalysisRunControl()
        let run = Task { try await pipeline.run(control: control) { p in if p.stage == .content { said.withLock { $0[0].append(p) } } } }
        while analyzer.counts.withLock({ $0.started }) == 0 { try await Task.sleep(for: .milliseconds(1)) }
        control.pause()
        let first = try await run.value
        analyzer.open.withLock { $0 = true }
        let total = try await store.allAssets().count
        let done = total - (try await Self.needing(store))
        #expect(first.pausedBecause == .userPaused)
        #expect(done == first.contentAnalyzed, "marked done \(done), analysed \(first.contentAnalyzed)")
        let second = try await pipeline.run { p in if p.stage == .content { said.withLock { $0[1].append(p) } } }
        let (before, after) = said.withLock { ($0[0], $0[1]) }
        #expect(before.last?.completed == done && before.last?.total == total)
        #expect(after.first?.completed == done && after.last?.completed == total && after.last?.total == total)
        #expect(second.isComplete)
        #expect(first.contentAnalyzed + second.contentAnalyzed == total)
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        #expect(contents.count == total && contents.values.allSatisfy { $0.failedAttempts == nil })
    }

    /// Pause and the photos in work ending at the same moment, in both orders: every photo is
    /// done with a result or still to do, never done without one; "Fortsetzen" does the rest.
    @Test(arguments: 0..<12) func pauseRacingTheEndOfThePhotos(_ seed: Int) async throws {
        try await race(seed, GatedAnalyzer(gateContent: true))
    }

    /// The same race on a machine so busy that a second of wall clock passes between two
    /// photos handed out (both Linux core jobs of b38dfdc): two photos are in work all the same,
    /// and the race ends. Before, the pipeline of these tests read the wall clock, ended the
    /// batch after its first photo, and the race waited for a second photo for ever (with a
    /// limit of one minute both cases failed with "Time limit was exceeded"; alone they take
    /// about 17 s).
    @Test(arguments: [0, 1])
    func pauseRacingTheEndOfThePhotosOnABusyMachine(_ seed: Int) async throws {
        try await race(seed, GatedAnalyzer(gateContent: true, slowMachine: .milliseconds(1100)))
    }

    func race(_ seed: Int, _ analyzer: GatedAnalyzer) async throws {
        let (store, pipeline) = try pipeline(analyzer: analyzer)
        let control = AnalysisRunControl()
        let run = Task { try await pipeline.run(control: control) }
        while analyzer.counts.withLock({ $0.started }) < 2 { try await Task.sleep(for: .milliseconds(1)) }
        if seed % 2 == 0 {
            control.pause()
            analyzer.open.withLock { $0 = true }
        } else {
            analyzer.open.withLock { $0 = true }
            control.pause()
        }
        let first = try await run.value
        let total = try await store.allAssets().count
        let done = total - (try await Self.needing(store))
        #expect(first.pausedBecause == .userPaused)
        #expect(done == first.contentAnalyzed, "marked done \(done), analysed \(first.contentAnalyzed)")
        #expect(try await store.results(ContentAnalysis.self, kind: "content").values.allSatisfy { $0.failedAttempts == nil })
        let second = try await pipeline.run()
        #expect(second.isComplete && first.contentAnalyzed + second.contentAnalyzed == total)
    }

    /// A text read cancelled for the Pause leaves nothing behind (no try counted, no text), and
    /// "Fortsetzen" reads every text.
    @Test func textCancelledForThePauseIsReadByFortsetzen() async throws {
        let analyzer = GatedAnalyzer(gateText: true)
        let (store, pipeline) = try pipeline(analyzer: analyzer)
        let first = try await runAndPauseInWork(pipeline, analyzer)
        #expect(first.pausedBecause == .userPaused)
        let stored = try await store.results(TextResult.self, kind: "text")
        #expect(stored.isEmpty, "stored for cancelled reads: \(stored.values.map { $0.retries ?? 0 })")
        let second = try await pipeline.run()
        #expect(second.isComplete && second.textRecognized == 5)
    }

    /// Everything the trips step stores, as the store holds it.
    struct Stored: Equatable {
        var trips: [Trip]?
        var identities: [TripIdentity]?
        var report: RecurringPlaceReport?
        var frequent: [FrequentPlace]?
        var home: Set<AssetID>?
        var detectedHome: DetectedHome?
        var zone: String?

        /// Nothing stored.
        init(nothing: Void) {}

        init(_ store: AlbumistStore) async throws {
            typealias K = AnalysisPipeline.Key
            trips = try await store.value([Trip].self, forKey: K.trips)
            identities = try await store.value([TripIdentity].self, forKey: K.tripIdentities)
            report = try await store.value(RecurringPlaceReport.self, forKey: K.recurringPlaceReport)
            frequent = try await store.value([FrequentPlace].self, forKey: K.frequentPlaces)
            home = try await store.value(Set<AssetID>.self, forKey: K.home)
            detectedHome = try await store.value(DetectedHome.self, forKey: K.detectedHome)
            zone = try await store.value(String.self, forKey: K.homeTimeZone)
        }
    }

    /// A move from Munich to New York with a trip after it, read by a run on the analysis of
    /// before. Paused at any of the trips step's checks (choosing the clock, after the
    /// detection, right before storing): nothing of it is stored, also not the new home time
    /// zone; the trips, places and home of before stay as they were. Not paused, all of it
    /// changes (so the comparison means something).
    @Test(arguments: [nil, AnalysisPipeline.StopPoint.tripsClockChosen, .tripsDetected, .tripsBeforeStoring])
    func pauseInTheTripsStepStoresAllOrNothing(_ point: AnalysisPipeline.StopPoint?) async throws {
        typealias L = LocalTimePipelineTests
        var lib = LibraryBuilder()
        lib.daily(from: "2025-06-01", to: "2026-01-31", at: Fixture.Places.munichHome, perDay: 2, skipping: [("2025-10-10", "2025-10-17")])
        lib.daily(from: "2025-10-10", to: "2025-10-17", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let beforeTheMove = lib.assets
        lib.daily(from: "2026-02-15", to: "2026-08-31", at: L.newYork, perDay: 2, skipping: [("2026-06-01", "2026-06-08")])
        lib.daily(from: "2026-06-01", to: "2026-06-08", at: GeoCoordinate(latitude: 25.7617, longitude: -80.1918), perDay: 4, hour: 10)
        let store = try AlbumistStore(url: nil)
        let first = L.pipeline(store: store, reader: InMemoryLibraryReader(assets: beforeTheMove), geocoder: nil, deviceZone: "Europe/Berlin")
        #expect(try await first.run().isComplete)
        let before = try await Stored(store)
        let moved = L.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: nil, deviceZone: "Europe/Berlin")
        let control = AnalysisRunControl()
        let seen = Locked<[AnalysisPipeline.StopPoint]>([])
        await moved.setStopPointProbe { p in
            seen.withLock { $0.append(p) }
            if p == point { control.pause() }
        }
        let report = try await moved.run(control: control) { p in
            // Not paused: stopped once the trips step is done, before its results are used.
            if point == nil, p.stage == .places { control.pause() }
        }
        let after = try await Stored(store)
        let order: [AnalysisPipeline.StopPoint] = [.tripsClockChosen, .tripsDetected, .tripsBeforeStoring]
        let reached = point.flatMap { order.firstIndex(of: $0) }.map { Array(order[...$0]) } ?? order
        #expect(Array(seen.withLock { $0 }.prefix(reached.count)) == reached)
        if point == nil {
            #expect(report.completedStages == [.inventory, .patterns])
            #expect(after.zone != before.zone && after.trips != before.trips && after.identities != before.identities)
            #expect(after.home != before.home && after.detectedHome != before.detectedHome && after.report != before.report)
        } else {
            #expect(report.pausedBecause == .userPaused && report.completedStages == [.inventory])
            #expect(after == before, "stored although paused at \(String(describing: point))")
            // No further part of the step began after the Pause.
            #expect(seen.withLock { $0 }.count == reached.count, "\(seen.withLock { $0 })")
        }
    }

    /// The first run, paused in the trips step: not even the home time zone of the first
    /// analysis (the iPhone's) is stored; the run that finishes the step stores it.
    @Test(arguments: [AnalysisPipeline.StopPoint.tripsClockChosen, .tripsDetected, .tripsBeforeStoring])
    func firstRunPausedInTheTripsStepStoresNoHomeZone(_ point: AnalysisPipeline.StopPoint) async throws {
        typealias L = LocalTimePipelineTests
        var lib = LibraryBuilder()
        lib.daily(from: "2025-06-01", to: "2026-01-31", at: Fixture.Places.munichHome, perDay: 2)
        let store = try AlbumistStore(url: nil)
        let pipeline = L.pipeline(store: store, reader: InMemoryLibraryReader(assets: lib.assets), geocoder: nil, deviceZone: "Asia/Tokyo")
        let control = AnalysisRunControl()
        await pipeline.setStopPointProbe { if $0 == point { control.pause() } }
        let report = try await pipeline.run(control: control)
        #expect(report.pausedBecause == .userPaused && report.completedStages == [.inventory])
        #expect(try await Stored(store) == Stored(nothing: ()))
        await pipeline.setStopPointProbe(nil)
        #expect(try await pipeline.run().isComplete)
        #expect(try await L.storedHomeZone(store) != nil)
    }

    /// Pause right before the suggestions are saved: the full set is not saved, the early set
    /// of the first run stays.
    @Test func pauseRightBeforeTheSuggestionsAreSavedSavesNothing() async throws {
        let (_, pipeline) = try pipeline()
        let control = AnalysisRunControl()
        let inProposals = Locked(false)
        await pipeline.setStopPointProbe { p in
            if p == .suggestionsBeforeSaving, inProposals.withLock({ $0 }) { control.pause() }
        }
        let report = try await pipeline.run(control: control) { p in
            if p.stage == .proposals { inProposals.withLock { $0 = true } }
        }
        #expect(control.isPaused, "the suggestions were never about to be saved")
        #expect(report.pausedBecause == .userPaused && !report.completedStages.contains(.proposals))
        #expect(try await pipeline.latestProposals()?.isEarly == true)
    }

    /// Work of the suggestions given up at the Pause (here held where it runs): the run ends
    /// at once, and "Fortsetzen" begins only once that work has ended, never beside it.
    @Test func fortsetzenWaitsForTheWorkGivenUpAtThePause() async throws {
        let (_, pipeline) = try pipeline()
        let control = AnalysisRunControl()
        let inProposals = Locked(false)
        let held = Locked<(holding: Bool, release: Bool)>((false, false))
        await pipeline.setOffActorProbe {
            guard inProposals.withLock({ $0 }), !control.isPaused else { return }
            held.withLock { $0.holding = true }
            control.pause()
            while !held.withLock({ $0.release }) { try? await Task.sleep(for: .milliseconds(2)) }
            held.withLock { $0.holding = false }
        }
        let report = try await pipeline.run(control: control) { p in
            if p.stage == .proposals { inProposals.withLock { $0 = true } }
        }
        #expect(report.pausedBecause == .userPaused)
        #expect(held.withLock { $0.holding }, "the run waited for the work it gave up")
        await pipeline.setOffActorProbe(nil)
        let began = Locked(false)
        let resumed = Task { try await pipeline.run { _ in began.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!began.withLock { $0 }, "Fortsetzen began beside the work given up")
        held.withLock { $0.release = true }
        #expect(try await resumed.value.isComplete)
        #expect(began.withLock { $0 })
    }

    /// The work given up at a Pause asks its own task and ends early (its result is dropped):
    /// the facts stop within 1,000 photos, the suggestions and the matching at once. Asked
    /// "never", they give what they always gave.
    @Test func workGivenUpEndsEarly() async throws {
        let (store, pipeline) = try pipeline()
        #expect(try await pipeline.run().isComplete)
        let all = try await store.allAssets()
        let inventory = try await store.loadInventory()
        func facts(_ stop: () -> Bool) -> [AssetFacts] {
            FactsAssembler.assemble(assets: all, places: [:], contents: [:], texts: [:], trips: [], frequentPlaces: [], groups: [],
                                    inventory: inventory, stoppingWhen: stop)
        }
        var asked = 0
        #expect(facts({ asked += 1; return asked > 1 }).count == 1_000 || all.count <= 1_000)
        #expect(facts({ true }).isEmpty)
        #expect(facts({ false }).map(\.id) == facts({ false }).map(\.id) && facts({ false }).count == all.count)
        let snapshot = try #require(try await pipeline.latestProposals())
        let current = try await pipeline.currentFacts()
        let engine = ProposalEngine(settings: OrganizationSettings(), calendar: Fixture.calendar)
        let analysis = AnalysisSnapshot(facts: current, trips: [], frequentPlaces: [], groups: [], recurringPlaces: [], home: HomeSettings())
        #expect(engine.suggestions(for: analysis, stoppingWhen: { true }).open.isEmpty)
        #expect(engine.suggestions(for: analysis, stoppingWhen: { false }).open == engine.suggestions(for: analysis).open)
        let matched = AnalysisPipeline.match(snapshot.proposals, dismissed: [], against: inventory, overrides: OverrideSet(), assignments: [:])
        #expect(AnalysisPipeline.match(snapshot.proposals, dismissed: [], against: inventory, overrides: OverrideSet(), assignments: [:],
                                       stoppingWhen: { true }).isEmpty)
        #expect(AnalysisPipeline.match(snapshot.proposals, dismissed: [], against: inventory, overrides: OverrideSet(), assignments: [:],
                                       stoppingWhen: { false }) == matched)
    }
}
