import Foundation
import Synchronization
import AlbumistCore
import AlbumistStore

/// Pause for one run, set by the app without waiting for the pipeline actor. A Pause tapped
/// while the run is still starting is not lost (the run used to clear the flag when it began),
/// and a Pause that arrives after its run ended cannot stop the next one.
public final class AnalysisRunControl: Sendable {
    /// Someone waiting for the Pause (`untilPaused`), or one that was cancelled before it waited.
    private enum Waiter {
        case waiting(CheckedContinuation<Void, Never>)
        case cancelled
    }

    private struct State {
        var paused = false
        var waiters: [Int: Waiter] = [:]
        var nextID = 0
    }

    private let state = Locked(State())
    public init() {}

    public func pause() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.paused = true
            defer { state.waiters = [:] }
            return state.waiters.values.compactMap { waiter in
                if case .waiting(let continuation) = waiter { return continuation }
                return nil
            }
        }
        for continuation in waiting { continuation.resume() }
    }

    public var isPaused: Bool { state.withLock { $0.paused } }

    /// Returns once the run is paused, or as soon as the calling task is cancelled.
    func untilPaused() async {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    // Paused already, or cancelled before it got here.
                    if state.paused || state.waiters.removeValue(forKey: id) != nil { return true }
                    state.waiters[id] = .waiting(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if case .waiting(let continuation) = state.waiters.removeValue(forKey: id) { return continuation }
                if !state.paused { state.waiters[id] = .cancelled }
                return nil
            }
            waiting?.resume()
        }
    }

    /// `work`, cancelled as soon as the run is paused (review P4-07: the photos in work were
    /// finished first, an iCloud original for up to 180 s, while the card said "Wird
    /// angehalten"). When the Pause comes before `work` ends, this throws `CancellationError`,
    /// whatever `work` ends with after its cancellation (an analyzer may answer the cancel with
    /// an error of its own): a photo given up for the Pause is never counted against it. A
    /// result that came before the Pause is returned as usual; a Pause before the call throws
    /// at once.
    func cancellingOnPause<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        if isPaused { throw CancellationError() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                await self.untilPaused()
                return nil
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw CancellationError() }
            return value
        }
    }
}

