import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Photos that could never count as done, whatever the user does (review 18.11.2026, P1-03,
/// P1-08, P1-09): the ring or the analysis count stayed below "fertig" for good. Counted the way
/// `AppModel.refreshDerived` counts.
@Suite("Photos that could never count as done")
struct NeverDoneTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    static let today = Fixture.date("2026-11-18 06:00")
    static let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)

    struct World {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var pipeline: AnalysisPipeline
        var settings: OrganizationSettings

        func derived() async throws -> DerivedLibraryStatus {
            DerivedLibraryStatus.derive(
                facts: try await pipeline.currentFacts(), snapshot: try await pipeline.latestProposals(), settings: settings,
                overrides: OverrideSet(try await store.overrides()),
                contents: try await store.results(ContentAnalysis.self, kind: "content"),
                managed: [], inventory: try await store.loadInventory(), scope: .all, calendar: Fixture.calendar)
        }

        func places(_ d: DerivedLibraryStatus, _ ids: [AssetID]) -> [String] {
            ids.map { d.states[$0]?.areas[.places]?.rawValue ?? "-" }
        }
    }

    static func world(_ assets: [AssetSnapshot], analyzer: any ContentAnalyzing = FakeContentAnalyzer(),
                      geocoder: any ReverseGeocoding = FakeGeocoder(),
                      now: @escaping @Sendable () -> Date = { NeverDoneTests.today },
                      configure: (inout OrganizationSettings) -> Void = { _ in }) throws -> World {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        configure(&settings)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map, conditions: FakeConditions(),
            settings: settings, calendar: Fixture.calendar, time: ManualTime().source, now: now
        )
        return World(store: store, reader: reader, pipeline: pipeline, settings: settings)
    }

    // MARK: P1-03 photos dated in the future

    /// Everyday life in Munich and three photos from Paris, too few for an album of their own:
    /// such photos leave the ring ("kein eigenes Album"). Three more from Paris carry the date
    /// 2031 (a camera with its clock set wrong). They were in the library when the suggestions
    /// were made, so they count exactly like the others, not as "unsortiert" for good (the rule
    /// meant photos taken after the suggestions, and compared the capture date).
    @Test func photosDatedInTheFutureCountLikeTheOthers() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1)
        let normal = (0..<3).map { lib.photo(at: Fixture.date("2026-03-0\($0 + 1) 12:00"), Self.paris) }
        let future = (0..<3).map { lib.photo(at: Fixture.date("2031-08-0\($0 + 1) 12:00"), Self.paris) }
        let w = try Self.world(lib.assets)
        for _ in 0..<2 {
            #expect(try await w.pipeline.run().isComplete)
            let d = try await w.derived()
            #expect(w.places(d, future) == w.places(d, normal), "the same photos, only the date differs")
            #expect(d.progress.unorganized == 0, "\(d.progress.unorganized) photos unsorted for good")
            #expect(d.leftOut.noAlbum == 6)
        }
    }

    /// The rule itself stays: a photo taken after the suggestions were made counts as unsorted
    /// until the next analysis has made its suggestions, also when its date is later than the
    /// moment it is looked at; one dated later that the analysis saw counts like the others.
    @Test func aPhotoTakenAfterTheSuggestionsStillCountsAsUnsorted() throws {
        let made = Fixture.date("2026-11-01 12:00")
        var settings = OrganizationSettings()
        settings.primaryAreas = [.places]
        func facts(_ id: String, _ date: String) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: Fixture.date(date), location: Self.paris),
                       place: PlaceComponents(isoCountryCode: "FR", country: "Frankreich"), placeSource: .gpsReverseGeocoded)
        }
        let photos = [facts("seen", "2026-10-01 12:00"), facts("seen-2031", "2031-08-01 12:00"),
                      facts("new", "2026-11-02 12:00"), facts("new-2031", "2031-08-02 12:00")]
        var snapshot = ProposalSnapshot(generatedAt: made, scope: .all, proposals: [], matches: [:])
        snapshot.datedAfterwards = ["seen-2031"]
        let states = LibraryStatus.compute(facts: photos, snapshot: snapshot, settings: settings,
                                           contentAnalyzed: Set(photos.map(\.id)))
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        #expect(resolver.isOutsideMainAreas(try #require(states["seen"])))
        #expect(resolver.isOutsideMainAreas(try #require(states["seen-2031"])))
        #expect(states["new"]?.areas[.places] == .unorganized)
        #expect(states["new-2031"]?.areas[.places] == .unorganized)
    }

    // MARK: P1-08 photos that could not be read three times

    /// Reads chosen photos only after a number of failed tries (a photo kept only in iCloud,
    /// whose preview comes later).
    final class LateAnalyzer: ContentAnalyzing, @unchecked Sendable {
        let failuresLeft: Locked<[AssetID: Int]>
        let calls = Locked<[AssetID: Int]>([:])
        init(failures: [AssetID: Int]) { failuresLeft = Locked(failures) }
        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            calls.withLock { $0[asset.id, default: 0] += 1 }
            let fail = failuresLeft.withLock { left -> Bool in
                guard let n = left[asset.id], n > 0 else { return false }
                left[asset.id] = n - 1
                return true
            }
            if fail { throw AnalysisError.unreadable }
            return ContentAnalysis(labels: [], source: .localPreview)
        }
        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            TextAnalysis(text: "", source: .original)
        }
    }

    final class Clock: @unchecked Sendable {
        let value = Locked(Fixture.date("2026-07-01 12:00"))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    /// The overview says "N Fotos konnten noch nicht gelesen werden. Albumist versucht es später
    /// noch einmal." After three failed runs the photo was given up for good: never read again,
    /// and the count stayed at "29 von 30 analysiert" also once the photo could be read. A photo
    /// given up is now read again a week after its last try (one read, given up again at once
    /// when it still fails), never sooner.
    @Test func aPhotoGivenUpAsUnreadableIsTriedAgainAWeekLater() async throws {
        var lib = LibraryBuilder()
        let ids = lib.daily(from: "2026-05-01", to: "2026-05-30", at: Fixture.Places.munichHome, perDay: 1)
        let late = ids[7]
        let analyzer = LateAnalyzer(failures: [late: 4])
        let clock = Clock()
        let w = try Self.world(lib.assets, analyzer: analyzer, now: { clock.now })
        func reads() -> Int { analyzer.calls.withLock { $0[late] ?? 0 } }
        // Three runs an hour apart: three failed tries, given up.
        for _ in 0..<3 {
            #expect(try await w.pipeline.run().isComplete)
            clock.advance(ContentAnalysis.retrySpacing)
        }
        #expect(reads() == 3)
        var d = try await w.derived()
        #expect(d.analyzed == 29 && d.unreadable == 1)
        // Runs during the following days do not read it again.
        for _ in 0..<6 {
            clock.advance(86_400)
            #expect(try await w.pipeline.run().isComplete)
        }
        #expect(reads() == 3, "read again before a week had passed")
        // A week after the last try: one more read, which fails; given up again, the run is complete.
        clock.advance(86_400)
        #expect(try await w.pipeline.run().isComplete)
        #expect(reads() == 4)
        #expect(try await w.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        clock.advance(ContentAnalysis.retrySpacing)
        #expect(try await w.pipeline.run().isComplete)
        #expect(reads() == 4, "a photo given up again waits another week")
        // The week after, the photo can be read: all 30 analysed.
        clock.advance(7 * 86_400)
        #expect(try await w.pipeline.run().isComplete)
        #expect(reads() == 5)
        d = try await w.derived()
        #expect(d.analyzed == 30 && d.unreadable == 0, "\(d.analyzed) of \(d.photos) analysed, \(d.unreadable) unreadable")
        #expect(try await w.store.result(ContentAnalysis.self, kind: "content", asset: late)?.failedAttempts == nil)
    }

    /// The overview sums up a check with "Beim Prüfen N neue Fotos analysiert". A photo given
    /// up and read a week later, now readable, is no new photo: the run that reads it says
    /// nothing of new photos.
    @Test func aPhotoReadAgainIsNoNewPhoto() async throws {
        var lib = LibraryBuilder()
        let ids = lib.daily(from: "2026-05-01", to: "2026-05-30", at: Fixture.Places.munichHome, perDay: 1)
        let photo = ids[7]
        let analyzer = LateAnalyzer(failures: [photo: ContentAnalysis.maxFailedAttempts])
        let clock = Clock()
        let w = try Self.world(lib.assets, analyzer: analyzer, now: { clock.now })
        for _ in 0..<ContentAnalysis.maxFailedAttempts {
            #expect(try await w.pipeline.run().isComplete)
            clock.advance(ContentAnalysis.retrySpacing)
        }
        clock.advance(8 * 86_400)
        let report = try await w.pipeline.run()
        #expect(report.isComplete && report.contentAnalyzed == 1, "the photo was not read again")
        #expect(report.newPhotosAnalyzed == 0)
        #expect(report.labelsAdded == 0)
        // A photo that comes in later is new.
        let added = lib.photo(at: Fixture.date("2026-06-02 12:00"), Fixture.Places.munichHome)
        await w.reader.set(assets: lib.assets)
        clock.advance(3_600)
        let next = try await w.pipeline.run()
        #expect(next.contentAnalyzed == 1 && next.newPhotosAnalyzed == 1, "\(added) not counted as new")
    }

    /// Reads a photo that is not readable (`AnalysisError.unreadable`) a few times, and after
    /// that fails with an error of the analyzer itself (Vision), as on a device where Vision
    /// stops working for a photo it could not read before.
    final class FailingAnalyzer: ContentAnalyzing, @unchecked Sendable {
        struct VisionFailed: Error {}
        let unreadable: Set<AssetID>
        let unreadableReads: Int
        let calls = Locked<[AssetID: Int]>([:])
        init(unreadable: Set<AssetID>, unreadableReads: Int) {
            self.unreadable = unreadable
            self.unreadableReads = unreadableReads
        }
        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            let n = calls.withLock { calls -> Int in
                calls[asset.id, default: 0] += 1
                return calls[asset.id]!
            }
            guard unreadable.contains(asset.id) else { return ContentAnalysis(labels: [], source: .localPreview) }
            if n <= unreadableReads { throw AnalysisError.unreadable }
            throw VisionFailed()
        }
        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            TextAnalysis(text: "", source: .original)
        }
        func reads(_ id: AssetID) -> Int { calls.withLock { $0[id] ?? 0 } }
    }

    /// A photo given up and read again a week later fails this time with an error of the
    /// analyzer, not of the photo. It stayed open without a time of its last try and was read
    /// again in every run after. It is given up again at once: one read a week.
    @Test func aPhotoTriedAgainIsReadAtMostOnceAWeekWhateverTheError() async throws {
        var lib = LibraryBuilder()
        let ids = lib.daily(from: "2026-05-01", to: "2026-05-30", at: Fixture.Places.munichHome, perDay: 1)
        let photo = ids[7]
        let analyzer = FailingAnalyzer(unreadable: [photo], unreadableReads: ContentAnalysis.maxFailedAttempts)
        let clock = Clock()
        let w = try Self.world(lib.assets, analyzer: analyzer, now: { clock.now })
        for _ in 0..<ContentAnalysis.maxFailedAttempts {
            #expect(try await w.pipeline.run().isComplete)
            clock.advance(ContentAnalysis.retrySpacing)
        }
        #expect(analyzer.reads(photo) == ContentAnalysis.maxFailedAttempts)
        // Eight days later: four runs two hours apart read it once.
        clock.advance(8 * 86_400)
        for run in 1...4 {
            let report = try await w.pipeline.run()
            #expect(report.isComplete && !report.analyzerUnavailable, "run \(run)")
            clock.advance(2 * 3_600)
        }
        #expect(analyzer.reads(photo) == ContentAnalysis.maxFailedAttempts + 1, "read in every run")
        #expect(try await w.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        let d = try await w.derived()
        #expect(d.analyzed == 29 && d.unreadable == 1)
        // A week after that try: one more read.
        clock.advance(7 * 86_400)
        #expect(try await w.pipeline.run().isComplete)
        clock.advance(2 * 3_600)
        #expect(try await w.pipeline.run().isComplete)
        #expect(analyzer.reads(photo) == ContentAnalysis.maxFailedAttempts + 2)
    }

    /// Five photos given up, read again a week later, all failing with an error of the analyzer:
    /// five such errors in a row end the run as "Analyse nicht verfügbar", in every run after,
    /// and the analysis never got done. Photos given up before do not stop the run.
    @Test func photosTriedAgainNeverKeepTheAnalysisFromFinishing() async throws {
        var lib = LibraryBuilder()
        let ids = lib.daily(from: "2026-05-01", to: "2026-05-30", at: Fixture.Places.munichHome, perDay: 1)
        let photos = Set(ids[10..<15])
        let analyzer = FailingAnalyzer(unreadable: photos, unreadableReads: ContentAnalysis.maxFailedAttempts)
        let clock = Clock()
        let w = try Self.world(lib.assets, analyzer: analyzer, now: { clock.now })
        for _ in 0..<ContentAnalysis.maxFailedAttempts {
            #expect(try await w.pipeline.run().isComplete)
            clock.advance(ContentAnalysis.retrySpacing)
        }
        clock.advance(8 * 86_400)
        for run in 1...4 {
            let report = try await w.pipeline.run()
            #expect(report.isComplete, "run \(run) ended with \(String(describing: report.pausedBecause))")
            #expect(!report.analyzerUnavailable, "run \(run)")
            clock.advance(2 * 3_600)
        }
        #expect(photos.map(analyzer.reads).allSatisfy { $0 == ContentAnalysis.maxFailedAttempts + 1 })
        #expect(try await w.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
    }

    // MARK: P1-09 photos whose country cannot be found

    /// Apple's lookup on open sea: no country, no town.
    final class SeaGeocoder: ReverseGeocoding, @unchecked Sendable {
        let inner = FakeGeocoder()
        let sea: GeoCoordinate
        let calls = Locked(0)
        init(sea: GeoCoordinate) { self.sea = sea }
        func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
            calls.withLock { $0 += 1 }
            if GeoMath.distance(coordinate, sea) < 40_000 { return nil }
            return try await inner.reverseGeocode(coordinate)
        }
    }

    /// Everyday life in Munich, and three photos from a ferry in the middle of the Adriatic
    /// (60 km off the coast). The lookup answers "nothing here" and the answer is kept: the photos
    /// can never get a country. They count like photos without a location (not "offen" for good).
    @Test func photosTakenAtSeaAreNotOpenForGood() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1)
        let adriatic = GeoCoordinate(latitude: 43.0, longitude: 15.0)
        let sea = (0..<3).map { lib.photo(at: Fixture.date("2026-04-0\($0 + 1) 12:00"), adriatic, jitterMeters: 300) }
        #expect(Self.map.lookup(adriatic).country == nil)
        let geocoder = SeaGeocoder(sea: adriatic)
        let w = try Self.world(lib.assets, geocoder: geocoder)
        var asked: [Int] = []
        for run in 1...2 {
            #expect(try await w.pipeline.run().isComplete)
            let d = try await w.derived()
            #expect(w.places(d, sea) == Array(repeating: AreaStatus.analysisImpossible.rawValue, count: 3), "run \(run)")
            #expect(d.progress.pending == 0, "run \(run): \(d.progress.pending) photos open for good")
            #expect(d.progress.total == 0, "run \(run): the ring counts photos no suggestion can ever be made for")
            asked.append(geocoder.calls.withLock { $0 })
        }
        // The answer "nothing here" is kept: not asked again.
        #expect(asked[0] > 0 && asked[1] == asked[0], "\(asked)")
    }

    /// "Orte online genauer bestimmen" is off. Three photos from Konstanz, a few hundred metres
    /// from the Swiss border: the map on the device names no country there. Without the online
    /// lookup they can never get one: they count like photos without a location. Turned on, the
    /// next run finds their country.
    @Test func photosNearABorderWithoutTheOnlineLookupAreNotOpenForGood() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1)
        let konstanz = GeoCoordinate(latitude: 47.6588, longitude: 9.1750)
        let border = (0..<3).map { lib.photo(at: Fixture.date("2026-04-0\($0 + 1) 12:00"), konstanz, jitterMeters: 100) }
        #expect(!Self.map.lookup(konstanz).countryIsCertain)
        let w = try Self.world(lib.assets, configure: { $0.privacy.allowOnlineGeocoding = false })
        for run in 1...2 {
            #expect(try await w.pipeline.run().isComplete)
            let d = try await w.derived()
            #expect(w.places(d, border) == Array(repeating: AreaStatus.analysisImpossible.rawValue, count: 3), "run \(run)")
            #expect(d.progress.pending == 0, "run \(run): \(d.progress.pending) photos open for good")
        }
        // Turned on: the country is found, and they count as usual.
        var settings = w.settings
        settings.privacy.allowOnlineGeocoding = true
        await w.pipeline.update(settings: settings)
        #expect(try await w.pipeline.run().isComplete)
        let facts = Dictionary(uniqueKeysWithValues: try await w.pipeline.currentFacts().map { ($0.id, $0) })
        #expect(border.allSatisfy { facts[$0]?.gpsPlace?.isoCountryCode != nil })
        let on = World(store: w.store, reader: w.reader, pipeline: w.pipeline, settings: settings)
        let d = try await on.derived()
        #expect(!w.places(d, border).contains(AreaStatus.analysisImpossible.rawValue))
    }

    /// The overview says "N Orte werden später genauer bestimmt" from the run's count of places
    /// waiting for the online lookup. Photos that cannot get a country because the lookup is
    /// switched off are not waiting: three such photos from Konstanz do not change the count.
    @Test func photosThatCannotGetACountryAreNotCountedAsWaiting() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1)
        let everyday = lib.assets
        let konstanz = GeoCoordinate(latitude: 47.6588, longitude: 9.1750)
        _ = (0..<3).map { lib.photo(at: Fixture.date("2026-04-0\($0 + 1) 12:00"), konstanz, jitterMeters: 100) }
        func waiting(_ assets: [AssetSnapshot]) async throws -> Int {
            let w = try Self.world(assets, configure: { $0.privacy.allowOnlineGeocoding = false })
            let report = try await w.pipeline.run()
            #expect(report.isComplete)
            return report.placesPendingOnline
        }
        let without = try await waiting(everyday)
        let with = try await waiting(lib.assets)
        #expect(with == without, "\(with) places waiting with the photos from Konstanz, \(without) without them")
    }

    /// Online lookup on, but Apple cannot be reached right now: the photos at the border wait for
    /// it ("offen"), as before; only a lookup that is switched off or has answered "nothing here"
    /// makes a place impossible.
    @Test func photosWaitingForAnOnlineLookupStayOpen() async throws {
        var lib = LibraryBuilder()
        _ = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1)
        let konstanz = GeoCoordinate(latitude: 47.6588, longitude: 9.1750)
        let border = (0..<3).map { lib.photo(at: Fixture.date("2026-04-0\($0 + 1) 12:00"), konstanz, jitterMeters: 100) }
        let w = try Self.world(lib.assets, geocoder: FakeGeocoder(failures: Array(repeating: .offline, count: 50)))
        _ = try await w.pipeline.run()
        let d = try await w.derived()
        #expect(w.places(d, border) == Array(repeating: AreaStatus.analysisPending.rawValue, count: 3))
    }
}
