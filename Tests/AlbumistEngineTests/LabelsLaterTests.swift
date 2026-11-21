import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
@testable import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// "Themen" or "Dokumente" turned on after the photos were analysed: image labels are asked
/// for only while one of them is on, and photos used to be marked analysed either way. So the
/// photos analysed before never got labels: search ("Hund", "Rechnung") and both areas missed
/// them until "Analyse neu aufbauen". Now the store records which photos have labels
/// (`labels_version`), and the next run gives exactly the photos without them their labels:
/// a look that asks for nothing else, merged into the earlier result, no text read again.
@Suite("Labels turned on later")
struct LabelsLaterTests {
    static let map: OfflineWorldMap = PipelineTests.map

    /// Labels from the id: every third photo a receipt, the others a dog. Records each request.
    final class Analyzer: ContentAnalyzing, @unchecked Sendable {
        let requests = Locked<[(AssetID, ContentAnalysisRequest)]>([])
        let textCalls = Locked<[AssetID]>([])
        let unreadable = Locked<Set<AssetID>>([])
        /// Photos the analyzer itself fails on (not `AnalysisError`): counted against a photo only
        /// once a photo after it works.
        let failing = Locked<Set<AssetID>>([])
        /// Photos Photos does not hand over in time (`PhotosNotResponding`).
        let quiet = Locked<Set<AssetID>>([])
        /// Photos whose text Photos does not hand over in time.
        let textQuiet = Locked<Set<AssetID>>([])
        /// How often the image step said it ended (`contentEnded`).
        let contentEnds = Locked(0)
        struct VisionFailed: Error {}
        let delay: Duration
        init(delay: Duration = .zero) { self.delay = delay }

        static func isReceipt(_ id: AssetID) -> Bool { (Int(id.rawValue.suffix(2)) ?? 0) % 3 == 0 }

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            requests.withLock { $0.append((asset.id, request)) }
            if delay > .zero { try await Task.sleep(for: delay) } else { await Task.yield() }
            if unreadable.withLock({ $0.contains(asset.id) }) { throw AnalysisError.unreadable }
            if failing.withLock({ $0.contains(asset.id) }) { throw VisionFailed() }
            if quiet.withLock({ $0.contains(asset.id) }) { throw PhotosNotResponding(lane: .image, what: "fetchAsset", notSent: false) }
            let labels = !request.classify ? []
                : Self.isReceipt(asset.id) ? [LabelScore("receipt", 0.9, isPrecise: true)] : [LabelScore("dog", 0.9, isPrecise: true)]
            // Only a full look has a feature print (the labels-only look asks for none).
            return ContentAnalysis(labels: labels, featurePrint: request.featurePrint ? Embedding([0.5, 0.5]) : nil,
                                   source: .localPreview, aestheticsScore: 0.25, isUtility: asset.isScreenshotLike)
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            textCalls.withLock { $0.append(asset.id) }
            if textQuiet.withLock({ $0.contains(asset.id) }) { throw PhotosNotResponding(lane: .image, what: "fetchAsset", notSent: false) }
            return TextAnalysis(text: "Rechnung Nr. 4711 Gesamtbetrag 12,50 EUR", source: .original)
        }

        func contentEnded() { contentEnds.withLock { $0 += 1 } }

