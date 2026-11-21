import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
@testable import AlbumistStore
import AlbumistTestSupport

/// Second review of the labels fix (17.11.): what follows the end of a run (`AnalysisRunEnd`),
/// decided against the settings the run really read (`Report.settingsUsed`). The owner's rules:
/// never a false "fertig", Pause is always respected, no run is lost, no number goes back.
@Suite("Run end: what follows a run")
struct AnalysisRunEndTests {
    typealias T = LabelsLaterTests

    static let off = T.settings(labels: false)
    static let on = T.settings(labels: true)

    /// A complete report of a run that read `used`.
    static func complete(_ used: OrganizationSettings) -> AnalysisPipeline.Report {
        var report = AnalysisPipeline.Report()
        report.completedStages = AnalysisPipeline.Stage.allCases
        report.settingsUsed = .init(used)
        return report
    }

    static func end(_ report: AnalysisPipeline.Report?, settings: OrganizationSettings = on, pauseTapped: Bool = false,
                    catchUp: Bool = false, mayStart: Bool = true, background: Bool = false) -> AnalysisRunEnd {
        AnalysisRunEnd(report: report, settings: settings, pauseTapped: pauseTapped, catchUpRequested: catchUp,
                       mayStart: mayStart, background: background)
    }

    // MARK: The decision

    @Test func aRunThatDidWhatTheSettingsAskIsFinished() {
        let done = Self.end(Self.complete(Self.on))
        #expect(done.isFinished && done.next == .nothing && !done.needsResume)
        #expect(done.report == Self.complete(Self.on))
        // Changes in Photos during it: one more pass after the usual gap, as before.
        let changed = Self.end(Self.complete(Self.on), catchUp: true)
        #expect(changed.isFinished && changed.next == .catchUp)
        // Settings changed in a way that needs no run ("Themen" off): finished.
        let offNow = Self.end(Self.complete(Self.on), settings: Self.off)
        #expect(offNow.isFinished && offNow.next == .nothing)
    }

    /// Finding 1: "Themen" turned on after the run decided on its labels. Not "fertig": one more
    /// run right away; it takes changes in Photos in too.
    @Test func aChangeTheRunMissedStartsOneMoreRightAway() {
        let missed = Self.end(Self.complete(Self.off))
        #expect(missed.next == .followUp)
        #expect(!missed.isFinished)
        // The report stays complete; the run goes on by itself, so the Lock Screen never reads "fertig".
        #expect(missed.report?.isComplete == true && missed.needsResume)
        #expect(Self.end(Self.complete(Self.off), catchUp: true).next == .followUp)
        // Each change `settingsChangeNeedsRun` names, the same way.
        var hidden = Self.on
        hidden.privacy.includeHiddenAssets = true
        var noHidden = Self.on
        noHidden.privacy.includeHiddenAssets = false
        #expect(Self.end(Self.complete(noHidden), settings: hidden).next == .followUp)
        var offline = Self.on
        offline.privacy.allowOnlineGeocoding = false
        #expect(Self.end(Self.complete(offline), settings: Self.on).next == .followUp)
    }

    /// No run may start now (a plan claimed or being written, a rebuild, no photo access): the
    /// one that ends that starts a run anyway. Still never "fertig".
    @Test func aMissedChangeWaitsForTheRunThatIsDueAnyway() {
        let held = Self.end(Self.complete(Self.off), mayStart: false)
        #expect(held.next == .nothing && !held.isFinished && held.needsResume)
        #expect(Self.end(Self.complete(Self.off), catchUp: true, mayStart: false).next == .catchUp)
    }

    /// Finding 2: Pause tapped during the last steps, which finish anyway. With work left the
    /// run reads as paused by the user ("Fortsetzen"), nothing starts by itself.
    @Test func aLatePauseKeepsTheWorkForFortsetzen() {
        let settingsLeft = Self.end(Self.complete(Self.off), pauseTapped: true)
        #expect(settingsLeft.report?.pausedBecause == .userPaused)
        #expect(settingsLeft.report?.isComplete == false)
        #expect(settingsLeft.next == .nothing && !settingsLeft.isFinished && !settingsLeft.needsResume)
        // Changes in Photos left: the same, Pause wins over the catch-up.
        let photosLeft = Self.end(Self.complete(Self.on), pauseTapped: true, catchUp: true)
        #expect(photosLeft.report?.pausedBecause == .userPaused && photosLeft.next == .nothing)
        // Nothing left: the Pause came too late for a run that was done; it is finished.
        let nothingLeft = Self.end(Self.complete(Self.on), pauseTapped: true)
        #expect(nothingLeft.isFinished && nothingLeft.report?.pausedBecause == nil)
    }

