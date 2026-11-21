import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// A full analysis on a library shaped like the owner's iPhone (5,683 items, ~1,040
/// screenshots, 19 countries, 103 trips, ~1,600 photos with a location that need Apple's
/// geocoder), with simulated time: every photo, text and town lookup takes its device time on
/// a simulated clock, sleeps advance it at once. Every `Progress` event is recorded with its
/// simulated time and checked against what the analysis card must never show: a stage that
/// does not say when it begins, a count that goes back or stands at "N von N" while work goes
/// on, a bar that jumps back after Pause, a silent stretch, a Pause that takes long.
///
/// Before every build for the device (promise 15.11.). `ALBUMIST_SIM_SCALE` (default 1) scales
/// the library; proportions, the geocoder's limit and the online budget stay.
@Suite("Full simulated run: what the analysis card shows")
struct FullRunDisplayTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    /// The uninterrupted run (a) always simulates the whole library; the other scenarios half
    /// of it (same proportions, same geocoder limit and online budget), so the suite stays fast.
    /// `ALBUMIST_SIM_SCALE=1` runs every scenario at full size (about 20 s on Linux).
    static let scaleOverride: Double? = ProcessInfo.processInfo.environment["ALBUMIST_SIM_SCALE"].flatMap(Double.init)
    static let scale: Double = scaleOverride ?? 0.5

    // MARK: Scenarios

    /// (a) One uninterrupted full run.
    @Test func uninterruptedFullRun() async throws {
        let sim = try Sim(scale: Self.scaleOverride ?? 1)
        #expect(sim.library.total == 5_683 || Self.scaleOverride != nil)
        let run = await sim.run("a")
        sim.expectComplete(run)
        // Every photo looked at exactly once, also with batches cut every second and photos
        // without a date.
        #expect(sim.analyzer.contentCalls.withLock { $0 } == sim.library.total)
        // Every stage was shown, in order (places has work: town names are looked up).
        #expect(run.stagesShown == Stage.allCases, "\(run.stagesShown)")
        // A run in the app asks what Albumist's limit allows without a wait (device test 18.11.,
        // build 36: with a budget of 60 it waited for the minute, "Apple antwortet gleich" with
        // the count standing still), then the rest waits for later.
        #expect(run.report?.onlineRequests == RequestThrottle.apple.maxRequests)
        #expect((run.report?.placesPendingOnline ?? 0) > 0)
        // The places step never stands still (invariant 11 checks every run for a wait).
        #expect(sim.longestStill("a", in: .places) <= .seconds(10), "\(sim.longestStill("a", in: .places))")
        // Review I4: on a device 30 % slower than the usual times, every clock time shown is
        // within 2 min (or a tenth of the time left, when more) of the real end. Clock times
        // are rounded to the minute, and to 5 min above 30 min left.
        let errors = sim.finishErrors("a")
        #expect(!errors.isEmpty)
        let bad = errors.filter { abs($0.off) > max(120, $0.left / 10) }
        #expect(bad.isEmpty, "\(bad.count) of \(errors.count) off, worst \(bad.map { Int($0.off) }.max() ?? 0) s")
        sim.finish()
    }

    /// (b) Pause in places (while the town names are looked up), in content and in text; each
    /// time a new run goes on. (Until 18.11. the Pause came while the run waited 30 s for Apple
    /// after a refusal; a run in the app no longer waits for it: `throttledGeocoderAndUsedUpBudget`.)
    @Test func pauseInEveryStageThenResume() async throws {
        let sim = try Sim()
        let places = await sim.run("b1 pause in places", pause: .whenGeocoderCalled(10))
        #expect(places.report?.pausedBecause == .userPaused)
        #expect(places.lastStage == .places, "paused in \(String(describing: places.lastStage))")
        // Fortsetzen within the hour does not ask Apple for town names again (device test
        // 15.11.: "es dauert lange, bis die App nach Pause weiterläuft").
        let askedInFirstRun = sim.geocoder.calls.withLock { $0 }

        let content = await sim.run("b2 pause in content", pause: .when(stage: .content, atLeast: 0.3))
        #expect(content.report?.pausedBecause == .userPaused)
        #expect(content.lastStage == .content)

        let text = await sim.run("b3 pause in text", pause: .when(stage: .text, atLeast: 0.4))
        #expect(text.report?.pausedBecause == .userPaused)
        #expect(text.lastStage == .text)

        let rest = await sim.run("b4 goes on to the end")
        sim.expectComplete(rest)
        #expect(sim.geocoder.calls.withLock { $0 } == askedInFirstRun)
        #expect(sim.clock.now < .seconds(3_600))
        // Pause finishes the photos in work and keeps them: none is looked at twice.
        #expect(sim.analyzer.contentCalls.withLock { $0 } == sim.library.total)
        sim.finish()
    }

    /// (h) Review of 11ef3e1: paused in the image step; nothing changed. The run that goes on
    /// holds the value through the steps before (the count moves) and, back at the photo it
    /// stopped at, reads the value it was paused at (invariant 10), then moves to the end.
    @Test func resumeIsHeldUntilWhereItStopped() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("h1 pause in content", pause: .when(stage: .content, atLeast: 0.6))
        #expect(first.lastStage == .content)
        let rest = await sim.run("h2 goes on")
        sim.expectComplete(rest)
        #expect(sim.passes.contains { $0.run == "h2 goes on" })
        #expect(sim.phases.isEmpty)
        sim.finish()
    }

    /// (i) A few photos come in while paused in the text step: not much more work, so no phase;
    /// held until back where it stopped, then on from there.
    @Test func fewNewPhotosAreHeldThenGoOn() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("i1 pause in text", pause: .when(stage: .text, atLeast: 0.5))
        #expect(first.lastStage == .text)
        await sim.addPhotos(20)
        let rest = await sim.run("i2 goes on")
        sim.expectComplete(rest)
        #expect(sim.phases.isEmpty)
        #expect(sim.passes.contains { $0.run == "i2 goes on" })
        sim.finish()
    }

    /// (j) Many photos come in while paused in the text step: a phase of its own, "Neue Fotos
    /// werden analysiert", with its own number from its own start, never back within it.
    @Test func manyNewPhotosStartTheirOwnPhase() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("j1 pause in text", pause: .when(stage: .text, atLeast: 0.5))
        #expect(first.lastStage == .text)
        await sim.addPhotos(800)
        let rest = await sim.run("j2 new photos")
        sim.expectComplete(rest)
        #expect(sim.phases.map(\.cause) == [.newPhotos])
        sim.finish()
    }

    /// (k) An update changes the image analysis while paused near the end: "Analyse nach Update".
    @Test func anUpdateStartsItsOwnPhase() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("k1 pause in text", pause: .when(stage: .text, atLeast: 0.5))
        #expect(first.lastStage == .text)
        try await sim.updateChangesTheAnalysis()
        let rest = await sim.run("k2 after update")
        sim.expectComplete(rest)
        #expect(sim.phases.map(\.cause) == [.afterUpdate])
        sim.finish()
    }

    /// (c) The app is ended in the middle of the image analysis; a fresh pipeline on the same
    /// store goes on.
    @Test func restartMidContentWithFreshPipeline() async throws {
        let sim = try Sim()
        let first = await sim.run("c1 ended mid-content", pause: .when(stage: .content, atLeast: 0.5), action: .cancel)
        #expect(first.lastStage == .content)
        sim.restartPipeline()
        let second = await sim.run("c2 fresh pipeline")
        sim.expectComplete(second)
        // Nothing analysed twice beyond the photos in work when the app was ended.
        #expect(sim.analyzer.contentCalls.withLock { $0 } <= sim.library.total + 8)
        sim.finish()
    }

    /// (d) After a complete run, "Analyse neu aufbauen" clears the analysis, then a full run.
    @Test func rebuildAfterCompleteRun() async throws {
        let sim = try Sim()
        sim.expectComplete(await sim.run("d1 full"))
        try await sim.store.resetAnalysis(includingDecisions: false)
        sim.newAnalysis()
        let rebuilt = await sim.run("d2 after reset")
        sim.expectComplete(rebuilt)
        // Counted from zero again (nothing is left over from before the reset).
        #expect(rebuilt.first(.content)?.completed == 0)
        #expect(rebuilt.first(.places)?.completed == 0)
        sim.finish()
    }

    /// (e) The device warms up during the image analysis: normal, gentle, waiting, normal.
    @Test func devicePaceChangesDuringContent() async throws {
        let sim = try Sim()
        let conditions = sim.conditions
        conditions.plan.withLock {
            $0.anchor = nil
            $0.steps = [(.seconds(20), .gentle), (.seconds(60), .wait(.thermal)), (.seconds(90), .normal)]
        }
        sim.onProgress = { progress, t in
            if progress.stage == .content { conditions.plan.withLock { if $0.anchor == nil { $0.anchor = t } } }
        }
        let run = await sim.run("e pace")
        sim.expectComplete(run)
        #expect(sim.analyzer.contentCalls.withLock { $0 } == sim.library.total)
        #expect(run.waits == [.thermal, nil], "\(run.waits)")
        sim.finish()
    }

    /// (f) Apple's geocoder keeps refusing; a run within the hour does not ask again; the run
    /// after the hour asks as many towns as Albumist's throttle allows without a wait (40 a
    /// minute, below the run's budget of 60), and leaves the rest for later.
    @Test func throttledGeocoderAndUsedUpBudget() async throws {
        let sim = try Sim()
        sim.geocoder.refuseCalls(5..<Int.max)
        let throttled = await sim.run("f1 geocoder throttled")
        sim.expectComplete(throttled)
        #expect(throttled.report?.placesThrottled == true)
        // Refused once: no more asking, no wait (device test 18.11., build 36).
        #expect(sim.geocoder.calls.withLock { $0 } == 6)
        #expect(sim.geocoder.refusals.withLock { $0.count } == 1)
        sim.geocoder.refuseCalls(0..<0)
        let asked = sim.geocoder.calls.withLock { $0 }
        let soon = await sim.run("f2 within the hour")
        sim.expectComplete(soon)
        #expect(soon.report?.onlineRequests == 0)
        #expect(sim.geocoder.calls.withLock { $0 } == asked)
        #expect(soon.first(.places)?.completed == throttled.last(.places)?.completed)
        sim.clock.advance(.seconds(AnalysisPipeline.foregroundOnlineCooldown))
        let budget = await sim.run("f3 after the hour, throttle full")
        sim.expectComplete(budget)
        #expect(budget.report?.onlineRequests == RequestThrottle.apple.maxRequests)
        #expect((budget.report?.placesPendingOnline ?? 0) > 0)
        sim.finish()
    }

    // MARK: The new card (progress display v3)

    /// (g) P2: iOS holds the app for 10 minutes in the middle of the image analysis (no
    /// continued task). The time in between is not counted: no finish time for 30 s after it
    /// comes back (invariant 9), then a right one again.
    @Test func backgroundGapResettles() async throws {
        let sim = try Sim()
        let suspended = Locked(false)
        sim.onProgress = { [weak sim] progress, _ in
            guard progress.stage == .content, progress.total > 0,
                  Double(progress.completed) >= 0.3 * Double(progress.total),
                  suspended.withLock({ let was = $0; $0 = true; return !was }) else { return }
            sim?.suspend(.seconds(600))
        }
        let run = await sim.run("g background")
        sim.expectComplete(run)
        #expect(suspended.withLock { $0 })
        let late = sim.finishTimes.filter { entry in
            guard case .at(let date) = entry.shown, entry.end - entry.t < .seconds(400) else { return false }
            return abs(date.timeIntervalSince(SimClock.base.addingTimeInterval(entry.end.seconds))) > 120
        }
        #expect(late.isEmpty, "\(late.count) finish times more than 2 min off after the gap")
        sim.finish()
    }

    /// (h) P8: an empty library finishes without a finish time and without a count standing.
    @Test func emptyLibraryShowsNoTime() async throws {
        let sim = try Sim(scale: 0.05, empty: true)
        let run = await sim.run("h empty")
        sim.expectComplete(run)
        #expect(sim.finishTimes.isEmpty)
        #expect(run.progress.compactMap(\.workload).first?.photos == 0)
        sim.finish()
    }

    /// The workload is said exactly once per run, with the library's amounts; the bar's widths
    /// come from it. "Gerade angesehen" (in the analysis card's Details) never shows a
    /// screenshot (B4).
    @Test func workloadIsSaidOnceWithTheLibrarysAmounts() async throws {
        let sim = try Sim(scale: 0.2)
        let run = await sim.run("workload")
        sim.expectComplete(run)
        let workloads = run.progress.compactMap(\.workload)
        #expect(workloads.count == 1)
        let w = try #require(workloads.first)
        #expect(w.photos == sim.library.total)
        #expect(w.located == sim.library.located)
        #expect(w.screenshots == sim.library.screenshots)
        #expect(w.contentLeft == sim.library.total)
        #expect(w.textLeft == sim.library.screenshots)
        let screenshots = Set(sim.library.assets.filter(\.isScreenshotLike).map(\.id))
        let recent = run.progress.flatMap(\.recent)
        #expect(!recent.isEmpty)
        #expect(recent.allSatisfy { !screenshots.contains($0) })
        #expect(run.progress.allSatisfy { $0.recent.count <= 3 })
        // The second run has nothing left to look at.
        let again = await sim.run("workload again")
        let second = try #require(again.progress.compactMap(\.workload).first)
        #expect(second.contentLeft == 0 && second.textLeft == 0)
        sim.finish()
    }

    /// P16, point 3: the suggestions offered before the image analysis ("Schon fertig: …",
    /// "Ansehen") keep their ids in the final set, so a decision made on them stays.
    @Test func earlyProposalsKeepTheirIDs() async throws {
        let sim = try Sim(scale: 0.2)
        let paused = await sim.run("early", pause: .when(stage: .content, atLeast: 0.2))
        #expect(paused.report?.earlyProposals == true)
        let early = try #require(try await sim.pipeline.latestProposals())
        let earlyIDs = Set(early.proposals.filter { [.trips, .places, .frequentPlaces].contains($0.kind.area) }.map(\.id))
        #expect(!earlyIDs.isEmpty)
        let done = AlreadyDone.counts(proposals: early.proposals, step: .content)
        #expect(done.trips > 0 && done.places > 0, "\(done)")
        let rest = await sim.run("final")
        sim.expectComplete(rest)
        let final = try #require(try await sim.pipeline.latestProposals())
        let missing = earlyIDs.subtracting(final.proposals.map(\.id))
        #expect(missing.isEmpty, "\(missing.count) of \(earlyIDs.count) early suggestions are not in the final set")
        sim.finish()
    }

    /// Review I2: "Schon fertig" read the suggestions at the report that starts the image
    /// step, before the early ones were saved, and never again. Now one more report says when
    /// they are saved; at that report they are in the store. Only the first run says it.
    /// They are made beside the first photos (stress run 44116350940), so that report comes
    /// after the one that starts the step and repeats the newest count: never back, no jump.
    @Test func earlySuggestionsAreSaidOnceSaved() async throws {
        let sim = try Sim(scale: 0.2)
        let saidAt = Locked<[Int]>([])
        let paused = await sim.run("early", pause: .when(stage: .content, atLeast: 0.2))
        let events = paused.events.withLock { $0 }.compactMap { e -> PipelineProgress? in
            if case .progress(let p) = e.kind { return p } else { return nil }
        }
        for (i, p) in events.enumerated() where p.earlyProposals { saidAt.withLock { $0.append(i) } }
        let at = saidAt.withLock { $0 }
        #expect(at.count == 1, "said \(at.count) times")
        // After the report that starts the image step, with the count of the report before it.
        let begin = try #require(events.firstIndex { $0.stage == .content })
        if let i = at.first {
            #expect(i > begin)
            #expect(events[i].stage == .content && events[i - 1].stage == .content)
            #expect(events[i].completed == events[i - 1].completed && events[i].total == events[i - 1].total)
        }
        let early = try #require(try await sim.pipeline.latestProposals())
        #expect(early.isEarly)
        let rest = await sim.run("final")
        sim.expectComplete(rest)
        let laterSaid = rest.events.withLock { $0 }.contains { if case .progress(let p) = $0.kind { p.earlyProposals } else { false } }
        #expect(!laterSaid)
        #expect(try await sim.pipeline.latestProposals()?.isEarly == false)
        sim.finish()
    }

    /// Review minor: an early suggestion the full analysis no longer makes stays when the user
    /// already decided on it; one nobody decided on goes.
    @Test func decidedEarlySuggestionsStay() async throws {
        let sim = try Sim(scale: 0.2)
        _ = await sim.run("early", pause: .when(stage: .content, atLeast: 0.2))
        var early = try #require(try await sim.pipeline.latestProposals())
        let model = try #require(early.proposals.first { $0.kind.area == .trips })
        // Two suggestions the full set will not make (ids no engine gives).
        var decided = model; decided.id = AlbumistID("gone-decided")
        var open = model; open.id = AlbumistID("gone-open")
        early.proposals += [decided, open]
        try await sim.store.setValue(early, forKey: "analysis.proposals")
        let decisions: [AlbumistID: ProposalDecision] = [decided.id: .createNew(title: nil, folderPath: nil), open.id: .undecided]
        try await sim.store.setValue(decisions, forKey: "user.decisions")
        let rest = await sim.run("final")
        sim.expectComplete(rest)
        let final = try #require(try await sim.pipeline.latestProposals())
        let ids = Set(final.proposals.map(\.id))
        #expect(ids.contains(decided.id))
        #expect(!ids.contains(open.id))
        #expect(!final.isEarly)
        sim.finish()
    }

    // MARK: Focused checks of the engine fixes

    /// A wait for Apple's geocoder (its limit of about 40 lookups a minute, or a refusal) is
    /// said every 2 s with the time left, so the card can show it instead of a count that
    /// stands for up to a minute.
    @Test func geocoderWaitsAreAnnounced() async throws {
        let clock = SimClock()
        let geocoder = SimGeocoder(clock: clock, map: Self.map)
        geocoder.refuseCalls(45..<46)
        let requests: [PlaceResolutionService.Request] = (0..<60).map { i in
            .init(assetID: AssetID("w-\(i)"), coordinate: GeoCoordinate(latitude: 48 + Double(i) * 0.1, longitude: 11))
        }
        let service = PlaceResolutionService(map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
                                             policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german),
                                             time: clock.source)
        let seen = Locked<[(Duration, Duration?)]>([])
        _ = try await service.resolve(requests,
                                      progress: { _ in seen.withLock { $0.append((clock.now, nil)) } },
                                      waiting: { left in seen.withLock { $0.append((clock.now, left)) } }) { _ in }
        let events = seen.withLock { $0 }
        let gaps = zip(events, events.dropFirst()).map { $1.0 - $0.0 }
        #expect(gaps.allSatisfy { $0 <= .seconds(2) + SimCost.geocode }, "\(gaps.max() ?? .zero)")
        // The throttle's wait and the refusal's wait were both said, with the time left.
        #expect(events.contains { $0.1 != nil && $0.1! > .seconds(20) })
        #expect(clock.now > .seconds(60))
    }

    /// The overnight refinement seen in the app (second review of the no-wait fix, device test
    /// 18.11., build 36): its wait for Apple's limit is on the card with a countdown that never
    /// says less than is left and at most a report (2 s) and a tick more, it goes when the
    /// wait ends, and nothing stands still for more than 10 s without a reason.
    @Test func refinementCardSaysWhyItWaitsWithAnHonestCountdown() async throws {
        let sim = try Sim()
        let first = await sim.run("r1 run in the app")
        sim.expectComplete(first)
        let left = first.report?.placesPendingOnline ?? 0
        #expect(left > 0)
        let refined = await sim.run("r2 overnight refinement", mode: .refinement)
        #expect(refined.report?.isComplete == true)
        #expect((refined.report?.placesPendingOnline ?? 0) < left)
        // The refinement waited for Apple's limit (40 lookups a minute).
        #expect(refined.progress.contains { $0.waitLeft != nil })
        let card = sim.replayRefinementCard(refined)
        #expect(card.countdownTicks > 0)
        #expect(!card.countdownEverLess)
        #expect(card.worstCountdownLead <= .milliseconds(2_250), "\(card.worstCountdownLead)")
        #expect(card.longestStill <= .seconds(10), "\(card.longestStill)")
        #expect(card.last.waitLeft == nil)
        sim.finish()
    }

    /// Lookups left for a later run (budget, refusal, Pause) are not counted as done: the run
    /// that goes on starts where this one ended, not below.
    @Test func placesLeftForLaterAreNotCountedAsDone() async throws {
        let sim = try Sim(scale: 0.1)
        let first = await sim.run("places first")
        let last = try #require(first.last(.places))
        #expect(last.completed < last.total)
        let second = await sim.run("places again")
        #expect(second.first(.places)?.completed == last.completed)
        sim.finish()
    }

    /// The trip detection says that it begins: the card no longer stands at
    /// "Mediathek wird gelesen · N von N" while trips are computed.
    @Test func patternsSayWhenTheyBegin() async throws {
        let sim = try Sim(scale: 0.05)
        let run = await sim.run("patterns")
        let patterns = run.progress.filter { $0.stage == .patterns }
        #expect(patterns.first?.completed == 0)
        // Then the photos with a location as they are grouped (review of 11ef3e1, minor 3).
        #expect((patterns.last?.completed ?? 0) > 1)
        #expect(patterns.last?.completed == patterns.last?.total)
        #expect(Set(patterns.map(\.completed)).count >= 2)
    }

    /// The image analysis saves and reports at least once a second, also on a warm device
    /// (a break after every photo, half the lanes): before, 50 photos made one step of
    /// 13 s or more.
    @Test func contentCountMovesEverySecondOnAWarmDevice() async throws {
        let sim = try Sim(scale: 0.05)
        sim.conditions.plan.withLock { $0.steps = [(.zero, .gentle)] }
        let run = await sim.run("gentle")
        sim.expectComplete(run)
        let content = run.timeline.filter { if case .progress(let p) = $0.kind { return p.stage == .content } else { return false } }
        let gaps = zip(content, content.dropFirst()).map { $1.t - $0.t }
        #expect(gaps.allSatisfy { $0 <= .seconds(2) }, "\(gaps.max() ?? .zero)")
        sim.finish()
    }

    /// A run that goes on in the text stage shows the texts read so far at once, not "0" first
    /// (the bar went back below where the paused run had got to).
    @Test func resumedTextStageStartsWhereItStopped() async throws {
        let sim = try Sim(scale: 0.1)
        let paused = await sim.run("text paused", pause: .when(stage: .text, atLeast: 0.5))
        let last = try #require(paused.last(.text))
        let resumed = await sim.run("text resumed")
        let first = try #require(resumed.first(.text))
        #expect(first.completed >= last.completed && first.total == last.total, "\(first) after \(last)")
        sim.finish()
    }
}

