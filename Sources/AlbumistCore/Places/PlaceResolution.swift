import Foundation
import Synchronization

/// Online reverse geocoding (Apple's geocoder, `CLGeocoder`, on iOS). Implementations throw `GeocodingError`.
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
            language: settings.titleLanguage
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
    /// observed ceiling for CLGeocoder/MapKit, so Albumist stays below it.
    public static let apple = RequestThrottle(maxRequests: 40, window: .seconds(60))
    public init(maxRequests: Int, window: Duration) {
        self.maxRequests = maxRequests
        self.window = window
    }
}

/// When the geocoder was asked, shared by every lookup of one pipeline: a run that starts
/// within a minute of the run before knows the requests that run made, so a run in the app
/// never asks more often than the throttle allows without waiting (device test 18.11., build 36).
public final class RequestLog: Sendable {
    private let times = Locked<[Duration]>([])
    public init() {}

    /// Takes a slot at `now` when one is free (fewer than `maxRequests` in the window).
    /// Otherwise how long until the oldest request leaves the window.
    func take(at now: Duration, _ throttle: RequestThrottle) -> Duration? {
        times.withLock { times in
            times.removeAll { now - $0 >= throttle.window }
            if times.count >= throttle.maxRequests, let oldest = times.first {
                return throttle.window - (now - oldest)
            }
            times.append(now)
            return nil
        }
    }

    /// Requests made within the window before `now`.
    public func count(at now: Duration, _ throttle: RequestThrottle) -> Int {
        times.withLock { times in times.filter { now - $0 < throttle.window }.count }
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
        /// The photo has a town already (a refinement asks for a finer one): nothing coarser
        /// is ever saved over it, not the map's country before the lookup, nor a country after
        /// a lookup whose town was dropped (review of d612bc0: a stopped refinement lost towns).
        public var hasTown: Bool
        /// The photo got its country from the map in an earlier run and waits for its town:
        /// the map pass does not check it again, it counts as checked from the start (review
        /// of 9f0bc40: after a Pause the "geprüft" count started lower again).
        public var hasCountry: Bool
        public init(assetID: AssetID, coordinate: GeoCoordinate, priority: Int = 0, hasTown: Bool = false, hasCountry: Bool = false) {
            self.assetID = assetID
            self.coordinate = coordinate
            self.priority = priority
            self.hasTown = hasTown
            self.hasCountry = hasCountry
        }
    }

    public struct Outcome: Sendable, Hashable {
        public var resolved = 0
        /// Assets that still need an online lookup (offline, disabled, rate limit, budget). Not
        /// those in `withoutCountry`.
        public var pendingOnline: Set<AssetID> = []
        public var onlineRequests = 0
        public var cacheHits = 0
        public var stoppedBecauseOffline = false
        /// Apple's geocoder kept refusing (rate limit): the remaining cells wait for a later run.
        public var stoppedBecauseThrottled = false
        /// The run's lookup limit ran out while cells that were neither cached nor asked remained.
        public var stoppedAtRequestLimit = false
        /// Asking stopped early because the run was paused (or got too hot, or the battery ran low).
        public var stoppedAsking = false
        /// Photos without a country that cannot get one (review P1-09): the lookup answered
        /// "nothing here" (open sea) and the map knows no country there, or their country needs
        /// the online lookup and the user has switched it off. Not photos that only wait for it
        /// (offline, refused, the run's limit, Pause): those are in `pendingOnline`.
        public var withoutCountry: Set<AssetID> = []
        /// Every request was looked at (no Pause or cancellation before the end):
        /// `withoutCountry` is then complete for these requests.
        public var reachedAll = true
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
    private let requestLog: RequestLog
    /// Told how long a wait for the geocoder still takes, and `nil` when it is over (see `resolve`).
    private var onWait: (@Sendable (Duration?) async -> Void)?
    /// Longest single sleep between two checks of `shouldStop`: Pause, heat or the end of the
    /// app's time interrupt a wait for the geocoder within seconds, not after minutes.
    static let waitSlice: Duration = .seconds(2)
    /// The pass over the offline map is saved, said (`checked`) and checked for Pause in
    /// parts of this size.
    static let offlineChunk = 1_000

