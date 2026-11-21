import Foundation
import Synchronization
import Testing
@testable import AlbumistCore
import AlbumistWorldMap
import AlbumistTestSupport

@Suite("Place resolution")
struct PlaceResolutionTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    func requests(_ place: GeoCoordinate, count: Int, prefix: String, priority: Int = 0) -> [PlaceResolutionService.Request] {
        (0..<count).map { i in
            .init(assetID: AssetID("\(prefix)-\(i)"), coordinate: Fixture.jitter(place, seed: i, meters: 300), priority: priority)
        }
    }

    func service(level: PlaceLevel, geocoder: FakeGeocoder?, cache: MemoryPlaceCache = MemoryPlaceCache(), throttle: RequestThrottle = .apple, time: TimeSource = ManualTime().source, online: Bool = true) -> PlaceResolutionService {
        PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: cache,
            policy: PlaceResolutionPolicy(deepestLevel: level, onlineAllowed: online, language: .german),
            throttle: throttle, time: time
        )
    }

    @Test func countriesNeedNoOnlineRequests() async throws {
        let geocoder = FakeGeocoder()
        let collector = ResultCollector()
        let outcome = try await service(level: .country, geocoder: geocoder)
            .resolve(requests(Fixture.Places.munichHome, count: 30, prefix: "m") + requests(Fixture.Places.rome, count: 20, prefix: "r")) { await collector.add($0) }
        #expect(geocoder.calls.isEmpty)
        #expect(outcome.resolved == 50)
        let places = await collector.places
        #expect(places[AssetID("m-0")]?.components.country == "Deutschland")
        #expect(places[AssetID("r-0")]?.components.isoCountryCode == "IT")
        #expect(places[AssetID("r-0")]?.precisionMeters == nil)
    }

    @Test func townsUseOneRequestPerCellAndOfflineNames() async throws {
        let geocoder = FakeGeocoder()
        let collector = ResultCollector()
        let outcome = try await service(level: .locality, geocoder: geocoder)
            .resolve(requests(Fixture.Places.munichHome, count: 30, prefix: "m") + requests(Fixture.Places.rome, count: 20, prefix: "r")) { await collector.add($0) }
        #expect(outcome.onlineRequests <= 4) // jitter may straddle a 5 km cell edge
        #expect(outcome.pendingOnline.isEmpty)
        let munich = await collector.places[AssetID("m-3")]
        #expect(munich?.components.locality == "München")
        #expect(munich?.components.country == "Deutschland")      // offline name, not "Germany"
        #expect(munich?.components.administrativeArea == "Bayern") // offline name, not "Bavaria"
        #expect(munich?.precisionMeters == 5_000)
        #expect(munich?.needsRefinement(to: 1_000) == true)
    }

    /// Stress run 43833158673: 50,000 photos stood at "0 von 50.233 Orten" for a minute, then
    /// jumped. Places from the map are now saved and counted in parts; each count is reported
    /// only after its places are saved, and it never goes down.
    @Test func manyOfflinePlacesAreSavedAndCountedInParts() async throws {
        actor Log {
            var saved = 0
            var events: [(saved: Int, counted: Int)] = []
            func save(_ n: Int) { saved += n }
            func count(_ n: Int) { events.append((saved, n)) }
        }
        let log = Log()
        let n = 2 * PlaceResolutionService.offlineChunk + 500
        let all = requests(Fixture.Places.rome, count: n, prefix: "r")
        let outcome = try await service(level: .country, geocoder: FakeGeocoder())
            .resolve(all, progress: { await log.count($0) }) { await log.save($0.count) }
        #expect(outcome.resolved == n)
        let events = await log.events
        #expect(events.count >= 3, "counted only \(events.count) times")
        #expect(events.last?.counted == n)
        for (i, e) in events.enumerated() {
            #expect(e.counted <= e.saved, "counted before saved")
            if i > 0 { #expect(e.counted >= events[i - 1].counted) }
        }
    }

    /// Review of d612bc0: Pause had no effect during the pass over the map. It stops at the next
    /// part; what is saved stays, the rest is pending for the next run.
    @Test func pauseStopsTheMapPassAtTheNextPart() async throws {
        actor Saved { var ids = Set<AssetID>(); func add(_ b: [AssetID: ResolvedPlace]) { ids.formUnion(b.keys) } }
        let saved = Saved()
        let flag = Locked(false)
        let n = 3 * PlaceResolutionService.offlineChunk
        let all = requests(Fixture.Places.rome, count: n, prefix: "r")
        let outcome = try await service(level: .country, geocoder: FakeGeocoder())
            .resolve(all, checked: { _ in flag.withLock { $0 = true } }, paused: { flag.withLock { $0 } }) { await saved.add($0) }
        let ids = await saved.ids
        #expect(ids.count == PlaceResolutionService.offlineChunk, "saved \(ids.count)")
        #expect(outcome.pendingOnline.count == n - ids.count)
        #expect(outcome.pendingOnline.isDisjoint(with: ids))
    }

    /// Review of d612bc0: a refinement saved the map's country over a stored town before its
    /// lookup; when the lookup did not happen (offline, Pause) the town was lost. A photo with
    /// a town never gets anything coarser.
    @Test func refinementNeverSavesACountryOverATown() async throws {
        let collector = ResultCollector()
        let towns = requests(Fixture.Places.rome, count: 20, prefix: "t").map {
            PlaceResolutionService.Request(assetID: $0.assetID, coordinate: $0.coordinate, hasTown: true)
        }
        let fresh = requests(Fixture.Places.rome, count: 5, prefix: "f")
        _ = try await service(level: .locality, geocoder: FakeGeocoder(failures: [.offline]))
            .resolve(towns + fresh, refining: true) { await collector.add($0) }
        let places = await collector.places
        #expect(towns.allSatisfy { places[$0.assetID] == nil }, "a town was overwritten")
        #expect(fresh.allSatisfy { places[$0.assetID]?.components.country == "Italien" })
    }

    /// Review of 9f0bc40 (C): at town level a Pause left the photos with their country from the
    /// map; the next run checked them again and its "geprüft" count started lower. They count
    /// as checked from the start now, and the count only rises.
    @Test func checkedCountGoesOnAfterAPause() async throws {
        actor Log { var counts: [Int] = []; func add(_ n: Int) { counts.append(n) } }
        let n = 3 * PlaceResolutionService.offlineChunk
        let all = requests(Fixture.Places.rome, count: n, prefix: "r")
        // First run: paused after the second part.
        let first = Log()
        let parts = Locked(0)
        _ = try await service(level: .locality, geocoder: FakeGeocoder(failures: [.offline]))
            .resolve(all, checked: { await first.add($0); parts.withLock { $0 += 1 } }, paused: { parts.withLock { $0 >= 2 } }) { _ in }
        let lastShown = try #require(await first.counts.last)
        #expect(lastShown == 2 * PlaceResolutionService.offlineChunk)
        // Next run: what has its country is passed on as such.
        let next = Log()
        let again = all.enumerated().map { i, r in
            PlaceResolutionService.Request(assetID: r.assetID, coordinate: r.coordinate, hasCountry: i < lastShown)
        }
        _ = try await service(level: .locality, geocoder: FakeGeocoder(failures: [.offline]))
            .resolve(again, checked: { await next.add($0) }) { _ in }
        let counts = await next.counts
        #expect(counts.first == lastShown, "started at \(counts.first ?? -1) after \(lastShown)")
        #expect(counts == counts.sorted() && counts.last == n)
    }

    @Test func cachedCellsAreNotRequestedAgain() async throws {
        let cache = MemoryPlaceCache()
        let first = FakeGeocoder()
        _ = try await service(level: .locality, geocoder: first, cache: cache).resolve(requests(Fixture.Places.rome, count: 10, prefix: "r")) { _ in }
        let second = FakeGeocoder()
        let outcome = try await service(level: .locality, geocoder: second, cache: cache).resolve(requests(Fixture.Places.rome, count: 10, prefix: "x")) { _ in }
        #expect(second.calls.isEmpty)
        #expect(outcome.cacheHits >= 1)
    }

    @Test func cellsWithoutResultAreRememberedToo() async throws {
        let cache = MemoryPlaceCache()
        let first = FakeGeocoder(answers: []) // e.g. a lake: the geocoder knows no town there
        let collector = ResultCollector()
        let outcome = try await service(level: .locality, geocoder: first, cache: cache)
            .resolve(requests(Fixture.Places.rome, count: 10, prefix: "r")) { await collector.add($0) }
        #expect(!first.calls.isEmpty)
        #expect(outcome.pendingOnline.isEmpty)
        let rome = await collector.places[AssetID("r-0")]
        #expect(rome?.components.country == "Italien")
        #expect(rome?.components.locality == nil)
        let second = FakeGeocoder(answers: [])
        _ = try await service(level: .locality, geocoder: second, cache: cache)
            .resolve(requests(Fixture.Places.rome, count: 10, prefix: "x")) { _ in }
        #expect(second.calls.isEmpty)
    }

    @Test func bordersAreConfirmedOnline() async throws {
        let geocoder = FakeGeocoder()
        let collector = ResultCollector()
        let basel = GeoCoordinate(latitude: 47.5903, longitude: 7.5893)
        _ = try await service(level: .country, geocoder: geocoder).resolve([.init(assetID: "b", coordinate: basel)]) { await collector.add($0) }
        #expect(geocoder.calls.count == 1)
        let place = await collector.places[AssetID("b")]
        #expect(place?.components.isoCountryCode == "CH")
        #expect(place?.components.country == "Schweiz")
    }

    @Test func offlineStopsOnlineButKeepsCountries() async throws {
        let geocoder = FakeGeocoder(failures: [.offline])
        let collector = ResultCollector()
        let outcome = try await service(level: .locality, geocoder: geocoder)
            .resolve(requests(Fixture.Places.munichHome, count: 5, prefix: "m") + requests(Fixture.Places.rome, count: 5, prefix: "r")) { await collector.add($0) }
        #expect(outcome.stoppedBecauseOffline)
        #expect(geocoder.calls.count == 1)
        #expect(outcome.pendingOnline.count == 10)
        let places = await collector.places
        #expect(places.count == 10)
        #expect(places.values.allSatisfy { $0.components.locality == nil && $0.components.country != nil })
    }

    @Test func onlineDisabledByPrivacySetting() async throws {
        let geocoder = FakeGeocoder()
        let outcome = try await service(level: .locality, geocoder: geocoder, online: false).resolve(requests(Fixture.Places.rome, count: 5, prefix: "r")) { _ in }
        #expect(geocoder.calls.isEmpty)
        #expect(outcome.pendingOnline.count == 5)
    }

    /// Audit 2, 5.2: consent is read again before every online lookup.
    @Test func consentIsCheckedBeforeEveryLookup() async throws {
        let geocoder = FakeGeocoder()
        let places = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]
        let reqs = places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
        let outcome = try await service(level: .locality, geocoder: geocoder)
            .resolve(reqs, onlineAllowed: { geocoder.calls.count < 2 }) { _ in }
        #expect(geocoder.calls.count == 2)
        #expect(outcome.pendingOnline.count == 3)
    }

    @Test func throttleSpacesRequests() async throws {
        let time = ManualTime()
        let geocoder = FakeGeocoder()
        let places = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]
        let reqs = places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
        _ = try await service(level: .locality, geocoder: geocoder, throttle: RequestThrottle(maxRequests: 2, window: .seconds(60)), time: time.source).resolve(reqs) { _ in }
        #expect(geocoder.calls.count == 5)
        #expect(time.now.withLock { $0 } >= .seconds(120))
    }

    /// Device test 18.11. (build 36): a run in the app never waits for the throttle. It asks
    /// while a slot is free, without sleeping, and leaves the rest pending for a later run.
    @Test func aCallThatMayNotWaitAsksOnlyWhileASlotIsFree() async throws {
        let time = ManualTime()
        let sleeps = Locked(0)
        let counting = TimeSource(elapsed: time.source.elapsed, sleep: { d in sleeps.withLock { $0 += 1 }; try await time.source.sleep(d) })
        let geocoder = FakeGeocoder()
        let places = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]
        let reqs = places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
        let collector = ResultCollector()
        let outcome = try await service(level: .locality, geocoder: geocoder, throttle: RequestThrottle(maxRequests: 2, window: .seconds(60)), time: counting)
            .resolve(reqs, mayWait: false) { await collector.add($0) }
        #expect(geocoder.calls.count == 2)
        #expect(sleeps.withLock { $0 } == 0)
        #expect(time.now.withLock { $0 } == .zero)
        #expect(outcome.onlineRequests == 2)
        #expect(outcome.stoppedAtRequestLimit)
        #expect(!outcome.stoppedBecauseThrottled)
        #expect(outcome.pendingOnline.count == 3)
        // The two asked got their towns; the others keep their country from the map.
        let towns = await collector.places.values.filter { $0.components.locality != nil }
        #expect(towns.count == 2)
        #expect(await collector.places.count == 5)
    }

    /// The requests of an earlier call on the same log count: a run right after a run does not
    /// ask more often in the minute than the throttle allows.
    @Test func requestsOfAnEarlierCallCountForTheWindow() async throws {
        let time = ManualTime()
        let log = RequestLog()
        let throttle = RequestThrottle(maxRequests: 3, window: .seconds(60))
        let geocoder = FakeGeocoder()
        func service() -> PlaceResolutionService {
            PlaceResolutionService(map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
                                   policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german),
                                   throttle: throttle, time: time.source, requestLog: log)
        }
        let first = try await service().resolve([.init(assetID: "a", coordinate: Fixture.Places.munichHome),
                                                 .init(assetID: "b", coordinate: Fixture.Places.rome)], mayWait: false) { _ in }
        #expect(first.onlineRequests == 2)
        #expect(log.count(at: time.now.withLock { $0 }, throttle) == 2)
        let places = [Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]
        let second = try await service().resolve(places.enumerated().map { .init(assetID: AssetID("c\($0.offset)"), coordinate: $0.element) },
                                                  mayWait: false) { _ in }
        #expect(second.onlineRequests == 1)
        #expect(second.stoppedAtRequestLimit)
        #expect(second.pendingOnline.count == 2)
        #expect(time.now.withLock { $0 } == .zero)
        // A minute later the window is free again.
        time.now.withLock { $0 += .seconds(60) }
        #expect(log.count(at: time.now.withLock { $0 }, throttle) == 0)
    }

    /// A refusal stops a call that may not wait at once: no retry, no sleep, whatever Apple's
    /// `retryAfter` says.
    @Test func aCallThatMayNotWaitStopsAtTheFirstRefusal() async throws {
        let time = ManualTime()
        let geocoder = FakeGeocoder(failures: [.rateLimited(retryAfter: 0)])
        let places = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence]
        let reqs = places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
        let outcome = try await service(level: .locality, geocoder: geocoder, time: time.source)
            .resolve(reqs, mayWait: false) { _ in }
        #expect(geocoder.calls.count == 1)
        #expect(time.now.withLock { $0 } == .zero)
        #expect(outcome.stoppedBecauseThrottled)
        #expect(outcome.pendingOnline.count == 3)
    }

    /// A call that may not wait stops asking at the first cell without a free slot, also when
    /// a slot would be free again for a later cell (a slow run: the minute moves on while it
    /// goes through the cells). The rest comes with a later run, in priority order.
    @Test func aCallThatMayNotWaitStopsAtTheFirstFullThrottle() async throws {
        let clock = Locked<Duration>(.zero)
        // Every look at the clock is 25 s later: the third request finds both slots taken,
        // the fourth would find one free again.
        let slow = TimeSource(elapsed: { clock.withLock { $0 += .seconds(25); return $0 } },
                              sleep: { d in clock.withLock { $0 += d } })
        let geocoder = FakeGeocoder()
        let places = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]
        let reqs = places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
        let outcome = try await service(level: .locality, geocoder: geocoder, throttle: RequestThrottle(maxRequests: 2, window: .seconds(60)), time: slow)
            .resolve(reqs, mayWait: false) { _ in }
        #expect(geocoder.calls.count == 2)
        #expect(outcome.stoppedAtRequestLimit)
        #expect(outcome.pendingOnline.count == 3)
    }

    /// After a wait for its slot, a call takes the slot anew instead of writing itself into the
    /// log: when another caller took the slot that came free meanwhile, it waits again, and the
    /// minute never holds more requests than the throttle allows (second review, SF5).
    @Test func aSlotTakenDuringTheWaitIsWaitedForAgain() async throws {
        let now = Locked<Duration>(.zero)
        let log = RequestLog()
        let throttle = RequestThrottle(maxRequests: 1, window: .seconds(60))
        #expect(log.take(at: .zero, throttle) == nil)
        let tookFreedSlot = Locked(false)
        let time = TimeSource(elapsed: { now.withLock { $0 } }, sleep: { d in
            let t = now.withLock { $0 += d; return $0 }
            // Just as the slot comes free, someone else takes it.
            if t >= .seconds(60), !tookFreedSlot.withLock({ $0 }) {
                tookFreedSlot.withLock { $0 = true }
                #expect(log.take(at: t, throttle) == nil)
            }
        })
        let geocoder = FakeGeocoder()
        let service = PlaceResolutionService(map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
                                             policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german),
                                             throttle: throttle, time: time, requestLog: log)
        _ = try await service.resolve([.init(assetID: "a", coordinate: Fixture.Places.rome)]) { _ in }
        #expect(geocoder.calls.count == 1)
        #expect(tookFreedSlot.withLock { $0 })
        // Waited for the next slot, a minute after the one the other caller took.
        #expect(now.withLock { $0 } >= .seconds(120))
        #expect(log.count(at: now.withLock { $0 }, throttle) <= throttle.maxRequests)
    }

    @Test func rateLimitIsRetried() async throws {
        let time = ManualTime()
        let geocoder = FakeGeocoder(failures: [.rateLimited(retryAfter: 42)])
        let collector = ResultCollector()
        let outcome = try await service(level: .locality, geocoder: geocoder, time: time.source)
            .resolve([.init(assetID: "r", coordinate: Fixture.Places.rome)]) { await collector.add($0) }
        #expect(geocoder.calls.count == 2)
        #expect(outcome.pendingOnline.isEmpty)
        #expect(time.now.withLock { $0 } >= .seconds(42))
        #expect(await collector.places[AssetID("r")]?.components.locality == "Rom")
    }

    @Test func highPriorityCellsGoFirstAndBudgetIsRespected() async throws {
        let geocoder = FakeGeocoder()
        let reqs = requests(Fixture.Places.munichHome, count: 50, prefix: "home") + requests(Fixture.Places.rome, count: 3, prefix: "trip", priority: 10)
        let outcome = try await service(level: .locality, geocoder: geocoder).resolve(reqs, maxOnlineRequests: 1) { _ in }
        #expect(geocoder.calls.count == 1)
        #expect(GeoMath.distance(geocoder.calls[0], Fixture.Places.rome) < 2_000)
        #expect(outcome.pendingOnline.contains(AssetID("home-0")))
    }

    @Test func pauseStopsOnlineLookupsButCountriesStillResolve() async throws {
        let geocoder = FakeGeocoder()
        let collector = ResultCollector()
        let reqs = requests(Fixture.Places.munichHome, count: 10, prefix: "home") + requests(Fixture.Places.rome, count: 10, prefix: "trip", priority: 10)
        let outcome = try await service(level: .locality, geocoder: geocoder)
            .resolve(reqs, shouldStop: { true }) { await collector.add($0) }
        #expect(geocoder.calls.isEmpty)
        #expect(outcome.pendingOnline.contains(AssetID("trip-0")))
        // The country is known offline and kept, even though the town is still open.
        #expect(await collector.places[AssetID("trip-0")]?.components.isoCountryCode == "IT")
    }

    @Test func borrowedTownFromAnotherCountryIsDropped() async {
        let s = service(level: .locality, geocoder: nil)
        let munich = Self.map.lookup(Fixture.Places.munichHome)
        let swissTown = PlaceComponents(isoCountryCode: "CH", country: "Schweiz", locality: "Basel")
        let merged = await s.merge(online: swissTown, offline: munich, at: Fixture.Places.munichHome)
        #expect(merged?.townIsValid == false)
        #expect(merged?.components.locality == nil)
        #expect(merged?.components.isoCountryCode == "DE")
    }

    @Test func refinementUsesFinerCells() {
        let policy = PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german)
        #expect(policy.cellMeters(refining: false) == 5_000)
        #expect(policy.cellMeters(refining: true) == 1_000)
        var fine = policy
        fine.deepestLevel = .subLocality
        #expect(fine.cellMeters(refining: false) == 400)
        var settings = OrganizationSettings()
        settings.enabledAreas = [.places]
        settings.places.levels = [.country]
        #expect(PlaceResolutionPolicy(settings: settings).deepestLevel == .country)
    }
}
