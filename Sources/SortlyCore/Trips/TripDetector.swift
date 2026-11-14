import Foundation

public enum TripKind: String, Sendable, Codable, CaseIterable {
    case dayTrip, weekendTrip, shortTrip, vacation, roadTrip
}

/// A detected trip (prompt §4.2). The date range is the span of the photos, not a proven
/// arrival/departure.
public struct Trip: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var start: Date
    public var end: Date
    /// Members with GPS evidence away from the habitual area.
    public var geotaggedAssetIDs: [AssetID]
    /// Members without GPS proposed only by time window. Always need confirmation.
    public var inferredAssetIDs: [AssetID]
    public var centroid: GeoCoordinate
    public var maxDistanceFromHomeMeters: Double
    /// Number of distinct overnight areas (~25 km cells with photos on ≥1 evening).
    public var distinctStops: Int
    public var kind: TripKind

    public var allAssetIDs: [AssetID] { geotaggedAssetIDs + inferredAssetIDs }
}

/// User corrections that survive re-analysis because they are expressed in time,
/// not in volatile ids (prompt §4.2: "Speichere solche Korrekturen dauerhaft").
public struct TripCorrections: Hashable, Sendable, Codable {
    /// Always split a trip at these instants.
    public var forcedBreaks: [Date] = []
    /// Never split inside these intervals (manual merge).
    public var forcedJoins: [DateInterval] = []
    /// Assets the user removed from trips.
    public var excludedAssets: Set<AssetID> = []

    public init(forcedBreaks: [Date] = [], forcedJoins: [DateInterval] = [], excludedAssets: Set<AssetID> = []) {
        self.forcedBreaks = forcedBreaks
        self.forcedJoins = forcedJoins
        self.excludedAssets = excludedAssets
    }
}