// MARK: - Simulated device

typealias Stage = AnalysisPipeline.Stage
typealias PipelineProgress = AnalysisPipeline.Progress

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Device time per piece of work (an iPhone of the owner's kind). Content and text run in
/// lanes side by side; the simulated clock adds up the work, so each value is the time per
/// photo with all lanes busy (4 lanes à 0.4 s, 2 lanes à 1 s).
enum SimCost {
    /// 30 % slower than the usual times the finish time starts from (`AnalysisStep
    /// .secondsPerItem`: 0.1 s and 0.5 s), so the accuracy checks measure the device's speed
    /// being found, not constants that happen to match (review I4).
    static let content: Duration = .milliseconds(130)
    static let text: Duration = .milliseconds(650)
    static let geocode: Duration = .milliseconds(300)
    /// One photo's own time in a lane: what Pause may still wait for.
    static func item(_ stage: Stage?) -> Duration {
        switch stage {
        case .places: geocode
        case .content: content * 4
        case .text: text * 2
        default: .zero
        }
    }
}

/// Simulated clock: sleeping and work advance it at once; hooks see every step.
final class SimClock: @unchecked Sendable {
    private let state = Locked<Duration>(.zero)
    private let hooks = Locked<[@Sendable (Duration) -> Void]>([])
    static let base = Fixture.date("2026-11-15 08:00")

    var now: Duration { state.withLock { $0 } }
    var date: Date { Self.base.addingTimeInterval(now.seconds) }

    func advance(_ d: Duration) {
        let t = state.withLock { $0 += d; return $0 }
        for hook in hooks.withLock({ $0 }) { hook(t) }
    }

    func onTick(_ hook: @escaping @Sendable (Duration) -> Void) { hooks.withLock { $0.append(hook) } }

    /// iOS holds the app: time passes without any work and without the hooks.
    func jump(_ d: Duration) { state.withLock { $0 += d } }

    var source: TimeSource { TimeSource(elapsed: { self.now }, sleep: { self.advance($0) }) }
}

extension Sim {
    /// Logs a suspension in the run in progress and lets the time pass.
    func suspend(_ d: Duration) {
        currentLog?.add(.suspended(d), at: clock.now)
        clock.jump(d)
    }
}

/// The device's pace: `steps` (time after `anchor`, pace from then on); normal before.
final class SimConditions: AnalysisConditions, @unchecked Sendable {
    struct Plan: Sendable {
        var anchor: Duration? = .zero
        var steps: [(after: Duration, pace: AnalysisPace)] = []
    }
    let clock: SimClock
    let plan = Locked(Plan())
    init(clock: SimClock) { self.clock = clock }
    func pauseReason() async -> PauseReason? { nil }
    func pace() async -> AnalysisPace {
        let now = clock.now
        return plan.withLock { plan in
            guard let anchor = plan.anchor else { return .normal }
            return plan.steps.last { now - anchor >= $0.after }?.pace ?? .normal
        }
    }
    func isOnWiFi() async -> Bool { true }
}

/// Apple's geocoder: 0.3 s per lookup, refuses the calls in `refused` (rate limit).
final class SimGeocoder: ReverseGeocoding, @unchecked Sendable {
    let clock: SimClock
    let map: OfflineWorldMap
    let calls = Locked(0)
    let refusals = Locked<[Duration]>([])
    private let refused = Locked<Range<Int>>(0..<0)
    var onCall: (@Sendable (Stage) -> Void)?

    init(clock: SimClock, map: OfflineWorldMap) {
        self.clock = clock
        self.map = map
    }

    func refuseCalls(_ range: Range<Int>) { refused.withLock { $0 = range } }

    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        onCall?(.places)
        clock.advance(SimCost.geocode)
        let n = calls.withLock { $0 += 1; return $0 - 1 }
        if refused.withLock({ $0.contains(n) }) {
            refusals.withLock { $0.append(clock.now) }
            throw GeocodingError.rateLimited(retryAfter: nil)
        }
        let destination = SimLibrary.destinations.min { GeoMath.distance($0.coordinate, coordinate) < GeoMath.distance($1.coordinate, coordinate) }!
        let code = map.lookup(coordinate).country.map { String($0.isoCode.prefix(2)) }
        return PlaceComponents(isoCountryCode: code, locality: "\(destination.name) \(Int(coordinate.latitude * 20))/\(Int(coordinate.longitude * 20))",
                               timeZoneIdentifier: destination.zone)
    }
}

