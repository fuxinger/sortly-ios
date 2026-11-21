import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Stress run 44116350940 (50,000 photos): "Bildinhalte werden erkannt 0 von 50.246 Fotos"
/// stood still for 13 s when the image step began, over the owner's limit of 10 s. Between the
/// report that starts the step and the first counted photo the run made the early suggestions
/// over the whole library (2.8 s on Linux over 50,000 photos, 0.25 s over 5,000: it grows with
/// the library), and the overview's refresh after them assembled the facts of every photo on the
/// pipeline's actor. The early suggestions are now made beside the first photos, and what grows
/// with the library runs off the actor: the count moves after the first photos at any size.
@Suite("Image step: the count moves at once")
struct ImageStepStartTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Setup {
        let store: AlbumistStore
        let pipeline: AnalysisPipeline
        let photos: Int
        let dogs: [AssetID]
    }

    /// A home, a week in Rome, screenshots of orders, a dog in Rome and at home: trips and places
    /// for the early suggestions, image and text themes for the full set only (as PipelineTests).
    /// `grace`: how long a stopping run waits for the early suggestions (the app's half second
    /// by default).
    func setup(grace: Duration = .milliseconds(500)) throws -> Setup {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        var screenshots: Set<AssetID> = []
        for day in 1...5 { screenshots.insert(lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot)) }
        let dogs = Array(rome.prefix(10)) + Array(home.suffix(10))
        let dogSet = Set(dogs), shots = screenshots
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.imageCategories.minPhotos = 10
        let store = try AlbumistStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets),
            analyzer: FakeContentAnalyzer(
                labels: { dogSet.contains($0.id) ? [LabelScore("dog", 0.92)] : [] },
                text: { shots.contains($0.id) ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung Sendungsverfolgung" : "" }
            ),
            geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source, batchSize: 10, earlyGraceOnStop: grace
        )
        return Setup(store: store, pipeline: pipeline, photos: lib.assets.count, dogs: dogs)
    }

    /// Suggestions that need the image or text analysis.
    static func needsAnalysis(_ p: AlbumProposal) -> Bool {
        switch p.kind {
        case .imageCategory, .screenshotCategory, .documentCategory, .personOrPet, .personalCategory: true
        default: false
        }
    }

    struct Seen {
        var events: [AnalysisPipeline.Progress] = []
        /// The image step's newest count.
        var counted = 0
        var inContent = false
        /// The early suggestions' work was held (`offActorProbe`), and the count when it let go.
        var held = false
        var countedWhileHeld: Int?
    }

    /// The early suggestions' work that grows with the library is held until the image step
    /// has counted 30 photos. Made before the photos, or on the pipeline's actor, it would hold
    /// the count instead: the probe then lets go after 30 s with the count where it was (a
    /// deadline only for that case; a busy test machine still counts 30 photos in well under it).
    @Test func photosAreCountedWhileTheEarlySuggestionsAreMade() async throws {
        let s = try setup()
        let seen = Locked(Seen())
        await s.pipeline.setOffActorProbe {
            let first = seen.withLock { state -> Bool in
                guard state.inContent, !state.held else { return false }
                state.held = true
                return true
            }
            guard first else { return }
            let deadline = Date().addingTimeInterval(30)
            while seen.withLock({ $0.counted }) < 30, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            seen.withLock { $0.countedWhileHeld = $0.counted }
        }
        let report = try await s.pipeline.run { progress in
            seen.withLock { state in
                state.events.append(progress)
                if progress.stage == .content {
                    state.inContent = true
                    state.counted = max(state.counted, progress.completed)
                }
            }
        }
        #expect(report.isComplete)
        #expect(report.earlyProposals)
        let state = seen.withLock { $0 }
        #expect(state.held, "the early suggestions did no work off the actor")
        #expect((state.countedWhileHeld ?? 0) >= 30, "counted \(state.countedWhileHeld ?? -1) photos while the early suggestions were made")
        let content = state.events.filter { $0.stage == .content }
        // The count never goes back, and the early suggestions are said once, after photos were
        // counted, with the newest count.
        #expect(zip(content, content.dropFirst()).allSatisfy { $0.completed <= $1.completed })
        let early = content.indices.filter { content[$0].earlyProposals }
        #expect(early.count == 1)
        if let i = early.first {
            #expect(content[i].completed >= 30)
            #expect(i > 0 && content[i].completed == content[i - 1].completed)
        }
        // The early set was replaced by the full one at the end of the run.
        #expect(try await s.pipeline.latestProposals()?.isEarly == false)
    }

    /// Pause right when the image step begins, before any photo, with early suggestions that
    /// are done within the time a stopping run waits for them (a small library: milliseconds;
    /// the test waits as long as it takes, so the machine's load does not decide): the paused
    /// first run offers trips and places, and says so with the count it stopped at.
    @Test func pauseBeforeTheFirstPhotoOffersEarlySuggestionsThatAreDone() async throws {
        let s = try setup(grace: .seconds(60))
        let control = AnalysisRunControl()
        let seen = Locked<[AnalysisPipeline.Progress]>([])
        let report = try await s.pipeline.run(control: control) { progress in
            seen.withLock { $0.append(progress) }
            if progress.stage == .content { control.pause() }
        }
        #expect(report.pausedBecause == .userPaused)
        #expect(report.contentAnalyzed == 0)
        #expect(report.earlyProposals)
        let early = try #require(try await s.pipeline.latestProposals())
        #expect(early.isEarly)
        #expect(early.proposals.contains { $0.title.hasPrefix("Rom") })
        let content = seen.withLock { $0 }.filter { $0.stage == .content }
        #expect(content.filter(\.earlyProposals).count == 1)
        #expect(content.allSatisfy { $0.completed == 0 })
        // The run that goes on makes the full set and says no early ones again.
        let rest = Locked(false)
        let second = try await s.pipeline.run { progress in if progress.earlyProposals { rest.withLock { $0 = true } } }
        #expect(second.isComplete)
        #expect(!second.earlyProposals && !rest.withLock { $0 })
        #expect(second.contentAnalyzed == s.photos)
        #expect(try await s.pipeline.latestProposals()?.isEarly == false)
    }

    /// Review of 9ff0dfc: Pause waited for the early suggestions however long they took (at
    /// 50,000 photos 1.6 s instead of a few ms; Pause must take effect within a second). Now a
    /// stopping run waits half a second at most; early suggestions not done by then are
    /// dropped unsaved, and the next run makes them again (there are still no suggestions).
    /// What the user sees: Pause at once, "Schon fertig" stays empty until Fortsetzen.
    /// Here the early suggestions are held until the run has returned, so a run that waited
    /// for them would only end at the probe's deadline. (The second itself is measured in the
    /// load test: in the parallel suite the machine's load decides the time.)
    @Test func pauseDoesNotWaitForSlowEarlySuggestions() async throws {
        let s = try setup()
        let release = Locked(false)
        let letGo = Locked(false)
        await s.pipeline.setOffActorProbe {
            guard !letGo.withLock({ $0 }) else { return }
            let deadline = Date().addingTimeInterval(60)
            while !release.withLock({ $0 }), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            if !release.withLock({ $0 }) { letGo.withLock { $0 = true } }
        }
        let control = AnalysisRunControl()
        let saidEarly = Locked(false)
        let report = try await s.pipeline.run(control: control) { progress in
            if progress.earlyProposals { saidEarly.withLock { $0 = true } }
            if progress.stage == .content { control.pause() }
        }
        #expect(report.pausedBecause == .userPaused)
        #expect(!letGo.withLock { $0 }, "the run waited for the early suggestions")
        #expect(!report.earlyProposals)
        release.withLock { $0 = true }
        await s.pipeline.waitForEarlyLeftBehind()
        // Dropped: nothing saved, nothing said after the run ended.
        #expect(try await s.pipeline.latestProposals() == nil)
        #expect(!saidEarly.withLock { $0 })
        // Fortsetzen: the next run offers them beside its photos, then the full set.
        await s.pipeline.setOffActorProbe(nil)
        let said = Locked(0)
        let second = try await s.pipeline.run { progress in if progress.earlyProposals { said.withLock { $0 += 1 } } }
        #expect(second.isComplete)
        #expect(second.earlyProposals && said.withLock { $0 } == 1)
        #expect(try await s.pipeline.latestProposals()?.isEarly == false)
    }

    /// Review of 9ff0dfc: made beside the photos, the early set read the labels of photos
    /// already looked at and offered "Hunde" before the image analysis was done. An early set
    /// has trips and places only, also on a first run that goes on after photos were analysed.
    @Test func earlySetHasNoImageOrTextThemes() async throws {
        let s = try setup()
        // First run: the early suggestions are held until the run paused (they are dropped),
        // after 100 photos with every dog among them (newest first).
        let release = Locked(false)
        await s.pipeline.setOffActorProbe {
            let deadline = Date().addingTimeInterval(30)
            while !release.withLock({ $0 }), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        }
        let control = AnalysisRunControl()
        let first = try await s.pipeline.run(control: control) { progress in
            if progress.stage == .content, progress.completed >= 100 { control.pause() }
        }
        release.withLock { $0 = true }
        await s.pipeline.waitForEarlyLeftBehind()
        await s.pipeline.setOffActorProbe(nil)
        #expect(first.pausedBecause == .userPaused && !first.earlyProposals)
        let labelled = try await s.store.results(ContentAnalysis.self, kind: "content")
        try #require(s.dogs.allSatisfy { labelled[$0] != nil }, "the dogs were not analysed yet")
        #expect(try await s.pipeline.latestProposals() == nil)
        // Second run: its early set, read when it is said.
        let again = AnalysisRunControl()
        let second = try await s.pipeline.run(control: again) { progress in
            if progress.earlyProposals { again.pause() }
        }
        #expect(second.earlyProposals)
        let early = try #require(try await s.pipeline.latestProposals())
        #expect(early.isEarly)
        #expect(early.proposals.contains { $0.title.hasPrefix("Rom") })
        let themes = early.proposals.filter(Self.needsAnalysis).map(\.title)
        #expect(themes.isEmpty, "early set offers \(themes)")
        // The full set has them.
        let last = try await s.pipeline.run()
        #expect(last.isComplete)
        let full = try #require(try await s.pipeline.latestProposals())
        #expect(full.proposals.contains { $0.title == "Hunde" })
    }

    /// Review of 9ff0dfc: an error in the early suggestions came out at the end of the image
    /// step and failed a run that was otherwise complete (hours later on a large library). Now
    /// the run goes on; the full set at its end replaces the early one, and the report says why
    /// there was none.
    @Test func failedEarlySuggestionsDoNotFailTheRun() async throws {
        struct Broken: Error {}
        let s = try setup()
        await s.pipeline.setEarlyProbe { throw Broken() }
        let saidEarly = Locked(false)
        let report = try await s.pipeline.run { progress in if progress.earlyProposals { saidEarly.withLock { $0 = true } } }
        #expect(report.isComplete)
        #expect(!report.earlyProposals)
        #expect(report.earlyProposalsFailure != nil)
        #expect(!saidEarly.withLock { $0 })
        #expect(report.contentAnalyzed == s.photos)
        let full = try #require(try await s.pipeline.latestProposals())
        #expect(!full.isEarly)
        #expect(full.proposals.contains { $0.title.hasPrefix("Rom") })
    }

    /// The overview's facts (`refreshDerived` after the early suggestions, and every 10 s per
    /// 5,000 photos while it has none) are assembled off the pipeline's actor too.
    @Test func factsAreAssembledOffTheActor() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        let probed = Locked(0)
        await s.pipeline.setOffActorProbe { probed.withLock { $0 += 1 } }
        let facts = try await s.pipeline.currentFacts()
        #expect(facts.count == s.photos)
        #expect(probed.withLock { $0 } == 1)
    }
}