public struct TripDetector: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Photos closer than this to the habitual area count as "at home".
        public var homeRadiusMeters: Double = 30_000
        /// Split when there are no away-photos for longer than this.
        public var maxGap: TimeInterval = 3 * 86_400
        /// Longer allowed gap when both sides are far away and close to each other
        /// (long vacation with photo-less days).
        public var maxGapFarAway: TimeInterval = 7 * 86_400
        public var farAwayMeters: Double = 300_000
        /// A trip ends when the user is back home for longer than this.
        public var homeInterludeTolerance: TimeInterval = 10 * 3_600
        public var minPhotos: Int = 5
        /// Window around the trip in which non-GPS photos may be proposed.
        public var inferenceTolerance: TimeInterval = 2 * 3_600
        /// Window for the time-local habitual area (people move house).
        public var homeWindowDays: Int = 120

        public init() {}
    }

    public var configuration: Configuration
    public var calendar: Calendar

    public init(configuration: Configuration = .init(), calendar: Calendar = .sortlyDefault) {
        self.configuration = configuration
        self.calendar = calendar
    }

    /// - Parameters:
    ///   - assets: all assets (with and without GPS).
    ///   - corrections: persisted user corrections.
    ///   - excludeFromInference: returns true for assets that must never be added to a trip
    ///     purely by time (screenshots, messenger media, downloads – prompt §4.2).
    public func detect(
        in assets: [AssetSnapshot],
        corrections: TripCorrections = .init(),
        excludeFromInference: (AssetSnapshot) -> Bool = { _ in false }
    ) -> [Trip] {
        let geotagged = assets
            .filter { $0.usableLocation != nil && $0.creationDate != nil && !$0.isScreenshotLike && !corrections.excludedAssets.contains($0.id) }
            .sorted { ($0.creationDate!, $0.id) < ($1.creationDate!, $1.id) }
        guard !geotagged.isEmpty else { return [] }

        let home = HabitualArea(assets: geotagged, calendar: calendar, windowDays: configuration.homeWindowDays)

        struct Segment {
            var members: [AssetSnapshot] = []
            var lastAway: Date
            var lastCoordinate: GeoCoordinate
            var firstHomeAfterLastAway: Date?
        }

        var segments: [[AssetSnapshot]] = []
        var current: Segment?

        func joinProtects(_ a: Date, _ b: Date) -> Bool {
            corrections.forcedJoins.contains { $0.contains(a) && $0.contains(b) }
        }
        func forcedBreakBetween(_ a: Date, _ b: Date) -> Bool {
            corrections.forcedBreaks.contains { $0 > a && $0 <= b }
        }

        for asset in geotagged {
            let date = asset.creationDate!
            let coordinate = asset.usableLocation!
            let distanceHome = home.distanceToHome(coordinate, at: date)
            let isAway = distanceHome > configuration.homeRadiusMeters

            if isAway {
                if var seg = current {
                    let gap = date.timeIntervalSince(seg.lastAway)
                    let bothFar = distanceHome > configuration.farAwayMeters
                        && home.distanceToHome(seg.lastCoordinate, at: seg.lastAway) > configuration.farAwayMeters
                        && GeoMath.distance(coordinate, seg.lastCoordinate) < configuration.farAwayMeters / 2
                    let allowedGap = bothFar ? configuration.maxGapFarAway : configuration.maxGap
                    let cameHome = seg.firstHomeAfterLastAway.map { date.timeIntervalSince($0) > configuration.homeInterludeTolerance } ?? false
                    let protected = joinProtects(seg.lastAway, date)
                    let mustBreak = forcedBreakBetween(seg.lastAway, date)
                    if mustBreak || (!protected && (gap > allowedGap || cameHome)) {
                        segments.append(seg.members)
                        current = Segment(members: [asset], lastAway: date, lastCoordinate: coordinate)
                    } else {
                        seg.members.append(asset)
                        seg.lastAway = date
                        seg.lastCoordinate = coordinate
                        seg.firstHomeAfterLastAway = nil
                        current = seg
                    }
                } else {
                    current = Segment(members: [asset], lastAway: date, lastCoordinate: coordinate)
                }
            } else if var seg = current {
                if seg.firstHomeAfterLastAway == nil {
                    seg.firstHomeAfterLastAway = date
                    current = seg
                }
            }
        }
        if let seg = current { segments.append(seg.members) }

        let candidates = segments.filter { $0.count >= configuration.minPhotos }
        let nonGeo = assets
            .filter { $0.usableLocation == nil && $0.creationDate != nil && !$0.isScreenshotLike && ($0.kind == .image || $0.kind == .video) }
            .filter { !corrections.excludedAssets.contains($0.id) && !excludeFromInference($0) }
            .sorted { ($0.creationDate!, $0.id) < ($1.creationDate!, $1.id) }

        return candidates.map { members in
            makeTrip(members, home: home, nonGeo: nonGeo)
        }
    }

    private func makeTrip(_ members: [AssetSnapshot], home: HabitualArea, nonGeo: [AssetSnapshot]) -> Trip {
        let start = members.first!.creationDate!
        let end = members.last!.creationDate!
        let coordinates = members.map { $0.usableLocation! }
        let centroid = GeoMath.centroid(coordinates) ?? coordinates[0]
        let maxDistance = zip(members, coordinates).map { home.distanceToHome($1, at: $0.creationDate!) }.max() ?? 0

        // Inferred members: binary search the time window.
        let lower = start.addingTimeInterval(-configuration.inferenceTolerance)
        let upper = end.addingTimeInterval(configuration.inferenceTolerance)
        var lo = 0, hi = nonGeo.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if nonGeo[mid].creationDate! < lower { lo = mid + 1 } else { hi = mid }
        }
        var inferred: [AssetID] = []
        var i = lo
        while i < nonGeo.count, nonGeo[i].creationDate! <= upper {
            inferred.append(nonGeo[i].id)
            i += 1
        }

        let (kind, stops) = Self.classify(dates: members.map { $0.creationDate! }, coordinates: coordinates, calendar: calendar)

        return Trip(
            id: .stable("trip", members.first!.id.rawValue),
            start: start,
            end: end,
            geotaggedAssetIDs: members.map(\.id),
            inferredAssetIDs: inferred,
            centroid: centroid,
            maxDistanceFromHomeMeters: maxDistance,
            distinctStops: stops,
            kind: kind
        )
    }

    /// Kind of a trip from its photos (sorted by date) and the number of distinct overnight
    /// stops. Days and evening hours are counted in `calendar`, which should use the
    /// destination's time zone when it is known: an evening flight home across midnight is
    /// still a day trip there.
    public static func classify(dates: [Date], coordinates: [GeoCoordinate], calendar: Calendar) -> (kind: TripKind, stops: Int) {
        guard let start = dates.first, let end = dates.last else { return (.dayTrip, 1) }
        // Distinct stops: ~25 km cells where photos were taken in the evening/night.
        var stopCells = Set<GeoCell>()
        for (date, c) in zip(dates, coordinates) {
            let hour = calendar.component(.hour, from: date)
            if hour >= 18 || hour < 6 { stopCells.insert(GeoCell(c, sizeMeters: 25_000)) }
        }
        let allCells = Set(coordinates.map { GeoCell($0, sizeMeters: 25_000) })

        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let dayCount = (calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
        let kind: TripKind
        if dayCount == 1 {
            kind = .dayTrip
        } else if stopCells.count >= 3 && allCells.count >= 4 && dayCount >= 3 {
            kind = .roadTrip
        } else if dayCount <= 3 && (startDay...endDay).containsWeekend(calendar) {
            kind = .weekendTrip
        } else if dayCount <= 3 {
            kind = .shortTrip
        } else {
            kind = .vacation
        }
        return (kind, max(stopCells.count, 1))
    }

    /// The trips with kind and stops counted in their destination's time zone (the most
    /// common one among their photos' places), where that differs from `calendar`'s.
    public static func inDestinationTime(_ trips: [Trip], assets: [AssetID: AssetSnapshot], timeZones: [AssetID: String], calendar: Calendar) -> [Trip] {
        trips.map { trip in
            var counts: [String: Int] = [:]
            for id in trip.geotaggedAssetIDs { if let zone = timeZones[id] { counts[zone, default: 0] += 1 } }
            guard let identifier = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                  let zone = TimeZone(identifier: identifier), zone.identifier != calendar.timeZone.identifier else { return trip }
            var local = calendar
            local.timeZone = zone
            let members = trip.geotaggedAssetIDs.compactMap { assets[$0] }
                .compactMap { a -> (Date, GeoCoordinate)? in
                    guard let date = a.creationDate, let c = a.usableLocation else { return nil }
                    return (date, c)
                }
                .sorted { $0.0 < $1.0 }
            guard !members.isEmpty else { return trip }
            var result = trip
            (result.kind, result.distinctStops) = classify(dates: members.map(\.0), coordinates: members.map(\.1), calendar: local)
            return result
        }
    }
}

