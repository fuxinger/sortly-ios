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
    var settings = OrganizationSettings()
    var analysis = AnalysisState()
    var snapshot: ProposalSnapshot?
    var decisions: [SortlyID: ProposalDecision] = [:]
    var userTitles: [SortlyID: String] = [:]
    var facts: [AssetFacts] = []
    var states: [AssetID: AssetOrganizationState] = [:]
    var progress = OrganizationStatusResolver.Progress()
    var inventory = CollectionInventory()
    var mergeSuggestions: [AlbumOverlapAnalyzer.MergeSuggestion] = []
    var history: [ChangePlan] = []
    var plan: ChangePlan?
    var execution = ExecutionState()
    var message: String?

    let library = PhotoKitLibrary()
    private(set) var store: SortlyStore?
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
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var url = base.appendingPathComponent("sortly.sqlite")
        // The analysis can be rebuilt from the library; keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    func requestAccess() async {
        access = await library.requestAccess()
    }

    func finishOnboarding(scope: OrganizationScope) {
        onboardingDone = true
        phase = .ready
        startAnalysis(scope: scope)
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

    func startAnalysis(scope: OrganizationScope = .all, mode: AnalysisPipeline.Mode = .incremental) {
        guard !analysis.isRunning, let pipeline else { return }
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
        let resolver = resolver
        return facts.filter { f in
            guard let state = states[f.id] else { return bucket == .all }
            return resolver.buckets(state).contains(bucket)
        }
        .sorted { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
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

    func search(_ query: String) async -> (tokens: [SearchToken], results: [AssetID]) {
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