    @Test func pausedOrStoppedRunsGoOnAsBefore() {
        var paused = Self.complete(Self.off)
        paused.pausedBecause = .userPaused
        // "Fortsetzen" reads the library and the settings: nothing follows, the catch-up is taken.
        for catchUp in [false, true] {
            let end = Self.end(paused, pauseTapped: true, catchUp: catchUp)
            #expect(end.next == .nothing && !end.isFinished && !end.needsResume)
        }
        var hot = Self.complete(Self.off)
        hot.pausedBecause = .thermal
        #expect(Self.end(hot).next == .retry)
        #expect(Self.end(hot).needsResume)
        #expect(Self.end(hot, catchUp: true).next == .catchUp)
        // Threw or stopped on purpose.
        #expect(Self.end(nil).next == .retry && Self.end(nil).needsResume)
        #expect(Self.end(nil, catchUp: true).next == .catchUp)
    }

    /// Finding 3: the overnight refinement ends through the same rules. It takes a catch-up
    /// asked for meanwhile, starts a run for a change it missed, and leaves retries to its
    /// next window.
    @Test func theRefinementEndsTheSameWay() {
        #expect(Self.end(Self.complete(Self.on), catchUp: true, background: true).next == .catchUp)
        #expect(Self.end(Self.complete(Self.off), background: true).next == .followUp)
        #expect(Self.end(Self.complete(Self.on), background: true).isFinished)
        var cut = Self.complete(Self.on)
        cut.pausedBecause = .timeBudget
        #expect(Self.end(cut, background: true).next == .nothing)
        #expect(Self.end(nil, background: true).next == .nothing)
        #expect(Self.end(nil, catchUp: true, background: true).next == .catchUp)
    }

    /// Third review, finding 1: the refinement decides its end as soon as its run returns, with
    /// the Pause tapped until then. Paused by the user, the analysis stays paused (before, an
    /// unfinished one went on by itself); the other ends set `needsResume` as before.
    @Test func aPauseDuringTheRefinementStays() {
        let late = Self.end(Self.complete(Self.off), pauseTapped: true, background: true)
        #expect(late.report?.pausedBecause == .userPaused && late.next == .nothing && !late.isFinished)
        var paused = Self.complete(Self.off)
        paused.pausedBecause = .userPaused
        for before in [false, true] {
            #expect(!late.needsResume(afterRefinement: before))
            #expect(!Self.end(paused, pauseTapped: true, background: true).needsResume(afterRefinement: before))
            // Finished: nothing to go on with. A change it missed: not done.
            #expect(!Self.end(Self.complete(Self.on), background: true).needsResume(afterRefinement: before))
            #expect(Self.end(Self.complete(Self.off), background: true).needsResume(afterRefinement: before))
            // Cut off by iOS or stopped by the device: as it was.
            var hot = Self.complete(Self.on)
            hot.pausedBecause = .thermal
            #expect(Self.end(hot, background: true).needsResume(afterRefinement: before) == before)
            #expect(Self.end(nil, background: true).needsResume(afterRefinement: before) == before)
        }
    }

    /// Third review, finding 3: "Themen" turned on while the overnight refinement runs, after it
    /// decided on labels. Its end asks for one more run, which the app makes a second pass of the
    /// refinement in the same window (`AppModel.refine`): that pass gives the labels and is finished.
    @Test func theRefinementDoesAChangeItMissedInASecondPass() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        _ = try await s.pipeline.run()
        let pipeline = s.pipeline
        final class Change: Sendable { let task = Locked<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let first = try await pipeline.run(mode: .refinement, onProgress: { p in
            guard p.stage == .content else { return }
            change.task.withLock { task in
                if task == nil { task = Task { await pipeline.update(settings: Self.on) } }
            }
        })
        _ = await change.task.withLock { $0 }?.value
        let end = Self.end(first, background: true)
        #expect(end.next == .followUp && !end.isFinished && end.needsResume(afterRefinement: false))
        let second = try await pipeline.run(mode: .refinement)
        #expect(second.labelsAdded == 12)
        let done = Self.end(second, background: true)
        #expect(done.isFinished && done.next == .nothing && !done.needsResume(afterRefinement: true))
    }

