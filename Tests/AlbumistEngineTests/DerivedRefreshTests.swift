import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Review P4-02: `AppModel.refreshDerived` read the whole library at every call, the image
/// results of every photo twice (once for the facts, once for the ring) and the album list twice,
/// and the start of the app waited for it, with each whole-library pass (preview ranks, albums
/// that overlap, the ring) run one after the other. It is one call into the engine now
/// (`AnalysisPipeline.derivedLibrary`): every input is read once, and the passes run side by side.
@Suite("Refresh of the overview: each read once, passes side by side")
struct DerivedRefreshTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Library {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var settings: OrganizationSettings
        var rome: [AssetID]

        /// A pipeline on the same database, as the app makes one at each launch.
        func launch() -> AnalysisPipeline {
            AnalysisPipeline(store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: DerivedRefreshTests.map,
                             conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source)
        }
    }

    /// An analysed library with "Themen" on: Munich every day and a week in Rome, three albums of
    /// Rome that overlap (Albumist's own "Rom" left out, the other two a merge suggestion), a
    /// photo ignored, one taken out of a suggestion, two not readable yet, three still without
    /// their image labels (one of them tried before).
    func analysed() async throws -> Library {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2025-11-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let inventory = CollectionInventory([
            CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(rome)),
            CollectionSnapshot(id: "rom-2026", title: "Rom 2026", assetIDs: Set(rome.dropLast(2))),
            CollectionSnapshot(id: "rom-ausflug", title: "Ausflug Rom", assetIDs: Set(rome.dropFirst(2))),
        ])
        let store = try AlbumistStore(url: nil)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.enabledAreas.insert(.imageCategories)
        let library = Library(store: store, reader: InMemoryLibraryReader(assets: lib.assets, inventory: inventory), settings: settings, rome: rome)
        _ = try await library.launch().run()
        try await store.addOverride(UserOverride(scope: .asset(rome[0]), decision: .ignoreAsset))
        if let suggestion = try await library.launch().latestProposals()?.proposals.first, let photo = suggestion.assetIDs.sorted().first {
            try await store.addOverride(UserOverride(scope: .assetInSource(photo, suggestion.id), decision: .neverAdd))
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        for id in rome[1...2] {
            var failed = try #require(contents[id])
            failed.failedAttempts = 1
            try await store.saveResult(failed, kind: "content", asset: id, version: AnalysisPipeline.contentVersion)
        }
        try await store.saveResults([] as [(AssetID, ContentAnalysis)], kind: "content", version: AnalysisPipeline.contentVersion,
                                    markingAnalyzed: Array(rome[3...5]), labelsVersion: 0)
        try await store.saveResult(LabelAttempts(failedAttempts: 1, lastAttempt: Fixture.date("2026-06-30")), kind: "labels", asset: rome[3],
                                   version: AnalysisPipeline.contentVersion)
        return library
    }

    static func managed(_ snapshot: ProposalSnapshot?) -> [ManagedAlbumState] {
        guard let first = snapshot?.proposals.first else { return [] }
        return [ManagedAlbumState(albumID: "rom", sourceID: first.id, lastKnownTitle: "Rom", lastKnownParentID: nil,
                                  lastKnownMembers: first.assetIDs, addedByAlbumist: first.assetIDs, createdByAlbumist: true)]
    }

    /// What a refresh reads, as the app's `refreshDerived` asks for it: the matches first, then
    /// everything made from the whole library.
    func refresh(_ pipeline: AnalysisPipeline, _ library: Library, scope: OrganizationScope = .all,
                 probe: DerivedLibrary.Probe? = nil) async throws -> (DerivedLibrary, [String: Int]) {
        let before = await library.store.wholeLibraryReads
        let snapshot = try await pipeline.refreshMatchesIfOutdated().snapshot
        let derived = try await pipeline.derivedLibrary(snapshot: snapshot, settings: library.settings, managed: Self.managed(snapshot),
                                                        scope: scope, ownAlbums: ["rom"], probe: probe)
        let after = await library.store.wholeLibraryReads
        return (derived, after.reduce(into: [:]) { reads, entry in
            let count = entry.value - (before[entry.key] ?? 0)
            if count > 0 { reads[entry.key] = count }
        })
    }

    /// The reads that go over every photo: each once, at the first refresh after a launch (the
    /// zones of the places are not known yet) and at every later one.
    @Test func eachWholeLibraryReadRunsOncePerRefresh() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let once = ["allAssets": 1, "loadInventory": 1, "places": 1, "results.content": 1, "results.text": 1, "overrides": 1]
        let (_, atLaunch) = try await refresh(pipeline, library)
        #expect(atLaunch == once, "the first refresh after a launch reads \(atLaunch)")
        let (_, later) = try await refresh(pipeline, library)
        #expect(later == once, "a later refresh reads \(later)")
    }

    /// The ring (and so the first screen) does not wait for the albums that overlap: held, the
    /// other passes still end. Before, ranks, overlaps and the ring ran one after the other.
    @Test func theRingDoesNotWaitForTheOverlappingAlbums() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let ended = Locked<Set<DerivedLibrary.Piece>>([])
        let held = Locked(true)
        let probe: DerivedLibrary.Probe = { piece, end in
            if end { _ = ended.withLock { $0.insert(piece) } }
            if piece == .merges, !end {
                while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        async let result = refresh(pipeline, library, probe: probe)
        let deadline = ContinuousClock.now + .seconds(20)
        while !ended.withLock({ $0.contains(.status) && $0.contains(.previewRanks) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let whileHeld = ended.withLock { $0 }
        held.withLock { $0 = false }
        _ = try await result
        #expect(whileHeld.contains(.status), "the ring waited for the albums that overlap")
        #expect(whileHeld.contains(.previewRanks), "the preview ranks waited for the albums that overlap")
        #expect(!whileHeld.contains(.merges))
    }

    /// The same results as the code it replaces (`AppModel.refreshDerived` before: the facts, then
    /// each input read on its own and each pass on its own).
    @Test(arguments: [OrganizationScope.all, .year(2026)])
    func sameResultsAsBefore(scope: OrganizationScope) async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let (derived, _) = try await refresh(pipeline, library, scope: scope)

        let store = library.store
        let snapshot = try await pipeline.latestProposals()
        // From a pipeline of its own: the zones of the places the refresh worked out are not
        // reused (second review: a fault in handing them over cancelled out).
        let facts = try await library.launch().currentFacts()
        let inventory = try await store.loadInventory()
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let stored = try await store.overrides()
        var removed: [AlbumistID: Set<AssetID>] = [:]
        for o in stored where o.decision == .neverAdd {
            if case .assetInSource(let asset, let source) = o.scope { removed[source, default: []].insert(asset) }
        }
        let labels = try await AnalysisPipeline.photosWaitingForLabels(in: store, settings: library.settings)
        let status = DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: library.settings, overrides: OverrideSet(stored),
                                                 contents: contents, labelsMissing: labels.missing, labelsRetrying: labels.retrying,
                                                 managed: Self.managed(snapshot), inventory: inventory, scope: scope)

        #expect(!facts.isEmpty && !(snapshot?.proposals.isEmpty ?? true))
        #expect(derived.facts == facts)
        #expect(derived.previewRanks == PreviewRank.ranks(of: facts))
        #expect(derived.inventory == inventory)
        let merges = AlbumOverlapAnalyzer().suggestions(in: inventory, excluding: ["rom"])
        #expect(merges.map(\.albumIDs) == [["rom-2026", "rom-ausflug"]])
        #expect(derived.merges == merges)
        #expect(!removed.isEmpty)
        #expect(derived.removed == removed)
        #expect(derived.status.states == status.states)
        #expect(derived.status.reasons == status.reasons)
        #expect(derived.status.progress == status.progress)
        #expect(derived.status.leftOut == status.leftOut)
        #expect(derived.status.photos == status.photos)
        #expect(derived.status.analyzed == status.analyzed)
        #expect(derived.status.unreadable == status.unreadable)
        #expect(status.unreadable == 2)
        #expect(derived.status.labelsMissing == status.labelsMissing)
        #expect(derived.status.labelsUntried == status.labelsUntried)
        #expect(status.labelsMissing == 3 && status.labelsUntried == 2)
        #expect(derived.status.ignored == status.ignored)
        #expect(!status.ignored.isEmpty)
        #expect(derived.status.ifNotIgnored == status.ifNotIgnored)
        // P4-09: what the first draw made on the main thread, made here with the same functions
        // (the app's former inline code for the capture dates).
        let dates = Dictionary(facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } }, uniquingKeysWith: { first, _ in first })
        #expect(!dates.isEmpty && derived.creationDates == dates)
        #expect(derived.atlas == TravelAtlas.compute(facts: facts, year: nil))
        #expect(derived.atlas.countryCodes.contains("IT"))
        #expect(derived.atlasYears == TravelAtlas.years(facts: facts))
        // P4-09, the rest: the facts by id (a dictionary made on the main thread at the first
        // lookup).
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(derived.factsByID.count == byID.count)
        #expect(byID.allSatisfy { derived.factsByID[$0.key] == $0.value })
        #expect(derived.factsByID[AssetID("no-such-photo")] == nil)
    }

    /// The facts by id say what the dictionary they replace said: the first photo of an id wins,
    /// an unknown id has none.
    @Test func factsByIDKeepsTheFirstPhotoOfAnID() {
        func photo(_ id: String, trip: String) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: Fixture.date("2024-05-01")), tripID: AlbumistID(trip))
        }
        let facts = [photo("p1", trip: "t1"), photo("p2", trip: "t2"), photo("p1", trip: "t3")]
        let byID = FactsByID(facts)
        #expect(byID.count == 2)
        #expect(byID[AssetID("p1")]?.tripID == AlbumistID("t1"), "the first photo with an id no longer wins")
        #expect(byID[AssetID("p2")]?.tripID == AlbumistID("t2"))
        #expect(byID[AssetID("p9")] == nil)
        #expect(FactsByID()[AssetID("p1")] == nil)
    }

    /// The whole package a refresh shows (`AnalysisPipeline.derivedRefresh`): what the app read
    /// one value after the other, and the detected home named from the facts.
    @Test func theRefreshPackageHasWhatTheAppReadItself() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let reopened = Locked<[Set<AlbumistID>]>([])
        let undone = Locked<[Set<AlbumistID>]>([])
        let once = DerivedRefresh.Once(reopened: { ids in reopened.withLock { $0.append(ids) } },
                                       undone: { ids in undone.withLock { $0.append(ids) } })
        let refreshed = try await pipeline.derivedRefresh(settings: library.settings, managed: [], scope: .all, historyLimit: 50, once: once)
        #expect(reopened.withLock { $0.count } == 1 && undone.withLock { $0.count } == 1, "a call skipped what it applies once")
        let store = library.store
        let snapshot = try await pipeline.latestProposals()
        let rechecked = try await store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) ?? 0
        let report = try await pipeline.recurringPlaceReport()
        let notice = try await pipeline.homeChangeNotice()
        let plans = try await store.planHistory(limit: 51)
        let undoneTargets = try await store.undoneTargets()
        let detected = try await pipeline.detectedHome()
        let facts = try await library.launch().currentFacts()
        #expect(refreshed.snapshot == snapshot)
        #expect(refreshed.rechecked == rechecked)
        #expect(refreshed.recurringReport == report)
        #expect(refreshed.homeNotice == notice)
        #expect(refreshed.historyHasMore == (plans.count > 50))
        #expect(refreshed.history == plans.prefix(50).filter { $0.reverts == nil })
        #expect(refreshed.undone == undoneTargets)
        let home = try #require(detected, "the library has no detected home")
        #expect(refreshed.detectedHome == home)
        #expect(refreshed.library.facts == facts)
    }

    /// Second review of P4-09, SHOULD-1: the atlas of each year (240 ms at 50,000 photos, 671 ms
    /// at 100,000) and the name of the detected home (299 / 590 ms) went over all photos at every
    /// refresh, although only the atlas's year picker and "Dein Zuhause" or the settings need
    /// them: battery for nothing at every early look of an analysis. A refresh makes neither: no
    /// pass of its own for the name, the first draw makes only what the first screens show, and
    /// the package carries nothing of either.
    @Test func aRefreshMakesNeitherTheAtlasOfEachYearNorTheHomeName() async throws {
        let library = try await analysed()
        let started = Locked<Set<String>>([])
        let probe: DerivedLibrary.Probe = { piece, ended in
            if !ended { _ = started.withLock { $0.insert(piece.rawValue) } }
        }
        let refreshed = try await library.launch().derivedRefresh(settings: library.settings, managed: [], scope: .all, historyLimit: 50,
                                                                  once: .nothing, probe: probe)
        #expect(refreshed.detectedHome != nil, "the library has no detected home to name")
        let passes = started.withLock { $0 }
        #expect(passes == ["status", "previewRanks", "firstDraw", "factsByID", "merges"], "a refresh runs the passes \(passes.sorted())")
        // What the package holds, by name: a field for either means the refresh made it.
        let fields = Set(Mirror(reflecting: refreshed).children.compactMap(\.label))
            .union(Mirror(reflecting: refreshed.library).children.compactMap(\.label))
        let made = fields.intersection(["yearAtlases", "homeName", "detectedHomePlace"])
        #expect(made.isEmpty, "a refresh makes \(made.sorted())")
    }

    /// Delta review, N2: a refresh whose facts equal those on screen hands back those very facts
    /// (the same storage), so the app keeps the facts and all it made from them (the atlas of a
    /// year, the name of the home: no spinner, no lost VoiceOver focus at every early look).
    /// Follow-up review, NIT1: what only the facts make (preview ranks, first draw, facts by id)
    /// is then not made at all; the app keeps its own. Facts that changed come anew, with all.
    @Test func aRefreshWithUnchangedFactsHandsBackTheFactsOnScreen() async throws {
        let library = try await analysed()
        let pipeline = library.launch()
        let settings = library.settings
        let first = try await pipeline.derivedRefresh(settings: settings, managed: [], scope: .all, historyLimit: 50, once: .nothing)
        let shown = first.library.facts
        let started = Locked<Set<String>>([])
        let probe: DerivedLibrary.Probe = { piece, ended in if !ended { _ = started.withLock { $0.insert(piece.rawValue) } } }
        let again = try await pipeline.derivedRefresh(settings: settings, managed: [], scope: .all, historyLimit: 50, once: .nothing,
                                                      shown: shown, probe: probe)
        let passes = started.withLock { $0 }
        #expect(passes.contains("sameFacts"), "the facts were not compared off the main thread")
        #expect(DerivedLibrary.sameFacts(again.library.facts, shown), "unchanged facts come as a new copy")
        #expect(passes == ["sameFacts", "status", "merges"], "unchanged facts still run \(passes.sorted())")
        #expect(again.library.status.states == first.library.status.states)
        // Without the facts on screen (the first refresh), or with others: new ones, and all passes.
        let fresh = try await pipeline.derivedRefresh(settings: settings, managed: [], scope: .all, historyLimit: 50, once: .nothing)
        #expect(fresh.library.facts == shown && !DerivedLibrary.sameFacts(fresh.library.facts, shown))
        _ = try await library.store.upsertAssets([OverlappingRefreshTests.late])
        started.withLock { $0 = [] }
        let changed = try await pipeline.derivedRefresh(settings: settings, managed: [], scope: .all, historyLimit: 50, once: .nothing,
                                                        shown: shown, probe: probe)
        #expect(!DerivedLibrary.sameFacts(changed.library.facts, shown))
        #expect(changed.library.facts.contains { $0.id == OverlappingRefreshTests.late.id })
        #expect(DerivedLibrary.sameFacts(changed.library.factsByID.facts, changed.library.facts))
        let all = started.withLock { $0 }
        #expect(all.isSuperset(of: ["status", "previewRanks", "firstDraw", "factsByID", "merges"]), "changed facts run only \(all.sorted())")
    }

    /// Delta review, N3: new facts cancel what is being made for the old ones; the making then
    /// stops and gives nothing (`nil`), so a cut-off result is never taken for a whole one.
    @Test func whatIsMadeOnDemandGivesNothingOnceCancelled() async throws {
        let library = try await analysed()
        let refreshed = try await library.launch().derivedRefresh(settings: library.settings, managed: [], scope: .all, historyLimit: 50,
                                                                  once: .nothing)
        let facts = refreshed.library.facts, allYears = refreshed.library.atlas
        let center = try #require(refreshed.detectedHome?.center)
        let started = Locked(false)
        let making = Task.detached { () -> ([Int: TravelAtlas]?, HomePlace?) in
            started.withLock { $0 = true }
            while !Task.isCancelled { await Task.yield() }
            let atlases: [Int: TravelAtlas]? = DerivedLibrary.yearAtlases(of: facts, allYears: allYears)
            let home: HomePlace? = DerivedLibrary.namedHome(at: center, facts: facts)
            return (atlases, home)
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        making.cancel()
        let (atlases, home) = await making.value
        #expect(atlases == nil, "a cancelled atlas of each year is handed out: \(atlases?.count ?? 0) years")
        #expect(home == nil, "a cancelled name of the home is handed out")
    }

    /// ...and what the screens get when they ask (`AppModel.travelAtlas(year:)` and
    /// `AppModel.detectedHomePlace`), made from what the refresh handed over (its facts, its atlas
    /// of all years, its detected home): each year's atlas as `TravelAtlas.compute(facts:year:)`
    /// makes it, a year without photos empty, and the home with its town.
    @Test func whatTheScreensAskForIsRightWhenTheyAsk() async throws {
        let library = try await analysed()
        let refreshed = try await library.launch().derivedRefresh(settings: library.settings, managed: [], scope: .all, historyLimit: 50,
                                                                  once: .nothing)
        let facts = refreshed.library.facts
        #expect(facts == (try await library.launch().currentFacts()))
        let atlases = try #require(DerivedLibrary.yearAtlases(of: facts, allYears: refreshed.library.atlas))
        let years = Set(facts.compactMap { f in f.asset.creationDate.map { Calendar.current.component(.year, from: $0) } })
        #expect(years.count >= 2)
        #expect(Set(atlases.keys) == years)
        for year in years.sorted() {
            #expect(atlases[year] == TravelAtlas.compute(facts: facts, year: year), "the atlas of \(year)")
        }
        #expect(atlases.values.contains { $0.newCountryCodes.contains("IT") })
        #expect(DerivedLibrary.emptyYearAtlas(1999) == TravelAtlas.compute(facts: facts, year: 1999))
        let home = try #require(refreshed.detectedHome, "the library has no detected home")
        let named = try #require(DerivedLibrary.namedHome(at: home.center, facts: facts))
        #expect(named == HomePlace(center: home.center, components: HomeName.components(near: home.center, facts: facts)))
        #expect(named.components?.locality != nil, "the detected home has no town: \(String(describing: named.components))")
    }
}