final class SimAnalyzer: ContentAnalyzing, @unchecked Sendable {
    let clock: SimClock
    let contentCalls = Locked(0)
    var onCall: (@Sendable (Stage) -> Void)?
    init(clock: SimClock) { self.clock = clock }

    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        onCall?(.content)
        contentCalls.withLock { $0 += 1 }
        clock.advance(SimCost.content)
        let labels = asset.isScreenshotLike ? [LabelScore("document", 0.3)] : [LabelScore(asset.id.rawValue.hasSuffix("3") ? "dog" : "outdoor", 0.8)]
        return ContentAnalysis(labels: labels, source: .localPreview)
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        onCall?(.text)
        clock.advance(SimCost.text)
        let text = asset.id.rawValue.hasSuffix("1") ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung" : "Akku 80 % Einstellungen WLAN"
        return TextAnalysis(text: text, source: .original)
    }
}

/// The owner's library, scaled: 5,683 items over 3.5 years, ~1,040 screenshots, 103 trips to
/// 19 countries, ~1,600 photos with a location (trips and some at home), the rest at home
/// without a location.
struct SimLibrary {
    struct Destination { var name: String; var coordinate: GeoCoordinate; var zone: String }
    static let destinations: [Destination] = [
        .init(name: "Rom", coordinate: Fixture.Places.rome, zone: "Europe/Rome"),
        .init(name: "Paris", coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522), zone: "Europe/Paris"),
        .init(name: "Barcelona", coordinate: GeoCoordinate(latitude: 41.3874, longitude: 2.1686), zone: "Europe/Madrid"),
        .init(name: "Lissabon", coordinate: GeoCoordinate(latitude: 38.7223, longitude: -9.1393), zone: "Europe/Lisbon"),
        .init(name: "New York", coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060), zone: "America/New_York"),
        .init(name: "Tokio", coordinate: GeoCoordinate(latitude: 35.6762, longitude: 139.6503), zone: "Asia/Tokyo"),
        .init(name: "Reykjavík", coordinate: GeoCoordinate(latitude: 64.1466, longitude: -21.9426), zone: "Atlantic/Reykjavik"),
        .init(name: "Athen", coordinate: GeoCoordinate(latitude: 37.9838, longitude: 23.7275), zone: "Europe/Athens"),
        .init(name: "Sydney", coordinate: Fixture.Places.sydney, zone: "Australia/Sydney"),
        .init(name: "Wien", coordinate: GeoCoordinate(latitude: 48.2082, longitude: 16.3738), zone: "Europe/Vienna"),
        .init(name: "Prag", coordinate: GeoCoordinate(latitude: 50.0755, longitude: 14.4378), zone: "Europe/Prague"),
        .init(name: "Amsterdam", coordinate: GeoCoordinate(latitude: 52.3676, longitude: 4.9041), zone: "Europe/Amsterdam"),
        .init(name: "London", coordinate: GeoCoordinate(latitude: 51.5072, longitude: -0.1276), zone: "Europe/London"),
        .init(name: "Kopenhagen", coordinate: GeoCoordinate(latitude: 55.6761, longitude: 12.5683), zone: "Europe/Copenhagen"),
        .init(name: "Luzern", coordinate: GeoCoordinate(latitude: 47.0502, longitude: 8.3093), zone: "Europe/Zurich"),
        .init(name: "Budapest", coordinate: GeoCoordinate(latitude: 47.4979, longitude: 19.0402), zone: "Europe/Budapest"),
        .init(name: "Split", coordinate: GeoCoordinate(latitude: 43.5081, longitude: 16.4402), zone: "Europe/Zagreb"),
        .init(name: "Istanbul", coordinate: GeoCoordinate(latitude: 41.0082, longitude: 28.9784), zone: "Europe/Istanbul"),
        .init(name: "Hamburg", coordinate: GeoCoordinate(latitude: 53.5511, longitude: 9.9937), zone: "Europe/Berlin"),
    ]

    var assets: [AssetSnapshot]
    var total: Int { assets.count }
    var screenshots: Int
    var located: Int
    var trips: Int

    init(scale: Double) {
        func scaled(_ n: Int) -> Int { max(1, Int((Double(n) * scale).rounded())) }
        let trips = scaled(103), perTrip = 12
        let screenshots = scaled(1_040)
        let homeLocated = scaled(1_600) - trips * perTrip
        let home = scaled(5_683) - screenshots - trips * perTrip
        let start = Fixture.date("2023-05-01"), days = 1_290
        var lib = LibraryBuilder()
        // Trips: 2–3 days every ~12 days, 12 photos spread over towns around the destination.
        var tripDays = Set<Int>()
        for i in 0..<trips {
            let first = 5 + i * (days - 10) / trips
            let length = 2 + i % 2
            let destination = Self.destinations[(i * 7) % Self.destinations.count]
            for p in 0..<perTrip {
                let day = first + p * length / perTrip
                tripDays.insert(day)
                let date = start.addingTimeInterval(Double(day) * 86_400 + 9 * 3_600 + Double(p) * 1_500)
                _ = lib.photo(at: date, destination.coordinate, jitterMeters: 8_000)
            }
        }
        // Everyday life at home: every ninth-ish photo has a location.
        let homeDays = (0..<days).filter { !tripDays.contains($0) }
        for i in 0..<home {
            let day = homeDays[i * homeDays.count / home]
            let date = start.addingTimeInterval(Double(day) * 86_400 + 12 * 3_600 + Double(i % 7) * 1_800)
            let located = homeLocated > 0 && i % max(1, home / homeLocated) == 0
            _ = lib.photo(at: date, located ? Fixture.Places.munichHome : nil, jitterMeters: 3_000)
        }
        for i in 0..<screenshots {
            let date = start.addingTimeInterval(Double(i * days / screenshots) * 86_400 + 20 * 3_600)
            _ = lib.photo(at: date, nil, subtypes: .screenshot)
        }
        // Some saved pictures carry no date at all (the image analysis takes them last).
        var assets = lib.assets
        for i in stride(from: 7, to: assets.count, by: 200) where assets[i].location == nil && !assets[i].isScreenshotLike {
            assets[i].creationDate = nil
        }
        self.assets = assets
        self.screenshots = screenshots
        self.located = lib.assets.filter { $0.usableLocation != nil }.count
        self.trips = trips
    }
}

