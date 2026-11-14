import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// The whole decision cycle, end to end, the way the app runs it: analysis → suggestions →
/// the recommended decisions → plan → execution in a photo library → the next analysis.
/// Every manual decision the user makes in Photos or in SORTLY must survive that cycle.
@Suite("Decision lifecycle (logic test)")
struct DecisionLifecycleTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    let planner = OrganizationPlanner(rootFolderTitle: "SORTLY", chunkSize: 50)

    struct World {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var library: InMemoryPhotoLibrary
        var pipeline: AnalysisPipeline
        var rome: [AssetID]
        var paris: [AssetID]
        var all: Set<AssetID>
        var initial: CollectionInventory
    }

    /// Munich everyday life, trips to Rome and Paris, screenshots, and an existing album
    /// "Sommer in Rom" that already holds part of the Rome trip.
    func world() async throws -> World {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                  skipping: [("2025-09-03", "2025-09-08"), ("2026-05-12", "2026-05-19")])
        let paris = lib.daily(from: "2025-09-03", to: "2025-09-08", at: GeoCoordinate(latitude: 48.8566, longitude: 2.3522), perDay: 4, hour: 10)
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for day in 1...5 { _ = lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        let shots = Set(lib.assets.filter { $0.subtypes.contains(.screenshot) }.map(\.id))
        let analyzer = FakeContentAnalyzer(
            labels: { _ in [] },
            text: { asset in shots.contains(asset.id) ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung Sendungsverfolgung" : "" }
        )
        let existing = CollectionSnapshot(id: "sommer-rom", title: "Sommer in Rom", assetIDs: Set(rome.prefix(20)))
        let smart = CollectionSnapshot(id: "smart", title: "Favoriten", kind: .smartAlbum, capabilities: [], assetIDs: Set(rome.prefix(3)))
        let initial = CollectionInventory([existing, smart])
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets, inventory: initial)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(pauseAfterChecks: nil), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, batchSize: 50
        )
        let all = Set(lib.assets.map(\.id))
        let library = InMemoryPhotoLibrary(assets: all, collections: [existing, smart])
        return World(store: store, reader: reader, library: library, pipeline: pipeline, rome: rome, paris: paris, all: all, initial: initial)
    }

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    /// What "Alle sicheren übernehmen" + "umsetzen" does in the app.
    func acceptSafe(_ snapshot: ProposalSnapshot) -> [ConfirmedProposal] {
        snapshot.proposals.compactMap { p in
            guard !p.isSensitive, !p.requiresUserName else { return nil }
            let decision = ProposalDecision.recommended(for: p, match: snapshot.matches[p.id])
            guard decision.isAccepted, !decision.isKeepExisting else { return nil }
            return ConfirmedProposal(proposal: p, decision: decision)
        }
    }

    /// Runs a plan in the library, records the albums like the app does and lets the next
    /// analysis see the result.
    @discardableResult
    func apply(_ items: [ConfirmedProposal], in w: World) async throws -> ChangePlan {
        let overrides = OverrideSet(try await w.store.overrides())
        let plan = confirmed(planner.makePlan(from: items, inventory: try await w.library.currentInventory(), overrides: overrides))
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        let after = try await w.library.currentInventory()
        try await w.store.saveManagedAlbums(ManagedAlbumTracker().record(executed, into: try await w.store.managedAlbums(), inventory: after))
        await w.reader.set(inventory: after)
        return executed
    }

    /// What the app does when it notices changes made in Photos.
    func reconcile(_ w: World) async throws {
        let current = try await w.library.currentInventory()
        await w.reader.set(inventory: current)
        let result = ManagedAlbumTracker().reconcile(try await w.store.managedAlbums(), with: current)
        for override in result.newOverrides { try await w.store.addOverride(override) }
        try await w.store.saveManagedAlbums(result.updatedStates)
    }

    // MARK: - Tests

    @Test func appliedSuggestionsAreCompleteAfterTheNextAnalysisAndNothingIsPlannedTwice() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let items = acceptSafe(first)
        #expect(items.count >= 3)
        // The existing album is extended, not duplicated.
        let romeTrip = try #require(items.first { $0.proposal.kind == .trip && Set($0.proposal.assetIDs) == Set(w.rome) })
        #expect(romeTrip.decision == .extendExisting("sommer-rom"))

        let executed = try await apply(items, in: w)
        #expect(executed.status == .completed)
        #expect(await w.library.assets == w.all) // never a photo created, copied or deleted

        _ = try await w.pipeline.run()
        let second = try #require(try await w.pipeline.latestProposals())
        for item in items {
            let match = second.matches[item.proposal.id]
            let albums = ([match?.best].compactMap { $0 } + (match?.alternatives ?? [])).map { "\($0.albumTitle) p\($0.metrics.purity) c\($0.metrics.coverage) s\($0.score)" }
            #expect(match?.status == .alreadyComplete, "\(item.proposal.title) [\(item.proposal.kind)]: \(String(describing: match?.status)) \(albums)")
        }
        // Accepting everything again changes nothing in Photos.
        let again = planner.makePlan(from: acceptSafe(second), inventory: try await w.library.currentInventory(),
                                     overrides: OverrideSet(try await w.store.overrides()))
        #expect(again.steps.isEmpty, "Second plan would change: \(again.steps.map(\.operation))")
    }

    @Test func readOnlyAlbumsAreNeverTouched() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let snapshot = try #require(try await w.pipeline.latestProposals())
        try await apply(acceptSafe(snapshot), in: w)
        let smart = try #require(try await w.library.currentInventory()["smart"])
        #expect(smart == w.initial["smart"])
    }

    @Test func undoBringsTheLibraryBack() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let snapshot = try #require(try await w.pipeline.latestProposals())
        let executed = try await apply(acceptSafe(snapshot), in: w)
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: try await w.library.currentInventory()))
        let undone = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        let inventory = try await w.library.currentInventory()
        #expect(Set(inventory.albums.map(\.id)) == Set(w.initial.albums.map(\.id)))
        for album in w.initial.albums { #expect(inventory[album.id] == album) }
    }

    @Test func photosTheUserTookOutOfAnAlbumStayOut() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        try await apply(acceptSafe(try #require(try await w.pipeline.latestProposals())), in: w)
        let states = try await w.store.managedAlbums()

        // In Photos, the user removes two Paris photos from the trip album SORTLY created.
        let parisAlbum = try #require(states.first { state in
            state.createdBySortly && state.addedBySortly == Set(w.paris) && state.lastKnownTitle.contains("·")
        })
        let removed = Array(w.paris.prefix(2))
        await w.library.userEdit { inv in
            var album = inv[parisAlbum.albumID]!
            album.assetIDs.subtract(removed)
            inv.upsert(album)
        }
        try await reconcile(w)

        _ = try await w.pipeline.run()
        let next = try #require(try await w.pipeline.latestProposals())
        // The suggestion counts as done: it is not offered again because of the two photos.
        #expect(next.matches[parisAlbum.sourceID]?.status == .alreadyComplete)
        let plan = planner.makePlan(from: acceptSafe(next), inventory: try await w.library.currentInventory(),
                                    overrides: OverrideSet(try await w.store.overrides()))
        let readded = plan.steps.flatMap { step -> [AssetID] in
            if case .addAssets(_, let assets) = step.operation { return assets } else { return [] }
        }
        #expect(Set(readded).isDisjoint(with: removed), "SORTLY would put removed photos back")
    }

    @Test func aDeletedAlbumIsNotCreatedAgain() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        try await apply(acceptSafe(try #require(try await w.pipeline.latestProposals())), in: w)
        let states = try await w.store.managedAlbums()
        let parisAlbum = try #require(states.first { $0.createdBySortly && $0.addedBySortly == Set(w.paris) })

        await w.library.userEdit { inv in inv.remove(parisAlbum.albumID) }
        try await reconcile(w)
        _ = try await w.pipeline.run()
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(!next.proposals.contains { $0.id == parisAlbum.sourceID })
    }

    @Test func aRejectedSuggestionStaysRejected() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let trip = try #require(first.proposals.first { $0.kind == .trip && Set($0.assetIDs) == Set(w.paris) })
        try await w.store.addOverride(UserOverride(scope: .source(trip.id), decision: .rejectProposal))
        _ = try await w.pipeline.run(mode: .refinement)
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(!next.proposals.contains { $0.id == trip.id })
        #expect(next.proposals.contains { $0.kind == .trip }) // the other trip is still there
    }

    @Test func anAlbumMarkedAsNotFittingIsReplacedByANewAlbum() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try #require(try await w.pipeline.latestProposals())
        let trip = try #require(first.proposals.first { $0.kind == .trip && Set($0.assetIDs) == Set(w.rome) })
        #expect(first.matches[trip.id]?.best?.albumID == "sommer-rom")

        try await w.store.addOverride(UserOverride(scope: .albumForSource("sommer-rom", trip.id), decision: .notMatchingAlbum))
        let rematched = try #require(try await w.pipeline.rematch())
        #expect(rematched.matches[trip.id]?.best?.albumID != "sommer-rom")
        let decision = ProposalDecision.recommended(for: trip, match: rematched.matches[trip.id])
        guard case .createNew = decision else {
            Issue.record("Expected a new album, got \(decision)")
            return
        }
        // It also holds after a full analysis, not only after the quick re-match.
        _ = try await w.pipeline.run(mode: .refinement)
        let next = try #require(try await w.pipeline.latestProposals())
        #expect(next.matches[trip.id]?.best?.albumID != "sommer-rom")
        // And applying it leaves the user's album exactly as it was.
        try await apply([ConfirmedProposal(proposal: trip, decision: decision)], in: w)
        #expect(try await w.library.currentInventory()["sommer-rom"] == w.initial["sommer-rom"])
    }

    /// Random libraries and decisions: whatever the user picks, the invariants hold.
    @Test(arguments: 1...40)
    func invariantsHoldForRandomDecisions(seed: Int) async throws {
        var rng = SplitMix(seed: UInt64(seed))
        let assets = (0..<200).map { AssetID("r-\($0)") }
        func randomSet(_ n: Int) -> Set<AssetID> { Set((0..<n).map { _ in assets[Int(rng.next() % 200)] }) }
        var albums: [CollectionSnapshot] = []
        for i in 0..<6 {
            let readOnly = rng.next() % 4 == 0
            albums.append(CollectionSnapshot(id: CollectionID("al-\(i)"), title: "Album \(i)",
                                             kind: readOnly ? .smartAlbum : .userAlbum, capabilities: readOnly ? [] : .all,
                                             assetIDs: randomSet(5 + Int(rng.next() % 40))))
        }
        let library = InMemoryPhotoLibrary(assets: Set(assets), collections: albums)
        let before = try await library.currentInventory()
        var items: [ConfirmedProposal] = []
        for i in 0..<8 {
            let proposal = AlbumProposal(id: SortlyID("p-\(i)"), kind: i % 2 == 0 ? .trip : .placeCollection(.locality),
                                         title: "Vorschlag \(i)", folderPath: i % 3 == 0 ? ["Reisen"] : [],
                                         assetIDs: randomSet(4 + Int(rng.next() % 30)))
            let target = albums[Int(rng.next() % UInt64(albums.count))].id
            let decision: ProposalDecision
            switch rng.next() % 5 {
            case 0: decision = .createNew(title: nil, folderPath: nil)
            case 1: decision = .extendExisting(target)
            case 2: decision = .keepExisting(target)
            case 3: decision = .renameExisting(target, newTitle: "Neu \(i)", extend: true)
            default: decision = .reject
            }
            items.append(ConfirmedProposal(proposal: proposal, decision: decision))
        }
        let plan = confirmed(planner.makePlan(from: items, inventory: before))
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(plan)
        let after = try await library.currentInventory()

        // 1. Photos are never created, copied or deleted.
        #expect(await library.assets == Set(assets))
        // 2. Read-only albums are untouched; no album loses photos in a normal plan.
        for album in before.albums {
            let now = try #require(after[album.id], "album \(album.id) disappeared")
            if !album.isEditableAlbum { #expect(now == album) }
            #expect(album.assetIDs.isSubset(of: now.assetIDs))
        }
        // 3. Rejected and kept suggestions change nothing.
        let touched = Set(executed.steps.compactMap(\.sourceID))
        for item in items where item.decision == .reject || item.decision.isKeepExisting {
            #expect(!touched.contains(item.proposal.id))
        }
        // 4. The next round (re-matching with the recorded albums, as the app does) adds nothing:
        //    applied suggestions are complete, untouched decisions are kept as they were.
        let states = ManagedAlbumTracker().record(executed, into: [], inventory: after)
        let assignments = AnalysisPipeline.assignments(states)
        let matches = AlbumMatcher().match(items.map(\.proposal), against: after, assignments: assignments)
        let second = items.compactMap { item -> ConfirmedProposal? in
            guard item.decision.isAccepted else { return nil }
            guard touched.contains(item.proposal.id) else { return item }
            let decision = ProposalDecision.recommended(for: item.proposal, match: matches[item.proposal.id])
            return decision.isAccepted ? ConfirmedProposal(proposal: item.proposal, decision: decision) : nil
        }
        let again = planner.makePlan(from: second, inventory: after)
        let adds = again.steps.filter { if case .addAssets = $0.operation { true } else { false } }
        #expect(adds.isEmpty, "seed \(seed): second run adds again")
        if !adds.isEmpty {
            for step in adds {
                let id = step.sourceID!
                let item = items.first { $0.proposal.id == id }!
                print("DEBUG decision \(item.decision) | assigned \(String(describing: assignments[id])) | match \(String(describing: matches[id]?.status)) best \(String(describing: matches[id]?.best?.albumTitle))")
                print("DEBUG steps \(executed.steps.filter { $0.sourceID == id }.map { "\($0.operation) \($0.state)" })")
            }
        }
        // 5. Undo restores every album that existed before.
        let undo = confirmed(UndoPlanner().undoPlan(for: executed, current: after))
        _ = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(undo)
        let restored = try await library.currentInventory()
        for album in before.albums { #expect(restored[album.id] == album, "seed \(seed): \(album.title) not restored") }
        #expect(Set(restored.albums.map(\.id)) == Set(before.albums.map(\.id)))
    }
}

/// Small deterministic generator for the randomized cases.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