    public init(
        map: OfflineWorldMap?,
        geocoder: (any ReverseGeocoding)?,
        cache: any PlaceCaching,
        policy: PlaceResolutionPolicy,
        throttle: RequestThrottle = .apple,
        time: TimeSource = .live(),
        requestLog: RequestLog = RequestLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.requestLog = requestLog
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
    ///
    /// After a refusal (rate limit) a call that may wait asks again up to three times, with
    /// growing waits; still refused, no more online lookups are made in this call and the rest
    /// is reported as pending.
    ///
    /// `progress`: how many requests are final (resolved, or not resolvable). Requests left
    /// for a later call (budget, refusal, offline, Pause) are not counted.
    ///
    /// `waiting`: called every 2 s while this call waits for the geocoder (its limit of about
    /// 40 lookups a minute, or a refusal) with the time left, and with `nil` when it goes on.
    ///
    /// `mayWait`: false for a run in the app, which never waits for the geocoder (device test
    /// 18.11., build 36: "Apple antwortet gleich" with the count standing for 20–30 s). It asks
    /// only while the throttle has a free slot (the requests of earlier calls on the same
    /// `RequestLog` count) and stops at the first refusal; the rest is reported as pending
    /// (`stoppedAtRequestLimit`, `stoppedBecauseThrottled`).
    public func resolve(
        _ requests: [Request],
        refining: Bool = false,
        maxOnlineRequests: Int? = nil,
        mayWait: Bool = true,
        shouldStop: (@Sendable () async -> Bool)? = nil,
        onlineAllowed: (@Sendable () async -> Bool)? = nil,
        progress: (@Sendable (Int) async -> Void)? = nil,
        checked: (@Sendable (Int) async -> Void)? = nil,
        paused: (@Sendable () -> Bool)? = nil,
        waiting: (@Sendable (Duration?) async -> Void)? = nil,
        sink: Sink
    ) async throws -> Outcome {
        var outcome = Outcome()
        onWait = waiting
        defer { onWait = nil }
        // How many requests are final (resolved, or not resolvable). A country known early from
        // the map does not count yet when the town still needs the online lookup, so the count
        // rises with the real work (first device test 15.11.: "5.683 von 5.683" showed at once
        // while the lookups had only begun). Requests left for a later run do not count either:
        // they are looked up again there, and that run's count starts where this one ended
        // instead of below it (simulated full run: Pause in step 3 jumped to "1.615 von 1.615",
        // the run that went on started at "271 von 1.615").
        var processed = 0
        var offlineOnly: [AssetID: ResolvedPlace] = [:]
        // Checked against the map in an earlier run (country saved, town still open, which
        // needs the online lookup at any level that asks for towns): straight to the lookups.
        let checkedBefore = requests.filter { $0.hasCountry && !$0.hasTown && policy.deepestLevel >= .locality }
        let toCheck = checkedBefore.isEmpty ? requests : requests.filter { !($0.hasCountry && !$0.hasTown && policy.deepestLevel >= .locality) }
        var needsOnline: [Request] = checkedBefore
        var offlineCache: [GeoCell: OfflineWorldMap.Match] = [:]

        // Every place saved from the map, so a town found later is not counted a second time
        // (review of d612bc0: 8,500 resolved for 4,500 photos once the map pass came in parts).
        var savedFromMap = Set<AssetID>()
        // In parts of `offlineChunk`: saved, then counted, then said (`checked`), and Pause is
        // looked at. 50,000 photos at once stood at "0 von 50.233 Orten" for a minute
        // (stress run 43833158673); with towns on (the default) none of them is final before
        // its lookup, so `checked` is the honest sign of life of this pass.
        if !checkedBefore.isEmpty { await checked?(checkedBefore.count) }
        for (index, r) in toCheck.enumerated() {
            if index > 0, index % Self.offlineChunk == 0 {
                if !offlineOnly.isEmpty {
                    try await sink(offlineOnly)
                    outcome.resolved += offlineOnly.count
                    savedFromMap.formUnion(offlineOnly.keys)
                    offlineOnly.removeAll(keepingCapacity: true)
                }
                let final = index - (needsOnline.count - checkedBefore.count)
                if final > processed {
                    processed = final
                    await progress?(processed)
                }
                await checked?(checkedBefore.count + index)
                // Pause: what is saved stays; the rest is asked for again by the next run.
                if paused?() == true || Task.isCancelled {
                    outcome.pendingOnline.formUnion(toCheck[index...].map(\.assetID))
                    outcome.pendingOnline.formUnion(needsOnline.map(\.assetID))
                    outcome.reachedAll = false
                    return outcome
                }
            }
            guard r.coordinate.isPlausible else { continue }
            let match = offlineMatch(r.coordinate, memo: &offlineCache)
            if !requiresOnline(match) {
                if let components = match?.components(language: policy.language) {
                    offlineOnly[r.assetID] = ResolvedPlace(components: components, source: .gpsReverseGeocoded, resolvedAt: now())
                }
            } else {
                needsOnline.append(r)
                // Country/region are useful right away, even before the town is known (but never
                // over a town the photo has already).
                if !r.hasTown, let match, match.countryIsCertain, let c = match.components(language: policy.language) {
                    offlineOnly[r.assetID] = ResolvedPlace(components: c, source: .gpsReverseGeocoded, resolvedAt: now())
                }
            }
        }
        if !offlineOnly.isEmpty {
            try await sink(offlineOnly)
            outcome.resolved += offlineOnly.count
            savedFromMap.formUnion(offlineOnly.keys)
            offlineOnly.removeAll(keepingCapacity: true)
        }
        processed = requests.count - needsOnline.count
        await progress?(processed)
        await checked?(requests.count)

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
        // The user switched the online lookup off (not offline, refused or paused).
        var switchedOff = !policy.onlineAllowed
        /// Has no country and gets none in this call.
        func hasNoCountry(_ member: Request) -> Bool {
            !member.hasTown && !member.hasCountry && !savedFromMap.contains(member.assetID)
        }
        for (cell, members) in groups {
            let pendingBefore = outcome.pendingOnline.count
            if Task.isCancelled { outcome.pendingOnline.formUnion(members.map(\.assetID)); outcome.reachedAll = false; continue }
            // Pause, heat or low battery: no more online lookups; cached cells still count.
            if !onlineDisabled, let shouldStop, await shouldStop() { onlineDisabled = true; outcome.stoppedAsking = true }
            // The user's consent is read again before every online lookup: switching it off in
            // the settings stops the next request, not only the next run (audit 2, 5.2).
            if !onlineDisabled, let onlineAllowed, !(await onlineAllowed()) { onlineDisabled = true; switchedOff = true }
            // The cell's answer is for this photo of it (also when it comes from the cache: the
            // members of a cell hardly move): a town from across a disputed line is not taken.
            let representative = Self.representative(of: members.map(\.coordinate))
            var online = try await cache.cachedPlace(cell: cell)
            if online != nil {
                outcome.cacheHits += 1
            } else if !onlineDisabled, maxOnlineRequests.map({ outcome.onlineRequests < $0 }) ?? true, let geocoder {
                switch await request(geocoder, representative, mayWait: mayWait, shouldStop: shouldStop) {
                case .found(let components):
                    outcome.onlineRequests += 1
                    // "Nothing here" (open sea, a lake, wilderness) is remembered as an empty
                    // answer, so the cell is not asked again every night.
                    let answer = components ?? PlaceComponents()
                    online = answer
                    try await cache.cachePlace(answer, cell: cell, resolvedAt: now())
                case .offline:
                    outcome.onlineRequests += 1
                    onlineDisabled = true
                    outcome.stoppedBecauseOffline = true
                case .throttled:
                    // Asking the next cell would only be refused as well (and wait again).
                    outcome.onlineRequests += 1
                    onlineDisabled = true
                    outcome.stoppedBecauseThrottled = true
                case .stopped:
                    onlineDisabled = true
                    outcome.stoppedAsking = true
                case .noSlot:
                    // A run in the app does not wait for the throttle: the rest of the towns
                    // come with a later run, as when the run's lookup limit is used up.
                    onlineDisabled = true
                    outcome.stoppedAtRequestLimit = true
                case .failed:
                    outcome.onlineRequests += 1
                }
            } else if !onlineDisabled, geocoder != nil {
                // Not cached and not asked: the run's lookup limit is used up.
                outcome.stoppedAtRequestLimit = true
            }
            guard let online else {
                // Without a country and with the lookup switched off they wait for nothing: not
                // "später genauer bestimmt" (second review of P1-09). Turned on, they are asked.
                let outOfReach = switchedOff ? Set(members.filter(hasNoCountry).map(\.assetID)) : []
                outcome.withoutCountry.formUnion(outOfReach)
                outcome.pendingOnline.formUnion(members.map(\.assetID).filter { !outOfReach.contains($0) })
                continue
            }
            var batch: [AssetID: ResolvedPlace] = [:]
            let sample = offlineMatch(representative, memo: &offlineCache)
            for member in members {
                let match = offlineMatch(member.coordinate, memo: &offlineCache)
                guard let merged = merge(online: online, offline: match, at: member.coordinate, sample: sample) else {
                    // An empty answer will not get better by asking again.
                    if online != PlaceComponents() {
                        outcome.pendingOnline.insert(member.assetID)
                    } else if hasNoCountry(member) {
                        outcome.withoutCountry.insert(member.assetID)
                    }
                    continue
                }
                if member.hasTown, !merged.townIsValid {
                    // Only a country came back: the stored town stays.
                    outcome.pendingOnline.insert(member.assetID)
                    continue
                }
                batch[member.assetID] = ResolvedPlace(components: merged.components, source: .gpsReverseGeocoded, resolvedAt: now(), precisionMeters: merged.townIsValid ? cellMeters : nil)
                if !merged.townIsValid { outcome.pendingOnline.insert(member.assetID) }
            }
            if !batch.isEmpty {
                try await sink(batch)
                outcome.resolved += batch.keys.filter { !savedFromMap.contains($0) }.count
            }
            let final = members.count - (outcome.pendingOnline.count - pendingBefore)
            if final > 0 {
                processed += final
                await progress?(processed)
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
        guard let match, match.country != nil || match.disputedArea != nil, match.countryIsCertain else { return true }
        if policy.deepestLevel >= .locality { return true }
        if policy.deepestLevel >= .administrativeArea && !match.regionIsCertain { return true }
        return false
    }

    /// Country and region always come from the offline map when it is certain, so names
    /// stay identical across sources and languages; the town comes from the online cell.
    ///
    /// `sample`: the map's answer for the point the online answer was asked for (the cell's
    /// representative). Where it lies on the other side of a disputed line than `coordinate`,
    /// the online town is not this photo's (second review of 752ba07).
    func merge(online: PlaceComponents, offline: OfflineWorldMap.Match?, at coordinate: GeoCoordinate,
               sample: OfflineWorldMap.Match? = nil) -> (components: PlaceComponents, townIsValid: Bool)? {
        var result = online
        var townIsValid = true
        if let area = offline?.disputedArea {
            // A disputed area: Apple names the country by the country of the device, Albumist
            // takes no side (decision Fuchs 18.11.2026). The town stays, if it is from the area.
            if let sample, sample.disputedArea != area {
                return (PlaceComponents(timeZoneIdentifier: online.timeZoneIdentifier).inDisputedArea(area, language: policy.language), false)
            }
            return (online.inDisputedArea(area, language: policy.language), true)
        }
        if let offline, offline.countryIsCertain, let country = offline.country {
            let borrowed = online.isoCountryCode.map { $0.uppercased() != country.isoCode.uppercased() } ?? false
            if borrowed || sample?.disputedArea != nil {
                // The coarse cell's representative lies in another country or in a disputed
                // area: keep this photo's own country, drop the borrowed town and refine later.
                result = PlaceComponents(isoCountryCode: country.isoCode, timeZoneIdentifier: online.timeZoneIdentifier)
                townIsValid = false
            }
            result.isoCountryCode = country.isoCode
            result.country = country.name(policy.language)
            if offline.regionIsCertain, let region = offline.region {
                result.administrativeArea = region.name(policy.language)
            }
        } else if let map, let code = online.isoCountryCode {
            // The map is not sure (a border, the sea): Apple's answer decides the side, but an
            // answer in a disputed area is still "nicht sicher" (second review of 752ba07: a
            // Kherson photo near Crimea became "Russland", a Serbian one "Kosovo").
            let country = map.country(code: code)
            let region = map.region(coordinate, inCountryCode: code)
            if let area = DisputedAreas.area(mapCountry: country?.nameEN, mapRegion: region?.region.isoCode)
                ?? DisputedAreas.area(outlineContaining: coordinate, mapCountry: country?.nameEN) {
                return (online.inDisputedArea(area, language: policy.language), true)
            }
            if let country { result.country = country.name(policy.language) }
            if let region, region.isCertain {
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

    enum Lookup: Equatable {
        case found(PlaceComponents?)
        case offline
        /// Still refused after the retries (or at once, for a call that may not wait).
        case throttled
        /// Pause, heat or the end of the app's time while waiting.
        case stopped
        /// The throttle has no free slot and the call may not wait for one (`mayWait`).
        case noSlot
        case failed
    }

    private func request(
        _ geocoder: any ReverseGeocoding, _ coordinate: GeoCoordinate,
        mayWait: Bool, shouldStop: (@Sendable () async -> Bool)?
    ) async -> Lookup {
        var backoff: Duration = .seconds(30)
        let attempts = 4
        for attempt in 1...attempts {
            switch await waitForSlot(mayWait: mayWait, shouldStop) {
            case .taken: break
            case .stopped: return .stopped
            case .full: return .noSlot
            }
            do {
                return .found(try await geocoder.reverseGeocode(coordinate))
            } catch let error as GeocodingError {
                switch error {
                case .rateLimited(let retryAfter):
                    // Refused: a run in the app stops asking at once instead of waiting.
                    if attempt == attempts || !mayWait { return .throttled }
                    let wait = retryAfter.map { Duration.milliseconds(Int64($0 * 1000)) } ?? backoff
                    backoff = min(backoff * 2, .seconds(600))
                    guard await pause(for: wait, shouldStop) else { return .stopped }
                case .offline:
                    return .offline
                case .failed:
                    return .failed
                }
            } catch {
                return .failed
            }
        }
        return .throttled
    }

    /// Sleeps in short slices and asks `shouldStop` between them. False: stopped.
    /// Each slice is announced with the time left, and the end of the wait too: without it the
    /// count stood still for up to a minute while the run waited (simulated full run: 48 s at
    /// the limit of 40 lookups a minute, 30 s after a refusal), and looked stuck.
    private func pause(for duration: Duration, _ shouldStop: (@Sendable () async -> Bool)?) async -> Bool {
        var left = duration
        var stopped = false
        while left > .zero {
            if Task.isCancelled { stopped = true; break }
            if let shouldStop, await shouldStop() { stopped = true; break }
            await onWait?(left)
            let slice = min(left, Self.waitSlice)
            do { try await time.sleep(slice) } catch { stopped = true; break }
            left -= slice
        }
        if duration > .zero { await onWait?(nil) }
        return !stopped && !Task.isCancelled
    }

    enum Slot { case taken, stopped, full }

    /// Takes a slot of the throttle, waiting for one when all are used and `mayWait`. After a
    /// wait the slot is taken anew, not just written down: one that another caller took
    /// meanwhile is waited for again (second review of the no-wait fix, SF5).
    private func waitForSlot(mayWait: Bool, _ shouldStop: (@Sendable () async -> Bool)?) async -> Slot {
        while true {
            guard let wait = requestLog.take(at: time.elapsed(), throttle) else { return .taken }
            guard mayWait else { return .full }
            guard await pause(for: wait, shouldStop) else { return .stopped }
        }
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
