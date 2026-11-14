import Foundation
import SortlyCore
import SortlyStore

/// Snapshot of the latest proposals, stored so the app opens instantly (prompt §14).
public struct ProposalSnapshot: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var scope: OrganizationScope
    public var proposals: [AlbumProposal]
    public var matches: [SortlyID: MatchResult]
}

/// Runs the analysis stages in a fixed, resumable order (prompt §13, §14):
///
/// 1. inventory  – read assets and albums, detect new/changed/removed items
/// 2. patterns   – trips and frequent places from time and GPS only (no network)
/// 3. places     – offline map + throttled online lookups, trip photos first
/// 4. content    – categories, animals, (opt-in) faces on local previews
/// 5. text       – OCR only for screenshots and document-like images
/// 6. groups     – person/pet grouping with the user's feedback
/// 7. proposals  – album proposals, matched against existing albums
///
/// Every stage persists its results as it goes, so pausing, a background expiry or a
/// crash loses at most one batch. Each result carries a version: raising a version
/// re-runs only the affected stage.
public actor AnalysisPipeline {
    public enum Stage: String, CaseIterable, Sendable, Codable {
        case inventory, patterns, places, content, text, groups, proposals

        /// Rough share of a full first run; the image analysis takes most of the time.
        public var share: Double {
            switch self {
            case .inventory: 0.05
            case .patterns: 0.03
            case .places: 0.12
            case .content: 0.6
            case .text: 0.12
            case .groups: 0.03
            case .proposals: 0.05
            }
        }

        /// 1-based position, for "Schritt 4 von 7".
        public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    }

    public enum Mode: String, Sendable, Codable {
        /// New and changed items only (also used for the first run).
        case incremental
        /// Overnight pass: finer town names, iCloud originals for text, fresh proposals.
        case refinement
    }

    public struct Progress: Sendable, Hashable {
        public var stage: Stage
        public var completed: Int
        public var total: Int

        /// One value for the whole run (0…1), so a bar never jumps back when the next stage starts.
        public static func overall(stage: Stage, completed: Int, total: Int) -> Double {
            let before = Stage.allCases.prefix { $0 != stage }.reduce(0) { $0 + $1.share }
            let within = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0
            return min(1, before + stage.share * within)
        }
    }

    public struct Report: Sendable, Hashable {
        public var completedStages: [Stage] = []
        /// Trips and places were offered before the image analysis (first run only).
        public var earlyProposals = false
        public var pausedBecause: PauseReason?
        public var newOrChanged = 0
        public var removed = 0
        public var placesResolved = 0
        public var placesPendingOnline = 0
        public var onlineRequests = 0
        public var contentAnalyzed = 0
        public var textRecognized = 0
        public var textWaitingForOriginal = 0
        public var proposals = 0

        public var isComplete: Bool { pausedBecause == nil && completedStages.count == Stage.allCases.count }
    }

    public static let contentVersion = 1
    public static let textVersion = 1

    enum Key {
        static let trips = "analysis.trips"
        static let frequentPlaces = "analysis.frequentPlaces"
        static let groups = "analysis.groups"
        static let tripCorrections = "user.tripCorrections"
        /// Trip identities across runs (kept by "Analyse neu aufbauen", like other user data).
        static let tripIdentities = "user.tripIdentities"
        static let groupingFeedback = "user.groupingFeedback"
        static let proposals = "analysis.proposals"
    }

    private let store: SortlyStore
    private let reader: any PhotoLibraryReading
    private let analyzer: any ContentAnalyzing
    private let geocoder: (any ReverseGeocoding)?
    private let map: OfflineWorldMap?
    private let conditions: any AnalysisConditions
    private let calendar: Calendar
    private let time: TimeSource
    private let batchSize: Int
    private let now: @Sendable () -> Date
    /// Bumped whenever the albums changed outside a run (a plan was applied): a run that
    /// computed its matches before that matches again before it saves them.
    private var albumGeneration = 0
    /// Online place lookups per normal run; the rest waits for the overnight refinement run.
    /// Keeps the first analysis from spending up to an hour on town names before photos are
    /// looked at (the geocoder allows about 40 requests a minute). `nil` = no limit.
    private let foregroundOnlineBudget: Int?
    public private(set) var settings: OrganizationSettings
    private var userPaused = false

    public init(
        store: SortlyStore,
        reader: any PhotoLibraryReading,
        analyzer: any ContentAnalyzing,
        geocoder: (any ReverseGeocoding)?,
        map: OfflineWorldMap?,
        conditions: any AnalysisConditions,
        settings: OrganizationSettings,
        calendar: Calendar = .sortlyDefault,
        time: TimeSource = .live(),
        batchSize: Int = 50,
        foregroundOnlineBudget: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.store = store
        self.reader = reader
        self.analyzer = analyzer
        self.geocoder = geocoder
        self.map = map
        self.conditions = conditions
        self.settings = settings
        self.calendar = calendar
        self.time = time
        self.batchSize = max(1, batchSize)
        self.foregroundOnlineBudget = foregroundOnlineBudget
    }

    public func update(settings: OrganizationSettings) { self.settings = settings }

    /// Pauses at the next batch boundary; `run` then returns with `.userPaused`.
    public func pause() { userPaused = true }

    /// Checked between online place lookups, so Pause, heat or low battery stop that stage
    /// within one request instead of after all of them.
    private func stopRequested() async -> Bool {
        if userPaused || Task.isCancelled { return true }
        return await conditions.pauseReason() != nil
    }

    public func run(
        mode: Mode = .incremental,
        scope: OrganizationScope = .all,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Report {
        userPaused = false
        var report = Report()

        func shouldStop() async -> PauseReason? {
            if userPaused { return .userPaused }
            if Task.isCancelled { return .timeBudget }
            return await conditions.pauseReason()
        }

        // 1. Inventory
        guard await reader.access().canRead else {
            report.pausedBecause = .accessRevoked
            return report
        }
        let assets = try await reader.fetchAssets(includeHidden: settings.privacy.includeHiddenAssets,
                                                  knownDetails: try await store.assetsWithFileDetails())
        report.newOrChanged = try await store.upsertAssets(assets).count
        report.removed = try await store.removeAssets(notIn: Set(assets.map(\.id)))
        let inventory = try await reader.currentInventory()
        try await store.saveInventory(inventory)
        onProgress(Progress(stage: .inventory, completed: assets.count, total: assets.count))
        report.completedStages.append(.inventory)
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }

        // 2. Patterns (pure computation over metadata, seconds even for large libraries)
        let all = try await store.allAssets()
        let corrections = try await store.value(TripCorrections.self, forKey: Key.tripCorrections) ?? TripCorrections()
        let detected = TripDetector(configuration: settings.trips.advanced, calendar: calendar).detect(in: all, corrections: corrections)
        // Trips keep their identity when their photos change a little (an older photo
        // imported, the first one deleted): decisions and deleted albums stay attached.
        var known = try await store.value([TripIdentity].self, forKey: Key.tripIdentities) ?? []
        if known.isEmpty {
            // First run with identities: the trips of the last analysis are the starting point.
            known = (try await store.value([Trip].self, forKey: Key.trips) ?? []).map(TripIdentity.init)
        }
        let trips = TripIdentity.carryOver(detected, from: known)
        try await store.setValue(Self.mergedIdentities(known, trips, library: Set(all.map(\.id))), forKey: Key.tripIdentities)
        var frequent = FrequentPlaceDetector(configuration: settings.frequentPlaces.advanced, calendar: calendar).detect(in: all)
        for i in frequent.indices { frequent[i].userName = settings.frequentPlaces.names[frequent[i].id] }
        try await store.setValue(trips, forKey: Key.trips)
        try await store.setValue(frequent, forKey: Key.frequentPlaces)
        report.completedStages.append(.patterns)
        onProgress(Progress(stage: .patterns, completed: 1, total: 1))

        // 3. Places
        let placeOutcome = try await resolvePlaces(all, trips: trips, frequent: frequent, refining: mode == .refinement, onProgress: onProgress)
        report.placesResolved = placeOutcome.resolved
        report.placesPendingOnline = placeOutcome.pendingOnline.count
        report.onlineRequests = placeOutcome.onlineRequests
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        report.completedStages.append(.places)

        // 4. Content
        let peopleRequest = ContentAnalysisRequest(
            classify: settings.enabledAreas.contains(.imageCategories) || settings.enabledAreas.contains(.documents),
            detectFaces: settings.people.faceGroupingEnabled && settings.enabledAreas.contains(.peopleAndPets),
            detectAnimals: settings.people.petGroupingEnabled && settings.enabledAreas.contains(.peopleAndPets),
            featurePrint: true
        )
        let contentTotal = try await store.countNeedingAnalysis(version: Self.contentVersion)
        // First results early: trips, countries and places need no image analysis. On a first
        // run (no suggestions yet) they are offered right away instead of after the image
        // analysis, which takes hours on a large library. The full set replaces them later;
        // suggestion ids are stable, so decisions made in between stay valid.
        if contentTotal > 0, try await latestProposals() == nil {
            let groups = try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
            _ = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope)
            report.earlyProposals = true
        }
        var contentDone = 0
        var cursor: AssetSnapshot?
        // Photos that could not be read in this run: tried again in a later run, not now.
        var deferred = Set<AssetID>()
        while true {
            if let reason = await shouldStop() { report.pausedBecause = reason; return report }
            var raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: batchSize + deferred.count, olderThan: cursor)
            if raw.isEmpty, cursor != nil {
                // Past the oldest dated photo: one plain pass picks up photos without a date.
                cursor = nil
                raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: batchSize + deferred.count)
            }
            let batch = raw.filter { !deferred.contains($0.id) }
            if batch.isEmpty { break }
            if let last = raw.last, last.creationDate != nil { cursor = last }
            var finished: [AssetID] = []
            var stopped: PauseReason?
            for asset in batch {
                // Checked per photo: heat, low battery or Pause stop within one image.
                if let reason = await shouldStop() { stopped = reason; break }
                do {
                    let result = try await analyzer.analyzeContent(asset, request: peopleRequest)
                    try await store.saveResult(result, kind: "content", asset: asset.id, version: Self.contentVersion)
                    finished.append(asset.id)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        // Stopped, not unreadable: what is done stays done, the rest waits.
                        try await store.markAnalyzed(finished, version: Self.contentVersion)
                        throw CancellationError()
                    }
                    // Not readable right now (no local preview yet, still syncing): tried again
                    // in later runs, and given up only after a few of them.
                    let previous = try? await store.result(ContentAnalysis.self, kind: "content", asset: asset.id)
                    if let previous, previous.failedAttempts == nil {
                        // Read before and the image is unchanged (an edit drops the old result):
                        // the earlier labels stay valid.
                        finished.append(asset.id)
                        continue
                    }
                    let earlier = previous?.failedAttempts ?? 0
                    var failed = ContentAnalysis()
                    failed.failedAttempts = earlier + 1
                    try await store.saveResult(failed, kind: "content", asset: asset.id, version: Self.contentVersion)
                    if earlier + 1 >= ContentAnalysis.maxFailedAttempts { finished.append(asset.id) } else { deferred.insert(asset.id) }
                }
            }
            try await store.markAnalyzed(finished, version: Self.contentVersion)
            contentDone += finished.count
            report.contentAnalyzed += finished.count
            onProgress(Progress(stage: .content, completed: contentDone, total: max(contentTotal, contentDone)))
            if let stopped { report.pausedBecause = stopped; return report }
        }
        report.completedStages.append(.content)

        // 5. Text
        let textOutcome = try await recognizeText(all, shouldStop: shouldStop, onProgress: onProgress)
        report.textRecognized = textOutcome.recognized
        report.textWaitingForOriginal = textOutcome.waiting
        if let reason = textOutcome.paused { report.pausedBecause = reason; return report }
        report.completedStages.append(.text)

        // 6. Groups
        let groups = try await groupObservations()
        report.completedStages.append(.groups)

        // 7. Proposals
        let snapshot = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope)
        report.proposals = snapshot.proposals.count
        report.completedStages.append(.proposals)
        onProgress(Progress(stage: .proposals, completed: snapshot.proposals.count, total: snapshot.proposals.count))
        return report
    }

    // MARK: Stages

    private func resolvePlaces(
        _ all: [AssetSnapshot], trips: [Trip], frequent: [FrequentPlace], refining: Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> PlaceResolutionService.Outcome {
        let policy = PlaceResolutionPolicy(settings: settings)
        let existing = try await store.places()
        let tripMembers = Set(trips.flatMap(\.geotaggedAssetIDs))
        let frequentMembers = Set(frequent.flatMap(\.assetIDs))
        let requests: [PlaceResolutionService.Request] = all.compactMap { asset in
            guard let coordinate = asset.usableLocation else { return nil }
            if let place = existing[asset.id] {
                let pendingTown = policy.deepestLevel >= .locality && place.precisionMeters == nil
                let refine = refining && place.needsRefinement(to: policy.cellMeters(refining: true))
                guard pendingTown || refine else { return nil }
            }
            let priority = tripMembers.contains(asset.id) ? 10 : (frequentMembers.contains(asset.id) ? 5 : 0)
            return .init(assetID: asset.id, coordinate: coordinate, priority: priority)
        }
        guard !requests.isEmpty else { return .init() }
        let service = PlaceResolutionService(map: map, geocoder: geocoder, cache: store, policy: policy, time: time)
        let store = self.store
        let total = requests.count
        let counter = ProgressCounter()
        let budget = refining ? nil : foregroundOnlineBudget
        return try await service.resolve(requests, refining: refining, maxOnlineRequests: budget,
                                         shouldStop: { [weak self] in await self?.stopRequested() ?? true }) { batch in
            try await store.setPlaces(batch)
            let done = await counter.add(batch.count)
            onProgress(Progress(stage: .places, completed: min(done, total), total: total))
        }
    }

    private func recognizeText(
        _ all: [AssetSnapshot],
        shouldStop: () async -> PauseReason?,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> (recognized: Int, waiting: Int, paused: PauseReason?) {
        guard settings.enabledAreas.contains(.screenshots) || settings.enabledAreas.contains(.documents) || settings.enabledAreas.contains(.messenger) else {
            return (0, 0, nil)
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let done = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion)
        // iCloud rule: originals only with consent, on Wi-Fi unless cellular is allowed.
        // Checked again before every photo: leaving Wi-Fi stops downloads at once.
        let networkAllowedNow: () async -> Bool = { [settings, conditions] in
            guard settings.privacy.allowNetworkForAnalysis else { return false }
            return settings.privacy.allowCellularDownloads ? true : await conditions.isOnWiFi()
        }
        let networkAllowed = await networkAllowedNow()
        let started = now()
        let candidates = all.filter { asset in
            guard let content = contents[asset.id], content.needsTextRecognition(for: asset) else { return false }
            guard let previous = done[asset.id] else { return true }
            return previous.shouldRetry(networkAllowed: networkAllowed, now: started)
        }
        var recognized = 0, waiting = 0
        let documents = DocumentAnalyzer()
        let screenshots = ScreenshotClassifier()
        for (index, asset) in candidates.enumerated() {
            if let reason = await shouldStop() { return (recognized, waiting, reason) }
            let previous = done[asset.id]
            let allowNetwork = networkAllowed ? await networkAllowedNow() : false
            // Needed the network and it is gone now: stays as it is for a later run.
            if let previous, previous.waitingForOriginal || previous.text?.source == .localPreview, !allowNetwork { continue }
            var result = TextResult()
            do {
                let text = try await analyzer.recognizeText(asset, allowNetwork: allowNetwork)
                result.document = documents.analyze(text: text.text)
                if asset.isScreenshotLike {
                    let labels = Set(contents[asset.id]?.labels.map(\.identifier) ?? [])
                    let classified = screenshots.classify(text: text.text, barcodePayloads: text.barcodePayloads, imageLabels: labels)
                    result.screenshotCategories = classified.categories.filter { $0.value >= .plausible }.map(\.key.rawValue).sorted()
                }
                // Analysis used the full text; only a minimized copy is kept on disk.
                var stored = text
                stored.text = TextMinimizer.storable(text.text)
                // Barcode contents (boarding passes, payment codes with IBAN, tickets with names)
                // only serve the classification above and are never kept.
                stored.barcodePayloads = []
                result.text = stored
                // The search index follows the new text; empty or withheld text removes the old one.
                if stored.text.isEmpty {
                    try await store.removeText(for: asset.id)
                } else {
                    try await store.indexText(stored.text, for: asset.id)
                }
                if text.source == .localPreview {
                    // Only the small preview was readable: read again from the original later.
                    result.retries = (previous?.retries ?? 0) + 1
                    result.lastAttempt = now()
                }
                recognized += 1
            } catch AnalysisError.originalNotAvailable {
                result = previous ?? TextResult()
                if allowNetwork {
                    // Even the download failed: a few more tries, spaced out, then it stays.
                    result.waitingForOriginal = false
                    result.retries = (previous?.retries ?? 0) + 1
                    result.lastAttempt = now()
                } else {
                    result.waitingForOriginal = true
                    waiting += 1
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Unreadable now: what was read before stays; a few more tries in later runs.
                result = previous ?? TextResult()
                result.waitingForOriginal = false
                result.retries = (previous?.retries ?? 0) + 1
                result.lastAttempt = now()
            }
            try await store.saveResult(result, kind: "text", asset: asset.id, version: Self.textVersion)
            if index % 20 == 19 || index == candidates.count - 1 {
                onProgress(Progress(stage: .text, completed: index + 1, total: candidates.count))
            }
        }
        return (recognized, waiting, nil)
    }

    private func groupObservations() async throws -> [ObservationGroup] {
        guard settings.enabledAreas.contains(.peopleAndPets) else {
            try await store.setValue([ObservationGroup](), forKey: Key.groups)
            return []
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let feedback = try await store.value(GroupingFeedback.self, forKey: Key.groupingFeedback) ?? GroupingFeedback()
        let grouper = ObservationGrouper(distanceThreshold: settings.people.advanced.distanceThreshold, minGroupSize: settings.people.advanced.minGroupSize)
        var groups: [ObservationGroup] = []
        if settings.people.faceGroupingEnabled {
            let faces = contents.keys.sorted().flatMap { contents[$0]!.faces }
            groups += grouper.group(faces, kind: .person, feedback: feedback)
        }
        if settings.people.petGroupingEnabled {
            let animals = contents.keys.sorted().flatMap { contents[$0]!.animals }
            for kind in [GroupKind.dog, .cat, .otherAnimal] {
                groups += grouper.group(animals.filter { $0.kind == kind }.map(\.observation), kind: kind, feedback: feedback)
            }
        }
        try await store.setValue(groups, forKey: Key.groups)
        return groups
    }

    private func makeProposals(
        all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace],
        groups: [ObservationGroup], scope: OrganizationScope
    ) async throws -> ProposalSnapshot {
        // The albums are read again: a plan applied while this run was busy (minutes or hours
        // on a large library) created albums the matching must see, or it would suggest them
        // a second time.
        let generation = albumGeneration
        var inventory = inventory
        if let fresh = try? await reader.currentInventory(), fresh != inventory {
            inventory = fresh
            try await store.saveInventory(fresh)
        }
        let facts = try await currentFacts(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups)
            .filter { scope.includes($0, calendar: calendar) }
        let overrides = OverrideSet(try await store.overrides())
        let scopedIDs = Set(facts.map(\.id))
        let analysis = AnalysisSnapshot(
            facts: facts,
            trips: scope == .all ? trips : trips.filter { !scopedIDs.isDisjoint(with: $0.geotaggedAssetIDs) },
            frequentPlaces: scope == .all ? frequent : [],
            groups: groups
        )
        let proposals = ProposalEngine(settings: settings, calendar: calendar).proposals(for: analysis, overrides: overrides)
        var matches = AlbumMatcher().match(proposals, against: inventory, overrides: overrides,
                                           assignments: Self.assignments(try await store.managedAlbums()))
        if generation != albumGeneration {
            // A plan was applied while this ran: match against the albums as they are now, or
            // the suggestions would offer albums that were just created.
            matches = AlbumMatcher().match(proposals, against: try await store.loadInventory(), overrides: OverrideSet(try await store.overrides()),
                                           assignments: Self.assignments(try await store.managedAlbums()))
        }
        let snapshot = ProposalSnapshot(generatedAt: Date(), scope: scope, proposals: proposals, matches: matches)
        try await store.setValue(snapshot, forKey: Key.proposals)
        return snapshot
    }

    /// Facts for every asset from the stored results (also used by search and status).
    public func currentFacts() async throws -> [AssetFacts] {
        try await currentFacts(
            all: try await store.allAssets(),
            inventory: try await store.loadInventory(),
            trips: try await store.value([Trip].self, forKey: Key.trips) ?? [],
            frequent: try await store.value([FrequentPlace].self, forKey: Key.frequentPlaces) ?? [],
            groups: try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
        )
    }

    private func currentFacts(all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace], groups: [ObservationGroup]) async throws -> [AssetFacts] {
        FactsAssembler.assemble(
            assets: all,
            places: try await store.places(),
            contents: try await store.results(ContentAnalysis.self, kind: "content"),
            texts: try await store.results(TextResult.self, kind: "text"),
            trips: trips,
            frequentPlaces: frequent,
            groups: groups,
            inventory: inventory
        )
    }

    /// The remembered identities, updated with this run's trips. Identities of trips that are
    /// not detected right now stay while any of their photos is still in the library (a trip
    /// can come back when its photos sync again or a correction is undone).
    static func mergedIdentities(_ known: [TripIdentity], _ trips: [Trip], library: Set<AssetID>) -> [TripIdentity] {
        let current = Set(trips.map(\.id))
        return trips.map(TripIdentity.init) + known.filter { identity in
            !current.contains(identity.id) && identity.members.contains(where: library.contains)
        }
    }

    /// Suggestion → the album it was applied to, from the managed-album records.
    static func assignments(_ states: [ManagedAlbumState]) -> [SortlyID: CollectionID] {
        Dictionary(states.flatMap { state in state.allSourceIDs.map { ($0, state.albumID) } }, uniquingKeysWith: { first, _ in first })
    }

    public func latestProposals() async throws -> ProposalSnapshot? {
        try await store.value(ProposalSnapshot.self, forKey: Key.proposals)
    }

    /// Re-runs only the album matching against the stored inventory and overrides, after
    /// albums were created or the user said an album does not fit. The suggestions then show
    /// the right state at once instead of after the next analysis.
    public func rematch() async throws -> ProposalSnapshot? {
        albumGeneration += 1
        guard var snapshot = try await latestProposals() else { return nil }
        let inventory = try await store.loadInventory()
        let overrides = OverrideSet(try await store.overrides())
        snapshot.matches = AlbumMatcher().match(snapshot.proposals, against: inventory, overrides: overrides,
                                                assignments: Self.assignments(try await store.managedAlbums()))
        try await store.setValue(snapshot, forKey: Key.proposals)
        return snapshot
    }
}

private actor ProgressCounter {
    var value = 0
    func add(_ n: Int) -> Int { value += n; return value }
}
