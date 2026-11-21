import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistTestSupport

/// Second review of "Dein Zuhause" (16.11.): the scenarios of its findings, kept as tests.
@Suite("Dein Zuhause: a home change and the analysis")
struct HomeChangeAndRunTests {
    let base = HomePipelineTests()
    let now = Fixture.date("2026-11-16")

    /// The new settings are stored before `resuggest()` gets the run lock. A run that gets it
    /// first, or the next launch after the app was closed or `resuggest` threw half way, applies
    /// the change through `run()` (the pending mark): the chosen trip is still held and the
    /// overview told, as with `resuggest()` alone.
    @Test func homeChangeAppliedByARunKeepsTheChosenSuggestion() async throws {
        let s = try base.setup { lib in _ = HomePipelineTests.gardaEveryMonth(&lib) }
        _ = try await s.pipeline.run()
        let before = try #require(try await s.pipeline.latestProposals())
        let chosen = try #require(before.proposals.first { $0.kind == .trip })
        try await s.store.setValue([chosen.id: ProposalDecision.createNew(title: nil, folderPath: nil)], forKey: "user.decisions")

        let parents = try await s.pipeline.recurringPlaceAnswers()
            .addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        try await s.pipeline.setRecurringPlaceAnswers(parents)
        // The run that got the lock first.
        _ = try await s.pipeline.run()
        // Then the resuggest the settings screen awaited.
        let notice = try await s.pipeline.resuggest()
        let after = try #require(try await s.pipeline.latestProposals())
        #expect(after.proposals.first { $0.id == chosen.id } == chosen)
        #expect((notice?.removed ?? 0) > 0)
    }

    /// A held suggestion loses the photos that are no longer in the library; with none left
    /// it is let go.
    @Test func heldSuggestionDropsDeletedPhotos() async throws {
        let s = try base.setup { lib in _ = HomePipelineTests.gardaEveryMonth(&lib) }
        _ = try await s.pipeline.run()
        let before = try #require(try await s.pipeline.latestProposals())
        let chosen = try #require(before.proposals.first { $0.kind == .trip })
        try await s.store.setValue([chosen.id: ProposalDecision.createNew(title: nil, folderPath: nil)], forKey: "user.decisions")
        let parents = try await s.pipeline.recurringPlaceAnswers()
            .addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        try await s.pipeline.setRecurringPlaceAnswers(parents)
        _ = try await s.pipeline.resuggest()
        // The user deletes half of the trip's photos in Photos; the next analysis runs.
        let deleted = Set(chosen.assetIDs.sorted().prefix(chosen.assetIDs.count / 2))
        await s.reader.set(assets: s.lib.assets.filter { !deleted.contains($0.id) })
        _ = try await s.pipeline.run()
        let library = Set(try await s.store.allAssets().map(\.id))
        let shown = try #require(try await s.pipeline.latestProposals()?.proposals.first { $0.id == chosen.id })
        #expect(shown.assetIDs.isSubset(of: library))
        #expect(shown.assetIDs == chosen.assetIDs.subtracting(deleted))
        #expect(shown.coverAssetID.map(shown.assetIDs.contains) == true)
        #expect(shown.title == chosen.title)
        // All of them: nothing left to hold.
        await s.reader.set(assets: s.lib.assets.filter { !chosen.assetIDs.contains($0.id) })
        _ = try await s.pipeline.run()
        #expect(try await s.pipeline.latestProposals()?.proposals.contains { $0.id == chosen.id } == false)
        #expect(try await s.pipeline.heldSuggestions().isEmpty)
    }
}

/// A reader that runs `hook` once, the first time the album list is read after `armed`.
final class HookedReader: PhotoLibraryReading, @unchecked Sendable {
    let base: InMemoryLibraryReader
    var armed = false
    var hook: (@Sendable () async -> Void)?
    init(base: InMemoryLibraryReader) { self.base = base }
    func access() async -> LibraryAccess { await base.access() }
    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] {
        try await base.fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails)
    }
    func currentInventory() async throws -> CollectionInventory {
        if armed, let hook { armed = false; await hook() }
        return try await base.currentInventory()
    }
}

