import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The change receipt (I01) shows what really happened, read from the journal.
@Suite("Change receipt")
struct PlanReceiptTests {
    let planner = OrganizationPlanner(rootFolderTitle: "Albumist")

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    @Test func receiptCountsWhatReallyArrivedAlbumByAlbum() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["a", "b", "c", "s1"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["s1"])])
        let italy = AlbumProposal(id: SortlyID("italien"), kind: .trip, title: "Italien", folderPath: ["Reisen"], assetIDs: ["a", "b", "gone"])
        let summer = AlbumProposal(id: SortlyID("sommer"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["c"])
        let plan = confirmed(planner.makePlan(from: [
            ConfirmedProposal(proposal: italy, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: summer, decision: .extendExisting("sommer")),
        ], inventory: try await lib.currentInventory()))
        let result = try await ChangeExecutor(library: lib, store: InMemoryPlanStore()).execute(plan)
        let receipt = PlanReceipt(plan: result, inventory: try await lib.currentInventory())

        #expect(!receipt.isUndo)
        #expect(receipt.createdFolders.contains("Reisen"))
        let created = try #require(receipt.albums.first { $0.title == "Italien" })
        #expect(created.change == .created)
        #expect(created.added == 2)          // "gone" was no longer in the library
        #expect(created.unavailable == 1)
        #expect(created.folderPath.last == "Reisen")
        let extended = try #require(receipt.albums.first { $0.title == "Sommer" })
        #expect(extended.change == .extended)
        #expect(extended.added == 1)
        #expect(receipt.photosAdded == 3)
        #expect(receipt.albumsCreated == 1 && receipt.albumsExtended == 1)
        #expect(receipt.unavailablePhotos == 1)
        #expect(receipt.originalsDeleted == 0 && receipt.originalsEdited == 0 && receipt.originalCopiesCreated == 0)
        #expect(receipt.isComplete)
        #expect(receipt.unconfirmedSteps == 0)
    }

    @Test func undoReceiptListsRemovedAlbumsAndPhotos() async throws {
        let lib = InMemoryPhotoLibrary(assets: ["a", "b", "s1", "c"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["s1"])])
        let italy = AlbumProposal(id: SortlyID("italien"), kind: .trip, title: "Italien", folderPath: [], assetIDs: ["a", "b"])
        let summer = AlbumProposal(id: SortlyID("sommer"), kind: .trip, title: "Sommer", folderPath: [], assetIDs: ["c"])
        let executor = ChangeExecutor(library: lib, store: InMemoryPlanStore())
        let result = try await executor.execute(confirmed(planner.makePlan(from: [
            ConfirmedProposal(proposal: italy, decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: summer, decision: .extendExisting("sommer")),
        ], inventory: try await lib.currentInventory())))
        let undo = try await executor.execute(confirmed(UndoPlanner().undoPlan(for: result, current: try await lib.currentInventory())))
        let receipt = PlanReceipt(plan: undo, inventory: try await lib.currentInventory())

        #expect(receipt.isUndo)
        #expect(receipt.albums.first { $0.title == "Italien" }?.change == .deleted)
        let summerLine = try #require(receipt.albums.first { $0.title == "Sommer" })
        #expect(summerLine.change == .reduced)
        #expect(summerLine.removed == 1)
        // The new album and the new "Albumist" folder go; the existing album only loses Albumist's photo.
        #expect(receipt.containersDeleted == 2)
        #expect(receipt.membershipsRemoved == 1)
        // The user's own photo stays in the user's album.
        #expect(try await lib.currentInventory()["sommer"]?.assetIDs == ["s1"])
    }

    @Test func unconfirmedAndFailedStepsAreNotCountedAsDone() {
        var record = ExecutionRecord()
        record.media["s1"] = ["x", "y"]          // intent written, library never confirmed
        record.unverified = ["s1"]
        let plan = ChangePlan(id: SortlyID("p"), createdAt: Date(), confirmedAt: Date(), status: .completedWithErrors, baseline: [:],
                              baselineCollectionIDs: [],
                              steps: [
                                  PlanStep(id: "s0", operation: .addAssets(album: .existing("a"), assets: ["x"]), sourceID: nil,
                                           state: .failed(reason: "Album nicht bearbeitbar")),
                                  PlanStep(id: "s1", operation: .addAssets(album: .existing("b"), assets: ["x", "y"]), sourceID: nil,
                                           state: .running(startedAt: Date())),
                              ],
                              conflicts: [], notes: [], resolvedKeys: [:], record: record)
        let receipt = PlanReceipt(plan: plan, inventory: CollectionInventory([
            CollectionSnapshot(id: "a", title: "Familie"), CollectionSnapshot(id: "b", title: "Urlaub"),
        ]))
        #expect(!receipt.isComplete)
        #expect(receipt.problems == ["Album nicht bearbeitbar"])
        #expect(receipt.unconfirmedSteps == 1)
        #expect(receipt.albums.first { $0.title == "Familie" }?.failed == true)
        #expect(receipt.albums.first { $0.title == "Familie" }?.added == 0)
        #expect(receipt.albums.first { $0.title == "Urlaub" }?.unconfirmed == true)
        // The intent of the unconfirmed step is not reported as done.
        #expect(receipt.albums.first { $0.title == "Urlaub" }?.added == 0)
        #expect(receipt.photosAdded == 0 && receipt.failedSteps == 1)
    }
}