    /// Finding 4: another run started while this one's end waited for the overview (a change
    /// of the settings, "Neu prüfen"): no finish moment and nothing scheduled from the older run.
    @Test func anEndThatWaitedLeavesTheNewerRunAlone() {
        let done = Self.end(Self.complete(Self.on), catchUp: true)
        #expect(done.afterWait(isNewest: true) == (finishMoment: true, next: .catchUp))
        #expect(done.afterWait(isNewest: false) == (finishMoment: false, next: .nothing))
        var hot = Self.complete(Self.on)
        hot.pausedBecause = .thermal
        #expect(Self.end(hot).afterWait(isNewest: true) == (finishMoment: false, next: .retry))
        #expect(Self.end(hot).afterWait(isNewest: false) == (finishMoment: false, next: .nothing))
        // The follow-up started before the wait: nothing more after it.
        #expect(Self.end(Self.complete(Self.off)).afterWait(isNewest: false) == (finishMoment: false, next: .nothing))
        #expect(Self.end(Self.complete(Self.off)).afterWait(isNewest: true) == (finishMoment: false, next: .nothing))
    }

    /// What a run read, step by step: a run that did not get to a setting decides nothing about
    /// it; one that read everything decides as `settingsChangeNeedsRun`.
    @Test func whatARunReadDecidesLikeTheChangeItself() {
        let nothing = AnalysisPipeline.SettingsUsed()
        #expect(!nothing.needsRun(for: Self.on))
        let pairs: [(OrganizationSettings, OrganizationSettings)] = [(Self.off, Self.on), (Self.on, Self.off), (Self.off, Self.off),
                                                                     (Self.on, T.settings(labels: false, documents: true))]
        for (old, new) in pairs {
            #expect(AnalysisPipeline.SettingsUsed(old).needsRun(for: new) == AnalysisPipeline.settingsChangeNeedsRun(from: old, to: new))
        }
        var labelsOnly = AnalysisPipeline.SettingsUsed()
        labelsOnly.labels = false
        #expect(labelsOnly.needsRun(for: Self.on))
        #expect(!labelsOnly.needsRun(for: Self.off))
    }

    // MARK: Through the pipeline

    /// Conditions that let a test act once, at the run's first check: right after the library
    /// was read, before the run decides on labels (the change lands there for certain, not when
    /// a task happens to run).
    final class FirstCheck: AnalysisConditions, Sendable {
        let action = Locked<(@Sendable () async -> Void)?>(nil)
        func pauseReason() async -> PauseReason? { nil }
        func pace() async -> AnalysisPace {
            let act = action.withLock { a in
                defer { a = nil }
                return a
            }
            await act?()
            return .normal
        }
        func isOnWiFi() async -> Bool { true }
    }

    /// "Themen" turned on after the library was read: the run decides on labels after the trips
    /// step and gives them itself. Its end needs nothing more (finding 5: the extra run).
    @Test func aChangeBeforeTheLabelsAreDecidedIsTakenInByTheRun() async throws {
        let check = FirstCheck()
        let s = try T.setup(photos: 12, screenshots: 0, labels: false, conditions: check)
        let pipeline = s.pipeline
        check.action.withLock { $0 = { _ = await pipeline.update(settings: Self.on) } }
        let report = try await pipeline.run()
        #expect(report.isComplete)
        #expect(report.settingsUsed.labels == true)
        #expect(report.labelsAdded + report.contentAnalyzed == 12)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        let end = Self.end(report)
        #expect(end.isFinished && end.next == .nothing)
    }

    /// "Themen" turned on in the image step, after the run decided against labels: its end
    /// starts one more run right away, not "fertig"; that run gives the labels and is finished.
    @Test func aChangeAfterTheLabelsAreDecidedStartsTheFollowUp() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let pipeline = s.pipeline
        final class Change: Sendable { let task = Locked<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let first = try await pipeline.run(onProgress: { p in
            guard p.stage == .content else { return }
            change.task.withLock { task in
                if task == nil { task = Task { await pipeline.update(settings: Self.on) } }
            }
        })
        _ = await change.task.withLock { $0 }?.value
        #expect(first.isComplete && first.settingsUsed.labels == false && first.labelsAdded == 0)
        let end = Self.end(first)
        #expect(end.next == .followUp && !end.isFinished)
        let followUp = try await pipeline.run()
        #expect(followUp.labelsAdded == 12)
        #expect(Self.end(followUp).isFinished)
    }

