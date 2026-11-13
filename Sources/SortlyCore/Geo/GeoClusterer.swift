import Foundation

/// Spatial hash index for radius queries on geographic points.
public struct GeoSpatialIndex<Element: Sendable>: Sendable {
    public struct Entry: Sendable {
        public let index: Int
        public let coordinate: GeoCoordinate
        public let element: Element
    }

    public let cellSize: Double
    private var cells: [GeoCell: [Int]] = [:]
    public private(set) var entries: [Entry] = []

    public init(cellSize: Double, points: [(GeoCoordinate, Element)]) {
        self.cellSize = cellSize
        entries.reserveCapacity(points.count)
        for (i, point) in points.enumerated() {
            entries.append(Entry(index: i, coordinate: point.0, element: point.1))
            cells[GeoCell(point.0, sizeMeters: cellSize), default: []].append(i)
        }
    }

    /// All entries within `radius` metres of `center` (radius must be ≤ cellSize).
    public func query(near center: GeoCoordinate, radius: Double) -> [Entry] {
        precondition(radius <= cellSize + 1e-6, "radius must not exceed the index cell size")
        let latStep = radius / GeoMath.metersPerDegreeLatitude
        let lonStep = latStep / max(cos(center.latitude * .pi / 180), 0.01)
        var visited = Set<GeoCell>()
        var result: [Entry] = []
        let factors: [Double] = [-1, -0.5, 0, 0.5, 1]
        for fy in factors {
            for fx in factors {
                let sample = GeoCoordinate(
                    latitude: max(-90, min(90, center.latitude + fy * latStep)),
                    longitude: normalizeLongitude(center.longitude + fx * lonStep)
                )
                let cell = GeoCell(sample, sizeMeters: cellSize)
                guard visited.insert(cell).inserted, let indices = cells[cell] else { continue }
                for i in indices where GeoMath.distance(entries[i].coordinate, center) <= radius {
                    result.append(entries[i])
                }
            }
        }
        return result
    }

    private func normalizeLongitude(_ lon: Double) -> Double {
        var l = lon
        while l > 180 { l -= 360 }
        while l < -180 { l += 360 }
        return l
    }
}

/// Density-based clustering (DBSCAN) on geographic points with a spatial index,
/// so the cost stays close to linear for photo libraries with 100k+ geotagged items.
public struct GeoClusterer: Sendable {
    public struct Cluster: Sendable, Hashable {
        public var memberIndices: [Int]
        public var centroid: GeoCoordinate
        /// 90th percentile distance of members to the centroid, in metres.
        public var radius90: Double
    }

    public var epsilonMeters: Double
    public var minPoints: Int

    public init(epsilonMeters: Double, minPoints: Int) {
        self.epsilonMeters = epsilonMeters
        self.minPoints = max(1, minPoints)
    }

    /// Returns clusters (sorted by size, descending) and indices of noise points.
    public func cluster(_ coordinates: [GeoCoordinate]) -> (clusters: [Cluster], noise: [Int]) {
        let index = GeoSpatialIndex(cellSize: epsilonMeters, points: coordinates.map { ($0, ()) })
        var labels = [Int](repeating: -2, count: coordinates.count) // -2 unvisited, -1 noise
        var clusterCount = 0

        for i in coordinates.indices where labels[i] == -2 {
            let neighbours = index.query(near: coordinates[i], radius: epsilonMeters)
            if neighbours.count < minPoints {
                labels[i] = -1
                continue
            }
            let clusterID = clusterCount
            clusterCount += 1
            labels[i] = clusterID
            var queue = neighbours.map(\.index)
            var head = 0
            while head < queue.count {
                let j = queue[head]
                head += 1
                if labels[j] == -1 { labels[j] = clusterID }
                guard labels[j] == -2 else { continue }
                labels[j] = clusterID
                let jNeighbours = index.query(near: coordinates[j], radius: epsilonMeters)
                if jNeighbours.count >= minPoints {
                    queue.append(contentsOf: jNeighbours.map(\.index).filter { labels[$0] < 0 })
                }
            }
        }

        var members = [[Int]](repeating: [], count: clusterCount)
        var noise: [Int] = []
        for (i, label) in labels.enumerated() {
            if label >= 0 { members[label].append(i) } else { noise.append(i) }
        }
        let clusters = members.compactMap { indices -> Cluster? in
            guard let centroid = GeoMath.centroid(indices.map { coordinates[$0] }) else { return nil }
            let distances = indices.map { GeoMath.distance(coordinates[$0], centroid) }.sorted()
            let p90 = distances.isEmpty ? 0 : distances[min(distances.count - 1, Int(Double(distances.count) * 0.9))]
            return Cluster(memberIndices: indices, centroid: centroid, radius90: p90)
        }
        .sorted { $0.memberIndices.count > $1.memberIndices.count }
        return (clusters, noise)
    }
}