private extension ClosedRange where Bound == Date {
    func containsWeekend(_ calendar: Calendar) -> Bool {
        var day = lowerBound
        while day <= upperBound {
            if calendar.isDateInWeekend(day) { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return false
    }
}

/// The user's habitual area ("gewöhnlicher Aufenthaltsbereich"), computed time-locally
/// so that moving house does not turn the old or new home into a "trip".
/// It is an internal reference only and is never shown or labelled as "home".
struct HabitualArea: Sendable {
    private struct Day { let day: Date; let coordinate: GeoCoordinate; var cluster: Int }
    private var days: [Day] = []
    private var clusterCentroids: [GeoCoordinate] = []
    private let windowDays: Int
    private let calendar: Calendar
    private var homesByDay: [Date: [Int]] = [:]
    private var globalHome: Int?
    /// Photo days per cluster, ascending.
    private var clusterDays: [[Date]] = []
    private var requireSpread = false
    /// A place only counts as home when its photo days inside the window lie at least this
    /// far apart. A burst of holiday days (one trip, even a long one) never makes a place
    /// "home", which matters for people who mostly take photos while travelling.
    static let minimumHomeSpread: TimeInterval = 21 * 86_400

    init(assets: [AssetSnapshot], calendar: Calendar, windowDays: Int) {
        self.calendar = calendar
        self.windowDays = windowDays
        var perDay: [Date: [GeoCoordinate]] = [:]
        for asset in assets {
            guard let c = asset.usableLocation, let d = asset.creationDate else { continue }
            perDay[calendar.startOfDay(for: d), default: []].append(c)
        }
        // One representative point per day: the coordinate minimizing total distance (medoid
        // of a small sample) – robust against a single far-away photo that day.
        let dayPoints = perDay.map { day, coordinates -> (Date, GeoCoordinate) in
            let sample = Array(coordinates.prefix(15))
            let medoid = sample.min { a, b in
                sample.reduce(0) { $0 + GeoMath.distance($1, a) } < sample.reduce(0) { $0 + GeoMath.distance($1, b) }
            } ?? coordinates[0]
            return (day, medoid)
        }.sorted { $0.0 < $1.0 }

        let clusterer = GeoClusterer(epsilonMeters: 15_000, minPoints: 3)
        let result = clusterer.cluster(dayPoints.map(\.1))
        var labels = [Int](repeating: -1, count: dayPoints.count)
        for (ci, cluster) in result.clusters.enumerated() {
            for m in cluster.memberIndices { labels[m] = ci }
        }
        clusterCentroids = result.clusters.map(\.centroid)
        days = dayPoints.enumerated().map { Day(day: $1.0, coordinate: $1.1, cluster: labels[$0]) }
        clusterDays = Array(repeating: [], count: result.clusters.count)
        for d in days where d.cluster >= 0 { clusterDays[d.cluster].append(d.day) }
        // Spread is only demanded once some place shows it; a library of a few weeks keeps
        // the plain majority rule (otherwise its home would turn into one long trip).
        requireSpread = clusterDays.contains { ($0.last ?? .distantPast).timeIntervalSince($0.first ?? .distantPast) >= Self.minimumHomeSpread }

        var global: [Int: Int] = [:]
        for d in days where d.cluster >= 0 && isSpread(d.cluster, from: .distantPast, to: .distantFuture) {
            global[d.cluster, default: 0] += 1
        }
        if let best = global.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), best.value >= 5 { globalHome = best.key }

        // Sliding window over the sorted days: O(days) instead of O(days²).
        let window = Double(windowDays) * 86_400
        var lo = 0, hi = 0
        var counts: [Int: Int] = [:]
        for d in days {
            while hi < days.count && days[hi].day <= d.day.addingTimeInterval(window) {
                if days[hi].cluster >= 0 { counts[days[hi].cluster, default: 0] += 1 }
                hi += 1
            }
            while lo < hi && days[lo].day < d.day.addingTimeInterval(-window) {
                if days[lo].cluster >= 0 { counts[days[lo].cluster, default: 0] -= 1 }
                lo += 1
            }
            let lower = d.day.addingTimeInterval(-window), upper = d.day.addingTimeInterval(window)
            let candidates = counts.filter { $0.value > 0 && isSpread($0.key, from: lower, to: upper) }
            homesByDay[d.day] = Self.select(counts: candidates, total: hi - lo, fallback: globalHome)
        }
    }

    /// Home clusters around `date`: clusters holding ≥ 25 % of the photo days in the window.
    private func homeClusters(at date: Date) -> [Int] {
        let center = calendar.startOfDay(for: date)
        if let cached = homesByDay[center] { return cached }
        return computeHomeClusters(center: center)
    }

    private func computeHomeClusters(center: Date) -> [Int] {
        guard !days.isEmpty else { return [] }
        let lower = center.addingTimeInterval(-Double(windowDays) * 86_400)
        let upper = center.addingTimeInterval(Double(windowDays) * 86_400)
        var counts: [Int: Int] = [:]
        var total = 0
        for d in days where d.day >= lower && d.day <= upper {
            total += 1
            if d.cluster >= 0 { counts[d.cluster, default: 0] += 1 }
        }
        return Self.select(counts: counts.filter { isSpread($0.key, from: lower, to: upper) }, total: total, fallback: globalHome)
    }

    /// True if the cluster's photo days between `lower` and `upper` span at least `minimumHomeSpread`.
    private func isSpread(_ cluster: Int, from lower: Date, to upper: Date) -> Bool {
        guard requireSpread else { return true }
        let list = clusterDays[cluster]
        var lo = 0, hi = list.count
        while lo < hi { let mid = (lo + hi) / 2; if list[mid] < lower { lo = mid + 1 } else { hi = mid } }
        let first = lo
        lo = first; hi = list.count
        while lo < hi { let mid = (lo + hi) / 2; if list[mid] <= upper { lo = mid + 1 } else { hi = mid } }
        let last = lo - 1
        guard first < list.count, last >= first else { return false }
        return list[last].timeIntervalSince(list[first]) >= Self.minimumHomeSpread
    }

    private static func select(counts: [Int: Int], total: Int, fallback: Int?) -> [Int] {
        let threshold = max(3, Int(Double(total) * 0.25))
        let homes = counts.filter { $0.value >= threshold }.map(\.key).sorted()
        if homes.isEmpty, let fallback { return [fallback] }
        return homes
    }

    func distanceToHome(_ coordinate: GeoCoordinate, at date: Date) -> Double {
        let homes = homeClusters(at: date)
        guard !homes.isEmpty else { return .infinity }
        return homes.map { GeoMath.distance(clusterCentroids[$0], coordinate) }.min() ?? .infinity
    }
}
