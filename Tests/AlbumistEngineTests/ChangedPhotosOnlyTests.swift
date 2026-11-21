import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Review P4-03: every run read the whole library again (every photo, every album) and wrote
/// every album back, also when nothing had changed; a run starts at every launch of the app.
/// A run now reads only what the library's change history names, and its results are the
/// same as after a whole read. Counted in work, not timed: photos read, album walks, rows written.
@Suite("Reading only changed photos")
struct ChangedPhotosOnlyTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    static let clock = Fixture.date("2026-07-01 12:00")

    struct World {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var pipeline: AnalysisPipeline
        var analyzer: FakeContentAnalyzer
        /// The pipeline's clock (`now`), moved on by tests.
        var clock: Clock
    }

    /// A clock tests move on.
    final class Clock: Sendable {
        let now = Locked(ChangedPhotosOnlyTests.clock)
    }

    /// Munich everyday life, a Rome trip, a few screenshots, and one album of the trip.
    static func library() -> (assets: [AssetSnapshot], inventory: CollectionInventory, rome: [AssetID], home: [AssetID]) {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for day in 1...3 { _ = lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        let album = CollectionSnapshot(id: CollectionID("album-rome"), title: "Rom", assetIDs: Set(rome.prefix(5)))
        let folder = CollectionSnapshot(id: CollectionID("folder-trips"), title: "Reisen", kind: .folder, childIDs: [album.id])
        var inside = album
        inside.parentID = folder.id
        return (lib.assets, CollectionInventory([folder, inside]), rome, home)
    }

    static func world(history: Bool = true, hidden: Set<AssetID> = [], progressEvery: Int? = nil,
                      settings configure: (inout OrganizationSettings) -> Void = { _ in }) throws -> World {
        let lib = library()
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        configure(&settings)
        let store = try AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets, inventory: lib.inventory, hidden: hidden, history: history,
                                           progressEvery: progressEvery)
        let analyzer = FakeContentAnalyzer()
        let clock = Clock()
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source,
            now: { clock.now.withLock { $0 } }, earlyGraceOnStop: .seconds(60)
        )
        return World(store: store, reader: reader, pipeline: pipeline, analyzer: analyzer, clock: clock)
    }

    struct Work: Equatable, CustomStringConvertible {
        var wholeReads: Int, photosRead: Int, albumWalks: Int, rowWrites: Int
        var description: String { "whole reads \(wholeReads), photos read \(photosRead), album walks \(albumWalks), rows written \(rowWrites)" }
    }

    static func work(_ w: World) async -> Work {
        Work(wholeReads: await w.reader.wholeReads, photosRead: await w.reader.photosRead,
             albumWalks: await w.reader.inventoryReads, rowWrites: await w.store.libraryRowWrites)
    }

    static func minus(_ a: Work, _ b: Work) -> Work {
        Work(wholeReads: a.wholeReads - b.wholeReads, photosRead: a.photosRead - b.photosRead,
             albumWalks: a.albumWalks - b.albumWalks, rowWrites: a.rowWrites - b.rowWrites)
    }

    /// Runs `w` and returns its report and the work of the run.
    static func run(_ w: World) async throws -> (AnalysisPipeline.Report, Work) {
        let before = await work(w)
        let report = try await w.pipeline.run()
        #expect(report.isComplete)
        return (report, minus(await work(w), before))
    }

    /// Everything a run leaves that a whole read decides: the photos, the albums, the places
    /// and the suggestions.
    struct Outcome: Equatable {
        var assets: [AssetSnapshot]
        var inventory: CollectionInventory
        var places: [AssetID: ResolvedPlace]
        var proposals: ProposalSnapshot?
        var newOrChanged: Int
        var removed: Int
    }

    static func outcome(_ w: World, _ report: AnalysisPipeline.Report) async throws -> Outcome {
        // When a place was looked up is the wall clock, not the run's.
        let places = try await w.store.places().mapValues { place in
            var place = place
            place.resolvedAt = .distantPast
            return place
        }
        return Outcome(assets: try await w.store.allAssets(), inventory: try await w.store.loadInventory(),
                places: places, proposals: try await w.pipeline.latestProposals(),
                newOrChanged: report.newOrChanged, removed: report.removed)
    }

    // MARK: - Work

    @Test func secondRunWithoutChangeReadsAndWritesNothing() async throws {
        let w = try Self.world()
        let (_, first) = try await Self.run(w)
        let photos = Self.library().assets.count
        #expect(first.photosRead == photos)
        #expect(first.rowWrites > photos)

        let (report, second) = try await Self.run(w)
        // Before: whole reads 1, photos read 208, album walks 2, rows written 7 (every album
        // and its photos written again). Now nothing of the library is read or written.
        #expect(second == Work(wholeReads: 0, photosRead: 0, albumWalks: 0, rowWrites: 0), "\(second)")
        #expect(report.newOrChanged == 0)
        #expect(report.removed == 0)
    }

    @Test func oneNewPhotoReadsOnlyThatPhoto() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        var assets = await w.reader.assets
        var lib = LibraryBuilder()
        for _ in 0..<1000 { _ = lib.photo(at: Fixture.date("2026-06-20 10:00"), Fixture.Places.munichHome) }
        var added = lib.assets.last!
        added.id = AssetID("new-photo")
        assets.append(added)
        await w.reader.set(assets: assets)

        let (report, second) = try await Self.run(w)
        #expect(second.wholeReads == 0)
        #expect(second.photosRead == 1)
        // Any change walks the albums once (a photo may have joined one); nothing of them is written.
        #expect(second.albumWalks == 1)
        #expect(second.rowWrites == 1)
        #expect(report.newOrChanged == 1)
    }

    // MARK: - Same results as a whole read

    /// Runs a world with the change history and one without it (every run a whole read)
    /// through the same changes, and expects the same outcome after each run.
    static func expectSameAsWholeRead(
        hidden: Set<AssetID> = [],
        settings configure: (inout OrganizationSettings) -> Void = { _ in },
        _ change: (InMemoryLibraryReader, inout OrganizationSettings) async throws -> Void
    ) async throws -> (changed: Work, whole: Work) {
        let changed = try Self.world(history: true, hidden: hidden, settings: configure)
        let whole = try Self.world(history: false, hidden: hidden, settings: configure)
        let (r1, _) = try await Self.run(changed)
        let (r2, _) = try await Self.run(whole)
        #expect(try await Self.outcome(changed, r1) == Self.outcome(whole, r2))

        var settings = await changed.pipeline.settings
        try await change(changed.reader, &settings)
        var settingsWhole = await whole.pipeline.settings
        try await change(whole.reader, &settingsWhole)
        await changed.pipeline.update(settings: settings)
        await whole.pipeline.update(settings: settingsWhole)

        let (c1, workChanged) = try await Self.run(changed)
        let (c2, workWhole) = try await Self.run(whole)
        let a = try await Self.outcome(changed, c1), b = try await Self.outcome(whole, c2)
        #expect(a.assets == b.assets)
        #expect(a.inventory == b.inventory)
        #expect(a.places == b.places)
        #expect(a.proposals == b.proposals)
        #expect(a.newOrChanged == b.newOrChanged)
        #expect(a.removed == b.removed)
        // And once more without a change: still the same.
        let (d1, _) = try await Self.run(changed)
        let (d2, _) = try await Self.run(whole)
        #expect(try await Self.outcome(changed, d1) == Self.outcome(whole, d2))
        return (workChanged, workWhole)
    }

    @Test func noChangeGivesTheSameResult() async throws {
        let work = try await Self.expectSameAsWholeRead { _, _ in }
        #expect(work.changed.photosRead == 0)
        #expect(work.whole.photosRead == Self.library().assets.count)
    }

    @Test func addedPhotoGivesTheSameResult() async throws {
        // A photo of the Rome trip that arrives from iCloud later, with its old date.
        let work = try await Self.expectSameAsWholeRead { reader, _ in
            var assets = await reader.assets
            assets.append(AssetSnapshot(id: AssetID("late-from-icloud"), kind: .image, creationDate: Fixture.date("2026-05-15 16:00"),
                                        location: Fixture.Places.rome, pixelWidth: 4032, pixelHeight: 3024))
            await reader.set(assets: assets)
        }
        #expect(work.changed.photosRead == 1)
        #expect(work.changed.wholeReads == 0)
    }

    @Test func deletedPhotoGivesTheSameResult() async throws {
        let rome = Self.library().rome
        let work = try await Self.expectSameAsWholeRead { reader, _ in
            // One of the album's photos: it leaves the album too.
            await reader.set(assets: await reader.assets.filter { $0.id != rome[0] })
            var inventory = await reader.inventory
            var album = try #require(inventory[CollectionID("album-rome")])
            album.assetIDs.remove(rome[0])
            inventory = CollectionInventory(inventory.collections.values.filter { $0.id != album.id } + [album])
            await reader.set(inventory: inventory)
        }
        #expect(work.changed.photosRead == 0)
        #expect(work.changed.wholeReads == 0)
        #expect(work.changed.albumWalks == 1)
    }

    @Test func editedLocationAndDateGiveTheSameResult() async throws {
        let home = Self.library().home
        let work = try await Self.expectSameAsWholeRead { reader, _ in
            var assets = await reader.assets
            // A home photo moved to Rome (location edited), another one to another day.
            for index in assets.indices where assets[index].id == home[10] || assets[index].id == home[20] {
                if assets[index].id == home[10] {
                    assets[index].location = Fixture.Places.rome
                } else {
                    assets[index].creationDate = Fixture.date("2026-05-14 09:00")
                }
                assets[index].modificationDate = Fixture.date("2026-06-30 08:00")
            }
            await reader.set(assets: assets)
        }
        #expect(work.changed.photosRead == 2)
        #expect(work.changed.wholeReads == 0)
    }

    @Test func hiddenPhotoGivesTheSameResult() async throws {
        let home = Self.library().home
        let work = try await Self.expectSameAsWholeRead(hidden: [home[3]]) { reader, _ in
            // One hidden photo shown again, another one hidden.
            await reader.set(hidden: [home[5]])
        }
        #expect(work.changed.wholeReads == 0)
        #expect(work.changed.photosRead == 1)
    }

    @Test func expiredHistoryReadsTheWholeLibrary() async throws {
        let home = Self.library().home
        let work = try await Self.expectSameAsWholeRead { reader, _ in
            await reader.set(assets: await reader.assets.filter { $0.id != home[1] })
            await reader.expireHistory()
        }
        #expect(work.changed.wholeReads == 1)
        #expect(work.changed.photosRead == Self.library().assets.count - 1)
    }

    @Test func showingHiddenPhotosReadsTheWholeLibrary() async throws {
        let home = Self.library().home
        let work = try await Self.expectSameAsWholeRead(hidden: [home[3]]) { _, settings in
            settings.privacy.includeHiddenAssets = true
        }
        #expect(work.changed.wholeReads == 1)
    }

    @Test func limitedAccessReadsTheWholeLibrary() async throws {
        let home = Self.library().home
        let work = try await Self.expectSameAsWholeRead { reader, _ in
            await reader.set(access: .limited)
            await reader.set(assets: await reader.assets.filter { $0.id != home[2] })
        }
        #expect(work.changed.wholeReads == 1)
    }

    /// The store holds other photos than the library at the mark (a database put back, a bug):
    /// the count after reading the changes differs, and the whole library is read in the same run.
    @Test func countThatDoesNotFitReadsTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let photos = Self.library().assets.count
        _ = try await w.store.removeAssets([Self.library().home[0]])
        let (report, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(try await w.store.assetCount() == photos)
        #expect(report.newOrChanged == 1)
    }

    /// "Analyse neu aufbauen" forgets the mark with the analysis: the next run reads everything.
    @Test func resetAnalysisReadsTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        try await w.store.resetAnalysis()
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
    }

    /// A Pause while the changed photos are read keeps the mark where it was: the next run
    /// reads those changes again, and the photos read before the Pause are kept.
    @Test func pauseWhileReadingChangesReadsThemAgain() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let lib = Self.library()
        let added = (1...3).map { n in
            AssetSnapshot(id: AssetID("added-\(n)"), kind: .image, creationDate: Fixture.date("2026-06-2\(n) 10:00"),
                          location: Fixture.Places.munichHome, pixelWidth: 4032, pixelHeight: 3024)
        }
        await w.reader.set(assets: lib.assets + added)
        let control = AnalysisRunControl()
        await w.reader.set(onChangedRead: { _ in control.pause() })
        let paused = try await w.pipeline.run(control: control)
        #expect(paused.pausedBecause == .userPaused)
        #expect(try await w.store.assetCount() == lib.assets.count + 1)

        await w.reader.set(onChangedRead: nil)
        let (report, work) = try await Self.run(w)
        #expect(work.wholeReads == 0)
        #expect(work.photosRead == 3)
        #expect(report.newOrChanged == 2)
        #expect(try await w.store.assetCount() == lib.assets.count + 3)
    }

    /// Many changed photos: the whole read, which says how far it is on the card.
    @Test func manyChangesReadTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let added = (0...AnalysisPipeline.largestChangeRead).map { n in
            AssetSnapshot(id: AssetID(String(format: "import-%05d", n)), kind: .image, creationDate: Fixture.date("2026-06-25 10:00").addingTimeInterval(Double(n)),
                          location: nil, pixelWidth: 4032, pixelHeight: 3024)
        }
        await w.reader.set(assets: Self.library().assets + added)
        let (report, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(report.newOrChanged == added.count)
    }

    /// Every `wholeReadEvery`-th run with changes reads the whole library anyway, and counts again.
    @Test func wholeReadNowAndThen() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        var mark = try #require(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: key))
        #expect(mark.changeReads == 0)
        let home = Self.library().home
        await w.reader.set(assets: await w.reader.assets.filter { $0.id != home[7] })
        _ = try await Self.run(w)
        mark = try #require(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: key))
        #expect(mark.changeReads == 1)
        // Runs without a change do not count.
        _ = try await Self.run(w)
        #expect(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: key)?.changeReads == 1)

        mark.changeReads = AnalysisPipeline.wholeReadEvery
        try await w.store.setValue(mark, forKey: key)
        await w.reader.set(assets: await w.reader.assets.filter { $0.id != home[8] })
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: key)?.changeReads == 0)
    }

    @Test func renamedAlbumGivesTheSameResult() async throws {
        let work = try await Self.expectSameAsWholeRead { reader, _ in
            var inventory = await reader.inventory
            var album = try #require(inventory[CollectionID("album-rome")])
            album.title = "Rom 2026"
            inventory = CollectionInventory(inventory.collections.values.filter { $0.id != album.id } + [album])
            await reader.set(inventory: inventory)
        }
        #expect(work.changed.photosRead == 0)
        #expect(work.changed.albumWalks == 1)
        #expect(work.changed.rowWrites == 2 * (1 + 5))
    }

    /// An album made while the run is busy (a plan applied meanwhile): the suggestions walk the
    /// albums again, since the history names a change after the run read them.
    @Test func albumMadeDuringTheRunIsSeenBySuggestions() async throws {
        let lib = Self.library()
        let base = InMemoryLibraryReader(assets: lib.assets, inventory: lib.inventory)
        let made = CollectionSnapshot(id: CollectionID("album-made"), title: "Neu", assetIDs: Set(lib.home.prefix(3)))
        let reader = AlbumMadeAfterFirstWalk(base: base, made: made)
        let store = try AlbumistStore(url: nil)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source,
            now: { Self.clock }, earlyGraceOnStop: .seconds(60)
        )
        #expect(try await pipeline.run().isComplete)
        #expect(try await store.loadInventory()[made.id] == made)
        // The next run reads that change: no whole read, and the albums are as in the library.
        #expect(try await pipeline.run().isComplete)
        #expect(await base.wholeReads == 1)
        #expect(try await store.loadInventory() == (await base.inventory))
    }

    // MARK: - Second review

    /// A photo the fetch by identifier misses (a reader that gets it wrong) is not deleted with
    /// its results before the count shows that something is wrong: the count is checked before
    /// anything is written, and the whole read follows. Red before: the photo was deleted with
    /// its analysis, put back by the whole read and analysed again.
    @Test func aPhotoTheFetchMissesKeepsItsResults() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let photo = Self.library().home[4]
        let analysed = w.analyzer.counts.withLock { $0.content }
        // Made a favourite: a change in the library that changes nothing stored.
        await w.reader.set(assets: await w.reader.assets.map { asset in
            var asset = asset
            if asset.id == photo { asset.isFavorite = true }
            return asset
        })
        await w.reader.set(missingFromFetchByID: [photo])
        let writesBefore = await w.store.libraryRowWrites
        let (report, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(report.removed == 0)
        #expect(report.contentAnalyzed == 0)
        #expect(w.analyzer.counts.withLock { $0.content } == analysed)
        #expect(await w.store.libraryRowWrites == writesBefore)
    }

    /// What every stored mark has.
    struct StoredMark: Codable {
        var mark: LibraryChangeMark
        var includeHidden: Bool
    }

    /// The mark as another version of the reader stored it.
    struct MarkOfAnotherReader: Codable {
        var mark: LibraryChangeMark
        var includeHidden: Bool
        var changeReads: Int
        var readerVersion: Int
        var wholeReadAt: Date
    }

    /// A mark of another version of the reader (an update that reads more of each photo): the
    /// whole library is read, so photos that did not change get what it reads now. Red before.
    @Test func markOfAnotherReaderVersionReadsTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        let stored = try #require(try await w.store.value(StoredMark.self, forKey: key))
        let older = MarkOfAnotherReader(mark: stored.mark, includeHidden: stored.includeHidden, changeReads: 0,
                                        readerVersion: 0, wholeReadAt: Self.clock)
        try await w.store.setValue(older, forKey: key)
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(try await w.store.value(MarkOfAnotherReader.self, forKey: key)?.readerVersion ?? 0 > 0)
    }

    /// A stored mark that cannot be read (an older form, a broken value) does not fail the run:
    /// the whole library is read and a new mark stored. Red before: the run ended with an error.
    @Test func markThatCannotBeReadReadsTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        try await w.store.setValue("not a mark", forKey: key)
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(try await w.store.value(StoredMark.self, forKey: key) != nil)
        let (_, again) = try await Self.run(w)
        #expect(again.wholeReads == 0)
    }

    /// A library without changes is read whole once a week anyway: what the history may miss
    /// (albums, details of a photo) is put right. Red before: never again.
    @Test func quietLibraryIsReadWholeAfterAWeek() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        w.clock.now.withLock { $0 = Self.clock.addingTimeInterval(6 * 86_400) }
        let (_, sixDays) = try await Self.run(w)
        #expect(sixDays.wholeReads == 0)
        w.clock.now.withLock { $0 = Self.clock.addingTimeInterval(8 * 86_400) }
        let (_, eightDays) = try await Self.run(w)
        #expect(eightDays.wholeReads == 1)
        // Counted from that read on.
        w.clock.now.withLock { $0 = Self.clock.addingTimeInterval(9 * 86_400) }
        let (_, nineDays) = try await Self.run(w)
        #expect(nineDays.wholeReads == 0)
    }

    /// A history that does not answer (Photos throws) does not end the run: the whole library
    /// is read. Red before: the run ended with the error.
    @Test func historyThatThrowsReadsTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        await w.reader.set(changesFail: true)
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
    }

    /// A whole read paused half way leaves no mark: the next run reads the whole library
    /// again instead of taking the photos stored until the Pause for the library.
    @Test func pausedWholeReadLeavesNoMark() async throws {
        let w = try Self.world(progressEvery: 50)
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        #expect(try await w.store.value(StoredMark.self, forKey: key) != nil)
        // Forces the next run to a whole read, then pauses it at 100 photos.
        await w.reader.expireHistory()
        let control = AnalysisRunControl()
        await w.reader.set(onWholeReadProgress: { read in if read >= 100 { control.pause() } })
        let paused = try await w.pipeline.run(control: control)
        #expect(paused.pausedBecause == .userPaused)
        #expect(try await w.store.value(StoredMark.self, forKey: key) == nil)
        await w.reader.set(onWholeReadProgress: nil)
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        let (_, again) = try await Self.run(w)
        #expect(again.wholeReads == 0)
    }

    /// Switching "Ausgeblendete Fotos" reads the whole library without asking the history
    /// from the mark read with the other setting.
    @Test func hiddenSettingSwitchedNeverAsksTheHistory() async throws {
        let home = Self.library().home
        let w = try Self.world(hidden: [home[3]])
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        let before = try #require(try await w.store.value(StoredMark.self, forKey: key)).mark
        let asked = await w.reader.changesAsked.filter { $0 == before }.count
        // A change too, so the next mark is another one.
        await w.reader.set(assets: await w.reader.assets.filter { $0.id != home[9] })
        var settings = await w.pipeline.settings
        settings.privacy.includeHiddenAssets = true
        await w.pipeline.update(settings: settings)
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        #expect(await w.reader.changesAsked.filter { $0 == before }.count == asked)
        #expect(try await w.store.assetCount() == Self.library().assets.count - 1)
    }

    /// A photo added while the whole library is read is read by the next run: the mark is
    /// taken before the whole read.
    @Test func photoAddedDuringAWholeReadIsReadNext() async throws {
        let w = try Self.world()
        let late = AssetSnapshot(id: AssetID("during-the-read"), kind: .image, creationDate: Fixture.date("2026-06-29 10:00"),
                                 location: Fixture.Places.munichHome, pixelWidth: 4032, pixelHeight: 3024)
        await w.reader.set(arrivingDuringWholeRead: [late])
        _ = try await Self.run(w)
        let photos = Self.library().assets.count
        #expect(try await w.store.assetCount() == photos)
        let (report, work) = try await Self.run(w)
        #expect(work.wholeReads == 0)
        #expect(work.photosRead == 1)
        #expect(report.newOrChanged == 1)
        #expect(try await w.store.assetCount() == photos + 1)
    }

    // MARK: - Third review

    /// More changed photos than are read one by one, with as many photos deleted as added: the
    /// count alone would fit. The history says "too many" and the whole library is read, so
    /// no deletion and no new photo is lost.
    @Test func manyChangesWhoseCountFitsReadTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        var lib = LibraryBuilder()
        for _ in 0..<1_100 { _ = lib.photo(at: Fixture.date("2026-06-25 10:00"), nil) }
        let imported = lib.assets.enumerated().map { index, asset -> AssetSnapshot in
            var asset = asset
            asset.id = AssetID(String(format: "import-%04d", index))
            return asset
        }
        let before = await w.reader.assets
        let deleted = Set(before.prefix(150).map(\.id))
        let kept = Array(before.dropFirst(150))
        // 150 deleted and 150 added (the count stays), and 950 more added and deleted again:
        // 1,250 photos named.
        await w.reader.set(assets: kept + imported.prefix(150))
        await w.reader.set(assets: kept + imported)
        await w.reader.set(assets: kept + imported.prefix(150))
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 1)
        let stored = Set(try await w.store.allAssets().map(\.id))
        #expect(stored.isDisjoint(with: deleted))
        #expect(stored.isSuperset(of: imported.prefix(150).map(\.id)))
        #expect(stored.count == before.count)
    }

    /// A history that does not answer in time (`PhotosNotResponding`) or a run that is ended
    /// (`CancellationError`) is not "a history that cannot tell": the run ends as with any
    /// read Photos does not answer, and the mark stays (no whole read, nothing removed).
    /// Red before: the error was taken for "cannot tell", the mark removed and the whole
    /// library read.
    @Test(arguments: [false, true])
    func historyThatHangsOrIsCancelledKeepsTheMark(cancelled: Bool) async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        let before = try #require(try await w.store.value(StoredMark.self, forKey: key)).mark
        let error: any Error & Sendable = cancelled
            ? CancellationError() : PhotosNotResponding(lane: .read, what: "libraryChanges", notSent: false)
        await w.reader.set(changesThrow: error)
        let wholeBefore = await w.reader.wholeReads
        await #expect(throws: (any Error).self) { _ = try await w.pipeline.run() }
        #expect(await w.reader.wholeReads == wholeBefore)
        #expect(try await w.store.value(StoredMark.self, forKey: key)?.mark == before)
        // Photos answers again: the changes are read from the same mark.
        await w.reader.set(changesThrow: nil)
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 0)
    }

    /// A photo the history names as deleted that the store never had (added and deleted
    /// between two runs) is no reason for a whole read.
    @Test func deletedPhotoNeverStoredReadsNoWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let photos = Self.library().assets
        let brief = AssetSnapshot(id: AssetID("brief"), kind: .image, creationDate: Fixture.date("2026-06-28 10:00"),
                                  location: nil, pixelWidth: 4032, pixelHeight: 3024)
        await w.reader.set(assets: photos + [brief])
        await w.reader.set(assets: photos)
        let (report, work) = try await Self.run(w)
        #expect(work.wholeReads == 0)
        #expect(report.removed == 0)
        #expect(try await w.store.assetCount() == photos.count)
    }

    /// A read of changes keeps the time of the last whole read: the weekly whole read counts
    /// from it, not from the last change.
    @Test func changeReadKeepsTheTimeOfTheWholeRead() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let key = AnalysisPipeline.Key.libraryMark
        #expect(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: key)?.wholeReadAt == Self.clock)
        w.clock.now.withLock { $0 = Self.clock.addingTimeInterval(2 * 86_400) }
        await w.reader.set(assets: await w.reader.assets.filter { $0.id != Self.library().home[11] })
        let (_, work) = try await Self.run(w)
        #expect(work.wholeReads == 0)
        let mark = try #require(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: key))
        #expect(mark.wholeReadAt == Self.clock)
        #expect(mark.changeReads == 1)
    }

    /// Adds `made` to the library right after the first walk over the albums.
    actor AlbumMadeAfterFirstWalk: PhotoLibraryReading {
        let base: InMemoryLibraryReader
        let made: CollectionSnapshot
        var walks = 0
        init(base: InMemoryLibraryReader, made: CollectionSnapshot) {
            self.base = base
            self.made = made
        }
        func access() async -> LibraryAccess { await base.access() }
        func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] {
            try await base.fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails)
        }
        func currentInventory() async throws -> CollectionInventory {
            let inventory = try await base.currentInventory()
            walks += 1
            if walks == 1 {
                await base.set(inventory: CollectionInventory(Array(inventory.collections.values) + [made]))
            }
            return inventory
        }
        func changeMark() async -> LibraryChangeMark? { await base.changeMark() }
        func changes(since mark: LibraryChangeMark, limit: Int) async throws -> LibraryChanges? {
            try await base.changes(since: mark, limit: limit)
        }
        func fetchAssets(_ ids: Set<AssetID>, includeHidden: Bool, knownDetails: [AssetID: Date],
                         progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> ChangedAssets {
            try await base.fetchAssets(ids, includeHidden: includeHidden, knownDetails: knownDetails, progress: progress)
        }
    }

    /// The marks of one library mean nothing for another one (a new iPhone, another Photos library).
    @Test func markOfAnotherLibraryReadsTheWholeLibrary() async throws {
        let w = try Self.world()
        _ = try await Self.run(w)
        let lib = Self.library()
        let other = InMemoryLibraryReader(assets: Array(lib.assets.dropFirst(3)), inventory: lib.inventory)
        let pipeline = AnalysisPipeline(
            store: w.store, reader: other, analyzer: FakeContentAnalyzer(), geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(), settings: await w.pipeline.settings, calendar: Fixture.calendar, time: ManualTime().source,
            now: { Self.clock }, earlyGraceOnStop: .seconds(60)
        )
        let report = try await pipeline.run()
        #expect(report.isComplete)
        #expect(await other.wholeReads == 1)
        #expect(report.removed == 3)
        #expect(try await w.store.assetCount() == lib.assets.count - 3)
    }
}
