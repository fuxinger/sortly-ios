import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

func ids(_ prefix: String, _ range: Range<Int>) -> Set<AssetID> {
    Set(range.map { AssetID("\(prefix)-\($0)") })
}

@Suite("Existing album matching")
struct MatchingTests {
    let matcher = AlbumMatcher()

    func tripProposal(_ id: String, _ assets: Set<AssetID>, title: String) -> AlbumProposal {
        AlbumProposal(id: SortlyID(id), kind: .trip, title: title, assetIDs: assets)
    }

    @Test("Scenario A: differently named album is recognized and extendable")
    func scenarioA() throws {
        let garda = ids("garda", 0..<286)
        let album = CollectionSnapshot(id: "sommer", title: "Sommerurlaub", assetIDs: ids("garda", 0..<248))
        let proposal = tripProposal("p-garda", garda, title: "Gardasee · 03.08.–14.08.2026")
        let result = try #require(matcher.match([proposal], against: CollectionInventory([album]))[proposal.id])
        #expect(result.status == .extendable)
        #expect(result.best?.albumID == "sommer")
        #expect(result.best?.metrics.missing == 38)
        #expect(result.reasons.contains(.albumContains(album: "Sommerurlaub", contained: 248, total: 286)))
        #expect(result.reasons.contains(.missingItems(count: 38)))
    }

    @Test("Scenario C: a country collection is not a substitute for single trips")
    func scenarioC() throws {
        let t1 = ids("rome24", 0..<50), t2 = ids("rome25", 0..<40), t3 = ids("florence", 0..<30)
        let italy = CollectionSnapshot(id: "italien", title: "Italien", assetIDs: t1.union(t2).union(t3))
        let trips = [tripProposal("t1", t1, title: "Rom · 2024"), tripProposal("t2", t2, title: "Rom · 2025"), tripProposal("t3", t3, title: "Florenz")]
        let country = AlbumProposal(id: SortlyID("country-it"), kind: .placeCollection(.country), title: "Italien", folderPath: ["Länder"], assetIDs: t1.union(t2).union(t3))
        let results = matcher.match(trips + [country], against: CollectionInventory([italy]))
        for t in trips {
            #expect(results[t.id]?.status == .newAlbumRequired)
            #expect(results[t.id]?.reasons.contains { if case .albumIsBroaderCollection = $0 { true } else { false } } == true)
        }
        #expect(results[country.id]?.status == .alreadyComplete)
    }

    @Test("Scenario D: overlapping albums are found as merge candidates with true union")
    func scenarioD() {
        let a = CollectionSnapshot(id: "a", title: "Italien Urlaub", assetIDs: ids("x", 0..<182))
        let b = CollectionSnapshot(id: "b", title: "Gardasee", assetIDs: ids("x", 100..<374))
        let c = CollectionSnapshot(id: "c", title: "Sommer 2026", assetIDs: ids("x", 50..<366))
        let unrelated = CollectionSnapshot(id: "d", title: "Hund", assetIDs: ids("dog", 0..<40))
        let suggestions = AlbumOverlapAnalyzer().suggestions(in: CollectionInventory([a, b, c, unrelated]))
        #expect(suggestions.count == 1)
        #expect(suggestions[0].albumIDs == ["a", "b", "c"])
        #expect(suggestions[0].distinctAssetCount == 374)
        #expect(suggestions[0].totalMemberships == 182 + 274 + 316)
    }

    @Test func identicalContentDifferentNameIsComplete() throws {
        let set = ids("t", 0..<100)
        let p = tripProposal("p", set, title: "Rom · 12.05.–19.05.2024")
        let r = try #require(matcher.match([p], against: CollectionInventory([CollectionSnapshot(id: "x", title: "Bella Italia", assetIDs: set)]))[p.id])
        #expect(r.status == .alreadyComplete)
    }

    @Test func sameNameDifferentContentIsNameConflict() throws {
        let p = tripProposal("p", ids("t", 0..<100), title: "Rom")
        let r = try #require(matcher.match([p], against: CollectionInventory([CollectionSnapshot(id: "x", title: "Rom", assetIDs: ids("other", 0..<80))]))[p.id])
        #expect(r.status == .nameConflict)
        #expect(r.sameNameAlbums == ["x"])
    }

    @Test func noAlbumMeansNewAlbum() throws {
        let p = tripProposal("p", ids("t", 0..<10), title: "Rom")
        #expect(matcher.match([p], against: CollectionInventory())[p.id]?.status == .newAlbumRequired)
    }

