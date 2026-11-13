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
    }

    public struct Report: Sendable, Hashable {
        public var completedStages: [Stage] = []
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
        batchSize: Int = 50
    ) {
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
    }

    public func update(settings: OrganizationSettings) { self.settings = settings }

    /// Pauses at the next batch boundary; `run` then returns with `.userPaused`.
    public func pause() { userPaused = true }

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
        let assets = try await reader.fetchAssets(includeHidden: settings.privacy.includeHiddenAssets)
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
        let trips = TripDetector(configuration: settings.trips.advanced, calendar: calendar).detect(in: all, corrections: corrections)
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
        var contentDone = 0
        while true {
            if let reason = await shouldStop() { report.pausedBecause = reason; return report }
            let batch = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: batchSize)
            if batch.isEmpty { break }
            for asset in batch {
                let result: ContentAnalysis
                do {
                    result = try await analyzer.analyzeContent(asset, request: peopleRequest)
                } catch {
                    // Unreadable items are recorded as analyzed-without-content and never block the queue.
                    result = ContentAnalysis()
                }
                try await store.saveResult(result, kind: "content", asset: asset.id, version: Self.contentVersion)
            }
            try await store.markAnalyzed(batch.map(\.id), version: Self.contentVersion)
            contentDone += batch.count
            report.contentAnalyzed += batch.count
            onProgress(Progress(stage: .content, completed: contentDone, total: max(contentTotal, contentDone)))
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
        return try await service.resolve(requests, refining: refining) { batch in
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
        let networkAllowed: Bool
        if settings.privacy.allowNetworkForAnalysis {
            networkAllowed = settings.privacy.allowCellularDownloads ? true : await conditions.isOnWiFi()
        } else {
            networkAllowed = false
        }
        let candidates = all.filter { asset in
            guard let content = contents[asset.id], content.needsTextRecognition(for: asset) else { return false }
            guard let previous = done[asset.id] else { return true }
            return previous.waitingForOriginal && networkAllowed
        }
        var recognized = 0, waiting = 0
        let documents = DocumentAnalyzer()
        let screenshots = ScreenshotClassifier()
        for (index, asset) in candidates.enumerated() {
            if index % batchSize == 0, let reason = await shouldStop() { return (recognized, waiting, reason) }
            var result = TextResult()
            do {
                let text = try await analyzer.recognizeText(asset, allowNetwork: networkAllowed)
                result.text = text
                result.document = documents.analyze(text: text.text)
                if asset.isScreenshotLike {
                    let labels = Set(contents[asset.id]?.labels.map(\.identifier) ?? [])
                    let classified = screenshots.classify(text: text.text, barcodePayloads: text.barcodePayloads, imageLabels: labels)
                    result.screenshotCategories = classified.categories.filter { $0.value >= .plausible }.map(\.key.rawValue).sorted()
                }
                if !text.text.isEmpty { try await store.indexText(text.text, for: asset.id) }
                recognized += 1
            } catch AnalysisError.originalNotAvailable {
                result.waitingForOriginal = true
                waiting += 1
            } catch {
                // Unreadable: stored as empty so it is not retried endlessly.
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
        let matches = AlbumMatcher().match(proposals, against: inventory)
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

    public func latestProposals() async throws -> ProposalSnapshot? {
        try await store.value(ProposalSnapshot.self, forKey: Key.proposals)
    }
}

private actor ProgressCounter {
    var value = 0
    func add(_ n: Int) -> Int { value += n; return value }
}