    /// The reviewer's probe: Pause tapped while the suggestions are made. Since review P4-07 it
    /// stops the run there (before, the run went on to the end). With "Themen" turned on during
    /// it, the run reads as paused ("Fortsetzen"), and "Fortsetzen" gives the labels.
    @Test func pauseDuringTheSuggestionsKeepsTheChangeForFortsetzen() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let pipeline = s.pipeline
        final class Change: Sendable { let task = Locked<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let control = AnalysisRunControl()
        let report = try await pipeline.run(control: control, onProgress: { p in
            if p.stage == .content {
                change.task.withLock { task in
                    if task == nil { task = Task { await pipeline.update(settings: Self.on) } }
                }
            }
            if p.stage == .proposals, p.completed == 0 { control.pause() }
        })
        _ = await change.task.withLock { $0 }?.value
        #expect(!report.isComplete && !report.completedStages.contains(.proposals))
        let end = Self.end(report, pauseTapped: control.isPaused)
        #expect(end.report?.pausedBecause == .userPaused)
        #expect(end.next == .nothing && !end.isFinished && !end.needsResume)
        let resumed = try await pipeline.run()
        #expect(resumed.labelsAdded == 12)
        #expect(Self.end(resumed).isFinished)
    }

    /// A run paused in the library read never got to the labels: nothing of its own decides;
    /// "Fortsetzen" reads the settings.
    @Test func aRunPausedEarlyReadOnlyWhatItGotTo() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let control = AnalysisRunControl()
        let report = try await s.pipeline.run(control: control, onProgress: { p in
            if p.stage == .inventory { control.pause() }
        })
        #expect(report.pausedBecause == .userPaused)
        #expect(report.settingsUsed.labels == nil && report.settingsUsed.text == nil && report.settingsUsed.places == nil)
        #expect(report.settingsUsed.hidden != nil)
    }

    // MARK: Words and the marker

    @Test func aCheckIsNamedForTheNewAreasWhenItIsMostlyLabels() {
        func w(content: Int, text: Int = 0, labels: Int) -> AnalysisWorkload {
            AnalysisWorkload(photos: 5_683, located: 4_000, screenshots: 300, contentLeft: content, textLeft: text, labelsLeft: labels)
        }
        #expect(w(content: 5_683, labels: 5_683).isMostlyLabels)
        #expect(w(content: 5_683, text: 40, labels: 5_600).isMostlyLabels)
        #expect(!w(content: 300, labels: 0).isMostlyLabels)
        #expect(!w(content: 3_000, labels: 1_000).isMostlyLabels)
        #expect(w(content: 2_000, labels: 1_000).isMostlyLabels)
    }

    /// Finding 9: the label "für die neuen Bereiche" is kept in the marker as one an older build
    /// knows ("Neue Fotos") plus a flag it ignores, and read back from the two. The marker itself
    /// (`AnalysisMarker.Point`) is the app's: its round trip and an older build reading it are in
    /// the app's tests (`AnalysisMarkerLabelTests`, third review, 7: not a copy of it here).
    @Test func theMarkerKeepsTheNewLabelInWordsOlderBuildsKnow() {
        let all: [ResumedRun.NewWork] = [.newAreas, .newPhotos, .moreNewPhotos, .afterUpdate, .afterUpdateAgain]
        for label in all {
            #expect(label.markerValue != .newAreas)
            #expect(ResumedRun.NewWork.fromMarker(label.markerValue, flag: label.markerFlag) == label)
            #expect((label.markerFlag != nil) == (label == .newAreas))
        }
        #expect(ResumedRun.NewWork.newAreas.markerValue == .newPhotos)
        // A marker without the flag (an older build wrote it) reads as it is.
        for label in all where label != .newAreas {
            #expect(ResumedRun.NewWork.fromMarker(label, flag: nil) == label)
        }
        #expect(ResumedRun.NewWork.fromMarker(nil, flag: nil) == nil)
    }

    // MARK: Store

    /// Finding 11: the overview reads only the analysed photos still without labels: none once
    /// they are caught up, none never analysed, none given up.
    @Test func theStoreReadsOnlyThePhotosWaitingForLabels() async throws {
        let store = try AlbumistStore(url: nil)
        var lib = LibraryBuilder()
        let a = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let b = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        let c = lib.photo(at: Fixture.date("2026-03-03 10:00"), Fixture.Places.munichHome)
        _ = lib.photo(at: Fixture.date("2026-03-04 10:00"), Fixture.Places.munichHome)
        _ = try await store.upsertAssets(lib.assets)
        try await store.saveResults([(a, ContentAnalysis()), (b, ContentAnalysis())], kind: "content", version: 1, markingAnalyzed: [a, b])
        try await store.saveResults([(c, ContentAnalysis(labels: [LabelScore("dog", 0.9)]))], kind: "content", version: 1,
                                    markingAnalyzed: [c], labelsVersion: 1)
        #expect(try await store.unlabelledAssets(version: 1, labelsVersion: 1) == [a, b])
        try await store.saveResults([(AssetID, ContentAnalysis)](), kind: "content", version: 1, markingAnalyzed: [a, b], labelsVersion: 1)
        #expect(try await store.unlabelledAssets(version: 1, labelsVersion: 1).isEmpty)
    }
}

