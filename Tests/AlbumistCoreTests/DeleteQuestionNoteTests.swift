import Foundation
import Synchronization
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Before Albumist deletes albums or folders in Photos, iOS asks once more ("delete 15 albums
/// and 9 folders"). Albumist's own question before it did not say so, and the word "delete"
/// scared (review 18.11., P3-07 / G3-09). Every confirmation that leads there now announces
/// it, with one sentence (`DeleteQuestionNote`), and only when the plan really deletes one.
/// The confirmations are found by what they call, not by line numbers.
///
/// What the source tests see, and what they do not (second review, SHOULD-2):
/// - Dialogs: `.confirmationDialog(…)` and `.alert(…)`, with their buttons and message as
///   trailing closures (`{ … } message: { … }`) or as labelled arguments (`actions: { … }`,
///   `message: { … }`). A button counts as deleting when it calls one of `deletingCalls`, a
///   function of the same file that does (`prepare(state)` → `removalPlan(`), or a function of
///   `AppModel` called as `model.name(` that does. Not followed: deeper chains, wrappers in
///   other view files, a dialog built by a helper that returns it, a `Menu` or swipe action
///   that deletes without a dialog.
/// - For a dialog the test checks only that its message uses `DeleteQuestionNote`, not the
///   condition it passes: that the condition is right is what the core tests here check
///   (`DeleteQuestion`, `InterruptedPlanUndo.deletesCollections`,
///   `deletesCollections`), and the app passes the result of `AppModel` (syntax only on Linux).
/// - Without a dialog (`directCalls`) it checks the `if` the note stands in, next to the call.
@Suite("Announcing the iOS question before albums are deleted")
struct DeleteQuestionNoteTests {
    static let german = "iOS fragt gleich noch einmal, ob Albumist die Alben löschen darf. Deine Fotos bleiben."
    static let english = "iOS will ask once more whether Albumist may delete the albums. Your photos stay."
    /// What the views use to say it.
    static let note = "DeleteQuestionNote"
    /// The ways into the plan executor that can delete albums or folders: an undo, the undo of
    /// an interrupted plan, and the removal of one of Albumist's albums.
    static let deletingCalls = ["undo(", "undoInterruptedPlan(", "removalPlan("]
    /// The ways that run such a plan without a dialog of their own: going on with an
    /// interrupted undo ("Rest zurücknehmen") or an interrupted removal ("Rest anlegen"), and
    /// carrying out a plan built elsewhere in the preview (the removal of an album from "Alben
    /// von Albumist", or the retry of one). `execute(` runs every plan the preview shows; only
    /// `PlanReviewView` calls it, and it shows removals, so it is checked there. Calls of a
    /// plan that can never delete would need leaving out here (none today).
    static let directCalls = ["resumeInterruptedPlan(", "execute("]

    // MARK: Only when albums are deleted

    static let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))

    static func plan(_ steps: [PlanStep], resolved: [String: CollectionID] = [:], record: ExecutionRecord? = nil) -> ChangePlan {
        var p = ChangePlan(id: AlbumistID("first"), createdAt: Date(), confirmedAt: Date(), status: .completed, baseline: [:],
                           baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [], resolvedKeys: resolved)
        p.record = record
        return p
    }

    /// An undo of a plan that made an album deletes it: iOS asks.
    @Test func undoOfANewAlbumDeletesIt() {
        let made = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["x"]), sourceID: nil, state: Self.done),
        ], resolved: ["A": "a1"])
        let current = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x"])])
        let undo = UndoPlanner().undoPlan(for: made, current: current, owned: ["a1": ["x"]])
        #expect(undo.deletesCollections)
    }

    /// An undo that only takes photos out of the user's own album deletes nothing: no word about
    /// deleting. So does an album the user put photos of their own into: it stays.
    @Test func undoThatOnlyTakesPhotosOutDeletesNothing() {
        let extended = Self.plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("mine"), assets: ["x"]), sourceID: nil, state: Self.done),
        ])
        let current = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "x"])])
        let undo = UndoPlanner().undoPlan(for: extended, current: current, owned: ["mine": ["x"]])
        #expect(!undo.steps.isEmpty)
        #expect(!undo.deletesCollections)

        let made = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["x"]), sourceID: nil, state: Self.done),
        ], resolved: ["A": "a1"])
        let filledByUser = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x", "own"])])
        #expect(!UndoPlanner().undoPlan(for: made, current: filledByUser, owned: ["a1": ["x"]]).deletesCollections)
    }

    /// An interrupted undo ("Rest zurücknehmen") says it while a deletion is still open, not
    /// after it ran.
    @Test func onlyOpenDeletionsCount() {
        var undo = Self.plan([
            PlanStep(id: "0", operation: .removeAssets(album: "mine", assets: ["x"]), sourceID: nil, state: Self.done),
            PlanStep(id: "1", operation: .deleteCollection("a1", title: "Rom"), sourceID: nil, state: .pending),
        ])
        #expect(undo.deletesCollections)
        undo.steps[1].state = Self.done
        #expect(!undo.deletesCollections)
    }

    /// "Alles zurücknehmen" of an interrupted plan: the album whose step was cut off counts when
    /// it is there under the id Photos gave it, as the undo will settle it.
    @Test func undoOfAnInterruptedPlanCountsTheAlbumMadeBeforeTheInterruption() {
        let current = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom")])
        let cutOff = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], resolved: ["A": "a1"])
        #expect(InterruptedPlanUndo.deletesCollections(interrupted: cutOff, current: current))
        var noted = ExecutionRecord()
        noted.maybeCreated["A"] = "a1"
        let unanswered = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], record: noted)
        #expect(InterruptedPlanUndo.deletesCollections(interrupted: unanswered, current: current))
        // Nothing made yet: nothing to delete.
        let nothingYet = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ])
        #expect(!InterruptedPlanUndo.deletesCollections(interrupted: nothingYet, current: CollectionInventory()))
        // Only photos added to the user's album before the interruption: taken out, nothing deleted.
        let onlyAdded = Self.plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("mine"), assets: ["x"]), sourceID: nil, state: Self.done),
            PlanStep(id: "1", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .pending),
        ])
        let mine = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "x"])])
        #expect(!InterruptedPlanUndo.deletesCollections(interrupted: onlyAdded, current: mine))
    }

    /// The app's list may be older than Photos: an interrupted plan never reached the step that
    /// reads the albums again, so its new album is not in it, while the undo (after
    /// `reconcileInterrupted` and a fresh read) deletes it. The question reads the albums at the
    /// tap, and looks up on its own an album of the plan the list still lacks (second review of
    /// P3-07, MUST-1; third review, NIT-1).
    @Test func anAlbumThePlanMadeThatTheAppsListLacksCounts() async {
        let stale = CollectionInventory()
        let empty = CollectionSnapshot(id: "a1", title: "Rom")
        let made = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .createAlbum(key: "B", title: "Paris", parent: .topLevel), sourceID: nil, state: .pending),
        ], resolved: ["A": "a1"])
        #expect(await Self.question(listed: CollectionInventory([empty])).interruptedUndo(made, cached: stale))
        #expect(await Self.question(listed: CollectionInventory(), found: [empty]).interruptedUndo(made, cached: stale))
        // Its id only written down inside the change (Photos ran it, the app ended).
        var noted = ExecutionRecord()
        noted.maybeCreated["A"] = "a1"
        let cutOff = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], record: noted)
        #expect(await Self.question(listed: CollectionInventory([empty])).interruptedUndo(cutOff, cached: stale))
        // An album found by its name after an interruption is never deleted: no word about it.
        var adopted = ExecutionRecord()
        adopted.adoptedKeys = ["A"]
        let found = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
        ], resolved: ["A": "a1"], record: adopted)
        #expect(found.collectionsMade.isEmpty)
        #expect(!(await Self.question(listed: CollectionInventory([empty])).interruptedUndo(found, cached: stale)))
    }

    /// "Rest rückgängig machen" after an undo that deleted "Rom": the album is gone for good, the
    /// look-up finds nothing, and only the user's photos are taken out: nothing said.
    @Test func anAlbumAnEarlierUndoDeletedIsNotCounted() async {
        let made = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .existing("mine"), assets: ["x"]), sourceID: nil, state: Self.done),
        ], resolved: ["A": "a1"])
        let listed = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "x"])])
        let records = [ManagedAlbumState(albumID: "mine", sourceID: AlbumistID("s"), lastKnownTitle: "Familie", lastKnownParentID: nil,
                                         lastKnownMembers: ["own", "x"], addedByAlbumist: ["x"], createdByAlbumist: false)]
        var earlier = Self.plan([
            PlanStep(id: "0", operation: .deleteCollection("a1", title: "Rom"), sourceID: nil, state: Self.done),
        ])
        earlier.reverts = made.id
        #expect(!(await Self.question(listed: listed).undo(made, albums: records, waiting: [], earlierUndos: [earlier], cached: listed)))
    }

    /// An interrupted removal from "Alben von Albumist" (no `reverts`), or its retry, deletes
    /// the album again when it goes on: "Rest anlegen" runs the deletion, and iOS asks. The plan
    /// says so on its own (MUST-2); the screens must not ask for an undo as well (below).
    @Test func anInterruptedRemovalStillDeletes() {
        let state = ManagedAlbumState(albumID: "a1", sourceID: AlbumistID("s"), lastKnownTitle: "Rom", lastKnownParentID: nil,
                                      lastKnownMembers: ["x"], addedByAlbumist: ["x"], createdByAlbumist: true)
        var removal = ManagedAlbumTracker().removalPlan(for: state, current: CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x"])]))
        #expect(removal.reverts == nil)
        removal.steps[0].state = .running(startedAt: Date())
        #expect(removal.deletesCollections)
    }

    // MARK: The question at the tap (third review)

    static let rome = CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x"])

    /// A plan that made "Rom" (a1) and put x in it.
    static var madeRome: ChangePlan {
        plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["x"]), sourceID: nil, state: done),
        ], resolved: ["A": "a1"])
    }

    static func question(listed: CollectionInventory?, found: [CollectionSnapshot] = [], limit: Duration = .seconds(3)) -> DeleteQuestion {
        DeleteQuestion(listAlbums: {
            guard let listed else { throw CancellationError() }
            return listed
        }, lookUp: { id in found.first { $0.id == id } }, limit: limit)
    }

    /// The plan's results are not stored yet (a full disk): "Rückgängig machen" stores them
    /// first and then deletes "Rom", so iOS asks. The question folds them in the same way
    /// (SHOULD-1; before: no records, nothing predicted, "Deine Fotos bleiben unverändert").
    @Test func resultsStillWaitingToBeStoredAreFoldedIn() async {
        let answer = await Self.question(listed: CollectionInventory([Self.rome]))
            .undo(Self.madeRome, albums: [], waiting: [Self.madeRome], earlierUndos: [], cached: CollectionInventory())
        #expect(answer)
    }

    /// An album of the plan the list lacks is looked up on its own (W3): there, it is deleted;
    /// gone (the user deleted it, a removal took it, a create that never landed), nothing is
    /// said (NIT-1; before, every such undo announced a question iOS never asked).
    @Test func anAlbumTheListLacksIsLookedUpOnItsOwn() async {
        let records = ManagedAlbumTracker().record(Self.madeRome, into: [], inventory: CollectionInventory([Self.rome]))
        let found = await Self.question(listed: CollectionInventory(), found: [Self.rome])
            .undo(Self.madeRome, albums: records, waiting: [], earlierUndos: [], cached: CollectionInventory())
        #expect(found)
        let gone = await Self.question(listed: CollectionInventory())
            .undo(Self.madeRome, albums: records, waiting: [], earlierUndos: [], cached: CollectionInventory())
        #expect(!gone)
        // An id written down for a create that never landed.
        var noted = ExecutionRecord()
        noted.earlierMaybeCreated = ["ghost"]
        let interrupted = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], record: noted)
        #expect(!(await Self.question(listed: CollectionInventory()).interruptedUndo(interrupted, cached: CollectionInventory())))
        // The interrupted plan's album, only the list lacks it.
        let cutOff = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], resolved: ["A": "a1"])
        let empty = CollectionSnapshot(id: "a1", title: "Rom")
        #expect(await Self.question(listed: CollectionInventory(), found: [empty]).interruptedUndo(cutOff, cached: CollectionInventory()))
    }

    /// Fourth review, NIT-1: a look-up that fails is not "gone". The answer is the safe side,
    /// since the album may still be there and be deleted.
    @Test func aFailedLookUpTakesTheSafeSide() async {
        let records = ManagedAlbumTracker().record(Self.madeRome, into: [], inventory: CollectionInventory([Self.rome]))
        let failing = DeleteQuestion(listAlbums: { CollectionInventory() },
                                     lookUp: { _ in throw CancellationError() })
        #expect(await failing.undo(Self.madeRome, albums: records, waiting: [], earlierUndos: [], cached: CollectionInventory()))
    }

    /// Fourth review, NIT-2: the undo completes the list for every album Albumist keeps a
    /// record of, not only those of this plan. "Bern" (b1) was made by an earlier plan with y;
    /// the user took y out; this plan put z in it. Undone, b1 is empty and Albumist's own, so it
    /// is deleted, also while the list lacks it for a while (iCloud).
    @Test func anAlbumOfAnotherPlanTheListLacksIsLookedUpToo() async {
        let madeBern = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "B", title: "Bern", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "b1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .planned("B"), assets: ["y"]), sourceID: nil, state: Self.done),
        ], resolved: ["B": "b1"])
        let addedZ = Self.plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("b1"), assets: ["z"]), sourceID: nil, state: Self.done),
        ])
        let bernBefore = CollectionSnapshot(id: "b1", title: "Bern", assetIDs: ["y"])
        let bernNow = CollectionSnapshot(id: "b1", title: "Bern", assetIDs: ["z"])
        var records = ManagedAlbumTracker().record(madeBern, into: [], inventory: CollectionInventory([bernBefore]))
        records = ManagedAlbumTracker().record(addedZ, into: records, inventory: CollectionInventory([bernNow]))
        // With the album in the list, the undo deletes it.
        #expect(await Self.question(listed: CollectionInventory([bernNow]))
            .undo(addedZ, albums: records, waiting: [], earlierUndos: [], cached: CollectionInventory()))
        // The list lacks it for a while; looked up on its own, it is still there.
        #expect(await Self.question(listed: CollectionInventory(), found: [bernNow])
            .undo(addedZ, albums: records, waiting: [], earlierUndos: [], cached: CollectionInventory()))
    }

    /// Photos could not be read: the safe side, iOS may ask whenever the plan made an album or
    /// folder (NIT-2), and never for a plan that made none and deletes nothing.
    @Test func withoutTheAlbumListTheAnswerIsTheSafeSide() async {
        let records = ManagedAlbumTracker().record(Self.madeRome, into: [], inventory: CollectionInventory([Self.rome]))
        // The app's list says the user put a photo of their own in: no deletion planned from it.
        let cached = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x", "own"])])
        #expect(await Self.question(listed: nil).undo(Self.madeRome, albums: records, waiting: [], earlierUndos: [], cached: cached))
        #expect(await Self.question(listed: nil).interruptedUndo(Self.madeRome, cached: cached))
        let onlyAdded = Self.plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("mine"), assets: ["x"]), sourceID: nil, state: Self.done),
        ])
        let mine = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "x"])])
        #expect(!(await Self.question(listed: nil).undo(onlyAdded, albums: [], waiting: [], earlierUndos: [], cached: mine)))
    }

    /// Photos takes long to list the albums: the dialog does not wait for it. After the limit
    /// the read is cancelled and the answer is the safe side (SHOULD-2). Told by the answer, not
    /// by the clock (the parallel suite starved a timer for 28 s): the list, had it been waited
    /// for, says the user's own photo keeps "Rom", so nothing would be announced.
    @Test func aSlowAlbumListIsNotWaitedFor() async {
        let cancelled = Locked(false)
        let slow = DeleteQuestion(listAlbums: {
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
            return CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x", "own"])])
        }, lookUp: { _ in nil }, limit: .milliseconds(50))
        let records = ManagedAlbumTracker().record(Self.madeRome, into: [], inventory: CollectionInventory([Self.rome]))
        let answer = await slow.undo(Self.madeRome, albums: records, waiting: [], earlierUndos: [],
                                     cached: CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x", "own"])]))
        #expect(answer)
        // The read is told to stop (it may take a moment to hear it).
        for _ in 0..<2_000 where !cancelled.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.withLock { $0 })
    }

    /// An interrupted removal from "Alben von Albumist" is called one: "Entfernen wurde
    /// unterbrochen", "Rest entfernen", not "Anlegen" right above "iOS fragt … löschen" (NIT-5).
    @Test func anInterruptedRemovalIsCalledARemoval() throws {
        for (file, type) in [("App/Albumist/Views/OverviewView.swift", "struct InterruptedPlanCard"),
                             ("App/Albumist/Views/SettingsView.swift", "struct InterruptedHistoryRow")] {
            let source = AppSource.code(try AppSource.read(file), keepStrings: true)
            let body = try #require(AppSource.body(of: type, in: source), "\(type)")
            #expect(body.contains("\"Rest entfernen\""), "\(type)")
            #expect(body.contains("removalSources"), "\(type)")
        }
        let card = AppSource.code(try AppSource.read("App/Albumist/Views/OverviewView.swift"), keepStrings: true)
        #expect(AppSource.body(of: "struct InterruptedPlanCard", in: card)?.contains("\"Entfernen wurde unterbrochen\"") == true)
    }

    /// The buttons that ask first show that Albumist checks, and take no second tap meanwhile
    /// (SHOULD-2): a spinner beside the title (`checkingBeside`), and a guard.
    @Test func theButtonsThatAskFirstShowTheyCheck() throws {
        var found = 0
        for file in AppSource.swiftFiles(under: "App/Albumist/Views") {
            let source = try AppSource.read(file)
            for call in ["undoDeletesCollections(", "interruptedUndoDeletesCollections("] {
                for site in AppSource.callSites(of: call, in: source) {
                    let code = Self.scalars(AppSource.code(source))
                    let body = try #require(Self.enclosingType(of: site.offset, in: source).map { Self.string(code[$0]) })
                    found += 1
                    #expect(body.contains(".checkingBeside("), "\(file): \(call) without a spinner")
                    #expect(body.contains("guard !"), "\(file): \(call) without ignoring a second tap")
                }
            }
        }
        #expect(found >= 4)
    }

    // MARK: Reading the App

    private struct Dialog {
        var kind: String
        var file: String
        var line: Int
        var action: String
        var message: String
    }

    private static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// The index just past the bracket that closes the one at `open`, in code with comments and
    /// strings blanked.
    private static func closing(_ code: [Unicode.Scalar], from open: Int) -> Int? {
        let opening = code[open]
        let close: Unicode.Scalar = opening == "(" ? ")" : "}"
        var depth = 0
        for index in open..<code.count {
            if code[index] == opening { depth += 1 }
            if code[index] == close {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
        }
        return nil
    }

    private static func skipSpaces(_ code: [Unicode.Scalar], _ index: Int) -> Int {
        var i = index
        while i < code.count, code[i] == " " || code[i] == "\n" || code[i] == "\t" { i += 1 }
        return i
    }

    /// The closure after `label` (e.g. "message:") from `index` on, before `limit`: its range.
    private static func labelledClosure(_ label: String, in code: [Unicode.Scalar], from index: Int, before limit: Int) -> Range<Int>? {
        let wanted = Array(label.unicodeScalars)
        var i = index
        while i + wanted.count <= limit {
            if Array(code[i..<(i + wanted.count)]) == wanted,
               i == 0 || !(CharacterSet.alphanumerics.contains(code[i - 1]) || code[i - 1] == "_") {
                let open = skipSpaces(code, i + wanted.count)
                if open < limit, code[open] == "{", let end = closing(code, from: open) { return open..<end }
            }
            i += 1
        }
        return nil
    }

    /// Every `.confirmationDialog(…)` and `.alert(…)` of the App's views: its buttons and its
    /// message, as code (comments and strings blanked), from trailing closures (`{ … } message:
    /// { … }`) or labelled arguments (`actions: { … }, message: { … }`).
    private static func dialogs() throws -> [Dialog] {
        try AppSource.swiftFiles(under: "App/Albumist").flatMap { dialogs(in: try AppSource.read($0), file: $0) }
    }

    private static func dialogs(in source: String, file: String) -> [Dialog] {
        var found: [Dialog] = []
        let code = scalars(AppSource.code(source))
        for kind in ["confirmationDialog", "alert"] {
            for site in AppSource.callSites(of: kind + "(", in: source) {
                let open = site.offset + kind.unicodeScalars.count
                guard let argumentsEnd = closing(code, from: open) else { continue }
                var action = labelledClosure("actions:", in: code, from: open, before: argumentsEnd)
                var message = labelledClosure("message:", in: code, from: open, before: argumentsEnd)
                let trailing = skipSpaces(code, argumentsEnd)
                if action == nil, trailing < code.count, code[trailing] == "{", let end = closing(code, from: trailing) {
                    action = trailing..<end
                    // `message:` right after the buttons, nothing between.
                    let after = skipSpaces(code, end)
                    let label = Array("message:".unicodeScalars)
                    if message == nil, after + label.count <= code.count, Array(code[after..<(after + label.count)]) == label {
                        message = labelledClosure("message:", in: code, from: after, before: code.count)
                    }
                }
                guard let action else { continue }
                found.append(Dialog(kind: kind, file: file, line: line(of: site.offset, in: code), action: string(code[action]),
                                    message: message.map { string(code[$0]) } ?? ""))
            }
        }
        return found
    }

    private static func line(of offset: Int, in code: [Unicode.Scalar]) -> Int {
        code[..<offset].filter { $0 == "\n" }.count + 1
    }

    /// Whether `code` calls one of `calls`, directly, through a function declared in `source`
    /// (the album removal's button calls `prepare(state)`, which asks for `removalPlan(`), or
    /// through a function of `AppModel` it calls as `model.name(`.
    private static func reaches(_ calls: [String], from code: String, in source: String) throws -> Bool {
        func callsOne(_ body: String) -> Bool { calls.contains { !AppSource.calls(of: $0, in: body).isEmpty } }
        if callsOne(code) { return true }
        let names = Set(code.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\(/).map { String($0.output.1) })
        if names.contains(where: { AppSource.body(of: "func \($0)(", in: source).map(callsOne) ?? false }) { return true }
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let onModel = Set(code.matches(of: /\bmodel\.([A-Za-z_][A-Za-z0-9_]*)\(/).map { String($0.output.1) })
        return onModel.contains { AppSource.body(of: "func \($0)(", in: model).map(callsOne) ?? false }
    }

    // MARK: Tests

    /// Every confirmation whose button leads to an undo or a removal says that iOS asks next.
    @Test func everyConfirmationBeforeDeletingAlbumsAnnouncesTheIOSQuestion() throws {
        var deleting: [String] = []
        for dialog in try Self.dialogs() {
            let source = try AppSource.read(dialog.file)
            guard try Self.reaches(Self.deletingCalls, from: dialog.action, in: source) else { continue }
            let place = "\(dialog.file.split(separator: "/").last ?? ""):\(dialog.line)"
            deleting.append(place)
            #expect(dialog.message.contains(Self.note), "\(place): the confirmation does not announce the iOS question")
        }
        // The confirmations the review names, and the one on the result card: none is lost by a
        // change in how they are written.
        let files = Set(deleting.map { $0.split(separator: ":").first.map(String.init) ?? "" })
        for named in ["PlanReceiptView.swift", "OverviewView.swift", "SettingsView.swift", "ManagedAlbumsView.swift", "PlanReviewView.swift"] {
            #expect(files.contains(named), "no confirmation before deleting found in \(named): \(deleting)")
        }
        #expect(deleting.count >= 5, "\(deleting)")
        // Alerts are read too (none of them deletes today).
        #expect(try Self.dialogs().contains { $0.kind == "alert" && !$0.message.isEmpty })
    }

    /// The scan finds a confirmation written with labelled closures and one that deletes
    /// through a function of `AppModel`, and sees whether its message has the note.
    @Test func theScanReadsLabelledClosuresAndModelWrappers() throws {
        let sample = """
        struct Sample: View {
            var body: some View {
                Text("x")
                    .confirmationDialog("Weg?", isPresented: $a, titleVisibility: .visible, actions: {
                        Button("Ja") { Task { await model.undoInterruptedPlan() } }
                    }, message: {
                        Text("Ohne Satz")
                    })
                    .alert("Weg?", isPresented: $b) {
                        Button("Ja") { Task { await model.undo(plan) } }
                    } message: {
                        DeleteQuestionNote.message(Text("Mit Satz"), deletes: true)
                    }
                    .alert("Info", isPresented: $c) {
                        Button("OK") {}
                    }
            }
        }
        """
        let found = Self.dialogs(in: sample, file: "Sample.swift")
        #expect(found.map(\.kind) == ["confirmationDialog", "alert", "alert"])
        let deleting = try found.filter { try Self.reaches(Self.deletingCalls, from: $0.action, in: sample) }
        #expect(deleting.map { $0.message.contains(Self.note) } == [false, true])
    }

    /// The ways that delete without a dialog of their own (going on with an interrupted plan,
    /// carrying out a removal in the preview) say it on the screen that has the button: the
    /// type around the call shows `DeleteQuestionNote.text` under an `if` that asks whether the
    /// plan deletes (`deletesCollections`, `deletedContainers`), and nothing else. The note in
    /// the type's undo dialog does not count (second review of P3-07, SHOULD-1). Asking
    /// whether the plan is an undo as well hid the note for an interrupted removal from "Alben
    /// von Albumist", whose "Rest anlegen" deletes the album again (MUST-2).
    @Test func screensThatDeleteWithoutADialogAnnounceTheIOSQuestion() throws {
        var checked: [String] = []
        for file in AppSource.swiftFiles(under: "App/Albumist/Views") {
            let source = try AppSource.read(file)
            let code = Self.scalars(AppSource.code(source))
            for call in Self.directCalls {
                for site in AppSource.callSites(of: call, in: source) {
                    let body = try #require(Self.enclosingType(of: site.offset, in: source).map { Self.string(code[$0]) },
                                            "\(file): \(call) outside a view")
                    let place = "\(file.split(separator: "/").last ?? ""):\(Self.line(of: site.offset, in: code))"
                    checked.append(place)
                    let conditions = Self.conditions(guarding: "\(Self.note).text", in: body)
                    #expect(!conditions.isEmpty, "\(place): \(call) without announcing the iOS question next to it")
                    for condition in conditions {
                        let asksForDeletion = condition.contains("deletesCollections") || condition.contains("deletedContainers")
                        let asksMore = ["reverts", "isUndo", "&&", "||"].contains { condition.contains($0) }
                        #expect(asksForDeletion && !asksMore, "\(place): the note shows only if \(condition)")
                    }
                }
            }
        }
        #expect(checked.count >= 3, "\(checked)")
    }

    /// The innermost `struct` around `offset`.
    private static func enclosingType(of offset: Int, in source: String) -> Range<Int>? {
        var enclosing: Range<Int>?
        for match in AppSource.code(source).matches(of: /(?m)^\s*(?:private |fileprivate )?struct ([A-Za-z0-9_]+)/) {
            guard let range = AppSource.bodyRange(of: "struct \(match.output.1)", in: source), range.contains(offset) else { continue }
            if enclosing.map({ range.count < $0.count }) ?? true { enclosing = range }
        }
        return enclosing
    }

    /// The condition of the `if` each `shown` stands in, directly (`if a { shown }`), as code.
    private static func conditions(guarding shown: String, in body: String) -> [String] {
        var found: [String] = []
        var rest = body[...]
        while let at = rest.range(of: shown) {
            let before = body[..<at.lowerBound]
            if let keyword = before.range(of: "if ", options: .backwards),
               let brace = before[keyword.upperBound...].firstIndex(of: "{"),
               before[before.index(after: brace)...].allSatisfy(\.isWhitespace) {
                found.append(before[keyword.upperBound..<brace].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            rest = body[at.upperBound...]
        }
        return found
    }

    /// One sentence, in German and English, kept in one place.
    @Test func theSentenceIsOneStringWithEnglish() throws {
        let file = try #require(AppSource.swiftFiles(under: "App/Albumist").first {
            (try? AppSource.code(AppSource.read($0)).contains("enum \(Self.note)")) == true
        }, "no enum \(Self.note) in the App")
        let source = AppSource.code(try AppSource.read(file), keepStrings: true)
        #expect(source.contains("\"\(Self.german)\""))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: AppSource.root.appendingPathComponent("App/Albumist/Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let entry = try #require(strings[Self.german] as? [String: Any])
        let english = ((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(english?["value"] as? String == Self.english)
        // Said only here: no second wording of the same sentence in the views.
        for other in AppSource.swiftFiles(under: "App/Albumist") where other != file {
            #expect(!AppSource.code(try AppSource.read(other), keepStrings: true).contains(Self.german), "\(other)")
        }
    }
}