@Suite("Review: Dein Zuhause, rebuild and stored values")
struct HomeReviewStoreTests {
    let now = Fixture.date("2026-11-16")

    func pipeline(_ store: AlbumistStore, reader: any PhotoLibraryReading) -> AnalysisPipeline {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.privacy.allowOnlineGeocoding = true
        return AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(answers: HomePipelineTests.answers),
            map: PipelineTests.map, conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, now: { Fixture.date("2026-11-16") })
    }

    /// "Analyse neu aufbauen" while `resuggest()` is busy: the app resets through the pipeline
    /// (`AnalysisPipeline.resetAnalysis`), which waits for the run lock, so the fresh store gets
    /// no suggestions of the old one.
    @Test func rebuildWaitsForResuggestAndLeavesAFreshStore() async throws {
        var lib = LibraryBuilder()
        HomePipelineTests.munichAndRome(&lib)
        let store = try AlbumistStore(url: nil)
        let reader = HookedReader(base: InMemoryLibraryReader(assets: lib.assets))
        let p = pipeline(store, reader: reader)
        _ = try await p.run()
        try await p.setHomeSettings(HomeSettings().withoutHome(date: now))
        final class Box: @unchecked Sendable { var reset: Task<Void, Never>? }
        let box = Box()
        reader.hook = { box.reset = Task { try? await p.resetAnalysis() } }
        reader.armed = true
        _ = try await p.resuggest()
        await box.reset?.value
        #expect(box.reset != nil)
        let proposals = try await store.value(ProposalSnapshot.self, forKey: "analysis.proposals")
        let trips = try await store.value([Trip].self, forKey: "analysis.trips")
        let places = try await store.places().count
        #expect(proposals == nil)
    }

    /// A value this build cannot read (a later version's shape, or damage) in `user.home`,
    /// `user.heldSuggestions` or a place answer: both are kept by "Analyse neu aufbauen" and come
    /// back from the backup copy, so they are read as not stored and the analysis runs.
    @Test func unreadableHomeValuesDoNotStopTheAnalysis() async throws {
        var lib = LibraryBuilder()
        HomePipelineTests.munichAndRome(&lib)
        let store = try AlbumistStore(url: nil)
        let p = pipeline(store, reader: InMemoryLibraryReader(assets: lib.assets))
        try await store.setValue(["version": "2", "mode": "confirmed", "confirmed": "Hamburg"], forKey: "user.home")
        var homeError: (any Error)?
        do { _ = try await p.run() } catch { homeError = error }
        #expect(homeError == nil)

        let store2 = try AlbumistStore(url: nil)
        let p2 = pipeline(store2, reader: InMemoryLibraryReader(assets: lib.assets))
        try await store2.setValue([["id": "x", "kind": "somethingNew"]], forKey: "user.heldSuggestions")
        var heldError: (any Error)?
        do { _ = try await p2.run() } catch { heldError = error }
        #expect(heldError == nil)

        // A kind of place a later version added ("Schule"): every answer becomes unreadable.
        struct Answer: Encodable { var id = "a"; var center = GeoCoordinate(latitude: 45.6, longitude: 10.7); var oftenHere = true; var name = "Malcesine"; var answeredAt = Date(timeIntervalSinceReferenceDate: 0); var kind = "school" }
        struct Answers: Encodable { var places = [Answer()] }
        let store3 = try AlbumistStore(url: nil)
        let p3 = pipeline(store3, reader: InMemoryLibraryReader(assets: lib.assets))
        try await store3.setValue(Answers(), forKey: "user.recurringPlaces")
        var placesError: (any Error)?
        do { _ = try await p3.run() } catch { placesError = error }
        #expect(placesError == nil)
    }
}