/// Owner decision 18.11.2026 ("Analyse läuft dann weiter"): a Pause of the user stands until the
/// user goes on. Nothing that happens by itself ends it; a tap does, and so does a change of the
/// user's that needs a run to apply it (a split, a merge, "Aufheben", "Reisen wieder automatisch
/// erkennen"): its run starts at once, like a tap. Before, the change was stored and nothing
/// applied it until "Fortsetzen", and the trip workshop kept its spinner with no word why.
@Suite("Run start: what a Pause does to it")
struct AnalysisStartCauseTests {
    typealias Cause = AnalysisStartCause

    @Test func everyAutomaticStartWaitsForThePause() {
        let automatic = Cause.allCases.filter { !$0.isUserInitiated }
        #expect(automatic == [.automatic])
        for cause in automatic {
            #expect(!cause.startsWhilePaused && !cause.endsPause, "\(cause)")
            #expect(!cause.startsRun(pausedByUser: true), "\(cause) started under a Pause")
            #expect(cause.pausedAfterStart(pausedByUser: true), "\(cause) ended the Pause")
            // Without a Pause it starts as before, and none comes from it.
            #expect(cause.startsRun(pausedByUser: false))
            #expect(!cause.pausedAfterStart(pausedByUser: false))
        }
    }

    @Test func aTapStartsAndEndsThePause() {
        #expect(Cause.tap.startsWhilePaused && Cause.tap.endsPause && Cause.tap.isUserInitiated)
        #expect(Cause.tap.startsRun(pausedByUser: true))
        #expect(!Cause.tap.pausedAfterStart(pausedByUser: true))
        #expect(Cause.tap.startsRun(pausedByUser: false))
    }

    @Test func theUsersOwnChangeStartsAndEndsThePauseLikeATap() {
        let change = Cause.userChange
        #expect(change.startsWhilePaused, "a trip change waited for Fortsetzen")
        #expect(change.endsPause)
        #expect(change.startsRun(pausedByUser: true), "a trip change was stored and nothing applied it")
        #expect(!change.pausedAfterStart(pausedByUser: true), "the Pause stood over the run of a trip change")
        #expect(change.startsRun(pausedByUser: false))
        // Like a tap: background time for a long run, the retries count from nothing again.
        #expect(change.isUserInitiated)
    }

