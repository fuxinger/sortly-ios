import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Regression tests for the analysis findings of the cross-review of 14.11.2026
/// (docs/review/AUDIT_2026-11-14.md, group 2, 4.2, 5.1, 5.4, 5.6).
@Suite("Audit 14.11.2026: analysis")
struct AuditAnalysisTests {
    static let map: OfflineWorldMap = PipelineTests.map

    /// Analyzer whose answers the test changes between runs.
    final class ScriptedAnalyzer: ContentAnalyzing, @unchecked Sendable {
        struct State {
            /// Content reads that fail before one succeeds, per asset.
            var contentFailures: [AssetID: Int] = [:]
            /// Text from the original (needs the network for `cloudOnly`) and from the preview.
            var original: [AssetID: String] = [:]
            var preview: [AssetID: String] = [:]
            var cloudOnly: Set<AssetID> = []
            var textCalls: [(AssetID, Bool)] = []
            var contentCalls = 0
        }
        let state = Mutex(State())
        let onText = Mutex<(@Sendable () async -> Void)?>(nil)

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            let fail = state.withLock { s -> Bool in
                s.contentCalls += 1
                guard let left = s.contentFailures[asset.id], left > 0 else { return false }
                s.contentFailures[asset.id] = left - 1
                return true
            }
            if fail { throw AnalysisError.unreadable }
            return ContentAnalysis(labels: [LabelScore("document", 0.9)], source: .localPreview)
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            if let hook = onText.withLock({ $0 }) { await hook() }
            return state.withLock { s in
                s.textCalls.append((asset.id, allowNetwork))
                if s.cloudOnly.contains(asset.id) && !allowNetwork {
                    return TextAnalysis(text: s.preview[asset.id] ?? "", source: .localPreview)
                }
                return TextAnalysis(text: s.original[asset.id] ?? "", source: .original)
            }
        }
    }

    final class Clock: @unchecked Sendable {
        let value = Mutex(Fixture.date("2026-07-01 12:00"))
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    func pipeline(
        store: SortlyStore, reader: InMemoryLibraryReader, analyzer: ScriptedAnalyzer, conditions: FakeConditions = FakeConditions(),
        clock: Clock = Clock(), batchSize: Int = 10, network: Bool = false, cellular: Bool = false
    ) -> AnalysisPipeline {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.privacy.allowNetworkForAnalysis = network
        settings.privacy.allowCellularDownloads = cellular
        return AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: conditions, settings: settings, calendar: Fixture.calendar, time: ManualTime().source,
            batchSize: batchSize, now: { clock.value.withLock { $0 } }
        )
    }

    func screenshots(_ count: Int) -> (assets: [AssetSnapshot], ids: [AssetID]) {
        var lib = LibraryBuilder()
        var ids: [AssetID] = []
        for day in 1...count {
            ids.append(lib.photo(at: Fixture.date(String(format: "2026-06-%02d 20:00", day)), nil, subtypes: .screenshot))
        }
        return (lib.assets, ids)
    }

    // MARK: 2.1 trip identity

    @Test func deletedTripStaysSuppressedAfterEarlierPhotoImport() async throws {
        let s = try PipelineTests().setup()
        _ = try await s.pipeline.run()
        let first = try #require(try await s.pipeline.latestProposals())
        let trip = try #require(first.proposals.first { $0.kind == .trip && $0.title.hasPrefix("Rom ·") })
        try await s.store.addOverride(UserOverride(scope: .source(trip.id), decision: .rejectProposal))

        // An older photo of the trip arrives (shared by a friend), and the first one is deleted.
        var assets = try await s.reader.fetchAssets(includeHidden: false, knownDetails: [:])
        let romeFirst = try #require(assets.first { $0.id == s.ids.rome[0] })
        var earlier = romeFirst
        earlier.id = "imported-earlier"
        earlier.creationDate = romeFirst.creationDate!.addingTimeInterval(-3 * 3600)
        assets.append(earlier)
        assets.removeAll { $0.id == s.ids.rome[1] }
        await s.reader.set(assets: assets)
        _ = try await s.pipeline.run(mode: .refinement)

        let trips = try #require(try await s.store.value([Trip].self, forKey: "analysis.trips"))
        let rome = try #require(trips.first { $0.geotaggedAssetIDs.contains("imported-earlier") })
        #expect(rome.id == trip.id)
        let next = try #require(try await s.pipeline.latestProposals())
        #expect(!next.proposals.contains { $0.kind == .trip && $0.title.hasPrefix("Rom ·") })
    }

    // MARK: 2.2 / 2.3 / 2.5 store invalidation

    @Test func changedOrRemovedGPSInvalidatesStoredPlace() async throws {
        let store = try SortlyStore(url: nil)
        let rome = GeoCoordinate(latitude: 41.9, longitude: 12.5)
        var a = AssetSnapshot(id: "a", creationDate: Fixture.date("2026-05-01 10:00"), location: rome, pixelWidth: 10, pixelHeight: 10)
        var b = AssetSnapshot(id: "b", creationDate: Fixture.date("2026-05-01 11:00"), location: rome, pixelWidth: 10, pixelHeight: 10)
        var c = AssetSnapshot(id: "c", creationDate: Fixture.date("2026-05-01 12:00"), location: rome, pixelWidth: 10, pixelHeight: 10)
        _ = try await store.upsertAssets([a, b, c])
        let place = ResolvedPlace(components: PlaceComponents(country: "Italien"), source: .gpsReverseGeocoded, resolvedAt: Date(), precisionMeters: 1000)
        try await store.setPlaces(["a": place, "b": place, "c": place])

        a.location = GeoCoordinate(latitude: 48.1, longitude: 11.6) // moved
        b.location = nil                                            // removed
        c.isFavorite = true; c.modificationDate = Date()            // unrelated change
        #expect(try await store.upsertAssets([a, b, c]) == ["a", "b", "c"])
        let places = try await store.places()
        #expect(places["a"] == nil)
        #expect(places["b"] == nil)
        #expect(places["c"] != nil)
    }

    @Test func incrementalScanKeepsRawMetadata() async throws {
        let raw = AssetSnapshot(id: "raw", subtypes: [.raw], creationDate: Fixture.date("2026-05-01 10:00"),
                                pixelWidth: 10, pixelHeight: 10, originalFilename: "IMG_1.DNG", uniformTypeIdentifier: "com.adobe.raw-image")
        let reader = InMemoryLibraryReader(assets: [raw])
        let store = try SortlyStore(url: nil)
        for _ in 0..<2 {
            let scanned = try await reader.fetchAssets(includeHidden: false, knownDetails: try await store.assetsWithFileDetails())
            _ = try await store.upsertAssets(scanned)
        }
        let second = try await reader.fetchAssets(includeHidden: false, knownDetails: try await store.assetsWithFileDetails())
        #expect(second[0].uniformTypeIdentifier == nil) // details were not read again …
        #expect(try await store.upsertAssets(second).isEmpty) // … and nothing counts as changed
        let stored = try #require(try await store.asset("raw"))
        #expect(stored.subtypes.contains(.raw))
        #expect(stored.uniformTypeIdentifier == "com.adobe.raw-image")
        #expect(stored.originalFilename == "IMG_1.DNG")
    }

    @Test func resourceScanCursorSurvivesStoreRebuild() async throws {
        let raw = AssetSnapshot(id: "raw", subtypes: [.raw], creationDate: Fixture.date("2026-05-01 10:00"),
                                pixelWidth: 10, pixelHeight: 10, uniformTypeIdentifier: "com.adobe.raw-image")
        let reader = InMemoryLibraryReader(assets: [raw])
        let old = try SortlyStore(url: nil)
        _ = try await old.upsertAssets(try await reader.fetchAssets(includeHidden: false, knownDetails: try await old.assetsWithFileDetails()))
        // A rebuilt (empty) database asks for all details again.
        let rebuilt = try SortlyStore(url: nil)
        _ = try await rebuilt.upsertAssets(try await reader.fetchAssets(includeHidden: false, knownDetails: try await rebuilt.assetsWithFileDetails()))
        #expect(try await rebuilt.asset("raw")?.subtypes.contains(.raw) == true)
    }

    @Test func modifiedScreenshotInvalidatesOCRAndSearchIndex() async throws {
        let (assets, ids) = screenshots(2)
        let analyzer = ScriptedAnalyzer()
        analyzer.state.withLock { $0.original = [ids[0]: "Rechnung Nummer 4711", ids[1]: "Bestellung Nummer 0815"] }
        let reader = InMemoryLibraryReader(assets: assets)
        let store = try SortlyStore(url: nil)
        let p = pipeline(store: store, reader: reader, analyzer: analyzer)
        _ = try await p.run()
        #expect(try await store.searchText("Rechnung") == [ids[0]])

        // The first screenshot is cropped: the old text must not stay findable.
        var edited = assets
        edited[0].modificationDate = Fixture.date("2026-06-10 09:00")
        edited[0].pixelWidth = 800
        await reader.set(assets: edited)
        analyzer.state.withLock { $0.original[ids[0]] = "" }
        _ = try await p.run()
        #expect(try await store.searchText("Rechnung").isEmpty)
        #expect(try await store.recognizedText(for: ids[0]) == nil)
        #expect(try await store.searchText("Bestellung") == [ids[1]])
        #expect(analyzer.state.withLock { $0.textCalls.filter { $0.0 == ids[0] }.count } == 2)
    }

    // MARK: 2.4 preview text is read again

    @Test func ocrPreviewIsRefinedWhenOriginalBecomesAvailable() async throws {
        let (assets, ids) = screenshots(1)
        let analyzer = ScriptedAnalyzer()
        analyzer.state.withLock {
            $0.cloudOnly = [ids[0]]
            $0.preview = [ids[0]: "Rechnvng"]
            $0.original = [ids[0]: "Rechnung Betrag 42 Euro"]
        }
        let reader = InMemoryLibraryReader(assets: assets)
        let store = try SortlyStore(url: nil)
        let clock = Clock()
        _ = try await pipeline(store: store, reader: reader, analyzer: analyzer, clock: clock, network: false).run()
        #expect(try await store.searchText("Rechnvng") == [ids[0]])

        // Without the network nothing changes; with it, but too soon, neither.
        _ = try await pipeline(store: store, reader: reader, analyzer: analyzer, clock: clock, network: false).run(mode: .refinement)
        clock.advance(600)
        _ = try await pipeline(store: store, reader: reader, analyzer: analyzer, clock: clock, network: true).run(mode: .refinement)
        #expect(analyzer.state.withLock { $0.textCalls.count } == 1)

        clock.advance(3600)
        _ = try await pipeline(store: store, reader: reader, analyzer: analyzer, clock: clock, network: true).run(mode: .refinement)
        #expect(analyzer.state.withLock { $0.textCalls.count } == 2)
        #expect(try await store.searchText("Rechnvng").isEmpty)
        #expect(try await store.searchText("Betrag") == [ids[0]])
        let result = try #require(try await store.result(TextResult.self, kind: "text", asset: ids[0]))
        #expect(result.text?.source == .original)
        #expect(result.retries == nil)

        // Final now: no further reads.
        clock.advance(7200)
        _ = try await pipeline(store: store, reader: reader, analyzer: analyzer, clock: clock, network: true).run(mode: .refinement)
        #expect(analyzer.state.withLock { $0.textCalls.count } == 2)
    }

    // MARK: 5.1 temporary read failures

    @Test func temporaryPreviewFailureIsRetriedWithoutMetadataChange() async throws {
        let (assets, ids) = screenshots(3)
        let analyzer = ScriptedAnalyzer()
        analyzer.state.withLock { $0.contentFailures = [ids[1]: 1] }
        let reader = InMemoryLibraryReader(assets: assets)
        let store = try SortlyStore(url: nil)
        let p = pipeline(store: store, reader: reader, analyzer: analyzer)
        let first = try await p.run()
        #expect(first.contentAnalyzed == 2)
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 1)
        #expect(try await store.result(ContentAnalysis.self, kind: "content", asset: ids[1])?.failedAttempts == 1)

        let second = try await p.run()
        #expect(second.contentAnalyzed == 1)
        let result = try #require(try await store.result(ContentAnalysis.self, kind: "content", asset: ids[1]))
        #expect(result.failedAttempts == nil)
        #expect(result.labels.contains { $0.identifier == "document" })
    }

    @Test func unreadablePhotoIsGivenUpAfterThreeRuns() async throws {
        let (assets, ids) = screenshots(2)
        let analyzer = ScriptedAnalyzer()
        analyzer.state.withLock { $0.contentFailures = [ids[0]: 10] }
        let reader = InMemoryLibraryReader(assets: assets)
        let store = try SortlyStore(url: nil)
        let p = pipeline(store: store, reader: reader, analyzer: analyzer)
        for _ in 0..<3 { _ = try await p.run() }
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        #expect(try await store.result(ContentAnalysis.self, kind: "content", asset: ids[0])?.failedAttempts == 3)
        let reads = analyzer.state.withLock { $0.contentCalls }
        _ = try await p.run()
        #expect(analyzer.state.withLock { $0.contentCalls } == reads)
    }

    // MARK: 5.4 network rule per photo

    @Test func ocrRechecksWiFiBeforeEveryOriginalRequest() async throws {
        let (assets, ids) = screenshots(2)
        let analyzer = ScriptedAnalyzer()
        analyzer.state.withLock {
            $0.cloudOnly = Set(ids)
            $0.original = [ids[0]: "Rechnung", ids[1]: "Bestellung"]
        }
        let conditions = FakeConditions(wifi: true)
        // The phone leaves Wi-Fi while the first screenshot is read.
        analyzer.onText.withLock { $0 = { conditions.state.withLock { $0.wifi = false } } }
        let reader = InMemoryLibraryReader(assets: assets)
        let store = try SortlyStore(url: nil)
        _ = try await pipeline(store: store, reader: reader, analyzer: analyzer, conditions: conditions, network: true).run()
        let calls = analyzer.state.withLock { $0.textCalls }
        #expect(calls.count == 2)
        #expect(calls.filter { $0.1 }.count == 1)
        #expect(calls.last?.1 == false)
    }

    // MARK: 5.6 stop within one photo

    @Test func contentStopsWithinOneAssetWhenThermalStateChanges() async throws {
        let (assets, _) = screenshots(30)
        var firstAnalyzed: Int?
        for limit in 1...20 where firstAnalyzed == nil {
            let analyzer = ScriptedAnalyzer()
            let reader = InMemoryLibraryReader(assets: assets)
            let store = try SortlyStore(url: nil)
            let report = try await pipeline(store: store, reader: reader, analyzer: analyzer,
                                            conditions: FakeConditions(pauseAfterChecks: limit), batchSize: 25).run()
            #expect(report.pausedBecause == .thermal)
            #expect(analyzer.state.withLock { $0.contentCalls } == report.contentAnalyzed)
            if report.contentAnalyzed > 0 { firstAnalyzed = report.contentAnalyzed }
        }
        // One more allowed check lets exactly one more photo through, not a batch of 25.
        #expect(firstAnalyzed == 1)
    }

    // MARK: 4.2 albums changed during the run

    /// PhotoKit as seen by the run: the read that makes the final suggestions returns the
    /// albums from just before a plan was committed; the app then saves the new albums and
    /// calls `rematch()` while the run is still busy. Later reads see the new albums.
    actor PlanCommittedDuringRead: PhotoLibraryReading {
        let assets: [AssetSnapshot]
        let after: CollectionInventory
        let isFinalRead: @Sendable () -> Bool
        var plan: (@Sendable () async -> Void)?
        var applied = false
        init(assets: [AssetSnapshot], after: CollectionInventory, isFinalRead: @escaping @Sendable () -> Bool) {
            self.assets = assets
            self.after = after
            self.isFinalRead = isFinalRead
        }
        func set(plan: @escaping @Sendable () async -> Void) { self.plan = plan }
        func access() async -> LibraryAccess { .full }
        func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] { assets }
        func currentInventory() async throws -> CollectionInventory {
            if applied { return after }
            if let plan, isFinalRead() {
                applied = true
                self.plan = nil
                await plan()
            }
            return CollectionInventory() // read before the commit
        }
    }

    @Test func analysisFinishesWithFreshInventoryAfterEarlyPlanApplied() async throws {
        let s = try PipelineTests().setup()
        let assets = try await s.reader.fetchAssets(includeHidden: false, knownDetails: [:])
        let album = CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(s.ids.rome))
        let analyzer = s.analyzer
        // The read for the final suggestions comes after the text stage.
        let reader = PlanCommittedDuringRead(assets: assets, after: CollectionInventory([album]),
                                             isFinalRead: { analyzer.counts.withLock { $0.text } > 0 })
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: s.store, reader: reader, analyzer: s.analyzer, geocoder: s.geocoder, map: Self.map,
            conditions: s.conditions, settings: settings, calendar: Fixture.calendar, time: ManualTime().source
        )
        let store = s.store
        await reader.set(plan: {
            try? await store.saveInventory(CollectionInventory([album]))
            _ = try? await pipeline.rematch()
        })
        _ = try await pipeline.run()
        #expect(await reader.applied)
        let snapshot = try #require(try await pipeline.latestProposals())
        let trip = try #require(snapshot.proposals.first { $0.title.hasPrefix("Rom ·") })
        #expect(snapshot.matches[trip.id]?.best?.albumID == "rom")
        #expect(try await store.loadInventory()["rom"] != nil)
    }
}
