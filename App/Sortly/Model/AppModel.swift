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
        /// Progress over all stages: one bar that fills once instead of restarting per stage.
        var overall: Double {
            stage.map { AnalysisPipeline.Progress.overall(stage: $0, completed: completed, total: total) } ?? 0
        }
    }

    struct ExecutionState: Equatable {
        var isRunning = false
        /// The plan this state belongs to: progress of an earlier run never lands on a later one.
        var planID: SortlyID?
        var completedSteps = 0
        var totalSteps = 0
        var finished: ChangePlan?
        var failure: String?
        /// Steps that failed or were skipped (the sorting show gives them no checkmark).
        var unsuccessfulSteps: Set<Int> = []
    }

    // MARK: State

    var phase: Phase = .loading
    var access: LibraryAccess = .notDetermined
    var settings = OrganizationSettings() { didSet { bucketCache = [:] } }
    var analysis = AnalysisState()
    var snapshot: ProposalSnapshot?
    var decisions: [SortlyID: ProposalDecision] = [:]
    var userTitles: [SortlyID: String] = [:]
    var facts: [AssetFacts] = [] { didSet { bucketCache = [:]; atlasCache = [:]; atlasYearsCache = nil; countryCache = [:]; datesCache = nil; factsIndex = nil } }
    var states: [AssetID: AssetOrganizationState] = [:] { didSet { bucketCache = [:] } }
    /// Filtered and sorted library buckets; rebuilt only when facts or states change, not on
    /// every redraw of the library (a selection tap redraws it).
    @ObservationIgnored private var bucketCache: [InboxBucket: [AssetFacts]] = [:]
    /// The atlas is shown on the overview, which redraws often during an analysis.
    @ObservationIgnored private var atlasCache: [Int: TravelAtlas] = [:]
    @ObservationIgnored private var atlasYearsCache: [Int]?

    /// Travel atlas for all years (`nil`) or one calendar year; computed once per facts change.
    func travelAtlas(year: Int? = nil) -> TravelAtlas {
        // Cache hits must still register the dependency, or views would never see new facts.
        access(keyPath: \.facts)
        if let cached = atlasCache[year ?? 0] { return cached }
        let atlas = TravelAtlas.compute(facts: facts, year: year)
        atlasCache[year ?? 0] = atlas
        return atlas
    }

    var atlasYears: [Int] {
        access(keyPath: \.facts)
        if let cached = atlasYearsCache { return cached }
        let years = TravelAtlas.years(facts: facts)
        atlasYearsCache = years
        return years
    }

    @ObservationIgnored private var countryCache: [String: CountryPhotos] = [:]
    @ObservationIgnored private var datesCache: [AssetID: Date]?
    @ObservationIgnored private var factsIndex: [AssetID: AssetFacts]?

    /// Facts by photo id (search hits, photo view).
    var factsByID: [AssetID: AssetFacts] {
        access(keyPath: \.facts)
        if let factsIndex { return factsIndex }
        let index = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        factsIndex = index
        return index
    }

    /// Capture date of every photo, for time-ordered previews.
    var creationDates: [AssetID: Date] {
        access(keyPath: \.facts)
        if let datesCache { return datesCache }
        let dates = Dictionary(facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } }, uniquingKeysWith: { first, _ in first })
        datesCache = dates
        return dates
    }

    /// Photos the user took out of a suggestion ("Aus Vorschlag entfernen").
    var removedFromProposals: [SortlyID: Set<AssetID>] = [:]

    /// The photos of a suggestion as the user sees them: without removed ones, oldest first.
    func members(of proposal: AlbumProposal) -> [AssetID] {
        PreviewPicker.chronological(proposal.assetIDs.subtracting(removedFromProposals[proposal.id] ?? []), dates: creationDates)
    }

    /// Preview photos spread over the suggestion's time span, with the cover photo.
    func previewIDs(for proposal: AlbumProposal, count: Int = 8) -> [AssetID] {
        PreviewPicker.pick(proposal.assetIDs.subtracting(removedFromProposals[proposal.id] ?? []),
                           dates: creationDates, cover: proposal.coverAssetID, count: count)
    }

    /// Takes photos out of one suggestion only; they stay in the library and in other suggestions.
    func removeFromProposal(_ assets: Set<AssetID>, proposal: AlbumProposal) async {
        guard let store, !assets.isEmpty else { return }
        removedFromProposals[proposal.id, default: []].formUnion(assets)
        for asset in assets {
            try? await store.addOverride(UserOverride(scope: .assetInSource(asset, proposal.id), decision: .neverAdd))
        }
        saveSafetyBackup()
        if let rematched = try? await pipeline?.rematch() { snapshot = rematched }
    }

    /// The photos of one atlas country (all years or one year), newest first.
    func countryPhotos(_ code: String, year: Int? = nil) -> CountryPhotos {
        let key = "\(code)|\(year ?? 0)"
        access(keyPath: \.facts)
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
    /// Executed plans, newest first. Undo runs are not listed on their own; they mark the
    /// plan they took back (see `undonePlans`).
    var history: [ChangePlan] = []
    /// Plans whose changes were taken back by a completed undo (over the whole journal).
    var undonePlans: Set<SortlyID> = []
    /// How many finished plans the history shows; "Ältere anzeigen" loads more.
    var historyLimit = 50
    /// More finished plans exist than the history shows.
    var historyHasMore = false
    /// Albums Albumist created or extended, with exactly the media it added.
    var managedAlbums: [ManagedAlbumState] = []
    var plan: ChangePlan?
    /// A plan that stopped half way because the app was closed while it ran.
    var interruptedPlan: ChangePlan?
    var execution = ExecutionState()
    var message: String?
    /// Where Siri, Shortcuts or a Spotlight result wants to go; the overview opens it.
    var route: Route?

    enum Route: Hashable {
        case suggestion(SortlyID)
        case country(String)
    }

    let library = PhotoKitLibrary()
    private(set) var store: SortlyStore?
    /// Offline country outlines, also used for the shareable travel atlas.
    private(set) var worldMap: OfflineWorldMap?
    private var pipeline: AnalysisPipeline?
    private var analysisTask: Task<Void, Never>?
    /// One plan at a time (apply, resume, undo, take back): claimed before the first await of
    /// every entry point, released when it ends.
    @ObservationIgnored private var executionClaimed = false
    /// Decisions that exist only for an open preview: kept in memory, never written to disk.
    /// Value: what was stored before the preview (nil = undecided).
    @ObservationIgnored private var previewOnly: [SortlyID: ProposalDecision?] = [:]

    private enum Key {
        static let settings = "user.settings"
        static let decisions = "user.decisions"
        static let titles = "user.titles"
        static let onboardingDone = "onboarding.done"
        /// Plans that started and whose results are not stored yet (finished at the next launch).
        static let pendingFinalization = "execution.pendingFinalization"
    }

    var onboardingDone: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboardingDone) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboardingDone) }
    }

    var resolver: OrganizationStatusResolver { OrganizationStatusResolver(primaryAreas: settings.primaryAreas) }

    // MARK: Lifecycle

    /// Loads the app state once. The app and a Siri or Spotlight intent can both ask for
    /// it at launch; the second caller waits for the first instead of opening the database twice.
    func bootstrap() async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await load() }
        bootstrapTask = task
        await task.value
    }

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    private func load() async {
        guard phase == .loading else { return }
        do {
            if UITestSupport.rebuildsDatabase, let url = try? Self.databaseURL() { Self.quarantineDatabase(at: url) }
            let store = try SortlyStore(url: try Self.databaseURL())
            self.store = store
            access = await library.access()
            // A rebuilt (or newly restored) database gets the user's decisions back first.
            await restoreFromBackupIfNeeded(store)
            lastSafetyBackup = Self.safetyBackupDate()
            settings = try await store.value(OrganizationSettings.self, forKey: Key.settings) ?? OrganizationSettings()
            decisions = try await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions) ?? [:]
            userTitles = try await store.value([SortlyID: String].self, forKey: Key.titles) ?? [:]
            let map = await Task.detached(priority: .userInitiated) { try? WorldMapResource.load() }.value
            worldMap = map
            pipeline = AnalysisPipeline(
                store: store, reader: library, analyzer: VisionAnalyzer(),
                geocoder: SystemGeocoder(locale: Locale(identifier: settings.titleLanguage.rawValue)),
                map: map, conditions: DeviceConditions(), settings: settings,
                foregroundOnlineBudget: 60
            )
            await refreshDerived()
            // A plan that finished right before the app was closed stores its results now.
            await finishPendingFinalizations()
            // A plan that stopped half way (app closed during "Jetzt umsetzen") is offered
            // on the overview: continue or take back.
            interruptedPlan = try? await store.unfinishedPlans().last
            phase = onboardingDone && access.canRead ? .ready : .onboarding
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// "Neu aufbauen" on the start error screen: the damaged database is set aside (one copy
    /// is kept for support) and Albumist starts fresh. Photos and albums are not touched.
    func rebuildAfterFailure() async {
        guard case .failed = phase else { return }
        if let url = try? Self.databaseURL() {
            Self.quarantineDatabase(at: url)
        }
        bootstrapTask = nil
        phase = .loading
        await bootstrap()
        // The new database is empty: the analysis starts right away, as at a normal launch.
        if phase == .ready && access.canRead && !UITestSupport.isRunning {
            LibraryChangeWatcher.shared.start()
            startAnalysis()
        }
    }

    /// Moves the database together with its write-ahead log and shared memory file into a
    /// dated quarantine folder (the log can hold the last saved changes, so it is never just
    /// deleted). The two newest quarantines are kept for support.
    private static func quarantineDatabase(at url: URL) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent().appendingPathComponent("Quarantine", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = folder.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
                try fm.moveItem(atPath: url.path + suffix, toPath: target.appendingPathComponent(url.lastPathComponent + suffix).path)
            }
        } catch {
            // Could not move: the start fails again and shows the error instead of losing data.
            return
        }
        let old = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in old.dropFirst(2) { try? fm.removeItem(at: stale) }
    }

    // MARK: Safety backup

    /// When the decisions were last copied for the device backup (shown under Verlauf).
    private(set) var lastSafetyBackup: Date?
    /// Set when this start restored the decisions from the copy; the overview says so once.
    var restoredFromBackup: BackupRestore?

    struct BackupRestore: Equatable {
        /// When the copy was made.
        var date: Date
        var albums: Albums

        enum Albums: Equatable {
            /// The copy had no album records or history.
            case noAlbums
            /// Album records and history came back too.
            case included
            /// The copy came from another library (new iPhone): only the decisions came back.
            case otherLibrary
            /// Album records wait until Albumist may see all photos (to check the library).
            case waiting
        }
    }
    @ObservationIgnored private var safetyBackupTask: Task<Void, Never>?

    /// The copy of the user's decisions. Unlike the database it is part of the iPhone backup.
    static func safetyBackupURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(AppInfo.supportFolderName) Backup", isDirectory: true)
            .appendingPathComponent("decisions.json")
    }

    static func safetyBackupDate() -> Date? {
        guard let url = try? safetyBackupURL() else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Copies the decisions shortly after a change (several changes in a row are one write),
    /// or at once.
    func saveSafetyBackup(immediately: Bool = false) {
        guard store != nil, UITestSupport.allowsSafetyBackup else { return }
        safetyBackupTask?.cancel()
        safetyBackupTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            await self?.writeSafetyBackup()
        }
    }

    /// Writes the copy and returns once it is on disk (the app is going to the background).
    func writeSafetyBackupNow() async {
        safetyBackupTask?.cancel()
        await writeSafetyBackup()
    }

    private func writeSafetyBackup() async {
        // While album records of the copy still wait for photo access, the copy stays as it is.
        guard let store, UITestSupport.allowsSafetyBackup, pendingLibraryRestore == nil,
              let backup = try? await store.safetyBackup(), let url = try? Self.safetyBackupURL() else { return }
        // Nothing decided yet and no earlier copy: nothing to keep.
        if backup.isEmpty && !FileManager.default.fileExists(atPath: url.path) { return }
        let written: Bool = await Task.detached(priority: .utility) {
            do {
                try backup.write(to: url)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: url.path)
                return true
            } catch {
                return false
            }
        }.value
        if written { lastSafetyBackup = backup.createdAt }
    }

    /// Album records and history from the copy that still wait for photo access (to check
    /// that the copy belongs to this library). While they wait, the copy is not overwritten.
    @ObservationIgnored private var pendingLibraryRestore: SafetyBackup?

    /// Restores the copy into a database without decisions (rebuilt after damage, or a new
    /// install from an iPhone backup). The decisions come back at once; album records and
    /// history only when the copy belongs to this library, which needs photo access to check.
    /// Returns true when something was restored.
    @discardableResult
    private func restoreFromBackupIfNeeded(_ store: SortlyStore) async -> Bool {
        pendingLibraryRestore = nil
        guard UITestSupport.allowsSafetyBackup, let url = try? Self.safetyBackupURL(),
              let backup = try? SafetyBackup.read(from: url), !backup.isEmpty else { return false }
        var restored = false
        if (try? await store.hasSafetyData()) == false {
            restored = (try? await store.restore(backup, includingLibraryState: false)) == true
        }
        var albums = restoredFromBackup?.albums ?? .noAlbums
        if !backup.managedAlbums.isEmpty || !backup.plans.isEmpty, (try? await store.hasLibraryState()) == false {
            switch await belongsToThisLibrary(backup) {
            case true?:
                if (try? await store.restoreLibraryState(backup)) == true {
                    restored = true
                    albums = .included
                }
            case false?:
                // Another library (new iPhone with new album identifiers): the old album
                // records would read as "deleted by you". The copy is renewed without them.
                albums = .otherLibrary
                saveSafetyBackup(immediately: true)
            case nil:
                albums = .waiting
                pendingLibraryRestore = backup
            }
        }
        if restored || restoredFromBackup != nil {
            restoredFromBackup = BackupRestore(date: backup.createdAt, albums: albums)
        }
        return restored
    }

    /// Nil while that cannot be told yet: no photo access, or limited access that may hide
    /// the albums.
    private func belongsToThisLibrary(_ backup: SafetyBackup) async -> Bool? {
        guard !backup.managedAlbums.isEmpty else { return true }
        guard access.canRead, let inventory = try? await library.currentInventory() else { return nil }
        if backup.matchesLibrary(albums: Set(inventory.albums.map(\.id))) { return true }
        return access == .full ? false : nil
    }

    /// After the photo access was granted or widened: album records waiting in the copy
    /// come back now if they belong to this library.
    private func restoreWaitingLibraryState() async {
        guard pendingLibraryRestore != nil, access.canRead, let store else { return }
        guard await restoreFromBackupIfNeeded(store) else {
            // Another library: the card already says so; the copy was renewed.
            return
        }
        settings = (try? await store.value(OrganizationSettings.self, forKey: Key.settings)) ?? settings
        decisions = (try? await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions)) ?? decisions
        userTitles = (try? await store.value([SortlyID: String].self, forKey: Key.titles)) ?? userTitles
        await pipeline?.update(settings: settings)
        await refreshDerived()
        interruptedPlan = try? await store.unfinishedPlans().last
        saveSafetyBackup()
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
        await restoreWaitingLibraryState()
    }

    /// Reads the access again, e.g. after the user came back from the Settings app.
    func refreshAccess() async {
        access = await library.access()
        await restoreWaitingLibraryState()
    }

    func finishOnboarding(scope: OrganizationScope) {
        onboardingDone = true
        phase = .ready
        if access.canRead { LibraryChangeWatcher.shared.start() }
        ContinuedAnalysis.requestNotificationPermission()
        startAnalysis(scope: scope, userInitiated: true)
    }

    // MARK: Settings

    func saveSettings() {
        let settings = settings
        Task {
            try? await store?.setValue(settings, forKey: Key.settings)
            saveSafetyBackup()
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
                        let model = AppModel.shared
                        // Trips and places are ready before the image analysis: show them now.
                        if progress.stage == .content, model.analysis.stage != .content, model.snapshot == nil {
                            Task { await model.refreshDerived() }
                        }
                        // First scan: the photos are known after reading the library (for the scan show).
                        if progress.stage == .patterns, model.analysis.stage == .inventory, model.facts.isEmpty {
                            Task { await model.refreshDerived() }
                        }
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
            // Trip identities (names and corrections stay with their trip) are kept in the copy.
            saveSafetyBackup()
            // "Analyse fertig" only when it really finished (not paused, stopped or failed).
            if analysis.lastReport?.isComplete == true, !Task.isCancelled {
                ContinuedAnalysis.notifyFinished(openSuggestions: openProposals.count)
            }
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
            saveSafetyBackup(immediately: true)
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
            // Albumist's own albums overlap on purpose (a country holds its trips).
            let own = Set(managedAlbums.map(\.albumID))
            mergeSuggestions = await Task.detached(priority: .utility) { AlbumOverlapAnalyzer().suggestions(in: inventory, excluding: own) }.value
            let plans = try await store.planHistory(limit: historyLimit + 1)
            historyHasMore = plans.count > historyLimit
            history = plans.prefix(historyLimit).filter { $0.reverts == nil }
            undonePlans = try await store.undoneTargets()
            // Photos that could not be read yet (failed attempts) do not count as looked at.
            let analyzed = Set(try await store.results(ContentAnalysis.self, kind: "content").filter { $0.value.failedAttempts == nil }.keys)
            let stored = try await store.overrides()
            let overrides = OverrideSet(stored)
            var removed: [SortlyID: Set<AssetID>] = [:]
            for o in stored where o.decision == .neverAdd {
                if case .assetInSource(let asset, let source) = o.scope { removed[source, default: []].insert(asset) }
            }
            removedFromProposals = removed
            let facts = facts, snapshot = snapshot, settings = settings
            let computed = await Task.detached(priority: .userInitiated) {
                LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides, contentAnalyzed: analyzed)
            }.value
            states = computed
            progress = resolver.progress(computed.values)
        } catch {
            message = error.localizedDescription
        }
        SpotlightIndex.scheduleUpdate(self)
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

    /// The best suggestions for a first round ("Dein Startpaket"): safe ones only (at least
    /// likely, nothing sensitive, no name needed, a clear action), trips and places first,
    /// then the biggest. Returned in display order, the order the preview lists them in.
    func starterSet(limit: Int) -> [AlbumProposal] {
        func rank(_ p: AlbumProposal) -> Int {
            switch p.kind.area {
            case .trips: 2
            case .places: 1
            default: 0
            }
        }
        return Array(openProposals
            .filter { $0.reliability >= .likely && !$0.isSensitive && !$0.requiresUserName && recommendedDecision(for: $0).isAccepted }
            .sorted { (rank($0), $0.assetIDs.count, $1.title) > (rank($1), $1.assetIDs.count, $0.title) }
            .prefix(limit)).inDisplayOrder()
    }

    /// "Die ersten N jetzt anlegen": keeps the biggest accepted suggestions within the free
    /// albums; the others go back to the open list (nothing is lost) and the plan is rebuilt.
    func keepFirstAccepted(_ limit: Int) async {
        let accepted = acceptedProposals.sorted { ($0.assetIDs.count, $1.title) > ($1.assetIDs.count, $0.title) }
        for p in accepted.dropFirst(max(0, limit)) { decisions[p.id] = nil }
        persistDecisions()
        await buildPlan()
    }

    func accept(_ proposals: [AlbumProposal]) {
        for p in proposals { setDecision(recommendedDecision(for: p), for: p) }
    }

    /// Decisions set only for a preview opened straight from a button ("Dein Startpaket",
    /// "Album anlegen"), with what was there before.
    struct PreviewSelection {
        fileprivate var entries: [(proposal: AlbumProposal, previous: ProposalDecision?, chosen: ProposalDecision)]
    }

    /// Selects suggestions for a preview. Leaving the preview without creating anything must
    /// undo this with `endPreview(_:)`: nothing may stay selected that the user never chose
    /// (Fuchs, 14.11.: "Ich hatte aber noch nichts ausgewählt").
    func selectForPreview(_ items: [(AlbumProposal, ProposalDecision)]) -> PreviewSelection {
        let entries = items.map { (proposal: $0.0, previous: decisions[$0.0.id], chosen: $0.1) }
        // In memory only: if the app is closed during the preview, nothing stays selected.
        for e in entries {
            if previewOnly[e.proposal.id] == nil { previewOnly[e.proposal.id] = .some(e.previous) }
            decisions[e.proposal.id] = e.chosen
        }
        return PreviewSelection(entries: entries)
    }

    /// Back from a preview: decisions that are still the preview's own go back to what they
    /// were. Applied suggestions were already cleared by the execution and stay as they are.
    func endPreview(_ selection: PreviewSelection) {
        for e in selection.entries {
            // Chosen on purpose meanwhile (or already applied and cleared): stays as it is.
            guard previewOnly.removeValue(forKey: e.proposal.id) != nil, decisions[e.proposal.id] == e.chosen else { continue }
            decisions[e.proposal.id] = e.previous
        }
    }

    /// "Auswahl aufheben" on the preview: every selected suggestion goes back to the open list.
    func clearSelection() {
        for (id, decision) in decisions where decision.isAccepted { decisions[id] = nil }
        previewOnly.removeAll()
        persistDecisions()
    }

    var acceptedProposals: [AlbumProposal] {
        proposals.filter { decisions[$0.id]?.isAccepted == true }
    }

    /// Selected suggestions that still change something in Photos: an album that is kept
    /// as it is needs nothing, so it does not count on the "N ausgewählte Alben anlegen" button.
    var proposalsToApply: [AlbumProposal] {
        proposals.filter { p in
            guard let decision = decisions[p.id] else { return false }
            return decision.isAccepted && !decision.isKeepExisting
        }
    }

    func setDecision(_ decision: ProposalDecision, for proposal: AlbumProposal) {
        let wasRejected = decisions[proposal.id] == .reject
        decisions[proposal.id] = decision
        previewOnly[proposal.id] = nil // chosen on purpose now
        persistDecisions()
        if decision == .reject {
            let override = UserOverride(scope: .source(proposal.id), decision: .rejectProposal)
            Task {
                try? await store?.addOverride(override)
                saveSafetyBackup()
            }
        } else if wasRejected || decision.isAccepted {
            // "Nicht jetzt" is reversible: accepting later lifts the stored rejection.
            Task { await removeRejection(of: [proposal.id]) }
        }
    }

    /// Removes stored "Nicht jetzt" rejections, so the suggestions can be offered and applied again.
    private func removeRejection(of sources: Set<SortlyID>?) async {
        guard let store, let all = try? await store.overrides() else { return }
        for o in all where o.decision == .rejectProposal {
            guard case .source(let s) = o.scope, sources?.contains(s) ?? true else { continue }
            try? await store.removeOverride(o.id)
        }
        saveSafetyBackup()
    }

    /// Number of suggestions the user put aside with "Nicht jetzt".
    func rejectedProposalCount() async -> Int {
        guard let all = try? await store?.overrides() else { return 0 }
        return all.filter { o in
            if o.decision == .rejectProposal, case .source = o.scope { return true }
            return false
        }.count
    }

    /// "Abgelehnte Vorschläge wieder zeigen": every rejection is lifted and the suggestions
    /// are built again.
    func restoreRejectedProposals() async {
        await removeRejection(of: nil)
        for (id, decision) in decisions where decision == .reject { decisions[id] = nil }
        persistDecisions()
        startAnalysis(userInitiated: true)
    }

    /// Overrides for planning. A suggestion the user accepted after "Nicht jetzt" is not
    /// skipped, even if its stored rejection has not been removed yet.
    private func planningOverrides(_ store: SortlyStore) async throws -> OverrideSet {
        let accepted = Set(decisions.filter { $0.value.isAccepted }.map(\.key))
        return OverrideSet(try await store.overrides().filter { o in
            if o.decision == .rejectProposal, case .source(let s) = o.scope, accepted.contains(s) { return false }
            return true
        })
    }

    /// "Passt nicht": this album is never offered for this suggestion again. A decision that
    /// pointed at the album is dropped, and the matching runs again right away.
    func rejectMatch(_ album: CollectionID, for proposal: AlbumProposal) async {
        guard let store else { return }
        do {
            try await store.addOverride(UserOverride(scope: .albumForSource(album, proposal.id), decision: .notMatchingAlbum))
            saveSafetyBackup()
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
        Task { [userTitles] in
            try? await store?.setValue(userTitles, forKey: Key.titles)
            saveSafetyBackup()
        }
    }

    private func persistDecisions() {
        let decisions = storedDecisions(decisions)
        Task {
            try? await store?.setValue(decisions, forKey: Key.decisions)
            saveSafetyBackup()
        }
        SpotlightIndex.scheduleUpdate(self)
    }

    /// What may be written to disk: preview-only selections are replaced by what was there before.
    private func storedDecisions(_ current: [SortlyID: ProposalDecision]) -> [SortlyID: ProposalDecision] {
        var result = current
        for (id, previous) in previewOnly { result[id] = previous }
        return result
    }

    // MARK: Plan and execution

    func buildPlan() async {
        guard let store else { return }
        // The user's latest changes in Photos count before anything is planned.
        guard await reconcileManagedAlbums() else { return }
        do {
            let current = try await library.currentInventory()
            let overrides = try await planningOverrides(store)
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
        guard await reconcileManagedAlbums() else { return nil }
        do {
            let current = try await library.currentInventory()
            let overrides = try await planningOverrides(store)
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

    /// Applies a reviewed plan. Only one plan runs at a time.
    func execute(_ plan: ChangePlan) async {
        guard claimExecution() else { return }
        defer { releaseExecution() }
        await run(plan)
    }

    private func claimExecution() -> Bool {
        guard !executionClaimed, !execution.isRunning else { return false }
        executionClaimed = true
        return true
    }

    private func releaseExecution() { executionClaimed = false }

    /// Runs a plan; the caller holds the execution claim. `resume`: an interrupted plan that
    /// was confirmed before (its free albums were checked then).
    private func run(_ plan: ChangePlan, resume: Bool = false) async {
        guard let store else { return }
        // The free albums are checked here too, not only on the review screen.
        let wanted = plan.summary.newAlbums + plan.summary.extendedAlbums
        if plan.reverts == nil, !resume, !Purchases.shared.allows(albums: wanted) {
            execution = ExecutionState(planID: plan.id, failure: String(localized: "Die Gratis-Alben reichen für diese Änderungen nicht. Schalte Albumist frei, um weiterzumachen."))
            return
        }
        var confirmed = plan
        if confirmed.status == .draft { confirmed.status = .confirmed }
        if confirmed.confirmedAt == nil { confirmed.confirmedAt = Date() }
        let planID = confirmed.id
        execution = ExecutionState(isRunning: true, planID: planID, completedSteps: 0, totalSteps: plan.steps.count)
        let executor = ChangeExecutor(library: library, store: store)
        do {
            // Remembered before anything runs: if the app is closed after the plan finished
            // but before its results were stored, the next launch stores them.
            try await setPendingFinalization(adding: planID)
            let result = try await executor.execute(confirmed) { event in
                if case .stepFinished(let index, let state) = event {
                    let succeeded: Bool = if case .succeeded = state { true } else { false }
                    Task { @MainActor in
                        let model = AppModel.shared
                        guard model.execution.planID == planID else { return }
                        if !succeeded { model.execution.unsuccessfulSteps.insert(index) }
                        model.execution.completedSteps = index + 1
                    }
                }
            }
            execution.finished = result
            if result.status == .completed || result.status == .completedWithErrors {
                await finalize(result)
            }
        } catch {
            execution.failure = error.localizedDescription
        }
        execution.isRunning = false
        self.plan = nil
        startAnalysis()
    }

    /// Everything that follows a finished plan, stored in one transaction: Albumist's albums,
    /// applied suggestions leaving the open list, and the plan marked as finalized. The free
    /// albums are counted once per plan, from what really changed.
    private func finalize(_ result: ChangePlan) async {
        guard let store else { return }
        do {
            let after = try await library.currentInventory()
            try await store.saveInventory(after)
            inventory = after
            let states = ManagedAlbumTracker().record(result, into: try await store.managedAlbums(), inventory: after)
            var newDecisions = decisions
            if result.reverts == nil {
                // Applied proposals leave the open list; other accepted ones stay accepted.
                let applied = Set(result.steps.compactMap(\.sourceID))
                for id in applied where newDecisions[id]?.isAccepted == true {
                    newDecisions[id] = nil
                    previewOnly[id] = nil
                }
                // Counted before the store write: counting twice is impossible (per plan id),
                // and a crash in between is completed at the next launch.
                let applied2 = result.appliedSummary
                Purchases.shared.recordUsage(plan: result.id, albums: applied2.newAlbums + applied2.extendedAlbums)
            }
            var done = result
            done.finalizedAt = Date()
            let pending = (try await store.value([SortlyID].self, forKey: Key.pendingFinalization) ?? []).filter { $0 != result.id }
            try await store.finalize(done, managedAlbums: states, values: [
                Key.decisions: storedDecisions(newDecisions),
                Key.pendingFinalization: pending,
            ])
            decisions = newDecisions
            managedAlbums = states
            saveSafetyBackup()
            SpotlightIndex.scheduleUpdate(self)
            // Suggestions see the new albums at once (e.g. "Album vollständig").
            if let rematched = try await pipeline?.rematch() { snapshot = rematched }
        } catch {
            message = error.localizedDescription
        }
    }

    private func setPendingFinalization(adding id: SortlyID? = nil, removing gone: Set<SortlyID> = []) async throws {
        guard let store else { return }
        var pending = try await store.value([SortlyID].self, forKey: Key.pendingFinalization) ?? []
        if let id, !pending.contains(id) { pending.append(id) }
        pending.removeAll { gone.contains($0) }
        try await store.setValue(pending, forKey: Key.pendingFinalization)
    }

    /// At launch: plans that finished but whose results were not stored yet are finalized now;
    /// plans that never started or were dropped leave the list. An interrupted plan stays
    /// (it is offered to continue or take back).
    private func finishPendingFinalizations() async {
        guard let store, let pending = try? await store.value([SortlyID].self, forKey: Key.pendingFinalization), !pending.isEmpty else { return }
        var drop = Set<SortlyID>()
        for id in pending {
            guard let plan = try? await store.plan(id) else { drop.insert(id); continue }
            switch plan.status {
            case .completed, .completedWithErrors:
                if plan.finalizedAt == nil { await finalize(plan) } else { drop.insert(id) }
            case .running, .confirmed:
                continue
            case .draft, .cancelled:
                drop.insert(id)
            }
        }
        if !drop.isEmpty { try? await setPendingFinalization(removing: drop) }
    }

    /// Merge plan for overlapping albums: the largest album receives the missing media of
    /// the others. The other albums stay unless the user removes them later (prompt §3).
    /// The target keeps its name exactly as it is.
    func mergePlan(_ suggestion: AlbumOverlapAnalyzer.MergeSuggestion) async -> ChangePlan? {
        guard let store else { return nil }
        guard await reconcileManagedAlbums() else { return nil }
        do {
            let current = try await library.currentInventory()
            let albums = suggestion.albumIDs.compactMap { current[$0] }
            guard let target = albums.max(by: { $0.assetIDs.count < $1.assetIDs.count }) else { return nil }
            let proposal = AlbumProposal(id: SortlyID(), kind: .rule, title: target.title, assetIDs: [], reliability: .certain)
            let decision = ProposalDecision.merge(target: target.id, sources: albums.map(\.id), title: nil, folderPath: nil, removeSourceAlbums: false)
            let overrides = OverrideSet(try await store.overrides())
            return OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Plan for photos the user put into an album by hand: an existing album is extended,
    /// otherwise a new album is created (in the Albumist folder). Goes through the normal review.
    func manualPlan(assets: [AssetID], target: CollectionID?, newTitle: String?) async -> ChangePlan? {
        guard let store, !assets.isEmpty else { return nil }
        guard await reconcileManagedAlbums() else { return nil }
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

    // MARK: Albums created by Albumist

    /// Detects changes the user made in the Photos app (renamed, deleted, photos removed)
    /// and turns them into overrides, so Albumist never undoes a manual decision. Returns
    /// false only if what it found could not be stored; planning then waits.
    @discardableResult
    private func reconcileManagedAlbums() async -> Bool {
        guard let store, let stored = try? await store.managedAlbums() else { return true }
        // Only with full access: a limited library would look like deleted albums and photos.
        guard !stored.isEmpty, !execution.isRunning, await library.access() == .full,
              let current = try? await library.currentInventory() else {
            managedAlbums = stored
            return true
        }
        let result = ManagedAlbumTracker().reconcile(stored, with: current)
        // An empty album list is a valid answer (the user deleted the last album). Only when
        // every remembered album seems gone at once, a second read has to confirm it.
        if result.updatedStates.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            guard let again = try? await library.currentInventory(),
                  stored.allSatisfy({ again[$0.albumID] == nil }) else {
                managedAlbums = stored
                return true
            }
        }
        if !result.changes.isEmpty {
            do {
                // Overrides and the new last-known state in one transaction: a manual change
                // is never marked as seen without its override.
                try await store.applyReconciliation(overrides: result.newOverrides, managedAlbums: result.updatedStates)
                saveSafetyBackup()
            } catch {
                managedAlbums = stored
                message = error.localizedDescription
                return false
            }
        }
        managedAlbums = result.updatedStates
        return true
    }

    /// Plan that takes Albumist's additions back out of one album (shown in the normal review).
    func removalPlan(for state: ManagedAlbumState) async -> ChangePlan? {
        guard await reconcileManagedAlbums() else { return nil }
        // The state may have changed with the reconciliation (photos the user took out).
        guard let fresh = managedAlbums.first(where: { $0.albumID == state.albumID }) else { return nil }
        do {
            let current = try await library.currentInventory()
            let plan = ManagedAlbumTracker().removalPlan(for: fresh, current: current)
            return plan.steps.isEmpty ? nil : plan
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// After a removal the suggestion behind the album is not offered again.
    func forgetProposal(_ source: SortlyID) async {
        try? await store?.addOverride(UserOverride(scope: .source(source), decision: .rejectProposal))
        saveSafetyBackup()
        await refreshDerived()
    }

    /// Finishes an interrupted plan. Steps that already ran are skipped; a step that was
    /// running is checked against the library first, so nothing is created twice. Photos the
    /// user has taken out of an album since then are not added anymore.
    func resumeInterruptedPlan() async {
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        guard await reconcileManagedAlbums() else { return }
        execution = ExecutionState()
        let overrides = (try? await store.overrides()).map { OverrideSet($0) } ?? OverrideSet()
        await run(interrupted.respecting(overrides), resume: true)
        if execution.failure == nil { interruptedPlan = nil }
    }

    /// Takes back what an interrupted plan already did, and drops the rest. Steps the
    /// interruption left open are first checked against the library (an album created or
    /// photos added right before the app was closed are taken back too).
    func undoInterruptedPlan() async {
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        do {
            let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
            let current = try await library.currentInventory()
            var undoPlan = UndoPlanner().undoPlan(for: settled, current: current)
            undoPlan.status = .confirmed
            undoPlan.confirmedAt = Date()
            var cancelled = settled
            cancelled.status = .cancelled
            // Both in one transaction: the undo is journaled before the plan stops being offered.
            try await store.save([cancelled] + (undoPlan.steps.isEmpty ? [] : [undoPlan]))
            try? await setPendingFinalization(removing: [interrupted.id])
            if !undoPlan.steps.isEmpty { await run(undoPlan) }
            interruptedPlan = nil
            await refreshDerived()
        } catch {
            message = error.localizedDescription
        }
    }

    func undo(_ executed: ChangePlan) async {
        // Taking back the same plan twice would find nothing to do (or remove what the user
        // added in the meantime), so a plan is undone once.
        guard let store, !undonePlans.contains(executed.id), executed.reverts == nil, claimExecution() else { return }
        defer { releaseExecution() }
        // What the user changed by hand since counts first: a photo they took out and put back
        // is theirs now and stays.
        guard await reconcileManagedAlbums() else { return }
        do {
            let current = try await library.currentInventory()
            var owned: [CollectionID: Set<AssetID>] = [:]
            for state in managedAlbums { owned[state.albumID, default: []].formUnion(state.addedBySortly) }
            let undoPlan = UndoPlanner().undoPlan(for: executed, current: current, owned: owned)
            await run(undoPlan)
            if let result = execution.finished, result.reverts == executed.id, result.status == .completed {
                undonePlans.insert(executed.id)
                // Albums that are gone again do not count against the free albums.
                let summary = executed.appliedSummary
                Purchases.shared.returnUsage(plan: executed.id, albums: summary.newAlbums + summary.extendedAlbums)
                // A removal that is taken back lets its suggestions come back as well.
                let sources = executed.removalSources
                if !sources.isEmpty {
                    for o in try await store.overrides() where o.decision == .rejectProposal {
                        if case .source(let s) = o.scope, sources.contains(s) { try await store.removeOverride(o.id) }
                    }
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// "Ältere anzeigen" in the history.
    func loadMoreHistory() async {
        historyLimit += 50
        await refreshDerived()
    }

    // MARK: Library and search

    func bucketMembers(_ bucket: InboxBucket) -> [AssetFacts] {
        access(keyPath: \.facts)
        access(keyPath: \.states)
        access(keyPath: \.settings)
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
            saveSafetyBackup()
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
            // Every text hit counts: the number shown and an album made from the search include all.
            textHits = Set((try? await store.searchText(parsed.filter.freeText.joined(separator: " "), limit: 1_000_000)) ?? [])
        }
        let overall = states.mapValues { resolver.overall($0) }
        let results = SearchEngine().search(parsed.filter, in: facts, statuses: overall, textHits: textHits)
        return (parsed.tokens, results)
    }

    // MARK: Reset

    /// "Analyse neu aufbauen": a running analysis stops first and is waited for, so it cannot
    /// write old results into the fresh tables; Spotlight forgets the old results too.
    func resetAnalysis() async {
        if analysis.isRunning {
            await pipeline?.pause()
            analysisTask?.cancel()
            await analysisTask?.value
            // A background refinement has no task to wait for: give it until its next check.
            var waited = 0
            while analysis.isRunning && waited < 150 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
        }
        do {
            try await store?.resetAnalysis(includingDecisions: false)
        } catch {
            message = error.localizedDescription
        }
        snapshot = nil
        SpotlightIndex.clear()
        await refreshDerived()
    }
}
