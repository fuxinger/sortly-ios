import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Reliability of the analysis on real devices (review after the first iPhone test, 15.11.):
/// runs that overlap or lose their Pause, photos given up after a few quick catch-up runs,
/// Vision failing in the background, and a throttled geocoder holding step 3 for hours.
@Suite("Analysis reliability")
struct AnalysisReliabilityTests {
    static let map: OfflineWorldMap = PipelineTests.map

    struct Failure: Error {}

    /// Analyzer whose behaviour the test scripts per photo; it suspends on every call, so two
    /// runs on the same pipeline would interleave if nothing kept them apart.
    final class ScriptedAnalyzer: ContentAnalyzing, @unchecked Sendable {
        enum Answer { case labels, unreadable, analyzerError }
        let contentAnswer = Locked<@Sendable (AssetSnapshot) -> Answer>({ _ in .labels })
        let textAnswer = Locked<@Sendable (AssetSnapshot) -> Answer>({ _ in .labels })
        let contentCalls = Locked<[AssetID]>([])
        let textCalls = Locked<[AssetID]>([])

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            contentCalls.withLock { $0.append(asset.id) }
            await Task.yield()
            switch contentAnswer.withLock({ $0 })(asset) {
            case .labels: return ContentAnalysis(labels: [LabelScore("food", 0.7)], source: .localPreview)
            case .unreadable: throw AnalysisError.unreadable
            case .analyzerError: throw Failure()
            }
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            textCalls.withLock { $0.append(asset.id) }
            await Task.yield()
            switch textAnswer.withLock({ $0 })(asset) {
            case .labels: return TextAnalysis(text: "Ihre Bestellung Lieferung", source: .original)
            case .unreadable: throw AnalysisError.unreadable
            case .analyzerError: throw Failure()
            }
        }
    }

    final class Clock: @unchecked Sendable {
        let value = Locked(Fixture.date("2026-07-01 12:00"))
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    struct Setup {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var analyzer: ScriptedAnalyzer
        var clock: Clock
        var time: ManualTime
        var pipeline: AnalysisPipeline
        var photos: [AssetID]
        var screenshots: [AssetID]
    }

    func setup(photos: Int = 12, screenshots: Int = 0, geocoder: (any ReverseGeocoding)? = FakeGeocoder(),
               foregroundOnlineBudget: Int? = nil, batchSize: Int = 5) throws -> Setup {
        var lib = LibraryBuilder()
        var ids: [AssetID] = []
        for day in 0..<photos {
            ids.append(lib.photo(at: Fixture.date("2026-06-01 12:00").addingTimeInterval(Double(day) * 86_400), Fixture.Places.munichHome))
        }
        var shots: [AssetID] = []
        for day in 0..<screenshots {
            shots.append(lib.photo(at: Fixture.date("2026-05-01 20:00").addingTimeInterval(Double(day) * 86_400), nil, subtypes: .screenshot))
        }
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let analyzer = ScriptedAnalyzer()
        let clock = Clock()
        let time = ManualTime()
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: time.source,
            batchSize: batchSize, foregroundOnlineBudget: foregroundOnlineBudget, now: { clock.value.withLock { $0 } }
        )
        return Setup(store: store, reader: reader, analyzer: analyzer, clock: clock, time: time, pipeline: pipeline, photos: ids, screenshots: shots)
    }

    // MARK: One run at a time, and Pause reaches the right one

    @Test func twoRunsCalledTogetherDoNotAnalyseAPhotoTwice() async throws {
        let s = try setup(photos: 30)
        async let first = s.pipeline.run()
        async let second = s.pipeline.run()
        let reports = try await [first, second]
        #expect(reports.allSatisfy { $0.isComplete })
        let calls = s.analyzer.contentCalls.withLock { $0 }
        #expect(calls.count == s.photos.count)
        #expect(Set(calls).count == calls.count)
        #expect(reports.map(\.contentAnalyzed).reduce(0, +) == s.photos.count)
    }

    @Test func pauseBeforeTheRunBeginsIsNotLost() async throws {
        let s = try setup()
        let control = AnalysisRunControl()
        // Tapped while the app was still handing the run over (it used to be cleared at the start).
        control.pause()
        let report = try await s.pipeline.run(control: control)
        #expect(report.pausedBecause == .userPaused)
        #expect(s.analyzer.contentCalls.withLock { $0 }.isEmpty)
    }

    @Test func pauseAfterARunEndedDoesNotStopTheNext() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        // A Pause that arrives late (the run had just finished) must not end "Neu prüfen".
        await s.pipeline.pause()
        await s.reader.set(assets: (await s.reader.assets) + [newPhoto(id: "late")])
        let next = try await s.pipeline.run()
        #expect(next.isComplete)
        #expect(next.contentAnalyzed == 1)
    }

    @Test func controlPausesTheRunInProgress() async throws {
        let s = try setup(photos: 30)
        let control = AnalysisRunControl()
        s.analyzer.contentAnswer.withLock { answer in
            answer = { asset in
                // The user taps Pause while the fifth photo is looked at.
                if asset.id == AssetID("asset-000026") { control.pause() }
                return .labels
            }
        }
        let report = try await s.pipeline.run(control: control)
        #expect(report.pausedBecause == .userPaused)
        #expect(report.contentAnalyzed == 5)
        // The next run goes on and leaves no photo out.
        let rest = try await s.pipeline.run()
        #expect(rest.isComplete)
        #expect(rest.contentAnalyzed == 25)
    }

    // MARK: Photos that cannot be read

    @Test func quickCatchUpRunsDoNotGiveUpAPhoto() async throws {
        let s = try setup()
        let broken = s.photos[4]
        s.analyzer.contentAnswer.withLock { answer in answer = { $0.id == broken ? .unreadable : .labels } }
        // While iCloud syncs, every change in Photos starts a run a few seconds later.
        for _ in 0..<5 {
            _ = try await s.pipeline.run()
            s.clock.advance(10)
        }
        let record = try #require(try await s.store.result(ContentAnalysis.self, kind: "content", asset: broken))
        #expect(record.failedAttempts == 1)
        #expect(s.analyzer.contentCalls.withLock { $0 }.filter { $0 == broken }.count == 1)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 1)

        // An hour later its preview has arrived: read like any other photo.
        s.analyzer.contentAnswer.withLock { answer in answer = { _ in .labels } }
        s.clock.advance(ContentAnalysis.retrySpacing)
        let later = try await s.pipeline.run()
        #expect(later.contentAnalyzed == 1)
        #expect(try await s.store.result(ContentAnalysis.self, kind: "content", asset: broken)?.failedAttempts == nil)
    }

    @Test func failingAnalyzerEndsTheRunWithoutMarkingPhotos() async throws {
        let s = try setup(photos: 20)
        // Vision fails for every photo (e.g. no graphics hardware in the background).
        s.analyzer.contentAnswer.withLock { answer in answer = { _ in .analyzerError } }
        let report = try await s.pipeline.run()
        #expect(report.pausedBecause == .timeBudget)
        #expect(report.analyzerUnavailable)
        #expect(!report.isComplete)
        // Photos already in other lanes finish, nothing more starts.
        #expect(s.analyzer.contentCalls.withLock { $0 }.count < AnalysisPipeline.analyzerFailureLimit + 4)
        // Nothing was counted against the photos.
        #expect(try await s.store.results(ContentAnalysis.self, kind: "content").isEmpty)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == s.photos.count)

        // Back in the app, Vision works again: every photo is read, none is "unreadable".
        s.analyzer.contentAnswer.withLock { answer in answer = { _ in .labels } }
        let next = try await s.pipeline.run()
        #expect(next.isComplete)
        #expect(next.contentAnalyzed == s.photos.count)
        let records = try await s.store.results(ContentAnalysis.self, kind: "content")
        #expect(records.values.allSatisfy { $0.failedAttempts == nil })
    }

    @Test func analyzerErrorOnOnePhotoCountsAgainstThatPhoto() async throws {
        let s = try setup()
        let odd = s.photos[6]
        s.analyzer.contentAnswer.withLock { answer in answer = { $0.id == odd ? .analyzerError : .labels } }
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(!report.analyzerUnavailable)
        #expect(report.contentAnalyzed == s.photos.count - 1)
        // The photos after it worked, so it was this photo: one try counted, spaced out.
        let record = try #require(try await s.store.result(ContentAnalysis.self, kind: "content", asset: odd))
        #expect(record.failedAttempts == 1)
        #expect(record.lastAttempt == s.clock.value.withLock { $0 })
    }

    @Test func storedLabelsAreNotReadAgain() async throws {
        let s = try setup()
        // The app was ended after the first photo's labels were saved, before it was marked.
        _ = try await s.store.upsertAssets(await s.reader.assets)
        try await s.store.saveResult(ContentAnalysis(labels: [LabelScore("dog", 0.9)]), kind: "content",
                                     asset: s.photos[0], version: AnalysisPipeline.contentVersion)
        let first = try await s.pipeline.run()
        #expect(first.isComplete)
        #expect(!s.analyzer.contentCalls.withLock { $0 }.contains(s.photos[0]))
        #expect(s.analyzer.contentCalls.withLock { $0 }.count == s.photos.count - 1)
        #expect(try await s.store.result(ContentAnalysis.self, kind: "content", asset: s.photos[0])?.labels.first?.identifier == "dog")

        // Only the place of one photo changed (no edit of the image): its labels stay valid.
        var assets = await s.reader.assets
        assets[3].location = Fixture.Places.tegernsee
        await s.reader.set(assets: assets)
        let reads = s.analyzer.contentCalls.withLock { $0 }.count
        let second = try await s.pipeline.run()
        #expect(second.isComplete)
        #expect(second.newOrChanged == 1)
        #expect(s.analyzer.contentCalls.withLock { $0 }.count == reads)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
    }

    // MARK: Text

    @Test func failingTextRecognitionKeepsItsRetries() async throws {
        let s = try setup(photos: 0, screenshots: 12)
        s.analyzer.textAnswer.withLock { answer in answer = { _ in .analyzerError } }
        let report = try await s.pipeline.run()
        #expect(report.analyzerUnavailable)
        #expect(report.pausedBecause == .timeBudget)
        #expect(s.analyzer.textCalls.withLock { $0 }.count < AnalysisPipeline.analyzerFailureLimit + 2)
        // No try was used up: the texts are read at the next run, not an hour later.
        #expect(try await s.store.results(TextResult.self, kind: "text").isEmpty)
        s.analyzer.textAnswer.withLock { answer in answer = { _ in .labels } }
        let next = try await s.pipeline.run()
        #expect(next.isComplete)
        #expect(next.textRecognized == s.screenshots.count)
    }

    // MARK: A throttled geocoder does not hold the run

    final class RefusingGeocoder: ReverseGeocoding, @unchecked Sendable {
        let calls = Locked(0)
        let retryAfter: Double?
        init(retryAfter: Double? = nil) { self.retryAfter = retryAfter }
        func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
            calls.withLock { $0 += 1 }
            throw GeocodingError.rateLimited(retryAfter: retryAfter)
        }
    }

    func requests(_ places: [GeoCoordinate]) -> [PlaceResolutionService.Request] {
        places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
    }

    static let fivePlaces = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]

    @Test func refusedLookupsStopAfterOneCellAlsoWithoutALimit() async throws {
        let time = ManualTime()
        let geocoder = RefusingGeocoder()
        let service = PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german), time: time.source
        )
        let outcome = try await service.resolve(requests(Self.fivePlaces), refining: true) { _ in }
        // Four tries for the first cell (the overnight run may wait), not four for every cell,
        // and no wait after the last one.
        #expect(geocoder.calls.withLock { $0 } == 4)
        #expect(time.now.withLock { $0 } == .seconds(30 + 60 + 120))
        #expect(outcome.stoppedBecauseThrottled)
    }

    @Test func pauseInterruptsAWaitForTheGeocoder() async throws {
        let time = ManualTime()
        let geocoder = RefusingGeocoder(retryAfter: 600)
        let service = PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german), time: time.source
        )
        let checks = Locked(0)
        // The user taps Pause a few seconds into a ten-minute wait.
        let outcome = try await service.resolve(requests(Self.fivePlaces), shouldStop: {
            checks.withLock { $0 += 1; return $0 > 3 }
        }) { _ in }
        #expect(geocoder.calls.withLock { $0 } == 1)
        #expect(time.now.withLock { $0 } < .seconds(10))
        #expect(outcome.pendingOnline.count == Self.fivePlaces.count)
    }

    @Test func runInTheAppGoesOnWhenTheGeocoderRefuses() async throws {
        let geocoder = RefusingGeocoder()
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(report.placesThrottled)
        #expect(report.contentAnalyzed == s.photos.count)
        // Device test 18.11. (build 36): not even the 30 s it waited before ("Apple antwortet
        // gleich" with the count standing still). Asked once, refused, no more asking.
        #expect(s.time.now.withLock { $0 } == .zero)
        #expect(geocoder.calls.withLock { $0 } == 1)
        #expect(report.placesPendingOnline > 0)
    }

    // MARK: A run in the app never waits for the geocoder (device test 18.11., build 36)

    /// Photos in `count` place cells of their own around Munich (one town lookup each).
    func gridPhotos(_ count: Int, prefix: String = "grid") -> [AssetSnapshot] {
        (0..<count).map { i in
            let coordinate = GeoCoordinate(latitude: 47.8 + Double(i / 10) * 0.07, longitude: 11.0 + Double(i % 10) * 0.1)
            return AssetSnapshot(id: AssetID("\(prefix)\(i)"), kind: .image,
                                 creationDate: Fixture.date("2026-03-01 10:00").addingTimeInterval(Double(i) * 3_600),
                                 location: coordinate, pixelWidth: 4032, pixelHeight: 3024)
        }
    }

    /// "Apple antwortet gleich" stood for 20–30 s with the count still: Albumist's own limit of
    /// 40 lookups a minute made a run with an online budget of 60 wait for the window. A run in
    /// the app asks only what fits without a wait; the rest stays pending, with its country.
    @Test func runInTheAppNeverWaitsForTheThrottle() async throws {
        let geocoder = FakeGeocoder()
        let s = try setup(photos: 0, geocoder: geocoder, foregroundOnlineBudget: 60)
        let grid = gridPhotos(100)
        await s.reader.set(assets: grid)
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(s.time.now.withLock { $0 } == .zero)
        #expect(report.onlineRequests == RequestThrottle.apple.maxRequests)
        #expect(geocoder.calls.count == RequestThrottle.apple.maxRequests)
        #expect(!report.placesThrottled)
        let places = try await s.store.places()
        let towns = grid.filter { places[$0.id]?.components.locality == "München" }
        #expect(towns.count == RequestThrottle.apple.maxRequests)
        // The rest waits for a later run: counted as pending, with the country from the map.
        #expect(report.placesPendingOnline == grid.count - towns.count)
        #expect(grid.allSatisfy { places[$0.id]?.components.isoCountryCode == "DE" })
    }

    /// The requests of the run before count for the minute: a run right after it (photos added,
    /// "Neu prüfen") asks only for what is left of the 40 and does not wait either.
    @Test func runRightAfterARunCountsItsRequests() async throws {
        let geocoder = FakeGeocoder()
        let s = try setup(photos: 0, geocoder: geocoder, foregroundOnlineBudget: 60)
        await s.reader.set(assets: gridPhotos(30))
        let first = try await s.pipeline.run()
        #expect(first.onlineRequests == 30)
        #expect(first.placesPendingOnline == 0)

        s.clock.advance(20)
        await s.reader.set(assets: gridPhotos(60))
        let second = try await s.pipeline.run()
        #expect(second.onlineRequests == RequestThrottle.apple.maxRequests - 30)
        #expect(second.placesPendingOnline == 20)
        #expect(s.time.now.withLock { $0 } == .zero)
    }

    /// A run that stopped asking because the throttle had no free slot starts the hour, like a
    /// used-up budget: a run within the hour asks nothing (even once Apple's minute is over),
    /// a run after it asks again what fits (second review of the no-wait fix, finding SF1).
    @Test func aRunStoppedByTheThrottleStartsTheHour() async throws {
        let geocoder = FakeGeocoder()
        let s = try setup(photos: 0, geocoder: geocoder, foregroundOnlineBudget: 60)
        await s.reader.set(assets: gridPhotos(100))
        let first = try await s.pipeline.run()
        #expect(first.onlineRequests == RequestThrottle.apple.maxRequests)
        #expect(first.placesPendingOnline == 60)

        // Apple's minute is over (the throttle has free slots again); the hour is not.
        s.time.now.withLock { $0 += .seconds(120) }
        s.clock.advance(5 * 60)
        let second = try await s.pipeline.run()
        #expect(second.onlineRequests == 0)
        #expect(geocoder.calls.count == RequestThrottle.apple.maxRequests)
        #expect(second.placesPendingOnline == 60)

        s.time.now.withLock { $0 += .seconds(AnalysisPipeline.foregroundOnlineCooldown) }
        s.clock.advance(AnalysisPipeline.foregroundOnlineCooldown)
        let third = try await s.pipeline.run()
        #expect(third.onlineRequests == RequestThrottle.apple.maxRequests)
        #expect(third.placesPendingOnline == 20)
    }

    /// The overnight refinement may wait: it gets the towns the run in the app left.
    @Test func refinementStillWaitsForTheThrottle() async throws {
        let geocoder = FakeGeocoder()
        let s = try setup(photos: 0, geocoder: geocoder, foregroundOnlineBudget: 60)
        let grid = gridPhotos(100)
        await s.reader.set(assets: grid)
        let first = try await s.pipeline.run()
        #expect(first.placesPendingOnline > 0)
        #expect(s.time.now.withLock { $0 } == .zero)

        let refined = try await s.pipeline.run(mode: .refinement)
        #expect(refined.placesPendingOnline == 0)
        #expect(s.time.now.withLock { $0 } >= .seconds(60))
        let places = try await s.store.places()
        #expect(grid.allSatisfy { places[$0.id]?.components.locality == "München" })
    }

    /// After a refusal the refinement waits and asks again; a run in the app does not (above).
    @Test func refinementStillWaitsAfterARefusal() async throws {
        let geocoder = FakeGeocoder(failures: [.rateLimited(retryAfter: 20)])
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        let report = try await s.pipeline.run(mode: .refinement)
        #expect(report.placesPendingOnline == 0)
        #expect(!report.placesThrottled)
        #expect(s.time.now.withLock { $0 } >= .seconds(20))
        #expect(try await s.store.places()[s.photos[0]]?.components.locality == "München")
    }

    /// Device test 15.11.: "es dauert lange, bis die App nach Pause weiterläuft". Fortsetzen
    /// within the hour does not ask Apple for town names again; after the hour it does.
    @Test func goingOnAfterAPauseDoesNotWaitForTownNamesAgain() async throws {
        let geocoder = RefusingGeocoder()
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        let first = try await s.pipeline.run()
        #expect(first.onlineRequests > 0)
        #expect(first.placesPendingOnline > 0)
        let askedFirst = geocoder.calls.withLock { $0 }

        s.clock.value.withLock { $0 = $0.addingTimeInterval(5 * 60) }
        let second = try await s.pipeline.run()
        #expect(second.onlineRequests == 0)
        #expect(geocoder.calls.withLock { $0 } == askedFirst)
        #expect(second.placesPendingOnline > 0)

        s.clock.value.withLock { $0 = $0.addingTimeInterval(AnalysisPipeline.foregroundOnlineCooldown) }
        let third = try await s.pipeline.run()
        #expect(third.onlineRequests > 0)
    }

    /// UI run 43779950348: a first run that got all its towns must not hold back the towns of
    /// photos added minutes later (the demo library arrives in chunks, a device gets new trip
    /// photos): they were left with region names for an hour.
    @Test func photosAddedAfterACompleteLookupGetTheirTownsAtOnce() async throws {
        let geocoder = FakeGeocoder()
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        let first = try await s.pipeline.run()
        #expect(first.onlineRequests > 0)
        #expect(first.placesPendingOnline == 0)

        s.clock.value.withLock { $0 = $0.addingTimeInterval(5 * 60) }
        await s.reader.set(assets: (await s.reader.assets) + romePhotos(6))
        let second = try await s.pipeline.run()
        #expect(second.onlineRequests > 0)
        #expect(second.placesPendingOnline == 0)
        let places = try await s.store.places()
        #expect(places[AssetID("rome0")]?.components.locality == "Rom")
    }

    func romePhotos(_ count: Int) -> [AssetSnapshot] {
        (0..<count).map { i in
            AssetSnapshot(id: AssetID("rome\(i)"), kind: .image, creationDate: Fixture.date("2026-06-20 10:00").addingTimeInterval(Double(i) * 3_600),
                          location: Fixture.Places.rome, pixelWidth: 4032, pixelHeight: 3024)
        }
    }

    /// The device case the hour was made for: the run's lookup limit is used up with towns left.
    /// A run soon after (Fortsetzen, a restart) does not ask again; a run after the hour does.
    @Test func aUsedUpLookupLimitWaitsAnHour() async throws {
        let geocoder = FakeGeocoder()
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 1)
        await s.reader.set(assets: (await s.reader.assets) + romePhotos(6))
        let first = try await s.pipeline.run()
        #expect(first.onlineRequests == 1)
        #expect(first.placesPendingOnline > 0)

        s.clock.value.withLock { $0 = $0.addingTimeInterval(5 * 60) }
        let soon = try await s.pipeline.run()
        #expect(soon.onlineRequests == 0)

        s.clock.value.withLock { $0 = $0.addingTimeInterval(61 * 60) }
        let later = try await s.pipeline.run()
        #expect(later.onlineRequests == 1)
        #expect(later.placesPendingOnline == 0)
    }

    /// A single failed answer (not a refusal) does not hold back the next run for an hour.
    @Test func aOneOffLookupErrorDoesNotWaitAnHour() async throws {
        let geocoder = FakeGeocoder(failures: [.failed])
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        let first = try await s.pipeline.run()
        #expect(first.onlineRequests == 1)
        #expect(first.placesPendingOnline > 0)

        s.clock.value.withLock { $0 = $0.addingTimeInterval(5 * 60) }
        let second = try await s.pipeline.run()
        #expect(second.onlineRequests > 0)
        #expect(second.placesPendingOnline == 0)
        #expect(try await s.store.places()[s.photos[0]]?.components.locality == "München")
    }

    /// "Analyse neu aufbauen" within the hour: the place cache is gone, so the rebuild asks again.
    @Test func aRebuildAsksForTownNamesAgainAtOnce() async throws {
        let geocoder = RefusingGeocoder()
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        _ = try await s.pipeline.run()
        try await s.store.resetAnalysis(includingDecisions: false)
        await s.pipeline.forgetRecentOnlineLookups()
        s.clock.value.withLock { $0 = $0.addingTimeInterval(5 * 60) }
        let rebuilt = try await s.pipeline.run()
        #expect(rebuilt.onlineRequests > 0)
    }

    func newPhoto(id: String) -> AssetSnapshot {
        AssetSnapshot(id: AssetID(id), kind: .image, creationDate: Fixture.date("2026-08-01 10:00"),
                      location: Fixture.Places.munichHome, pixelWidth: 4032, pixelHeight: 3024)
    }
}
