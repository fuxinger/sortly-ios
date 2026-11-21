import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistTestSupport

/// Reviews G4-03 and P4-10: `AppModel.refreshDerived` guarded only its last assignment with
/// `LatestCall`. The suggestions (`snapshot`), the facts, the inventory, the history and the
/// rest were assigned as each was read, so two overlapping calls that finished in swapped order
/// left an older call's suggestions or facts next to the newer call's states until the next
/// refresh. With a trip change in flight that was the old trip back in the list for a moment.
/// Now everything is read first and assigned together, and only over an older result: never
/// over a newer call's, but also when the newer calls failed (second review, NIT-1).
@Suite("Overlapping refreshes: a call assigns only over an older result")
struct OverlappingRefreshTests {
    /// Everything the overview shows from a refresh.
    static let shown = ["snapshot", "recheckedSuggestions", "recurringPlaceReport", "detectedHome", "homeChangeNotice",
                        "facts", "previewRanksCache", "inventory", "mergeSuggestions", "historyHasMore", "history",
                        "undonePlans", "removedFromProposals", "datesCache", "atlasCache", "atlasYearsCache", "factsIndex"]

    /// The rule itself: a call assigns only when it is newer than the result on screen. Of two
    /// overlapping calls the older one never puts its result over the newer one's, whichever
    /// ends last; when the newer one failed, the older one's result is still newer than what is
    /// shown (second review of P4-10, NIT-1).
    @Test func aCallAssignsOnlyOverAnOlderResult() {
        var calls = LatestCall()
        let older = calls.begin()
        let newer = calls.begin()
        #expect(calls.isNewest(newer) && !calls.isNewest(older))
        #expect(calls.mayShow(newer) && calls.mayShow(older), "nothing is shown yet")
        calls.shown(newer)
        #expect(!calls.mayShow(older), "an older call that ends last would put back its result")

        var failing = LatestCall()
        let first = failing.begin()
        _ = failing.begin() // fails: shows nothing
        #expect(failing.mayShow(first), "a newer call that failed throws away the older call's result")
        failing.shown(first)
        #expect(!failing.mayShow(first) && failing.lastShown == first)
        let third = failing.begin()
        #expect(failing.mayShow(third))
    }