// MARK: - Recording

struct SimEvent: Sendable {
    enum Kind: Sendable {
        case progress(PipelineProgress)
        case waiting(PauseReason?)
        case pauseRequested
        case work(Stage)
        /// iOS held the app (background without the continued task): the clock jumps, nothing
        /// is reported meanwhile.
        case suspended(Duration)
    }
    var t: Duration
    var wall: ContinuousClock.Instant
    var kind: Kind
}

final class RunLog: @unchecked Sendable {
    let label: String
    let events = Locked<[SimEvent]>([])
    var start: Duration = .zero
    var end: Duration = .zero
    var report: AnalysisPipeline.Report?
    var error: (any Error)?

    init(label: String) { self.label = label }

    func add(_ kind: SimEvent.Kind, at t: Duration) {
        events.withLock { $0.append(SimEvent(t: t, wall: .now, kind: kind)) }
    }

    var timeline: [SimEvent] { events.withLock { $0 } }
    var progress: [PipelineProgress] {
        timeline.compactMap { if case .progress(let p) = $0.kind { p } else { nil } }
    }
    var waits: [PauseReason?] {
        timeline.compactMap { if case .waiting(let w) = $0.kind { .some(w) } else { nil } }
    }
    var stagesShown: [Stage] {
        progress.reduce(into: [Stage]()) { if $0.last != $1.stage { $0.append($1.stage) } }
    }
    var lastStage: Stage? { progress.last?.stage }
    func first(_ stage: Stage) -> PipelineProgress? { progress.first { $0.stage == stage } }
    func last(_ stage: Stage) -> PipelineProgress? { progress.last { $0.stage == stage } }
    var pauseTime: Duration? {
        timeline.first { if case .pauseRequested = $0.kind { true } else { false } }?.t
    }
}

/// The app's `AnalysisMarker.Point`, as the simulator keeps it between runs.
struct SimMarker {
    var stage: Int
    var completed: Int?
    var overall: Double
    var widths: StepWidths?
    var left: Int?
    var photos: Int?
    var version: String
    var newWork: ResumedRun.NewWork?
    var secondsLeft: Double?
    var caughtUp: Double?
}

