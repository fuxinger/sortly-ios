import Foundation

/// Online reverse geocoding (MapKit on iOS). Implementations throw `GeocodingError`.
public protocol ReverseGeocoding: Sendable {
    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents?
}

public enum GeocodingError: Error, Equatable, Sendable {
    /// Apple throttles reverse geocoding; `retryAfter` in seconds when known.
    case rateLimited(retryAfter: Double?)
    case offline
    case failed
}

/// Persistent per-cell cache (implemented by the store).
public protocol PlaceCaching: Sendable {
    func cachedPlace(cell: GeoCell) async throws -> PlaceComponents?
    func cachePlace(_ components: PlaceComponents, cell: GeoCell, resolvedAt: Date) async throws
}

/// Which place details a run needs and how coarse the online raster may be (speed-up 2).
public struct PlaceResolutionPolicy: Hashable, Sendable {
    /// Deepest level any enabled area needs (places levels, trip names).
    public var deepestLevel: PlaceLevel
    public var onlineAllowed: Bool
    public var language: TitleLanguage
    /// Raster for town names in the first pass (≈ 5 km: a village may get the next town).
    public var fastCellMeters: Double = 5_000
    /// Raster for streets, districts and places of interest.
    public var fineCellMeters: Double = 400
    /// Raster of the overnight refinement pass for town names.
    public var refinedCellMeters: Double = 1_000

    public init(deepestLevel: PlaceLevel, onlineAllowed: Bool, language: TitleLanguage) {
        self.deepestLevel = deepestLevel
        self.onlineAllowed = onlineAllowed
        self.language = language
    }

    public init(settings: OrganizationSettings) {
        var deepest = settings.places.levels.max() ?? .country
        if settings.enabledAreas.contains(.trips) { deepest = max(deepest, .locality) }
        self.init(
            deepestLevel: deepest,
            onlineAllowed: settings.privacy.allowOnlineGeocoding,
            language: settings.titleLanguage == .deviceDefault ? (Locale.current.language.languageCode?.identifier == "de" ? .german : .english) : settings.titleLanguage
        )
    }

    public func cellMeters(refining: Bool) -> Double {
        if deepestLevel > .locality { return fineCellMeters }
        return refining ? refinedCellMeters : fastCellMeters
    }
}

/// Simple sliding-window limiter: at most `maxRequests` per `window`.
public struct RequestThrottle: Sendable, Hashable {
    public var maxRequests: Int
    public var window: Duration
    /// Apple does not publish an exact limit; ~50 requests per minute is the commonly
    /// observed ceiling for CLGeocoder/MapKit, so SORTLY stays below it.
    public static let apple = RequestThrottle(maxRequests: 40, window: .seconds(60))
    public init(maxRequests: Int, window: Duration) {
        self.maxRequests = maxRequests
        self.window = window
    }
}