/// The app's side (it does not build on Linux, so its code is read, `AppSource`).
@Suite("Refresh of the overview: the app only assigns")
struct DerivedRefreshAppTests {
    static func refreshBody() throws -> String {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        return AppSource.code(try #require(AppSource.body(of: "func refreshDerived(", in: model)))
    }

    /// P4-02: the inputs made from the whole library are read by the engine, once each, not by the
    /// app next to it (the image results and the album list were read twice).
    @Test func refreshDerivedReadsNothingOfTheWholeLibraryItself() throws {
        let body = try Self.refreshBody()
        #expect(!AppSource.calls(of: "pipeline.derivedRefresh(", in: body).isEmpty, "refreshDerived does not ask the engine")
        // Review P4-10: everything else it shows comes in the same package, not read beside it.
        for read in ["store.loadInventory(", "store.results(", "store.overrides(", "pipeline.currentFacts(", "store.allAssets(",
                     "pipeline.derivedLibrary(", "store.planHistory(", "store.undoneTargets(", "store.value(",
                     "pipeline.recurringPlaceReport(", "pipeline.detectedHome(", "pipeline.homeChangeNotice(",
                     "pipeline.refreshMatchesIfOutdated("] {
            #expect(AppSource.calls(of: read, in: body).isEmpty, "refreshDerived reads \(read)) itself")
        }
    }

    /// P4-02: no pass over all photos is awaited one after the other in the app; the engine runs
    /// them side by side.
    @Test func refreshDerivedAwaitsNoPassOfItsOwn() throws {
        let body = try Self.refreshBody()
        #expect(AppSource.calls(of: "Task.detached(", in: body).isEmpty, "refreshDerived awaits passes over all photos one after the other")
    }

    /// P4-09: what the first screens make from all photos at their first draw after a refresh (the
    /// capture dates of the previews, the atlas of all years and its years) was made on the main
    /// thread there; the engine makes it off the main thread and the refresh hands it over with
    /// the facts (after them: a new value of the facts empties these caches).
    @Test func refreshDerivedHandsOverWhatTheFirstDrawMadeOnTheMainThread() throws {
        let body = try Self.refreshBody()
        let facts = try #require(body.range(of: "(?<![A-Za-z0-9_.])facts = ", options: .regularExpression), "refreshDerived assigns no facts")
        for cache in ["previewRanksCache = ", "datesCache = ", "atlasCache = ", "atlasYearsCache = ", "factsIndex = "] {
            let handed = body.range(of: cache, options: .backwards).map { $0.lowerBound > facts.lowerBound } ?? false
            #expect(handed, "refreshDerived does not hand over \(cache)…: the first draw makes it on the main thread")
        }
    }

    /// What only one screen needs from all photos, and how the app makes it: the getter the
    /// screen reads, the function that starts making it, the pass, the cache and the task.
    struct OnDemand: Sendable, CustomTestStringConvertible {
        var getter, make, pass, cache, task: String
        var testDescription: String { pass }
    }

    /// P4-09, second review: the places "Dein Zuhause" offers (322 ms at 50,000 photos); its
    /// SHOULD-1: the atlas of each year (only the atlas's year picker) and the name of the
    /// detected home (only "Dein Zuhause" and the settings).
    static let onDemand = [
        OnDemand(getter: "var homeCandidates: [HomeCandidate]?", make: "private func makeHomeCandidates(", pass: "HomeCandidates.make(",
                 cache: "homeCandidatesCache", task: "homeCandidatesTask"),
        OnDemand(getter: "func travelAtlas(year: Int) -> TravelAtlas?", make: "private func makeYearAtlases(", pass: "DerivedLibrary.yearAtlases(",
                 cache: "yearAtlasesCache", task: "yearAtlasesTask"),
        OnDemand(getter: "var detectedHomePlace: HomePlace?", make: "private func nameDetectedHome(", pass: "DerivedLibrary.namedHome(",
                 cache: "detectedHomePlaceCache", task: "detectedHomeNameTask"),
    ]

    /// The engine's side in its code (delta review, N1): neither the refresh nor the library it
    /// reads calls any of these passes, in any of their overloads (the behaviour:
    /// `DerivedRefreshTests.aRefreshMakesNeitherTheAtlasOfEachYearNorTheHomeName`).
    @Test func theRefreshCodeCallsNoneOfWhatOnlyOneScreenNeeds() throws {
        let engine = try AppSource.read("Sources/AlbumistEngine/DerivedLibrary.swift")
        let code = Array(AppSource.code(engine).unicodeScalars)
        let passes = ["HomeCandidates.make(", "HomeName.components(", "namedHome(", "yearAtlases("]
        for function in ["func derivedLibrary(", "func derivedRefresh("] {
            var bodies: [String] = []
            var from = 0
            while let range = AppSource.bodyRange(of: function, in: engine, within: from..<code.count) {
                bodies.append(String(String.UnicodeScalarView(code[range])))
                from = range.upperBound
            }
            #expect(bodies.count == 2, "\(function)…): \(bodies.count) bodies, expected the public one and the one with the probe")
            for body in bodies {
                for pass in passes {
                    #expect(AppSource.calls(of: pass, in: body).isEmpty, "\(function)…) calls \(pass)…)")
                }
            }
        }
    }

    /// Delta review, N3: new facts cancel the making of the atlas of each year and of the home's
    /// name (the work stops, `whatIsMadeOnDemandGivesNothingOnceCancelled`), and a cancelled or
    /// cut-off result is never stored.
    @Test(arguments: Self.onDemand.dropFirst())
    func newFactsCancelWhatIsMadeForTheOldOnes(_ item: OnDemand) throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let factsLine = try #require(AppSource.code(model).components(separatedBy: "\n").first { $0.contains("var facts: [AssetFacts] = []") })
        #expect(factsLine.contains("\(item.task)?.cancel(); \(item.task) = nil"), "new facts leave \(item.task) running")
        let make = AppSource.code(AppSource.body(of: item.make, in: model) ?? "")
        let forwards = make.contains("withTaskCancellationHandler") && make.contains(".cancel() }")
        #expect(forwards, "\(item.make)…) does not stop its detached work when it is cancelled")
        let guarded = make.range(of: "guard let [a-z]+, !Task.isCancelled, let self, version == self.factsVersion else \\{ return \\}",
                                 options: .regularExpression) != nil
        #expect(guarded, "\(item.make)…) can store a cancelled or cut-off result")
    }