/// Snapshot of the latest proposals, stored so the app opens instantly (prompt §14).
public struct ProposalSnapshot: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var scope: OrganizationScope
    public var proposals: [AlbumProposal]
    /// Matches of the shown and of the dismissed suggestions.
    public var matches: [AlbumistID: MatchResult]
    /// Suggestions the user dismissed: never shown, but an own album that fits one still
    /// counts as sorted (`Suggestions`).
    public var dismissed: [AlbumProposal] = []
    /// Albums that stand for photos without an album of their own (`StandIn`).
    public var standIns: [StandIn] = []
    /// The early set of a first run (trips and places, before the image analysis). The full
    /// set that replaces it keeps every suggestion of it the user already decided on.
    public var isEarly = false
    /// `AlbumMatcher.version` of `matches`. Results of an older version (0: stored before the
    /// stamp) are matched again at launch (`refreshMatchesIfOutdated`).
    public var matcherVersion: Int
    /// Photos the suggestions were made with although their date is later than `generatedAt`
    /// (a camera with its clock set wrong, "2031"). They count like every photo the suggestions
    /// saw, not as taken afterwards (`LibraryStatus`, review P1-03). Usually none.
    public var datedAfterwards: Set<AssetID> = []

    public init(generatedAt: Date, scope: OrganizationScope, proposals: [AlbumProposal], matches: [AlbumistID: MatchResult],
                dismissed: [AlbumProposal] = [], standIns: [StandIn] = [], isEarly: Bool = false,
                matcherVersion: Int = AlbumMatcher.version) {
        self.generatedAt = generatedAt
        self.scope = scope
        self.proposals = proposals
        self.matches = matches
        self.dismissed = dismissed
        self.standIns = standIns
        self.isEarly = isEarly
        self.matcherVersion = matcherVersion
    }

    enum CodingKeys: String, CodingKey { case generatedAt, scope, proposals, matches, dismissed, standIns, isEarly, matcherVersion, datedAfterwards }

    /// Snapshots stored before dismissed suggestions and stand-ins were kept still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        scope = try c.decode(OrganizationScope.self, forKey: .scope)
        proposals = try c.decode([AlbumProposal].self, forKey: .proposals)
        matches = try c.decode([AlbumistID: MatchResult].self, forKey: .matches)
        dismissed = try c.decodeIfPresent([AlbumProposal].self, forKey: .dismissed) ?? []
        standIns = try c.decodeIfPresent([StandIn].self, forKey: .standIns) ?? []
        isEarly = try c.decodeIfPresent(Bool.self, forKey: .isEarly) ?? false
        matcherVersion = try c.decodeIfPresent(Int.self, forKey: .matcherVersion) ?? 0
        datedAfterwards = try c.decodeIfPresent(Set<AssetID>.self, forKey: .datedAfterwards) ?? []
    }
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
        /// Set while the stage waits for Apple's geocoder (its limit of about 40 lookups a
        /// minute, or after it refused): about how long the wait still takes. Said every 2 s,
        /// so the card can show the wait instead of a count that stands for up to a minute;
        /// `nil` again when the lookups go on.
        public var waitLeft: Duration? = nil
        /// Said once, with the end of the trips step: how much work the run has (the bar's
        /// widths and the finish time come from it).
        public var workload: AnalysisWorkload? = nil
        /// The image step: the last photos looked at (never screenshots: B4), for the card's
        /// "Gerade angesehen".
        public var recent: [AssetID] = []
        /// Said once, right after the first run saved its early suggestions (trips, places):
        /// the overview reads them now for "Schon fertig". The report that starts the image
        /// step comes before they are saved, so reading at that report found nothing (review I2).
        /// They are made beside the first photos (see `run`): this report repeats the image
        /// step's newest count, so the count never goes back.
        public var earlyProposals = false
        /// The places step's pass over the offline map: how many photos are checked so far.
        /// With towns on (the default) no place is final before its online lookup, so this is
        /// what moves while the pass runs (review of d612bc0: "0 von 50.233 Orten" for 60 s).
        public var mapPass: MapPass? = nil

        /// One value for the whole run (0…1), so a bar never jumps back when the next stage starts.
        public static func overall(stage: Stage, completed: Int, total: Int) -> Double {
            let before = Stage.allCases.prefix { $0 != stage }.reduce(0) { $0 + $1.share }
            let within = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0
            return min(1, before + stage.share * within)
        }
    }

    public struct MapPass: Sendable, Hashable {
        public var checked: Int
        public var of: Int
        public init(checked: Int, of: Int) {
            self.checked = checked
            self.of = of
        }
    }

    public struct Report: Sendable, Hashable {
        public var completedStages: [Stage] = []
        /// Trips and places were offered before the image analysis was done (first run only).
        public var earlyProposals = false
        /// The early suggestions failed (the error, for the diagnostic report). The run went
        /// on without them: the full set at its end replaces them.
        public var earlyProposalsFailure: String?
        public var pausedBecause: PauseReason?
        public var newOrChanged = 0
        /// Photos deleted from the store: gone from the library, read with full access.
        public var removed = 0
        /// Photos set aside because "Ausgewählte Fotos" hides them (review P1-07): kept with
        /// their analysis, left out of everything until they are read again.
        public var setAside = 0
        public var placesResolved = 0
        public var placesPendingOnline = 0
        public var onlineRequests = 0
        public var contentAnalyzed = 0
        /// Of `contentAnalyzed`: photos analysed before that got their labels now: only their
        /// labels, or one more full look for a photo given up before (it has nothing to add the
        /// labels to). Either way no new photo (second review of the labels fix, nit).
        public var labelsAdded = 0
        /// Of `contentAnalyzed`: the photos looked at in full, without those that only got
        /// their labels ("Themen" or "Dokumente" turned on later). The overview calls only these
        /// new photos (review of the labels fix, M2: "Beim Prüfen 5.683 neue Fotos analysiert"
        /// after "Themen" was turned on, with no new photo at all), and without photos given up
        /// as unreadable and read again a week later (`givenUpReadAgain`, second review of P1-08).
        public var newPhotosAnalyzed: Int { max(0, contentAnalyzed - labelsAdded - givenUpReadAgain) }
        /// Of `contentAnalyzed`: photos given up as unreadable that were read in their weekly
        /// further try (`reopenGivenUpPhotos`), not counted in `labelsAdded`.
        public var givenUpReadAgain = 0
        public var textRecognized = 0
        public var textWaitingForOriginal = 0
        /// How long reading the texts took in this run (diagnostic report: photos per minute).
        public var textSeconds: Double = 0
        public var proposals = 0
        /// Vision failed for several photos in a row (not the photos' fault, e.g. no graphics
        /// hardware in the background): the run stopped without counting those against them.
        public var analyzerUnavailable = false
        /// Apple's geocoder kept refusing: the remaining town names wait for a later run.
        public var placesThrottled = false
        /// The settings this run read for its work, each where it read it: a change after that
        /// point is decided at the run's end (`AnalysisRunEnd`).
        public var settingsUsed = SettingsUsed()

        public var isComplete: Bool { pausedBecause == nil && completedStages.count == Stage.allCases.count }

        public init() {}
    }

    public static let contentVersion = 1
    /// Version of the image labels a photo has (`assets.labels_version`; 0: none). Labels are
    /// asked for only while "Themen" or "Dokumente" is on (`wantsLabels`). Turned on later,
    /// the photos analysed without them get their labels in the image step of the next run,
    /// and only those (no second full look, no text read again). The store's migration 5
    /// marks photos of earlier versions that have labels with 1.
    public static let labelsVersion = 1
    /// 2: screenshot categories with whole-word flight rules and short keywords as whole words
    /// (first device test 15.11.); every stored screenshot is read once more.
    /// Not raised for `DocumentAnalyzer` reporting cards, IDs and medical papers without a
    /// document type as `.other` (second review of the build 36 fix): texts read before keep no
    /// document facts for them, and `PreviewRank` hides such pictures from what is stored. For
    /// photos: taken for a document without document facts. For screenshots too (third review:
    /// an ID or medical screenshot read before was stored with an empty text and no document
    /// facts): any picture with an empty stored text and no document facts, and a screenshot
    /// whose text is not read. Card and financial words in the stored text count for both.
    /// `.other` makes no album. What is stored of a text and its masks did not change, so no
    /// text needs reading again.
    public static let textVersion = 2
    /// Both versions together: a marker that kept another one was written before an update
    /// that changed the analysis ("Analyse nach Update", `ResumedRun`).
    public static var analysisVersion: String { "\(contentVersion).\(textVersion)" }
    /// Analyzer errors in a row after which a run stops instead of going through every photo:
    /// when Vision itself fails, each further photo would fail the same way.
    static let analyzerFailureLimit = 5

    enum Key {
        static let trips = "analysis.trips"
        /// Where in the library's change history the stored photos and albums are
        /// (`LibraryReadMark`). An analysis key: "Analyse neu aufbauen" and the safety copy
        /// leave it out, so a database put back or rebuilt reads the whole library first.
        static let libraryMark = "analysis.libraryMark"
        static let frequentPlaces = "analysis.frequentPlaces"
        /// Places of the analysis before whose photos are set aside under "Ausgewählte Fotos"
        /// and that the selection does not make (review P1-07): kept for their ids, so they come
        /// back with them (name, "Nicht jetzt", album). Never shown or counted.
        static let frequentPlacesOutOfView = "analysis.frequentPlacesOutOfView"
        static let groups = "analysis.groups"
        static let tripCorrections = "user.tripCorrections"
        /// The user's answers to "Bist du hier öfter?" (part of the decisions copy in the backup).
        static let recurringPlaces = "user.recurringPlaces"
        /// Places to ask about, where each trip was, the photos of the places the user is often at.
        static let recurringPlaceReport = "analysis.recurringPlaces"
        /// Trip identities across runs (kept by "Analyse neu aufbauen", like other user data).
        static let tripIdentities = "user.tripIdentities"
        static let groupingFeedback = "user.groupingFeedback"
        /// Version of the masks the stored texts went through (see `TextMinimizer.maskVersion`).
        static let textMaskVersion = "analysis.textMaskVersion"
        /// The language the stored places' countries and regions are named in (review P1-12).
        static let placesLanguage = "analysis.placesLanguage"
        /// The region part of place keys, fixed per region (`OfflineWorldMap.RegionKeys`). The
        /// user's decisions hang on the ids made from it, so it is kept like them: "Analyse neu
        /// aufbauen" leaves it and the safety copy carries it (third review of P1-12).
        static let regionKeys = "user.regionKeys"
        /// Where 638ff85 stored the table; moved to `regionKeys` once.
        static let regionKeysBefore = "analysis.regionKeys"
        static let proposals = "analysis.proposals"
        /// Photos whose country cannot be found (`PlaceResolutionService.Outcome.withoutCountry`,
        /// review P1-09): they count like photos without a location.
        static let placesWithoutCountry = "analysis.placesWithoutCountry"
        /// When the image step last looked for photos given up as unreadable that are due for
        /// another read (`reopenGivenUpPhotos`).
        static let givenUpChecked = "analysis.givenUpChecked"
        /// Photos taken where the user lives (`TripAnalysis.atHome`), from the last analysis.
        static let home = "analysis.home"
        /// What the user set in "Dein Zuhause" (part of the decisions copy in the backup, kept
        /// by "Analyse neu aufbauen").
        static let homeSettings = "user.home"
        /// The home Albumist found by itself, from the last analysis (`DetectedHome`).
        static let detectedHome = "analysis.detectedHome"
        /// The trial run's year chosen at the start (kept by "Analyse neu aufbauen").
        static let scope = "user.analysisScope"
        /// The user's decisions on suggestions (written by the app; here only to set decisions
        /// back to open after a rule update, together with the new matches).
        static let decisions = "user.decisions"
        /// The names the user typed for suggestions in the app (written by the app; read here so
        /// a named suggestion is kept, `AnalysisSnapshot.chosen`).
        static let titles = "user.titles"
        /// "suggestion|album" of each "ergänzen" set back to open because the album recorded for
        /// the suggestion holds other photos (`refreshMatchesIfOutdated`): never twice.
        static let reopenedExtensions = "user.reopenedExtensions"
        /// Suggestions the user chose before a change in "Dein Zuhause" would have changed or
        /// dropped them: kept as chosen (`HeldSuggestions`).
        static let heldSuggestions = "user.heldSuggestions"
        /// A change in "Dein Zuhause" no suggestions were made for yet (`PendingHomeChange`).
        static let pendingHomeChange = "analysis.pendingHomeChange"
        /// The clock of photos whose place tells no time zone (review P1-15, `LocalTime`): the
        /// iPhone's time zone at the first analysis, as an IANA identifier. Stored once and kept
        /// when the iPhone travels, so its time zone during an analysis changes no album. Kept
        /// like the user's settings: "Analyse neu aufbauen" leaves it, the safety copy carries it.
        /// A database from before gets the time zone of its first run after the update.
        static let homeTimeZone = "user.homeTimeZone"
    }

    let store: AlbumistStore
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
    /// Bumped whenever "Dein Zuhause" or the places the user is often at changed (after the
    /// change is stored): a run that detected its trips before that detects them again before it
    /// makes suggestions, so its suggestions never undo the change; and suggestions made from the
    /// settings before it leave the change pending (`PendingHomeChange`).
    private var homeGeneration = 0
    /// Bumped whenever the stored suggestions are replaced: `rematch()` matches again when new
    /// suggestions came while it matched, instead of writing older ones back.
    private var proposalsGeneration = 0
    /// Changes in "Dein Zuhause" between checking for a `PendingHomeChange` and storing
    /// themselves: while one is, suggestions that finish keep the mark (they could remove the one
    /// the change saw and leave it unmarked).
    private var homeChangesBeingStored = 0
    /// Tests only: runs after `setHomeChange` checked for a pending change, before it stores.
    var afterPendingCheck: (@Sendable () async -> Void)?
    func setAfterPendingCheck(_ hook: (@Sendable () async -> Void)?) { afterPendingCheck = hook }
    /// Online place lookups per normal run; the rest waits for the overnight refinement run.
    /// Keeps the first analysis from spending up to an hour on town names before photos are
    /// looked at (the geocoder allows about 40 requests a minute). `nil` = no limit.
    /// A run in the app never waits for the geocoder either (device test 18.11., build 36: the
    /// card said "Apple antwortet gleich" and the count stood for 20–30 s): it asks only while
    /// Albumist's own throttle has a free slot (`RequestThrottle.apple`, the requests of the runs
    /// before within its minute count, `geocoderRequests`) and stops at Apple's first refusal.
    /// Either way the towns left come with a later run or the overnight refinement, which may wait.
    private let foregroundOnlineBudget: Int?
    /// Every request to the geocoder of this pipeline's runs, for the throttle's window.
    private let geocoderRequests = RequestLog()
    /// When a run in the app last asked Apple for town names and was left with towns still
    /// waiting because asking stopped early (Apple refused, the run's budget or the throttle's
    /// free slots ran out, or a Pause).
    /// A one-off error, being offline or a border cell whose answer is from the other country do
    /// not count, so photos near a border do not hold back new towns. A run within the hour after it
    /// (Fortsetzen after a Pause, a restart) does not ask again: the lookups and Apple's waits
    /// held "Orte werden bestimmt" for a minute or more before the run got back to where it was
    /// (device test 15.11.: "es dauert lange, bis die App nach Pause weiterläuft"). The towns
    /// still missing come with the overnight refinement or a run after the hour.
    /// A round that got every town it asked for sets nothing: photos added after it (new trip
    /// photos, an import) get their towns in the next run. Otherwise one early lookup kept
    /// every later photo at region names for an hour (UI run 43779950348: "Latium" instead of
    /// "Rom", the Iceland trip "Reykjavík" instead of "Island", 5 instead of 22 towns).
    private var lastForegroundOnlineLookup: Date?
    /// Finds the map region of stored places for `keyedRegions` (built once; its language is not used).
    private var regionRenamer: OfflineWorldMap.Renamer?
    static let foregroundOnlineCooldown: TimeInterval = 60 * 60

    /// "Analyse neu aufbauen" cleared the place cache: the next run asks Apple again at once,
    /// or the rebuilt trips would get no town names for an hour.
    public func forgetRecentOnlineLookups() {
        lastForegroundOnlineLookup = nil
    }
    public private(set) var settings: OrganizationSettings
    /// The run in progress: `pause()` reaches it through its control.
    private var activeControl: AnalysisRunControl?
    /// One run at a time. The actor alone does not ensure that: a second run would interleave
    /// with the first at every `await`, analyse the same photos and count them twice.
    private var runInProgress = false
    private var queuedRuns: [CheckedContinuation<Void, Never>] = []
    /// The mode of the run in progress (online place lookups ask it between requests).
    private var runMode: Mode = .incremental
    /// Told when the run in progress waits for the device, and when it goes on.
    private var runOnWaiting: @Sendable (PauseReason?) -> Void = { _ in }
    /// The photo access the run in progress started with.
    private var runAccess: LibraryAccess = .notDetermined
    /// The image step's newest report in the run in progress: the early suggestions are said
    /// with it (`earlySuggestions`), so the count never goes back.
    private var contentShown: Progress?
    /// A warm device: break after every photo. Waiting: how often the device is asked again.
    static let gentleBreak: Duration = .milliseconds(250)
    static let waitCheck: Duration = .seconds(2)
    /// Photos looked at side by side at full speed (image loading, which waits for the disk,
    /// overlaps with Vision); half of them when the device is warm, none while it waits.
    private let contentLanes: Int
    /// Text recognition reads larger images and is heavier: fewer side by side.
    private let textLanes: Int

    public init(
        store: AlbumistStore,
        reader: any PhotoLibraryReading,
        analyzer: any ContentAnalyzing,
        geocoder: (any ReverseGeocoding)?,
        map: OfflineWorldMap?,
        conditions: any AnalysisConditions,
        settings: OrganizationSettings,
        calendar: Calendar = .albumistDefault,
        time: TimeSource = .live(),
        batchSize: Int = 50,
        foregroundOnlineBudget: Int? = nil,
        contentLanes: Int = 4,
        textLanes: Int = 2,
        now: @escaping @Sendable () -> Date = { Date() },
        earlyGraceOnStop: Duration = .milliseconds(500)
    ) {
        self.now = now
        self.earlyGraceOnStop = earlyGraceOnStop
        self.contentLanes = max(1, contentLanes)
        self.textLanes = max(1, textLanes)
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

    /// Takes the user's settings and returns the ones they replace: the app compares the two
    /// (`runAfterSettingsChange`), against what the runs really used until now.
    @discardableResult
    public func update(settings: OrganizationSettings) -> OrganizationSettings {
        let previous = self.settings
        self.settings = settings
        return previous
    }

    /// Whether the image step asks for labels: they serve "Themen" and "Dokumente" (and the
    /// search for things in photos, "Hund", "Rechnung").
    public static func wantsLabels(_ settings: OrganizationSettings) -> Bool {
        settings.enabledAreas.contains(.imageCategories) || settings.enabledAreas.contains(.documents)
    }

    /// Whether the text step runs: screenshots, documents and messenger pictures are read.
    public static func readsText(_ settings: OrganizationSettings) -> Bool {
        settings.enabledAreas.contains(.screenshots) || settings.enabledAreas.contains(.documents)
            || settings.enabledAreas.contains(.messenger)
    }

    /// A change of the settings that gives a step work on photos read already: the app starts
    /// a run after it, as after new photos. Any change that makes a step newly needed:
    /// - labels wanted ("Themen" or "Dokumente" on): photos analysed without them get them,
    /// - the text step on (screenshots, documents or messenger pictures): they are read,
    /// - finer places (towns, also for trips) or online lookups allowed: places are resolved further,
    /// - another language of album names: stored countries and regions are named again (P1-12),
    /// - hidden photos included: they are read in and analysed.
    /// Faces are not computed yet (`VisionAnalyzer`), so people and pets need no run here.
    /// A change that only shows or hides suggestions needs none: the suggestions follow the
    /// settings with the next run anyway.
    public static func settingsChangeNeedsRun(from old: OrganizationSettings, to new: OrganizationSettings) -> Bool {
        SettingsUsed(old).needsRun(for: new)
    }

    /// The settings a run read for its work, each at the point where it read it
    /// (`Report.settingsUsed`): hidden photos with the library read, labels after the trips
    /// step, places and texts at the start of their steps. `nil`: the run did not get there.
    /// A change before that point is taken in by the run itself; one after it is decided at the
    /// run's end against these (`AnalysisRunEnd`, second review of the labels fix: a change
    /// during the library read was already used by the run, and one more run was redundant).
    public struct SettingsUsed: Sendable, Hashable {
        /// Labels asked for (`wantsLabels`).
        public var labels: Bool?
        /// The text step ran (`readsText`).
        public var text: Bool?
        /// How far places were resolved, and whether online lookups were allowed then.
        public var places: PlaceResolutionPolicy?
        /// Hidden photos read in.
        public var hidden: Bool?

        /// Nothing read yet.
        public init() {}

        /// All of it as these settings ask for.
        public init(_ settings: OrganizationSettings) {
            labels = AnalysisPipeline.wantsLabels(settings)
            text = AnalysisPipeline.readsText(settings)
            places = PlaceResolutionPolicy(settings: settings)
            hidden = settings.privacy.includeHiddenAssets
        }

        /// The settings `new` give a step work that a run with these did not do (the rules of
        /// `settingsChangeNeedsRun`).
        public func needsRun(for new: OrganizationSettings) -> Bool {
            if labels == false && AnalysisPipeline.wantsLabels(new) { return true }
            if text == false && AnalysisPipeline.readsText(new) { return true }
            if let places {
                let after = PlaceResolutionPolicy(settings: new)
                if after.deepestLevel > places.deepestLevel || (!places.onlineAllowed && after.onlineAllowed) { return true }
                // Another language of album names: stored countries and regions are named again.
                if after.language != places.language { return true }
            }
            return hidden == false && new.privacy.includeHiddenAssets
        }
    }

    /// What follows a change of the settings in the app (`AppModel.saveSettings`), decided once
    /// the pipeline has the new ones (`update(settings:)` returns the old ones).
    public enum RunAfterSettingsChange: Sendable, Equatable {
        /// Nothing starts: the change gives no step new work, or no run may start now and one
        /// follows anyway. The introduction ends with the first analysis; photo access that
        /// comes back, a plan that is being written and "Analyse neu aufbauen" each end with a
        /// run; and every run reads the settings it runs with.
        case noRun
        /// A run starts now.
        case now
        /// A run is busy: nothing starts now. Its end compares what it read
        /// (`Report.settingsUsed`) with the settings then and starts one more run right away if
        /// it missed a change (`AnalysisRunEnd`); one, however many changes come meanwhile.
        case afterCurrentRun
        /// The user paused the analysis, or tapped Pause and the run is finishing the photos in
        /// work: nothing starts by itself, a change of the settings never undoes a Pause.
        /// "Fortsetzen" does the new work with the rest (it reads the new settings).
        case whenResumed
    }

    /// `running`: a run is busy. `pausedByUser`: see `RunAfterSettingsChange.whenResumed`.
    /// `mayStart`: a run may start now (past the introduction, photos readable, no plan being
    /// written, no rebuild of the analysis).
    public static func runAfterSettingsChange(from old: OrganizationSettings, to new: OrganizationSettings,
                                              running: Bool, pausedByUser: Bool, mayStart: Bool) -> RunAfterSettingsChange {
        guard settingsChangeNeedsRun(from: old, to: new) else { return .noRun }
        if pausedByUser { return .whenResumed }
        if running { return .afterCurrentRun }
        return mayStart ? .now : .noRun
    }

    /// What runs without an explicit scope work on. First device test 15.11.: "nur 2026" at
    /// the start applied to the first run only; every later run suggested the whole library.
    public func storedScope() async throws -> OrganizationScope {
        try await store.value(OrganizationScope.self, forKey: Key.scope) ?? .all
    }

    public func setScope(_ scope: OrganizationScope) async throws {
        try await store.setValue(scope, forKey: Key.scope)
    }

    /// A trial run over one year analyses only the photos of that year (and the trips that
    /// touch it); the rest is looked at once the user takes in the whole library. A photo's year
    /// is that of its own clock (review P1-15): the range holds every instant that is in the year
    /// on a clock in `calendar`'s zone (the home time zone) or in one of `zones` (those of the
    /// places in the library). Which photos are in the year is told by their facts
    /// (`OrganizationScope.includes`); this range only limits the work.
    static func dateRange(of scope: OrganizationScope, calendar: Calendar, zones: Set<TimeZone> = []) -> Range<Date>? {
        guard case .year(let year) = scope else { return nil }
        var range: Range<Date>?
        for zone in [calendar.timeZone] + zones.sorted(by: { $0.identifier < $1.identifier }) {
            var local = calendar
            local.timeZone = zone
            guard let start = local.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = local.date(byAdding: .year, value: 1, to: start) else { continue }
            range = range.map { min($0.lowerBound, start)..<max($0.upperBound, end) } ?? start..<end
        }
        return range
    }

    /// The clocks a year begins first and ends last on (the date line): with them `dateRange`
    /// holds every instant that is in the year somewhere.
    static let everyClock: Set<TimeZone> = [TimeZone(secondsFromGMT: 14 * 3600)!, TimeZone(secondsFromGMT: -12 * 3600)!]

    /// The clock of photos whose place tells no time zone (review P1-15): the zone of the home
    /// (second review), as stored by the last run; the zone of the home the user chose in "Dein
    /// Zuhause", or of the one the last analysis found while none is stored; while no home is
    /// known, the iPhone's at the first analysis (stored then), or the iPhone's.
    public func homeTimeZone() async throws -> TimeZone {
        try await homeTimeZoneInEffect(all: nil).zone
    }

    /// The home time zone and whether a run stores it (`patternsClock`), in this order:
    /// - the zone of the home the user chose, whatever is stored;
    /// - the stored one (a home the analysis finds later changes it before the trips are
    ///   detected, `patternsClock`);
    /// - none stored (or none this system can read): the zone of the home the last analysis
    ///   found, when the home is left to the analysis (an update on a trip abroad: the home
    ///   in Munich gives Berlin time, not the iPhone's Los Angeles time);
    /// - no home known: the iPhone's, stored only when nothing is stored.
    /// `all`: the library, where a run or `resuggest()` has it read (`placeTimeZones`).
    private func homeTimeZoneInEffect(all: [AssetSnapshot]?) async throws -> (zone: TimeZone, store: Bool) {
        let stored = try await storedHomeTimeZone()
        let home = try await homeSettings()
        if home.currentMode == .confirmed, let place = home.confirmed,
           let zone = try await zone(ofHomeAt: place.center, components: place.components, all: all) {
            if case .zone(let current) = stored, current.identifier == zone.identifier { return (zone, false) }
            return (zone, true)
        }
        if case .zone(let zone) = stored { return (zone, false) }
        if home.currentMode == .automatic,
           let found = try await readable({ try await store.value(DetectedHome.self, forKey: Key.detectedHome) }),
           let zone = try await zone(ofHomeAt: found.center, components: nil, all: all) {
            return (zone, true)
        }
        if case .none = stored { return (calendar.timeZone, true) }
        return (calendar.timeZone, false)
    }

    /// The time zone of a home (second review of P1-15): the one its place names (a home the user
    /// chose: online its own zone, else its country's there); else that of the country the
    /// offline map finds at its centre; else the most common one of the photos within the home
    /// radius (no map, or a centre at sea).
    private func zone(ofHomeAt center: GeoCoordinate, components: PlaceComponents?, all: [AssetSnapshot]?) async throws -> TimeZone? {
        if let zone = LocalTime.zone(of: components, at: center) { return zone }
        if let map, let zone = LocalTime.zone(of: map.lookup(center).components(language: .english), at: center) { return zone }
        let zones = try await placeTimeZones(library: all)
        guard !zones.isEmpty else { return nil }
        let radius = settings.trips.advanced.homeRadiusMeters
        var library = all
        if library == nil { library = try await store.allAssets() }
        let near = (library ?? []).filter { $0.usableLocation.map { GeoMath.distance($0, center) <= radius } ?? false }
        var counts: [String: Int] = [:]
        for asset in near { if let zone = zones[asset.id] { counts[zone.identifier, default: 0] += 1 } }
        return counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }).flatMap { TimeZone(identifier: $0.key) }
    }

    /// What the store holds as the home time zone.
    private enum StoredHomeTimeZone {
        case none
        case zone(TimeZone)
        /// A zone this system's database does not know (newer, from the safety copy of a newer
        /// iPhone) or a value in a shape a later version stored: kept as it is, never replaced
        /// for that (second review of P1-15). Meanwhile the iPhone's zone stands in, in memory.
        case unreadable
    }

    private func storedHomeTimeZone() async throws -> StoredHomeTimeZone {
        do {
            guard let identifier = try await store.value(String.self, forKey: Key.homeTimeZone) else { return .none }
            return TimeZone(identifier: identifier).map(StoredHomeTimeZone.zone) ?? .unreadable
        } catch is DecodingError {
            return .unreadable
        }
    }

    /// The calendar the analysis counts days in where no photo's own clock is asked (home days,
    /// trips at home, the places the user is often at): the iPhone's calendar in the home time
    /// zone, so the iPhone's time zone during an analysis changes nothing (review P1-15).
    private func homeCalendar() async throws -> Calendar {
        var home = calendar
        home.timeZone = try await homeTimeZone()
        return home
    }

    /// The zone each photo's place tells (online its own, offline its country's there), for the
    /// photos that have one (review P1-15). Worked out once for each state of the places and the
    /// photos' locations (`AlbumistStore.placesRevision`): a run asked for them up to four times
    /// and every read of the facts once more, about three seconds each over 100,000 photos in as
    /// many places (second review). Off the actor, like the facts (`offActor`).
    /// `library`: the photos as the store holds them, where a run or `resuggest()` has them read
    /// (only a run writes the photos, and the two take turns); otherwise they are read here.
    /// While no place is known (a first run before its places step) no photo is read: a read of
    /// 50,000 photos made the trips step stand silent for longer than it may.
    /// `read`: the places and the photos a caller read itself, after it took the state of the
    /// places (`revision`): used instead of reading them again (the overview's facts, P4-02); a
    /// write after `revision` keeps them from being kept for others, as below.
    private func placeTimeZones(library: [AssetSnapshot]? = nil,
                                read: (revision: Int, places: [AssetID: ResolvedPlace])? = nil) async throws -> [AssetID: TimeZone] {
        let revision: Int
        if let read { revision = read.revision } else { revision = await store.placesRevision }
        if let cached = placeZones, cached.revision == revision { return cached.zones }
        let places: [AssetID: ResolvedPlace]
        if let read { places = read.places } else { places = try await store.places() }
        var zones: [AssetID: TimeZone] = [:]
        if !places.isEmpty {
            zoneProbe?()
            var assets = library
            if assets == nil { assets = try await store.allAssets() }
            let photos = assets ?? []
            zones = await Task.detached(priority: Task.currentPriority) { LocalTime.placeZones(of: photos, places: places) }.value
        }
        // A write meanwhile made them older than the store: they serve this caller only.
        if await store.placesRevision == revision { placeZones = (revision, zones) }
        return zones
    }

    /// `placeTimeZones()` and the state of the places they were worked out for.
    private var placeZones: (revision: Int, zones: [AssetID: TimeZone])?

    /// The photos the image step of a trial run over one year looks at (second review of P1-15):
    /// those of the year on their own clock, as their facts read it (`PhotoClocks`, with the
    /// places known so far). The count of the step and the photos it looks at are the same.
    struct PhotosOfTheYear: Sendable {
        /// The time they were taken in: the year on the clocks of the home and of the places
        /// (`dateRange`), to find them in the store.
        let range: Range<Date>
        /// The photos taken in `range` that are of another year on their own clock: New Year's
        /// Eve at home lies in the new year of Sydney's clock once a photo of Sydney is known.
        let otherYears: Set<AssetID>
        /// How many there are.
        let count: Int

        func contains(_ asset: AssetSnapshot) -> Bool {
            (asset.creationDate.map(range.contains) ?? false) && !otherYears.contains(asset.id)
        }
    }

    /// `PhotosOfTheYear` of a run over `scope`; nil for the whole library.
    private func photosOfTheYear(_ scope: OrganizationScope, all: [AssetSnapshot], trips: [Trip]) async throws -> PhotosOfTheYear? {
        guard case .year = scope else { return nil }
        let home = try await homeCalendar()
        let zones = try await placeTimeZones(library: all)
        guard let range = Self.dateRange(of: scope, calendar: home, zones: Set(zones.values)) else { return nil }
        let clocks = PhotoClocks(places: zones, trips: trips, home: home.timeZone)
        var otherYears = Set<AssetID>()
        var count = 0
        for asset in all where asset.creationDate.map(range.contains) ?? false {
            if scope.includes(AssetFacts(asset: asset, timeZone: clocks.zone(of: asset.id)), calendar: home) {
                count += 1
            } else {
                otherYears.insert(asset.id)
            }
        }
        return PhotosOfTheYear(range: range, otherYears: otherYears, count: count)
    }

    /// Pauses the run in progress at its next check; `run` then returns with `.userPaused`.
    /// Without a run in progress nothing happens (the next run is not affected).
    public func pause() { activeControl?.pause() }

    private func beginRun() async {
        if runInProgress {
            await withCheckedContinuation { queuedRuns.append($0) }
        } else {
            runInProgress = true
        }
        // Early suggestions a stopped run left behind finish first (cancelled, they save
        // nothing): nothing of them overlaps the next run's own writes.
        await waitForEarlyLeftBehind()
        // Work of a step given up at a Pause ends first: "Fortsetzen" does not run beside it.
        await waitForAbandonedWork()
    }

    private func endRun() {
        // Handed straight to the next waiting run, so no other caller slips in between.
        if queuedRuns.isEmpty { runInProgress = false } else { queuedRuns.removeFirst().resume() }
    }

    /// Checked between online place lookups, so Pause, heat or low battery stop that stage
    /// within one request instead of after all of them. The lookups left over wait for the
    /// overnight refinement; a run in the app goes on with the photos.
    private func stopRequested() async -> Bool {
        if activeControl?.isPaused == true || Task.isCancelled { return true }
        if runMode == .refinement { return await conditions.pauseReason() != nil }
        switch await conditions.pace() {
        case .normal, .gentle: return false
        case .wait, .stop: return true
        }
    }

    /// Asked before every photo: whether the run stops, and how many photos may be in work
    /// at once. A run in the app never ends because of the device: it slows down when warm
    /// and waits when hot, then goes on by itself. Only Pause, the end of the app's time and
    /// the overnight refinement's rules end a run.
    private func admission(lanes: Int) async -> (stop: PauseReason?, width: Int) {
        guard let control = activeControl else { return (.timeBudget, 0) }
        if control.isPaused { return (.userPaused, 0) }
        if Task.isCancelled { return (.timeBudget, 0) }
        if runMode == .refinement {
            if let reason = await conditions.pauseReason() { return (reason, 0) }
            return (nil, lanes)
        }
        let onWaiting = runOnWaiting
        var waitingFor: PauseReason?
        defer { if waitingFor != nil { onWaiting(nil) } }
        while true {
            switch await conditions.pace() {
            case .normal:
                return (nil, lanes)
            case .gentle:
                do { try await time.sleep(Self.gentleBreak) } catch { return (.timeBudget, 0) }
                return control.isPaused ? (.userPaused, 0) : (nil, max(1, lanes / 2))
            case .stop(let reason):
                return (reason, 0)
            case .wait(let reason):
                if waitingFor != reason {
                    waitingFor = reason
                    onWaiting(reason)
                }
                do { try await time.sleep(Self.waitCheck) } catch { return (.timeBudget, 0) }
                if control.isPaused { return (.userPaused, 0) }
                if Task.isCancelled { return (.timeBudget, 0) }
            }
        }
    }

    /// Access taken away or changed in Settings while the run is busy: photos cannot be read
    /// (or other ones can), and must not be marked unreadable for that. The run ends; the
    /// next one reads the library as it is then.
    private func accessChanged() async -> Bool {
        await reader.access() != runAccess
    }

    /// Where in the library's change history the stored photos and albums are: they are
    /// the library as it was at `mark`, read with `includeHidden`. Written after a whole read
    /// with full access and after each read of the changes; removed before a whole read.
    struct LibraryReadMark: Codable, Sendable {
        var mark: LibraryChangeMark
        var includeHidden: Bool
        /// Reads of changes since the last whole read (`wholeReadEvery`).
        var changeReads = 0
        /// `currentReaderVersion` when it was written.
        var readerVersion = AnalysisPipeline.currentReaderVersion
        /// When the library was last read whole (`wholeReadAfter`).
        var wholeReadAt: Date
    }

    /// What a read takes of each photo (`AssetSnapshot`, the PhotoKit reader's `snapshot`).
    /// Raised by an update that reads more or other of a photo: the stored photos are then
    /// read whole once, or the photos that do not change would never get it.
    static let currentReaderVersion = 1
    /// After this many runs that read changes, one reads the whole library anyway: whatever
    /// the change history may have missed is put right within days (a run starts at every
    /// launch of the app). Runs without any change do not count.
    static let wholeReadEvery = 30
    /// And a whole read at the latest this long after the last one, also when the history
    /// names no change at all: albums or details of a photo it may miss are put right.
    static let wholeReadAfter: TimeInterval = 7 * 24 * 60 * 60
    /// More changed photos than this: the whole read, which says how far it is on the card
    /// (a read of the changes says nothing until it is done).
    static let largestChangeRead = 1_000

    /// The mark at which this run read the albums and those albums, for `albumsUnchanged`.
    private var inventoryMark: (mark: LibraryChangeMark, inventory: CollectionInventory)?

    /// The stored mark. One that cannot be read (an older form, a broken value) counts as none
    /// and is removed: the run reads the whole library instead of ending with the error.
    private func storedLibraryMark() async -> LibraryReadMark? {
        do {
            return try await store.value(LibraryReadMark.self, forKey: Key.libraryMark)
        } catch {
            try? await store.removeValue(forKey: Key.libraryMark)
            return nil
        }
    }

    /// Step 1 by the library's change history (review P4-03): the photos added, changed or
    /// deleted since the stored mark are read and stored, nothing else. The albums are walked
    /// again only when anything changed at all. Returns the albums and the number of photos,
    /// or `nil` when the whole library has to be read: no mark (or one that cannot be read, or
    /// of another reader version), another setting for hidden photos, limited access (the
    /// selection can change without a change in the library), photos still set aside from
    /// limited access (review P1-07), a history that cannot tell or
    /// does not answer (too old, another library, an error), many changes, every
    /// `wholeReadEvery`-th time, a week after the last whole read, or a number of photos after
    /// the changes that does not fit the library. Nothing is written before that is known.
    /// Throws `LibraryReadPaused` on a Pause, with the mark left where it was (the changes are
    /// read again next time).
    private func readChanges(includeHidden: Bool, control: AnalysisRunControl,
                             report: inout Report) async throws -> (CollectionInventory, Int)? {
        // Photos set aside under "Ausgewählte Fotos" are put right by a whole read only (it
        // takes them back or deletes them); the history knows nothing of the selection. A run
        // does not leave them with a mark (a whole read removes it first and writes it only when
        // it read with full access, also when access changed while it read), and the count check
        // below would send it to a whole read too; kept as the plain rule
        // (`photosSetAsideAreTakenBackByAWholeRead` seeds that case).
        guard runAccess == .full, try await store.outOfViewCount() == 0,
              let stored = await storedLibraryMark(),
              stored.readerVersion == Self.currentReaderVersion,
              stored.includeHidden == includeHidden, stored.changeReads < Self.wholeReadEvery,
              abs(now().timeIntervalSince(stored.wholeReadAt)) < Self.wholeReadAfter else { return nil }
        let answer: LibraryChanges?
        do {
            answer = try await reader.changes(since: stored.mark, limit: Self.largestChangeRead)
        } catch let error as CancellationError {
            // The run is ended, or Photos does not answer: the run ends as with any read that
            // gets no answer, and the mark stays for the next run.
            throw error
        } catch let error as PhotosNotResponding {
            throw error
        } catch {
            // Any other error of the history is no reason to end the run: the whole read follows.
            answer = nil
        }
        guard let changes = answer,
              !changes.tooMany,
              changes.assets.count + changes.deleted.count <= Self.largestChangeRead else { return nil }
        // The deleted ones too: what is readable now stays, whatever order the history named
        // its changes in (a photo put back from "Zuletzt gelöscht").
        let asked = changes.assets.union(changes.deleted)
        let read = try await reader.fetchAssets(asked, includeHidden: includeHidden,
                                                knownDetails: try await store.fileDetails(for: asked)) { _, _ in !control.isPaused }
        let readIDs = Set(read.assets.map(\.id))
        // Named and not read: deleted, hidden, or no longer of the user's library.
        let gone = asked.subtracting(readIDs)
        // The number of photos the store will hold, against the library's, before anything is
        // written: a removal deletes the photo's results too, and one the reader got wrong
        // would cost its analysis. Only the numbers are compared, not which photos they are
        // (two errors that cancel out go unseen until the next whole read).
        let storedAsked = try await store.storedAssets(among: asked)
        let expected = try await store.assetCount() - storedAsked.intersection(gone).count + readIDs.subtracting(storedAsked).count
        guard expected == read.libraryCount else { return nil }
        report.newOrChanged = try await store.upsertAssets(read.assets).count
        report.removed = try await store.removeAssets(gone)
        if changes.isEmpty {
            // Nothing changed: the stored albums are the library's; the mark stays (no write).
            return (try await store.loadInventory(), read.libraryCount)
        }
        // Any change walks the albums: a photo added, deleted or changed may have joined or
        // left one. Only the albums that differ are written.
        let inventory = try await reader.currentInventory()
        try await store.saveInventory(inventory)
        var next = stored
        next.mark = changes.mark
        next.changeReads += 1
        try await store.setValue(next, forKey: Key.libraryMark)
        return (inventory, read.libraryCount)
    }

    /// Whether the albums are still as this run read them (`inventory`), by the change history:
    /// then the suggestions need no second walk over all albums (review P4-03). `false` when
    /// that cannot be told.
    private func albumsUnchanged(_ inventory: CollectionInventory) async -> Bool {
        guard let (mark, read) = inventoryMark, read == inventory,
              let changes = try? await reader.changes(since: mark, limit: Self.largestChangeRead) else { return false }
        return changes.isEmpty
    }

    /// `onWaiting`: the run waits for the device (hot, battery nearly empty) and goes on by
    /// itself; called with `nil` when it goes on.
    /// `control`: the app's handle to pause exactly this run. A run that is called while
    /// another one is in progress waits until that one has ended.
    public func run(
        mode: Mode = .incremental,
        scope requested: OrganizationScope? = nil,
        control: AnalysisRunControl = AnalysisRunControl(),
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        onWaiting: @escaping @Sendable (PauseReason?) -> Void = { _ in }
    ) async throws -> Report {
        await beginRun()
        defer { endRun() }
        activeControl = control
        defer { activeControl = nil }
        runMode = mode
        var report = Report()
        // Paused or ended while it waited for its turn: nothing is read.
        if control.isPaused { report.pausedBecause = .userPaused; return report }
        if Task.isCancelled { report.pausedBecause = .timeBudget; return report }
        let scope: OrganizationScope
        if let requested { scope = requested } else { scope = try await storedScope() }
        // Stored texts follow stricter masks first, whatever this run reads (it reads no photo):
        // also with the text step off, and before a failed read writes an earlier result back.
        try await remaskStoredTexts()

        runOnWaiting = onWaiting
        func shouldStop() async -> PauseReason? { await admission(lanes: 1).stop }

        // 1. Inventory
        runAccess = await reader.access()
        guard runAccess.canRead else {
            report.pausedBecause = .accessRevoked
            return report
        }
        // Said while reading (the count moves on a large first read) and once more when the
        // photos are stored. Pause ends the read at the next report. The photos read until then
        // keep their file details (the next read skips those), but the partial list is never
        // taken as the library: nothing is removed (review of 9f0bc40: a user who paused again
        // and again started from nothing each time).
        let includeHidden = settings.privacy.includeHiddenAssets
        report.settingsUsed.hidden = includeHidden
        // Only what changed since the last run, when the library's change history can say
        // (review P4-03); otherwise, or when anything is in doubt, the whole library.
        let inventory: CollectionInventory
        let libraryCount: Int
        do {
            if let changed = try await readChanges(includeHidden: includeHidden, control: control, report: &report) {
                (inventory, libraryCount) = changed
            } else {
                // A whole read starts without a mark: one paused or failed half way never
                // leaves a mark that the partial read would be taken for.
                try await store.removeValue(forKey: Key.libraryMark)
                // Taken before the read: a change made while it reads is read next time.
                let mark = runAccess == .full ? await reader.changeMark() : nil
                let assets = try await reader.fetchAssets(includeHidden: includeHidden,
                                                          knownDetails: try await store.assetsWithFileDetails()) { read, total in
                    onProgress(Progress(stage: .inventory, completed: min(read, total), total: total))
                    return !control.isPaused
                }
                report.newOrChanged += try await store.upsertAssets(assets).count
                // A photo missing from a read of "Ausgewählte Fotos" is only out of view: it is
                // set aside with its analysis, place and text, not deleted. Only full access
                // shows that a photo is gone (review P1-07: back on "Alle Fotos" every photo
                // outside the selection was analysed again, hours on a large library).
                // Asked again after the read: switched to "Ausgewählte Fotos" while it read, it may
                // have read only the selection (second review of P1-07).
                let readWithFullAccess = runAccess == .full ? await reader.access() == .full : false
                if readWithFullAccess {
                    report.removed += try await store.removeAssets(notIn: Set(assets.map(\.id)))
                } else {
                    report.setAside += try await store.setAside(notIn: Set(assets.map(\.id)))
                }
                inventory = try await reader.currentInventory()
                try await store.saveInventory(inventory)
                libraryCount = assets.count
                // Only after a read with full access: one that set photos aside (access switched
                // while it read) leaves no mark, so the next run reads the whole library again.
                if let mark, readWithFullAccess {
                    try await store.setValue(LibraryReadMark(mark: mark, includeHidden: includeHidden, wholeReadAt: now()),
                                             forKey: Key.libraryMark)
                }
            }
        } catch let paused as LibraryReadPaused {
            if !paused.read.isEmpty { _ = try await store.upsertAssets(paused.read) }
            report.pausedBecause = .userPaused
            return report
        } catch is CancellationError where control.isPaused {
            report.pausedBecause = .userPaused
            return report
        }
        // Where the albums are known to be as stored (`albumsUnchanged`).
        inventoryMark = await storedLibraryMark().map { ($0.mark, inventory) }
        onProgress(Progress(stage: .inventory, completed: libraryCount, total: libraryCount))
        report.completedStages.append(.inventory)
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }

        // 2. Patterns (pure computation over metadata, seconds even for large libraries)
        // Said before the trips are computed, or the card stands at "Mediathek wird gelesen ·
        // N von N" meanwhile (simulated full run: step 2 was first shown when it was done).
        // Total 0: no count yet; the photos with a location follow as they are grouped.
        onProgress(Progress(stage: .patterns, completed: 0, total: 0))
        let all = try await store.allAssets()
        // Reading every photo takes a moment on a large library (review P4-07).
        if control.isPaused { report.pausedBecause = .userPaused; return report }
        var patternsGeneration = homeGeneration
        // The step's count: photos with a location grouped so far ("12.000 von 30.000 Fotos"),
        // so it does not stand still on a large library (review of 11ef3e1, minor 3).
        var grouped = (done: 0, of: 1)
        var trips: [Trip], frequent: [FrequentPlace]
        do {
            (trips, frequent) = try await detectPatterns(all: all, stopsAt: control, progress: { done, of in
                grouped = (done, max(1, of))
                onProgress(Progress(stage: .patterns, completed: done, total: max(1, of)))
            })
        } catch is CancellationError where control.isPaused {
            report.pausedBecause = .userPaused
            return report
        }
        report.completedStages.append(.patterns)

        // The photos this run analyses: all of them, or one year and the trips that touch it. A
        // photo's year is that of its own clock (review P1-15): places are looked for wherever a
        // photo may be in the year on any clock (`reach`), the image step looks at the photos of
        // the year on the clocks known (`year`, again after the places step).
        var year = try await photosOfTheYear(scope, all: all, trips: trips)
        let reach = Self.dateRange(of: scope, calendar: calendar, zones: Self.everyClock)
        // Read once: the workload said below and the image step count the same photos.
        let labels = Self.wantsLabels(settings) ? Self.labelsVersion : nil
        report.settingsUsed.labels = labels != nil
        let scoped: [AssetSnapshot]
        if let reach {
            let inYear = Set(all.filter { $0.creationDate.map(reach.contains) ?? false }.map(\.id))
            let tripMembers = Set(trips.filter { !inYear.isDisjoint(with: $0.geotaggedAssetIDs) }.flatMap(\.geotaggedAssetIDs))
            scoped = all.filter { inYear.contains($0.id) || tripMembers.contains($0.id) }
        } else {
            scoped = all
        }
        onProgress(Progress(stage: .patterns, completed: grouped.of, total: grouped.of,
                            workload: try await workload(all: all, scoped: scoped, year: year, labels: labels)))

        // 3. Places
        // A Pause during the trips step: the places step does not begin (review P4-07).
        if control.isPaused { report.pausedBecause = .userPaused; return report }
        // What `resolvePlaces` reads first thing (same moment, no wait in between).
        report.settingsUsed.places = PlaceResolutionPolicy(settings: settings)
        let placeOutcome = try await resolvePlaces(scoped, trips: trips, frequent: frequent, refining: mode == .refinement, onProgress: onProgress)
        report.placesResolved = placeOutcome.resolved
        report.placesPendingOnline = placeOutcome.pendingOnline.count
        report.onlineRequests = placeOutcome.onlineRequests
        report.placesThrottled = placeOutcome.stoppedBecauseThrottled
        trips = try await inDestinationTime(trips, all: all)
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        report.completedStages.append(.places)
        // A trial year also goes by the clocks of the places found in this run (review P1-15).
        if year != nil { year = try await photosOfTheYear(scope, all: all, trips: trips) }

        // 4. Content
        let peopleRequest = ContentAnalysisRequest(
            classify: labels != nil,
            detectFaces: settings.people.faceGroupingEnabled && settings.enabledAreas.contains(.peopleAndPets),
            detectAnimals: settings.people.petGroupingEnabled && settings.enabledAreas.contains(.peopleAndPets),
            featurePrint: true
        )
        // Photos given up as unreadable a week ago or longer get one more read (review P1-08).
        try await reopenGivenUpPhotos(all, within: year, labels: labels)
        // With labels wanted, also the photos analysed while they were not: only their labels
        // are asked for (`labelsOnly` below). Each counts as one photo, like a full look.
        let contentTotal = try await store.countNeedingAnalysis(version: Self.contentVersion, labelsVersion: labels,
                                                                within: year?.range, excluding: year?.otherYears ?? [])
        // Shown over the whole library: after a pause the count goes on from what is done
        // (first device test 15.11.: "1.450 von 14.332", then "2.700 von 12.708").
        let contentBefore = max(0, (year?.count ?? all.count) - contentTotal)
        // Every report of this step goes through here: the early suggestions are said with the
        // newest one (`earlySuggestions`). Nothing of an earlier run's step.
        contentShown = nil
        func sayContent(_ progress: Progress) {
            contentShown = progress
            onProgress(progress)
        }
        // Said also when nothing is left to look at: every stage says when it begins, or the
        // card kept showing the stage before ("Orte werden bestimmt · 1.600 von 1.600") while
        // the run went on (device test 15.11.: "jetzt hängt es hier").
        sayContent(Progress(stage: .content, completed: contentBefore, total: contentBefore + contentTotal))
        // First results early: trips, countries and places need no image analysis. On a first
        // run (no suggestions yet) they are offered while the image analysis begins instead of
        // after it, which takes hours on a large library. The full set replaces them later;
        // suggestion ids are stable, so decisions made in between stay valid.
        // They are made beside the first photos, not before them: their work grows with the
        // library, and the count stood at "0 von 50.246 Fotos" for 13 s meanwhile (stress run
        // 44116350940; 2.8 s on Linux over 50,000 photos, 0.25 s over 5,000). What grows with
        // the library runs off this actor (`offActor`), so the photos go on at their own pace.
        var early: (task: Task<EarlySuggestions, any Error>, done: EarlyDone)?
        if contentTotal > 0, try await latestProposals() == nil {
            let done = EarlyDone()
            early = (Task { [patternsGeneration, trips, frequent] in
                defer { done.mark() }
                return try await self.earlySuggestions(all: all, inventory: inventory, trips: trips, frequent: frequent, scope: scope,
                                                       generation: patternsGeneration, onProgress: onProgress)
            }, done)
        }
        // Waited for when the image step is done: trips detected again with them (a change in
        // "Dein Zuhause" meanwhile) are what the later steps use. When the run stops (Pause,
        // heat, no access, its time is up) they get half a second more: Pause must take effect
        // within a second (at 50,000 photos they take 2.8 s on Linux). Not done by then, they
        // are dropped unsaved (`abandonEarly`) and the next run makes them again, since there
        // are still no suggestions. A failed early set is no reason to fail the run: the full
        // set of step 7 replaces it (`Report.earlyProposalsFailure`).
        // `stopping`: when the run saw the stop (the half second counts from then, so it runs
        // beside the photos still in work); nil when the step is done.
        func settleEarly(stopping: ContinuousClock.Instant?) async {
            guard let (task, done) = early else { return }
            early = nil
            if let stopping, !(await done.wait(upTo: earlyGraceOnStop - (ContinuousClock.now - stopping))) {
                abandonEarly(task)
                return
            }
            do {
                let outcome = try await task.value
                report.earlyProposals = true
                if let fresh = outcome.fresh { (trips, frequent) = fresh }
                patternsGeneration = outcome.generation
            } catch {
                report.earlyProposalsFailure = String(describing: error)
            }
        }
        do {
            // Photos still to analyse that have a result of this version already: their labels
            // were saved by a run that ended before it marked them (or only their place or date
            // changed since), so they are not looked at twice; or they could not be read before.
            let stored = contentTotal > 0
                ? try await store.pendingResults(ContentAnalysis.self, kind: "content", version: Self.contentVersion,
                                                 within: year?.range, excluding: year?.otherYears ?? [])
                : [:]
            // Photos given up before and read once more (`reopenGivenUpPhotos`): whatever goes
            // wrong with that read, the photo is given up again for another week. An analyzer
            // error kept it open without a time of its last try, read in every run after, and
            // five of them ended every run as "Analyse nicht verfügbar" (second review of P1-08).
            // Not when the run is stopped, Photos does not answer or the access was taken away.
            let triedAgain = Set(stored.compactMap { id, previous in
                (previous.failedAttempts ?? 0) >= ContentAnalysis.maxFailedAttempts ? id : nil
            })
            var contentDone = 0
            var cursor: AssetSnapshot?
            // Photos that are not read in this run: they could not be read (tried again in a later
            // run, spaced out), or the analyzer failed on them.
            var deferred = Set<AssetID>()
            // Analyzer errors in a row, not counted against the photos yet: only when a later photo
            // works was it the photo. When every photo fails, the analyzer is the problem.
            var suspects: [AssetID] = []
            // The last photos looked at, for "Gerade angesehen" (no screenshots: account numbers,
            // ID cards would be shown large on the overview, B4).
            var lookedAt: [AssetID] = []
            // Photos of this run that only need their labels: their failed reads count apart from
            // their content result (`LabelAttempts`), also when the failure is noted a batch later.
            var labelsOnlyIDs = Set<AssetID>()
            let analyzer = self.analyzer
            // Previews loaded ahead end with the image step, also when it is cut off (third
            // review of the PhotoKit limits, N7).
            defer { analyzer.contentEnded() }
            while true {
                if let reason = await shouldStop() { report.pausedBecause = reason; await settleEarly(stopping: .now); return report }
                if await accessChanged() { report.pausedBecause = .accessRevoked; await settleEarly(stopping: .now); return report }
                // Deferred photos can come back only without a cursor (behind it they are past).
                let limit = batchSize + (cursor == nil ? deferred.count : 0)
                var raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, labelsVersion: labels, limit: limit,
                                                                olderThan: cursor, within: year?.range, excluding: year?.otherYears ?? [])
                if raw.isEmpty, cursor != nil {
                    // Past the oldest dated photo: one plain pass picks up photos without a date.
                    cursor = nil
                    raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, labelsVersion: labels,
                                                                limit: batchSize + deferred.count, within: year?.range,
                                                                excluding: year?.otherYears ?? [])
                }
                var batch = raw.filter { !deferred.contains($0.id) }
                if batch.isEmpty { break }
                if let last = raw.last, last.creationDate != nil { cursor = last }
                var finished: [AssetID] = []
                // Saved with the batch's marks in one transaction.
                var results: [(AssetID, ContentAnalysis)] = []
                var analyzed = 0
                var stopped: PauseReason?
                var stopSeen: ContinuousClock.Instant?
                var cancelled = false
                // Photos did not hand over a photo in time (`PhotosNotResponding`, second review of
                // the PhotoKit limits, 4): not the photo's fault and not Vision's. Nothing is
                // counted for it; the photos in work finish, and the run ends with the error (the
                // card says "Fotos antwortet gerade nicht", the run comes again by itself).
                var photosQuiet: PhotosNotResponding?
                // Saved and shown at least once a second: a batch of 50 photos took 5 s, on a warm
                // device 18 s, and the count stood still meanwhile (simulated full run). The photos
                // after the cut stay for the next batch.
                let batchStart = now()
                var cut = false
                var next = 0
                // Photos analysed already that only need their labels ("Themen" or "Dokumente"
                // turned on since): the earlier result, which gets the labels of a look that asks
                // for nothing else. Their marks are set like those of a full look.
                // A photo given up as unreadable has no result to add to: it gets one more full look
                // (given up again if it still cannot be read).
                let analysedBefore = labels == nil ? [:]
                    : try await store.analyzedResults(ContentAnalysis.self, kind: "content", version: Self.contentVersion, of: batch.map(\.id))
                var labelsOnly = analysedBefore.filter { $0.value.failedAttempts == nil }
                // Decided without looking at the image: labels stored already, or a photo that
                // could not be read a short while ago (not again in this run).
                batch = batch.filter { asset in
                    guard let previous = stored[asset.id] else { return true }
                    if previous.failedAttempts == nil {
                        // Read before, but without labels (stored while they were not wanted):
                        // only the labels are asked for. A photo that has labels keeps them.
                        if labels != nil, previous.labels.isEmpty {
                            labelsOnly[asset.id] = previous
                            return true
                        }
                        finished.append(asset.id)
                    } else if !previous.isDueForRetry(now: now()) {
                        deferred.insert(asset.id)
                    } else {
                        return true
                    }
                    return false
                }
                // Labels that could not be read a short while ago: not again in this run (like
                // photos that could not be read at all, above).
                var labelAttempts: [AssetID: LabelAttempts] = [:]
                for id in labelsOnly.keys {
                    guard let tried = try await store.result(LabelAttempts.self, kind: "labels", asset: id) else { continue }
                    labelAttempts[id] = tried
                    if !tried.isDueForRetry(now: now()) { deferred.insert(id) }
                }
                batch.removeAll { labelsOnly[$0.id] != nil && deferred.contains($0.id) }
                labelsOnlyIDs.formUnion(labelsOnly.keys)
                await analyzer.willAnalyze(Array(batch.prefix(2 * contentLanes)))
                try await withThrowingTaskGroup(of: (AssetSnapshot, Result<ContentAnalysis, any Error>).self) { group in
                    var inFlight = 0
                    var width = contentLanes
                    while true {
                        // Fill the lanes. Heat, low battery or Pause are checked before every
                        // photo, so a stop takes effect within one photo per lane.
                        while stopped == nil, !cancelled, photosQuiet == nil, next < batch.count, inFlight < width {
                            if next > 0, now().timeIntervalSince(batchStart) >= 1 { cut = true; break }
                            let (reason, lanes) = await admission(lanes: contentLanes)
                            if let reason { stopped = reason; stopSeen = .now; break }
                            width = lanes
                            guard inFlight < width else { break }
                            let asset = batch[next]
                            if next + 2 * contentLanes < batch.count {
                                await analyzer.willAnalyze([batch[next + 2 * contentLanes]])
                            }
                            next += 1
                            inFlight += 1
                            let earlier = labelsOnly[asset.id]
                            // Cancelled at a Pause instead of finished first (review P4-07).
                            group.addTask {
                                do {
                                    guard let earlier else {
                                        return (asset, .success(try await control.cancellingOnPause {
                                            try await analyzer.analyzeContent(asset, request: peopleRequest)
                                        }))
                                    }
                                    let fresh = try await control.cancellingOnPause {
                                        try await analyzer.analyzeContent(asset, request: .labelsOnly)
                                    }
                                    return (asset, .success(earlier.addingLabels(of: fresh)))
                                } catch {
                                    return (asset, .failure(error))
                                }
                            }
                        }
                        guard let (asset, outcome) = try await group.next() else { break }
                        inFlight -= 1
                        switch outcome {
                        case .success(let result):
                            results.append((asset.id, result))
                            finished.append(asset.id)
                            analyzed += 1
                            if labelsOnly[asset.id] != nil || analysedBefore[asset.id] != nil {
                                report.labelsAdded += 1
                            } else if triedAgain.contains(asset.id) {
                                report.givenUpReadAgain += 1
                            }
                            // "Gerade angesehen" shows no screenshot, and no document, receipt or
                            // card either (second review of the build 36 fix): this result
                            // says whether the picture is one, before any text is read.
                            if !asset.isScreenshotLike && !result.isDocumentLike {
                                lookedAt.append(asset.id)
                                if lookedAt.count > 3 { lookedAt.removeFirst() }
                            }
                            // The analyzer works: the photos it failed on just before were the problem.
                            for id in suspects {
                                if try await recordFailure(id, labelsOnly: labelsOnlyIDs.contains(id)) { finished.append(id) }
                            }
                            suspects = []
                        case .failure(let error):
                            deferred.insert(asset.id)
                            if error is CancellationError, control.isPaused, !Task.isCancelled {
                                // Given up for the Pause, not unreadable: nothing is counted for it,
                                // and the run ends like at a Pause between two photos.
                                if stopped == nil { stopped = .userPaused; stopSeen = .now }
                            } else if error is CancellationError || Task.isCancelled {
                                // Stopped, not unreadable: what is done stays done, the rest waits.
                                cancelled = true
                            } else if let quiet = error as? PhotosNotResponding {
                                if photosQuiet == nil { photosQuiet = quiet }
                            } else if !(error is AnalysisError), !triedAgain.contains(asset.id) {
                                suspects.append(asset.id)
                                if suspects.count >= Self.analyzerFailureLimit, stopped == nil {
                                    // Vision itself fails: going through every photo would mark all
                                    // of them as unreadable. The run ends; the photos wait untouched.
                                    report.analyzerUnavailable = true
                                    stopped = .timeBudget
                                }
                            } else if await accessChanged() {
                                // Not the photo: the access was taken away. Nothing is counted.
                                stopped = .accessRevoked
                            } else if try await recordFailure(asset.id, labelsOnly: labelsOnlyIDs.contains(asset.id)) {
                                // Not readable right now (no local preview yet, still syncing): tried
                                // again in later runs, and given up only after a few of them.
                                finished.append(asset.id)
                            }
                        }
                    }
                }
                // With labels wanted, every photo done here has its labels: looked at with them
                // asked for, labels stored before, or given up (not readable, also without labels).
                // A photo that only needs its labels and cannot be read now (it was before) is tried
                // again in later runs like any photo (`LabelAttempts`) and given up for its labels
                // after as many; its earlier result stays as it is meanwhile and after.
                try await store.saveResults(results, kind: "content", version: Self.contentVersion, markingAnalyzed: finished,
                                            labelsVersion: labels)
                let read = Set(results.map(\.0))
                try await store.removeResults(kind: "labels", assets: labelAttempts.keys.filter(read.contains))
                if cancelled { throw CancellationError() }
                if let photosQuiet { throw photosQuiet }
                if cut {
                    // Goes on behind the last photo looked at (same order as the store's query);
                    // without a date, from the start of the photos still to analyse.
                    let last = batch[next - 1]
                    cursor = last.creationDate != nil ? last : nil
                }
                contentDone += finished.count
                report.contentAnalyzed += analyzed
                sayContent(Progress(stage: .content, completed: contentBefore + contentDone,
                                    total: contentBefore + max(contentTotal, contentDone), recent: lookedAt))
                if let stopped { report.pausedBecause = stopped; await settleEarly(stopping: stopSeen ?? .now); return report }
            }
            await settleEarly(stopping: nil)
        } catch {
            // The run ends with an error (also when it was cancelled): the early suggestions are
            // not saved any more if they have not been yet.
            if let early { abandonEarly(early.task) }
            throw error
        }
        report.completedStages.append(.content)
        contentShown = nil

        // 5. Text
        let textStart = now()
        // What `recognizeText` reads first thing (same moment, no wait in between).
        report.settingsUsed.text = Self.readsText(settings)
        let textOutcome = try await recognizeText(scoped, onProgress: onProgress)
        report.textSeconds = now().timeIntervalSince(textStart)
        report.textRecognized = textOutcome.recognized
        report.textWaitingForOriginal = textOutcome.waiting
        report.analyzerUnavailable = report.analyzerUnavailable || textOutcome.analyzerUnavailable
        if let reason = textOutcome.paused { report.pausedBecause = reason; return report }
        report.completedStages.append(.text)

        // 6. Groups
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        onProgress(Progress(stage: .groups, completed: 0, total: 0))
        let groups = try await groupObservations()
        report.completedStages.append(.groups)

        // 7. Proposals
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        onProgress(Progress(stage: .proposals, completed: 0, total: 0))
        if let fresh = try await patternsAfterAHomeChange(since: &patternsGeneration, all: all) { (trips, frequent) = fresh }
        let snapshot: ProposalSnapshot
        do {
            snapshot = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope,
                                               homeChange: patternsGeneration, stopsAt: control)
        } catch is CancellationError where control.isPaused {
            report.pausedBecause = .userPaused
            return report
        }
        report.proposals = snapshot.proposals.count
        report.completedStages.append(.proposals)
        onProgress(Progress(stage: .proposals, completed: snapshot.proposals.count, total: snapshot.proposals.count))
        return report
    }

    // MARK: Stages

    /// Step 2: trips, the places the user is often at, frequent places and the home, from time
    /// and GPS alone (no network, seconds even for a large library). Stored as it goes.
    /// Trips and places detected again when "Dein Zuhause" or the places the user is often at
    /// changed since `generation` (a run that was busy meanwhile follows the change); `nil` when
    /// nothing changed.
    private func patternsAfterAHomeChange(since generation: inout Int, all: [AssetSnapshot]) async throws -> (trips: [Trip], frequent: [FrequentPlace])? {
        guard generation != homeGeneration else { return nil }
        generation = homeGeneration
        let (trips, frequent) = try await detectPatterns(all: all)
        return (try await inDestinationTime(trips, all: all), frequent)
    }

    /// `progress(grouped, of)`: photos with a location grouped so far (see `TripDetector.analyse`).
    /// Detected once, on the clock of the home (`patternsClock`), and stored at the end, the home
    /// time zone with the trips and places.
    /// `control`: a Pause of the run throws `CancellationError`, also inside the detection
    /// (review P4-07: over 100,000 photos the step took up to 6.3 s without asking), before
    /// anything is stored: all of it or none.
    private func detectPatterns(all: [AssetSnapshot], stopsAt control: AnalysisRunControl? = nil,
                                progress: (_ grouped: Int, _ of: Int) -> Void = { _, _ in }) async throws -> (trips: [Trip], frequent: [FrequentPlace]) {
        let paused = { control?.isPaused == true }
        func checkPause(_ point: StopPoint) throws {
            stopPointProbe?(point)
            if paused() { throw CancellationError() }
        }
        let corrections = try await store.value(TripCorrections.self, forKey: Key.tripCorrections, defaults: TripCorrections()) ?? TripCorrections()
        let answers = try await recurringPlaceAnswers()
        var home = calendar
        let clock = try await patternsClock(all: all, corrections: corrections, answers: answers, progress: progress, stoppingWhen: paused)
        home.timeZone = clock.zone
        try checkPause(.tripsClockChosen)
        let tripAnalysis = try TripDetector(configuration: settings.trips.advanced, calendar: home)
            .analyse(in: all, corrections: corrections, places: answers, home: try await homeSettings(), progress: progress,
                     stoppingWhen: paused)
        try checkPause(.tripsDetected)
        let detected = tripAnalysis.trips
        // Trips keep their identity when their photos change a little (an older photo
        // imported, the first one deleted): decisions and deleted albums stay attached.
        var known = try await store.value([TripIdentity].self, forKey: Key.tripIdentities) ?? []
        if known.isEmpty {
            // First run with identities: the trips of the last analysis are the starting point.
            known = (try await store.value([Trip].self, forKey: Key.trips) ?? []).map(TripIdentity.init)
        }
        let trips = TripIdentity.carryOver(detected, from: known)
        // Photos set aside under "Ausgewählte Fotos" are not deleted: identities bound to them
        // stay, so trips and places come back with their ids (second review of P1-07).
        let setAside = try await store.outOfViewAssetIDs()
        // Places keep their IDs by their photos, from the places the last analysis stored (names,
        // "Nicht jetzt", decisions and albums are bound to them), and those kept while their
        // photos are set aside, after them. An unreadable list counts as none.
        var previousPlaces = (try? await store.value([FrequentPlace].self, forKey: Key.frequentPlaces)) ?? nil
        if let away = (try? await store.value([FrequentPlace].self, forKey: Key.frequentPlacesOutOfView)) ?? nil, !away.isEmpty {
            previousPlaces = Self.withPhotosSetAside(previousPlaces ?? [], away)
        }
        // A place's days: those of the clocks its photos were taken on, where their places are
        // known so far (review P1-15).
        var frequent = FrequentPlaceDetector(configuration: settings.frequentPlaces.advanced, calendar: home)
            .detect(in: all, previous: previousPlaces ?? [], zones: try await placeTimeZones(library: all))
        for i in frequent.indices { frequent[i].userName = settings.frequentPlaces.names[frequent[i].id] }
        // Each place before keeps its photos set aside for the next run: a place the shared
        // photos do not make whole, one they make only a part of with its part set aside (a
        // second selection with the other part keeps the id, third review of P1-07).
        let made = Set(frequent.map(\.id))
        let placesOutOfView: [FrequentPlace] = setAside.isEmpty ? [] : (previousPlaces ?? []).compactMap { place in
            guard !setAside.isDisjoint(with: place.assetIDs) else { return nil }
            guard made.contains(place.id) else { return place }
            var part = place
            part.assetIDs = place.assetIDs.filter(setAside.contains)
            return part
        }
        // The last moment to stop: from here on everything is stored, all of it or none.
        try checkPause(.tripsBeforeStoring)
        // Only a run or `resuggest()` stores the home time zone, never a read of the facts: it
        // goes into the safety copy, and a fresh database gets the decisions of a copy only
        // while it holds nothing of its own.
        if clock.store { try await store.setValue(clock.zone.identifier, forKey: Key.homeTimeZone) }
        try await store.setValue(Self.mergedIdentities(known, trips, library: Set(all.map(\.id)).union(setAside), setAside: setAside),
                                 forKey: Key.tripIdentities)
        try await store.setValue(RecurringPlaceReport(tripAnalysis, trips: trips, answers: answers), forKey: Key.recurringPlaceReport)
        try await store.setValue(trips, forKey: Key.trips)
        try await store.setValue(frequent, forKey: Key.frequentPlaces)
        if placesOutOfView.isEmpty {
            try await store.removeValue(forKey: Key.frequentPlacesOutOfView)
        } else {
            try await store.setValue(placesOutOfView, forKey: Key.frequentPlacesOutOfView)
        }
        try await store.setValue(tripAnalysis.atHome, forKey: Key.home)
        if let home = tripAnalysis.detectedHome {
            try await store.setValue(home, forKey: Key.detectedHome)
        } else {
            try await store.removeValue(forKey: Key.detectedHome)
        }
        return (trips, frequent)
    }

    /// The clock the trips are detected on, which follows the home (second review of P1-15):
    /// the home time zone in effect (`homeTimeZoneInEffect`), `store` where it changed: the zone
    /// of the home the user chose, of the home found before the update, or the iPhone's at the
    /// first analysis while no home is known. Stored by `detectPatterns` with the trips. Where the
    /// user left the home to the analysis and the home found on that clock has another zone
    /// (found for the first time, or a move), that zone, if the home found on its clock has it
    /// too. Two homes with about as many photo days can each have the more days on the other's
    /// clock (Munich and Auckland, half a day apart): following the detection would swap the zone
    /// with every run, so it stays as it was. Only the home is detected for this
    /// (`TripDetector.detectedHome`, a small part of the work), so the trips are detected once,
    /// with their count going on: a second detection on another clock stood silent for longer
    /// than the step may. The count is named first (`progress`, at 0).
    /// `stop`: gives up with `CancellationError` (`TripDetector.detectedHome`).
    private func patternsClock(all: [AssetSnapshot], corrections: TripCorrections, answers: RecurringPlaceAnswers,
                               progress: (_ grouped: Int, _ of: Int) -> Void,
                               stoppingWhen stop: () -> Bool) async throws -> (zone: TimeZone, store: Bool) {
        let (zone, changed) = try await homeTimeZoneInEffect(all: all)
        guard try await homeSettings().currentMode == .automatic else { return (zone, changed) }
        func homeFound(on zone: TimeZone, progress: (_ grouped: Int, _ of: Int) -> Void = { _, _ in }) throws -> DetectedHome? {
            var clock = calendar
            clock.timeZone = zone
            return try TripDetector(configuration: settings.trips.advanced, calendar: clock)
                .detectedHome(in: all, corrections: corrections, places: answers, progress: progress, stoppingWhen: stop)
        }
        guard let found = try homeFound(on: zone, progress: progress),
              let other = try await self.zone(ofHomeAt: found.center, components: nil, all: all),
              other.identifier != zone.identifier,
              let again = try homeFound(on: other),
              try await self.zone(ofHomeAt: again.center, components: nil, all: all)?.identifier == other.identifier else { return (zone, changed) }
        return (other, true)
    }

    /// Where a run checks for a Pause in the middle of the trips and suggestions steps (tests:
    /// `setStopPointProbe`, called right before each check).
    enum StopPoint: Sendable {
        case tripsClockChosen, tripsDetected, tripsBeforeStoring, suggestionsBeforeSaving
    }

    /// Tests only: see `StopPoint`.
    private var stopPointProbe: (@Sendable (StopPoint) -> Void)?
    func setStopPointProbe(_ probe: (@Sendable (StopPoint) -> Void)?) { stopPointProbe = probe }

    /// Day trip or weekend is decided in the destination's days, once places know its time
    /// zone (an evening in New York is already the next day in Munich): the zone the online
    /// lookup names, else the country's there (review P1-15). Stored when it changed.
    private func inDestinationTime(_ trips: [Trip], all: [AssetSnapshot]) async throws -> [Trip] {
        // Only the trips' photos count: with the zones of countries known offline nearly every
        // photo with a location has one.
        let members = Set(trips.lazy.flatMap(\.geotaggedAssetIDs))
        let travelled = all.filter { members.contains($0.id) }
        let placeZones = try await placeTimeZones(library: all)
        var zones: [AssetID: String] = [:]
        for id in members { if let zone = placeZones[id] { zones[id] = zone.identifier } }
        guard !zones.isEmpty else { return trips }
        let localTrips = TripDetector.inDestinationTime(trips, assets: Dictionary(uniqueKeysWithValues: travelled.map { ($0.id, $0) }),
                                                        timeZones: zones, calendar: try await homeCalendar())
        if localTrips != trips { try await store.setValue(localTrips, forKey: Key.trips) }
        return localTrips
    }

    /// How much work this run has (see `AnalysisWorkload`): the amounts over the part of the
    /// library the run works on, and what is still to do in the image and text steps.
    private func workload(all: [AssetSnapshot], scoped: [AssetSnapshot], year: PhotosOfTheYear?, labels: Int?) async throws -> AnalysisWorkload {
        let photos = year?.count ?? all.count
        let screenshots = scoped.filter(\.isScreenshotLike)
        let read = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion)
        let located = scoped.filter { $0.usableLocation != nil }
        // Places still to resolve, as the places step asks for them (`resolvePlaces`, not
        // refining): no place yet, or a town still pending (review of ee36188).
        let places = try await store.places()
        let wantsTown = PlaceResolutionPolicy(settings: settings).deepestLevel >= .locality
        let placesLeft = located.filter { asset in
            guard let place = places[asset.id] else { return true }
            return wantsTown && place.precisionMeters == nil
        }.count
        // Of the photos still to look at: those analysed already that get only their labels.
        var labelsLeft = 0
        if let labels {
            labelsLeft = try await store.countNeedingLabelsOnly(version: Self.contentVersion, labelsVersion: labels,
                                                                within: year?.range, excluding: year?.otherYears ?? [])
        }
        return AnalysisWorkload(
            photos: photos,
            located: located.count,
            screenshots: screenshots.count,
            contentLeft: try await store.countNeedingAnalysis(version: Self.contentVersion, labelsVersion: labels,
                                                              within: year?.range, excluding: year?.otherYears ?? []),
            textLeft: screenshots.filter { read[$0.id] == nil }.count,
            placesLeft: placesLeft,
            labelsLeft: labelsLeft
        )
    }

    /// Photos given up as unreadable (`ContentAnalysis.maxFailedAttempts`) were never read
    /// again, while the overview says "Albumist versucht es später noch einmal" and the count
    /// stayed at "29 von 30 analysiert" also once the photo could be read (review P1-08). A week
    /// after its last try such a photo is marked for the image step again: it gets one read,
    /// and still unreadable it is given up again at once (`recordContentFailure`), for another
    /// week. Looked for at most once a day (it reads every photo's result) and only in the
    /// part of the library the run works on. Not a photo this run reads anyway for its labels
    /// ("Themen" turned on later: one more full look for a photo given up, `labels`).
    private func reopenGivenUpPhotos(_ all: [AssetSnapshot], within year: PhotosOfTheYear?, labels: Int?) async throws {
        let now = now()
        if let checked = try await store.value(Date.self, forKey: Key.givenUpChecked),
           (0..<86_400).contains(now.timeIntervalSince(checked)) { return }
        let contents = try await store.results(ContentAnalysis.self, kind: "content", minimumVersion: Self.contentVersion)
        var due = Set(contents.compactMap { $0.value.isGivenUpAndDueAgain(now: now) ? $0.key : nil })
        if let labels, !due.isEmpty {
            due.subtract(try await store.unlabelledAssets(version: Self.contentVersion, labelsVersion: labels))
        }
        let reopen = all.filter { asset in due.contains(asset.id) && (year?.contains(asset) ?? true) }.map(\.id)
        if !reopen.isEmpty { try await store.markAnalyzed(reopen, version: 0) }
        try await store.setValue(now, forKey: Key.givenUpChecked)
    }

    /// Counts a failed read against a photo. Returns true when the photo is done with: read
    /// before (the image is unchanged, its earlier labels stay valid) or given up.
    private func recordContentFailure(_ id: AssetID) async throws -> Bool {
        let previous = try? await store.result(ContentAnalysis.self, kind: "content", asset: id)
        if let previous, previous.failedAttempts == nil { return true }
        let attempts = (previous?.failedAttempts ?? 0) + 1
        var failed = ContentAnalysis()
        failed.failedAttempts = attempts
        failed.lastAttempt = now()
        try await store.saveResult(failed, kind: "content", asset: id, version: Self.contentVersion)
        return attempts >= ContentAnalysis.maxFailedAttempts
    }

    private func recordFailure(_ id: AssetID, labelsOnly: Bool) async throws -> Bool {
        labelsOnly ? try await recordLabelsFailure(id) : try await recordContentFailure(id)
    }

    /// Counts a failed read against a photo that only needed its labels. Returns true when it
    /// is given up for them. Its content result is not touched.
    private func recordLabelsFailure(_ id: AssetID) async throws -> Bool {
        let previous = try? await store.result(LabelAttempts.self, kind: "labels", asset: id)
        let attempts = (previous?.failedAttempts ?? 0) + 1
        try await store.saveResult(LabelAttempts(failedAttempts: attempts, lastAttempt: now()), kind: "labels", asset: id,
                                   version: Self.labelsVersion)
        return attempts >= ContentAnalysis.maxFailedAttempts
    }

    private func resolvePlaces(
        _ all: [AssetSnapshot], trips: [Trip], frequent: [FrequentPlace], refining: Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> PlaceResolutionService.Outcome {
        let policy = PlaceResolutionPolicy(settings: settings)
        // Keys first, from the names as they are, then the names in the language.
        let stored = try await store.places()
        let keyed = try await keyedRegions(stored)
        if !keyed.isEmpty { try await store.setPlaces(keyed) }
        try await renamePlaces(to: policy.language)
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
            let stored = existing[asset.id]
            return .init(assetID: asset.id, coordinate: coordinate, priority: priority,
                         hasTown: stored?.precisionMeters != nil, hasCountry: stored != nil && stored?.precisionMeters == nil)
        }
        guard !requests.isEmpty else {
            try await saveWithoutCountry(.init())
            return .init()
        }
        let service = PlaceResolutionService(map: map, geocoder: geocoder, cache: store, policy: policy, time: time,
                                             requestLog: geocoderRequests)
        let store = self.store
        // Counted over every photo with a location, not only this run's requests: a run that
        // starts again after a pause goes on from the real state instead of from zero.
        let total = all.filter { $0.usableLocation != nil }.count
        let before = max(0, total - requests.count)
        let askedRecently = lastForegroundOnlineLookup.map { now().timeIntervalSince($0) < Self.foregroundOnlineCooldown } ?? false
        let budget = refining ? nil : (askedRecently ? 0 : foregroundOnlineBudget)
        onProgress(Progress(stage: .places, completed: before, total: total))
        // The count last shown, repeated with the time left while the run waits for the geocoder.
        let shown = Locked(before)
        let control = activeControl
        let outcome = try await service.resolve(requests, refining: refining, maxOnlineRequests: budget,
                                         mayWait: refining,
                                         shouldStop: { [weak self] in await self?.stopRequested() ?? true },
                                         onlineAllowed: { [weak self] in await self?.settings.privacy.allowOnlineGeocoding ?? false },
                                         progress: { processed in
                                             let completed = min(before + processed, total)
                                             shown.withLock { $0 = completed }
                                             onProgress(Progress(stage: .places, completed: completed, total: total))
                                         },
                                         checked: { checked in
                                             onProgress(Progress(stage: .places, completed: shown.withLock { $0 }, total: total,
                                                                 mapPass: MapPass(checked: checked, of: requests.count)))
                                         },
                                         paused: { control?.isPaused ?? false },
                                         waiting: { left in
                                             onProgress(Progress(stage: .places, completed: shown.withLock { $0 }, total: total, waitLeft: left))
                                         }) { [weak self] batch in
            // New places get the key their region has, whatever language they are named in.
            let keyed = try await self?.keyedRegions(batch) ?? [:]
            try await store.setPlaces(batch.merging(keyed) { $1 })
        }
        // Only a refusal, a used-up lookup limit (the budget, or the throttle's free slots: a run
        // in the app does not wait for them) or a Pause in the middle of asking starts the hour.
        // A one-off error, being offline or towns that stay open after an answer (a border cell)
        // do not: photos added later get their towns at once.
        if !refining, outcome.onlineRequests > 0,
           outcome.stoppedBecauseThrottled || outcome.stoppedAtRequestLimit || outcome.stoppedAsking {
            lastForegroundOnlineLookup = now()
        }
        try await saveWithoutCountry(outcome)
        return outcome
    }

    /// Photos whose country cannot be found, for the status (`currentFacts`). A call that looked
    /// at every photo without a place replaces them; one cut short by a Pause adds to them (the
    /// photos it did not reach keep what the call before found). A photo that has a place since
    /// does not count (`LibraryStatus`); the next complete call drops it.
    private func saveWithoutCountry(_ outcome: PlaceResolutionService.Outcome) async throws {
        let before = try await store.value(Set<AssetID>.self, forKey: Key.placesWithoutCountry) ?? []
        let now = outcome.reachedAll ? outcome.withoutCountry : before.union(outcome.withoutCountry)
        guard now != before else { return }
        try await store.setValue(now, forKey: Key.placesWithoutCountry)
    }

    /// After the language of album names changed, the countries and regions of the places
    /// stored before are named again from the offline map, which has both languages, so a
    /// country's photos never carry two names ("Countries/Italien" next to "Italy", review
    /// P1-12). Town names come from Apple's lookup in the language it was made in and stay.
    /// The places of `places` whose region key changed, with it fixed (`RegionKeys`); new
    /// regions are recorded at once, so a run that stops halfway keeps their keys.
    private func keyedRegions(_ places: [AssetID: ResolvedPlace]) async throws -> [AssetID: ResolvedPlace] {
        guard let map, !places.isEmpty else { return [:] }
        let renamer = regionRenamer ?? map.renamer(to: .german)
        regionRenamer = renamer
        var keys = try await regionKeys()
        let before = keys
        let changed = keys.fix(places, with: renamer)
        if keys != before { try await store.setValue(keys, forKey: Key.regionKeys) }
        return changed
    }

    /// The library's region keys. A table this build cannot read counts as none: the keys the
    /// stored places carry outweigh names when it is made anew (`RegionKeys.fix`), so the ids
    /// stay. The table under its first key is moved over once.
    private func regionKeys() async throws -> OfflineWorldMap.RegionKeys {
        if let keys = try await readable({ try await store.value(OfflineWorldMap.RegionKeys.self, forKey: Key.regionKeys) }) { return keys }
        guard let earlier = try await readable({ try await store.value(OfflineWorldMap.RegionKeys.self, forKey: Key.regionKeysBefore) }) else {
            return OfflineWorldMap.RegionKeys()
        }
        try await store.setValues([Key.regionKeys: earlier], removing: [Key.regionKeysBefore])
        return earlier
    }

    private func renamePlaces(to language: TitleLanguage) async throws {
        guard let map, try await store.value(TitleLanguage.self, forKey: Key.placesLanguage) != language else { return }
        let renamer = map.renamer(to: language)
        var renamed: [AssetID: ResolvedPlace] = [:]
        // Also the places of photos set aside under "Ausgewählte Fotos": they come back renamed.
        for (id, var place) in try await store.places(includingOutOfView: true) {
            let components = renamer.renamed(place.components)
            guard components != place.components else { continue }
            place.components = components
            renamed[id] = place
        }
        if !renamed.isEmpty { try await store.setPlaces(renamed) }
        try await store.setValue(language, forKey: Key.placesLanguage)
    }

    struct TextOutcome {
        var recognized = 0
        var waiting = 0
        var paused: PauseReason?
        var analyzerUnavailable = false
    }

    private func recognizeText(
        _ all: [AssetSnapshot],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TextOutcome {
        var outcome = TextOutcome()
        guard Self.readsText(settings) else { return outcome }
        let done = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion)
        let networkAllowed = await networkAllowedNow()
        let started = now()
        let needing: [AssetSnapshot]
        var screenshotLabels: [AssetID: Set<String>] = [:]
        do {
            // Every photo's labels are read once here and let go before the slow part: on a
            // large library they are the biggest thing this stage would hold for hours of OCR.
            let contents = try await store.results(ContentAnalysis.self, kind: "content")
            needing = all.filter { asset in
                guard let content = contents[asset.id] else { return false }
                return content.needsTextRecognition(for: asset)
            }
            for asset in needing where asset.isScreenshotLike {
                screenshotLabels[asset.id] = Set(contents[asset.id]?.labels.map(\.identifier) ?? [])
            }
        }
        let candidates = needing.filter { asset in
            guard let previous = done[asset.id] else { return true }
            return previous.shouldRetry(networkAllowed: networkAllowed, now: started)
        }
        // Counted over all screenshots and documents, so a later run goes on from the real state.
        let textBefore = needing.count - candidates.count
        // Said as soon as the count is known, also when nothing is left to read. A "0" said
        // before the count put the bar of a run that goes on in this step below where the
        // paused run had got to (simulated full run: 86 % back to 80 %).
        onProgress(Progress(stage: .text, completed: textBefore, total: needing.count))
        let documents = DocumentAnalyzer()
        let screenshots = ScreenshotClassifier()
        let analyzer = self.analyzer
        let control = activeControl ?? AnalysisRunControl()
        // Analyzer errors in a row, not counted against the photos yet (see the content stage).
        var suspects: [AssetID] = []
        var processed = 0
        var lastShown = now()
        // The count moves with every photo that takes time (device test 15.11.: shown only
        // every 20 photos, the stage looked stuck), and in steps of 20 when they go fast.
        func counted() {
            processed += 1
            let time = now()
            if processed % 20 == 0 || processed == candidates.count || time.timeIntervalSince(lastShown) >= 1 {
                lastShown = time
                onProgress(Progress(stage: .text, completed: textBefore + processed, total: needing.count))
            }
        }
        try await withThrowingTaskGroup(of: (AssetSnapshot, Bool, Result<TextAnalysis, any Error>).self) { group in
            var next = 0
            var inFlight = 0
            var width = textLanes
            var cancelled = false
            // A read that may download an original is in work: it goes alone, so leaving
            // Wi-Fi or switching off the consent applies to the very next photo (audit 2, 5.1).
            var downloading = false
            // Photos did not hand over a photo in time: neither the photo's fault nor Vision's.
            // Nothing is counted for it, no new reads start, and the run ends with the error like
            // in the image step (third review of the PhotoKit limits, N3).
            var photosQuiet: PhotosNotResponding?
            while true {
                while outcome.paused == nil, !cancelled, photosQuiet == nil, !downloading, next < candidates.count, inFlight < width {
                    let asset = candidates[next]
                    let previous = done[asset.id]
                    let allowNetwork = networkAllowed ? await networkAllowedNow() : false
                    // Needed the network and it is gone now: stays as it is for a later run.
                    if let previous, previous.waitingForOriginal || previous.text?.source == .localPreview, !allowNetwork {
                        next += 1
                        counted()
                        continue
                    }
                    if allowNetwork && inFlight > 0 { break }
                    let (reason, lanes) = await admission(lanes: textLanes)
                    if let reason { outcome.paused = reason; break }
                    width = lanes
                    guard inFlight < width else { break }
                    next += 1
                    downloading = allowNetwork
                    inFlight += 1
                    // Cancelled at a Pause instead of finished first (review P4-07).
                    group.addTask {
                        do {
                            return (asset, allowNetwork, .success(try await control.cancellingOnPause {
                                try await analyzer.recognizeText(asset, allowNetwork: allowNetwork)
                            }))
                        } catch {
                            return (asset, allowNetwork, .failure(error))
                        }
                    }
                }
                guard let (asset, allowNetwork, read) = try await group.next() else { break }
                inFlight -= 1
                if allowNetwork { downloading = false }
                let previous = done[asset.id]
                var result = TextResult()
                switch read {
                case .success(let text):
                    result.document = documents.analyze(text: text.text)
                    if asset.isScreenshotLike {
                        let labels = screenshotLabels[asset.id] ?? []
                        let classified = screenshots.classify(text: text.text, barcodePayloads: text.barcodePayloads, imageLabels: labels)
                        result.screenshotCategories = classified.categories.filter { $0.value >= .plausible }.map(\.key.rawValue).sorted()
                    }
                    // Analysis used the full text; only a minimized copy is kept on disk.
                    var stored = text
                    stored.text = TextMinimizer.storable(text.text)
                    // Barcode contents (boarding passes, payment codes with IBAN, tickets with
                    // names) only serve the classification above and are never kept.
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
                    outcome.recognized += 1
                    // The analyzer works: the photos it failed on just before were the problem.
                    for id in suspects { try await recordTextFailure(id, previous: done[id]) }
                    suspects = []
                case .failure(AnalysisError.originalNotAvailable):
                    result = previous ?? TextResult()
                    if allowNetwork {
                        // Even the download failed: a few more tries, spaced out, then it stays.
                        result.waitingForOriginal = false
                        result.retries = (previous?.retries ?? 0) + 1
                        result.lastAttempt = now()
                    } else {
                        result.waitingForOriginal = true
                        outcome.waiting += 1
                    }
                case .failure(let error):
                    if error is CancellationError, control.isPaused, !Task.isCancelled {
                        // Given up for the Pause: stays as it was, read again by the next run.
                        if outcome.paused == nil { outcome.paused = .userPaused }
                        continue
                    }
                    if error is CancellationError || Task.isCancelled {
                        cancelled = true
                        continue
                    }
                    if let quiet = error as? PhotosNotResponding {
                        if photosQuiet == nil { photosQuiet = quiet }
                        continue
                    }
                    if !(error is AnalysisError) {
                        // Vision failed, maybe not because of this photo: nothing is counted yet.
                        suspects.append(asset.id)
                        counted()
                        if suspects.count >= Self.analyzerFailureLimit, outcome.paused == nil {
                            outcome.analyzerUnavailable = true
                            outcome.paused = .timeBudget
                        }
                        continue
                    }
                    if await accessChanged() {
                        if outcome.paused == nil { outcome.paused = .accessRevoked }
                        continue
                    }
                    // Unreadable now: what was read before stays; a few more tries in later runs.
                    result = previous ?? TextResult()
                    result.waitingForOriginal = false
                    result.retries = (previous?.retries ?? 0) + 1
                    result.lastAttempt = now()
                }
                try await store.saveResult(result, kind: "text", asset: asset.id, version: Self.textVersion)
                counted()
            }
            if cancelled { throw CancellationError() }
            if let photosQuiet { throw photosQuiet }
        }
        return outcome
    }

    /// One more unsuccessful read of a photo's text: what was read before stays, and it is
    /// tried again later, spaced out (see `TextResult.shouldRetry`).
    private func recordTextFailure(_ id: AssetID, previous: TextResult?) async throws {
        var result = previous ?? TextResult()
        result.waitingForOriginal = false
        result.retries = (previous?.retries ?? 0) + 1
        result.lastAttempt = now()
        try await store.saveResult(result, kind: "text", asset: id, version: Self.textVersion)
    }

    /// iCloud rule: originals only with consent, on Wi-Fi unless cellular is allowed. Read from
    /// the current settings before every photo, so switching the consent off or leaving Wi-Fi
    /// stops the next download at once, not only the next run (audit 2, 5.1).
    private func networkAllowedNow() async -> Bool {
        guard settings.privacy.allowNetworkForAnalysis else { return false }
        if settings.privacy.allowCellularDownloads { return true }
        let onWiFi = await conditions.isOnWiFi()
        // The settings may have changed while waiting for the network state.
        return onWiFi && settings.privacy.allowNetworkForAnalysis
    }

    /// Texts stored before the masks got stricter are masked again once (no new reading of
    /// the photos): the stored copy only ever loses detail. Called at the start of every run,
    /// also when no text is read any more (screenshots, documents and messenger pictures off):
    /// what was stored before must not stay (second review of G2-03).
    private func remaskStoredTexts() async throws {
        let done = try await store.value(Int.self, forKey: Key.textMaskVersion) ?? 1
        guard done < TextMinimizer.maskVersion else { return }
        // Also the texts of photos set aside under "Ausgewählte Fotos": they come back masked.
        let current = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion, includingOutOfView: true)
        for (asset, var result) in try await store.results(TextResult.self, kind: "text", includingOutOfView: true) {
            // A big library takes minutes the first time; a cut-off run keeps what it did (masked
            // rows are skipped next time) and the purge below runs when the last row is done.
            try Task.checkCancellation()
            guard let text = result.text?.text else { continue }
            let level = TextMinimizer.sensitivity(of: text)
            let masked = text.isEmpty || level >= .identity ? "" : TextMinimizer.masked(text)
            // The subject line of a letter is stored with the document facts (review P2-04). An ID
            // or medical document keeps none: version 2 stored no text for it but its subject in
            // full, so it is cleared here even though there is no text to mask (second review).
            let sensitive = (result.document?.sensitivity ?? .normal) >= .identity || (!text.isEmpty && masked.isEmpty)
            let subject = sensitive ? nil : result.document?.subject.map(TextMinimizer.masked)
            // A document that newer words mark as sensitive (an English medical letter, review
            // G2-03) is handled as such from now on, also by the document proposals.
            let sensitivity = result.document.map { max($0.sensitivity, level) }
            guard masked != text || subject != result.document?.subject || sensitivity != result.document?.sensitivity else { continue }
            result.text?.text = masked
            result.document?.subject = subject
            if let sensitivity { result.document?.sensitivity = sensitivity }
            // An outdated result keeps its old version, so it is still read again later.
            let version = current[asset] != nil ? Self.textVersion : 0
            try await store.saveResult(result, kind: "text", asset: asset, version: version)
            if masked.isEmpty {
                try await store.removeText(for: asset)
            } else {
                try await store.indexText(masked, for: asset)
            }
        }
        // The old wording must not stay readable in the file: deleted rows are overwritten
        // (secure_delete), the search index drops its old entries and the log is emptied. Once
        // per mask version, also when an earlier, cut-off run changed the rows.
        try await store.purgeDeletedText()
        try await store.setValue(TextMinimizer.maskVersion, forKey: Key.textMaskVersion)
    }

    private func groupObservations() async throws -> [ObservationGroup] {
        guard settings.enabledAreas.contains(.peopleAndPets) else {
            try await store.setValue([ObservationGroup](), forKey: Key.groups)
            return []
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let feedback = try await store.value(GroupingFeedback.self, forKey: Key.groupingFeedback, defaults: GroupingFeedback()) ?? GroupingFeedback()
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

    /// What the early suggestions of a first run found besides the suggestions: the trips
    /// detected again after a change in "Dein Zuhause" (nil: none) and its generation.
    struct EarlySuggestions: Sendable {
        var fresh: (trips: [Trip], frequent: [FrequentPlace])?
        var generation: Int
    }

    /// Set when the early suggestions' task has ended, so a stopping run can wait for them a
    /// limited time (`run`).
    final class EarlyDone: Sendable {
        private let done = Locked(false)
        func mark() { done.withLock { $0 = true } }
        /// Whether they ended within `limit` (at once when the run itself is cancelled).
        func wait(upTo limit: Duration) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + limit
            while !done.withLock({ $0 }) {
                guard clock.now < deadline, !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    /// How long a stopping run waits for early suggestions that are not done yet (real time:
    /// Pause must take effect within a second). Tests that check the early set after a stop
    /// pass a long one: their simulated clocks reach a stop in far less real time than a device.
    private let earlyGraceOnStop: Duration

    /// Early suggestions of a run that stopped or failed before they were done: cancelled,
    /// they neither save nor say anything (`makeProposals`, `earlySuggestions`). The next run
    /// waits for them to end before it begins (`beginRun`).
    private var earlyLeftBehind: [Task<EarlySuggestions, any Error>] = []

    private func abandonEarly(_ task: Task<EarlySuggestions, any Error>) {
        task.cancel()
        earlyLeftBehind.append(task)
    }

    /// Also for tests: the early suggestions a stopped run left behind have ended.
    func waitForEarlyLeftBehind() async {
        while let task = earlyLeftBehind.popLast() { _ = try? await task.value }
    }

    /// Tests only: runs at the start of the early suggestions (a test makes them fail there).
    private var earlyProbe: (@Sendable () throws -> Void)?
    func setEarlyProbe(_ probe: (@Sendable () throws -> Void)?) { earlyProbe = probe }

    /// The early suggestions of a first run (trips, countries, places; see `run`), made beside
    /// the image step's first photos. Once they are saved, the step's newest report is said
    /// again with `earlyProposals`: the overview reads them then (review I2), and the count
    /// stays where it is.
    private func earlySuggestions(all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace],
                                  scope: OrganizationScope, generation: Int,
                                  onProgress: @escaping @Sendable (Progress) -> Void) async throws -> EarlySuggestions {
        try earlyProbe?()
        var generation = generation
        var (trips, frequent) = (trips, frequent)
        try Task.checkCancellation()
        let fresh = try await patternsAfterAHomeChange(since: &generation, all: all)
        if let fresh { (trips, frequent) = fresh }
        let groups = try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
        _ = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope,
                                    early: true, homeChange: generation, abandonable: true)
        // Left behind by a run that stopped meanwhile (and saved after all, if it was cancelled
        // while saving): that run has said its last report.
        if !Task.isCancelled, var newest = contentShown {
            newest.earlyProposals = true
            onProgress(newest)
        }
        return EarlySuggestions(fresh: fresh, generation: generation)
    }

    /// Work that grows with the library (the facts of every photo, the suggestions, the
    /// matching), done off this actor: over 50,000 photos it takes seconds, and the image step
    /// of the run goes on meanwhile (`run`). The work itself is plain computation on copies.
    private func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let probe = offActorProbe
        return await Task.detached(priority: Task.currentPriority) {
            await probe?()
            return work()
        }.value
    }

    /// When work in the middle of a step gives up (review P4-07): at a Pause of the run
    /// (`control`), and for early suggestions also when they are dropped (`whenCancelled`: the
    /// calling task is cancelled).
    struct WorkStop: Sendable {
        let control: AnalysisRunControl?
        let whenCancelled: Bool
        /// Asked in the calling task.
        var now: Bool { control?.isPaused == true || (whenCancelled && Task.isCancelled) }
    }

    /// Settled once: by the end of the work (`false`) or by a stop (`true`), whichever is first.
    private final class FirstOf: Sendable {
        private let state = Locked<(stopped: Bool?, waiting: CheckedContinuation<Bool, Never>?)>((nil, nil))

        func settle(stopped: Bool) {
            let waiting = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard state.stopped == nil else { return nil }
                state.stopped = stopped
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume(returning: stopped)
        }

        var stopped: Bool {
            get async {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let settled = state.withLock { state -> Bool? in
                        if let stopped = state.stopped { return stopped }
                        state.waiting = continuation
                        return nil
                    }
                    if let settled { continuation.resume(returning: settled) }
                }
            }
        }
    }

    /// `offActor`, given up the moment `stop` says so (a Pause wakes it, no polling): throws
    /// `CancellationError` then (review P4-07: a Pause waited for seconds of it). The work's own
    /// task is cancelled: the facts, the suggestions and the matching ask for that and end
    /// early with a result nobody reads, and the next run waits for it (`beginRun`), so a
    /// "Fortsetzen" never runs beside a copy of it. Without `stop`, plain `offActor`.
    private func offActor<T: Sendable>(unless stop: WorkStop?, _ work: @escaping @Sendable () -> T) async throws -> T {
        guard let stop, stop.control != nil || stop.whenCancelled else { return await offActor(work) }
        if stop.now { throw CancellationError() }
        let probe = offActorProbe
        let first = FirstOf()
        let task = Task.detached(priority: Task.currentPriority) { () -> T in
            defer { first.settle(stopped: false) }
            await probe?()
            return work()
        }
        let watcher = stop.control.map { control in
            Task.detached {
                await control.untilPaused()
                // Also when the watcher is cancelled after the work ended: settled already.
                if control.isPaused { first.settle(stopped: true) }
            }
        }
        let stopped = await withTaskCancellationHandler {
            await first.stopped
        } onCancel: {
            if stop.whenCancelled { first.settle(stopped: true) }
        }
        watcher?.cancel()
        guard !stopped else {
            task.cancel()
            // A task of its own that waits for the work and drops its value, so a partial
            // result (up to a whole set of facts) is freed when the work ends, not only at
            // the next run, which may be hours later while paused (re-review N2).
            let ending = Task.detached(priority: .utility) { _ = await task.value }
            abandonedWork.append { await ending.value }
            throw CancellationError()
        }
        return await task.value
    }

    /// Work given up by `offActor(unless:)` that may still be ending (see there).
    private var abandonedWork: [@Sendable () async -> Void] = []

    /// Also for tests: the work given up at a Pause has ended.
    func waitForAbandonedWork() async {
        while let work = abandonedWork.popLast() { await work() }
    }

    /// Tests only: runs where `offActor` work runs, before it (a test holds it there and sees
    /// the image step go on).
    private var offActorProbe: (@Sendable () async -> Void)?
    func setOffActorProbe(_ probe: (@Sendable () async -> Void)?) { offActorProbe = probe }

    /// Tests only: called whenever the zones of the photos' places are worked out.
    private var zoneProbe: (@Sendable () -> Void)?
    func setZoneProbe(_ probe: (@Sendable () -> Void)?) { zoneProbe = probe }

    /// After a change in "Dein Zuhause" that no suggestions were made for yet
    /// (`PendingHomeChange`), whichever step makes them (`resuggest()`, a run, the early set):
    /// the suggestions the user chose before the change keep their content (`HeldSuggestions`),
    /// and the overview is told (`HomeChangeNotice`), in the same transaction as the suggestions.
    /// `homeChange`: `homeGeneration` as it was before `trips` were detected. A change stored
    /// after that (the trips or the settings read here may be older than it) stays pending.
    private func makeProposals(
        all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace],
        groups: [ObservationGroup], scope: OrganizationScope, early: Bool = false, homeChange: Int, abandonable: Bool = false,
        stopsAt control: AnalysisRunControl? = nil
    ) async throws -> ProposalSnapshot {
        // Dropped meanwhile (an early set, `abandonable`) or the run paused (`control`, review
        // P4-07: the step took 3.5 to 7.8 s over 50,000 to 100,000 photos without asking): no
        // more of the suggestions is made, and nothing is saved (`CancellationError`).
        let stop = WorkStop(control: control, whenCancelled: abandonable)
        func checkStop() throws { if stop.now { throw CancellationError() } }
        let pending = try await pendingHomeChange()
        // The albums are read again: a plan applied while this run was busy (minutes or hours
        // on a large library) created albums the matching must see, or it would suggest them
        // a second time.
        let generation = albumGeneration
        var inventory = inventory
        if await albumsUnchanged(inventory) {
            // Nothing changed in the library since this run read the albums.
        } else if let fresh = try? await reader.currentInventory(), fresh != inventory {
            inventory = fresh
            try await store.saveInventory(fresh)
        }
        // An early set has no image or text themes (`ProposalSnapshot.isEarly`), also when photos
        // were analysed already (a first run paused in the image step): only the full set, made
        // once every photo is looked at, offers those.
        let home = try await homeCalendar()
        try checkStop()
        let facts = try await currentFacts(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups,
                                           analysed: !early, unless: stop)
            .filter { scope.includes($0, calendar: home) }
        // Dropped meanwhile: the suggestions (seconds over a large library) are not made at all.
        try checkStop()
        let overrides = OverrideSet(try await store.overrides())
        let scopedIDs = Set(facts.map(\.id))
        let oftenHere = try await recurringPlaceReport()?.places ?? []
        var analysis = AnalysisSnapshot(
            facts: facts,
            trips: scope == .all ? trips : trips.filter { !scopedIDs.isDisjoint(with: $0.geotaggedAssetIDs) },
            frequentPlaces: scope == .all ? frequent : [],
            groups: groups,
            // Like trips: a place with photos in the trial year comes with all its photos.
            recurringPlaces: scope == .all ? oftenHere : oftenHere.filter { !scopedIDs.isDisjoint(with: $0.assetIDs) },
            home: try await homeSettings()
        )
        analysis.applied = Set(Self.assignments(try await store.managedAlbums()).keys)
        analysis.chosen = try await chosenSuggestions()
        let engine = ProposalEngine(settings: settings, calendar: home)
        let input = analysis
        var suggestions = try await offActor(unless: stop) {
            engine.suggestions(for: input, overrides: overrides, stoppingWhen: { Task.isCancelled })
        }
        try checkStop()
        // Chosen before a change in "Dein Zuhause": stays as the user chose it, in this and
        // every later run, until it is created or deselected.
        let decisions = try await store.value([AlbumistID: ProposalDecision].self, forKey: Key.decisions) ?? [:]
        var held = try await heldSuggestions()
        if let pending { held = HeldSuggestions.adding(pending.before.proposals, to: held, decisions: decisions, new: suggestions) }
        // A chosen suggestion keeps its photos set aside under "Ausgewählte Fotos" and shows only
        // the shared ones (second review of P1-07).
        let inView = Set(all.map(\.id))
        held = HeldSuggestions.apply(held, decisions: decisions, library: inView.union(try await store.outOfViewAssetIDs()),
                                     inView: inView, to: &suggestions)
        // The full set after an early one: a suggestion of the early set the user already
        // decided on stays, even when the full analysis would not make it any more (review
        // minor: a decision must not lose its suggestion).
        var keptMatches: [AlbumistID: MatchResult] = [:]
        if !early, let previous = try await latestProposals(), previous.isEarly,
           let decided = try await store.value([AlbumistID: ProposalDecision].self, forKey: Key.decisions) {
            let present = Set(suggestions.open.map(\.id)).union(suggestions.dismissed.map(\.id))
            for p in previous.proposals where !present.contains(p.id) && (decided[p.id] ?? .undecided) != .undecided {
                suggestions.open.append(p)
                keptMatches[p.id] = previous.matches[p.id]
            }
        }
        let tripSets = trips.map { Set($0.allAssetIDs) }
        let unlocated = Set(all.filter { $0.usableLocation == nil }.map(\.id))
        let found = suggestions, albums = inventory
        let assignments = Self.assignments(try await store.managedAlbums(), proposals: found.open + found.dismissed, inventory: albums)
        var matches = try await offActor(unless: stop) {
            Self.match(found.open, dismissed: found.dismissed, against: albums, overrides: overrides, assignments: assignments, trips: tripSets,
                       unlocated: unlocated, stoppingWhen: { Task.isCancelled })
        }
        if generation != albumGeneration {
            // A plan was applied while this ran: match against the albums as they are now, or
            // the suggestions would offer albums that were just created.
            let albumsNow = try await store.loadInventory(), overridesNow = OverrideSet(try await store.overrides())
            let assignmentsNow = Self.assignments(try await store.managedAlbums(), proposals: found.open + found.dismissed, inventory: albumsNow)
            matches = try await offActor(unless: stop) {
                Self.match(found.open, dismissed: found.dismissed, against: albumsNow, overrides: overridesNow, assignments: assignmentsNow,
                           trips: tripSets, unlocated: unlocated, stoppingWhen: { Task.isCancelled })
            }
        }
        for (id, match) in keptMatches where matches[id] == nil { matches[id] = match }
        var snapshot = ProposalSnapshot(generatedAt: now(), scope: scope, proposals: suggestions.open, matches: matches,
                                        dismissed: suggestions.dismissed, standIns: suggestions.standIns, isEarly: early)
        snapshot.datedAfterwards = Set(facts.filter { ($0.asset.creationDate ?? .distantPast) > snapshot.generatedAt }.map(\.id))
        var values: [String: any Encodable & Sendable] = [Key.proposals: snapshot, Key.heldSuggestions: held]
        var removing: Set<String> = []
        if let pending {
            let heldIDs = Set(held.map(\.id))
            let notice = try await homeChangeNotice()?.followed(by: snapshot, held: heldIDs, date: now())
                ?? HomeChangeNotice(before: pending.before, after: snapshot, held: heldIDs, date: now())
            // A change stored while these suggestions were made stays pending for the next step.
            if homeChange == homeGeneration, homeChangesBeingStored == 0 {
                if notice.isEmpty { removing.insert(Self.homeChangeNoticeKey) } else { values[Self.homeChangeNoticeKey] = notice }
                removing.insert(Key.pendingHomeChange)
            }
        }
        // The early set of a run that stopped or failed meanwhile is not saved (`run`), nor the
        // set of a run paused meanwhile.
        stopPointProbe?(.suggestionsBeforeSaving)
        try checkStop()
        proposalsGeneration += 1
        try await store.setValues(values, removing: removing)
        return snapshot
    }

    /// The suggestions the user named in the app (`user.titles`, a name typed for it) or chose
    /// to create (an accepted decision): the same place as another suggestion keeps them
    /// (`ProposalEngine.suggestEachPlaceOnce`). Values this build cannot read count as none.
    func chosenSuggestions() async throws -> Set<AlbumistID> {
        let titles = try await readable { try await store.value([AlbumistID: String].self, forKey: Key.titles) } ?? [:]
        let decisions = try await readable { try await store.value([AlbumistID: ProposalDecision].self, forKey: Key.decisions) } ?? [:]
        return Set(titles.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys)
            .union(decisions.filter { $0.value.isAccepted }.keys)
    }

    /// The shown suggestions are matched on their own, as always. The dismissed ones are
    /// matched together with them, so an album that spans several trips stays a broader
    /// collection for a dismissed trip too; only their results are taken from that pass.
    /// An album that already is the complete album of a dismissed suggestion stays its album:
    /// no shown suggestion extends it (review 16.11., A10).
    /// `stop`: asked between the matchings; when it says so, what is matched so far is
    /// returned (only for work whose result is dropped then, review P4-07).
    static func match(_ open: [AlbumProposal], dismissed: [AlbumProposal], against inventory: CollectionInventory,
                      overrides: OverrideSet, assignments: [AlbumistID: CollectionID],
                      trips: [Set<AssetID>] = [], unlocated: Set<AssetID> = [],
                      stoppingWhen stop: () -> Bool = { false }) -> [AlbumistID: MatchResult] {
        if stop() { return [:] }
        guard !dismissed.isEmpty else {
            return AlbumMatcher().match(open, against: inventory, overrides: overrides, assignments: assignments, trips: trips,
                                        unlocated: unlocated)
        }
        let all = AlbumMatcher().match(open + dismissed, against: inventory, overrides: overrides, assignments: assignments, trips: trips,
                                       unlocated: unlocated)
        if stop() { return [:] }
        let reserved = Set(dismissed.compactMap { p in
            all[p.id].flatMap { $0.status == .alreadyComplete && $0.best?.isEditable == true ? $0.best?.albumID : nil }
        })
        var matches = AlbumMatcher().match(open, against: inventory, overrides: overrides, assignments: assignments,
                                           reserved: reserved, trips: trips, unlocated: unlocated)
        for p in dismissed { matches[p.id] = all[p.id] }
        return matches
    }

    /// Facts for every asset from the stored results (also used by search and status).
    /// The trips the user split or merged (I07). Kept in time, so they hold for every
    /// later analysis; the next run applies them.
    public func tripCorrections() async throws -> TripCorrections {
        try await store.value(TripCorrections.self, forKey: Key.tripCorrections, defaults: TripCorrections()) ?? TripCorrections()
    }

    public func setTripCorrections(_ corrections: TripCorrections) async throws {
        try await store.setValue(corrections, forKey: Key.tripCorrections)
    }

    /// The user's answers to "Bist du hier öfter?". Kept by position, so they hold for every
    /// later analysis; the next run applies them.
    public func recurringPlaceAnswers() async throws -> RecurringPlaceAnswers {
        try await readable { try await store.value(RecurringPlaceAnswers.self, forKey: Key.recurringPlaces, defaults: RecurringPlaceAnswers()) } ?? RecurringPlaceAnswers()
    }

    /// Stores the answers; a change of the places the user is often at is applied like a change
    /// in "Dein Zuhause" (`setHomeChange`).
    public func setRecurringPlaceAnswers(_ answers: RecurringPlaceAnswers) async throws {
        try await setHomeChange(places: answers)
    }

    /// What the last analysis found about places visited again and again.
    public func recurringPlaceReport() async throws -> RecurringPlaceReport? {
        try await store.value(RecurringPlaceReport.self, forKey: Key.recurringPlaceReport)
    }

    // MARK: Dein Zuhause

    /// What the user set in "Dein Zuhause". Nothing stored (every version before this one):
    /// automatic, as before.
    /// A value this build cannot read (a later version's shape, or damage) is read as automatic,
    /// so it never stops an analysis.
    public func homeSettings() async throws -> HomeSettings {
        try await readable { try await store.value(HomeSettings.self, forKey: Key.homeSettings, defaults: HomeSettings()) } ?? HomeSettings()
    }

    public func setHomeSettings(_ home: HomeSettings) async throws {
        try await setHomeChange(home: home)
    }

    /// Stores a change in "Dein Zuhause" (`home`) and of the places the user is often at
    /// (`places`), with a `PendingHomeChange` when it changes what the suggestions are made
    /// from, all in one transaction. `resuggest()` applies it; if a run gets there first, or the
    /// app is ended before, that run applies it the same way.
    public func setHomeChange(home: HomeSettings? = nil, places: RecurringPlaceAnswers? = nil) async throws {
        var values: [String: any Encodable & Sendable] = [:]
        var changes = false
        if let home {
            values[Key.homeSettings] = home
            var old = try await homeSettings(), new = home
            old.changedAt = nil
            new.changedAt = nil
            changes = changes || old != new
        }
        if let places {
            values[Key.recurringPlaces] = places
            let old = try await recurringPlaceAnswers()
            changes = changes || old.oftenHere != places.oftenHere
        }
        guard !values.isEmpty else { return }
        // From the check for a pending change to the bump after the write, suggestions that
        // finish keep the mark (see makeProposals): the check, the write and the bump act as one.
        if changes { homeChangesBeingStored += 1 }
        defer { if changes { homeChangesBeingStored -= 1 } }
        if changes, try await pendingHomeChange() == nil, let current = try await latestProposals() {
            values[Key.pendingHomeChange] = PendingHomeChange(before: current, date: now())
        }
        if changes, let afterPendingCheck { await afterPendingCheck() }
        try await store.setValues(values)
        // After the write, and only when something the suggestions are made from changed ("Nein,
        // das sind Reisen" changes nothing): suggestions made from what was read before stay
        // pending (see makeProposals).
        if changes { homeGeneration += 1 }
    }

    /// The change in "Dein Zuhause" that no suggestions were made for yet.
    func pendingHomeChange() async throws -> PendingHomeChange? {
        try await readable { try await store.value(PendingHomeChange.self, forKey: Key.pendingHomeChange) }
    }

    /// Suggestions held as the user chose them; one this build cannot read is left out.
    func heldSuggestions() async throws -> [AlbumProposal] {
        (try await readable { try await store.value([Lenient<AlbumProposal>].self, forKey: Key.heldSuggestions) } ?? []).compactMap(\.value)
    }

    /// `read`, with a stored value this build cannot decode read as not stored. For values the
    /// user set or that only add to what is shown: they must never stop an analysis, and
    /// "Analyse neu aufbauen" keeps the `user.*` ones, so nothing else would clear them.
    private func readable<T>(_ read: () async throws -> T?) async throws -> T? {
        do { return try await read() } catch is DecodingError { return nil }
    }

    /// The home Albumist found by itself in the last analysis.
    public func detectedHome() async throws -> DetectedHome? {
        try await store.value(DetectedHome.self, forKey: Key.detectedHome)
    }

    /// What the overview says after a change in "Dein Zuhause", until the user taps OK.
    public static let homeChangeNoticeKey = "user.homeChangeNotice"

    /// After a change in "Dein Zuhause": only the suggestion step runs again, on what the
    /// analysis already knows (trips, places and the home from the stored dates and places,
    /// then the suggestions). No photo is read again and nothing changes in Photos. Suggestions
    /// the user already chose stay as they were (`HeldSuggestions`); what changed is stored
    /// for the overview in the same transaction as the new suggestions (`makeProposals`).
    /// Returns what the overview says (nil: nothing); nothing is made when there are no
    /// suggestions yet (the next analysis applies the settings) or a run already applied the
    /// change. Waits for a run in progress, like a run does.
    public func resuggest() async throws -> HomeChangeNotice? {
        await beginRun()
        defer { endRun() }
        guard let previous = try await latestProposals() else { return nil }
        guard try await pendingHomeChange() != nil else { return try await homeChangeNotice() }
        // Before the trips are detected: a change stored while they are stays pending.
        let homeChange = homeGeneration
        let all = try await store.allAssets()
        var (trips, frequent) = try await detectPatterns(all: all)
        trips = try await inDestinationTime(trips, all: all)
        let groups = try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
        _ = try await makeProposals(all: all, inventory: try await store.loadInventory(), trips: trips, frequent: frequent,
                                    groups: groups, scope: previous.scope, early: previous.isEarly, homeChange: homeChange)
        return try await homeChangeNotice()
    }

    /// "Analyse neu aufbauen": the stored analysis is deleted (`AlbumistStore.resetAnalysis`)
    /// between runs, never while a run or `resuggest()` is writing (they would write old results
    /// into the fresh tables). Waits for one in progress.
    public func resetAnalysis() async throws {
        await beginRun()
        defer { endRun() }
        // Before the reset is sent: a `rematch()` that read the old suggestions matches again
        // (and finds none) instead of writing them into the fresh store.
        proposalsGeneration += 1
        try await store.resetAnalysis(includingDecisions: false)
        lastForegroundOnlineLookup = nil
    }

    /// "OK" on the overview card.
    public func dismissHomeChangeNotice() async throws {
        try await store.removeValue(forKey: Self.homeChangeNoticeKey)
    }

    public func homeChangeNotice() async throws -> HomeChangeNotice? {
        try await readable { try await store.value(HomeChangeNotice.self, forKey: Self.homeChangeNoticeKey) }
    }

    public func currentFacts() async throws -> [AssetFacts] {
        try await currentFacts(
            all: try await store.allAssets(),
            inventory: try await store.loadInventory(),
            trips: try await store.value([Trip].self, forKey: Key.trips) ?? [],
            frequent: try await store.value([FrequentPlace].self, forKey: Key.frequentPlaces) ?? [],
            groups: try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
        )
    }

    /// The facts, with the album list and the image results read for them: the overview needs
    /// both too, and read them a second time next to the facts (review P4-02: the image results
    /// of 50,000 photos are about a second to read). Each input is read once; the photos and the
    /// places also serve the zones of the places when they are not known for this state of the
    /// places yet (the first refresh after a launch read both twice).
    func factsForOverview() async throws -> (facts: [AssetFacts], inventory: CollectionInventory, contents: [AssetID: ContentAnalysis]) {
        // Before the photos and the places are read: a write meanwhile keeps the zones made
        // from them from being kept (`placeTimeZones`).
        let revision = await store.placesRevision
        let all = try await store.allAssets()
        let inventory = try await store.loadInventory()
        let read = try await assembledFacts(
            all: all, inventory: inventory,
            trips: try await store.value([Trip].self, forKey: Key.trips) ?? [],
            frequent: try await store.value([FrequentPlace].self, forKey: Key.frequentPlaces) ?? [],
            groups: try await store.value([ObservationGroup].self, forKey: Key.groups) ?? [],
            analysed: true, placesRevision: revision)
        return (read.facts, inventory, read.contents)
    }

    /// Assembled off this actor (`offActor`): the overview asks for the facts while a run goes
    /// on (`refreshDerived` after the early suggestions), and over 50,000 photos assembling
    /// them held the run's image step for about a second on Linux.
    /// `analysed` false: without the labels and texts read so far (an early set, `makeProposals`).
    /// `stop`: given up when it says so (`offActor(unless:)`).
    private func currentFacts(all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace], groups: [ObservationGroup],
                              analysed: Bool = true, unless stop: WorkStop? = nil) async throws -> [AssetFacts] {
        try await assembledFacts(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups,
                                 analysed: analysed, placesRevision: nil, unless: stop).facts
    }

    /// `currentFacts`, with the image results it read. `placesRevision`: the state of the places
    /// taken before `all` was read; the zones of the places are then made from `all` and the
    /// places read here (`factsForOverview`), not read again.
    private func assembledFacts(all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace],
                                groups: [ObservationGroup], analysed: Bool, placesRevision: Int?,
                                unless stop: WorkStop? = nil) async throws -> (facts: [AssetFacts], contents: [AssetID: ContentAnalysis]) {
        let places = try await store.places()
        let contents = analysed ? try await store.results(ContentAnalysis.self, kind: "content") : [:]
        let texts = analysed ? try await store.results(TextResult.self, kind: "text") : [:]
        let home = try await store.value(Set<AssetID>.self, forKey: Key.home) ?? []
        let withoutCountry = try await store.value(Set<AssetID>.self, forKey: Key.placesWithoutCountry) ?? []
        let homeZone = try await homeTimeZone()
        let placeZones: [AssetID: TimeZone]
        if let placesRevision {
            placeZones = try await placeTimeZones(library: all, read: (placesRevision, places))
        } else {
            placeZones = try await placeTimeZones()
        }
        let facts = try await offActor(unless: stop) {
            FactsAssembler.assemble(assets: all, places: places, contents: contents, texts: texts, trips: trips,
                                    frequentPlaces: frequent, groups: groups, inventory: inventory, home: home,
                                    withoutCountry: withoutCountry, homeTimeZone: homeZone, placeZones: placeZones,
                                    stoppingWhen: { Task.isCancelled })
        }
        return (facts, contents)
    }

    /// The remembered identities, updated with this run's trips. Identities of trips that are
    /// not detected right now stay while any of their photos is still in the library (a trip
    /// can come back when its photos sync again or a correction is undone).
    /// `setAside`: photos set aside under "Ausgewählte Fotos". A trip that keeps its id keeps the
    /// photos of its identity that are set aside too: detected from the shared photos it is only
    /// a part of itself, and a second selection with the other part must find the id again
    /// (third review of P1-07). With full access nothing is set aside: the trip's photos.
    static func mergedIdentities(_ known: [TripIdentity], _ trips: [Trip], library: Set<AssetID>,
                                 setAside: Set<AssetID> = []) -> [TripIdentity] {
        let current = Set(trips.map(\.id))
        let before = Dictionary(known.map { ($0.id, $0.members) }, uniquingKeysWith: { first, _ in first })
        return trips.map { trip in
            var identity = TripIdentity(trip)
            if !setAside.isEmpty, let members = before[trip.id] {
                let mine = Set(identity.members)
                identity.members += members.filter { setAside.contains($0) && !mine.contains($0) }
            }
            return identity
        } + known.filter { identity in
            !current.contains(identity.id) && identity.members.contains(where: library.contains)
        }
    }

    /// The places of the analysis before (`stored`) with the photos set aside of each (`away`,
    /// `Key.frequentPlacesOutOfView`): a place of both keeps its photos and gets the others, a
    /// place only set aside comes after the stored ones (their order decides ties).
    static func withPhotosSetAside(_ stored: [FrequentPlace], _ away: [FrequentPlace]) -> [FrequentPlace] {
        var result = stored
        let index = Dictionary(stored.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for place in away {
            if let i = index[place.id] {
                let have = Set(result[i].assetIDs)
                result[i].assetIDs += place.assetIDs.filter { !have.contains($0) }
            } else if !result.contains(where: { $0.id == place.id }) {
                result.append(place)
            }
        }
        return result
    }

    /// Suggestion → the album it was applied to, from the managed-album records. Two albums
    /// can be recorded for one ID (the album of a place that had the ID before, and the one made
    /// for the place that has it now, second review of the place IDs 18.11.): the one sharing
    /// the most photos with the suggestion (`proposals`; its photos as in `inventory`, else as
    /// last recorded) is its album; with none shared, the first record, as before.
    static func assignments(_ states: [ManagedAlbumState], proposals: [AlbumProposal] = [],
                            inventory: CollectionInventory? = nil) -> [AlbumistID: CollectionID] {
        let recorded = recordedAlbums(states)
        var result = Dictionary(states.flatMap { state in state.allSourceIDs.map { ($0, state.albumID) } }, uniquingKeysWith: { first, _ in first })
        let members = Dictionary(states.map { ($0.albumID, $0.lastKnownMembers) }, uniquingKeysWith: { first, _ in first })
        for proposal in proposals {
            guard let albums = recorded[proposal.id], albums.count > 1, let first = result[proposal.id] else { continue }
            func shared(_ album: CollectionID) -> Int {
                (inventory?[album]?.assetIDs ?? members[album] ?? []).intersection(proposal.assetIDs).count
            }
            let best = albums.sorted { $0.rawValue < $1.rawValue }.max { shared($0) < shared($1) }
            if let best, shared(best) > shared(first) { result[proposal.id] = best }
        }
        return result
    }

    /// Suggestion → every album recorded for it.
    static func recordedAlbums(_ states: [ManagedAlbumState]) -> [AlbumistID: Set<CollectionID>] {
        states.reduce(into: [:]) { result, state in
            for id in state.allSourceIDs { result[id, default: []].insert(state.albumID) }
        }
    }

    public func latestProposals() async throws -> ProposalSnapshot? {
        try await store.value(ProposalSnapshot.self, forKey: Key.proposals)
    }

    /// Re-runs only the album matching against the stored inventory and overrides, after
    /// albums were created or the user said an album does not fit. The suggestions then show
    /// the right state at once instead of after the next analysis.
    /// New suggestions written while it matched (`resuggest()` or a run) are matched again
    /// instead of being overwritten with the older ones.
    public func rematch() async throws -> ProposalSnapshot? {
        while true {
            let generation = proposalsGeneration
            guard let snapshot = try await rematched() else { return nil }
            guard generation == proposalsGeneration else { continue }
            proposalsGeneration += 1
            try await store.setValue(snapshot, forKey: Key.proposals)
            return snapshot
        }
    }

    /// The stored suggestions matched again with the current rules, not saved yet.
    private func rematched() async throws -> ProposalSnapshot? {
        albumGeneration += 1
        guard var snapshot = try await latestProposals() else { return nil }
        let inventory = try await store.loadInventory()
        let overrides = OverrideSet(try await store.overrides())
        let trips = (try await store.value([Trip].self, forKey: Key.trips) ?? []).map { Set($0.allAssetIDs) }
        let unlocated = try await unlocatedInPlaceAlbums(snapshot.proposals + snapshot.dismissed, inventory: inventory)
        let found = snapshot
        let assignments = Self.assignments(try await store.managedAlbums(), proposals: found.proposals + found.dismissed, inventory: inventory)
        snapshot.matches = await offActor {
            Self.match(found.proposals, dismissed: found.dismissed, against: inventory, overrides: overrides, assignments: assignments, trips: trips,
                       unlocated: unlocated)
        }
        snapshot.matcherVersion = AlbumMatcher.version
        return snapshot
    }

    /// The photos without a location that matching needs: only those in an album named exactly
    /// like a place suggestion count apart (`AlbumMatcher.match(unlocated:)`). The photos are
    /// read only when there is such an album, not at every re-match (third review 19.11.).
    private func unlocatedInPlaceAlbums(_ proposals: [AlbumProposal], inventory: CollectionInventory) async throws -> Set<AssetID> {
        let places = Set(proposals.compactMap { proposal -> String? in
            switch proposal.kind {
            case .placeCollection, .frequentPlace: AlbumTitle.normalized(proposal.title)
            default: nil
            }
        })
        let members = inventory.albums.reduce(into: Set<AssetID>()) { members, album in
            if places.contains(AlbumTitle.normalized(album.title)) { members.formUnion(album.assetIDs) }
        }
        guard !members.isEmpty else { return [] }
        return Set(try await store.allAssets().filter { members.contains($0.id) && $0.usableLocation == nil }.map(\.id))
    }

    /// What `refreshMatchesIfOutdated` did.
    public struct MatchRefresh: Sendable {
        /// The suggestions with their matches (nil: there are none).
        public var snapshot: ProposalSnapshot?
        /// Suggestions whose accepted "extend this album" decision was no longer a certain
        /// match under the new rules (`ProposalDecision.uncertainExtensions`), or went into the
        /// album recorded for the ID while that album holds other photos
        /// (`ProposalDecision.extensionsOfOtherPhotos`), or went against "Gleicher Name gewinnt"
        /// (`ProposalDecision.sameNameConflicts`), and is open again in the store. The app drops
        /// them from its decisions in memory too.
        public var reopened: Set<AlbumistID> = []
    }

    /// How many suggestions a rule update set back to open, until the user tapped OK on the
    /// overview. Kept in the store and written together with the reopened decisions.
    public static let recheckedSuggestionsKey = "user.recheckedSuggestions"

    /// At launch: suggestions matched by an older version of the rules are matched again, so
    /// a fixed rule (review 16.11.: possible matches never change albums) holds at once and not
    /// only after the next analysis. Decisions accepted under the old rules that would now
    /// extend an album without a certain match go back to open (`reopened`), and so do those
    /// that go against "Gleicher Name gewinnt" (a second "Italien", or the trip keeping the
    /// album that is now the country's; not counted for the overview's notice, whose text gives
    /// the other reason); suggestions of a plan that already started (not finished) are never
    /// among them.
    ///
    /// Every time (the app calls this after each analysis too): an accepted "ergänzen" into the
    /// album recorded for the suggestion's ID while that album was made for other photos goes
    /// back to open (`ProposalDecision.extensionsOfOtherPhotos`, second review of the place IDs
    /// 18.11.: a frequent place's ID can go to a new place).
    ///
    /// The new matches with their version stamp, the decisions without the reopened ones and
    /// the count for the overview are written in one transaction (final check 16.11.): if the
    /// app is ended in between, nothing is written and the next launch does it again. Before,
    /// the stamp was saved first, and an old "ergänzen" survived such a crash for good.
    public func refreshMatchesIfOutdated() async throws -> MatchRefresh {
        try await refreshMatchesIfOutdated(afterEachWrite: nil)
    }

    /// `afterEachWrite`: for tests, runs inside the transaction after each value (see
    /// `AlbumistStore.setValues`); throwing there is the app ending half way.
    func refreshMatchesIfOutdated(afterEachWrite: (@Sendable (String) throws -> Void)?) async throws -> MatchRefresh {
        guard var snapshot = try await latestProposals() else { return MatchRefresh(snapshot: nil) }
        let outdated = snapshot.matcherVersion < AlbumMatcher.version
        // Decisions made before "Gleicher Name gewinnt" held whatever the album holds; a choice
        // made under that rule is the user's and stays at every later re-match (S5, 19.11.).
        let beforeSameNameRule = snapshot.matcherVersion < AlbumMatcher.sameNameWhateverItHoldsVersion
        if outdated {
            guard let rematched = try await rematched() else { return MatchRefresh(snapshot: nil) }
            snapshot = rematched
        }
        var decisions = try await store.value([AlbumistID: ProposalDecision].self, forKey: Key.decisions) ?? [:]
        let recorded = Self.recordedAlbums(try await store.managedAlbums())
        // Most refreshes have no "ergänzen" into an album recorded for the same suggestion.
        let ownAlbum = decisions.contains { id, decision in
            decision.isAccepted && decision.extendedAlbum.map { recorded[id]?.contains($0) == true } == true
        }
        // Remembered reopenings (below) of suggestions with neither a decision nor a recorded
        // album any more are dropped.
        let remembered = try await readable { try await store.value(Set<String>.self, forKey: Key.reopenedExtensions) } ?? []
        let before = remembered.filter { entry in
            let id = AlbumistID(String(entry.prefix { $0 != "|" }))
            return decisions[id] != nil || recorded[id] != nil
        }
        guard outdated || ownAlbum || before != remembered else { return MatchRefresh(snapshot: snapshot) }
        var values: [String: any Encodable & Sendable] = [:]
        if before != remembered { values[Key.reopenedExtensions] = before }
        let started = Set(try await store.unfinishedPlans().flatMap { $0.steps.compactMap(\.sourceID) })
        let suggested = snapshot.proposals + snapshot.dismissed
        var reopened = outdated ? ProposalDecision.uncertainExtensions(decisions, proposals: suggested, matches: snapshot.matches,
                                                                       protected: started) : []
        // Against "Gleicher Name gewinnt" (second review 19.11.): open again too, but not for
        // the reason the overview's notice gives ("nur noch, wenn sie sicher passen"), so they
        // are not counted for it.
        let sameName = outdated && beforeSameNameRule
            ? ProposalDecision.sameNameConflicts(decisions, proposals: suggested, matches: snapshot.matches, protected: started)
            : []
        if ownAlbum {
            // Once per suggestion and album: an album the user picks again for it ("Anderes
            // Album wählen") is their choice and stays (re-review 18.11.). Which way a decision
            // was made is not stored, so the first time cannot be told apart.
            let found = ProposalDecision.extensionsOfOtherPhotos(
                decisions, proposals: suggested, inventory: try await store.loadInventory(), recorded: recorded,
                overrides: OverrideSet(try await store.overrides()), protected: started)
            let pairs = Dictionary(found.compactMap { id in decisions[id]?.extendedAlbum.map { (id, id.rawValue + "|" + $0.rawValue) } },
                                   uniquingKeysWith: { first, _ in first })
            let new = pairs.filter { !before.contains($0.value) }
            if !new.isEmpty {
                reopened.formUnion(new.keys)
                values[Key.reopenedExtensions] = before.union(new.values)
            }
        }
        let counted = reopened.subtracting(sameName).count
        reopened.formUnion(sameName)
        guard outdated || !reopened.isEmpty || !values.isEmpty else { return MatchRefresh(snapshot: snapshot) }
        if outdated { values[Key.proposals] = snapshot }
        if !reopened.isEmpty {
            for id in reopened { decisions[id] = nil }
            values[Key.decisions] = decisions
            if counted > 0 {
                let shown = try await store.value(Int.self, forKey: Self.recheckedSuggestionsKey) ?? 0
                values[Self.recheckedSuggestionsKey] = shown + counted
            }
        }
        if outdated { proposalsGeneration += 1 }
        try await store.setValues(values, afterEach: afterEachWrite)
        return MatchRefresh(snapshot: snapshot, reopened: reopened)
    }
}

extension ResumedRun {
    /// Whether the database has photos, for `markerApplies` at the app's start. Photos set
    /// aside under "Ausgewählte Fotos" count (review P1-07): with no photo shared, a database
    /// full of analysis is not an empty one.
    public static func databaseHasPhotos(_ store: AlbumistStore) async throws -> Bool {
        try await store.assetCount(includingOutOfView: true) > 0
    }
}