        var full: Int { requests.withLock { $0.filter { $0.1.featurePrint }.count } }
        var labelsOnly: Int { requests.withLock { $0.filter { $0.1 == .labelsOnly }.count } }
        var classifyingRequests: Int { requests.withLock { $0.filter { $0.1.classify }.count } }
    }

    static func settings(labels: Bool, documents: Bool? = nil) -> OrganizationSettings {
        var s = OrganizationSettings()
        s.titleLanguage = .german
        s.enabledAreas.remove(.imageCategories)
        s.enabledAreas.remove(.documents)
        if labels { s.enabledAreas.insert(.imageCategories) }
        if documents ?? false { s.enabledAreas.insert(.documents) }
        return s
    }

    struct Setup {
        let store: AlbumistStore
        let analyzer: Analyzer
        let pipeline: AnalysisPipeline
        let photos: [AssetID]
        let screenshots: [AssetID]
    }

    static func setup(photos count: Int = 30, screenshots shots: Int = 3, labels: Bool, store: AlbumistStore? = nil,
                      delay: Duration = .zero, conditions: any AnalysisConditions = FakeConditions()) throws -> Setup {
        var lib = LibraryBuilder()
        var photos: [AssetID] = []
        for i in 0..<count {
            photos.append(lib.photo(at: Fixture.date("2026-03-01 10:00").addingTimeInterval(Double(i) * 7_200), Fixture.Places.munichHome))
        }
        var screenshots: [AssetID] = []
        for i in 0..<shots {
            screenshots.append(lib.photo(at: Fixture.date("2026-02-01 20:00").addingTimeInterval(Double(i) * 3_600), nil, subtypes: .screenshot))
        }
        let store = try store ?? AlbumistStore(url: nil)
        let analyzer = Analyzer(delay: delay)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer, geocoder: FakeGeocoder(), map: map,
            conditions: conditions, settings: settings(labels: labels), calendar: Fixture.calendar, time: ManualTime().source, batchSize: 7
        )
        return Setup(store: store, analyzer: analyzer, pipeline: pipeline, photos: photos, screenshots: screenshots)
    }

    /// The content step's reports of one run, in order.
    final class Recorder: @unchecked Sendable {
        let content = Locked<[(completed: Int, total: Int)]>([])
        let overall = Locked<[Double]>([])
        var onProgress: @Sendable (AnalysisPipeline.Progress) -> Void {
            { p in
                if p.stage == .content { self.content.withLock { $0.append((p.completed, p.total)) } }
                self.overall.withLock { $0.append(AnalysisPipeline.Progress.overall(stage: p.stage, completed: p.completed, total: p.total)) }
            }
        }
        func expectMonotonic(_ comment: Comment? = nil) {
            let content = content.withLock { $0 }
            for (a, b) in zip(content, content.dropFirst()) {
                #expect(b.completed >= a.completed, comment)
                #expect(b.total >= a.total, comment)
            }
            for c in content { #expect(c.completed <= c.total, comment) }
            let overall = overall.withLock { $0 }
            for (a, b) in zip(overall, overall.dropFirst()) { #expect(b >= a - 1e-9, comment) }
        }
    }

    static func dogSearch(_ pipeline: AnalysisPipeline) async throws -> Set<AssetID> {
        Set(SearchIndex(facts: try await pipeline.currentFacts()).search("Hund").ids)
    }

    @Test func turnedOnLaterTheOlderPhotosGetLabelsOnlyOnce() async throws {
        let s = try Self.setup(labels: false)
        let first = try await s.pipeline.run()
        #expect(first.isComplete)
        let all = s.photos.count + s.screenshots.count
        #expect(s.analyzer.full == all)
        #expect(s.analyzer.classifyingRequests == 0)
        #expect(try await Self.dogSearch(s.pipeline).isEmpty)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == 0 })
        let textBefore = s.analyzer.textCalls.withLock { $0 }
        #expect(Set(textBefore) == Set(s.screenshots))
        let before = try await s.store.results(ContentAnalysis.self, kind: "content")

        // "Themen" on.
        let on = Self.settings(labels: true)
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: Self.settings(labels: false), to: on))
        await s.pipeline.update(settings: on)
        let recorder = Recorder()
        let second = try await s.pipeline.run(onProgress: recorder.onProgress)
        #expect(second.isComplete)
        // Each photo once, labels only: no second full look.
        #expect(s.analyzer.full == all)
        #expect(s.analyzer.labelsOnly == all)
        #expect(second.labelsAdded == all)
        #expect(second.contentAnalyzed == all)
        // No text read again: only the photos the labels show to be documents are read, once.
        let textAfter = s.analyzer.textCalls.withLock { $0 }
        let newlyRead = Array(textAfter.dropFirst(textBefore.count))
        #expect(Array(textAfter.prefix(textBefore.count)) == textBefore)
        #expect(Set(newlyRead) == Set(s.photos.filter(Analyzer.isReceipt)))
        #expect(newlyRead.count == Set(newlyRead).count)
        // The labels are added, everything else of the earlier result stays.
        let after = try await s.store.results(ContentAnalysis.self, kind: "content")
        for id in s.photos {
            let old = try #require(before[id]), new = try #require(after[id])
            #expect(!new.labels.isEmpty)
            #expect(new.featurePrint == old.featurePrint && new.featurePrint != nil)
            #expect(new.aestheticsScore == old.aestheticsScore)
            #expect(new.failedAttempts == nil)
        }
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        let dogs = Set((s.photos + s.screenshots).filter { !Analyzer.isReceipt($0) })
        let foundDogs = try await Self.dogSearch(s.pipeline)
        #expect(foundDogs == dogs, "\(foundDogs.subtracting(dogs).sorted()) \(dogs.subtracting(foundDogs).sorted())")
        // The count: one photo each, never back, ends at its total.
        recorder.expectMonotonic()
        let content = recorder.content.withLock { $0 }
        #expect(content.first?.completed == 0)
        #expect(content.first?.total == all)
        #expect(content.last.map { $0.completed == $0.total } == true)

        // Once only: the next run looks at nothing.
        let third = try await s.pipeline.run()
        #expect(third.isComplete)
        #expect(s.analyzer.requests.withLock { $0.count } == 2 * all)
    }

    @Test func offAndOnAgainKeepsTheLabelsAndDoesNothing() async throws {
        let s = try Self.setup(labels: true)
        _ = try await s.pipeline.run()
        let all = s.photos.count + s.screenshots.count
        #expect(s.analyzer.full == all)
        #expect(s.analyzer.classifyingRequests == all)
        #expect(s.analyzer.labelsOnly == 0)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        let labelled = try await s.store.results(ContentAnalysis.self, kind: "content")

        // Off: the labels stay (search still finds what they say, and turning the area on again
        // costs nothing); the step has nothing to do.
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: Self.settings(labels: true), to: Self.settings(labels: false)))
        await s.pipeline.update(settings: Self.settings(labels: false))
        let off = Recorder()
        _ = try await s.pipeline.run(onProgress: off.onProgress)
        #expect(s.analyzer.requests.withLock { $0.count } == all)
        #expect(try await s.store.results(ContentAnalysis.self, kind: "content") == labelled)
        #expect(off.content.withLock { $0.allSatisfy { $0.completed == $0.total } })

        // On again: nothing to do either.
        await s.pipeline.update(settings: Self.settings(labels: true))
        let on = Recorder()
        _ = try await s.pipeline.run(onProgress: on.onProgress)
        #expect(s.analyzer.requests.withLock { $0.count } == all)
        #expect(on.content.withLock { $0.allSatisfy { $0.completed == $0.total } })
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })

        // Off, on, off, on without a run between: still nothing.
        for labels in [false, true, false, true] { await s.pipeline.update(settings: Self.settings(labels: labels)) }
        _ = try await s.pipeline.run()
        #expect(s.analyzer.requests.withLock { $0.count } == all)
    }

    /// "Dokumente" on later: the photos get their labels, and the ones that turn out to be
    /// documents are read for the first time ("Rechnung"); screenshots read before are not.
    @Test func documentsOnLaterReadsOnlyTheNewDocuments() async throws {
        let s = try Self.setup(labels: false)
        _ = try await s.pipeline.run()
        let textBefore = s.analyzer.textCalls.withLock { $0 }
        #expect(Set(textBefore) == Set(s.screenshots))

        await s.pipeline.update(settings: Self.settings(labels: false, documents: true))
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(s.analyzer.labelsOnly == s.photos.count + s.screenshots.count)
        let textAfter = s.analyzer.textCalls.withLock { $0 }
        let newlyRead = Array(textAfter.dropFirst(textBefore.count))
        let receipts = s.photos.filter(Analyzer.isReceipt)
        #expect(!receipts.isEmpty)
        #expect(Set(newlyRead) == Set(receipts))
        #expect(newlyRead.count == receipts.count)
        let found = Set(SearchIndex(facts: try await s.pipeline.currentFacts()).search("Rechnung").ids)
        #expect(found.isSuperset(of: receipts))
    }

    /// Pause in the middle of giving labels: stops within a photo per lane, the count goes on
    /// from where it was (never back), and the rest follows in the next run.
    @Test func pausedWhileAddingLabelsGoesOnWhereItStopped() async throws {
        let s = try Self.setup(photos: 40, screenshots: 0, labels: false, delay: .milliseconds(5))
        _ = try await s.pipeline.run()
        await s.pipeline.update(settings: Self.settings(labels: true))

        let control = AnalysisRunControl()
        let first = Recorder()
        let stopAt = 12
        let progress: @Sendable (AnalysisPipeline.Progress) -> Void = { p in
            first.onProgress(p)
            if p.stage == .content, p.completed >= stopAt { control.pause() }
        }
        let clock = ContinuousClock()
        let paused = try await s.pipeline.run(control: control, onProgress: progress)
        #expect(paused.pausedBecause == .userPaused)
        first.expectMonotonic()
        let reached = try #require(first.content.withLock { $0.last })
        #expect(reached.completed >= stopAt && reached.completed < reached.total)
        #expect(try await s.store.labelsVersions().values.filter { $0 == AnalysisPipeline.labelsVersion }.count == reached.completed)

        let second = Recorder()
        let start = clock.now
        let rest = try await s.pipeline.run(onProgress: second.onProgress)
        #expect(rest.isComplete)
        #expect(clock.now - start < .seconds(10))
        second.expectMonotonic()
        let resumed = try #require(second.content.withLock { $0.first })
        #expect(resumed.completed == reached.completed)
        #expect(resumed.total == reached.total)
        // Every photo got its labels once.
        #expect(s.analyzer.labelsOnly == 40)
        #expect(s.analyzer.full == 40)
    }

    /// A photo given up as unreadable has no result to add labels to: one more full look,
    /// given up again when it still cannot be read, and not tried every run after that.
    @Test func unreadablePhotosAreNotTriedEveryRun() async throws {
        let s = try Self.setup(photos: 6, screenshots: 0, labels: false)
        let broken = s.photos[2]
        s.analyzer.unreadable.withLock { $0 = [broken] }
        // Given up after its attempts (spaced out: the stored attempt is made old each time).
        for _ in 0..<ContentAnalysis.maxFailedAttempts {
            _ = try await s.pipeline.run()
            if var failed = try await s.store.result(ContentAnalysis.self, kind: "content", asset: broken), failed.failedAttempts != nil {
                failed.lastAttempt = .distantPast
                try await s.store.saveResult(failed, kind: "content", asset: broken, version: AnalysisPipeline.contentVersion)
            }
        }
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        await s.pipeline.update(settings: Self.settings(labels: true))
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(report.labelsAdded == 5)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion, labelsVersion: AnalysisPipeline.labelsVersion) == 0)
        // The photo given up had a full look again (no result to add labels to), not labels only.
        let afterEnabling = s.analyzer.requests.withLock { $0.filter { $0.0 == broken }.last?.1 }
        #expect(afterEnabling?.featurePrint == true && afterEnabling?.classify == true)
        let calls = s.analyzer.requests.withLock { $0.count }
        _ = try await s.pipeline.run()
        #expect(s.analyzer.requests.withLock { $0.count } == calls)
    }

    /// A photo that only needs its labels and cannot be read now: tried again in later runs,
    /// spaced out like any photo, and given up for its labels after as many tries. Its earlier
    /// result stays byte for byte as it was all the while (review probe of 29b6e6c, M1/N4).
    @Test func labelsOnlyFailuresAreCountedAndKeepTheEarlierResult() async throws {
        let s = try Self.setup(photos: 6, screenshots: 0, labels: false)
        _ = try await s.pipeline.run()
        let broken = s.photos[3]
        let earlier = try #require(try await s.store.rawResult(kind: "content", asset: broken))
        s.analyzer.unreadable.withLock { $0 = [broken] }
        await s.pipeline.update(settings: Self.settings(labels: true))

        func tries() -> Int { s.analyzer.requests.withLock { $0.filter { $0.0 == broken && $0.1 == .labelsOnly }.count } }
        func makeDue() async throws {
            var tried = try #require(try await s.store.result(LabelAttempts.self, kind: "labels", asset: broken))
            tried.lastAttempt = .distantPast
            try await s.store.saveResult(tried, kind: "labels", asset: broken, version: AnalysisPipeline.labelsVersion)
        }
        for attempt in 1..<ContentAnalysis.maxFailedAttempts {
            let report = try await s.pipeline.run()
            #expect(report.pausedBecause == nil)
            #expect(tries() == attempt)
            #expect(try await s.store.labelsVersions()[broken] == 0, "not given up after \(attempt)")
            #expect(try await s.store.result(LabelAttempts.self, kind: "labels", asset: broken)?.failedAttempts == attempt)
            #expect(try await s.store.rawResult(kind: "content", asset: broken) == earlier)
            // Right away again: not tried (spaced out like any photo that could not be read).
            _ = try await s.pipeline.run()
            #expect(tries() == attempt)
            try await makeDue()
        }
        _ = try await s.pipeline.run()
        #expect(tries() == ContentAnalysis.maxFailedAttempts)
        #expect(try await s.store.labelsVersions()[broken] == AnalysisPipeline.labelsVersion)
        #expect(try await s.store.rawResult(kind: "content", asset: broken) == earlier)
        // Given up: never tried again, and every other photo has its labels.
        _ = try await s.pipeline.run()
        #expect(tries() == ContentAnalysis.maxFailedAttempts)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion, labelsVersion: AnalysisPipeline.labelsVersion) == 0)
        #expect(s.analyzer.full == 6)
    }

    /// Readable again on a later try: the labels come, the count of failed tries goes.
    @Test func labelsOnlyFailureThenReadable() async throws {
        let s = try Self.setup(photos: 4, screenshots: 0, labels: false)
        _ = try await s.pipeline.run()
        let flaky = s.photos[1]
        s.analyzer.unreadable.withLock { $0 = [flaky] }
        await s.pipeline.update(settings: Self.settings(labels: true))
        _ = try await s.pipeline.run()
        #expect(try await s.store.labelsVersions()[flaky] == 0)
        var tried = try #require(try await s.store.result(LabelAttempts.self, kind: "labels", asset: flaky))
        tried.lastAttempt = .distantPast
        try await s.store.saveResult(tried, kind: "labels", asset: flaky, version: AnalysisPipeline.labelsVersion)
        s.analyzer.unreadable.withLock { $0 = [] }
        let report = try await s.pipeline.run()
        #expect(report.labelsAdded == 1)
        #expect(try await s.store.labelsVersions()[flaky] == AnalysisPipeline.labelsVersion)
        #expect(try await s.store.result(LabelAttempts.self, kind: "labels", asset: flaky) == nil)
        #expect(try await s.store.result(ContentAnalysis.self, kind: "content", asset: flaky)?.labels.isEmpty == false)
    }

    /// "Themen" and "Dokumente" turned on after the analysis, both as main areas: until the
    /// run gave the photos their labels, neither area counts them (the sorted count does not
    /// fall, the total does not shrink as the labels come in: second review of the labels fix),
    /// and the overview counts them apart (`labelsMissing`). Then the areas count as they apply.
    @Test func photosWaitingForLabelsAreCountedApart() async throws {
        let s = try Self.setup(labels: false)
        _ = try await s.pipeline.run()
        var off = Self.settings(labels: false)
        off.primaryAreas = [.trips, .places]
        var on = Self.settings(labels: true, documents: true)
        on.primaryAreas = [.trips, .places, .imageCategories, .documents]
        await s.pipeline.update(settings: on)

        func derive(_ settings: OrganizationSettings, scope: OrganizationScope = .all) async throws -> DerivedLibraryStatus {
            let missing = AnalysisPipeline.wantsLabels(settings)
                ? try await s.store.unlabelledAssets(version: AnalysisPipeline.contentVersion, labelsVersion: AnalysisPipeline.labelsVersion)
                : []
            return DerivedLibraryStatus.derive(
                facts: try await s.pipeline.currentFacts(), snapshot: try await s.pipeline.latestProposals(), settings: settings,
                overrides: OverrideSet(), contents: try await s.store.results(ContentAnalysis.self, kind: "content"),
                labelsMissing: missing, managed: [], inventory: CollectionInventory(), scope: scope)
        }
        let before = try await derive(off)
        let waiting = try await derive(on)
        #expect(before.labelsMissing == 0)
        // Every photo analysed before waits for its labels; the analysed count stays.
        #expect(waiting.labelsMissing == s.photos.count + s.screenshots.count)
        #expect(waiting.analyzed == before.analyzed)
        // The photos count in the ring as before the areas were turned on. The screenshots were
        // read as documents by their text (the text step read them, "Screenshots" is on): they
        // count for "Dokumente" right away, so the total grows and the sorted count stays.
        let ringOff = OrganizationStatusResolver(primaryAreas: off.primaryAreas)
        let ringOn = OrganizationStatusResolver(primaryAreas: on.primaryAreas)
        #expect(ringOn.progress(s.photos.compactMap { waiting.states[$0] }) == ringOff.progress(s.photos.compactMap { before.states[$0] }))
        #expect(waiting.progress.total == before.progress.total + s.screenshots.count)
        #expect(waiting.progress.fully >= before.progress.fully)
        for id in s.photos {
            #expect(waiting.states[id]?.areas[.imageCategories] == .notApplicable)
            #expect(waiting.states[id]?.areas[.documents] == .notApplicable)
        }
        // Only the chosen part of the library (the photos are from March 2026, the screenshots from February).
        let march = try await derive(on, scope: .year(2026))
        #expect(march.labelsMissing == s.photos.count + s.screenshots.count)
        let otherYear = try await derive(on, scope: .year(2025))
        #expect(otherYear.labelsMissing == 0)

        _ = try await s.pipeline.run()
        let after = try await derive(on)
        #expect(after.labelsMissing == 0)
        // Each photo counts now: a dog for "Themen", a receipt for "Dokumente" (its text is read
        // once its labels say it is one).
        for id in s.photos {
            let areas = after.states[id]?.areas
            #expect(areas?[Analyzer.isReceipt(id) ? .documents : .imageCategories] != .notApplicable)
        }
        #expect(after.progress.total >= waiting.progress.total + s.photos.count)
        #expect(after.progress.fully >= waiting.progress.fully)
    }

    /// The reviewer's case: two photos sorted into their trip's album, then "Dokumente" and
    /// "Themen" made main areas while their labels are missing. They stay sorted (before:
    /// "0 von 2 sortiert, dazu 2 teilweise").
    @Test func sortedPhotosStaySortedWhileTheirLabelsAreMissing() {
        var lib = LibraryBuilder()
        let a = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let b = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        let facts = lib.assets.map { AssetFacts(asset: $0, tripID: AlbumistID("trip")) }
        var settings = Self.settings(labels: true, documents: true)
        settings.primaryAreas = [.trips, .documents, .imageCategories]
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        let states = LibraryStatus.compute(facts: facts, snapshot: nil, settings: settings, contentAnalyzed: [a, b],
                                           organizedByAlbumist: [.trips: [a, b]])
        let ring = resolver.progress(states.values)
        #expect(ring.fully == 2 && ring.total == 2 && ring.partially == 0)
    }

    /// Third review of the labels fix, finding 2: photos sorted by their trip, then "Themen" made a
    /// main area. As their labels come in, a photo with a theme needs a theme album too, and the
    /// sorted count fell photo by photo. From the first refresh that would show it fall, the ring
    /// holds the count it showed ("Wird neu gezählt · Zuletzt 30 von 30 sortiert") until every
    /// photo was looked at once, also across a Pause; then it shows the new count. A photo whose
    /// labels could not be read holds nothing.
    @Test func theRingHoldsItsCountWhileTheLabelsComeIn() async throws {
        let s = try Self.setup(photos: 30, screenshots: 0, labels: false, delay: .milliseconds(2))
        let first = try await s.pipeline.run()
        var on = Self.settings(labels: true)
        on.primaryAreas = [.trips, .imageCategories]
        await s.pipeline.update(settings: on)
        let resolver = OrganizationStatusResolver(primaryAreas: on.primaryAreas)
        func status() async throws -> DerivedLibraryStatus {
            let labels = try await AnalysisPipeline.photosWaitingForLabels(in: s.store, settings: on)
            let contents = try await s.store.results(ContentAnalysis.self, kind: "content")
            let facts = try await s.pipeline.currentFacts().map { f -> AssetFacts in
                var f = f
                f.tripID = AlbumistID("trip")
                return f
            }
            var status = DerivedLibraryStatus.derive(facts: facts, snapshot: nil, settings: on, overrides: OverrideSet(),
                                                     contents: contents, labelsMissing: labels.missing, labelsRetrying: labels.retrying,
                                                     managed: [], inventory: CollectionInventory(), scope: .all)
            // Every photo is in its trip's album, put there by Albumist.
            let analysed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
            let states = LibraryStatus.compute(facts: facts, snapshot: nil, settings: on, contentAnalyzed: analysed,
                                               organizedByAlbumist: [.trips: Set(s.photos)])
            status.progress = resolver.progress(states.values)
            return status
        }
        // What the overview shows after each refresh (`AppModel.assignDerived`): the count held,
        // or the ring's own.
        var hold: RecountState?
        var shown = OrganizationStatusResolver.Progress()
        var shownLabels: RecountState.LabelsWaiting?
        var seen: [Int] = []
        func assign(_ status: DerivedLibraryStatus, ended: AnalysisPipeline.Report?) {
            hold = RecountState.next(hold, shown: shown, shownLabels: shownLabels, derived: status, settings: on,
                                     newSuggestions: true, ended: ended)
            shown = status.progress
            shownLabels = RecountState.LabelsWaiting(status)
            seen.append(hold?.fully ?? status.progress.fully)
        }

        // Turned on: the photos without their labels stay sorted, nothing falls, nothing is held.
        let before = try await status()
        #expect(before.labelsMissing == 30 && before.labelsUntried == 30)
        #expect(before.progress.fully == 30 && before.progress.total == 30)
        assign(before, ended: first)
        #expect(hold == nil)

        // Paused part way through the labels.
        let control = AnalysisRunControl()
        let paused = try await s.pipeline.run(control: control, onProgress: { p in
            if p.stage == .content, p.completed >= 12 { control.pause() }
        })
        #expect(paused.pausedBecause == .userPaused)
        let halfway = try await status()
        #expect(halfway.labelsUntried > 0 && halfway.labelsUntried < 30)
        // Without the hold the ring would fall now: the dogs need a theme album.
        #expect(halfway.progress.fully < 30)
        assign(halfway, ended: paused)
        #expect(hold == RecountState(fully: 30, total: 30, labels: true))
        // Refreshed again while paused, and while the next run is busy: still held.
        assign(halfway, ended: paused)
        assign(halfway, ended: nil)
        #expect(hold == RecountState(fully: 30, total: 30, labels: true))

        // The rest; one photo cannot be read now: it waits for its retry and holds nothing.
        let broken = try #require(try await AnalysisPipeline.photosWaitingForLabels(in: s.store, settings: on).missing
            .sorted { $0.rawValue < $1.rawValue }.first)
        s.analyzer.unreadable.withLock { $0 = [broken] }
        let rest = try await s.pipeline.run()
        #expect(rest.isComplete)
        let after = try await status()
        #expect(after.labelsMissing == 1 && after.labelsUntried == 0)
        assign(after, ended: rest)
        #expect(hold == nil)
        // On screen: 30 while the labels came in, then the new count, for what "Themen" asks now.
        #expect(seen == [30, 30, 30, 30, after.progress.fully])
        #expect(after.progress.fully < 30 && after.progress.total == 30)
    }

    /// A photo the analyzer fails on last in a run has no attempt noted (no photo after it showed
    /// the analyzer working, so it is not counted against the photo): it stays not looked at for
    /// its labels, and it held the ring for good. The run went through with the labels asked for,
    /// so each photo was looked at once: the hold ends with it, and none begins again over that
    /// photo, also not while the next run is busy (the count does not fall).
    @Test func aPhotoTheAnalyzerFailedOnLastHoldsTheRingNoLonger() async throws {
        let s = try Self.setup(photos: 1, screenshots: 0, labels: false)
        let first = try await s.pipeline.run()
        #expect(first.isComplete && first.settingsUsed.labels == false)
        var on = Self.settings(labels: true)
        on.primaryAreas = [.trips, .imageCategories]
        await s.pipeline.update(settings: on)
        s.analyzer.failing.withLock { $0 = Set(s.photos) }
        let run = try await s.pipeline.run()
        #expect(run.isComplete && run.settingsUsed.labels == true && run.labelsAdded == 0)
        let labels = try await AnalysisPipeline.photosWaitingForLabels(in: s.store, settings: on)
        let contents = try await s.store.results(ContentAnalysis.self, kind: "content")
        let status = DerivedLibraryStatus.derive(facts: try await s.pipeline.currentFacts(), snapshot: nil, settings: on,
                                                 overrides: OverrideSet(), contents: contents, labelsMissing: labels.missing,
                                                 labelsRetrying: labels.retrying, managed: [], inventory: CollectionInventory(),
                                                 scope: .all)
        // No attempt noted: as far as the store knows, the photo was not looked at yet.
        #expect(status.labelsMissing == 1 && status.labelsUntried == 1)
        // A count shown before that is higher than the ring's own now.
        var higher = status.progress
        higher.fully += 1
        higher.total = max(higher.total, higher.fully)
        let held = RecountState(fully: higher.fully, total: higher.total, labels: true)
        // One photo was looked at since the count shown: a fall the labels can explain.
        func next(_ current: RecountState?, shown: OrganizationStatusResolver.Progress = higher,
                  ended: AnalysisPipeline.Report?) -> RecountState? {
            RecountState.next(current, shown: shown,
                              shownLabels: .init(untried: status.labelsUntried + 1, missing: status.labelsMissing + 1),
                              derived: status, settings: on,
                              newSuggestions: false, ended: ended)
        }
        // A run that did not ask for the labels (they were turned on after it) leaves it held.
        #expect(next(held, ended: first) == held)
        // This run asked for them: the hold ends, and none begins again over that photo.
        #expect(next(held, ended: run) == nil)
        #expect(next(nil, ended: run) == nil)
        // While the next run is busy, the count as it was: nothing held.
        #expect(next(nil, shown: status.progress, ended: nil) == nil)
    }

    /// The hold's rules (`RecountState.next`): "Analyse neu aufbauen" as before; the labels hold
    /// only where the ring counts "Themen" or "Dokumente", only for photos not looked at yet, and
    /// only once the count would fall.
    @Test func theRingsHoldRules() {
        var themen = Self.settings(labels: true)
        themen.primaryAreas = [.trips, .imageCategories]
        var notMain = Self.settings(labels: true, documents: true)
        notMain.primaryAreas = [.trips, .places]
        var documents = Self.settings(labels: true, documents: true)
        documents.primaryAreas = [.documents]
        var shown = OrganizationStatusResolver.Progress()
        shown.total = 200
        shown.fully = 120
        var waiting = DerivedLibraryStatus()
        waiting.labelsMissing = 50
        waiting.labelsUntried = 40
        waiting.progress.total = 190
        waiting.progress.fully = 110
        var retrying = waiting
        retrying.labelsUntried = 0
        var rising = waiting
        rising.progress.fully = 125
        let none = DerivedLibraryStatus()
        // Reports of runs that ended: through or paused, with the labels asked for or not.
        func report(complete: Bool, labels: Bool) -> AnalysisPipeline.Report {
            var report = AnalysisPipeline.Report()
            report.completedStages = complete ? AnalysisPipeline.Stage.allCases : [.inventory, .patterns]
            if !complete { report.pausedBecause = .userPaused }
            report.settingsUsed.labels = labels
            return report
        }
        let withoutLabels = report(complete: true, labels: false)
        let through = report(complete: true, labels: true)
        let paused = report(complete: false, labels: true)
        // 60 photos waited for their labels when 120 of 200 were shown: 20 were looked at since.
        func next(_ current: RecountState?, _ derived: DerivedLibraryStatus, _ settings: OrganizationSettings,
                  shown: OrganizationStatusResolver.Progress = shown, shownUntried: Int? = 60, shownMissing: Int = 50,
                  suggestions: Bool = false, ended: AnalysisPipeline.Report? = nil) -> RecountState? {
            RecountState.next(current, shown: shown,
                              shownLabels: shownUntried.map { RecountState.LabelsWaiting(untried: $0, missing: shownMissing) },
                              derived: derived, settings: settings,
                              newSuggestions: suggestions, ended: ended)
        }
        let labels = RecountState(fully: 120, total: 200, labels: true)
        // Begins when the count would fall, with the count on screen; not while it does not fall,
        // nor with nothing shown yet (the first refresh after a launch: the next one compares).
        #expect(next(nil, waiting, themen) == labels)
        #expect(next(nil, waiting, documents, ended: withoutLabels) == labels)
        #expect(next(nil, rising, themen) == nil)
        #expect(next(nil, waiting, themen, shown: .init()) == nil)
        // Only a fall the labels can explain (open point B): no more photos fell than were looked
        // at for their labels since the count shown. None looked at, or a larger fall (a sorted
        // photo left its album in Photos, the main areas changed): the new count is shown.
        #expect(next(nil, waiting, themen, shownUntried: 50) == labels)
        #expect(next(nil, waiting, themen, shownUntried: 45) == nil)
        #expect(next(nil, waiting, themen, shownUntried: 40) == nil)
        #expect(next(nil, waiting, themen, shownUntried: nil) == nil)
        // Photos waiting for their retry that got their labels now are looked at too, though
        // they were never "untried" (second review 3): 10 fewer without labels, 10 fell.
        #expect(next(nil, waiting, themen, shownUntried: 40, shownMissing: 60) == labels)
        #expect(next(nil, waiting, themen, shownUntried: 40, shownMissing: 55) == nil)
        // Not where the ring does not count the two areas, nor for photos waiting for a retry.
        #expect(next(nil, waiting, notMain) == nil)
        #expect(next(nil, retrying, themen) == nil)
        // Held until every photo was looked at once: new suggestions, a Pause, a count that rises
        // or a finished run that did not ask for the labels (turned on after it) do not end it.
        #expect(next(labels, waiting, themen, suggestions: true, ended: withoutLabels) == labels)
        #expect(next(labels, waiting, themen, ended: paused) == labels)
        #expect(next(labels, rising, themen) == labels)
        #expect(next(labels, retrying, themen, ended: withoutLabels) == nil)
        #expect(next(labels, waiting, notMain) == nil)
        // A run that went through with the labels asked for looked at each photo once: one it
        // could not settle (the analyzer failed on it last) holds nothing, and no hold begins.
        #expect(next(labels, waiting, themen, ended: through) == nil)
        #expect(next(nil, waiting, themen, ended: through) == nil)
        // "Analyse neu aufbauen": until the first new suggestions or the end of the analysis
        // (`ended` is nil during the rebuild's own refresh: the run before it is no end).
        let rebuild = RecountState(fully: 300, total: 400)
        #expect(!rebuild.isForLabels)
        #expect(next(rebuild, none, themen) == rebuild)
        #expect(next(rebuild, none, themen, ended: paused) == rebuild)
        #expect(next(rebuild, none, themen, suggestions: true) == nil)
        #expect(next(rebuild, none, themen, ended: through) == nil)
        // Labels still to come then: the same count, held on for them.
        #expect(next(rebuild, waiting, themen, ended: withoutLabels) == RecountState(fully: 300, total: 400, labels: true))
        #expect(next(rebuild, waiting, themen, ended: through) == nil)
        // A hold stored by an earlier version reads as the rebuild's.
        let stored = try? JSONDecoder().decode(RecountState.self, from: Data(#"{"fully":3,"total":4}"#.utf8))
        #expect(stored == RecountState(fully: 3, total: 4))
    }

    /// "Dokumente" as a main area during a first analysis: a photo not analysed yet is not
    /// counted for it, so the total only grows as documents are found (the second review saw it
    /// shrink while the labels came in).
    @Test func theTotalWithDocumentsAsAMainAreaOnlyGrows() async throws {
        var settings = Self.settings(labels: true, documents: true)
        settings.primaryAreas = [.documents]
        let s = try Self.setup(labels: true)
        await s.pipeline.update(settings: settings)
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        func total() async throws -> Int {
            let contents = try await s.store.results(ContentAnalysis.self, kind: "content")
            let analysed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
            let states = LibraryStatus.compute(facts: try await s.pipeline.currentFacts(), snapshot: try await s.pipeline.latestProposals(),
                                               settings: settings, contentAnalyzed: analysed)
            return resolver.progress(states.values).total
        }
        let control = AnalysisRunControl()
        let reached = Locked(0)
        _ = try await s.pipeline.run(control: control, onProgress: { p in
            if p.stage == .content, p.completed >= 14 { reached.withLock { $0 = p.completed }; control.pause() }
        })
        let halfway = try await total()
        _ = try await s.pipeline.run()
        let done = try await total()
        #expect(reached.withLock { $0 } >= 14)
        #expect(done >= halfway)
        #expect(done > 0)
    }

    @Test func settingsChangesThatNeedARun() {
        let off = Self.settings(labels: false)
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: off, to: Self.settings(labels: true)))
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: off, to: Self.settings(labels: false, documents: true)))
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: Self.settings(labels: true), to: off))
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: off, to: off))
        // The text step newly on (nothing was read before).
        var noText = off
        noText.enabledAreas.subtract([.screenshots, .documents, .messenger])
        #expect(!AnalysisPipeline.readsText(noText))
        var screenshots = noText
        screenshots.enabledAreas.insert(.screenshots)
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: noText, to: screenshots))
        var messenger = noText
        messenger.enabledAreas.insert(.messenger)
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: noText, to: messenger))
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: screenshots, to: noText))
        // Online lookups allowed, hidden photos included.
        var offline = off
        offline.privacy.allowOnlineGeocoding = false
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: offline, to: off))
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: off, to: offline))
        var hidden = off
        hidden.privacy.includeHiddenAssets = !off.privacy.includeHiddenAssets
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: off, to: hidden) == hidden.privacy.includeHiddenAssets)
        // Finer places: towns wanted where only countries were.
        var countries = off
        countries.enabledAreas.remove(.trips)
        countries.places.levels = [.country]
        var towns = countries
        towns.places.levels = [.country, .locality]
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: countries, to: towns))
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: towns, to: countries))
    }

    // MARK: Store

    /// An edited image loses its labels with its result; a photo whose place or date changed
    /// keeps them.
    @Test func anEditedImageNeedsItsLabelsAgain() async throws {
        let store = try AlbumistStore(url: nil)
        var lib = LibraryBuilder()
        let a = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let b = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        _ = try await store.upsertAssets(lib.assets)
        try await store.saveResults([(a, ContentAnalysis(labels: [LabelScore("dog", 0.9)])), (b, ContentAnalysis(labels: [LabelScore("dog", 0.9)]))],
                                    kind: "content", version: 1, markingAnalyzed: [a, b], labelsVersion: 1)
        #expect(try await store.countNeedingAnalysis(version: 1, labelsVersion: 1) == 0)
        var edited = lib.assets
        edited[0].pixelWidth = 2000
        edited[1].location = Fixture.Places.rome
        _ = try await store.upsertAssets(edited)
        let versions = try await store.labelsVersions()
        #expect(versions[a] == 0)
        #expect(versions[b] == 1)
        #expect(try await store.assetsNeedingAnalysis(version: 1, labelsVersion: 1, limit: 10).map(\.id).sorted() == [a, b])
        // Labels not wanted: only the analysis marks count.
        #expect(try await store.countNeedingAnalysis(version: 1) == 2)
        try await store.resetAnalysis()
        #expect(try await store.labelsVersions().values.allSatisfy { $0 == 0 })
    }

    /// A database of an earlier version: a photo counts as having labels only if its stored
    /// result has some. One without (analysed while topics were off, or with nothing found)
    /// is classified once more; the migration cannot tell the two apart.
    @Test func migrationMarksOnlyPhotosWithLabels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("albumist.sqlite")

        // As the previous app version left it: analysed with topics on (labels), with topics
        // off (none), analysed without a result, a photo given up as unreadable, a new photo.
        var lib = LibraryBuilder()
        let withLabels = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let without = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        let noResult = lib.photo(at: Fixture.date("2026-03-03 10:00"), Fixture.Places.munichHome)
        let givenUp = lib.photo(at: Fixture.date("2026-03-04 10:00"), Fixture.Places.munichHome)
        let fresh = lib.photo(at: Fixture.date("2026-03-05 10:00"), Fixture.Places.munichHome)
        do {
            let store = try AlbumistStore(url: url)
            _ = try await store.upsertAssets(lib.assets)
            var failed = ContentAnalysis()
            failed.failedAttempts = ContentAnalysis.maxFailedAttempts
            try await store.saveResults([
                (withLabels, ContentAnalysis(labels: [LabelScore("dog", 0.9, isPrecise: true), LabelScore("grass", 0.3)], featurePrint: Embedding([1, 0]))),
                (without, ContentAnalysis(labels: [], featurePrint: Embedding([0, 1]), aestheticsScore: 0.5)),
                (givenUp, failed),
            ], kind: "content", version: AnalysisPipeline.contentVersion, markingAnalyzed: [withLabels, without, noResult, givenUp])
        }
        do {
            // Back to schema 4 (without version 6's column too).
            let old = try SQLiteDatabase(path: url.path)
            try old.execute("DROP INDEX idx_assets_out_of_view")
            try old.execute("ALTER TABLE assets DROP COLUMN out_of_view")
            try old.execute("DROP INDEX idx_assets_labels")
            try old.execute("ALTER TABLE assets DROP COLUMN labels_version")
            try old.setUserVersion(4)
        }
        let store = try AlbumistStore(url: url)
        #expect(await store.schemaVersion == 6)
        let versions = try await store.labelsVersions()
        #expect(versions == [withLabels: 1, without: 0, noResult: 0, givenUp: 0, fresh: 0])
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 1)
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion, labelsVersion: AnalysisPipeline.labelsVersion) == 4)
        // Reopening migrates nothing again.
        let reopened = try AlbumistStore(url: url)
        #expect(try await reopened.labelsVersions() == versions)

        // The next run with topics on: labels for the one without (its result kept), a full
        // look for the new photo, the one without a result and the one given up; nothing for
        // the one with labels.
        let analyzer = Analyzer()
        let pipeline = AnalysisPipeline(
            store: reopened, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(), settings: Self.settings(labels: true), calendar: Fixture.calendar, time: ManualTime().source
        )
        let report = try await pipeline.run()
        #expect(report.isComplete)
        let requests = analyzer.requests.withLock { Dictionary($0.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a }) }
        #expect(requests[withLabels] == nil)
        #expect(requests[without] == .labelsOnly)
        #expect(requests[noResult]?.featurePrint == true && requests[noResult]?.classify == true)
        #expect(requests[givenUp]?.featurePrint == true && requests[givenUp]?.classify == true)
        #expect(requests[fresh]?.featurePrint == true && requests[fresh]?.classify == true)
        // The one given up gets its look for the labels: analysed before, so no new photo
        // (second review of the labels fix, nit: it was counted as one). The workload counted it
        // with the labels too.
        #expect(report.labelsAdded == 2)
        #expect(report.newPhotosAnalyzed == 2)
        let kept = try #require(try await reopened.result(ContentAnalysis.self, kind: "content", asset: without))
        #expect(kept.featurePrint == Embedding([0, 1]) && kept.aestheticsScore == 0.5 && !kept.labels.isEmpty)
        #expect(try await reopened.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
    }
}