    /// No run goes on under a card that says "Analyse pausiert": what starts while paused ends it.
    @Test func noRunStartsUnderAStandingPause() {
        for cause in Cause.allCases {
            #expect(cause.startsWhilePaused == cause.endsPause, "\(cause)")
            if cause.startsRun(pausedByUser: true) { #expect(!cause.pausedAfterStart(pausedByUser: true), "\(cause)") }
        }
    }

    /// The App really decides by this rule (it does not build on Linux, so its code is read,
    /// without comments and strings: `AppSource.code`): a trip change starts its run as the
    /// user's change, the start and the Pause follow the cause, and no start outside the places
    /// the user asks for passes a cause that would end a Pause. Each check goes red when that
    /// part of the fix is taken back (reviews of 163d656 and 7e8aba3).
    @Test func theAppStartsByThisRule() throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        func code(_ declaration: String) throws -> String {
            AppSource.code(try #require(AppSource.body(of: declaration, in: model), "AppModel.swift: no \(declaration)"))
        }
        // Booleans first: an expectation on `contains` would print the whole file.
        let tripChangeIsTheUsers = try code("func changeTrips(").contains("startAnalysis(cause: .userChange)")
        #expect(tripChangeIsTheUsers, "changeTrips does not start its run as the user's change")
        let answerIsTheUsers = try code("func changeRecurringPlaces(").contains("startAnalysis(cause: .userChange)")
        #expect(answerIsTheUsers, "changeRecurringPlaces(rerun: true) does not start its run as the user's change")

        // The start and the Pause, line by line as the rule says them.
        let start = try code("func startAnalysisNow(")
        let lines = Set(start.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        for line in ["let pausedBefore = analysis.pausedByUser",
                     "guard cause.startsRun(pausedByUser: pausedBefore) else { return }",
                     "setPausedByUser(cause.pausedAfterStart(pausedByUser: pausedBefore))",
                     "if cause.asksForARunAfter(running: analysis.isRunning) { changeAfterRun = true }"] {
            #expect(lines.contains(line), "startAnalysisNow lacks: \(line)")
        }
        let ownGate = start.contains("cause == .") || start.contains("cause != .") || start.contains("pausedByUser && !")
        #expect(!ownGate, "startAnalysisNow has a Pause rule of its own")
        // The run's end and the refinement's take the request for one more run, and taking it
        // clears it: else every later run would start one more (third review of d7da886).
        for declaration in ["func startAnalysisNow(", "func refinePass("] {
            let takesIt = try code(declaration).contains("changeRequested: takeChangeRequest()")
            #expect(takesIt, "\(declaration): the end of the run does not take a trip change that came during it")
        }
        let take = Set(try code("func takeChangeRequest(").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(take.contains("defer { changeAfterRun = false }") && take.contains("return changeAfterRun"),
                "takeChangeRequest does not clear the request it hands out")
        let modelCode = AppSource.code(model)
        let uses = modelCode.components(separatedBy: "changeAfterRun").count - 1
        #expect(uses == 4, "changeAfterRun is used outside its declaration, the start rule and takeChangeRequest (\(uses) uses)")

        // Every start in the App: only where the user asks for the analysis (a tap, the user's
        // own change, the queued start after a change in "Dein Zuhause") may a cause other than
        // `.automatic` be passed. Found by declaration, not by line.
        let allowed: [String: [[String]]] = [
            "App/Albumist/Model/AppModel.swift": [["func finishOnboarding("], ["func changeScope("], ["func runAfterSettingsChange("],
                                                ["func restoreRejectedProposals("], ["func changeTrips("], ["func changeRecurringPlaces("],
                                                ["func startAnalysis("], ["func changeHome("]],
            "App/Albumist/Views/EmptyLibraryCard.swift": [["struct EmptyLibraryCard", "var body: some View"]],
            "App/Albumist/Views/SettingsView.swift": [["struct SettingsView", "var body: some View"]],
            "App/Albumist/Views/OverviewView.swift": [["var analysisCard: some View"], ["struct LimitedAccessCard", "var body: some View"],
                                                    ["func presentPicker("]],
            "App/Albumist/Views/AnalysisProgressCard.swift": [["struct AnalysisProgressCard", "var control: some View"]],
            "App/Albumist/Platform/UITestSwitches.swift": [["static func didLaunch("]],
            "App/Albumist/Platform/DemoLibrary.swift": [["func seed(then model:"]],
            "App/Albumist/Platform/SamplePhotos.swift": [["func add(model:"], ["func remove(model:"]],
        ]
        let files = AppSource.swiftFiles(under: "App")
        #expect(files.count > 50)
        var automatic = 0, asked = 0
        for path in files {
            let source = try AppSource.read(path)
            var ranges: [Range<Int>] = []
            for declaration in allowed[path] ?? [] {
                let range = AppSource.bodyRange(of: declaration, in: source)
                #expect(range != nil, "\(path): no \(declaration.joined(separator: " › ")) (moved?)")
                if let range { ranges.append(range) }
            }
            for call in AppSource.callSites(of: "startAnalysis(", in: source) {
                let cause = call.arguments.components(separatedBy: "cause:").dropFirst().first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cause == nil || cause == ".automatic" {
                    automatic += 1
                    continue
                }
                asked += 1
                let allowedHere = ranges.contains { $0.contains(call.offset) }
                let line = source.unicodeScalars.prefix(call.offset).filter { $0 == "\n" }.count + 1
                #expect(allowedHere, "\(path):\(line): a start the user did not ask for passes \"\(call.arguments)\"")
            }
        }
        // Today: 13 automatic starts and 18 the user asks for.
        #expect(automatic == 13, "an automatic start was added or removed: check that it may not end a Pause, then update the count")
        #expect(asked == 18, "a start the user asks for was added or removed: check that it may end a Pause, then update the count")
    }

    /// A run slipped in between storing the user's change and its start (a change in Photos, a
    /// retry): that run may have read the old change, so one more run follows it, as after a
    /// change in the settings it missed (re-review of 7e8aba3). "Gespeichert … sobald die
    /// Analyse fertig ist" holds in every path.
    @Test func aChangeRefusedByARunningRunAsksForOneMore() {
        #expect(AnalysisStartCause.userChange.asksForARunAfter(running: true), "the trip change was lost behind a running run")
        #expect(!AnalysisStartCause.userChange.asksForARunAfter(running: false))
        // Taps and starts by themselves read everything anew in their own run; nothing is left.
        for cause in [AnalysisStartCause.automatic, .tap] {
            #expect(!cause.asksForARunAfter(running: true), "\(cause)")
            #expect(!cause.asksForARunAfter(running: false), "\(cause)")
        }
    }

    @Test func theEndOfThatRunStartsOneMore() {
        typealias T = AnalysisRunEndTests
        func end(_ report: AnalysisPipeline.Report?, pauseTapped: Bool = false, mayStart: Bool = true, background: Bool = false) -> AnalysisRunEnd {
            AnalysisRunEnd(report: report, settings: T.on, pauseTapped: pauseTapped, catchUpRequested: false,
                           mayStart: mayStart, background: background, changeRequested: true)
        }
        // A complete run: not the end of the analysis, one more right away.
        let done = end(T.complete(T.on))
        #expect(done.next == .followUp, "no run applied the trip change")
        #expect(!done.isFinished && done.needsResume)
        // A plan holds the start: the run goes on when it may (needsResume).
        let held = end(T.complete(T.on), mayStart: false)
        #expect(held.next == .nothing && !held.isFinished && held.needsResume)
        // Pause tapped on that run: the Pause stays, "Fortsetzen" applies the change.
        let paused = end(T.complete(T.on), pauseTapped: true)
        #expect(paused.next == .nothing && paused.keepsPause && !paused.isFinished)
        // The overnight refinement takes it in one more pass (`AppModel.refine`).
        #expect(end(T.complete(T.on), background: true).next == .followUp)
        // Ended early: as before (a retry, or the Pause), never finished.
        #expect(end(nil).next == .retry && !end(nil).isFinished)
        // Without the request nothing changes.
        #expect(T.end(T.complete(T.on)).isFinished)
    }

    /// Several requests while a change in "Dein Zuhause" is applied become one run: the one the
    /// user asked for wins, so a queued trip change still ends the Pause.
    @Test func joinedRequestsKeepWhatTheUserAskedFor() {
        #expect(Cause.automatic.joined(with: nil) == .automatic)
        #expect(Cause.automatic.joined(with: .automatic) == .automatic)
        #expect(Cause.automatic.joined(with: .tap) == .tap)
        #expect(Cause.tap.joined(with: .automatic) == .tap)
        #expect(Cause.automatic.joined(with: .userChange) == .userChange)
        #expect(Cause.userChange.joined(with: .automatic) == .userChange)
        for a in Cause.allCases {
            for b in Cause.allCases {
                #expect(a.joined(with: b).isUserInitiated == (a.isUserInitiated || b.isUserInitiated), "\(a) + \(b)")
                #expect(a.joined(with: b).startsWhilePaused == (a.startsWhilePaused || b.startsWhilePaused), "\(a) + \(b)")
            }
        }
    }
}
