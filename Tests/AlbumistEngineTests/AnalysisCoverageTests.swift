import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Cases from the coverage map after the first device test (15.11.): access changed during a
/// run, photos added and deleted during a run, hidden photos, a run killed and resumed with a
/// reopened database, small and unusual libraries, and photos analysed side by side.
@Suite("Analysis coverage")
struct AnalysisCoverageTests {
    static let map: OfflineWorldMap = PipelineTests.map

    /// Deterministic analyzer: labels from the id, text for screenshots, an optional delay,
    /// a hook per content call, and photos it cannot read.
    final class Analyzer: ContentAnalyzing, @unchecked Sendable {
        let delay: Duration
        let contentCalls = Locked<[AssetID]>([])
        let textCalls = Locked<[AssetID]>([])
        let unreadable = Locked<Set<AssetID>>([])
        let blocked = Locked(false)
        let hook = Locked<(@Sendable (Int) async -> Void)?>(nil)

        init(delay: Duration = .zero) { self.delay = delay }

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            let count = contentCalls.withLock { $0.append(asset.id); return $0.count }
            if let hook = hook.withLock({ $0 }) { await hook(count) }
            if delay > .zero { try await Task.sleep(for: delay) } else { await Task.yield() }
            if blocked.withLock({ $0 }) || unreadable.withLock({ $0.contains(asset.id) }) { throw AnalysisError.unreadable }
            let n = Int(asset.id.rawValue.suffix(2)) ?? 0
            let labels = n % 3 == 0 ? [LabelScore("dog", 0.9, isPrecise: true), LabelScore("grass", 0.4)] : [LabelScore("food", 0.7)]
            return ContentAnalysis(labels: labels, source: .localPreview, aestheticsScore: Double(n % 10) / 10, isUtility: asset.isScreenshotLike)
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            textCalls.withLock { $0.append(asset.id) }
            if delay > .zero { try await Task.sleep(for: delay) } else { await Task.yield() }
            if blocked.withLock({ $0 }) { throw AnalysisError.unreadable }
            return TextAnalysis(text: "Ihre Bestellung Nr. \(asset.id.rawValue) Lieferung morgen", source: .original)
        }
    }

    final class Clock: @unchecked Sendable {
        let value = Locked(Fixture.date("2026-07-01 12:00"))
    }

    static func library(photos: Int, screenshots: Int = 0, videos: Int = 0) -> [AssetSnapshot] {
        var lib = LibraryBuilder()
        for i in 0..<photos {
            _ = lib.photo(at: Fixture.date("2026-03-01 10:00").addingTimeInterval(Double(i) * 7_200), i % 4 == 0 ? Fixture.Places.rome : Fixture.Places.munichHome)
        }
        for i in 0..<screenshots {
            _ = lib.photo(at: Fixture.date("2026-02-01 20:00").addingTimeInterval(Double(i) * 3_600), nil, subtypes: .screenshot)
        }
        for i in 0..<videos {
            _ = lib.photo(at: Fixture.date("2026-01-10 18:00").addingTimeInterval(Double(i) * 86_400), Fixture.Places.munichHome, kind: .video)
        }
        return lib.assets
    }

    static func pipeline(
        store: AlbumistStore, reader: InMemoryLibraryReader, analyzer: Analyzer, settings: OrganizationSettings = settings(),
        lanes: (content: Int, text: Int) = (4, 2), batchSize: Int = 10, time: ManualTime = ManualTime()
    ) -> AnalysisPipeline {
        let clock = Clock()
        return AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: time.source,
            batchSize: batchSize, contentLanes: lanes.content, textLanes: lanes.text, now: { clock.value.withLock { $0 } }
        )
    }

    static func settings(hidden: Bool = false) -> OrganizationSettings {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        settings.privacy.includeHiddenAssets = hidden
        return settings
    }

    // MARK: B4 photo access changed during a run

    /// Review of 11ef3e1 (minor 3): the trips step stood still (no count, the value held) on a
    /// large library. It counts the photos with a location it has grouped, every 1,000, and the
    /// card shows that count; the whole run reports it as it goes.
    @Test func tripsStepCountsThePhotosItGroups() async throws {
        let assets = Self.library(photos: 4_500)
        var seen: [Int] = []
        var of = 0
        _ = TripDetector(configuration: OrganizationSettings().trips.advanced, calendar: Fixture.calendar)
            .analyse(in: assets, progress: { done, total in seen.append(done); of = total })
        #expect(of == 4_500)
        #expect(seen == [0, 1_000, 2_000, 3_000, 4_000, 4_500])
        #expect(AnalysisCardState.Position(step: .trips, completed: 2_000, total: 4_500).hasCount)
        #expect(!AnalysisCardState.Position(step: .trips, completed: 0, total: 1).hasCount)

        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets)
        let pipeline = Self.pipeline(store: store, reader: reader, analyzer: Analyzer())
        let counts = Locked<[Int]>([])
        _ = try await pipeline.run(onProgress: { p in
            if p.stage == .patterns { counts.withLock { $0.append(p.completed) } }
        })
        let reported = counts.withLock { $0 }
        #expect(Set(reported).count >= 5, "trips step reports: \(reported)")
        #expect(reported == reported.sorted())
    }

    /// Review of ee36188 (4): the places step's work left counts only located photos whose
    /// place is not resolved yet, so the time left is not inflated on a run that goes on.
    @Test func placesLeftCountsOnlyUnresolvedPlaces() async throws {
        let assets = Self.library(photos: 300)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets)
        let pipeline = Self.pipeline(store: store, reader: reader, analyzer: Analyzer())
        let workloads = Locked<[AnalysisWorkload]>([])
        let record: @Sendable (AnalysisPipeline.Progress) -> Void = { p in
            if let w = p.workload { workloads.withLock { $0.append(w) } }
        }
        _ = try await pipeline.run(onProgress: record)
        _ = try await pipeline.run(onProgress: record)
        let seen = workloads.withLock { $0 }
        let first = try #require(seen.first), second = try #require(seen.last)
        #expect(seen.count == 2)
        #expect(first.located > 0)
        #expect(first.itemsLeft(.places) == first.located)
        let resolved = try await store.places().count
        #expect(resolved > 0)
        #expect(second.itemsLeft(.places) == max(0, second.located - resolved), "\(second) with \(resolved) places resolved")
        #expect(AnalysisWorkload(photos: 10, located: 8, screenshots: 0, contentLeft: 0, textLeft: 0).itemsLeft(.places) == 8)
    }

    @Test func accessRevokedDuringARunStopsCleanlyAndResumes() async throws {
        let assets = Self.library(photos: 40)
        let reader = InMemoryLibraryReader(assets: assets)
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: reader, analyzer: analyzer)
        // In Settings the user takes the access away while the 15th photo is read: PhotoKit
        // cannot load any image from then on.
        analyzer.hook.withLock { $0 = { count in
            if count == 15 {
                await reader.set(access: .denied)
                analyzer.blocked.withLock { $0 = true }
            }
        } }
        let first = try await p.run()
        #expect(first.pausedBecause == .accessRevoked)
        #expect(!first.isComplete)
        // Nothing was counted against the photos, nothing was removed.
        let records = try await store.results(ContentAnalysis.self, kind: "content")
        #expect(records.values.allSatisfy { $0.failedAttempts == nil })
        #expect(try await store.assetCount() == assets.count)
        let done = assets.count - (try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion))
        #expect(done > 0 && done < assets.count)

        // Still no access: the next run says so at once and reads nothing.
        analyzer.hook.withLock { $0 = nil }
        let calls = analyzer.contentCalls.withLock { $0.count }
        let refused = try await p.run()
        #expect(refused.pausedBecause == .accessRevoked)
        #expect(analyzer.contentCalls.withLock { $0.count } == calls)

        // Access back: goes on from where it was and finishes; no photo is read twice.
        await reader.set(access: .full)
        analyzer.blocked.withLock { $0 = false }
        let seen = Locked<[AnalysisPipeline.Progress]>([])
        let resumed = try await p.run(onProgress: { progress in seen.withLock { $0.append(progress) } })
        #expect(resumed.isComplete)
        #expect(resumed.contentAnalyzed == assets.count - done)
        #expect(seen.withLock { $0 }.first { $0.stage == .content }?.completed == done)
        let succeeded = Set(try await store.results(ContentAnalysis.self, kind: "content").filter { $0.value.failedAttempts == nil }.keys)
        #expect(succeeded.count == assets.count)
    }

    @Test func accessReducedToLimitedDuringARunEndsIt() async throws {
        let assets = Self.library(photos: 30)
        let reader = InMemoryLibraryReader(assets: assets)
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: reader, analyzer: analyzer)
        let selection = Array(assets.prefix(5))
        // "Ausgewählte Fotos": photos outside the selection cannot be loaded any more.
        analyzer.hook.withLock { $0 = { count in
            if count == 12 {
                await reader.set(access: .limited)
                analyzer.unreadable.withLock { $0 = Set(assets.dropFirst(5).map(\.id)) }
            }
        } }
        let first = try await p.run()
        #expect(first.pausedBecause == .accessRevoked)
        #expect(try await store.results(ContentAnalysis.self, kind: "content").values.allSatisfy { $0.failedAttempts == nil })
        // The next run reads the library as it is now: only the selection.
        analyzer.hook.withLock { $0 = nil }
        await reader.set(assets: selection)
        let next = try await p.run()
        #expect(next.isComplete)
        // The photos outside the selection are set aside, not deleted (review P1-07): what was
        // found about them stays for when they are shared again.
        #expect(next.removed == 0)
        #expect(next.setAside == assets.count - selection.count)
        #expect(try await store.outOfViewCount() == assets.count - selection.count)
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
    }

    // MARK: B15 photos added and deleted during a run

    @Test func photosAddedAndDeletedDuringARun() async throws {
        let assets = Self.library(photos: 40)
        let reader = InMemoryLibraryReader(assets: assets)
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: reader, analyzer: analyzer)
        // Oldest photos (read last) are deleted, new ones arrive while the 10th photo is read.
        let deleted = Set(assets.prefix(6).map(\.id))
        let added = (0..<4).map { i in
            AssetSnapshot(id: AssetID("new-\(i)"), kind: .image, creationDate: Fixture.date("2026-09-01 10:00").addingTimeInterval(Double(i) * 60),
                          location: Fixture.Places.munichHome, pixelWidth: 4032, pixelHeight: 3024)
        }
        analyzer.hook.withLock { $0 = { count in
            if count == 10 {
                await reader.set(assets: assets.filter { !deleted.contains($0.id) } + added)
                analyzer.unreadable.withLock { $0 = deleted }
            }
        } }
        let first = try await p.run()
        #expect(first.isComplete)
        #expect(first.contentAnalyzed == assets.count - deleted.count)
        // The catch-up run: deleted photos vanish with their results, new ones are analysed.
        analyzer.hook.withLock { $0 = nil }
        let catchUp = try await p.run()
        #expect(catchUp.isComplete)
        #expect(catchUp.removed == deleted.count)
        #expect(catchUp.contentAnalyzed == added.count)
        #expect(try await store.assetCount() == assets.count - deleted.count + added.count)
        let records = try await store.results(ContentAnalysis.self, kind: "content")
        #expect(records.keys.allSatisfy { !deleted.contains($0) })
        #expect(records.count == assets.count - deleted.count + added.count)
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        let facts = try await p.currentFacts()
        #expect(facts.count == assets.count - deleted.count + added.count)
    }

    // MARK: B13 hidden photos

    @Test func hiddenPhotosOnlyWhenTheUserLetsAlbumistSeeThem() async throws {
        let assets = Self.library(photos: 20)
        let hidden = Set(assets.suffix(3).map(\.id))
        let reader = InMemoryLibraryReader(assets: assets, hidden: hidden)
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: reader, analyzer: analyzer)
        let first = try await p.run()
        #expect(first.isComplete)
        #expect(first.contentAnalyzed == assets.count - hidden.count)
        #expect(analyzer.contentCalls.withLock { $0 }.allSatisfy { !hidden.contains($0) })
        #expect(try await p.latestProposals()?.proposals.allSatisfy { $0.assetIDs.isDisjoint(with: hidden) } ?? true)

        // Switched on: the hidden photos are analysed too.
        await p.update(settings: Self.settings(hidden: true))
        let shown = try await p.run()
        #expect(shown.contentAnalyzed == hidden.count)
        #expect(try await store.assetCount() == assets.count)

        // Switched off again: they leave the database with their results.
        await p.update(settings: Self.settings(hidden: false))
        let off = try await p.run()
        #expect(off.removed == hidden.count)
        #expect(try await store.results(ContentAnalysis.self, kind: "content").keys.allSatisfy { !hidden.contains($0) })
    }

    // MARK: A4 killed and resumed with the database opened again

    @Test func runKilledMidwayGoesOnWithAReopenedDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-kill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")
        let assets = Self.library(photos: 60, screenshots: 6)
        let batch = 10

        // First process: iOS ends it while the 25th photo is analysed (it never returns).
        let killed = Analyzer()
        killed.hook.withLock { $0 = { count in
            if count >= 25 { try? await Task.sleep(for: .seconds(3_600)) }
        } }
        let firstStore = try AlbumistStore(url: url)
        let first = Self.pipeline(store: firstStore, reader: InMemoryLibraryReader(assets: assets), analyzer: killed, batchSize: batch)
        let progress = Locked<[AnalysisPipeline.Progress]>([])
        let abandoned = Task { try await first.run(onProgress: { p in progress.withLock { $0.append(p) } }) }
        // Wait until it hangs in the 25th photo, and until the early suggestions it makes beside
        // the image step are saved: a process iOS has ended writes nothing more, but this one
        // goes on in the test, and a write of it during the second run locked the database
        // ("SQLite error 5", 1 of 6 runs on main 31ec24c, 5 of 6 once the overview refresh
        // made the early set later).
        // Only a guard against a hang, not a measure of speed: alone this takes under a second,
        // but in the whole parallel suite the load tests hold the shared threads, and the test's
        // own loop was not resumed for 71.7 s (Linux, 4 cores, 20.11.; IMPROVEMENTS.md).
        let clock = ContinuousClock()
        let waitedFrom = clock.now
        while killed.contentCalls.withLock({ $0.count }) < 25 || !progress.withLock({ $0.contains(where: \.earlyProposals) }) {
            try #require(clock.now - waitedFrom < .seconds(300), "the first process never got to the 25th photo with its early suggestions saved")
            try await Task.sleep(for: .milliseconds(5))
        }
        let markedBefore = try await firstStore.assetCount() - (try await firstStore.countNeedingAnalysis(version: AnalysisPipeline.contentVersion))
        #expect(markedBefore >= 20 && markedBefore < 25)

        // Second process: a new store on the same file.
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: url)
        let second = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: analyzer, batchSize: batch)
        let seen = Locked<[AnalysisPipeline.Progress]>([])
        let report = try await second.run(onProgress: { p in seen.withLock { $0.append(p) } })
        // The first process is gone for good: its run is never resumed or cancelled.
        _ = abandoned
        #expect(report.isComplete)
        // Goes on from what the first process stored, counted over the whole library.
        let content = seen.withLock { $0 }.filter { $0.stage == .content }
        #expect(content.first?.completed == markedBefore)
        #expect(content.last?.completed == assets.count)
        // At most the batch in work when it was killed is read again.
        #expect(analyzer.contentCalls.withLock { $0.count } == assets.count - markedBefore)
        #expect(analyzer.contentCalls.withLock { $0.count } + markedBefore == assets.count)
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        #expect(report.textRecognized == 6)
    }

    // MARK: B5, B10, B6 small and unusual libraries

    @Test func emptyLibraryFinishes() async throws {
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: []), analyzer: analyzer)
        let report = try await p.run()
        #expect(report.isComplete)
        #expect(report.newOrChanged == 0 && report.contentAnalyzed == 0 && report.textRecognized == 0)
        #expect(report.proposals == 0)
        #expect(try await p.latestProposals()?.proposals.isEmpty == true)
        // And again (a check on an empty library).
        #expect(try await p.run().isComplete)
    }

    @Test func videosOnlyLibraryFinishes() async throws {
        let assets = Self.library(photos: 0, videos: 8)
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: analyzer)
        let report = try await p.run()
        #expect(report.isComplete)
        #expect(report.contentAnalyzed == 8)
        // Videos are never read for text.
        #expect(analyzer.textCalls.withLock { $0 }.isEmpty)
        #expect(report.placesResolved == 8)
    }

    @Test func fivePhotosFinish() async throws {
        let assets = Self.library(photos: 5)
        let analyzer = Analyzer()
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: analyzer)
        let report = try await p.run()
        #expect(report.isComplete)
        #expect(report.contentAnalyzed == 5)
        #expect(report.newOrChanged == 5)
        let again = try await p.run()
        #expect(again.isComplete && again.contentAnalyzed == 0 && again.newOrChanged == 0)
    }

    // MARK: Side by side gives the same results as one by one

    struct Stored: Equatable {
        var contents: [AssetID: ContentAnalysis]
        var texts: [AssetID: TextResult]
        var places: [AssetID: ResolvedPlace]
        var proposals: [String]
        var report: AnalysisPipeline.Report
    }

    func runOnce(lanes: (content: Int, text: Int), delay: Duration) async throws -> (Stored, Duration, Analyzer) {
        let assets = Self.library(photos: 80, screenshots: 20, videos: 4)
        let analyzer = Analyzer(delay: delay)
        let store = try AlbumistStore(url: nil)
        let p = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: analyzer, lanes: lanes)
        var report = AnalysisPipeline.Report()
        let elapsed = try await ContinuousClock().measure { report = try await p.run() }
        let stored = Stored(
            contents: try await store.results(ContentAnalysis.self, kind: "content"),
            texts: try await store.results(TextResult.self, kind: "text"),
            places: try await store.places().mapValues { var p = $0; p.resolvedAt = .distantPast; return p },
            proposals: (try await p.latestProposals()?.proposals ?? []).map { "\($0.id)|\($0.title)|\($0.assetIDs.sorted())" }.sorted(),
            report: report
        )
        return (stored, elapsed, analyzer)
    }

    @Test func sideBySideStoresTheSameAsOneByOne() async throws {
        let (sequential, _, _) = try await runOnce(lanes: (1, 1), delay: .milliseconds(1))
        let (concurrent, _, analyzer) = try await runOnce(lanes: (4, 2), delay: .milliseconds(1))
        #expect(sequential.report.isComplete && concurrent.report.isComplete)
        #expect(sequential.contents.count == 104)
        #expect(sequential.contents == concurrent.contents)
        #expect(sequential.texts == concurrent.texts)
        #expect(sequential.places == concurrent.places)
        #expect(sequential.proposals == concurrent.proposals)
        #expect(sequential.report == concurrent.report)
        // Every photo once, none twice.
        let calls = analyzer.contentCalls.withLock { $0 }
        #expect(calls.count == Set(calls).count)
    }

    @Test func sideBySideIsFaster() async throws {
        let (_, sequential, _) = try await runOnce(lanes: (1, 1), delay: .milliseconds(10))
        let (_, concurrent, _) = try await runOnce(lanes: (4, 2), delay: .milliseconds(10))
        print("LANES_TIMING 104 photos at 10 ms: one by one \(sequential), side by side \(concurrent)")
        #expect(concurrent < sequential * 0.6)
    }

    /// 2,000 photos at 20 ms per image (Vision-like waiting), measured one by one and side by
    /// side. Run with ALBUMIST_LOAD_TEST=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALBUMIST_LOAD_TEST"] != nil))
    func twoThousandPhotosOneByOneAndSideBySide() async throws {
        var timings: [String] = []
        for lanes in [(1, 1), (4, 2)] {
            let assets = Self.library(photos: 1_800, screenshots: 200)
            let analyzer = Analyzer(delay: .milliseconds(20))
            let store = try AlbumistStore(url: nil)
            let p = Self.pipeline(store: store, reader: InMemoryLibraryReader(assets: assets), analyzer: analyzer, lanes: lanes, batchSize: 50)
            var report = AnalysisPipeline.Report()
            let elapsed = try await ContinuousClock().measure { report = try await p.run() }
            #expect(report.isComplete)
            #expect(report.contentAnalyzed == 2_000)
            timings.append("lanes \(lanes.0)/\(lanes.1): \(elapsed)")
        }
        print("LANES_TIMING 2000 photos at 20 ms: " + timings.joined(separator: " | "))
    }
}

