import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// "Erneut versuchen" (I16): only what did not happen runs again, on the albums the first run made.
@Suite("Retry of unfinished plans")
struct RetryPlannerTests {
    let done = StepState.succeeded(createdID: nil, verifiedAt: Date())

    func executed(_ steps: [PlanStep], resolved: [String: CollectionID]) -> ChangePlan {
        ChangePlan(id: SortlyID("first"), createdAt: Date(), confirmedAt: Date(), status: .completedWithErrors, baseline: [:],
                   baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [], resolvedKeys: resolved)
    }

    @Test func retryRunsOnlyWhatFailedOnTheAlbumsTheFirstRunMade() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["x", "y", "z"], collections: [
            CollectionSnapshot(id: "f1", title: "Albumist", kind: .folder),
            CollectionSnapshot(id: "a1", title: "Italien", parentID: "f1", assetIDs: ["z"]),
        ])
        let first = executed([
            PlanStep(id: "0", operation: .createFolder(key: "F", title: "Albumist", parent: .topLevel), sourceID: nil, state: done),
            PlanStep(id: "1", operation: .createAlbum(key: "A", title: "Italien", parent: .planned("F")), sourceID: SortlyID("it"), state: done),
            PlanStep(id: "2", operation: .addAssets(album: .planned("A"), assets: ["z", "x"]), sourceID: SortlyID("it"),
                     state: .failed(reason: "added media could not be verified")),
            PlanStep(id: "3", operation: .createAlbum(key: "B", title: "Rom", parent: .planned("F")), sourceID: SortlyID("rom"),
                     state: .failed(reason: "interrupted")),
            PlanStep(id: "4", operation: .addAssets(album: .planned("B"), assets: ["y"]), sourceID: SortlyID("rom"),
                     state: .skipped(reason: "target album was not created")),
        ], resolved: ["F": "f1", "A": "a1"])

        let retry = try #require(RetryPlanner().retryPlan(for: first, current: try await lib.currentInventory(), id: SortlyID("retry")))
        #expect(retry.steps.map(\.operation) == [
            .addAssets(album: .existing("a1"), assets: ["x"]),     // "z" is already in it
            .createAlbum(key: "B", title: "Rom", parent: .existing("f1")),
            .addAssets(album: .planned("B"), assets: ["y"]),
        ])
        #expect(retry.steps.map(\.sourceID) == [SortlyID("it"), SortlyID("rom"), SortlyID("rom")])
        #expect(retry.baseline.keys.sorted() == ["a1", "f1"])
        #expect(retry.retries == first.id)
        // "Rom" is new; "Italien" was made (and counted) by the first run.
        #expect(retry.freeAlbumUse(applied: false) == 1)

        var confirmed = retry
        confirmed.status = .confirmed
        confirmed.confirmedAt = Date()
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(confirmed)
        #expect(result.status == .completed)
        let after = try await lib.currentInventory()
        #expect(after["a1"]?.assetIDs == ["z", "x"])
        let rom = try #require(after.collections.values.first { $0.title == "Rom" })
        #expect(rom.parentID == "f1" && rom.assetIDs == ["y"])
        // Nothing was created twice.
        #expect(after.collections.values.filter { $0.title == "Italien" }.count == 1)
    }

    @Test func retryRespectsDeletedAlbumsAndDeliberateSkips() {
        let current = CollectionInventory([CollectionSnapshot(id: "keep", title: "Familie", assetIDs: ["mine", "x"])])
        let first = executed([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Italien", parent: .topLevel), sourceID: nil, state: done),
            // The user deleted "Italien" since: nothing is added to it again.
            PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["x"]), sourceID: nil, state: .failed(reason: "interrupted")),
            // Kept on purpose because the user's photo is in it: not retried.
            PlanStep(id: "2", operation: .deleteCollection("keep", title: "Familie"), sourceID: nil,
                     state: .skipped(reason: "kept: the album holds photos added meanwhile; only Albumist's photos were taken out")),
            // Left undone by the user ("So lassen"): can be retried.
            PlanStep(id: "3", operation: .removeAssets(album: "keep", assets: ["x"]), sourceID: nil,
                     state: .skipped(reason: StepState.leftByUserReason)),
        ], resolved: ["A": "gone"])
        let retry = RetryPlanner().retryPlan(for: first, current: current, id: SortlyID("r"))
        #expect(retry?.steps.map(\.operation) == [.removeAssets(album: "keep", assets: ["x"])])
    }

    @Test func nothingToRetry() {
        let complete = executed([PlanStep(id: "0", operation: .createAlbum(key: "A", title: "X", parent: .topLevel), sourceID: nil, state: done)],
                                resolved: ["A": "a"])
        #expect(RetryPlanner().retryPlan(for: complete, current: CollectionInventory()) == nil)
        var undo = executed([PlanStep(id: "0", operation: .deleteCollection("a", title: "X"), sourceID: nil, state: .failed(reason: "x"))], resolved: [:])
        undo.reverts = SortlyID("p")
        #expect(RetryPlanner().retryPlan(for: undo, current: CollectionInventory()) == nil)
    }
}

/// The diagnostic report names no album, folder or photo (I16).
@Suite("Diagnostic report")
struct PlanDiagnosticsTests {
    @Test func planLineHasCountsAndReasonCodesButNoNames() {
        var record = ExecutionRecord()
        record.unverified = ["2"]
        let plan = ChangePlan(id: SortlyID("0123456789abcdef"), createdAt: Date(timeIntervalSince1970: 0), confirmedAt: nil,
                              status: .completedWithErrors, baseline: [:], baselineCollectionIDs: [],
                              steps: [
                                  PlanStep(id: "0", operation: .createAlbum(key: "Urlaub-Mallorca", title: "Mallorca mit Anna", parent: .topLevel),
                                           sourceID: nil, state: .succeeded(createdID: "album-secret", verifiedAt: Date())),
                                  PlanStep(id: "1", operation: .addAssets(album: .planned("Urlaub-Mallorca"), assets: ["IMG-secret-1", "IMG-secret-2"]),
                                           sourceID: nil, state: .failed(reason: "Error Domain=PHPhotosErrorDomain Code=3300 \"Mallorca mit Anna\"")),
                                  PlanStep(id: "2", operation: .renameCollection("album-secret", from: "Anna", to: "Mallorca"), sourceID: nil,
                                           state: .failed(reason: "album no longer exists")),
                              ],
                              conflicts: [], notes: [], resolvedKeys: ["Urlaub-Mallorca": "album-secret"], record: record)
        let line = PlanDiagnostics.describe(plan)
        #expect(line.contains("plan 01234567"))
        #expect(line.contains("steps 3: 1 ok, 2 failed, 0 skipped, 0 open"))
        #expect(line.contains("error PHPhotosErrorDomain 3300 ×1"))
        #expect(line.contains("album no longer exists ×1"))
        #expect(line.contains("unverified 1"))
        for secret in ["Mallorca", "Anna", "secret", "Urlaub"] {
            #expect(!line.contains(secret), "leaks \(secret)")
        }
    }
}