    /// The App assigns nothing it shows before its guard (a call shows its result only over an
    /// older one, `LatestCall.mayShow`), and each of it after the guard (it does not build on
    /// Linux, so its code is read without comments and strings, `AppSource.code`). The
    /// reopenings after a recheck are decisions and stay before it.
    @Test func refreshDerivedAssignsOnlyAfterItsGuard() throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let body = AppSource.code(try #require(AppSource.body(of: "func refreshDerived(", in: model)))
        let guardLine = "guard derivedCalls.mayShow(call), scope == analysisScope else { return }"
        let parts = body.components(separatedBy: guardLine)
        #expect(parts.count == 2, "refreshDerived has no single guard that lets a call show only over an older result")
        guard parts.count == 2 else { return }
        // Noted at once, before anything else of the call: an older call that ends later sees it.
        let notes = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("derivedCalls.shown(call)")
        #expect(notes, "refreshDerived does not note right after its guard that the call shows its result")
        func assigns(_ name: String, in text: String) throws -> Bool {
            let pattern = try Regex("(?m)^\\s*(self\\.)?\(name)\\s*=[^=]")
            return text.contains(pattern) || text.contains("{ self.\(name) = ") || text.contains("{ \(name) = ")
        }
        for name in Self.shown {
            let early = try assigns(name, in: parts[0])
            let late = try assigns(name, in: parts[1])
            #expect(!early, "refreshDerived assigns \(name) before it knows it is the newest call")
            #expect(late, "refreshDerived does not assign \(name) after the guard")
        }
        // Handed to the engine call that reads them (`DerivedRefresh.Once`), before the guard.
        let reopensFirst = parts[0].contains("reopenAfterRecheck(reopened)") && parts[0].contains("DerivedRefresh.Once(")
        #expect(reopensFirst, "the reopenings after a recheck depend on the call being the newest")
        // One call into the engine, one package: nothing else is awaited before the guard
        // (`reconcileManagedAlbums` comes before the reads, as before). What is awaited, by name
        // (second review, NIT-6: a count of the text "await " broke with a line break after it).
        let awaitedCall = try Regex("\\bawait\\s+([A-Za-z_][A-Za-z0-9_.?]*)")
        func awaited(in text: String) -> [String] {
            text.matches(of: awaitedCall).compactMap { $0.output[1].substring.map(String.init) }.sorted()
        }
        let beforeGuard = awaited(in: parts[0])
        #expect(beforeGuard == ["Purchases.shared.settleUndone", "pipeline.derivedRefresh", "reconcileManagedAlbums", "self?.reopenAfterRecheck"],
                "refreshDerived awaits \(beforeGuard) before its guard: only the album check, the package and the two it applies once")
        let assigning = parts[1].components(separatedBy: "} catch {")[0]
        #expect(awaited(in: assigning).isEmpty, "refreshDerived awaits \(awaited(in: assigning)) between its guard and its assignments")
        // An older call that fails does not show its error over a newer call's result.
        let catchPart = body.components(separatedBy: "} catch {").dropFirst().joined()
        #expect(catchPart.contains("if derivedCalls.isNewest(call) { message = .failure("), "an older call shows its error")
    }

    // MARK: Two overlapping calls, the first one held (review P4-10)

    /// What the overview shows of a refresh: the photos of the facts and those with a state.
    struct Shown: Sendable, Equatable {
        var facts: Set<AssetID> = []
        var states: Set<AssetID> = []
        var history: Int?
    }

    struct Failed: Error {}

    /// The overview as `AppModel.refreshDerived` fills it, on one actor like the main actor.
    actor Overview {
        var calls = LatestCall()
        var shown = Shown()

        /// As the app does it now: one package from the engine (`derivedRefresh`), assigned
        /// together, only over an older result. `fails`: the call throws once it has its package
        /// (as a read of the store can).
        func refresh(_ pipeline: AnalysisPipeline, settings: OrganizationSettings, probe: DerivedLibrary.Probe?, fails: Bool = false) async throws {
            let call = calls.begin()
            let refreshed = try await pipeline.derivedRefresh(settings: settings, managed: [], scope: .all, historyLimit: 50,
                                                              once: .nothing, probe: probe)
            if fails { throw Failed() }
            guard calls.mayShow(call) else { return }
            calls.shown(call)
            shown = Shown(facts: Set(refreshed.library.facts.map(\.id)), states: Set(refreshed.library.status.states.keys),
                          history: refreshed.history.count)
        }

        /// As the app did it before the reviews G4-03 and P4-10: each part assigned as soon as
        /// it was read, only the states behind the newest-call guard.
        func refreshAsBefore(_ pipeline: AnalysisPipeline, settings: OrganizationSettings, probe: DerivedLibrary.Probe?) async throws {
            let call = calls.begin()
            let snapshot = try await pipeline.refreshMatchesIfOutdated().snapshot
            let derived = try await pipeline.derivedLibrary(snapshot: snapshot, settings: settings, managed: [], scope: .all,
                                                            ownAlbums: [], probe: probe)
            shown.facts = Set(derived.facts.map(\.id))
            guard calls.isNewest(call) else { return }
            shown.states = Set(derived.status.states.keys)
        }
    }

    /// A photo that comes in between the two calls: only the second call reads it.
    static let late = AssetSnapshot(id: AssetID("late-photo"), kind: .image, creationDate: Fixture.date("2026-06-30"),
                                    location: Fixture.Places.munichHome, pixelWidth: 4032, pixelHeight: 3024)

    /// Two overlapping refreshes: the first one is held after it read the facts, the library
    /// changes (one more photo), the second one ends, then the first. `asBefore`: with the
    /// order the app had before the fix. `secondFails`: the second call throws.
    static func overlapping(asBefore: Bool, secondFails: Bool = false) async throws -> (shown: Shown, photos: Int) {
        let library = try await DerivedRefreshTests().analysed()
        let pipeline = library.launch()
        let overview = Overview()
        let held = Locked(false), release = Locked(false)
        let holdFirst: DerivedLibrary.Probe = { piece, ended in
            guard piece == .status, !ended else { return }
            held.withLock { $0 = true }
            while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let settings = library.settings
        let first = Task {
            if asBefore {
                try await overview.refreshAsBefore(pipeline, settings: settings, probe: holdFirst)
            } else {
                try await overview.refresh(pipeline, settings: settings, probe: holdFirst)
            }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !held.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(held.withLock { $0 }, "the first call never got to its states")
        _ = try await library.store.upsertAssets([Self.late])
        if asBefore {
            try await overview.refreshAsBefore(pipeline, settings: settings, probe: nil)
        } else {
            do {
                try await overview.refresh(pipeline, settings: settings, probe: nil, fails: secondFails)
            } catch is Failed {
                #expect(secondFails)
            }
        }
        release.withLock { $0 = true }
        try await first.value
        let photos = try await library.store.allAssets().count
        return (await overview.shown, photos)
    }

    /// Facts and states on screen come from the same call, the newest: the photo that came in
    /// between has its facts and its state, also after the older call ended last.
    @Test func overlappingCallsShowFactsAndStatesOfTheNewestCall() async throws {
        let (shown, photos) = try await Self.overlapping(asBefore: false)
        #expect(shown.facts.count == photos, "the facts on screen are not the newest call's")
        #expect(shown.facts.contains(Self.late.id))
        #expect(shown.states.contains(Self.late.id))
        #expect(shown.facts == shown.states, "facts of one call next to states of another: \(shown.facts.count) photos with facts, \(shown.states.count) with a state")
        #expect(shown.history != nil)
    }

    /// Second review of P4-10, NIT-1: the newer call fails, the older one ends after it. Its
    /// result is newer than what is on screen (nothing yet here), so it is shown; "only the
    /// newest call assigns" threw it away and left the screen as it was until the next refresh.
    @Test func aNewerCallThatFailsLeavesTheOlderResultToShow() async throws {
        let (shown, photos) = try await Self.overlapping(asBefore: false, secondFails: true)
        #expect(!shown.facts.isEmpty, "the older call's result was thrown away")
        #expect(shown.facts.count == photos - 1 && !shown.facts.contains(Self.late.id), "not the older call's facts")
        #expect(shown.facts == shown.states, "facts of one call next to states of another")
        #expect(shown.history != nil)
    }

    /// The same overlap with the order the app had before (each part assigned when read): the
    /// older call put its facts back next to the newer call's states. The scenario above finds
    /// the fault it guards against.
    @Test func theOrderBeforeShowedFactsAndStatesOfDifferentCalls() async throws {
        let (shown, _) = try await Self.overlapping(asBefore: true)
        #expect(!shown.facts.contains(Self.late.id), "the older call's facts were not put back")
        #expect(shown.states.contains(Self.late.id))
        #expect(shown.facts != shown.states)
    }
}
