import Foundation
import Observation
import SortlyCore
import SortlyEngine
import SortlyStore
import SortlyWorldMap

/// App state and use cases. Views read it; all work happens in the core/engine actors.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    struct AnalysisState: Equatable {
        var isRunning = false
        var stage: AnalysisPipeline.Stage?
        var completed = 0
        var total = 0
        var lastReport: AnalysisPipeline.Report?
        var lastRun: Date?

        var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }
    }

    struct ExecutionState: Equatable {
        var isRunning = false
        var completedSteps = 0
        var totalSteps = 0
        var finished: ChangePlan?
        var failure: String?
    }

    // MARK: State

    var phase: Phase = .loading
    var access: LibraryAccess = .notDetermined
    var settings = OrganizationSettings() { didSet { bucketCache = [:] } }
    var analysis = AnalysisState()
    var snapshot: ProposalSnapshot?
    var decisions: [SortlyID: ProposalDecision] = [:]
    var userTitles: [SortlyID: String] = [:]
    var facts: [AssetFacts] = [] { didSet { bucketCache = [:]; atlasCache = [:]; atlasYearsCache = nil; countryCache = [:] } }
    var states: [AssetID: AssetOrganizationState] = [:] { didSet { bucketCache = [:] } }
    /// Filtered and sorted library buckets; rebuilt only when facts or states change, not on
    /// every redraw of the library (a selection tap redraws it).
    @ObservationIgnored private var bucketCache: [InboxBucket: [AssetFacts]] = [:]
    /// The atlas is shown on the overview, which redraws often during an analysis.
    @ObservationIgnored private var atlasCache: [Int: TravelAtlas] = [:]
    @ObservationIgnored private var atlasYearsCache: [Int]?

    /// Travel atlas for all years (`nil`) or one calendar year; computed once per facts change.
    func travelAtlas(year: Int? = nil) -> TravelAtlas {
        if let cached = atlasCache[year ?? 0] { return cached }
        let atlas = TravelAtlas.compute(facts: facts, year: year)
        atlasCache[year ?? 0] = atlas
        return atlas
    }

    var atlasYears: [Int] {
        if let cached = atlasYearsCache { return cached }
        let years = TravelAtlas.years(facts: facts)
        atlasYearsCache = years
        return years
    }

    @ObservationIgnored private var countryCache: [String: CountryPhotos] = [:]

    /// The photos of one atlas country (all years or one year), newest first.
    func countryPhotos(_ code: String, year: Int? = nil) -> CountryPhotos {
        let key = "\(code)|\(year ?? 0)"
        if let cached = countryCache[key] { return cached }
        let photos = CountryPhotos.collect(countryCode: code, facts: facts, year: year)
        countryCache[key] = photos
        return photos
    }

    /// The open country suggestion that covers most of these photos, if there is one,
    /// so the atlas can offer "Album anlegen" right where the photos are shown.
    func countryProposal(for country: CountryPhotos) -> AlbumProposal? {
        let ids = country.assetIDs
        guard !ids.isEmpty else { return nil }
        return openProposals
            .filter { $0.kind == .placeCollection(.country) }
            .map { ($0, $0.assetIDs.intersection(ids).count) }
            .filter { $0.1 * 2 > $0.0.assetIDs.count }
            .max { $0.1 < $1.1 }?.0
    }
    var progress = OrganizationStatusResolver.Progress()
    var inventory = CollectionInventory()
    var mergeSuggestions: [AlbumOverlapAnalyzer.MergeSuggestion] = []
    var history: [ChangePlan] = []
    /// Albums SORTLY created or extended, with exactly the media it added.
    var managedAlbums: [ManagedAlbumState] = []
    var plan: ChangePlan?
    var execution = ExecutionState()
    var message: String?

    let library = PhotoKitLibrary()
    private(set) var store: SortlyStore?
    /// Offline country outlines, also used for the shareable travel atlas.
    private(set) var worldMap: OfflineWorldMap?
    private var pipeline: AnalysisPipeline?
    private var analysisTask: Task<Void, Never>?

    private enum Key {
        static let settings = "user.settings"
        static let decisions = "user.decisions"
        static let titles = "user.titles"
        static let onboardingDone = "onboarding.done"
    }

    var onboardingDone: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboardingDone) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboardingDone) }
    }

    var resolver: OrganizationStatusResolver { OrganizationStatusResolver(primaryAreas: settings.primaryAreas) }

    // MARK: Lifecycle

    func bootstrap() async {
        guard phase == .loading else { return }
        do {
            let store = try SortlyStore(url: try Self.databaseURL())
            self.store = store
            settings = try await store.value(OrganizationSettings.self, forKey: Key.settings) ?? OrganizationSettings()
            decisions = try await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions) ?? [:]
            userTitles = try await store.value([SortlyID: String].self, forKey: Key.titles) ?? [:]
            access = await library.access()
            let map = await Task.detached(priority: .userInitiated) { try? WorldMapResource.load() }.value
            worldMap = map
            pipeline = AnalysisPipeline(
                store: store, reader: library, analyzer: VisionAnalyzer(),
                geocoder: SystemGeocoder(locale: Locale(identifier: settings.titleLanguage.rawValue)),
                map: map, conditions: DeviceConditions(), settings: settings
            )
            await refreshDerived()
            phase = onboardingDone && access.canRead ? .ready : .onboarding
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppInfo.supportFolderName, isDirectory: true)
        // The database holds recognized text of screenshots and documents: encrypted at rest
        // once the device was unlocked after boot (needed so background analysis still works).
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: protection)
        try? FileManager.default.setAttributes(protection, ofItemAtPath: base.path)
        // The analysis can be rebuilt from the library; keep the whole folder out of backups.
        // (Set on the folder: a resource value on a file that does not exist yet is lost.)
        var folder = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let url = base.appendingPathComponent("sortly.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(protection, ofItemAtPath: path)
            }
        }
        return url
    }

    func requestAccess() async {
        access = await library.requestAccess()
    }

    func finishOnboarding(scope: OrganizationScope) {
        onboardingDone = true
        phase = .ready
        ContinuedAnalysis.requestNotificationPermission()
        startAnalysis(scope: scope, userInitiated: true)
    }

    // MARK: Settings

    func saveSettings() {
        let settings = settings
        Task {
            try? await store?.setValue(settings, forKey: Key.settings)
            await pipeline?.update(settings: settings)
            await refreshDerived()
        }
    }

    // MARK: Analysis

    /// `userInitiated`: started by a tap, so it may continue in the background with progress
    /// on the Lock Screen (iOS 26 continued processing).
    func startAnalysis(scope: OrganizationScope = .all, mode: AnalysisPipeline.Mode = .incremental, userInitiated: Bool = false) {
        guard !analysis.isRunning, let pipeline else { return }
        if userInitiated { ContinuedAnalysis.begin() }
        analysis.isRunning = true
        analysis.completed = 0
        analysis.total = 0
        analysisTask = Task {
            do {
                let report = try await pipeline.run(mode: mode, scope: scope) { progress in
                    Task { @MainActor in
                        AppModel.shared.analysis.stage = progress.stage
                        AppModel.shared.analysis.completed = progress.completed
                        AppModel.shared.analysis.total = progress.total
                    }
                }
                analysis.lastReport = report
                analysis.lastRun = Date()
            } catch {
                message = error.localizedDescription
            }
            analysis.isRunning = false
            analysis.stage = nil
            await refreshDerived()
            ContinuedAnalysis.notifyFinished(openSuggestions: openProposals.count)
            BackgroundWork.scheduleRefinement()
        }
    }

    func pauseAnalysis() {
        Task { await pipeline?.pause() }
    }

    /// Called by the background task while charging.
    func runBackgroundRefinement() async -> Bool {
        if phase == .loading { await bootstrap() }
        guard let pipeline, !analysis.isRunning, access.canRead else { return false }
        analysis.isRunning = true
        defer { analysis.isRunning = false }
        do {
            let report = try await pipeline.run(mode: .refinement)
            analysis.lastReport = report
            await refreshDerived()
            return report.pausedBecause == nil
        } catch {
            return false
        }
    }

    func refreshDerived() async {
        guard let store, let pipeline else { return }
        await reconcileManagedAlbums()
        do {
            snapshot = try await pipeline.latestProposals()
            facts = try await pipeline.currentFacts()
            inventory = try await store.loadInventory()
            let inventory = inventory
            mergeSuggestions = await Task.detached(priority: .utility) { AlbumOverlapAnalyzer().suggestions(in: inventory) }.value
            history = try await store.planHistory()
            let analyzed = Set(try await store.results(ContentAnalysis.self, kind: "content").keys)
            let overrides = OverrideSet(try await store.overrides())
            let facts = facts, snapshot = snapshot, settings = settings
            let computed = await Task.detached(priority: .userInitiated) {
                LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides, contentAnalyzed: analyzed)
            }.value
            states = computed
            progress = resolver.progress(computed.values)
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Proposals and decisions

    var proposals: [AlbumProposal] { snapshot?.proposals ?? [] }

    func match(for proposal: AlbumProposal) -> MatchResult? { snapshot?.matches[proposal.id] }

    func decision(for proposal: AlbumProposal) -> ProposalDecision {
        decisions[proposal.id] ?? .undecided
    }

    func recommendedDecision(for proposal: AlbumProposal) -> ProposalDecision {
        ProposalDecision.recommended(for: proposal, match: match(for: proposal), userTitle: userTitles[proposal.id])
    }

    /// Proposals that contain this photo (shown on the photo so it can be opened directly).
    func proposals(containing id: AssetID) -> [AlbumProposal] {
        proposals.filter { $0.assetIDs.contains(id) }
            .sorted { ($0.reliability, $0.assetIDs.count) > ($1.reliability, $1.assetIDs.count) }
    }

    var openProposals: [AlbumProposal] {
        proposals.filter { decisions[$0.id] == nil && match(for: $0)?.status != .alreadyComplete }
    }

    var acceptedProposals: [AlbumProposal] {
        proposals.filter { decisions[$0.id]?.isAccepted == true }
    }

    func setDecision(_ decision: ProposalDecision, for proposal: AlbumProposal) {
        decisions[proposal.id] = decision
        persistDecisions()
        if decision == .reject {
            let override = UserOverride(scope: .source(proposal.id), decision: .rejectProposal)
            Task { try? await store?.addOverride(override) }
        }
    }

    /// "Passt nicht": this album is never offered for this suggestion again. A decision that
    /// pointed at the album is dropped, and the matching runs again right away.
    func rejectMatch(_ album: CollectionID, for proposal: AlbumProposal) async {
        guard let store else { return }
        do {
            try await store.addOverride(UserOverride(scope: .albumForSource(album, proposal.id), decision: .notMatchingAlbum))
            switch decisions[proposal.id] {
            case .extendExisting(album)?, .keepExisting(album)?:
                decisions[proposal.id] = nil
                persistDecisions()
            case .renameExisting(let id, _, _)? where id == album:
                decisions[proposal.id] = nil
                persistDecisions()
            case .moveExisting(let id, _, _)? where id == album:
                decisions[proposal.id] = nil
                persistDecisions()
            default:
                break
            }
            if let rematched = try await pipeline?.rematch() { snapshot = rematched }
        } catch {
            message = error.localizedDescription
        }
    }

    func setUserTitle(_ title: String, for proposal: AlbumProposal) {
        userTitles[proposal.id] = title
        Task { [userTitles] in try? await store?.setValue(userTitles, forKey: Key.titles) }
    }

    private func persistDecisions() {
        let decisions = decisions
        Task { try? await store?.setValue(decisions, forKey: Key.decisions) }
    }

    // MARK: Plan and execution

    func buildPlan() async {
        guard let store else { return }
        do {
            let current = try await library.currentInventory()
            let overrides = OverrideSet(try await store.overrides())
            let confirmed = acceptedProposals.map { proposal in
                var decision = decisions[proposal.id] ?? .undecided
                if case .createNew(nil, let path) = decision, let title = userTitles[proposal.id], !title.isEmpty {
                    decision = .createNew(title: title, folderPath: path)
                }
                return ConfirmedProposal(proposal: proposal, decision: decision)
            }
            plan = OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle).makePlan(from: confirmed, inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Plan for one proposal only, so "Album anlegen" in a suggestion does it right away
    /// (still through the normal preview, with undo).
    func singlePlan(for proposal: AlbumProposal) async -> ChangePlan? {
        guard let store else { return nil }
        do {
            let current = try await library.currentInventory()
            let overrides = OverrideSet(try await store.overrides())
            var decision = decisions[proposal.id] ?? .undecided
            if case .createNew(nil, let path) = decision, let title = userTitles[proposal.id], !title.isEmpty {
                decision = .createNew(title: title, folderPath: path)
            }
            let plan = OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
            return plan.steps.isEmpty ? nil : plan
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func execute(_ plan: ChangePlan) async {
        guard let store else { return }
        var confirmed = plan
        confirmed.status = .confirmed
        confirmed.confirmedAt = Date()
        execution = ExecutionState(isRunning: true, completedSteps: 0, totalSteps: plan.steps.count)
        let executor = ChangeExecutor(library: library, store: store)
        do {
            let result = try await executor.execute(confirmed) { event in
                if case .stepFinished(let index, _) = event {
                    Task { @MainActor in AppModel.shared.execution.completedSteps = index + 1 }
                }
            }
            execution.finished = result
            await recordManagedAlbums(after: result)
            let used = result.summary
            Purchases.shared.recordUsage(albums: used.newAlbums + used.extendedAlbums)
            // Applied proposals leave the open list; other accepted ones stay accepted.
            let applied = Set(result.steps.compactMap(\.sourceID))
            for id in applied where decisions[id]?.isAccepted == true { decisions[id] = nil }
            persistDecisions()
        } catch {
            execution.failure = error.localizedDescription
        }
        execution.isRunning = false
        self.plan = nil
        startAnalysis()
    }

    /// Merge plan for overlapping albums: the largest album receives the missing media of
    /// the others. The other albums stay unless the user removes them later (prompt §3).
    func mergePlan(_ suggestion: AlbumOverlapAnalyzer.MergeSuggestion) async -> ChangePlan? {
        guard let store else { return nil }
        do {
            let current = try await library.currentInventory()
            let albums = suggestion.albumIDs.compactMap { current[$0] }
            guard let target = albums.max(by: { $0.assetIDs.count < $1.assetIDs.count }) else { return nil }
            let proposal = AlbumProposal(id: SortlyID(), kind: .rule, title: target.title, assetIDs: [], reliability: .certain)
            let decision = ProposalDecision.merge(target: target.id, sources: albums.map(\.id), title: target.title, folderPath: nil, removeSourceAlbums: false)
            let overrides = OverrideSet(try await store.overrides())
            return OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Plan for photos the user put into an album by hand: an existing album is extended,
    /// otherwise a new album is created (in the SORTLY folder). Goes through the normal review.
    func manualPlan(assets: [AssetID], target: CollectionID?, newTitle: String?) async -> ChangePlan? {
        guard let store, !assets.isEmpty else { return nil }
        do {
            let current = try await library.currentInventory()
            let title = newTitle ?? target.flatMap { current[$0]?.title } ?? ""
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let proposal = AlbumProposal(id: SortlyID(), kind: .rule, title: title, assetIDs: Set(assets), reliability: .certain)
            let decision: ProposalDecision = target.map { .extendExisting($0) } ?? .createNew(title: title, folderPath: nil)
            let overrides = OverrideSet(try await store.overrides())
            return OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    // MARK: Albums created by SORTLY

    /// Remembers which albums the plan created or extended (and which media it added).
    private func recordManagedAlbums(after result: ChangePlan) async {
        guard let store else { return }
        do {
            let after = try await library.currentInventory()
            // New albums show up under "Alben" right away, not only after the next analysis.
            try await store.saveInventory(after)
            inventory = after
            let states = ManagedAlbumTracker().record(result, into: try await store.managedAlbums(), inventory: after)
            try await store.saveManagedAlbums(states)
            managedAlbums = states
            // Suggestions see the new albums at once (e.g. "Album vollständig").
            if let rematched = try await pipeline?.rematch() { snapshot = rematched }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Detects changes the user made in the Photos app (renamed, deleted, photos removed)
    /// and turns them into overrides, so SORTLY never undoes a manual decision.
    private func reconcileManagedAlbums() async {
        guard let store, let stored = try? await store.managedAlbums() else { return }
        // Only with full access: a limited library would look like deleted albums and photos.
        guard !stored.isEmpty, !execution.isRunning, await library.access() == .full,
              let current = try? await library.currentInventory(), !current.albums.isEmpty else {
            managedAlbums = stored
            return
        }
        let result = ManagedAlbumTracker().reconcile(stored, with: current)
        if !result.changes.isEmpty {
            for override in result.newOverrides { try? await store.addOverride(override) }
            try? await store.saveManagedAlbums(result.updatedStates)
        }
        managedAlbums = result.updatedStates
    }

    /// Plan that takes SORTLY's additions back out of one album (shown in the normal review).
    func removalPlan(for state: ManagedAlbumState) async -> ChangePlan? {
        do {
            let current = try await library.currentInventory()
            let plan = ManagedAlbumTracker().removalPlan(for: state, current: current)
            return plan.steps.isEmpty ? nil : plan
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// After a removal the suggestion behind the album is not offered again.
    func forgetProposal(_ source: SortlyID) async {
        try? await store?.addOverride(UserOverride(scope: .source(source), decision: .rejectProposal))
        await refreshDerived()
    }

    func undo(_ executed: ChangePlan) async {
        do {
            let current = try await library.currentInventory()
            let undoPlan = UndoPlanner().undoPlan(for: executed, current: current)
            await execute(undoPlan)
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Library and search

    func bucketMembers(_ bucket: InboxBucket) -> [AssetFacts] {
        if let cached = bucketCache[bucket] { return cached }
        let resolver = resolver
        let members = facts.filter { f in
            guard let state = states[f.id] else { return bucket == .all }
            return resolver.buckets(state).contains(bucket)
        }
        .sorted { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
        bucketCache[bucket] = members
        return members
    }

    func ignore(_ assets: [AssetID]) {
        Task {
            for id in assets { try? await store?.addOverride(UserOverride(scope: .asset(id), decision: .ignoreAsset)) }
            await refreshDerived()
        }
    }

    var searchParser: QueryParser {
        QueryParser(vocabulary: SearchVocabulary.build(facts: facts, inventory: inventory, groups: []))
    }

    /// Keywords Apple Intelligence derived from the last sentence-style query (shown in the UI).
    var lastSearchRewrite: String?

    func search(_ query: String) async -> (tokens: [SearchToken], results: [AssetID]) {
        lastSearchRewrite = nil
        let direct = await plainSearch(query)
        let wordCount = query.split(whereSeparator: \.isWhitespace).count
        // Sentences ("Fotos vom Grillen letzten Sommer") get help from the on-device model.
        guard wordCount >= 3, direct.results.isEmpty || direct.tokens.count < 2, SmartAssistant.isAvailable,
              let keywords = await SmartAssistant.searchKeywords(for: query) else { return direct }
        let assisted = await plainSearch(keywords)
        guard !assisted.results.isEmpty else { return direct }
        lastSearchRewrite = keywords
        return assisted
    }

    private func plainSearch(_ query: String) async -> (tokens: [SearchToken], results: [AssetID]) {
        let parsed = searchParser.parse(query)
        guard !parsed.filter.isEmpty else { return (parsed.tokens, []) }
        var textHits: Set<AssetID>?
        if !parsed.filter.freeText.isEmpty, let store {
            textHits = Set((try? await store.searchText(parsed.filter.freeText.joined(separator: " "))) ?? [])
        }
        let overall = states.mapValues { resolver.overall($0) }
        let results = SearchEngine().search(parsed.filter, in: facts, statuses: overall, textHits: textHits)
        return (parsed.tokens, results)
    }

    // MARK: Reset

    func resetAnalysis() async {
        try? await store?.resetAnalysis(includingDecisions: false)
        await refreshDerived()
    }
}