/// Found by the five-photo library: a trip without a known home had an infinite distance,
/// which JSON cannot hold, and every run failed while saving the trips.
@Suite("Stored values that are not finite")
struct NonFiniteValueTests {
    @Test func tripWithoutHomeIsStored() async throws {
        // Five photos, two of them in Rome: too few for a habitual area to measure from.
        let assets = AnalysisCoverageTests.library(photos: 5)
        let trips = TripDetector(configuration: OrganizationSettings().trips.advanced, calendar: Fixture.calendar).detect(in: assets, corrections: TripCorrections())
        #expect(!trips.isEmpty)
        #expect(trips.allSatisfy { $0.maxDistanceFromHomeMeters.isFinite })
        let store = try AlbumistStore(url: nil)
        try await store.setValue(trips, forKey: "analysis.trips")
        #expect(try await store.value([Trip].self, forKey: "analysis.trips") == trips)
    }

    @Test func storeKeepsInfinityAndNaN() async throws {
        let store = try AlbumistStore(url: nil)
        try await store.setValue([Double.infinity, -.infinity, 1.5], forKey: "numbers")
        #expect(try await store.value([Double].self, forKey: "numbers") == [.infinity, -.infinity, 1.5])
        try await store.setValue(Double.nan, forKey: "nan")
        #expect(try await store.value(Double.self, forKey: "nan")?.isNaN == true)
    }
}
