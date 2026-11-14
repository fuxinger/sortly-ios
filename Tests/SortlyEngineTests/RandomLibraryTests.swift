import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Final stress test: many different, randomly built photo libraries (different homes,
/// sparse or busy everyday photos, 0 to 12 trips, some back to back, photos without place, screenshots,
/// existing albums) go through the whole cycle. Rules that must hold for every library:
/// suggestions only contain real photos, trips never share photos, every real trip is found,
/// a second analysis gives the same result, applying never touches a photo, every applied
/// suggestion ends up complete in its album, and undo restores the user's albums.
@Suite("Random libraries (final stress test)")
struct RandomLibraryTests {
    static let homes: [GeoCoordinate] = [
        Fixture.Places.munichHome,
        GeoCoordinate(latitude: 53.5511, longitude: 9.9937),   // Hamburg
        GeoCoordinate(latitude: 48.2082, longitude: 16.3738),  // Vienna
        GeoCoordinate(latitude: 47.3769, longitude: 8.5417),   // Zurich
        GeoCoordinate(latitude: 52.5200, longitude: 13.4050),  // Berlin
    ]

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    struct PlannedTrip {
        var start: Date
        var days: Int
        var destination: GeoCoordinate
        var photos: [AssetID]
    }

    struct Library {
        var assets: [AssetSnapshot]
        var trips: [PlannedTrip]
        var albums: [CollectionSnapshot]
        var description: String
    }

    static func day(_ base: String, plus days: Int) -> Date {
        Fixture.calendar.date(byAdding: .day, value: days, to: Fixture.date(base))!
    }

    static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Fixture.calendar
        f.timeZone = Fixture.utc
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func offset(_ c: GeoCoordinate, km: Double, bearing degrees: Double) -> GeoCoordinate {
        let rad = degrees * .pi / 180
        let lat = c.latitude + km / 111.0 * cos(rad)
        let lon = c.longitude + km / (111.0 * cos(c.latitude * .pi / 180)) * sin(rad)
        return GeoCoordinate(latitude: lat, longitude: lon)
    }

    /// A random but reproducible library for one seed.
    static func library(seed: Int) -> Library {
        var rng = Seeded(state: UInt64(seed) &* 0x2545F4914F6CDD1D)
        var lib = LibraryBuilder()
        let home = homes[Int.random(in: 0..<homes.count, using: &rng)]
        let farAway = LoadTests.destinations.filter { GeoMath.distance($0, home) > 400_000 }

        // Trips in distinct months of 2024 and 2025, 2 to 9 days each.
        let tripCount = Int.random(in: 0...6, using: &rng)
        let months = Array(Array(0..<24).shuffled(using: &rng).prefix(tripCount)).sorted()
        var plans: [(start: Date, days: Int, destination: GeoCoordinate, perDay: Int)] = []
        for month in months {
            let start = day("2024-01-05", plus: month * 30 + Int.random(in: 0..<10, using: &rng))
            // Mostly far away; sometimes a short trip 80 to 250 km from home (lakes, mountains).
            let near = Bool.random(using: &rng) && Bool.random(using: &rng)
            let destination = near
                ? offset(home, km: Double.random(in: 80...250, using: &rng), bearing: Double.random(in: 0..<360, using: &rng))
                : farAway[Int.random(in: 0..<farAway.count, using: &rng)]
            plans.append((start, Int.random(in: 2...9, using: &rng), destination, Int.random(in: 3...25, using: &rng)))
            // Sometimes a second trip right after: two days at home, then somewhere else.
            if Bool.random(using: &rng), let last = plans.last {
                let next = day(iso(last.start), plus: last.days + 2)
                let other = farAway.filter { GeoMath.distance($0, last.destination) > 400_000 }
                if let destination = other.randomElement(using: &rng) {
                    plans.append((next, Int.random(in: 2...6, using: &rng), destination, Int.random(in: 5...25, using: &rng)))
                }
            }
        }

        // Everyday life at home: busy (daily) or sparse (every few days), never during a trip.
        let skipping = plans.map { (iso($0.start), iso(day(iso($0.start), plus: $0.days - 1))) }
        let homePerDay = Int.random(in: 1...3, using: &rng)
        let everyNth = Int.random(in: 1...4, using: &rng)
        lib.daily(from: "2023-06-01", to: "2026-03-31", at: home, perDay: homePerDay, everyNthDay: everyNth, hour: 18, skipping: skipping)

        var trips: [PlannedTrip] = []
        for plan in plans {
            let ids = lib.daily(from: iso(plan.start), to: iso(day(iso(plan.start), plus: plan.days - 1)),
                                at: plan.destination, perDay: plan.perDay, hour: 9)
            trips.append(PlannedTrip(start: plan.start, days: plan.days, destination: plan.destination, photos: ids))
        }

        // Photos without a place, and screenshots, at random times.
        for _ in 0..<Int.random(in: 0...30, using: &rng) {
            _ = lib.photo(at: day("2023-06-01", plus: Int.random(in: 0..<1000, using: &rng)), nil)
        }
        for _ in 0..<Int.random(in: 0...20, using: &rng) {
            _ = lib.photo(at: day("2023-06-01", plus: Int.random(in: 0..<1000, using: &rng)), nil, subtypes: .screenshot)
        }

        // A few albums the user made, some of them with part of a trip.
        var albums: [CollectionSnapshot] = []
        for i in 0..<Int.random(in: 0...4, using: &rng) {
            let source = trips.isEmpty || Bool.random(using: &rng) ? lib.assets.map(\.id) : trips[Int.random(in: 0..<trips.count, using: &rng)].photos
            let members = Set(source.shuffled(using: &rng).prefix(Int.random(in: 1...max(1, source.count / 2), using: &rng)))
            albums.append(CollectionSnapshot(id: CollectionID("user-\(i)"), title: "Mein Album \(i)", assetIDs: members))
        }
        let description = "seed \(seed): \(lib.assets.count) photos, \(trips.count) trips, home \(homePerDay)/day every \(everyNth) days, \(albums.count) albums"
        return Library(assets: lib.assets, trips: trips, albums: albums, description: description)
    }

    func pipeline(_ library: Library, store: SortlyStore, reader: InMemoryLibraryReader) -> AnalysisPipeline {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        return AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(labels: { _ in [] }, text: { _ in "" }),
            geocoder: FakeGeocoder(), map: DecisionLifecycleTests.map, conditions: FakeConditions(pauseAfterChecks: nil),
            settings: settings, calendar: Fixture.calendar, time: ManualTime().source, batchSize: 200
        )
    }

    /// 16 libraries per run; `SORTLY_STRESS_SEEDS=500` checks more.
    static let seeds = Array(1...(ProcessInfo.processInfo.environment["SORTLY_STRESS_SEEDS"].flatMap(Int.init) ?? 16))

    @Test(arguments: seeds)
    func everyRuleHoldsForARandomLibrary(seed: Int) async throws {
        let library = Self.library(seed: seed)
        let note = Comment(rawValue: library.description)
        let all = Set(library.assets.map(\.id))
        let initial = CollectionInventory(library.albums)
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: library.assets, inventory: initial)
        let pipeline = pipeline(library, store: store, reader: reader)

        _ = try await pipeline.run()
        let snapshot = try #require(try await pipeline.latestProposals(), note)

        // 1. Suggestions contain only real photos, and have a name.
        for proposal in snapshot.proposals {
            #expect(!proposal.assetIDs.isEmpty, note)
            #expect(proposal.assetIDs.isSubset(of: all), note)
            #expect(!proposal.title.trimmingCharacters(in: .whitespaces).isEmpty, note)
        }

        // 2. Trips never share photos.
        let tripProposals = snapshot.proposals.filter { $0.kind == .trip }
        var seen: Set<AssetID> = []
        for trip in tripProposals {
            #expect(seen.isDisjoint(with: trip.assetIDs), "\(trip.title) shares photos with another trip. \(library.description)")
            seen.formUnion(trip.assetIDs)
        }

        // 3. Every real trip big enough for an album (10 photos by default) is found:
        //    one trip suggestion holds at least 80 % of its photos.
        let minimum = OrganizationSettings().trips.minPhotos
        for trip in library.trips where trip.photos.count >= minimum {
            let photos = Set(trip.photos)
            let best = tripProposals.map { $0.assetIDs.intersection(photos).count }.max() ?? 0
            #expect(best * 5 >= photos.count * 4,
                    "Trip \(Self.iso(trip.start)) (\(trip.days) days, \(photos.count) photos) found only \(best). \(library.description)")
        }

        // 4. A second analysis of the same library gives the same suggestions.
        _ = try await pipeline.run()
        let again = try #require(try await pipeline.latestProposals(), note)
        #expect(Set(again.proposals.map(\.id)) == Set(snapshot.proposals.map(\.id)), note)

        // 5. Matches only point at albums that exist.
        for match in snapshot.matches.values {
            if let best = match.best { #expect(initial[best.albumID] != nil, note) }
        }

        // 6. Applying the safe suggestions never touches a photo, and every applied
        //    suggestion is complete in its album afterwards.
        let lifecycle = DecisionLifecycleTests()
        let photoLibrary = InMemoryPhotoLibrary(assets: all, collections: library.albums)
        let world = DecisionLifecycleTests.World(store: store, reader: reader, library: photoLibrary, pipeline: pipeline,
                                                 rome: [], paris: [], all: all, initial: initial)
        let items = lifecycle.acceptSafe(snapshot)
        let executed = try await lifecycle.apply(items, in: world)
        #expect(executed.status == .completed, note)
        #expect(await photoLibrary.assets == all, note)
        let after = try await photoLibrary.currentInventory()
        let states = try await store.managedAlbums()
        for item in items {
            let state = states.first { $0.allSourceIDs.contains(item.proposal.id) }
            let members = state.flatMap { after[$0.albumID] }?.assetIDs ?? []
            #expect(item.proposal.assetIDs.isSubset(of: members), "\(item.proposal.title) is not complete in its album. \(library.description)")
        }

        // 7. Undo brings back exactly the albums the user had.
        let undo = lifecycle.confirmed(UndoPlanner().undoPlan(for: executed, current: after))
        let undone = try await ChangeExecutor(library: photoLibrary, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed, note)
        let restored = try await photoLibrary.currentInventory()
        #expect(Set(restored.albums.map(\.id)) == Set(initial.albums.map(\.id)), note)
        for album in initial.albums { #expect(restored[album.id] == album, note) }
    }
}