// MARK: - Harness

enum PauseTrigger: Sendable {
    case when(stage: Stage, atLeast: Double)
    /// Once Apple's geocoder was asked this many times.
    case whenGeocoderCalled(Int)
}

enum PauseAction: Sendable { case pause, cancel }

final class Sim: @unchecked Sendable {
    let clock = SimClock()
    let library: SimLibrary
    let store: AlbumistStore
    let reader: InMemoryLibraryReader
    let analyzer: SimAnalyzer
    let geocoder: SimGeocoder
    let conditions: SimConditions
    private(set) var pipeline: AnalysisPipeline!
    var runs: [RunLog] = []
    /// The run before, of the same analysis (cleared by "Analyse neu aufbauen").
    private var previous: [RunLog] = []
    /// The number the card showed last in this analysis (pause and resume included; a phase
    /// of its own starts it again).
    private var lastShown: Double = 0
    /// The app's `AnalysisMarker.unfinished`: where the analysis got to, with its widths once
    /// they are known (kept over Pause and a restart: S6). A run that goes on starts from it.
    private var marker: SimMarker?
    /// Where runs that went on passed the position the run before stopped at: the value then,
    /// the held value, and the real value under the widths (review of 11ef3e1).
    private(set) var passes: [(run: String, shown: Double, floor: Double, real: Double)] = []
    /// Phases of their own that runs started, with their label.
    private(set) var phases: [(run: String, cause: ResumedRun.NewWork)] = []
    /// Every value the card's number showed (run, time, value), and the bar drawn then.
    private(set) var shownValues: [(run: String, t: Duration, value: Double)] = []
    private(set) var shownBars: [(run: String, t: Duration, bar: Double)] = []
    /// The step each of `shownValues` was shown in.
    private(set) var shownSteps: [Stage] = []
    /// The bar the card drew last, as a value and as the six segments' fills.
    private var lastShownBar: Double = 0
    private var lastFills: [Double] = []
    /// Every finish time the card showed: (simulated time, what it said, the run's real end).
    var finishTimes: [(run: String, t: Duration, shown: FinishEstimate, end: Duration, complete: Bool)] = []
    var violations: [String] = []
    var onProgress: (@Sendable (PipelineProgress, Duration) -> Void)?
    private let current = Locked<RunLog?>(nil)
    var currentLog: RunLog? { current.withLock { $0 } }
    /// The Pause (or the end of the app) planned for the run in progress. Data, not closures:
    /// a closure kept in a Mutex and called on every tick slowed the simulation down many times.
    private struct Armed: @unchecked Sendable {
        var trigger: PauseTrigger
        var action: PauseAction
        var control: AnalysisRunControl
        var task: Task<AnalysisPipeline.Report, any Error>?
    }
    private let armed = Locked<Armed?>(nil)
    private let wallStart = ContinuousClock.now

    init(scale: Double = FullRunDisplayTests.scale, empty: Bool = false) throws {
        library = SimLibrary(scale: scale)
        store = try AlbumistStore(url: nil)
        reader = InMemoryLibraryReader(assets: empty ? [] : library.assets)
        analyzer = SimAnalyzer(clock: clock)
        geocoder = SimGeocoder(clock: clock, map: FullRunDisplayTests.map)
        conditions = SimConditions(clock: clock)
        let clock = self.clock
        let work: @Sendable (Stage) -> Void = { [weak self] stage in self?.current.withLock { $0 }?.add(.work(stage), at: clock.now) }
        analyzer.onCall = work
        geocoder.onCall = work
        clock.onTick { [weak self] t in self?.fire(t, nil) }
        restartPipeline()
    }

