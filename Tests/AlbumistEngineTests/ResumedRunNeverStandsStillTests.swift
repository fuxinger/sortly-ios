import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistTestSupport

/// Review of 0305d20: a run that goes on never stands still, and the label of a phase never
/// comes before its own number. Adapted where decisions B and C changed what is measured.
@Suite("Review evidence 5: holding and the early label")
struct ReviewFifthPassEvidenceTests {
    /// 1. The label "Neue Fotos werden analysiert" is shown early by the library read while the
    /// value is held at the floor (90 %). The phase starts only at the workload (after the
    /// trips step): under the SAME label the number then falls to the phase's own start.
    /// Before 0305d20 the label and the restart came together. The user sees
    /// "Neue Fotos werden analysiert · 90 %" for minutes (reading 50,000 new photos), then
    /// "Neue Fotos werden analysiert · 2 %".
    @Test func earlyLabelThenTheNumberFallsUnderIt() {
        var run = ResumedRun(stage: 5, completed: 1_000, shown: 0.90, left: 2_000, photos: 50_000)
        let w = StepWidths.standard
        // Adapted (decision C of the review of 0305d20): the library read shows no label any
        // more; while the value is held, the title is not the phase's.
        #expect(run.newWork == nil)
        let held = run.shown(running: true, catchingUp: true,
                             overall: w.overall(step: .trips, completed: 5_000, total: 30_000), stopped: nil)
        #expect(held == 0.90)
        let more = AnalysisWorkload(photos: 60_000, located: 30_000, screenshots: 2_100, contentLeft: 10_000, textLeft: 2_100)
        let started = run.workload(more)
        #expect(started)
        #expect(run.newWork == .newPhotos)  // the label comes with the phase's own number
        let phaseWidths = StepWidths(workload: more)
        let underLabel = run.shown(running: true, catchingUp: false,
                                   overall: phaseWidths.overall(step: .trips, completed: 30_000, total: 30_000), stopped: nil)
        let afterStart = run.shown(running: true, catchingUp: false,
                                   overall: phaseWidths.overall(step: .places, completed: 1_000, total: 30_000), stopped: nil)
        #expect(afterStart >= underLabel - 1e-9,
                "under the label \"Neue Fotos werden analysiert\" the number fell from \(Int(underLabel * 100)) % to \(Int(afterStart * 100)) %")
    }

    /// 2. Paused in the text step; 450 new photos come in (not "much more": < 500). The run
    /// that goes on holds the value until it is back in the text step, so through the image
    /// analysis of every new photo the number and the bar stand still at the floor (the work
    /// is real new work, not catching up). Simulated device: 450 x 0.13 s, about a minute; on a
    /// 50,000-photo library stopped with 2,000 screenshots left, up to 1,000 new photos (100 s+).
    /// The floor is in the text step, every value of the image step is below it, so the
    /// shown value is exactly the floor for the whole stretch measured here.
    @Test func heldNumberStandsStillThroughNewWork() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("r5 pause in text", pause: .when(stage: .text, atLeast: 0.5))
        let stopped = try #require(first.last(.text))
        await sim.addPhotos(450)
        let rest = await sim.run("r5 goes on")
        sim.expectComplete(rest)
        #expect(sim.phases.isEmpty)
        // Adapted (decision B): the time to pass the stopped position is the pipeline's; what
        // must not stand still is the number the card shows (the simulator's card, as AppModel).
        _ = stopped
        let floor = try #require(sim.shownValues.last { $0.run == "r5 pause in text" }?.value)
        let held = Self.longestAt(floor, in: sim.shownValues.filter { $0.run == "r5 goes on" })
        #expect(held <= .seconds(10), "number held at the floor for \(Int(held.seconds)) s")
        // Review of c772325 (5): measured as the card shows it, on whole percent and the bar
        // (a move of 0.2 %), not on a value creeping by 0.0001; and every invariant of the
        // simulator's card (8: something moves every 10 s).
        let still = sim.longestStill("r5 goes on")
        #expect(still <= .seconds(10), "number and bar stood still for \(Int(still.seconds)) s")
        sim.finish()
    }

    /// The longest stretch the number stayed exactly at `value`.
    static func longestAt(_ value: Double, in shown: [(run: String, t: Duration, value: Double)]) -> Duration {
        var from: Duration?
        var longest: Duration = .zero
        for v in shown {
            if abs(v.value - value) < 1e-9 {
                from = from ?? v.t
                longest = max(longest, v.t - from!)
            } else {
                from = nil
            }
        }
        return longest
    }

    /// 3. Paused in the image step at 60 %; 150 analysed photos were deleted meanwhile. The
    /// image step starts 150 below the stopped count: the value is held until the count is
    /// back there or the real value passes the floor. Measured: how long the shown number
    /// stays exactly at the floor while photos are analysed.
    @Test func deletedPhotosHoldTheNumber() async throws {
        let sim = try Sim(scale: 0.2)
        let first = await sim.run("r5 pause in content", pause: .when(stage: .content, atLeast: 0.6))
        let stopped = try #require(first.last(.content))
        let analysed = try await sim.store.results(ContentAnalysis.self, kind: "content")
        var assets = await sim.reader.assets
        let delete = Set(assets.filter { analysed[$0.id] != nil }.prefix(400).map(\.id))
        assets.removeAll { delete.contains($0.id) }
        await sim.reader.set(assets: assets)
        let rest = await sim.run("r5 after deleting")
        sim.expectComplete(rest)
        let begin = try #require(rest.first(.content))
        #expect(begin.completed < stopped.completed, "\(begin) vs \(stopped)")
        // Adapted (decision B): measured on the number the card shows (the simulator's card).
        let floor = try #require(sim.shownValues.last { $0.run == "r5 pause in content" }?.value)
        let frozen = Self.longestAt(floor, in: sim.shownValues.filter { $0.run == "r5 after deleting" })
        #expect(frozen <= .seconds(10), "number held at the floor for \(Int(frozen.seconds)) s inside the image step")
        // Review of c772325 (5): on whole percent and the bar, and every invariant of the card.
        let still = sim.longestStill("r5 after deleting")
        #expect(still <= .seconds(10), "number and bar stood still for \(Int(still.seconds)) s inside the image step")
        sim.finish()
    }

    /// 4. Silent stretches of the trips step on a 50,000-item library (wall clock on Linux; an
    /// iPhone is about 3-5 times slower): the longest time between two reports from the start
    /// of the trips step to the start of the places step.
    @Test func tripsStepGapsAtFiftyThousand() async throws {
        let library = SimLibrary(scale: 8.8)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: library.assets)
        let pipeline = AnalysisCoverageTests.pipeline(store: store, reader: reader, analyzer: .init())
        let control = AnalysisRunControl()
        let events = Locked<[(ContinuousClock.Instant, String)]>([])
        _ = try await pipeline.run(control: control, onProgress: { p in
            events.withLock { $0.append((.now, "\(p.stage) \(p.completed)/\(p.total)")) }
            if p.stage == .content { control.pause() }
        })
        let e = events.withLock { $0 }
        let from = e.firstIndex { $0.1.hasPrefix("patterns") } ?? 0
        let to = e.firstIndex { !$0.1.hasPrefix("patterns") && !$0.1.hasPrefix("inventory") } ?? e.count - 1
        let slice = ProcessInfo.processInfo.environment["R5_ALL"] != nil ? e : Array(e[max(0, from - 1)...to])
        let gaps = zip(slice, slice.dropFirst()).map { (($1.0 - $0.0).seconds, "\($0.1) -> \($1.1)") }
        let worst = gaps.max { $0.0 < $1.0 }
        print("R5 trips step: \(library.total) items, \(library.located) located; worst gap \(String(format: "%.2f", worst?.0 ?? 0)) s: \(worst?.1 ?? "")")
        for g in gaps where g.0 > 0.3 { print("R5 gap \(String(format: "%.2f", g.0)) s: \(g.1)") }
        // 10 s on the device, Linux 3x faster as the lower bound.
        #expect((worst?.0 ?? 0) <= 10.0 / 3, "\(worst.map { "\($0.0) s \($0.1)" } ?? "")")
    }
}
