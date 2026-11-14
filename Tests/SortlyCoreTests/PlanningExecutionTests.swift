import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Planning and safe execution")
struct PlanningExecutionTests {
    let planner = OrganizationPlanner(rootFolderTitle: "SORTLY", chunkSize: 50)
    let allAssets: Set<AssetID> = ids("a", 0..<300)

    func proposal(_ id: String, _ kind: ProposalKind, _ title: String, _ path: [String], _ assets: Set<AssetID>) -> AlbumProposal {
        AlbumProposal(id: SortlyID(id), kind: kind, title: title, folderPath: path, assetIDs: assets)
    }

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    @Test("Scenario I: one photo in four albums, no copies")
    func scenarioI() async throws {
        let photo: AssetID = "a-1"
        let items = [
            ConfirmedProposal(proposal: proposal("italy", .placeCollection(.country), "Italien", ["Länder"], [photo]), decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: proposal("rome", .placeCollection(.locality), "Rom", ["Länder", "Italien"], [photo]), decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: proposal("trip", .trip, "Rom · 12.05.–19.05.2024", ["Reisen"], [photo]), decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: proposal("cars", .imageCategory("vehicle"), "Fahrzeuge", ["Themen"], [photo]), decision: .createNew(title: nil, folderPath: nil)),
        ]
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let plan = planner.makePlan(from: items, inventory: try await library.currentInventory())
        #expect(plan.conflicts.isEmpty)
        #expect(plan.summary.newAlbums == 4)
        #expect(plan.summary.newFolders == 5) // SORTLY, Länder, Italien, Reisen, Themen
        #expect(plan.summary.distinctAssets == 1)
        #expect(plan.summary.totalAssignments == 4)
        #expect(plan.summary.originalsDeleted == 0 && plan.summary.originalCopiesCreated == 0)

        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        let result = try await executor.execute(confirmed(plan))
        #expect(result.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv.albums.filter { $0.assetIDs.contains(photo) }.count == 4)
        #expect(await library.assets == allAssets) // Scenario O: originals unchanged
        let rome = try #require(inv.albums.first { $0.title == "Rom" })
        #expect(inv.path(of: rome.id) == ["SORTLY", "Länder", "Italien"])
    }

    @Test("Scenario L: only the selected areas are created")
    func scenarioL() throws {
        let areas: [(ProposalKind, String)] = [
            (.placeCollection(.country), "Italien"), (.trip, "Rom"), (.screenshotCategory("order"), "Bestellungen"),
            (.imageCategory("animal.dog"), "Hunde"), (.chronology(.year), "2026"), (.mediaType("videos"), "Videos"),
        ]
        let wanted: Set<OrganizationArea> = [.places, .trips, .screenshots]
        let items = areas.enumerated().map { i, a in
            ConfirmedProposal(
                proposal: proposal("p\(i)", a.0, a.1, [], ids("a", (i * 10)..<(i * 10 + 10))),
                decision: wanted.contains(a.0.area) ? .createNew(title: nil, folderPath: nil) : .reject
            )
        }
        let plan = planner.makePlan(from: items, inventory: CollectionInventory())
        let titles = plan.steps.compactMap { step -> String? in
            if case .createAlbum(_, let t, _) = step.operation { return t }
            return nil
        }
        #expect(Set(titles) == ["Italien", "Rom", "Bestellungen"])
    }

    @Test func existingFoldersAreReusedAndExtensionAddsOnlyMissing() throws {
        let root = CollectionSnapshot(id: "f-root", title: "SORTLY", kind: .folder)
        let countries = CollectionSnapshot(id: "f-c", title: "Länder", kind: .folder, parentID: "f-root")
        let sommer = CollectionSnapshot(id: "sommer", title: "Sommerurlaub", assetIDs: ids("a", 0..<248))
        let inv = CollectionInventory([root, countries, sommer])
        let items = [
            ConfirmedProposal(proposal: proposal("garda", .trip, "Gardasee", ["Reisen"], ids("a", 0..<286)), decision: .extendExisting("sommer")),
            ConfirmedProposal(proposal: proposal("it", .placeCollection(.country), "Italien", ["Länder"], ids("a", 0..<10)), decision: .createNew(title: nil, folderPath: nil)),
        ]
        let plan = planner.makePlan(from: items, inventory: inv)
        #expect(plan.summary.newFolders == 0)
        #expect(plan.summary.extendedAlbums == 1)
        let added = plan.steps.flatMap { step -> [AssetID] in
            if case .addAssets(.existing("sommer"), let a) = step.operation { return a }
            return []
        }
        #expect(Set(added) == ids("a", 248..<286))
        #expect(plan.baseline["sommer"] == sommer.fingerprint)
    }