/// Runs `hook` once, at the first photo it looks at after `armed`.
final class HookedAnalyzer: ContentAnalyzing, @unchecked Sendable {
    let base = FakeContentAnalyzer()
    let state = Locked<(armed: Bool, hook: (@Sendable () async -> Void)?)>((false, nil))
    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        let hook: (@Sendable () async -> Void)? = state.withLock { s in
            guard s.armed else { return nil }
            s.armed = false
            return s.hook
        }
        if let hook { await hook() }
        return try await base.analyzeContent(asset, request: request)
    }
    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        try await base.recognizeText(asset, allowNetwork: allowNetwork)
    }
}

@Suite("Review: a home change during a run")
struct HomeReviewDuringRunTests {
    let now = Fixture.date("2026-11-16")

    @Test func runDuringAHomeChangeHoldsTheChoiceAndTellsTheOverview() async throws {
        var lib = LibraryBuilder()
        _ = HomePipelineTests.gardaEveryMonth(&lib)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let analyzer = HookedAnalyzer()
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.privacy.allowOnlineGeocoding = true
        let p = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(answers: HomePipelineTests.answers),
            map: PipelineTests.map, conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, now: { Fixture.date("2026-11-16") })
        _ = try await p.run()
        let before = try #require(try await p.latestProposals())
        let chosen = try #require(before.proposals.first { $0.kind == .trip })
        try await store.setValue([chosen.id: ProposalDecision.createNew(title: nil, folderPath: nil)], forKey: "user.decisions")

        // New photos arrive (a catch-up run), and the change is stored while that run is busy.
        var later = lib
        later.daily(from: "2026-11-01", to: "2026-11-03", at: Fixture.Places.munichHome, perDay: 2)
        await reader.set(assets: later.assets)
        let parents = try await p.recurringPlaceAnswers()
            .addingPersonalPlace(at: Fixture.Places.gardaLake, name: "Malcesine", kind: .parents, label: nil, date: now)
        analyzer.state.withLock { $0 = (true, { try? await p.setRecurringPlaceAnswers(parents) }) }
        _ = try await p.run()
        let afterRun = try #require(try await p.latestProposals())
        let tripsLeft = afterRun.proposals.filter { $0.kind == .trip }.count
        // The settings screen's resuggest, queued behind the run.
        let notice = try await p.resuggest()
        let after = try #require(try await p.latestProposals())
        // The run follows the change: the nine other trips are gone.
        #expect(tripsLeft <= 1)
        // What the user chose is held, and the overview is told.
        #expect(after.proposals.first { $0.id == chosen.id } == chosen)
        #expect(notice?.isEmpty == false)
    }
}

@Suite("Review: Stimmt after a move, through the pipeline")
struct HomeReviewStimmtPipelineTests {
    let now = Fixture.date("2026-11-16")

    @Test func stimmtAfterAMoveAddsNoTrip() async throws {
        let s = try HomePipelineTests().setup { lib in
            lib.daily(from: "2017-01-01", to: "2018-12-31", at: HomePipelineTests.hamburg, perDay: 2, hour: 19)
            lib.daily(from: "2019-01-01", to: "2020-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        }
        _ = try await s.pipeline.run()
        let before = try #require(try await s.pipeline.latestProposals())
        let detected = try #require(try await s.pipeline.detectedHome())
        let facts = try await s.pipeline.currentFacts()
        // AppModel.confirmDetectedHome: the detected place, named from the photos, no date.
        let place = HomePlace(center: detected.center, components: HomeName.components(near: detected.center, facts: facts))
        try await s.pipeline.setHomeSettings(HomeSettings().confirming(place, date: now))
        let notice = try await s.pipeline.resuggest()
        let after = try #require(try await s.pipeline.latestProposals())
        let newTrips = after.proposals.filter { $0.kind == .trip }
        let home = try await s.store.value(Set<AssetID>.self, forKey: "analysis.home") ?? []
        #expect(newTrips.isEmpty)
    }
}