    /// A new pipeline on the same store (the app was ended and opened again).
    func restartPipeline() {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let clock = self.clock
        // As in AppModel.bootstrap: online budget 60, 4 lanes for images, 2 for texts, batches of 50.
        pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: FullRunDisplayTests.map,
            conditions: conditions, settings: settings, calendar: Fixture.calendar, time: clock.source,
            foregroundOnlineBudget: 60, contentLanes: 4, textLanes: 2, now: { clock.date },
            // The simulated time runs far ahead of real time: a Pause at 20 % of the image step
            // comes a few real milliseconds after it begins, and the early set it checks would
            // depend on the test machine's load. The real half second is tested in ImageStepStartTests.
            earlyGraceOnStop: .seconds(60)
        )
    }

    /// Photos come in between runs (copies of the library's everyday photos under new ids).
    func addPhotos(_ count: Int) async {
        var assets = await reader.assets
        let everyday = library.assets.filter { !$0.isScreenshotLike && $0.creationDate != nil }
        for i in 0..<count {
            var copy = everyday[i % everyday.count]
            copy.id = AssetID("added-\(assets.count)-\(i)")
            copy.creationDate = copy.creationDate?.addingTimeInterval(60)
            assets.append(copy)
        }
        await reader.set(assets: assets)
    }

    /// The longest stretch of the run `label` in which the card stood still: the number on
    /// whole percent did not change and the bar did not move by 0.2 % (invariant 8's measure,
    /// without its exceptions for waiting).
    /// `in`: only the time the card showed that stage (from its first report to the next
    /// stage's first).
    func longestStill(_ label: String, in stage: Stage? = nil) -> Duration {
        let indices = shownValues.indices.filter { shownValues[$0].run == label }
        var kept = indices
        if let stage {
            // Up to and with the next stage's first report: the time until it counts too.
            guard let first = indices.first(where: { shownSteps[$0] == stage }) else { return .zero }
            let end = indices.first { $0 > first && shownSteps[$0] != stage } ?? indices.last ?? first
            kept = indices.filter { $0 >= first && $0 <= end }
        }
        let values = kept.map { shownValues[$0] }
        let bars = kept.map { shownBars[$0] }
        var longest: Duration = .zero
        var since: Duration?
        var percentThen: Int?
        var barThen = 0.0
        for (v, b) in zip(values, bars) {
            let percent = AnalysisPercent.percent(v.value, isComplete: false)
            if since == nil || percent != percentThen || b.bar - barThen >= 0.002 {
                since = v.t
                percentThen = percent
                barThen = b.bar
            } else if let since {
                longest = max(longest, v.t - since)
            }
        }
        return longest
    }

    /// What the card showed during a refinement (`RefinementCard`, as `AppModel.refinePass`
    /// feeds it): its events into the mailbox in order, a tick every 250 ms.
    struct RefinementReplay {
        /// Ticks that showed the countdown of a wait for Apple.
        var countdownTicks = 0
        /// The longest stretch in which nothing on the card changed (count, step, countdown,
        /// the bar by 0.2 %) and it said no reason (a wait for Apple or for the device).
        var longestStill: Duration = .zero
        /// How much more the countdown said than was really left (never less: checked).
        var worstCountdownLead: Duration = .zero
        var countdownEverLess = false
        var last = RefinementCard.Shown()
    }

    func replayRefinementCard(_ run: RunLog) -> RefinementReplay {
        let base = ContinuousClock.now
        let timeline = run.timeline
        // When a wait for Apple really ended: the first report after the one that showed it
        // that says it is over (or the end of the run).
        func waitEnd(after index: Int) -> Duration {
            for e in timeline[(index + 1)...] {
                if case .progress(let p) = e.kind, p.waitLeft == nil { return e.t }
            }
            return run.end
        }
        let mailbox = ProgressMailbox()
        var card = RefinementCard()
        var result = RefinementReplay()
        var next = 0
        var t = run.start
        var lastChange = run.start
        var lastKey = ""
        var barAtChange = 0.0
        var reported: Int?
        while t <= run.end + .milliseconds(250) {
            while next < timeline.count, timeline[next].t <= t {
                switch timeline[next].kind {
                case .progress(let p):
                    mailbox.post(p)
                    reported = p.waitLeft != nil ? next : nil
                case .waiting(let w): mailbox.wait(w)
                default: break
                }
                next += 1
            }
            let shown = card.take(mailbox.take(), at: base.advanced(by: t), gliding: true)
            if let left = shown.waitLeft, let reported {
                result.countdownTicks += 1
                let real = waitEnd(after: reported) - t
                if left < real - .milliseconds(1) { result.countdownEverLess = true }
                result.worstCountdownLead = max(result.worstCountdownLead, left - real)
            }
            let key = "\(String(describing: shown.stage)) \(shown.completed)/\(shown.total) \(String(describing: shown.countdown)) \(String(describing: shown.waiting))"
            if key != lastKey || shown.bar - barAtChange >= 0.002 || shown.waitLeft != nil || shown.waiting != nil {
                lastKey = key
                barAtChange = shown.bar
                lastChange = t
            } else {
                result.longestStill = max(result.longestStill, t - lastChange)
            }
            result.last = shown
            t += .milliseconds(250)
        }
        return result
    }

    /// An update that changed the image analysis: every photo is to be looked at again, and
    /// the marker was written by the version before.
    func updateChangesTheAnalysis() async throws {
        let ids = try await store.allAssets().map(\.id)
        try await store.markAnalyzed(ids, version: 0)
        marker?.version = "0.0"
        countsStartAgain = true
    }

    /// The next run's counts start again (an update asks for every photo again): not compared
    /// with where the run before ended.
    private var countsStartAgain = false

    /// "Analyse neu aufbauen": the next run is a full one again (AnalysisMarker.reset()).
    func newAnalysis() {
        previous = []
        lastShown = 0
        marker = nil
        lastShownBar = 0
        lastFills = []
    }

    private func fire(_ t: Duration, _ progress: PipelineProgress?) {
        guard let hit = armed.withLock({ armed -> Armed? in
            guard let current = armed else { return nil }
            let due: Bool
            switch current.trigger {
            case .when(let stage, let share):
                guard let p = progress, p.stage == stage, p.total > 0 else { return nil }
                due = Double(p.completed) >= share * Double(p.total)
            case .whenGeocoderCalled(let calls):
                due = geocoder.calls.withLock { $0 } >= calls
            }
            guard due, current.action == .pause || current.task != nil else { return nil }
            armed = nil
            return current
        }) else { return }
        current.withLock { $0 }?.add(.pauseRequested, at: t)
        switch hit.action {
        case .pause: hit.control.pause()
        case .cancel: hit.task?.cancel()
        }
    }

    /// `mode`: `.refinement` runs the overnight refinement; its card is checked by
    /// `replayRefinementCard`, not by the rules of a run in the app, and it leaves the analysis
    /// it follows as it was (the marker, the number shown).
    @discardableResult
    func run(_ label: String, mode: AnalysisPipeline.Mode = .incremental, pause: PauseTrigger? = nil,
             action: PauseAction = .pause) async -> RunLog {
        let log = RunLog(label: label)
        current.withLock { $0 = log }
        let control = AnalysisRunControl()
        let pipeline = self.pipeline!
        let clock = self.clock
        let onProgress = self.onProgress
        if let pause { armed.withLock { $0 = Armed(trigger: pause, action: action, control: control) } }
        log.start = clock.now
        let task = Task {
            try await pipeline.run(mode: mode, control: control, onProgress: { [weak self] progress in
                let t = clock.now
                log.add(.progress(progress), at: t)
                onProgress?(progress, t)
                self?.fire(t, progress)
            }, onWaiting: { reason in
                log.add(.waiting(reason), at: clock.now)
            })
        }
        armed.withLock { $0?.task = task }
        do {
            log.report = try await task.value
        } catch {
            log.error = error
        }
        log.end = clock.now
        armed.withLock { $0 = nil }
        current.withLock { $0 = nil }
        if mode == .refinement {
            runs.append(log)
            return log
        }
        check(log)
        checkCard(log)
        countsStartAgain = false
        runs.append(log)
        previous.append(log)
        if log.report?.isComplete == true {
            lastShown = 0
            marker = nil
            lastShownBar = 0
            lastFills = []
        }
        return log
    }

    func expectComplete(_ run: RunLog, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(run.report?.isComplete == true, "\(run.label): \(String(describing: run.report?.pausedBecause)) \(String(describing: run.error))", sourceLocation: sourceLocation)
    }

    /// Fails the test with every violation found in all runs, and prints the run times.
    func finish(sourceLocation: SourceLocation = #_sourceLocation) {
        for run in runs {
            let wall = run.timeline.last.map { ($0.wall - wallStart).seconds } ?? 0
            let starts = run.timeline.reduce(into: [(Stage, ContinuousClock.Instant)]()) { acc, e in
                if case .progress(let p) = e.kind, acc.last?.0 != p.stage { acc.append((p.stage, e.wall)) }
            }
            let perStage = zip(starts, starts.dropFirst()).map { "\($0.0) \(String(format: "%.2f", ($1.1 - $0.1).seconds))" }
            let tl = run.timeline
            let worst = zip(tl, tl.dropFirst()).max { ($0.1.wall - $0.0.wall) < ($1.1.wall - $1.0.wall) }
            if let worst { print("SIM \(run.label) longest wall gap \(String(format: "%.3f", (worst.1.wall - worst.0.wall).seconds)) s: \(describe(worst.0.kind)) → \(describe(worst.1.kind)) at t=\(worst.0.t.seconds)") }
            print("SIM \(run.label) wall per stage: \(perStage.joined(separator: ", "))")
            print("SIM \(run.label): \(String(format: "%.0f", (run.end - run.start).seconds)) s simulated, \(run.progress.count) progress events, ended \(run.report?.isComplete == true ? "complete" : String(describing: run.report?.pausedBecause)) (wall \(String(format: "%.2f", wall)) s)")
        }
        let longestCPU = runs.flatMap { run in
            zip(run.timeline, run.timeline.dropFirst()).compactMap { a, b -> (Double, String)? in
                guard a.t == b.t else { return nil }
                return ((b.wall - a.wall).seconds, "\(run.label) \(describe(a.kind)) → \(describe(b.kind))")
            }
        }.max { $0.0 < $1.0 }
        if let longestCPU { print("SIM longest stretch without simulated time (CPU on Linux): \(String(format: "%.3f", longestCPU.0)) s, \(longestCPU.1)") }
        // How far the finish times were off, for complete runs (minutes, by time left).
        for run in runs where run.report?.isComplete == true {
            let errors = finishErrors(run.label)
            if let worst = errors.max(by: { abs($0.off) < abs($1.off) }) {
                print("SIM \(run.label) finish times: \(errors.count) shown, worst \(Int(worst.off)) s off with \(Int(worst.left)) s left, first with \(Int(errors.first!.left)) s left")
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: "\(violations.count) display violations:\n" + violations.prefix(40).joined(separator: "\n")), sourceLocation: sourceLocation)
    }

    private func describe(_ kind: SimEvent.Kind) -> String {
        switch kind {
        case .progress(let p): "\(p.stage) \(p.completed)/\(p.total)\(p.waitLeft.map { " waiting \(Int($0.seconds)) s" } ?? "")"
        case .waiting(let w): "waiting \(w.map(\.rawValue) ?? "over")"
        case .pauseRequested: "Pause"
        case .work(let s): "work \(s)"
        case .suspended(let d): "suspended \(Int(d.seconds)) s"
        }
    }

    private func fail(_ run: RunLog, _ invariant: Int, _ text: String, at t: Duration) {
        violations.append("[\(run.label)] invariant \(invariant) at t=\(String(format: "%.1f", t.seconds)) s: \(text)")
    }

    // MARK: Invariants

    private func check(_ run: RunLog) {
        let timeline = run.timeline
        let maxGap: Duration = .seconds(2)

        // 7. Ends complete or with a reason, never silently.
        if run.report == nil {
            fail(run, 7, "the run ended with an error instead of a reason: \(String(describing: run.error))", at: run.end)
        } else if run.report?.isComplete != true, run.report?.pausedBecause == nil {
            fail(run, 7, "the run ended neither complete nor with a reason (stages \(run.report!.completedStages))", at: run.end)
        }

        // 1. Stage order, and each stage says it begins before its work.
        var announced = Set<Stage>()
        var stageNow: Stage?
        for event in timeline {
            switch event.kind {
            case .progress(let p):
                if let stageNow, p.stage.number < stageNow.number {
                    fail(run, 1, "stage \(p.stage) shown after \(stageNow)", at: event.t)
                }
                if !announced.contains(p.stage), p.total > 0, p.completed >= p.total, [.patterns, .groups].contains(p.stage) {
                    fail(run, 1, "\(p.stage) first shown when done (\(p.completed)/\(p.total)): its work ran under the stage before", at: event.t)
                }
                announced.insert(p.stage)
                stageNow = p.stage
            case .work(let stage):
                if !announced.contains(stage) {
                    fail(run, 1, "\(stage) works before it says that it begins (card shows \(stageNow.map { "\($0)" } ?? "nothing"))", at: event.t)
                    announced.insert(stage)
                }
            default: break
            }
        }
        if run.report?.isComplete == true {
            let hasPlaces = run.first(.places) != nil || timeline.contains { if case .work(.places) = $0.kind { true } else { false } }
            let expected = Stage.allCases.filter { $0 != .places || hasPlaces }
            if run.stagesShown != expected { fail(run, 1, "complete run showed stages \(run.stagesShown)", at: run.end) }
        }

        // 2. Counts within a stage; and against where the run before ended.
        var lastOf: [Stage: PipelineProgress] = [:]
        var rawOverall = 0.0
        for event in timeline {
            guard case .progress(let p) = event.kind else { continue }
            if p.completed > p.total { fail(run, 2, "\(p.stage) \(p.completed) von \(p.total): above the total", at: event.t) }
            if let last = lastOf[p.stage] {
                if p.completed < last.completed { fail(run, 2, "\(p.stage) went back from \(last.completed) to \(p.completed) (von \(p.total))", at: event.t) }
                if p.total != last.total, last.total != 0 { fail(run, 2, "\(p.stage) total changed from \(last.total) to \(p.total)", at: event.t) }
            } else if !countsStartAgain, [.places, .content, .text].contains(p.stage),
                      let before = previous.last(where: { $0.last(p.stage) != nil })?.last(p.stage), before.total == p.total, p.completed < before.completed {
                // Counts that persist across runs (the other steps are computed anew each run).
                fail(run, 2, "\(p.stage) starts at \(p.completed) von \(p.total), below where the run before ended (\(before.completed))", at: event.t)
            }
            lastOf[p.stage] = p
            // 3. The bar: never back within a run, nor below the paused run's while going on.
            let overall = PipelineProgress.overall(stage: p.stage, completed: p.completed, total: p.total)
            if overall + 1e-9 < rawOverall {
                fail(run, 3, "overall went back from \(pct(rawOverall)) to \(pct(overall)) at \(p.stage) \(p.completed)/\(p.total)", at: event.t)
            }
            rawOverall = max(rawOverall, overall)
        }

        // 4. No silent stretch while working; 5. no "N von N" while the stage still works.
        let pause = run.pauseTime
        let points: [(t: Duration, kind: SimEvent.Kind?)] = [(run.start, nil)]
            + timeline.filter { if case .work = $0.kind { false } else { true } }.map { ($0.t, $0.kind) }
            + [(run.end, nil)]
        var waiting = false
        var waitedWhileFull = false
        var shown: PipelineProgress?
        var fullSince: Duration?
        func leaveFull(at t: Duration) {
            defer { fullSince = nil; waitedWhileFull = false }
            guard let since = fullSince, let shown, !waitedWhileFull else { return }
            let until = min(t, pause ?? t)
            if until - since > maxGap {
                fail(run, 5, "\(shown.stage) stood at \(shown.completed) von \(shown.total) for \(String(format: "%.1f", (until - since).seconds)) s while the run went on", at: since)
            }
        }
        for (index, point) in points.enumerated() {
            if index > 0 {
                let before = points[index - 1]
                let afterPause = pause.map { before.t >= $0 } ?? false
                let suspended = if case .suspended? = before.kind { true } else { false }
                if point.t - before.t > maxGap, !waiting, !afterPause, !suspended {
                    fail(run, 4, "\(String(format: "%.1f", (point.t - before.t).seconds)) s without a progress event, card shows \(shown.map { "\($0.stage) \($0.completed)/\($0.total)" } ?? "nothing")", at: before.t)
                }
            }
            switch point.kind {
            case .progress(let p)?:
                if p.stage != shown?.stage { leaveFull(at: point.t) }
                shown = p
                if p.total > 0, p.completed >= p.total {
                    fullSince = fullSince ?? point.t
                } else {
                    fullSince = nil
                }
            case .waiting(let w)?:
                waiting = w != nil
                if waiting { waitedWhileFull = true }
            case nil where index > 0:
                // The run ended: the last suggestions count stands, that is the result.
                if shown?.stage != .proposals { leaveFull(at: point.t) }
            default:
                break
            }
        }

        // 11. A run in the app never waits for Apple's geocoder (device test 18.11., build 36:
        //     "Apple antwortet gleich" for 20–30 s while the count stood still). Only the
        //     overnight refinement may wait; every run here is a run in the app.
        if let wait = timeline.first(where: { if case .progress(let p) = $0.kind { p.waitLeft != nil } else { false } }) {
            fail(run, 11, "the run waited for Apple's geocoder (\(describe(wait.kind)))", at: wait.t)
        }

        // 6. Pause ends the run within one item plus 2 s.
        if let pause {
            let stage = timeline.last { if case .progress = $0.kind { $0.t <= pause } else { false } }.flatMap { e -> Stage? in
                if case .progress(let p) = e.kind { p.stage } else { nil }
            }
            let limit = SimCost.item(stage) + maxGap
            if run.end - pause > limit {
                fail(run, 6, "Pause in \(stage.map { "\($0)" } ?? "?") took \(String(format: "%.1f", (run.end - pause).seconds)) s (limit \(String(format: "%.1f", limit.seconds)) s)", at: pause)
            }
        }
    }

    private func pct(_ x: Double) -> String { String(format: "%.2f %%", x * 100) }

    /// The card as the app computes it on its 250 ms tick (AppModel.tick): the six-step bar with
    /// the widths of this analysis, the gliding bar, the finish time (`ProgressEstimator`).
    /// 3b. The drawn bar never goes back, also over Pause and restarts; never more than 1 % of a
    ///     step ahead of the real value.
    /// 8.  While the run works, something on the card changes at least every 10 s: the count,
    ///     the countdown of a wait for Apple, or the gliding bar (limit set by the product owner,
    ///     15.11.).
    /// 9.  No finish time while the run waits or after Pause; "Gleich fertig" only in the last
    ///     3 minutes (checked against the real end in `finish`).
    /// Each clock time the card showed in the run `label`: seconds left then, and how far it
    /// was off the real end (positive: too late). "Gleich fertig" is not a clock time.
    func finishErrors(_ label: String) -> [(left: Double, off: Double)] {
        finishTimes.filter { $0.run == label }.compactMap { entry in
            guard case .at(let date) = entry.shown else { return nil }
            let realEnd = SimClock.base.addingTimeInterval(entry.end.seconds)
            return ((entry.end - entry.t).seconds, date.timeIntervalSince(realEnd))
        }
    }

    private func checkCard(_ run: RunLog) {
        let base = ContinuousClock.now
        func instant(_ t: Duration) -> ContinuousClock.Instant { base.advanced(by: t) }
        func wall(_ t: Duration) -> Date { SimClock.base.addingTimeInterval(t.seconds) }
        var estimator = ProgressEstimator()
        // As AppModel.startAnalysis and beginCard: the widths of the analysis this run goes on
        // with, and the bar from where it was drawn last.
        let resumeFrom = marker
        var w = resumeFrom?.widths ?? .standard
        var widthsFixed = resumeFrom?.widths != nil
        // As AppModel.startAnalysis: a run that goes on (`ResumedRun`, reviews of 83db832 and
        // 11ef3e1): held until it passes where the run before stopped, then on from there;
        // much more work starts a phase of its own.
        var resumed = resumeFrom.map {
            ResumedRun(stage: $0.stage, completed: $0.completed, shown: $0.overall, left: $0.left, photos: $0.photos,
                       seconds: $0.secondsLeft, updated: $0.version != AnalysisPipeline.analysisVersion, newWork: $0.newWork,
                       caughtUp: $0.caughtUp)
        }
        // As AppModel.tick: the time the run worked (not waiting, paused or held), for the time
        // share of a run that goes on (`ResumedRun.spend`).
        var active = 0.0
        var lastT = run.start
        // What the card's title says (AnalysisProgressCard.title): a phase's label, "Macht da
        // weiter", or the step. The number may start again only together with a new title.
        var title = ""
        var phaseStartedNow = false
        var workload: AnalysisWorkload?
        var libraryPhotos: Int?
        var glide = BarGlide()
        if resumeFrom != nil {
            glide.reset(keeping: lastShownBar)
        } else {
            lastShownBar = 0
            lastFills = []
        }
        var step: AnalysisStep?
        var waiting = false
        var paused = false
        var lastChange: Duration = run.start
        // What the card shows (rule: nothing stands still for more than 10 s while work goes
        // on): the count or the step's name, the finish time, the bar, Apple's wait spinner.
        var lastText: String?
        var lastPercent: Int?
        var lastCountdown: Int?
        var lastFinishShown: FinishEstimate?
        var barAtChange = lastShownBar
        var shown: [(Duration, FinishEstimate)] = []
        var suspendedUntil: Duration?
        for event in run.timeline {
            switch event.kind {
            case .progress(let p):
                let s = AnalysisStep(p.stage)
                if !waiting, !paused { active += (event.t - lastT).seconds }
                lastT = event.t
                phaseStartedNow = false
                if let wl = p.workload {
                    estimator.setWorkload(wl)
                    workload = wl
                    // As AppModel.tick: much more work than when the run before stopped starts
                    // a phase of its own, with this workload's widths, from its own start.
                    var startsPhase = false
                    if var r = resumed {
                        startsPhase = r.workload(wl, remaining: estimator.estimatedRemaining?.seconds)
                        resumed = r
                    }
                    if startsPhase, let cause = resumed?.newWork {
                        w = StepWidths(workload: wl)
                        widthsFixed = true
                        glide.reset()
                        // A labelled phase starts its own number together with its own title
                        // (checked below with invariant 3).
                        phaseStartedNow = true
                        phases.append((run.label, cause))
                    } else if !widthsFixed {
                        // As AppModel.tick: new widths, continued from the bar drawn so far
                        // where they would put it lower (review of 9f0bc40: never falls); not
                        // while a run that goes on holds its value (review of 11ef3e1).
                        let held = glide.value(at: instant(event.t), gliding: false)
                        var nw = StepWidths(workload: wl)
                        if !(resumed?.holds(running: true) ?? false),
                           let c = nw.continuing(held: held, step: s, completed: p.completed, total: p.total) { nw = c }
                        w = nw
                        widthsFixed = true
                        glide.reset(keeping: held)
                    }
                }
                if let step, s < step { continue }
                step = s
                if !paused { estimator.record(step: s, completed: p.completed, total: p.total, at: instant(event.t), appleWait: p.waitLeft != nil) }
                // As AppModel.receive: the library read may show the label early; the first
                // report past the stopped position spreads the rest from there, once.
                if p.stage == .inventory, p.total > 0 {
                    libraryPhotos = p.total
                    resumed?.library(photos: p.total)
                }
                if var r = resumed {
                    r.spend(active: active, remaining: estimator.estimatedRemaining?.seconds)
                    resumed = r
                }
                if var r = resumed {
                    let wasBack = r.isBack
                    let before = r.shown(running: true, catchingUp: false, overall: w.overall(step: s, completed: p.completed, total: p.total), stopped: nil)
                    r.back(at: p.stage.number, completed: p.completed, total: p.total)
                    resumed = r
                    if !wasBack, r.isBack {
                        let now = r.shown(running: true, catchingUp: false, overall: w.overall(step: s, completed: p.completed, total: p.total), stopped: nil)
                        passes.append((run.label, now, r.floor, before))
                        // 10. Back where it stopped, going on from there adds nothing to the
                        //     value: the work done before the stop is never counted again; the
                        //     value is above the held one only by the time worked to get here
                        //     (review of 11ef3e1 and 0305d20).
                        if now > before + 0.005 {
                            fail(run, 10, "back at \(p.stage) \(p.completed)/\(p.total): shows \(pct(now)) after \(pct(before)), held \(pct(r.floor))", at: event.t)
                        }
                    }
                }
                // As AppModel (`shownOverall`): held at the floor until the run is back; never
                // 100 % before the end.
                let overall = w.overall(step: s, completed: p.completed, total: p.total)
                let real = resumed?.shown(running: true, catchingUp: false, overall: overall, stopped: nil)
                    ?? AnalysisPercent.value(overall, isComplete: false)
                // 3. The number never goes back, also over Pause and restarts; only a phase of
                //    its own starts it again, and only together with a new title (review of
                //    0305d20: a label shown early, then the number fell under it).
                let newTitle: String
                if let label = resumed?.newWork { newTitle = "\(label)" }
                else if resumed?.isCatchingUp(running: true, at: p.stage.number) == true { newTitle = "catching up" }
                else { newTitle = "\(s)" }
                if phaseStartedNow {
                    if newTitle == title { fail(run, 3, "a phase started under the title it already had (\(title))", at: event.t) }
                    lastShown = real
                    lastShownBar = 0
                    lastFills = []
                    glide.reset()
                } else if real + 1e-9 < lastShown {
                    fail(run, 3, "number shows \(pct(real)) after \(pct(lastShown)) under \(newTitle) (\(p.stage) \(p.completed)/\(p.total))", at: event.t)
                }
                title = newTitle
                lastShown = max(lastShown, real)
                shownValues.append((run.label, event.t, real))
                shownSteps.append(p.stage)
                // As AppModel.receive: the marker moves on only once the value is not held.
                // As AppModel.receive: before the run is back, the marker keeps the stopped
                // position with the value shown now.
                do {
                    let held = (resumed?.holds(running: true) ?? false) ? resumeFrom : nil
                    let carried = workload == nil ? resumeFrom : nil
                    marker = SimMarker(
                        stage: held?.stage ?? p.stage.number, completed: held != nil ? held?.completed : p.completed,
                        overall: real, widths: widthsFixed ? w : nil,
                        left: workload.map { $0.heavyLeft(at: s, completed: p.completed, total: p.total) } ?? carried?.left,
                        photos: carried?.photos ?? libraryPhotos,
                        version: carried?.version ?? AnalysisPipeline.analysisVersion,
                        newWork: resumed?.newWork,
                        secondsLeft: estimator.estimatedRemaining?.seconds
                            ?? (carried != nil ? resumed?.secondsThen ?? carried?.secondsLeft : nil),
                        caughtUp: held != nil ? resumed?.caughtUp : nil)
                }
                let barWidths = w
                glide.update(real: real, at: instant(event.t), step: s, widths: barWidths, itemsPerSecond: estimator.rate, total: p.total)
                let bar = glide.value(at: instant(event.t), gliding: !waiting && !paused)
                if bar > AnalysisPercent.cap + 1e-9 {
                    fail(run, 3, "drawn bar \(pct(bar)) before the end (never 100 %)", at: event.t)
                }
                // What the eye sees is the segments: each one's fill never goes back (also
                // when the widths change, review I3), and the drawn value never goes back
                // under the same widths.
                let fills = barWidths.fills(for: bar)
                if let back = zip(fills, lastFills).enumerated().first(where: { $0.element.0 + 1e-9 < $0.element.1 }) {
                    fail(run, 3, "segment \(back.offset + 1) went back from \(pct(back.element.1)) to \(pct(back.element.0)) at \(p.stage) \(p.completed)/\(p.total)", at: event.t)
                }
                // Against the real value as the app computes it, not the glide's own (which
                // kept the old widths' value and so hid the frozen bar, review I3).
                if bar > real + BarGlide.maxLead * barWidths.width(of: s) + 1e-9 {
                    fail(run, 3, "drawn bar \(pct(bar)) more than 1 % of the step ahead of \(pct(real))", at: event.t)
                }
                // The drawn value never falls within a run, also not when the widths come
                // from the workload (review of 9f0bc40).
                if bar + 1e-9 < lastShownBar {
                    fail(run, 3, "drawn bar fell from \(pct(lastShownBar)) to \(pct(bar)) at \(p.stage) \(p.completed)/\(p.total)", at: event.t)
                }
                lastShownBar = bar
                lastFills = fills
                shownBars.append((run.label, event.t, bar))
                let position = AnalysisCardState.Position(step: s, completed: p.completed, total: p.total)
                let text = position.hasCount ? "\(p.completed)/\(p.total)" : "\(s)"
                let finish = estimator.finish(at: instant(event.t), wall: wall(event.t))
                let display = finish  // already rounded to what the card says
                // About 0.7 pt on a 340 pt wide bar.
                // 8. The number or the bar moves (review of 0305d20: a moving count alone is not
                //    enough); Apple's wait shows its own spinner.
                let barMoved = bar - barAtChange >= 0.002
                let percent = Int((real * 100).rounded())
                // A wait for Apple counts only while its countdown moves ("weiter in 25 s").
                let countdown = p.waitLeft.map { Int($0.seconds.rounded(.up)) }
                let countdownMoved = countdown != nil && countdown != lastCountdown
                lastCountdown = countdown
                if percent != lastPercent || barMoved || countdownMoved || waiting || paused {
                    if !waiting, !paused, event.t - lastChange > .seconds(10) {
                        fail(run, 8, "card stood still for \(String(format: "%.1f", (event.t - lastChange).seconds)) s while the run worked (\(p.stage) \(p.completed)/\(p.total))", at: lastChange)
                    }
                    lastChange = event.t
                    barAtChange = bar
                }
                lastText = text
                lastPercent = percent
                lastFinishShown = display
                if let finish {
                    // Review I4: before an image or text step was measured, the time would
                    // rest on the usual times only.
                    if s < .content, let wl = estimator.workload, wl.itemsLeft(.content) + wl.itemsLeft(.text) > 0 {
                        fail(run, 9, "finish time shown in \(s) before the device was measured", at: event.t)
                    }
                    if waiting || paused { fail(run, 9, "finish time shown while \(waiting ? "waiting" : "paused")", at: event.t) }
                    if let until = suspendedUntil, event.t - until < .seconds(30) {
                        fail(run, 9, "finish time shown \(Int((event.t - until).seconds)) s after the app came back from the background (settles 30 s first)", at: event.t)
                    }
                    shown.append((event.t, finish))
                }
            case .waiting(let reason):
                waiting = reason != nil
                if waiting { estimator.idle() }
                lastChange = event.t
            case .pauseRequested:
                paused = true
                estimator.idle()
            case .suspended(let d):
                // Nothing on screen meanwhile; the estimator sees only the gap (S4).
                lastChange = event.t + d
                lastT = event.t + d
                suspendedUntil = event.t + d
            case .work:
                break
            }
        }
        finishTimes += shown.map { (run.label, $0.0, $0.1, run.end, run.report?.isComplete == true) }
        guard run.report?.isComplete == true else { return }
        for (t, finish) in shown where finish == .soon && run.end - t > .seconds(180) {
            fail(run, 9, "\"Gleich fertig\" \(Int((run.end - t).seconds)) s before the end", at: t)
        }
    }
}
