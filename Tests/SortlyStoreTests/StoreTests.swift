import Foundation
import Testing
@testable import SortlyStore
import SortlyCore
import SortlyTestSupport

@Suite("Local store")
struct StoreTests {
    func store() throws -> SortlyStore { try SortlyStore(url: nil) }

    @Test func migrationsRun() async throws {
        let s = try store()
        #expect(await s.schemaVersion == 1)
    }

    @Test func fileBackedStoreSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sortly-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let s = try SortlyStore(url: url)
            try await s.upsertAssets([AssetSnapshot(id: "a", creationDate: Fixture.date("2026-01-01"))])
        }
        let reopened = try SortlyStore(url: url)
        #expect(try await reopened.assetCount() == 1)
        #expect(await reopened.schemaVersion == 1)
    }

    @Test func upsertReportsOnlyChangedAssetsAndRoundTrips() async throws {
        let s = try store()
        let a = AssetSnapshot(id: "a", kind: .video, subtypes: [.slowMotion], creationDate: Fixture.date("2026-01-01 10:00"),
                              location: GeoCoordinate(latitude: 48.1, longitude: 11.5), locationAccuracy: 12, pixelWidth: 1920,
                              pixelHeight: 1080, duration: 12.5, burstIdentifier: nil, isFavorite: true, originalFilename: "IMG_1.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie")
        let b = AssetSnapshot(id: "b", creationDate: nil)
        #expect(try await s.upsertAssets([a, b]) == ["a", "b"])
        #expect(try await s.upsertAssets([a, b]).isEmpty)
        var modified = a
        modified.modificationDate = Fixture.date("2026-02-01")
        #expect(try await s.upsertAssets([modified]) == ["a"])
        #expect(try await s.asset("a") == modified)
        #expect(try await s.asset("b")?.creationDate == nil) // unknown dates stay unknown
    }

    @Test func incrementalAnalysisTracking() async throws {
        let s = try store()
        try await s.upsertAssets((0..<10).map { AssetSnapshot(id: AssetID("a\($0)"), creationDate: Fixture.date("2026-01-01")) })
        #expect(try await s.assetsNeedingAnalysis(version: 1, limit: 100).count == 10)
        try await s.markAnalyzed((0..<7).map { AssetID("a\($0)") }, version: 1)
        #expect(try await s.assetsNeedingAnalysis(version: 1, limit: 100).count == 3)
        // A pipeline upgrade marks everything as outdated without touching metadata.
        #expect(try await s.assetsNeedingAnalysis(version: 2, limit: 100).count == 10)
        #expect(try await s.removeAssets(notIn: ["a0", "a1"]) == 8)
        #expect(try await s.assetCount() == 2)
    }

    @Test func inventoryRoundTrip() async throws {
        let s = try store()
        let inv = CollectionInventory([
            CollectionSnapshot(id: "f", title: "SORTLY", kind: .folder, childIDs: ["a"]),
            CollectionSnapshot(id: "a", title: "Rom", parentID: "f", assetIDs: ["1", "2"]),
            CollectionSnapshot(id: "s", title: "Favoriten", kind: .smartAlbum, capabilities: [], assetIDs: ["2"]),
        ])
        try await s.saveInventory(inv)
        #expect(try await s.loadInventory() == inv)
    }

    @Test func placeCacheAndAssetPlaces() async throws {
        let s = try store()
        try await s.upsertAssets([AssetSnapshot(id: "a", creationDate: Date())])
        let cell = GeoCell(Fixture.Places.rome, sizeMeters: 1_000)
        let rome = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", timeZoneIdentifier: "Europe/Rome")
        #expect(try await s.cachedPlace(cell: cell) == nil)
        try await s.cachePlace(rome, cell: cell)
        #expect(try await s.cachedPlace(cell: cell) == rome)
        try await s.setPlace(ResolvedPlace(components: rome, source: .gpsReverseGeocoded, resolvedAt: Fixture.date("2026-01-01")), for: "a")
        #expect(try await s.places()["a"]?.components.locality == "Rom")
    }

    @Test func textSearch() async throws {
        let s = try store()
        try await s.upsertAssets([AssetSnapshot(id: "a"), AssetSnapshot(id: "b")])
        try await s.indexText("Amazon Bestellnummer 302-1234567", for: "a")
        try await s.indexText("Kassenbon Bäckerei", for: "b")
        #expect(try await s.searchText("bestellnummer") == ["a"])
        #expect(try await s.searchText("amazon bestell") == ["a"])
        #expect(try await s.searchText("Bäckerei") == ["b"])
        #expect(try await s.searchText("").isEmpty)
    }

    @Test func rulesAreVersionedInTheStore() async throws {
        let s = try store()
        let v1 = OrganizationRule(name: "Rom", area: .places, condition: .predicate(.city("Rom")), target: .existingAlbum("x"))
        let v2 = v1.revised { $0.name = "Rom (alle)" }
        try await s.saveRule(v1)
        try await s.saveRule(v2)
        #expect(try await s.currentRules() == [v2])
        #expect(try await s.ruleHistory(v1.id).map(\.version) == [1, 2])
    }

    @Test func plansAndUnfinishedPlansForResume() async throws {
        let s = try store()
        var plan = OrganizationPlanner().makePlan(from: [], inventory: CollectionInventory())
        plan.status = .running
        try await s.save(plan)
        #expect(try await s.unfinishedPlans().map(\.id) == [plan.id])
        plan.status = .completed
        try await s.save(plan)
        #expect(try await s.unfinishedPlans().isEmpty)
        #expect(try await s.planHistory().map(\.id) == [plan.id])
    }

    @Test func overridesManagedAlbumsSettingsProgress() async throws {
        let s = try store()
        let o = UserOverride(scope: .assetInAlbum("1", "a"), decision: .neverAdd)
        try await s.addOverride(o)
        #expect(try await s.overrides() == [o])
        let state = ManagedAlbumState(albumID: "a", sourceID: SortlyID("p"), lastKnownTitle: "Rom", lastKnownParentID: nil, lastKnownMembers: ["1"], addedBySortly: ["1"], createdBySortly: true)
        try await s.saveManagedAlbums([state])
        #expect(try await s.managedAlbums() == [state])
        try await s.setValue(TripCorrections(forcedBreaks: [Fixture.date("2026-01-01")]), forKey: "tripCorrections")
        #expect(try await s.value(TripCorrections.self, forKey: "tripCorrections")?.forcedBreaks.count == 1)
        try await s.setProgress(stage: "geocoding", cursor: "a42", version: 1, completed: false)
        #expect(try await s.progress(stage: "geocoding")?.cursor == "a42")
    }

    @Test func resetKeepsDecisionsByDefault() async throws {
        let s = try store()
        try await s.upsertAssets([AssetSnapshot(id: "a")])
        try await s.markAnalyzed(["a"], version: 3)
        try await s.saveResult(["dog": 0.9], kind: "vision", asset: "a", version: 3)
        try await s.addOverride(UserOverride(scope: .asset("a"), decision: .ignoreAsset))
        try await s.resetAnalysis()
        #expect(try await s.results([String: Double].self, kind: "vision").isEmpty)
        #expect(try await s.assetsNeedingAnalysis(version: 1, limit: 10).count == 1)
        #expect(try await s.overrides().count == 1)
        try await s.resetAnalysis(includingDecisions: true)
        #expect(try await s.overrides().isEmpty)
    }

    @Test func storeWorksAsExecutorJournal() async throws {
        let s = try store()
        let library = InMemoryPhotoLibrary(assets: ["1", "2"])
        let items = [ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("p"), kind: .trip, title: "Rom", assetIDs: ["1", "2"]), decision: .createNew(title: nil, folderPath: nil))]
        var plan = OrganizationPlanner().makePlan(from: items, inventory: CollectionInventory())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let result = try await ChangeExecutor(library: library, store: s).execute(plan)
        #expect(result.status == .completed)
        #expect(try await s.plan(plan.id)?.status == .completed)
    }

    @Test func bulkInsertPerformanceIsReasonable() async throws {
        let s = try store()
        let assets = (0..<20_000).map { AssetSnapshot(id: AssetID("a\($0)"), creationDate: Date(timeIntervalSince1970: Double($0) * 3600), location: GeoCoordinate(latitude: 48 + Double($0 % 100) / 1000, longitude: 11)) }
        let start = Date()
        try await s.upsertAssets(assets)
        let elapsed = Date().timeIntervalSince(start)
        #expect(try await s.assetCount() == 20_000)
        // Generous bound for CI machines; real measurements belong in TEST_PLAN.md.
        #expect(elapsed < 30)
        print("[measure] upsert 20k assets: \(String(format: "%.2f", elapsed)) s")
    }
}
