import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The fast grid DBSCAN must give the same result as the textbook algorithm.
@Suite("DBSCAN equivalence")
struct ClusteringEquivalenceTests {
    /// Textbook DBSCAN with brute-force neighbour search (the previous implementation's logic).
    static func reference(_ coordinates: [GeoCoordinate], eps: Double, minPoints: Int) -> (clusters: [[Int]], noise: [Int]) {
        func neighbours(_ i: Int) -> [Int] { coordinates.indices.filter { GeoMath.distance(coordinates[i], coordinates[$0]) <= eps } }
        var labels = [Int](repeating: -2, count: coordinates.count)
        var clusterCount = 0
        for i in coordinates.indices where labels[i] == -2 {
            let n = neighbours(i)
            if n.count < minPoints { labels[i] = -1; continue }
            let id = clusterCount
            clusterCount += 1
            labels[i] = id
            var queue = n
            var head = 0
            while head < queue.count {
                let j = queue[head]; head += 1
                if labels[j] == -1 { labels[j] = id }
                guard labels[j] == -2 else { continue }
                labels[j] = id
                let nj = neighbours(j)
                if nj.count >= minPoints { queue.append(contentsOf: nj.filter { labels[$0] < 0 }) }
            }
        }
        var members = [[Int]](repeating: [], count: clusterCount)
        var noise: [Int] = []
        for (i, l) in labels.enumerated() { if l >= 0 { members[l].append(i) } else { noise.append(i) } }
        return (members.sorted { $0.count > $1.count }, noise)
    }

    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func scatter(_ center: GeoCoordinate, count: Int, meters: Double, rng: inout LCG) -> [GeoCoordinate] {
        (0..<count).map { _ in
            let dLat = Double.random(in: -1...1, using: &rng) * meters / GeoMath.metersPerDegreeLatitude
            let dLon = Double.random(in: -1...1, using: &rng) * meters / (GeoMath.metersPerDegreeLatitude * cos(center.latitude * .pi / 180))
            return GeoCoordinate(latitude: center.latitude + dLat, longitude: center.longitude + dLon)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func sameResultAsTextbookDBSCAN(seed: Int) {
        var rng = LCG(state: UInt64(seed) &* 0x9E3779B97F4A7C15)
        var points: [GeoCoordinate] = []
        let centers = [Fixture.Places.munichHome, Fixture.Places.munichWork, Fixture.Places.rome, Fixture.Places.sydney,
                       GeoCoordinate(latitude: 64.14, longitude: -21.94), GeoCoordinate(latitude: -16.5, longitude: 179.99)]
        for (k, center) in centers.enumerated() {
            points += Self.scatter(center, count: 20 + (seed * 37 + k * 11) % 150, meters: Double(40 + (seed + k) % 5 * 60), rng: &rng)
            points += Self.scatter(center, count: 12, meters: 900, rng: &rng) // thin edges and border points
        }
        points.shuffle(using: &rng)
        for (eps, minPoints) in [(120.0, 4), (60.0, 3), (300.0, 6), (15_000.0, 3)] {
            let fast = GeoClusterer(epsilonMeters: eps, minPoints: minPoints).cluster(points)
            let expected = Self.reference(points, eps: eps, minPoints: minPoints)
            #expect(fast.clusters.map(\.memberIndices) == expected.clusters, "eps \(eps) minPoints \(minPoints)")
            #expect(fast.noise == expected.noise, "eps \(eps) minPoints \(minPoints)")
        }
    }

    @Test func denseHomeClusterIsFast() {
        var rng = LCG(state: 42)
        let points = Self.scatter(Fixture.Places.munichHome, count: 20_000, meters: 60, rng: &rng)
        let clock = ContinuousClock()
        var result: (clusters: [GeoClusterer.Cluster], noise: [Int]) = ([], [])
        let elapsed = clock.measure { result = GeoClusterer(epsilonMeters: 120, minPoints: 4).cluster(points) }
        #expect(result.clusters.count == 1)
        #expect(result.clusters.first?.memberIndices.count == 20_000)
        #expect(elapsed < .seconds(3))
    }
}