    /// Each is made only when its screen asks, off the main thread, once for each value of the
    /// facts, and never at a refresh (battery): the getter starts it and makes nothing itself,
    /// the work runs in `Task.detached`, a result for facts that changed meanwhile is dropped
    /// (`factsVersion`), and new facts empty the cache. The engine's side: `DerivedRefreshTests.
    /// aRefreshMakesNeitherTheAtlasOfEachYearNorTheHomeName`.
    @Test(arguments: Self.onDemand)
    func whatOnlyOneScreenNeedsIsMadeOffTheMainThreadWhenItAsks(_ item: OnDemand) throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let refresh = try Self.refreshBody()
        #expect(AppSource.calls(of: item.pass, in: refresh).isEmpty, "every refresh makes \(item.pass)…)")
        #expect(!refresh.contains("\(item.cache) ="), "every refresh hands over \(item.cache)")
        let getter = AppSource.code(AppSource.body(of: item.getter, in: model) ?? "")
        #expect(!getter.isEmpty, "no \(item.getter)")
        #expect(AppSource.calls(of: item.pass, in: getter).isEmpty, "the screen makes \(item.pass)…) on the main thread")
        let name = String(item.make.dropFirst("private func ".count))
        #expect(!AppSource.calls(of: name, in: getter).isEmpty, "\(item.getter) does not start \(name)…)")
        let make = AppSource.code(AppSource.body(of: item.make, in: model) ?? "")
        let offMain = !AppSource.calls(of: "Task.detached(", in: make).isEmpty && !AppSource.calls(of: item.pass, in: make).isEmpty
        #expect(offMain, "\(item.pass)…) is not made off the main thread")
        #expect(make.contains("guard \(item.task) == nil"), "\(name)…) starts again while it runs")
        #expect(make.contains("version == self.factsVersion"), "\(name)…) keeps a result for facts that changed meanwhile")
        let factsLine = try #require(AppSource.code(model).components(separatedBy: "\n").first { $0.contains("var facts: [AssetFacts] = []") })
        #expect(factsLine.contains("\(item.cache) = nil") && factsLine.contains("\(item.task) = nil"),
                "new facts keep \(item.cache)")
    }

    /// The passes over all photos that ran on the main actor when a screen asked (review P4-09:
    /// the places of "Dein Zuhause", the facts by id at the first lookup, the atlas of a year,
    /// the statuses of a search, the start of a stay when a home is picked, the name of the
    /// detected home): wherever the app or "Dein Zuhause" still makes one of these, it is inside a
    /// `Task.detached` closure; the rest comes made with the facts (`DerivedLibrary`).
    /// Only these passes, in these two files: not every pass over all photos is off the main
    /// thread. Known and accepted (second review of P4-09, NIT-2), each made once and kept:
    /// `CountryPhotos.collect` (`AppModel.countryPhotos`, a country opened in the atlas), the
    /// capture dates made again after a memory warning (`AppModel.creationDates`), the preview
    /// ranks when they did not come with the facts (`AppModel.previewRanks`, a fallback); and,
    /// at each draw of the atlas with Apple Intelligence, `PhotoStory.availableYears` (`Atlas.swift`).
    static let passesOverAllPhotos = ["HomeCandidates.make(", "HomeCandidates.stayStart(", "HomeName.components(", "TravelAtlas.compute(",
                                      "TravelAtlas.years(", "DerivedLibrary.yearAtlases(", "DerivedLibrary.namedHome(", "LibraryStatus.searchStatuses(",
                                      "LibraryBuckets.make(", "FactsByID(", "Dictionary(", ".mapValues("]

    @Test func passesOverAllPhotosRunOffTheMainActor() throws {
        var found = 0
        for path in ["App/Albumist/Model/AppModel.swift", "App/Albumist/Views/HomeSettingsView.swift"] {
            let source = try AppSource.read(path)
            let length = AppSource.code(source).unicodeScalars.count
            let detached = AppSource.callSites(of: "Task.detached(", in: source).compactMap { site in
                AppSource.bodyRange(of: "Task.detached(", in: source, within: site.offset..<length)
            }
            for pass in Self.passesOverAllPhotos {
                for site in AppSource.callSites(of: pass, in: source) {
                    // `FactsByID()`: no facts, nothing to go over.
                    if pass == "FactsByID(", site.arguments.isEmpty { continue }
                    // A dictionary or a mapping of something other than all photos (a few albums, a value).
                    if pass == "Dictionary(" || pass == ".mapValues(" {
                        let line = source.unicodeScalars.count > site.offset ? Self.line(at: site.offset, in: source) : ""
                        guard line.contains("facts") || line.contains("states") else { continue }
                    }
                    found += 1
                    let off = detached.contains { $0.contains(site.offset) }
                    #expect(off, "\(path): \(pass)\(site.arguments)) runs on the main actor: \(Self.line(at: site.offset, in: source))")
                }
            }
        }
        // The ones still made in the app: the home places, the atlas of each year, the name of the
        // detected home, the start of a stay, the library tab's areas and the statuses of a search.
        #expect(found >= 6, "the scan found only \(found) passes")
    }

    /// Second review of P4-09, NIT-5: the facts by id are handed over apart from the facts; debug
    /// builds check where they are read that they were made from these facts: the same storage,
    /// not only as many (delta review, N4).
    @Test func debugBuildsCheckTheFactsByIDAgainstTheFacts() throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let getter = AppSource.code(AppSource.body(of: "var factsByID: FactsByID", in: model) ?? "")
        let checks = AppSource.calls(of: "assert(", in: getter).contains { $0.contains("DerivedLibrary.sameFacts($0.facts, facts)") }
        #expect(checks, "factsByID does not check that factsIndex goes with the facts")
    }

    /// Delta review, N2: the refresh hands the engine the facts on screen and, when it gets them
    /// back (`DerivedLibrary.sameFacts`), assigns neither the facts nor anything made from them
    /// (the behaviour: `DerivedRefreshTests.aRefreshWithUnchangedFactsHandsBackTheFactsOnScreen`).
    @Test func unchangedFactsAreNotAssignedAgain() throws {
        let body = try Self.refreshBody()
        #expect(body.contains("let shownFacts = keepsOnDemand ? facts : []"), "refreshDerived does not take the facts on screen")
        // Only while something made on demand is there to keep (the comparison costs battery).
        let model = AppSource.code(try AppSource.read("App/Albumist/Model/AppModel.swift"))
        let keeps = AppSource.code(AppSource.body(of: "private var keepsOnDemand: Bool", in: model) ?? "")
        for item in Self.onDemand {
            #expect(keeps.contains("\(item.cache) != nil") && keeps.contains("\(item.task) != nil"), "keepsOnDemand leaves out \(item.cache)")
        }
        let passes = AppSource.calls(of: "pipeline.derivedRefresh(", in: body).contains { $0.hasSuffix("shown: shownFacts") }
        #expect(passes, "refreshDerived does not hand the engine the facts on screen")
        let skip = try #require(body.range(of: "if DerivedLibrary.sameFacts(derived.facts, facts) {"), "refreshDerived assigns unchanged facts")
        let assign = try #require(body.range(of: "(?<![A-Za-z0-9_.])facts = derived.facts", options: .regularExpression))
        #expect(skip.lowerBound < assign.lowerBound, "the facts are assigned before it is asked whether they changed")
        // Follow-up review, NIT1: a package for facts an older call replaced meanwhile lacks what
        // only the facts make; it is not shown, one more refresh comes instead.
        let stale = try #require(body.range(of: "if refreshed.library.factsOnScreen, !DerivedLibrary.sameFacts(refreshed.library.facts, facts) {"),
                                 "refreshDerived shows a package without what the facts make")
        #expect(stale.lowerBound < skip.lowerBound && String(body[stale.upperBound...].prefix(60)).contains("refreshAgain()"))
        let branch = String(body[skip.upperBound..<assign.lowerBound])
        #expect(branch.contains("return") && !branch.contains("factsIndex") && !branch.contains("atlasCache") && !branch.contains("previewRanksCache"),
                "unchanged facts still empty or replace what is made from them: \(branch)")
    }

    /// Second review of P4-09, NIT-3: while "Seit wann wohnst du dort?" is proposed off the main
    /// thread (`AppModel.homeStayStart`), the place tapped shows a spinner and the other choices
    /// are dimmed and take no tap, as in Apple's own lists; before, the screen showed nothing
    /// and other taps were dropped without a sign.
    @Test func thePlacePickedShowsItsSpinnerWhileItsDateIsProposed() throws {
        let view = try AppSource.read("App/Albumist/Views/HomeSettingsView.swift")
        let picker = AppSource.code(try #require(AppSource.body(of: "struct HomePlacePicker", in: view)))
        let spinner = picker.range(of: "if proposing == candidate.id \\{\\s*ProgressView\\(\\)", options: .regularExpression) != nil
        #expect(spinner, "the place picked shows no spinner while its date is proposed")
        #expect(picker.contains(".disabled(busy || (proposing != nil && proposing != candidate.id))"), "the other places take taps meanwhile")
        #expect(picker.contains(".disabled(busy || proposing != nil)"), "the other choices take taps meanwhile")
        let ask = AppSource.code(AppSource.body(of: "private func askSince(", in: view) ?? "")
        #expect(ask.contains("guard proposing == nil else { return }"), "a second tap asks twice")
    }

    /// Delta review of the second review, S1: the atlas share sheet read the atlas live, so a
    /// refresh that emptied the atlas of each year switched an open sheet's card and "Teilen" to
    /// the atlas of all years for a moment. The sheet gets the atlas (and the count) captured
    /// when "Teilen" is tapped (`.sheet(item:)`), never the model's.
    @Test func theShareSheetSharesTheAtlasAsItWasWhenTapped() throws {
        let view = try AppSource.read("App/Albumist/Views/Atlas.swift")
        let screen = AppSource.code(try #require(AppSource.body(of: "struct AtlasView", in: view)))
        #expect(screen.contains(".sheet(item: $sharing)"), "the share sheet is not opened with a captured value")
        let sheet = AppSource.calls(of: "ShareCardSheet(", in: screen)
        #expect(sheet.count == 1)
        let captured = sheet.allSatisfy { $0.hasPrefix("atlas: shared.atlas, sortedPhotos: shared.sortedPhotos,") && !$0.contains("model.travelAtlas") }
        #expect(captured, "the share sheet reads the atlas live: \(sheet)")
        let tap = screen.contains("sharing = SharedAtlas(atlas: atlas, sortedPhotos: model.progress.fully)")
        #expect(tap, "Teilen does not capture the atlas shown")
    }

    /// The line of `source` at a position in Unicode scalars, trimmed.
    static func line(at offset: Int, in source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var start = min(offset, scalars.count), end = start
        while start > 0, scalars[start - 1] != "\n" { start -= 1 }
        while end < scalars.count, scalars[end] != "\n" { end += 1 }
        return String(String.UnicodeScalarView(scalars[start..<end])).trimmingCharacters(in: .whitespaces)
    }

    /// What the refresh hands over (the facts by id, the atlas of all years and its years) is
    /// there whenever facts are: the facts and the detected home are assigned in
    /// `refreshDerived` only, together with them. The getters make nothing themselves; those of
    /// what only one screen needs start making it off the main thread
    /// (`whatOnlyOneScreenNeedsIsMadeOffTheMainThreadWhenItAsks`).
    @Test func factsAndTheDetectedHomeAreAssignedOnlyWithWhatIsMadeFromThem() throws {
        let model = AppSource.code(try AppSource.read("App/Albumist/Model/AppModel.swift"))
        let refresh = try Self.refreshBody()
        for name in ["facts", "detectedHome"] {
            let pattern = try Regex("(?m)^\\s*(self\\.)?\(name)\\s*=[^=]")
            let everywhere = model.matches(of: pattern).count
            let inRefresh = refresh.matches(of: pattern).count
            #expect(everywhere == 1 && inRefresh == 1, "\(name) is assigned \(everywhere) times, \(inRefresh) of them in refreshDerived")
        }
        for getter in ["func travelAtlas() -> TravelAtlas", "func travelAtlas(year: Int) -> TravelAtlas?", "var atlasYears: [Int]",
                       "var factsByID: FactsByID", "var detectedHomePlace: HomePlace?"] {
            let body = AppSource.code(AppSource.body(of: getter, in: model) ?? "")
            #expect(!body.isEmpty, "no \(getter)")
            let makes = Self.passesOverAllPhotos.contains { !AppSource.calls(of: $0, in: body).filter { !$0.isEmpty }.isEmpty }
            #expect(!makes, "\(getter) goes over all photos on the main thread")
        }
    }
}
