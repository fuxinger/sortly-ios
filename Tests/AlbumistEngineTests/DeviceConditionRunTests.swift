import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
@testable import AlbumistCore
@testable import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// How the device-condition UI tests (DeviceConditionUITests 01, 02, 03, 06 and 09) end, here
/// instead of on the simulator. Those tests waited on the simulator for the whole demo library
/// (246 photos, about 2 to 3 minutes each) to be analysed again after the condition; whether a
/// run then ends with every photo, without counting back and without looking at a photo twice,
/// is the pipeline's work and is checked here in a second. The UI tests keep what the user
/// sees: the waiting card, that it goes on by itself, that the count moves and never goes back
/// (docs/TEST_PLAN.md, "UI-Tests: Dauer und Verlagerung").
@Suite("Device conditions: every run ends with every photo")
struct DeviceConditionRunTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Setup {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var analyzer: FakeContentAnalyzer
        var conditions: FakeConditions
        var time: ManualTime
        var settings: OrganizationSettings
        var photos: Int

        /// A pipeline on this store, as the app makes one at every launch.
        func pipeline(analyzer other: (any ContentAnalyzing)? = nil) -> AnalysisPipeline {
            AnalysisPipeline(
                store: store, reader: reader, analyzer: other ?? analyzer, geocoder: FakeGeocoder(), map: DeviceConditionRunTests.map,
                conditions: conditions, settings: settings, calendar: Fixture.calendar, time: time.source, batchSize: 10
            )
        }
    }

    /// Everyday Munich for two months and a Rome trip: about 150 photos, enough for every
    /// script below to reach the image analysis and leave work after it.
    func setup(store: AlbumistStore? = nil) throws -> Setup {
        var lib = LibraryBuilder()
        var ids = lib.daily(from: "2026-03-01", to: "2026-04-30", at: Fixture.Places.munichHome, perDay: 2)
        ids += lib.daily(from: "2026-05-12", to: "2026-05-17", at: Fixture.Places.rome, perDay: 5, hour: 10)
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        return Setup(store: try store ?? AlbumistStore(url: nil), reader: InMemoryLibraryReader(assets: lib.assets),
                     analyzer: FakeContentAnalyzer(cloudOnly: [], labels: { _ in [] }, text: { _ in "" }),
                     conditions: FakeConditions(), time: ManualTime(), settings: settings, photos: ids.count)
    }

    /// The image step's counts of one run, in the order the card showed them.
    final class ContentCounts: Sendable {
        let seen = Locked<[Int]>([])
        var onProgress: @Sendable (AnalysisPipeline.Progress) -> Void {
            { progress in
                guard progress.stage == .content else { return }
                self.seen.withLock { $0.append(progress.completed) }
            }
        }
        var values: [Int] { seen.withLock { $0 } }
        var neverGoesBack: Bool { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
    }

    // MARK: 01 Heat

    /// DeviceConditionUITests.test01 plays `normal:40,gentle:40,hot:10,normal`: 40 checks at full
    /// speed, 40 warm, 10 hot, then normal again. The run waits instead of ending, says so once
    /// and once that it goes on, and ends with every photo looked at exactly once.
    @Test func heatScriptOfTheUITestEndsWithEveryPhoto() async throws {
        let s = try setup()
        s.conditions.paces.withLock {
            $0 = Array(repeating: .normal, count: 40) + Array(repeating: .gentle, count: 40)
                + Array(repeating: .wait(.thermal), count: 10) + [.normal]
        }
        let waits = Locked<[PauseReason?]>([])
        let counts = ContentCounts()
        let report = try await s.pipeline().run(onProgress: counts.onProgress, onWaiting: { reason in waits.withLock { $0.append(reason) } })
        #expect(report.isComplete)
        #expect(report.pausedBecause == nil)
        #expect(report.contentAnalyzed == s.photos)
        #expect(s.analyzer.counts.withLock { $0.content } == s.photos)
        #expect(waits.withLock { $0 } == [.thermal, nil])
        #expect(counts.neverGoesBack)
        #expect(counts.values.last == s.photos)
        // It waited on the clock (ten checks, each followed by a break) instead of ending.
        #expect(s.time.now.withLock { $0 } >= AnalysisPipeline.waitCheck * 10)
    }

    // MARK: 02 Low battery, Low Power Mode

    /// DeviceConditionUITests.test02 plays `normal:30,battery:8,lowpower`: the run waits for the
    /// charger and goes on by itself; Low Power Mode is full speed in the app (the app's script
    /// answers `.normal` for it, `DeviceStateTests` checks the device's own rule). It ends with
    /// every photo, and nothing waits for a tap.
    @Test func lowBatteryThenLowPowerModeEndsWithEveryPhoto() async throws {
        let s = try setup()
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 30) + Array(repeating: .wait(.batteryLow), count: 8) + [.normal] }
        let waits = Locked<[PauseReason?]>([])
        let counts = ContentCounts()
        let report = try await s.pipeline().run(onProgress: counts.onProgress, onWaiting: { reason in waits.withLock { $0.append(reason) } })
        #expect(report.isComplete)
        #expect(report.pausedBecause == nil)
        #expect(report.contentAnalyzed == s.photos)
        #expect(waits.withLock { $0 } == [.batteryLow, nil])
        #expect(counts.neverGoesBack)
        #expect(counts.values.last == s.photos)
        // Low Power Mode alone never makes a run in the app stop or wait.
        #expect(DeviceState(thermal: .nominal, batteryLevel: 0.8, isLowPowerMode: true).appPace == .normal)
        #expect(DeviceState(thermal: .nominal, batteryLevel: 0.05, isLowPowerMode: true).appPace == .wait(.batteryLow))
    }

    // MARK: 03 Background time over, app ended

    /// DeviceConditionUITests.test03: iOS takes the background time away in the middle of the
    /// image analysis (the run ends with `.timeBudget`), then the app is ended and opened again
    /// (a new pipeline on the same database). The next run counts on from what was done, never
    /// back, ends with every photo and looks at no finished photo again.
    @Test func backgroundTimeOverThenRelaunchEndsWithEveryPhoto() async throws {
        let s = try setup()
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 40) + [.stop(.timeBudget)] }
        let first = try await s.pipeline().run()
        #expect(first.pausedBecause == .timeBudget)
        #expect(!first.isComplete)
        let done = first.contentAnalyzed
        #expect(done > 0 && done < s.photos)

        s.conditions.paces.withLock { $0 = [.normal] }
        let counts = ContentCounts()
        let second = try await s.pipeline().run(onProgress: counts.onProgress)
        #expect(second.isComplete)
        #expect(counts.values.first == done)
        #expect(counts.neverGoesBack)
        #expect(counts.values.last == s.photos)
        #expect(first.contentAnalyzed + second.contentAnalyzed == s.photos)
        #expect(s.analyzer.counts.withLock { $0.content } == s.photos)
    }

    // MARK: 09 Photo access taken away during the analysis

    /// DeviceConditionUITests.test09: access is taken away while the image analysis runs (iOS
    /// ends the app), the next launch has no access (nothing is read, nothing is lost), then
    /// access comes back: the run after it ends with every photo, none looked at twice.
    @Test func accessTakenAwayThenBackEndsWithEveryPhoto() async throws {
        let s = try setup()
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 30) + [.stop(.timeBudget)] }
        let ended = try await s.pipeline().run()
        let done = ended.contentAnalyzed
        #expect(done > 0 && done < s.photos)

        await s.reader.set(access: .denied)
        s.conditions.paces.withLock { $0 = [.normal] }
        let refused = try await s.pipeline().run()
        #expect(refused.pausedBecause == .accessRevoked)
        #expect(refused.contentAnalyzed == 0)

        await s.reader.set(access: .full)
        let counts = ContentCounts()
        let back = try await s.pipeline().run(onProgress: counts.onProgress)
        #expect(back.isComplete)
        #expect(counts.values.first == done)
        #expect(counts.neverGoesBack)
        #expect(counts.values.last == s.photos)
        #expect(s.analyzer.counts.withLock { $0.content } == s.photos)
    }

    // MARK: 06 Full disk during the analysis

    /// DeviceConditionUITests.test06: the disk fills up in the middle of the analysis. The run
    /// stops on SQLite's "full" error and keeps what it stored; once there is space again the
    /// next run ends with every photo, from where the first one got to.
    @Test func fullDiskDuringTheAnalysisThenSpaceAgainEndsWithEveryPhoto() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-diskfull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AlbumistStore(url: dir.appendingPathComponent("albumist.sqlite"))
        let s = try setup(store: store)

        // Part of the image analysis is stored, then the disk is full.
        s.conditions.paces.withLock { $0 = Array(repeating: .normal, count: 30) + [.stop(.timeBudget)] }
        let first = try await s.pipeline().run()
        #expect(first.pausedBecause == .timeBudget)
        let done = first.contentAnalyzed
        #expect(done > 0)
        try await store.fillDiskForTest()
        s.conditions.paces.withLock { $0 = [.normal] }
        var failedOnFullDisk = false
        do {
            _ = try await s.pipeline().run()
        } catch let error as SQLiteError {
            failedOnFullDisk = true
            #expect(error.code == 13, "\(error)") // SQLITE_FULL
        }
        #expect(failedOnFullDisk, "The run on a full disk did not meet the full disk")
        #expect(try await store.integrityReportForTest() == "ok")

        // Space again (the user freed some in Settings): the next run ends with every photo.
        try await store.freeDiskForTest()
        let counts = ContentCounts()
        let after = try await s.pipeline().run(onProgress: counts.onProgress)
        #expect(after.isComplete)
        #expect(counts.neverGoesBack)
        #expect(counts.values.last == s.photos)
        #expect(try await store.integrityReportForTest() == "ok")
        // Nothing is left for a later run, and photos whose results the full disk kept from
        // being stored were looked at once more at most.
        let again = try await s.pipeline().run()
        #expect(again.isComplete)
        #expect(again.contentAnalyzed == 0)
        #expect(s.analyzer.counts.withLock { $0.content } <= 2 * s.photos)
    }

    /// DeviceConditionUITests.test06 as it ran (TestFlight run 44461253154): the disk fills up
    /// after the 25th photo of the image step (`UITestAnalyzer`), the run ends on SQLITE_FULL,
    /// and back in the app the next run goes on from where it stopped. While that run is on the
    /// steps before the image step, the card says "Gleich wieder bei Schritt 4 von 6"; the count
    /// beside it was the library read's ("246 von 246 Fotos"), and it fell to the image step's
    /// "36 von 246" once the run got there. Read as the UI test reads the card (step and count
    /// of the progress element), no count read later is below one read earlier: while catching
    /// up, the card shows where the run stopped in the step it names.
    @Test func fullDiskInTheImageStepThenTheCardNeverCountsBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-diskfull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AlbumistStore(url: dir.appendingPathComponent("albumist.sqlite"))
        let s = try setup(store: store)
        let filling = DiskFillingAnalyzer(base: s.analyzer, store: store, after: 25)
        let pipeline = s.pipeline(analyzer: filling)

        let first = ProgressReports()
        var failedOnFullDisk = false
        do {
            _ = try await pipeline.run(onProgress: first.onProgress)
        } catch let error as SQLiteError {
            failedOnFullDisk = true
            #expect(error.code == 13, "\(error)") // SQLITE_FULL
        }
        #expect(failedOnFullDisk, "The run did not meet the full disk")
        let shownFirst = CardAsTheAppShowsIt.readings(first.values, goingOnFrom: nil)
        let marker = try #require(shownFirst.marker)
        #expect(marker.stage == AnalysisPipeline.Stage.content.number)
        let stoppedAt = try #require(marker.completed)
        #expect(stoppedAt > 0 && stoppedAt < s.photos)

        // Space again (the app was in the background): the run on return goes on by itself.
        try await store.freeDiskForTest()
        let second = ProgressReports()
        let after = try await pipeline.run(onProgress: second.onProgress)
        #expect(after.isComplete)
        let shownSecond = CardAsTheAppShowsIt.readings(second.values, goingOnFrom: marker)
        // The first count on return is where the run stopped, in the step the card names.
        #expect(shownSecond.readings.first.map { [$0.step, $0.done, $0.total] }
                == [AnalysisStep.content.number, stoppedAt, s.photos])
        let readings = shownFirst.readings + shownSecond.readings
        for (i, earlier) in readings.enumerated() {
            for later in readings[(i + 1)...] {
                let back = later.step < earlier.step
                    || (later.step == earlier.step && later.total == earlier.total && later.done < earlier.done)
                #expect(!back, "The card went back: (step \(earlier.step), \(earlier.done) of \(earlier.total)) -> (step \(later.step), \(later.done) of \(later.total))")
                if back { return }
            }
        }
    }
}

