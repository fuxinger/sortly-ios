import Foundation

/// A place where the user photographs repeatedly (prompt §4.3).
/// SORTLY never labels such a place as "home" or "work" by itself – it only reports facts.
public struct FrequentPlace: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var centroid: GeoCoordinate
    /// Radius covering 90 % of the photos, in metres.
    public var radiusMeters: Double
    public var assetIDs: [AssetID]
    public var distinctDays: Int
    public var firstDate: Date
    public var lastDate: Date
    /// Name given or confirmed by the user ("Zuhause", "Garten", ...). Never auto-filled.
    public var userName: String?

    public var photoCount: Int { assetIDs.count }
}

public struct FrequentPlaceDetector: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Neighbourhood radius for density clustering. Larger values treat a large
        /// premises as one place ("großes Gelände"), smaller values separate neighbours.
        public var clusterRadiusMeters: Double = 120
        public var minPhotosPerCore: Int = 4
        /// Minimum number of different days with photos.
        public var minDistinctDays: Int = 5
        /// Minimum time between first and last visit.
        public var minSpan: TimeInterval = 14 * 86_400
        /// Clusters whose centroids are closer than this are merged (user option).
        public var mergeRadiusMeters: Double = 0

        public init() {}
    }

    public var configuration: Configuration
    public var calendar: Calendar

    public init(configuration: Configuration = .init(), calendar: Calendar = .sortlyDefault) {
        self.configuration = configuration
        self.calendar = calendar
    }

    public func detect(in assets: [AssetSnapshot]) -> [FrequentPlace] {
        let usable = assets.compactMap { asset -> (AssetSnapshot, GeoCoordinate, Date)? in
            guard let c = asset.usableLocation, let d = asset.creationDate else { return nil }
            return (asset, c, d)
        }
        guard !usable.isEmpty else { return [] }

        let clusterer = GeoClusterer(epsilonMeters: configuration.clusterRadiusMeters, minPoints: configuration.minPhotosPerCore)
        var groups = clusterer.cluster(usable.map(\.1)).clusters.map(\.memberIndices)

        if configuration.mergeRadiusMeters > 0 {
            groups = mergeNearby(groups, coordinates: usable.map(\.1))
        }

        let places = groups.compactMap { indices -> FrequentPlace? in
            let members = indices.map { usable[$0] }
            let days = Set(members.map { calendar.startOfDay(for: $0.2) })
            guard days.count >= configuration.minDistinctDays,
                  let first = members.map(\.2).min(), let last = members.map(\.2).max(),
                  last.timeIntervalSince(first) >= configuration.minSpan,
                  let centroid = GeoMath.centroid(members.map(\.1))
            else { return nil }
            let distances = members.map { GeoMath.distance($0.1, centroid) }.sorted()
            let p90 = distances[min(distances.count - 1, Int(Double(distances.count) * 0.9))]
            let ids = members.map(\.0.id).sorted()
            return FrequentPlace(
                id: .stable("frequent", String(format: "%.3f,%.3f", centroid.latitude, centroid.longitude)),
                centroid: centroid,
                radiusMeters: max(p90, 25),
                assetIDs: ids,
                distinctDays: days.count,
                firstDate: first,
                lastDate: last,
                userName: nil
            )
        }
        return places.sorted { ($0.distinctDays, $0.photoCount) > ($1.distinctDays, $1.photoCount) }
    }

    private func mergeNearby(_ groups: [[Int]], coordinates: [GeoCoordinate]) -> [[Int]] {
        var merged: [[Int]] = []
        var centroids: [GeoCoordinate] = []
        for group in groups {
            guard let c = GeoMath.centroid(group.map { coordinates[$0] }) else { continue }
            if let target = centroids.firstIndex(where: { GeoMath.distance($0, c) <= configuration.mergeRadiusMeters }) {
                merged[target].append(contentsOf: group)
                centroids[target] = GeoMath.centroid(merged[target].map { coordinates[$0] }) ?? centroids[target]
            } else {
                merged.append(group)
                centroids.append(c)
            }
        }
        return merged
    }
}

public extension Calendar {
    /// Gregorian calendar in the device time zone, Monday as first weekday (ISO 8601 weeks).
    static var sortlyDefault: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = .current
        return calendar
    }
}