    @Test func duplicatePlannedTitlesAreAConflict() {
        let items = [
            ConfirmedProposal(proposal: proposal("t1", .trip, "Rom", ["Reisen"], ids("a", 0..<5)), decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: proposal("t2", .trip, "Rom", ["Reisen"], ids("a", 5..<10)), decision: .createNew(title: nil, folderPath: nil)),
        ]
        let plan = planner.makePlan(from: items, inventory: CollectionInventory())
        #expect(plan.conflicts.contains { if case .duplicatePlannedTitle(let t, _, _) = $0 { t == "Rom" } else { false } })
    }

    @Test func plannerRespectsOverridesAndDeletedAlbums() {
        let source = SortlyID("t1")
        let overrides = OverrideSet([
            UserOverride(scope: .assetInSource("a-1", source), decision: .neverAdd),
            UserOverride(scope: .source(SortlyID("t2")), decision: .doNotRecreateAlbum),
        ])
        let items = [
            ConfirmedProposal(proposal: proposal("t1", .trip, "Rom", [], ids("a", 0..<5)), decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: proposal("t2", .trip, "Paris", [], ids("a", 5..<10)), decision: .createNew(title: nil, folderPath: nil)),
        ]
        let plan = planner.makePlan(from: items, inventory: CollectionInventory(), overrides: overrides)
        #expect(plan.summary.distinctAssets == 4)
        #expect(plan.notes.contains(.skippedDeletedByUser(SortlyID("t2"))))
    }