extension DeviceConditionRunTests {
    /// A marker of an older version has no count: while catching up the card shows none (the
    /// step it names, "Gleich wieder bei Schritt 4 von 6"), never the count of the step it re-reads.
    @Test func catchingUpFromAMarkerWithoutCountShowsNoCount() {
        var i = AnalysisCardState.Inputs()
        i.isRunning = true
        i.position = AnalysisCardState.Position(step: .library, completed: 246, total: 246)
        i.catchingUp(stage: AnalysisPipeline.Stage.content.number, completed: nil, total: nil)
        guard case .running(let shown?, _, _, let catchingUp)? = AnalysisCardState.resolve(i) else {
            Issue.record("not a running card with a position")
            return
        }
        #expect(catchingUp == AnalysisStep.content.number)
        #expect(shown.step == .content)
        #expect(!shown.hasCount)
    }
}

/// Every progress report of one run, in order.
final class ProgressReports: Sendable {
    private let seen = Locked<[AnalysisPipeline.Progress]>([])
    var onProgress: @Sendable (AnalysisPipeline.Progress) -> Void {
        { progress in self.seen.withLock { $0.append(progress) } }
    }
    var values: [AnalysisPipeline.Progress] { seen.withLock { $0 } }
}

/// The analyzer of `-AlbumistUITestDiskFull analysis` (`UITestAnalyzer`): the disk is full from
/// the `after`th photo looked at on (once; space comes back with `freeDiskForTest`).
final class DiskFillingAnalyzer: ContentAnalyzing, Sendable {
    let base: FakeContentAnalyzer
    let store: AlbumistStore
    let after: Int
    private let analysed = Locked(0)