/// The app side of "Themen" or "Dokumente" turned on later (review of the labels fix): a change
/// of the settings starts the run it needs, or one more after the run in progress, and never
/// undoes a Pause; the analysis card and the overview call the labels a run gives what they
/// are, not new photos (M2).
@Suite("Labels turned on later: the run after the change, and its words")
struct LabelsLaterFollowUpTests {
    typealias T = LabelsLaterTests

    /// The workloads and the image step's counts of one run.
    final class Reports: Sendable {
        let workloads = Locked<[AnalysisWorkload]>([])
        let content = Locked<[(completed: Int, total: Int)]>([])
        var onProgress: @Sendable (AnalysisPipeline.Progress) -> Void {
            { p in
                if let w = p.workload { self.workloads.withLock { $0.append(w) } }
                if p.stage == .content { self.content.withLock { $0.append((p.completed, p.total)) } }
            }
        }
        var workload: AnalysisWorkload? { workloads.withLock { $0.last } }
    }

    static func pipeline(_ lib: LibraryBuilder, labels: Bool) throws -> (AnalysisPipeline, InMemoryLibraryReader, AlbumistStore) {
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: T.Analyzer(), geocoder: FakeGeocoder(), map: T.map, conditions: FakeConditions(),
            settings: T.settings(labels: labels), calendar: Fixture.calendar, time: ManualTime().source, batchSize: 50)
        return (pipeline, reader, store)
    }

    // MARK: The run after a change of the settings

    @Test func aSettingsChangeStartsTheRunItNeeds() {
        let off = T.settings(labels: false), on = T.settings(labels: true)
        func next(_ old: OrganizationSettings, _ new: OrganizationSettings, running: Bool = false, paused: Bool = false,
                  mayStart: Bool = true) -> AnalysisPipeline.RunAfterSettingsChange {
            AnalysisPipeline.runAfterSettingsChange(from: old, to: new, running: running, pausedByUser: paused, mayStart: mayStart)
        }
        // Nothing new for photos read already: no run, whatever the state.
        var renamed = on
        renamed.rootFolderTitle = "Albumist"
        for running in [false, true] {
            #expect(next(on, off, running: running) == .noRun)
            #expect(next(off, off, running: running) == .noRun)
            #expect(next(on, renamed, running: running) == .noRun)
        }
        // "Themen" on: a run now, or one more after the run in progress (it decided at its start
        // whether it gives labels).
        #expect(next(off, on) == .now)
        #expect(next(off, on, running: true) == .afterCurrentRun)
        // A run that is busy gets one more after it also while none may start right now: the
        // catch-up after the run checks again.
        #expect(next(off, on, running: true, mayStart: false) == .afterCurrentRun)
        // Paused by the user, also while the run finishes after Pause: nothing starts by itself.
        #expect(next(off, on, paused: true) == .whenResumed)
        #expect(next(off, on, running: true, paused: true) == .whenResumed)
        // No run may start now (introduction, no photo access, a plan, a rebuild): one follows anyway.
        #expect(next(off, on, mayStart: false) == .noRun)
        // Every change `settingsChangeNeedsRun` names, the same way.
        var withHidden = off, withoutHidden = off
        withHidden.privacy.includeHiddenAssets = true
        withoutHidden.privacy.includeHiddenAssets = false
        #expect(next(withoutHidden, withHidden) == .now)
        #expect(next(withHidden, withoutHidden) == .noRun)
        #expect(next(withoutHidden, withHidden, running: true) == .afterCurrentRun)
    }

    /// The pipeline says which settings the runs used until the change: every edit in the
    /// settings saves (each letter of the folder name), and only a real change needs a run.
    @Test func updateReturnsTheSettingsItReplaces() async throws {
        let s = try T.setup(photos: 3, screenshots: 0, labels: false)
        let on = T.settings(labels: true)
        let first = await s.pipeline.update(settings: on)
        #expect(first == T.settings(labels: false))
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: first, to: on))
        let again = await s.pipeline.update(settings: on)
        #expect(again == on)
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: again, to: on))
        #expect(await s.pipeline.settings == on)
    }

    /// "Themen" turned on while a run is busy: that run decided before its image step that it
    /// gives no labels, so the change needs one more run after it, and that one gives them.
    @Test func turnedOnDuringARunTheRunAfterItGivesTheLabels() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let on = T.settings(labels: true)
        final class Change: Sendable { let task = Locked<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let pipeline = s.pipeline
        let report = try await pipeline.run(onProgress: { p in
            guard p.stage == .content else { return }
            change.task.withLock { task in
                if task == nil { task = Task { await pipeline.update(settings: on) } }
            }
        })
        #expect(report.isComplete)
        #expect(report.labelsAdded == 0)
        #expect(s.analyzer.classifyingRequests == 0)
        let task = try #require(change.task.withLock { $0 })
        let previous = await task.value
        #expect(previous == T.settings(labels: false))
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == 0 })
        // Told while the run was busy: one more run after it.
        #expect(AnalysisPipeline.runAfterSettingsChange(from: previous, to: on, running: true, pausedByUser: false, mayStart: true)
            == .afterCurrentRun)
        let after = try await pipeline.run()
        #expect(after.isComplete)
        #expect(after.labelsAdded == 12)
        #expect(after.newPhotosAnalyzed == 0)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        #expect(try await T.dogSearch(pipeline).isEmpty == false)
    }

    // MARK: Labels said apart from new photos

    @Test func storeCountsThePhotosThatOnlyNeedTheirLabels() async throws {
        let store = try AlbumistStore(url: nil)
        var lib = LibraryBuilder()
        let a = lib.photo(at: Fixture.date("2025-03-01 10:00"), Fixture.Places.munichHome)
        let b = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let c = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        _ = lib.photo(at: Fixture.date("2026-03-03 10:00"), Fixture.Places.munichHome)
        _ = try await store.upsertAssets(lib.assets)
        // a and b analysed without labels, c with them; the fourth is new.
        try await store.saveResults([(a, ContentAnalysis()), (b, ContentAnalysis())], kind: "content", version: 1, markingAnalyzed: [a, b])
        try await store.saveResults([(c, ContentAnalysis(labels: [LabelScore("dog", 0.9)]))], kind: "content", version: 1,
                                    markingAnalyzed: [c], labelsVersion: 1)
        #expect(try await store.countNeedingLabelsOnly(version: 1, labelsVersion: 1) == 2)
        #expect(try await store.countNeedingAnalysis(version: 1, labelsVersion: 1) == 3)
        let year = Fixture.date("2026-01-01 00:00")..<Fixture.date("2027-01-01 00:00")
        #expect(try await store.countNeedingLabelsOnly(version: 1, labelsVersion: 1, within: year) == 1)
        // A newer analysis version: they need a full look, not their labels only.
        #expect(try await store.countNeedingLabelsOnly(version: 2, labelsVersion: 1) == 0)
    }

    /// The workload says the photos that get only their labels apart (they are in `contentLeft`
    /// too), and the report counts only the others as new photos.
    @Test func workloadAndReportSayTheLabelsApartFromNewPhotos() async throws {
        var lib = LibraryBuilder()
        for i in 0..<20 { _ = lib.photo(at: Fixture.date("2026-03-01 10:00").addingTimeInterval(Double(i) * 7_200), Fixture.Places.munichHome) }
        let (pipeline, reader, _) = try Self.pipeline(lib, labels: false)
        let first = Reports()
        let one = try await pipeline.run(onProgress: first.onProgress)
        #expect(one.newPhotosAnalyzed == 20 && one.labelsAdded == 0)
        #expect(first.workload?.labelsLeft == 0)

        // Three new photos, and "Themen" on.
        for i in 0..<3 { _ = lib.photo(at: Fixture.date("2026-04-01 10:00").addingTimeInterval(Double(i) * 7_200), Fixture.Places.munichHome) }
        await reader.set(assets: lib.assets)
        await pipeline.update(settings: T.settings(labels: true))
        let second = Reports()
        let two = try await pipeline.run(onProgress: second.onProgress)
        let workload = try #require(second.workload)
        #expect(workload.labelsLeft == 20)
        #expect(workload.contentLeft == 23)
        #expect(two.contentAnalyzed == 23)
        #expect(two.labelsAdded == 20)
        #expect(two.newPhotosAnalyzed == 3)

        // Nothing left: no labels left in the next workload either.
        let third = Reports()
        let three = try await pipeline.run(onProgress: third.onProgress)
        #expect(third.workload?.labelsLeft == 0 && third.workload?.contentLeft == 0)
        #expect(three.newPhotosAnalyzed == 0 && three.labelsAdded == 0)
    }

    // MARK: The phase label of a run that goes on (M2)

    /// The first analysis stopped at 40 % with "Themen" off, then turned on: the run that goes
    /// on has much more work, all of it labels for the photos analysed before. Its phase is
    /// "Fotos werden für die neuen Bereiche angesehen", no longer "Neue Fotos werden analysiert";
    /// number and widths are those of the phase as before.
    @Test func labelsForAreasTurnedOnAreNamedForTheNewAreas() {
        // 5,683 photos, stopped in the image step at 2,273: 3,410 photos and 200 screenshots left.
        let leftThen = 3_410 + 200
        func stopped() -> ResumedRun { ResumedRun(stage: 4, completed: 2_273, shown: 0.40, left: leftThen, photos: 5_683) }
        let turnedOn = AnalysisWorkload(photos: 5_683, located: 4_000, screenshots: 300, contentLeft: 3_410 + 2_273, textLeft: 200,
                                        labelsLeft: 2_273)
        var run = stopped()
        let runStarts = run.workload(turnedOn, remaining: 900)
        #expect(runStarts)
        #expect(run.newWork == .newAreas)
        // The same work not said apart (before the fix): "Neue Fotos werden analysiert".
        var unsaid = turnedOn
        unsaid.labelsLeft = 0
        var before = stopped()
        let beforeStarts = before.workload(unsaid, remaining: 900)
        #expect(beforeStarts)
        #expect(before.newWork == .newPhotos)
        #expect(run.ownStart == before.ownStart)
        #expect(run.shown(running: true, catchingUp: false, overall: 0.1, stopped: nil)
            == before.shown(running: true, catchingUp: false, overall: 0.1, stopped: nil))

        // A few new photos came in as well: still mostly labels.
        let few = AnalysisWorkload(photos: 5_783, located: 4_000, screenshots: 300, contentLeft: 3_410 + 100 + 2_273, textLeft: 200,
                                   labelsLeft: 2_273)
        var withFew = stopped()
        let withFewStarts = withFew.workload(few, remaining: 900)
        #expect(withFewStarts && withFew.newWork == .newAreas)
        // More new photos than labels: "Neue Fotos werden analysiert".
        let many = AnalysisWorkload(photos: 8_683, located: 6_000, screenshots: 300, contentLeft: 3_410 + 3_000 + 2_273, textLeft: 200,
                                    labelsLeft: 2_273)
        var withMany = stopped()
        let withManyStarts = withMany.workload(many, remaining: 1_200)
        #expect(withManyStarts && withMany.newWork == .newPhotos)
        // An update of the analysis is named first, as before.
        var updated = ResumedRun(stage: 4, completed: 2_273, shown: 0.40, left: leftThen, photos: 5_683, updated: true)
        let updatedStarts = updated.workload(turnedOn, remaining: 900)
        #expect(updatedStarts && updated.newWork == .afterUpdate)
        // Stopped at 20 %: not much more work, no phase and no label (the value goes on from the floor).
        var early = ResumedRun(stage: 4, completed: 1_137, shown: 0.20, left: 4_546 + 200, photos: 5_683)
        let early20 = AnalysisWorkload(photos: 5_683, located: 4_000, screenshots: 300, contentLeft: 4_546 + 1_137, textLeft: 200,
                                       labelsLeft: 1_137)
        let earlyStarts = early.workload(early20, remaining: 900)
        #expect(!earlyStarts && early.newWork == nil)
    }

    /// A run that already showed "Neue Fotos werden analysiert" and stopped near the end:
    /// "Themen" on gives it labels it cannot move through. Its next phase is named for the new
    /// areas, not "Weitere neue Fotos werden analysiert" (M2); new photos after that phase are
    /// new photos again (a title shown is never shown again).
    @Test func aPhaseShownBeforeGoesOnUnderTheRightTitle() {
        let labels = AnalysisWorkload(photos: 50_800, located: 30_000, screenshots: 2_000, contentLeft: 1_600, textLeft: 0, labelsLeft: 1_600)
        var afterNewPhotos = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, newWork: .newPhotos)
        let afterNewPhotosStarts = afterNewPhotos.workload(labels, remaining: 300)
        #expect(afterNewPhotosStarts)
        #expect(afterNewPhotos.newWork == .newAreas)
        var afterMore = ResumedRun(stage: 5, completed: 1_000, shown: 0.98, left: 0, photos: 50_800, newWork: .moreNewPhotos)
        let afterMoreStarts = afterMore.workload(labels, remaining: 300)
        #expect(afterMoreStarts && afterMore.newWork == .newAreas)
        // Stopped near the end of a phase for the new areas with 1,200 labels left; 400 new
        // photos came in: the phase that starts is about them.
        let newPhotos = AnalysisWorkload(photos: 51_200, located: 30_000, screenshots: 2_000, contentLeft: 1_600, textLeft: 0, labelsLeft: 1_200)
        var afterAreas = ResumedRun(stage: 4, completed: 49_000, shown: 0.98, left: 1_200, photos: 50_800, newWork: .newAreas)
        let afterAreasStarts = afterAreas.workload(newPhotos, remaining: 300)
        #expect(afterAreasStarts)
        #expect(afterAreas.newWork == .newPhotos)
        // With room to move nothing starts again, whatever the work (as for every label).
        var roomy = ResumedRun(stage: 4, completed: 20_000, shown: 0.60, left: 1_200, photos: 50_800, newWork: .newAreas)
        let roomyStarts = roomy.workload(newPhotos, remaining: 300)
        #expect(!roomyStarts && roomy.newWork == .newAreas)
    }

    /// The label only names the work: with the labels said apart or not, a phase starts in the
    /// same runs with the same number, labels only ever change the title, and a title shown is
    /// never the title of the next phase.
    @Test func theLabelChangesNeitherThePhaseNorItsNumber() {
        let shownLabels: [ResumedRun.NewWork?] = [nil, .newPhotos, .moreNewPhotos, .afterUpdate, .afterUpdateAgain, .newAreas]
        var cases = 0
        for shown in [0.40, 0.97] {
            for leftThen in [0, 900, 3_600] {
                for content in [500, 1_600, 6_000] {
                    for labels in [0, 300, 1_600, 4_000] where labels <= content {
                        for newWork in shownLabels {
                            for updated in [false, true] {
                                for remaining in [nil, 120.0, 3_000.0] as [Double?] {
                                    let w = AnalysisWorkload(photos: 50_000, located: 30_000, screenshots: 2_000, contentLeft: content,
                                                             textLeft: 200, labelsLeft: labels)
                                    var plain = w
                                    plain.labelsLeft = 0
                                    var with = ResumedRun(stage: 4, completed: 100, shown: shown, left: leftThen, photos: 50_000,
                                                          updated: updated, newWork: newWork)
                                    var without = with
                                    let a = with.workload(w, remaining: remaining)
                                    let b = without.workload(plain, remaining: remaining)
                                    let what = "shown \(shown) left \(leftThen) content \(content) labels \(labels) \(String(describing: newWork)) updated \(updated) remaining \(String(describing: remaining))"
                                    #expect(a == b, "\(what)")
                                    #expect(with.ownStart == without.ownStart, "\(what)")
                                    #expect(with.shown(running: true, catchingUp: false, overall: 0.3, stopped: nil)
                                        == without.shown(running: true, catchingUp: false, overall: 0.3, stopped: nil), "\(what)")
                                    if a, let newWork { #expect(with.newWork != newWork, "\(what)") }
                                    if labels == 0 { #expect(with.newWork == without.newWork, "\(what)") }
                                    if with.newWork == .newAreas, with.newWork != newWork { #expect(labels > 0 && !updated, "\(what)") }
                                    cases += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(cases > 1_000)
    }

    /// M2 end to end: the first analysis paused at about 40 % with "Themen" off, then turned on.
    /// The workload of the run that goes on, as the pipeline says it, names the phase for the
    /// new areas.
    @Test func firstAnalysisPausedThenThemenOnIsNamedForTheNewAreas() async throws {
        var lib = LibraryBuilder()
        for i in 0..<1_500 {
            _ = lib.photo(at: Fixture.date("2024-01-01 10:00").addingTimeInterval(Double(i) * 3_600), Fixture.Places.munichHome)
        }
        let (pipeline, _, store) = try Self.pipeline(lib, labels: false)
        let control = AnalysisRunControl()
        let first = Reports()
        let paused = try await pipeline.run(control: control, onProgress: { p in
            first.onProgress(p)
            if p.stage == .content, p.completed >= 600 { control.pause() }
        })
        #expect(paused.pausedBecause == .userPaused)
        let reached = try #require(first.content.withLock { $0.last })
        #expect(reached.completed >= 600 && reached.completed < 1_500)
        let workloadThen = try #require(first.workload)
        // What the marker keeps (`AnalysisMarker.left`).
        let leftThen = workloadThen.heavyLeft(at: .content, completed: reached.completed, total: reached.total)

        await pipeline.update(settings: T.settings(labels: true))
        let second = Reports()
        let rest = try await pipeline.run(onProgress: second.onProgress)
        #expect(rest.isComplete)
        let workload = try #require(second.workload)
        #expect(workload.labelsLeft == reached.completed)
        #expect(workload.contentLeft == 1_500)
        #expect(rest.labelsAdded == reached.completed)
        #expect(rest.newPhotosAnalyzed == 1_500 - reached.completed)
        var run = ResumedRun(stage: AnalysisPipeline.Stage.content.number, completed: reached.completed, shown: 0.40,
                             left: leftThen, photos: 1_500)
        let runStarts = run.workload(workload)
        #expect(runStarts)
        #expect(run.newWork == .newAreas)
        #expect(try await store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
    }
}