    @Test func twoEquallyGoodAlbumsAreMultipleMatches() throws {
        let p = tripProposal("p", ids("t", 0..<100), title: "Rom")
        let inv = CollectionInventory([
            CollectionSnapshot(id: "a", title: "Rom 1", assetIDs: ids("t", 0..<60)),
            CollectionSnapshot(id: "b", title: "Rom 2", assetIDs: ids("t", 40..<100)),
        ])
        #expect(matcher.match([p], against: inv)[p.id]?.status == .multipleMatches)
    }

    @Test func smartAlbumIsNotEditable() throws {
        let p = AlbumProposal(id: SortlyID("s"), kind: .mediaType("screenshots"), title: "Screenshots", assetIDs: ids("s", 0..<20))
        let smart = CollectionSnapshot(id: "smart", title: "Bildschirmfotos", kind: .smartAlbum, capabilities: [], assetIDs: ids("s", 0..<20))
        #expect(matcher.match([p], against: CollectionInventory([smart]))[p.id]?.status == .notEditable)
    }

    @Test func impureAlbumIsOnlyPossibleMatch() throws {
        let p = tripProposal("p", ids("t", 0..<100), title: "Rom")
        let album = CollectionSnapshot(id: "a", title: "Sommer", assetIDs: ids("t", 0..<60).union(ids("home", 0..<40)))
        #expect(matcher.match([p], against: CollectionInventory([album]))[p.id]?.status == .possibleMatch)
    }

    @Test func weakOverlapIsAmbiguous() throws {
        let p = tripProposal("p", ids("t", 0..<100), title: "Rom")
        let album = CollectionSnapshot(id: "a", title: "Alles", assetIDs: ids("t", 0..<10).union(ids("home", 0..<200)))
        #expect(matcher.match([p], against: CollectionInventory([album]))[p.id]?.status == .ambiguous)
    }

    @Test func overlapMetricsFormulas() {
        let m = OverlapMetrics(proposalCount: 286, albumCount: 260, intersection: 248)
        #expect(abs(m.coverage - 248.0 / 286) < 1e-9)
        #expect(abs(m.purity - 248.0 / 260) < 1e-9)
        #expect(abs(m.jaccard - 248.0 / 298) < 1e-9)
        #expect(m.missing == 38 && m.extra == 12)
    }
}

@Suite("Managed albums and overrides")
struct ManagedAlbumTests {
    @Test("Scenario E: manual removal becomes a never-add override")
    func scenarioE() {
        let state = ManagedAlbumState(albumID: "a", sourceID: SortlyID("p"), lastKnownTitle: "Rom", lastKnownParentID: nil,
                                      lastKnownMembers: ["1", "2", "3"], addedBySortly: ["1", "2", "3"], createdBySortly: true)
        let inv = CollectionInventory([CollectionSnapshot(id: "a", title: "Rom", assetIDs: ["1", "3"])])
        let r = ManagedAlbumTracker().reconcile([state], with: inv)
        #expect(r.changes == [.assetsRemovedByUser(albumID: "a", assets: ["2"])])
        let overrides = OverrideSet(r.newOverrides)
        #expect(!overrides.mayAdd("2", toAlbum: "a"))
        #expect(overrides.mayAdd("1", toAlbum: "a"))
        #expect(r.updatedStates[0].addedBySortly == ["1", "3"])
    }

    @Test("Scenario F: renamed album keeps its identity")
    func scenarioF() {
        let state = ManagedAlbumState(albumID: "a", sourceID: SortlyID("p"), lastKnownTitle: "Rom · 2024", lastKnownParentID: nil,
                                      lastKnownMembers: ["1"], addedBySortly: ["1"], createdBySortly: true)
        let inv = CollectionInventory([CollectionSnapshot(id: "a", title: "Rom mit Anna", assetIDs: ["1"])])
        let r = ManagedAlbumTracker().reconcile([state], with: inv)
        #expect(r.changes == [.renamed(albumID: "a", from: "Rom · 2024", to: "Rom mit Anna")])
        #expect(r.updatedStates[0].albumID == "a")
        #expect(r.newOverrides.isEmpty)
    }

    @Test func deletedAlbumIsNeverRecreated() {
        let source = SortlyID("p")
        let state = ManagedAlbumState(albumID: "a", sourceID: source, lastKnownTitle: "Rom", lastKnownParentID: nil,
                                      lastKnownMembers: ["1"], addedBySortly: ["1"], createdBySortly: true)
        let r = ManagedAlbumTracker().reconcile([state], with: CollectionInventory())
        #expect(OverrideSet(r.newOverrides).mustNotRecreate(source))
    }
}