    init(base: FakeContentAnalyzer, store: AlbumistStore, after: Int) {
        self.base = base
        self.store = store
        self.after = after
    }

    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        let result = try await base.analyzeContent(asset, request: request)
        if analysed.withLock({ $0 += 1; return $0 }) == after { try await store.fillDiskForTest() }
        return result
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        try await base.recognizeText(asset, allowNetwork: allowNetwork)
    }
}

/// The analysis card as AppModel feeds it, over the reports of one run: a count never goes back
/// within a stage nor a stage (`receive`), a run that goes on from the marker of the run before
/// (`ResumedRun`, catching up while it is on the steps before), the marker kept like
/// `AnalysisMarker.unfinished`, and the state from `AnalysisCardState.resolve` (`updateCard`).
/// Read as `DeviceConditionUITests.analysisCount` reads the progress element: the step the card
/// names ("Gleich wieder bei Schritt 4 von 6" while catching up) and the count shown.
enum CardAsTheAppShowsIt {
    struct Marker: Equatable {
        var stage: Int
        var completed: Int?
        var total: Int?
    }

    static func readings(_ reports: [AnalysisPipeline.Progress], goingOnFrom resumeFrom: Marker?)
        -> (readings: [(step: Int, done: Int, total: Int)], marker: Marker?) {
        var resumed = resumeFrom.map { ResumedRun(stage: $0.stage, completed: $0.completed, shown: 0) }
        var marker = resumeFrom
        var stage: AnalysisPipeline.Stage?
        var completed = 0
        var readings: [(step: Int, done: Int, total: Int)] = []
        for p in reports {
            if let stage {
                if p.stage.number < stage.number { continue }
                if p.stage == stage, p.completed < completed { continue }
            }
            stage = p.stage
            completed = p.completed
            resumed?.back(at: p.stage.number, completed: p.completed, total: p.total)
            let held = resumed?.holds(running: true) == true ? resumeFrom : nil
            marker = held ?? Marker(stage: p.stage.number, completed: p.completed, total: p.total)
            var i = AnalysisCardState.Inputs()
            i.isRunning = true
            i.position = AnalysisCardState.Position(step: AnalysisStep(p.stage), completed: p.completed, total: p.total)
            if resumed?.isCatchingUp(running: true, at: p.stage.number) == true, let resumeFrom {
                i.catchingUp(stage: resumeFrom.stage, completed: resumeFrom.completed, total: resumeFrom.total)
            }
            guard case .running(let position, _, _, let catchingUp)? = AnalysisCardState.resolve(i),
                  let position, position.hasCount else { continue }
            readings.append((catchingUp ?? position.step.number, position.completed, position.total))
        }
        return (readings, marker)
    }
}

/// A full disk for the database file underneath the store (as `DataSafetyTests` does it in
/// the store's own tests): SQLite then fails with SQLITE_FULL, as on a full iPhone.
extension AlbumistStore {
    func fillDiskForTest() throws {
        let used = try db.query("PRAGMA page_count").first?["page_count"]?.int ?? 0
        try db.execute("PRAGMA max_page_count = \(used)")
    }

    func freeDiskForTest() throws {
        try db.execute("PRAGMA max_page_count = 1073741823")
    }

    func integrityReportForTest() throws -> String {
        try db.query("PRAGMA integrity_check").map { $0.values.first?.string ?? "?" }.joined(separator: "; ")
    }
}