/// Resolves photo coordinates to places: offline world map first, online geocoder only
/// where needed, one request per raster cell, cached, throttled and prioritized.
public actor PlaceResolutionService {
    public struct Request: Sendable, Hashable {
        public var assetID: AssetID
        public var coordinate: GeoCoordinate
        /// Higher first (trips and frequent places before everything else, speed-up 3).
        public var priority: Int
        public init(assetID: AssetID, coordinate: GeoCoordinate, priority: Int = 0) {
            self.assetID = assetID
            self.coordinate = coordinate
            self.priority = priority
        }
    }

    public struct Outcome: Sendable, Hashable {
        public var resolved = 0
        /// Assets that still need an online lookup (offline, disabled, rate limit, budget).
        public var pendingOnline: Set<AssetID> = []
        public var onlineRequests = 0
        public var cacheHits = 0
        public var stoppedBecauseOffline = false
        public init() {}
    }

    public typealias Sink = @Sendable ([AssetID: ResolvedPlace]) async throws -> Void

    private let map: OfflineWorldMap?
    private let geocoder: (any ReverseGeocoding)?
    private let cache: any PlaceCaching
    private let policy: PlaceResolutionPolicy
    private let throttle: RequestThrottle
    private let time: TimeSource
    private let now: @Sendable () -> Date
    private var requestTimes: [Duration] = []

    public init(
        map: OfflineWorldMap?,
        geocoder: (any ReverseGeocoding)?,
        cache: any PlaceCaching,
        policy: PlaceResolutionPolicy,
        throttle: RequestThrottle = .apple,
        time: TimeSource = .live(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.map = map
        self.geocoder = geocoder
        self.cache = cache
        self.policy = policy
        self.throttle = throttle
        self.time = time
        self.now = now
    }

    /// Resolves all requests. Results are handed to `sink` in batches as they arrive, so a
    /// paused or killed run keeps everything finished so far. Cancellation stops early and
    /// reports the rest as pending.
    public func resolve(
        _ requests: [Request],
        refining: Bool = false,
        maxOnlineRequests: Int? = nil,
        sink: Sink
    ) async throws -> Outcome {
        var outcome = Outcome()
        var offlineOnly: [AssetID: ResolvedPlace] = [:]
        var needsOnline: [Request] = []
        var offlineCache: [GeoCell: OfflineWorldMap.Match] = [:]

        for r in requests where r.coordinate.isPlausible {
            let match = offlineMatch(r.coordinate, memo: &offlineCache)
            if !requiresOnline(match) {
                if let components = match?.components(language: policy.language) {
                    offlineOnly[r.assetID] = ResolvedPlace(components: components, source: .gpsReverseGeocoded, resolvedAt: now())
                }
            } else {
                needsOnline.append(r)
                // Country/region are useful right away, even before the town is known.
                if let match, match.countryIsCertain, let c = match.components(language: policy.language) {
                    offlineOnly[r.assetID] = ResolvedPlace(components: c, source: .gpsReverseGeocoded, resolvedAt: now())
                }
            }
        }
        if !offlineOnly.isEmpty {
            try await sink(offlineOnly)
            outcome.resolved += offlineOnly.count
        }

        // One online request per raster cell, highest priority and biggest cells first.
        let cellMeters = policy.cellMeters(refining: refining)
        let groups = Dictionary(grouping: needsOnline) { GeoCell($0.coordinate, sizeMeters: cellMeters) }
            .sorted { a, b in
                let pa = a.value.map(\.priority).max() ?? 0, pb = b.value.map(\.priority).max() ?? 0
                if pa != pb { return pa > pb }
                if a.value.count != b.value.count { return a.value.count > b.value.count }
                return a.key.description < b.key.description
            }

        var onlineDisabled = !policy.onlineAllowed || geocoder == nil
        for (cell, members) in groups {
            if Task.isCancelled { outcome.pendingOnline.formUnion(members.map(\.assetID)); continue }
            var online = try await cache.cachedPlace(cell: cell)
            if online != nil {
                outcome.cacheHits += 1
            } else if !onlineDisabled, maxOnlineRequests.map({ outcome.onlineRequests < $0 }) ?? true, let geocoder {
                let representative = Self.representative(of: members.map(\.coordinate))
                switch await request(geocoder, representative) {
                case .success(let components):
                    outcome.onlineRequests += 1
                    online = components
                    if let components { try await cache.cachePlace(components, cell: cell, resolvedAt: now()) }
                case .failure(.offline):
                    outcome.onlineRequests += 1
                    onlineDisabled = true
                    outcome.stoppedBecauseOffline = true
                case .failure:
                    outcome.onlineRequests += 1
                }
            }
            guard let online else {
                outcome.pendingOnline.formUnion(members.map(\.assetID))
                continue
            }
            var batch: [AssetID: ResolvedPlace] = [:]
            for member in members {
                let match = offlineMatch(member.coordinate, memo: &offlineCache)
                guard let merged = merge(online: online, offline: match, at: member.coordinate) else {
                    outcome.pendingOnline.insert(member.assetID)
                    continue
                }
                batch[member.assetID] = ResolvedPlace(components: merged.components, source: .gpsReverseGeocoded, resolvedAt: now(), precisionMeters: merged.townIsValid ? cellMeters : nil)
                if !merged.townIsValid { outcome.pendingOnline.insert(member.assetID) }
            }
            if !batch.isEmpty {
                try await sink(batch)
                outcome.resolved += batch.count - batch.keys.filter { offlineOnly[$0] != nil }.count
            }
        }
        return outcome
    }

    // MARK: Decisions

    private func offlineMatch(_ c: GeoCoordinate, memo: inout [GeoCell: OfflineWorldMap.Match]) -> OfflineWorldMap.Match? {
        guard let map else { return nil }
        let cell = GeoCell(c, sizeMeters: 100)
        if let m = memo[cell] { return m }
        let m = map.lookup(c)
        memo[cell] = m
        return m
    }

    /// Online is needed for town-level names, at borders, or when the map knows nothing.
    func requiresOnline(_ match: OfflineWorldMap.Match?) -> Bool {
        guard let match, match.country != nil, match.countryIsCertain else { return true }
        if policy.deepestLevel >= .locality { return true }
        if policy.deepestLevel >= .administrativeArea && !match.regionIsCertain { return true }
        return false
    }

    /// Country and region always come from the offline map when it is certain, so names
    /// stay identical across sources and languages; the town comes from the online cell.
    func merge(online: PlaceComponents, offline: OfflineWorldMap.Match?, at coordinate: GeoCoordinate) -> (components: PlaceComponents, townIsValid: Bool)? {
        var result = online
        var townIsValid = true
        if let offline, offline.countryIsCertain, let country = offline.country {
            if let code = online.isoCountryCode, code.uppercased() != country.isoCode.uppercased() {
                // The coarse cell's representative lies in another country: keep this photo's
                // own country, drop the borrowed town and refine later.
                result = PlaceComponents(isoCountryCode: country.isoCode, timeZoneIdentifier: online.timeZoneIdentifier)
                townIsValid = false
            }
            result.isoCountryCode = country.isoCode
            result.country = country.name(policy.language)
            if offline.regionIsCertain, let region = offline.region {
                result.administrativeArea = region.name(policy.language)
            }
        } else if let map, let code = online.isoCountryCode {
            if let country = map.country(code: code) { result.country = country.name(policy.language) }
            if let region = map.region(coordinate, inCountryCode: code), region.isCertain {
                result.administrativeArea = region.region.name(policy.language)
            }
        }
        guard result.country != nil || result.isoCountryCode != nil else { return nil }
        return (result, townIsValid)
    }

    /// The member closest to the members' centroid, so the looked-up point is a real
    /// photo location (never an empty field in the middle of the cell).
    static func representative(of coordinates: [GeoCoordinate]) -> GeoCoordinate {
        guard let centroid = GeoMath.centroid(coordinates) else { return coordinates[0] }
        return coordinates.min { GeoMath.distance($0, centroid) < GeoMath.distance($1, centroid) } ?? coordinates[0]
    }

    // MARK: Throttled requests

    private func request(_ geocoder: any ReverseGeocoding, _ coordinate: GeoCoordinate) async -> Result<PlaceComponents?, GeocodingError> {
        var backoff: Duration = .seconds(30)
        for _ in 0..<4 {
            do {
                try await waitForSlot()
                return .success(try await geocoder.reverseGeocode(coordinate))
            } catch let error as GeocodingError {
                switch error {
                case .rateLimited(let retryAfter):
                    let wait = retryAfter.map { Duration.milliseconds(Int64($0 * 1000)) } ?? backoff
                    backoff = min(backoff * 2, .seconds(600))
                    do { try await time.sleep(wait) } catch { return .failure(.failed) }
                case .offline, .failed:
                    return .failure(error)
                }
            } catch {
                return .failure(.failed)
            }
        }
        return .failure(.rateLimited(retryAfter: nil))
    }

    private func waitForSlot() async throws {
        var current = time.elapsed()
        requestTimes.removeAll { current - $0 >= throttle.window }
        if requestTimes.count >= throttle.maxRequests, let oldest = requestTimes.first {
            try await time.sleep(throttle.window - (current - oldest))
            current = time.elapsed()
            requestTimes.removeAll { current - $0 >= throttle.window }
        }
        requestTimes.append(current)
    }
}

/// Elapsed time and sleeping, injectable so throttling is testable without waiting.
public struct TimeSource: Sendable {
    public var elapsed: @Sendable () -> Duration
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(elapsed: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.elapsed = elapsed
        self.sleep = sleep
    }

    public static func live() -> TimeSource {
        let clock = ContinuousClock()
        let start = clock.now
        return TimeSource(elapsed: { start.duration(to: clock.now) }, sleep: { try await clock.sleep(for: $0) })
    }
}