    @Test("Scenario J: interrupted execution resumes without duplicate albums", arguments: [false, true])
    func scenarioJ(crashAfterApplying: Bool) async throws {
        let items = (0..<3).map { i in
            ConfirmedProposal(proposal: proposal("t\(i)", .trip, "Reise \(i)", ["Reisen"], ids("a", (i * 100)..<(i * 100 + 100))), decision: .createNew(title: nil, folderPath: nil))
        }
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let store = InMemoryPlanStore()
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))

        // Writes: 1 folder SORTLY, 2 folder Reisen, 3 album 0, 4+5 add, 6 album 1 ← crash here.
        await library.setFailAfterWrites(5, afterApplying: crashAfterApplying)
        _ = try await ChangeExecutor(library: library, store: store).execute(plan)

        // The process "died" while that step was running: take the journal snapshot that
        // was persisted right before the failing step touched the library.
        let journal = await store.saved
        let failedIndex = try #require(journal.last?.steps.firstIndex { if case .failed = $0.state { true } else { false } })
        let crashed = try #require(journal.first { p in if case .running = p.steps[failedIndex].state { true } else { false } })
        await library.setFailAfterWrites(nil)

        let final = try await ChangeExecutor(library: library, store: store).execute(crashed)
        #expect(final.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv.albums.count == 3)
        #expect(inv.folders.count == 2)
        for i in 0..<3 {
            let album = try #require(inv.albums.first { $0.title == "Reise \(i)" })
            #expect(album.assetIDs.count == 100)
        }
    }

    @Test("Scenario N: external change after preview blocks execution")
    func scenarioN() async throws {
        let sommer = CollectionSnapshot(id: "sommer", title: "Sommerurlaub", assetIDs: ids("a", 0..<10))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [sommer])
        let items = [ConfirmedProposal(proposal: proposal("g", .trip, "Garda", [], ids("a", 0..<20)), decision: .extendExisting("sommer"))]
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))
        await library.userEdit { inv in
            var a = inv["sommer"]!
            a.assetIDs.remove("a-3")
            inv.upsert(a)
        }
        await #expect(throws: ChangeExecutor.ExecutionError.blocked([.albumChangedSincePreview("sommer")])) {
            _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        }
    }

    @Test func draftPlansNeverRun() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        let plan = planner.makePlan(from: [], inventory: CollectionInventory())
        await #expect(throws: ChangeExecutor.ExecutionError.notConfirmed) {
            _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        }
    }

    @Test func missingWriteAccessBlocks() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets)
        await library.setWriteAllowed(false)
        let items = [ConfirmedProposal(proposal: proposal("t", .trip, "Rom", [], ids("a", 0..<3)), decision: .createNew(title: nil, folderPath: nil))]
        let plan = confirmed(planner.makePlan(from: items, inventory: CollectionInventory()))
        await #expect(throws: ChangeExecutor.ExecutionError.blocked([.writeAccessMissing])) {
            _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        }
    }

    @Test func mergeAndRenameAndMove() async throws {
        let a = CollectionSnapshot(id: "a", title: "Italien Urlaub", assetIDs: ids("a", 0..<20))
        let b = CollectionSnapshot(id: "b", title: "Gardasee", assetIDs: ids("a", 10..<40))
        let c = CollectionSnapshot(id: "c", title: "Alt", assetIDs: ids("a", 50..<55))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [a, b, c])
        let items = [
            ConfirmedProposal(proposal: proposal("m", .trip, "Gardasee · 2026", ["Reisen"], ids("a", 0..<40)),
                              decision: .merge(target: "a", sources: ["a", "b"], title: "Gardasee · 2026", folderPath: nil, removeSourceAlbums: true)),
            ConfirmedProposal(proposal: proposal("r", .trip, "Neu", [], ids("a", 50..<55)), decision: .moveExisting("c", folderPath: ["Archiv"], extend: false)),
        ]
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))
        let result = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        #expect(result.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["a"]?.title == "Gardasee · 2026")
        #expect(inv["a"]?.assetIDs == ids("a", 0..<40))
        #expect(inv["b"] == nil) // old album container removed after merge
        #expect(inv.path(of: "c") == ["SORTLY", "Archiv"])
        #expect(await library.assets == allAssets)
    }

    @Test func undoRevertsOnlyOwnChanges() async throws {
        let existing = CollectionSnapshot(id: "sommer", title: "Sommerurlaub", assetIDs: ids("a", 0..<5))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [existing])
        let items = [
            ConfirmedProposal(proposal: proposal("g", .trip, "Garda", [], ids("a", 0..<10)), decision: .renameExisting("sommer", newTitle: "Gardasee", extend: true)),
            ConfirmedProposal(proposal: proposal("r", .trip, "Rom", ["Reisen"], ids("a", 100..<110)), decision: .createNew(title: nil, folderPath: nil)),
            ConfirmedProposal(proposal: proposal("p", .trip, "Paris", ["Reisen"], ids("a", 200..<210)), decision: .createNew(title: nil, folderPath: nil)),
        ]
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)

        // The user adds an own photo to the new "Paris" album in the meantime.
        let parisID = try #require(try await library.currentInventory().albums.first { $0.title == "Paris" }?.id)
        await library.userEdit { inv in
            var p = inv[parisID]!
            p.assetIDs.insert("a-299")
            inv.upsert(p)
        }

        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await library.currentInventory()))
        let undone = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.title == "Sommerurlaub")
        #expect(inv["sommer"]?.assetIDs == ids("a", 0..<5))
        #expect(inv.albums.first { $0.title == "Rom" } == nil)
        #expect(inv[parisID]?.assetIDs == ["a-299"]) // user content kept
        #expect(await library.assets == allAssets)
    }

    @Test func managedAlbumsAreRecordedAndCanBeRemovedAgain() async throws {
        let existing = CollectionSnapshot(id: "sommer", title: "Sommerurlaub", assetIDs: ids("a", 0..<5))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [existing])
        let items = [
            ConfirmedProposal(proposal: proposal("g", .trip, "Garda", [], ids("a", 0..<10)), decision: .extendExisting("sommer")),
            ConfirmedProposal(proposal: proposal("r", .trip, "Rom", ["Reisen"], ids("a", 100..<110)), decision: .createNew(title: nil, folderPath: nil)),
        ]
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let tracker = ManagedAlbumTracker()
        var states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        #expect(states.count == 2)
        let sommer = try #require(states.first { $0.albumID == "sommer" })
        #expect(!sommer.createdBySortly)
        #expect(sommer.addedBySortly == ids("a", 5..<10))
        #expect(sommer.sourceID == SortlyID("g"))
        let rom = try #require(states.first { $0.createdBySortly })
        #expect(rom.lastKnownTitle == "Rom")
        #expect(rom.addedBySortly == ids("a", 100..<110))

        // Nothing changed by hand: reconciliation reports nothing.
        #expect(tracker.reconcile(states, with: try await library.currentInventory()).changes.isEmpty)

        // Removing both: the extended album keeps the user's photos, the created one is deleted.
        for state in states {
            let removal = confirmed(tracker.removalPlan(for: state, current: try await library.currentInventory()))
            let done = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(removal)
            #expect(done.status == .completed)
            states = tracker.record(done, into: states, inventory: try await library.currentInventory())
        }
        let inv = try await library.currentInventory()
        #expect(inv["sommer"]?.assetIDs == ids("a", 0..<5))
        #expect(inv["sommer"]?.title == "Sommerurlaub")
        #expect(inv[rom.albumID] == nil)
        #expect(states.isEmpty)
        #expect(await library.assets == allAssets)
    }

    @Test func removalKeepsPhotosTheUserAddedToACreatedAlbum() async throws {
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [])
        let items = [ConfirmedProposal(proposal: proposal("p", .trip, "Paris", [], ids("a", 200..<210)), decision: .createNew(title: nil, folderPath: nil))]
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(executed, into: [], inventory: try await library.currentInventory())
        let paris = try #require(states.first)
        await library.userEdit { inv in
            var p = inv[paris.albumID]!
            p.assetIDs.insert("a-299")
            inv.upsert(p)
        }
        let removal = confirmed(tracker.removalPlan(for: paris, current: try await library.currentInventory()))
        _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(removal)
        #expect(try await library.currentInventory()[paris.albumID]?.assetIDs == ["a-299"])
    }

    @Test func twoSuggestionsInOneAlbumAreBothRemembered() async throws {
        let existing = CollectionSnapshot(id: "best", title: "Beste Fotos", assetIDs: ids("a", 0..<5))
        let library = InMemoryPhotoLibrary(assets: allAssets, collections: [existing])
        let items = [
            ConfirmedProposal(proposal: proposal("x", .trip, "Rom", [], ids("a", 10..<15)), decision: .extendExisting("best")),
            ConfirmedProposal(proposal: proposal("y", .trip, "Paris", [], ids("a", 20..<25)), decision: .extendExisting("best")),
        ]
        let plan = confirmed(planner.makePlan(from: items, inventory: try await library.currentInventory()))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let states = ManagedAlbumTracker().record(executed, into: [], inventory: try await library.currentInventory())
        let state = try #require(states.first)
        #expect(state.allSourceIDs == [SortlyID("x"), SortlyID("y")])
        // Deleting that album keeps both suggestions from coming back.
        let overrides = OverrideSet(ManagedAlbumTracker().reconcile(states, with: CollectionInventory([])).newOverrides)
        #expect(overrides.mustNotRecreate(SortlyID("x")) && overrides.mustNotRecreate(SortlyID("y")))
    }

    @Test func managedAlbumRecordsFromOlderVersionsStillLoad() throws {
        let old = #"{"albumID":"a1","sourceID":"s1","lastKnownTitle":"Rom","lastKnownMembers":["a-1"],"addedBySortly":["a-1"],"createdBySortly":true}"#
        let state = try JSONDecoder().decode(ManagedAlbumState.self, from: Data(old.utf8))
        #expect(state.allSourceIDs == [SortlyID("s1")])
        let roundTrip = try JSONDecoder().decode(ManagedAlbumState.self, from: JSONEncoder().encode(state))
        #expect(roundTrip == state)
    }

    @Test func deletedManagedAlbumIsNotSuggestedAgain() async throws {
        let state = ManagedAlbumState(albumID: "gone", sourceID: SortlyID("trip-1"), lastKnownTitle: "Rom", lastKnownParentID: nil,
                                      lastKnownMembers: ids("a", 0..<3), addedBySortly: ids("a", 0..<3), createdBySortly: true)
        let result = ManagedAlbumTracker().reconcile([state], with: CollectionInventory([]))
        let overrides = OverrideSet(result.newOverrides)
        #expect(overrides.mustNotRecreate(SortlyID("trip-1")))
    }
}
