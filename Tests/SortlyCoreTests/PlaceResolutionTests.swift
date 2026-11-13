import Foundation
import Testing
@testable import SortlyCore
import SortlyWorldMap
import SortlyTestSupport

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

    @Test func cachedCellsAreNotRequestedAgain() async throws {
        let cache = MemoryPlaceCache()
        let first = FakeGeocoder()
        _ = try await service(level: .locality, geocoder: first, cache: cache).resolve(requests(Fixture.Places.rome, count: 10, prefix: "r")) { _ in }
        let second = FakeGeocoder()
        let outcome = try await service(level: .locality, geocoder: second, cache: cache).resolve(requests(Fixture.Places.rome, count: 10, prefix: "x")) { _ in }
        #expect(second.calls.isEmpty)
        #expect(outcome.cacheHits >= 1)
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

    @Test func throttleSpacesRequests() async throws {
        let time = ManualTime()
        let geocoder = FakeGeocoder()
        let places = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]
        let reqs = places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
        _ = try await service(level: .locality, geocoder: geocoder, throttle: RequestThrottle(maxRequests: 2, window: .seconds(60)), time: time.source).resolve(reqs) { _ in }
        #expect(geocoder.calls.count == 5)
        #expect(time.now.withLock { $0 } >= .seconds(120))
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
