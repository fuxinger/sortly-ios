import Foundation
import Synchronization
import AlbumistCore

// What the analysis card shows, as pure values (progress display, spec v3 with the five points
// chosen on 15.11.). The app only renders these; every rule here is tested on Linux
// (AnalysisDisplayTests, FullRunDisplayTests).

// MARK: Steps

/// The six steps the card shows (spec M2). The pipeline's `groups` stage belongs to the last
/// step: grouping people and pets comes with version 1.1.
public enum AnalysisStep: Int, CaseIterable, Sendable, Codable, Comparable {
    case library, trips, places, content, text, proposals

    public init(_ stage: AnalysisPipeline.Stage) {
        switch stage {
        case .inventory: self = .library
        case .patterns: self = .trips
        case .places: self = .places
        case .content: self = .content
        case .text: self = .text
        case .groups, .proposals: self = .proposals
        }
    }

    /// 1-based, for "Schritt 4 von 6".
    public var number: Int { rawValue + 1 }
    public static var count: Int { allCases.count }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// What the step counts.
    public enum Unit: Sendable { case photos, places, screenshots, none }

    public var unit: Unit {
        switch self {
        case .library, .trips, .content: .photos
        case .places: .places
        case .text: .screenshots
        case .proposals: .none
        }
    }

    /// Usual device time per item and per step, on an iPhone of the owner's kind (the same
    /// values the simulated full run uses: 4 lanes à 0.4 s per photo, 2 lanes à 1 s per text,
    /// town names limited by Apple). Used for the widths of the bar and, scaled by how fast
    /// this device really is, for the steps that have not started yet.
    public var secondsPerItem: Double {
        switch self {
        case .library: 0.003
        case .trips: 0.001
        case .places: 0.06
        case .content: 0.1
        case .text: 0.5
        case .proposals: 0.002
        }
    }

    public var fixedSeconds: Double {
        switch self {
        case .library: 2
        case .trips: 1
        case .places: 0
        case .content: 0
        case .text: 0
        case .proposals: 3
        }
    }

    /// Steps whose speed depends on the device (not on Apple's geocoder or on fixed costs):
    /// they tell how fast this iPhone is compared with the usual times.
    var measuresDevice: Bool { self == .content || self == .text }
}

/// How much work a run has, known right after the library was read and the trips were found
/// (said once with the end of the trips step).
public struct AnalysisWorkload: Sendable, Hashable, Codable {
    /// Photos in the part of the library the run works on.
    public var photos: Int
    /// Photos with a location (the places step counts these).
    public var located: Int
    /// Screenshots and screen recordings (the text step reads these).
    public var screenshots: Int
    /// Photos whose image contents are still to be looked at.
    public var contentLeft: Int
    /// Screenshots whose text is still to be read.
    public var textLeft: Int
    /// Photos with a location whose place is not resolved yet (the places step's work left;
    /// review of ee36188: counting every located photo made the time left far too long).
    /// `nil`: not known, all located photos count.
    public var placesLeft: Int?
    /// Of `contentLeft`: photos analysed already that get only their image labels, because
    /// "Themen" or "Dokumente" was turned on after they were analysed. Said apart so a run that
    /// goes on names this work for what it is (`ResumedRun.NewWork.newAreas`), not as new photos.
    public var labelsLeft: Int

    public init(photos: Int, located: Int, screenshots: Int, contentLeft: Int, textLeft: Int, placesLeft: Int? = nil,
                labelsLeft: Int = 0) {
        self.photos = photos
        self.located = located
        self.screenshots = screenshots
        self.contentLeft = contentLeft
        self.textLeft = textLeft
        self.placesLeft = placesLeft.map { min(located, max(0, $0)) }
        self.labelsLeft = min(max(0, contentLeft), max(0, labelsLeft))
    }

    /// All items of a step (for the widths: the counts are over the whole library too).
    public func items(_ step: AnalysisStep) -> Int {
        switch step {
        case .library, .trips, .proposals, .content: photos
        case .places: located
        case .text: screenshots
        }
    }

    /// Items still to do in a step that has not started yet (for the finish time).
    public func itemsLeft(_ step: AnalysisStep) -> Int {
        switch step {
        case .library, .trips, .proposals: photos
        case .places: placesLeft ?? located
        case .content: contentLeft
        case .text: textLeft
        }
    }

    /// Photos still to look at and screenshots still to read, from a run standing at `step`
    /// (`completed` of `total`): the work a marker keeps, to tell on return whether there is
    /// much more of it than when the run stopped (`ResumedRun`).
    public func heavyLeft(at step: AnalysisStep, completed: Int, total: Int) -> Int {
        let running = max(0, total - completed)
        switch step {
        case .library, .trips, .places: return contentLeft + textLeft
        case .content: return running + textLeft
        case .text: return running
        case .proposals: return 0
        }
    }
}

// MARK: Widths of the bar

/// The share of the bar each step gets: its usual time with this library's amounts, fixed
/// for the whole analysis (stored with the marker, so a restart keeps them: S6). Without
/// amounts the fixed 5, 3, 12, 60, 12, 8 %.
public struct StepWidths: Sendable, Hashable, Codable {
    public private(set) var shares: [Double]

    public static let standard = StepWidths(validShares: [0.05, 0.03, 0.12, 0.60, 0.12, 0.08])
    /// Every step stays visible as a segment of its own.
    public static let minimumShare = 0.02

    private init(validShares: [Double]) { shares = validShares }

    /// From stored shares; anything that does not fit six positive shares gives the standard.
    public init(shares: [Double]) {
        guard shares.count == AnalysisStep.count, shares.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            self = .standard
            return
        }
        let sum = shares.reduce(0, +)
        self.shares = shares.map { $0 / sum }
    }

    public init(workload: AnalysisWorkload) {
        let seconds = AnalysisStep.allCases.map { step in
            Double(workload.items(step)) * step.secondsPerItem + step.fixedSeconds
        }
        let total = seconds.reduce(0, +)
        guard total > 0 else {
            self = .standard
            return
        }
        // Raised to the minimum, the rest scaled down so the sum stays 1.
        var shares = seconds.map { $0 / total }
        let small = shares.indices.filter { shares[$0] < Self.minimumShare }
        let raised = Double(small.count) * Self.minimumShare
        let restSum = shares.indices.filter { !small.contains($0) }.map { shares[$0] }.reduce(0, +)
        for i in shares.indices {
            shares[i] = small.contains(i) ? Self.minimumShare : shares[i] / restSum * (1 - raised)
        }
        self.init(shares: shares)
    }

    public func width(of step: AnalysisStep) -> Double { shares[step.rawValue] }
    public func start(of step: AnalysisStep) -> Double { shares.prefix(step.rawValue).reduce(0, +) }
    public func end(of step: AnalysisStep) -> Double { start(of: step) + width(of: step) }

    /// The bar for the whole analysis (0…1): never from the start again when a step begins.
    public func overall(step: AnalysisStep, completed: Int, total: Int) -> Double {
        let within = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0
        return min(1, start(of: step) + width(of: step) * within)
    }

    /// A run that goes on with an earlier analysis is back at its step (`step`, `completed` of
    /// `total`), but these widths put it below `held`, the value the card showed when the
    /// earlier run stopped: photos came in since, or the database was rebuilt. Stress run
    /// 43833158673 (50,000 photos added): the card held "64 %" while catching up, then fell to
    /// "38 %" when the image step began, and the bar stood still until the real value passed
    /// 64 % again. The new widths start the running step's rest exactly at `held` and spread
    /// the rest of the way (the running step's rest and the steps after it) over the rest of
    /// the bar, in their old proportions; the steps before shrink or grow to fill the start.
    /// So the number never goes back and moves on with the real work. `nil`: nothing to
    /// change (the real value is not below `held`).
    public func continuing(held: Double, step: AnalysisStep, completed: Int, total: Int) -> StepWidths? {
        let base = overall(step: step, completed: completed, total: total)
        guard held.isFinite, held < 1, base < held - 1e-9 else { return nil }
        // base…1 is drawn over held…1.
        let k = (1 - held) / (1 - base)
        let stepStart = start(of: step)
        let newStepStart = held - (base - stepStart) * k
        guard newStepStart > 0, stepStart > 0 else { return nil }
        let j = newStepStart / stepStart
        let scaled = AnalysisStep.allCases.map { s in s < step ? width(of: s) * j : width(of: s) * k }
        return StepWidths(shares: scaled)
    }

    /// How far each segment is filled for a value of the bar (0…1 per step).
    public func fills(for overall: Double) -> [Double] {
        AnalysisStep.allCases.map { step in
            let w = width(of: step)
            return w > 0 ? min(1, max(0, (overall - start(of: step)) / w)) : 0
        }
    }
}

// MARK: Finish time

/// What the card says about the end: a clock time, or "Gleich fertig".
public enum FinishEstimate: Sendable, Equatable {
    case soon
    case at(Date)

    /// How the date is said: today "Fertig gegen 23:40", tomorrow "Fertig morgen gegen 7:10",
    /// later in the week with the weekday, beyond that with the date.
    public enum Day: Sendable, Equatable { case today, tomorrow, weekday, date }

    public static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .tomorrow
        case 2...6: return .weekday
        default: return .date
        }
    }
}

/// Measures the speed of the analysis and says when it will be done (point 1).
///
/// - The running step: items per second of active time in its last 60 s.
/// - Steps not started yet: their items times the usual time per item, scaled by how fast this
///   device was on the image and text steps measured so far (factor 1 before either was).
/// - Trustworthy only after 30 s and 20 items in the running step; after any time without
///   progress (waiting, Pause, background without the task, a gap of more than 5 s) it settles
///   again from there, and no time is shown meanwhile.
/// - Checked at most every 15 s; a shown time moves only when the new one differs by 2 min or
///   more. More than 30 min ahead it is rounded to 5 min, else to the minute; less than a
///   minute ahead it says "Gleich fertig".
///
/// Times are `ContinuousClock` instants handed in by the caller (tests pass their own), the
/// finish is a wall-clock `Date` handed in with them.
public struct ProgressEstimator: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public struct Rules: Sendable {
        public var minActive: Duration = .seconds(30)
        public var minItems = 20
        public var window: Duration = .seconds(60)
        public var maxGap: Duration = .seconds(5)
        public var refresh: Duration = .seconds(15)
        public var hysteresis: TimeInterval = 120
        public var roundAbove: TimeInterval = 30 * 60
        public var roundTo: TimeInterval = 5 * 60
        public var soon: TimeInterval = 60
        public init() {}
    }

    struct Sample: Sendable {
        var active: Duration
        var completed: Int
    }

    struct Running: Sendable {
        var step: AnalysisStep
        var completed: Int
        var total: Int
        /// When the last progress came; `nil` after a time without progress (settles again).
        var lastAt: Instant?
        var active: Duration = .zero
        var samples: [Sample] = []
        /// Where the measuring (re)started: 30 s and 20 items from here make it trustworthy.
        var settledFrom = Sample(active: .zero, completed: 0)
        /// Everything measured in this step, for its average speed once it is done.
        var measuredItems = 0
        var measuredActive: Duration = .zero
        var waitingForApple = false
    }

    public let rules: Rules
    private(set) var running: Running?
    /// Measured steps: items and active seconds.
    private(set) var measured: [AnalysisStep: (items: Int, seconds: Double)] = [:]
    public private(set) var workload: AnalysisWorkload?
    /// The finish time last accepted (unrounded) and when it was last checked.
    private var accepted: Date?
    private var lastCheck: Instant?

    public init(rules: Rules = Rules()) { self.rules = rules }

    public mutating func setWorkload(_ workload: AnalysisWorkload) { self.workload = workload }

    /// A progress report of the run. `appleWait`: the report says the run waits for Apple's
    /// geocoder (`Progress.waitLeft`). Since 18.11. (device test, build 36) only the overnight
    /// refinement waits; a run in the app never does, so its finish time never sees one. That
    /// time says nothing about the speed per item (the limit is Apple's, and after its online
    /// budget the step resolves the rest offline in seconds): it is not measured, and the speed
    /// settles again afterwards, but a time already shown stays (the card shows the wait's
    /// countdown meanwhile, not the time). Measured in the simulated run with a refusing
    /// geocoder: counted, the waits put the finish time more than 5 min too late.
    public mutating func record(step: AnalysisStep, completed: Int, total: Int, at now: Instant, appleWait: Bool = false) {
        guard var r = running, r.step == step else {
            if let r = running { keepMeasured(r) }
            running = Running(step: step, completed: completed, total: total, lastAt: now,
                              samples: [Sample(active: .zero, completed: completed)],
                              settledFrom: Sample(active: .zero, completed: completed))
            return
        }
        defer { running = r }
        let previous = r.completed
        r.completed = max(r.completed, completed)
        r.total = total
        if appleWait {
            r.waitingForApple = true
            return
        }
        if r.waitingForApple {
            r.waitingForApple = false
            r.lastAt = now
            r.samples = [Sample(active: r.active, completed: r.completed)]
            r.settledFrom = Sample(active: r.active, completed: r.completed)
            return
        }
        guard let last = r.lastAt else {
            settle(&r, at: now)
            return
        }
        let gap = now - last
        if gap > rules.maxGap || gap < .zero {
            // Nothing came for a while (suspended in the background, a long wait): that time
            // is not counted, and the speed is measured anew from here.
            settle(&r, at: now)
            return
        }
        r.lastAt = now
        r.active += gap
        r.measuredActive += gap
        r.measuredItems += max(0, r.completed - previous)
        r.samples.append(Sample(active: r.active, completed: r.completed))
        // Keeps one sample at or before the start of the window.
        let windowStart = r.active - rules.window
        if let firstInside = r.samples.firstIndex(where: { $0.active >= windowStart }), firstInside > 1 {
            r.samples.removeFirst(firstInside - 1)
        }
    }

    /// The run waits (heat, battery), is paused, or is in the background without iOS running
    /// it: no time is shown, and the measuring settles again when progress comes.
    public mutating func idle() {
        running?.lastAt = nil
        accepted = nil
        lastCheck = nil
    }

    /// Forgets everything (a new run).
    public mutating func reset() { self = ProgressEstimator(rules: rules) }

    private mutating func settle(_ r: inout Running, at now: Instant) {
        r.lastAt = now
        r.samples = [Sample(active: r.active, completed: r.completed)]
        r.settledFrom = Sample(active: r.active, completed: r.completed)
        accepted = nil
        lastCheck = nil
    }

    private mutating func keepMeasured(_ r: Running) {
        guard r.measuredItems > 0, r.measuredActive > .zero else { return }
        let before = measured[r.step] ?? (0, 0)
        measured[r.step] = (before.items + r.measuredItems, before.seconds + r.measuredActive.seconds)
    }

    /// Items per second of the running step, once trustworthy.
    public var rate: Double? {
        guard let r = running, r.lastAt != nil, !r.waitingForApple, r.total > 1 else { return nil }
        guard r.active - r.settledFrom.active >= rules.minActive,
              r.completed - r.settledFrom.completed >= rules.minItems,
              let first = r.samples.first, let last = r.samples.last else { return nil }
        let seconds = (last.active - first.active).seconds
        let items = last.completed - first.completed
        guard seconds > 0, items > 0 else { return nil }
        return Double(items) / seconds
    }

    /// How much slower (> 1) or faster (< 1) this device is than the usual times, from the
    /// image and text steps measured so far.
    public var deviceFactor: Double {
        var items: [AnalysisStep: (Int, Double)] = measured.mapValues { ($0.items, $0.seconds) }
        if let r = running, r.measuredItems >= rules.minItems, r.measuredActive >= rules.minActive {
            let before = items[r.step] ?? (0, 0)
            items[r.step] = (before.0 + r.measuredItems, before.1 + r.measuredActive.seconds)
        }
        var usual = 0.0, real = 0.0
        for (step, value) in items where step.measuresDevice {
            usual += Double(value.0) * step.secondsPerItem
            real += value.1
        }
        guard usual > 0, real > 0 else { return 1 }
        return min(4, max(0.25, real / usual))
    }

    /// Time left in the running step, once trustworthy (Details: "noch etwa 12 Min.").
    public var stepRemaining: Duration? {
        guard let r = running, let rate else { return nil }
        return .seconds(Double(max(0, r.total - r.completed)) / rate)
    }

    /// This device's speed is measured (an image or text step ran long enough), or no work
    /// is left whose time depends on it. Before that a whole-analysis time would rest on the
    /// usual times only, which are a guess for this device (review I4).
    public var deviceKnown: Bool {
        if measured.keys.contains(where: \.measuresDevice) { return true }
        if let r = running, r.step.measuresDevice, rate != nil { return true }
        guard let r = running, let workload else { return false }
        return !AnalysisStep.allCases.contains { $0 > r.step && $0.measuresDevice && workload.itemsLeft($0) > 0 }
    }

    /// Time left for the whole analysis, once trustworthy: the running step measured, and the
    /// device measured (`deviceKnown`).
    public var remaining: Duration? {
        guard let r = running, let step = stepRemaining, let workload, deviceKnown else { return nil }
        let factor = deviceFactor
        let later = AnalysisStep.allCases.filter { $0 > r.step }.reduce(0.0) { sum, s in
            sum + (Double(workload.itemsLeft(s)) * s.secondsPerItem + s.fixedSeconds) * (s.measuresDevice ? factor : 1)
        }
        return step + .seconds(later)
    }

    /// Time left for the whole analysis by the best estimate there is now, also before it is
    /// trustworthy: the running step at its measured speed (else the usual time per item), the
    /// steps after it at the usual times, scaled by this device's speed as far as measured.
    /// For the time share of a run that goes on (`ResumedRun.spend`), never shown as a time.
    /// `nil` before the workload is known.
    public var estimatedRemaining: Duration? {
        guard let r = running, let workload else { return nil }
        let factor = deviceFactor
        let left = Double(max(0, r.total - r.completed))
        let current = rate.map { left / $0 } ?? left * r.step.secondsPerItem * (r.step.measuresDevice ? factor : 1)
        let later = AnalysisStep.allCases.filter { $0 > r.step }.reduce(0.0) { sum, s in
            sum + (Double(workload.itemsLeft(s)) * s.secondsPerItem + s.fixedSeconds) * (s.measuresDevice ? factor : 1)
        }
        return .seconds(current + later)
    }

    /// The finish time to show now, or `nil` while there is none to trust.
    public mutating func finish(at now: Instant, wall: Date) -> FinishEstimate? {
        guard let r = running, r.lastAt != nil else { return nil }
        // The time shown has passed and the run goes on: a new one at once, without waiting
        // for the refresh or the hysteresis (review minor: "Gleich fertig" stayed for up to
        // 2 min after the end time).
        let passed = accepted.map { $0 <= wall } ?? false
        // Steps without a count (trips, suggestions) are short: the time shown stays.
        if r.total > 1, passed || (lastCheck.map({ now - $0 >= rules.refresh }) ?? true) {
            if let remaining {
                lastCheck = now
                let candidate = wall.addingTimeInterval(remaining.seconds)
                if passed || (accepted.map({ abs(candidate.timeIntervalSince($0)) >= rules.hysteresis }) ?? true) {
                    accepted = candidate
                }
            }
        }
        guard let accepted else { return nil }
        // No new time to show: "Gleich fertig" for at most a minute past the time, then none.
        if wall.timeIntervalSince(accepted) > rules.soon { return nil }
        return Self.display(accepted, wall: wall, rules: rules)
    }

    /// The wall clock jumped (set by hand, another time zone does not count: a `Date` stays
    /// the same instant): it moved more than `tolerance` apart from the time that really
    /// passed. `significantTimeChangeNotification` also comes at midnight and when the
    /// carrier corrects the time by a little (re-review a); then the time shown stays.
    public static func clockJumped(wallThen: Date, wallNow: Date, elapsed: Duration,
                                   tolerance: TimeInterval = 60) -> Bool {
        abs(wallNow.timeIntervalSince(wallThen) - elapsed.seconds) > tolerance
    }

    static func display(_ finish: Date, wall: Date, rules: Rules) -> FinishEstimate {
        let left = finish.timeIntervalSince(wall)
        if left < rules.soon { return .soon }
        let step = left > rules.roundAbove ? rules.roundTo : 60
        let rounded = (finish.timeIntervalSinceReferenceDate / step).rounded() * step
        return .at(Date(timeIntervalSinceReferenceDate: rounded))
    }
}

fileprivate extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

// MARK: Gliding bar

/// The bar between two real reports (point 2): it moves on at the measured speed instead of
/// standing and jumping, but never goes back and never gets more than 1 % of the running step
/// ahead of the last real value (nor past the step's end). When the real value is ahead, the
/// value jumps to it and the view eases there.
public struct BarGlide: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant
    public static let maxLead = 0.01

    public private(set) var real = 0.0
    public private(set) var shown = 0.0
    private var realAt: Instant?
    /// Bar units per second.
    private var speed: Double?
    private var cap = 0.0

    public init() {}

    /// A real value. `itemsPerSecond`: the running step's measured speed (`nil`: not known,
    /// no gliding); `total`: its items.
    public mutating func update(real value: Double, at now: Instant, step: AnalysisStep, widths: StepWidths,
                                itemsPerSecond: Double?, total: Int) {
        real = max(real, value)
        realAt = now
        let width = widths.width(of: step)
        // Never past 99 % before the end (`AnalysisPercent`).
        cap = min(real + Self.maxLead * width, widths.end(of: step), AnalysisPercent.cap)
        if let itemsPerSecond, total > 0 {
            speed = width * itemsPerSecond / Double(total)
        } else {
            speed = nil
        }
        shown = max(shown, min(real, AnalysisPercent.cap))
    }

    /// The value to draw now. `gliding` is off while the run waits or is paused, with
    /// Reduce Motion, and while the app is not active: then the real value only.
    public mutating func value(at now: Instant, gliding: Bool) -> Double {
        guard gliding, let speed, let realAt else {
            shown = max(shown, min(real, AnalysisPercent.cap))
            return shown
        }
        let elapsed = max(0, (now - realAt).seconds)
        shown = max(shown, min(real + speed * elapsed, cap))
        return shown
    }

    /// A new run, or new widths for the run (review I3: the glide held the bar at the old
    /// widths' value, so it stood still until the real value under the new widths caught up).
    public mutating func reset() { self = BarGlide() }

    /// A run that goes on with the same analysis: starts from the value drawn last, so the
    /// bar does not lose the lead it had glided (review minor: up to 1 % of a step back).
    public mutating func reset(keeping drawn: Double) {
        self = BarGlide()
        shown = min(drawn, AnalysisPercent.cap)
    }
}

// MARK: Never 100 % before the end

/// The number the card, VoiceOver, the details and the Lock Screen show: 100 % only once the
/// analysis is complete, 99 % at most before (review of 83db832: "Analyse zu 100 % fertig"
/// with hours of work left).
public enum AnalysisPercent {
    public static let cap = 0.99

    public static func value(_ value: Double, isComplete: Bool) -> Double {
        if isComplete { return 1 }
        return value.isFinite ? min(cap, max(0, value)) : 0
    }

    public static func percent(_ value: Double, isComplete: Bool) -> Int {
        Int((Self.value(value, isComplete: isComplete) * 100).rounded())
    }
}

// MARK: A run that goes on

/// A run that goes on from where an earlier one stopped (the marker kept across launches):
/// what the card shows. Pure, so the Linux tests cover what `AppModel` does.
///
/// Two ways a run goes on (reviews of 83db832, 11ef3e1 and 0305d20):
/// - **From the floor**: the value never goes below what the card showed when the run before
///   stopped (the floor). From there it moves with the time the run works, as a share of the
///   time left by the best estimate (`spend`), so the number and the bar move also while the
///   run re-counts what was done before or works on new photos before the step it stopped
///   in; the real value takes over once it is ahead. Nothing is re-spread, so the work done
///   before the stop is never counted again and no segment of the bar goes back.
/// - **A phase of its own**: the work left is much larger than when it stopped
///   (`isMuchMore`: more than 1.5 times and at least 500 photos more, as the workload counts
///   them, in the run's part of the library and only what the analysis looks at), or there
///   is new work and, near the cap, the number could only move slower than the visible pace
///   from where it stands to 99 % (`movesTooSlowly`, reviews of c772325 and ee36188). The floor does not hold: the run
///   shows its own honest value from its own start, under a label that says why ("Neue Fotos
///   werden analysiert", "Analyse nach Update"). The label and the phase's own number come
///   together, with the workload; within the phase the number never goes back. A phase that
///   goes on later keeps its value under its label; it starts again only when the number
///   could not move visibly, and then under another title ("Weitere neue Fotos werden
///   analysiert").
///
/// Whether the floor belongs to this database at all is decided before (`markerApplies`).
public struct ResumedRun: Sendable, Equatable {
    /// Why a run has a phase of its own.
    public enum NewWork: String, Sendable, Codable, Equatable {
        /// Photos came in since ("Neue Fotos werden analysiert").
        case newPhotos
        /// The app's analysis changed with an update and asks for the photos again
        /// ("Analyse nach Update").
        case afterUpdate
        /// More photos came in during a phase "Neue Fotos werden analysiert", and its number
        /// could no longer move visibly ("Weitere neue Fotos werden analysiert", review of
        /// c772325: a second phase never starts again under the title already shown).
        case moreNewPhotos
        /// The app's analysis changed again during a phase "Analyse nach Update" whose number
        /// could no longer move visibly ("Analyse nach erneutem Update", review of ee36188).
        case afterUpdateAgain
        /// "Themen" or "Dokumente" was turned on since: photos analysed before get the image
        /// labels these areas need ("Fotos werden für die neuen Bereiche angesehen"; review of
        /// the labels fix, M2: this work was called "Neue Fotos werden analysiert", or "Weitere
        /// neue Fotos werden analysiert" in a run that already showed that phase).
        case newAreas
    }

    /// "Much more work": more than this times the work left when the run stopped …
    public static let muchMoreFactor = 1.5
    /// … and at least this many photos more.
    public static let muchMoreAtLeast = 500
    /// The slowest pace the card still visibly moves at: 0.25 % per 10 s, a little above the
    /// 0.2 % of the bar (about 0.7 pt on a 340 pt wide bar) that counts as a move (review of
    /// c772325). A run with new work whose number could only move slower than this from where
    /// it stands to 99 % by the time left starts a phase of its own (`workload`); a run that
    /// re-reads what the runs before it already re-read moves no faster (`spend`).
    public static let visiblePace = 0.0025 / 10
    /// The pace rule applies only near the cap: with at most this much room above the value
    /// shown (5 points). Further down, a long run's honest pace is often below the visible
    /// one (50,000 photos at 37 %: 0.62 over 4,900 s, 0.13 % per 10 s); it goes on from its
    /// value by its time share, at the honest pace of the work, with the count moving (review
    /// of ee36188: one new photo made "Neue Fotos werden analysiert" and 37 % -> 4 %).
    public static let nearCapRoom = 0.05

    /// Pipeline stage number (1…7) the earlier run stopped in.
    public let stage: Int
    /// The count it stopped at in that stage (`nil` in older markers: then the run is back
    /// when it reaches the stage).
    public let stoppedCompleted: Int?
    /// What the card showed when it stopped.
    public let floor: Double
    /// Photos still to look at and screenshots still to read when it stopped
    /// (`AnalysisWorkload.heavyLeft`); `nil` in older markers and before the workload was known.
    public let leftThen: Int?
    /// Photos in the library when it stopped (the library read's total; kept for the logs).
    public let photosThen: Int?
    /// The usual time left when it stopped (`ProgressEstimator.estimatedRemaining`), for the
    /// time share before this run knows its own workload. Older markers carry none: then the
    /// work left then at the usual times, or, without that either, the library's photos once
    /// the library read counted them (`library(photos:)`, review of c772325: the number moves
    /// within 10 s after the update).
    public private(set) var secondsThen: Double?
    /// Active time the runs before this one spent re-reading (before they knew their workload)
    /// while they held the value, the longest of them; they were cut off before they got past
    /// where the run stopped. This run re-reads the same: until it has worked as long, the value
    /// moves at the visible pace at most (review of c772325: ten cut-offs of 40 s while
    /// re-reading moved 37 % to 57 % with nothing done).
    public let caughtUpBefore: Double
    /// The same for this run: the longest re-read so far, including this run's (kept in the
    /// marker while the run holds).
    public private(set) var caughtUp: Double

    /// The app's analysis changed since (`AnalysisPipeline.analysisVersion`).
    public let updated: Bool
    /// The label shown (the phase's, or one shown early by the library read).
    public private(set) var newWork: NewWork?
    /// This run started a phase of its own: the floor no longer holds.
    public private(set) var ownStart = false
    /// The run passed the position it stopped at (decided once): from here on the marker
    /// keeps this run's own position, and the card no longer says "Macht da weiter".
    public private(set) var isBack = false
    /// The value moved on by the time this run has worked (`spend`), never lower than before.
    public private(set) var spread: Double
    /// The time worked at the last `spend`.
    private var spent = 0.0

    public init(stage: Int, completed: Int? = nil, shown: Double, left: Int? = nil, photos: Int? = nil,
                seconds: Double? = nil, updated: Bool = false, newWork: NewWork? = nil, caughtUp: Double? = nil) {
        self.stage = stage
        self.stoppedCompleted = completed
        self.floor = shown.isFinite ? min(1, max(0, shown)) : 0
        self.leftThen = left
        self.photosThen = photos
        self.secondsThen = seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            ?? left.map { Self.usualSeconds(left: $0, stage: stage) }
        self.spread = self.floor
        self.updated = updated
        self.newWork = newWork
        let before = caughtUp.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        self.caughtUpBefore = before
        self.caughtUp = before
    }

    /// The usual time for `left` photos and screenshots still to look at, from a run that
    /// stopped in `stage`, at each step's usual rate (review of ee36188, 4): in the text step
    /// they are screenshots (0.5 s each); before it, photos for the image step (0.1 s each)
    /// plus the texts after it, at the usual ratio of the two steps (the standard widths:
    /// 12 % text to 60 % image, so another fifth). Then the suggestions' fixed time.
    static func usualSeconds(left: Int, stage: Int) -> Double {
        let n = Double(max(0, left))
        let standard = StepWidths.standard
        let fixed = AnalysisStep.proposals.fixedSeconds
        let text = AnalysisPipeline.Stage.text.number
        switch stage {
        case text:
            return n * AnalysisStep.text.secondsPerItem + fixed
        case (text + 1)...:
            return fixed
        default:
            return n * AnalysisStep.content.secondsPerItem * (1 + standard.width(of: .text) / standard.width(of: .content)) + fixed
        }
    }

    /// The library read counted the library's `photos`: a marker of an older version without
    /// the time nor the work left then gets the usual time for the photos not yet behind the
    /// value shown (review of c772325, 4: such a marker held the number until the workload).
    /// The usual time of a whole analysis comes from the image step's rate and its usual
    /// share of the time (the standard widths: 60 %), so every step counts at its own rate.
    public mutating func library(photos: Int) {
        guard secondsThen == nil, photos > 0 else { return }
        let whole = Double(photos) * AnalysisStep.content.secondsPerItem / StepWidths.standard.width(of: .content)
        secondsThen = whole * max(0.01, 1 - floor) + AnalysisStep.proposals.fixedSeconds
    }

    /// The run has worked `active` seconds since it went on, and `remaining` seconds are left
    /// by the best estimate now (`ProgressEstimator.estimatedRemaining`; before the workload is
    /// known, the time left when the run before stopped). The value moves from the floor
    /// towards 99 % by the share of the time left that was worked since the last call:
    /// gap x worked / (worked + remaining). With a right estimate it reaches 99 % when the
    /// work is done, evenly; a larger estimate only slows it down, it never stops nor goes
    /// back. So the number and the bar move while the run re-counts what was done or works
    /// on new photos before the step it stopped in (review of 0305d20: 58 s at the floor with
    /// 450 new photos; deleted photos held it until the count was back). Re-counting is
    /// quick next to the work left, so back where it stopped the value is barely above the
    /// floor (no 56 % -> 78 %).
    ///
    /// Before the workload (`remaining == nil`) the run re-reads the library: while it has not
    /// worked longer than the runs before it already re-read (`caughtUpBefore`), it moves at
    /// the visible pace at most. So repeated cut-offs while re-reading add one run's time
    /// share and then only the slowest visible movement: n cut-offs of a seconds each move the
    /// value at most by the time share of one run of a seconds plus (n - 1) x a x
    /// `visiblePace` (37 % with 1,000 s left, ten cut-offs of 40 s: 39.4 % plus 9 x 0.1 %,
    /// below 48.5 %, instead of 57 %). The value is never written back lower (it would fall
    /// on the next start).
    public mutating func spend(active: Double, remaining: Double?) {
        guard !ownStart, active.isFinite, active > spent else { return }
        let worked = active - spent
        let from = spent
        spent = active
        if remaining == nil { caughtUp = max(caughtUp, active) }
        guard let left = remaining ?? secondsThen, left.isFinite else { return }
        var step = (AnalysisPercent.cap - spread) * worked / (worked + max(0, left))
        let again = remaining == nil ? max(0, min(active, caughtUpBefore) - from) : 0
        if again > 0 {
            // The part of this stretch that re-reads what a run before already re-read.
            let share = again / worked
            step = step * (1 - share) + min(step * share, Self.visiblePace * again)
        }
        spread = min(AnalysisPercent.cap, spread + max(0, step))
    }

    /// A marker belongs to the database it was written for. Markers of older versions carry no
    /// stamp: they count only for a database that has photos already (not for a new one, nor
    /// for one restored empty on a new iPhone).
    public static func markerApplies(markerDatabase: String?, database: String, databaseHasPhotos: Bool) -> Bool {
        guard let markerDatabase else { return databaseHasPhotos }
        return markerDatabase == database
    }

    /// Much more work than when the run stopped.
    public static func isMuchMore(_ now: Int, than then: Int) -> Bool {
        Double(now) > Double(then) * muchMoreFactor && now - then >= muchMoreAtLeast
    }

    /// Near the cap (`nearCapRoom`), the number could only move slower than the visible pace
    /// from `value` to 99 % in the `remaining` seconds: the room is the reason it would stand
    /// still (review of c772325: stopped at the end of the text step, 450 new photos, 98-99 %
    /// for 85 s). Further down the honest pace decides, not the room (review of ee36188).
    public static func movesTooSlowly(from value: Double, remaining: Double) -> Bool {
        guard remaining.isFinite, remaining > 0 else { return false }
        let room = AnalysisPercent.cap - value
        return room <= nearCapRoom + 1e-9 && room / remaining < visiblePace
    }

    /// The report (`current` stage, `completed` of `total`) is at or past where the run
    /// stopped: a later stage, or the same stage at the same count or further (or its end).
    public func hasPassed(at current: Int, completed: Int, total: Int) -> Bool {
        if current != stage { return current > stage }
        guard let stoppedCompleted else { return true }
        return completed >= stoppedCompleted || (total > 0 && completed >= total)
    }

    /// The value is held at the floor (running, no phase of its own, not past the stop).
    public func holds(running: Bool) -> Bool {
        running && !ownStart && !isBack
    }

    /// Still on the steps before the one it stopped in ("Gleich wieder bei Schritt n").
    public func isCatchingUp(running: Bool, at current: Int?) -> Bool {
        holds(running: running) && (current ?? 0) < stage
    }

    /// The workload (said once, after the trips step), with the time left by the estimate
    /// now (`remaining`). A phase of its own starts, "Analyse nach Update" when the app's
    /// analysis changed since, "Fotos werden für die neuen Bereiche angesehen" when the work
    /// added is mostly labels for areas turned on since (`addsMostlyLabels`), otherwise "Neue
    /// Fotos werden analysiert",
    /// - with much more work left than when the run stopped (`isMuchMore`), or
    /// - with more work than then, near the cap, when the number could only move slower than
    ///   the visible pace from where it stands to 99 % (`movesTooSlowly`, reviews of c772325
    ///   and ee36188), whatever the amount. An update that adds no work starts nothing.
    /// A run that already shows a phase's label goes on from its value under it: only the
    /// second rule starts a phase again, and only under another title ("Weitere neue Fotos
    /// werden analysiert", "Analyse nach erneutem Update"; review of c772325: never again under
    /// the title already shown), alternating with the first.
    /// The label appears only now, together with the phase's own number (review of 0305d20).
    /// The label only names the work: whether a phase starts, its number and its widths do not
    /// depend on it.
    /// `true`: the phase starts now.
    public mutating func workload(_ workload: AnalysisWorkload, remaining: Double? = nil) -> Bool {
        guard !ownStart, let leftThen else { return false }
        let work = workload.contentLeft + workload.textLeft
        let tooSlow = work > leftThen && remaining.map { Self.movesTooSlowly(from: spread, remaining: $0) } == true
        let cause: NewWork = updated ? .afterUpdate
            : addsMostlyLabels(workload, work: work, leftThen: leftThen) ? .newAreas : .newPhotos
        let label: NewWork
        if let shownLabel = newWork {
            guard tooSlow else { return false }
            switch (cause, shownLabel) {
            case (.afterUpdate, .afterUpdate): label = .afterUpdateAgain
            case (.afterUpdate, _): label = .afterUpdate
            // Never the title shown: after "neue Bereiche" the cause is never the labels again.
            case (.newAreas, _): label = .newAreas
            case (_, .newPhotos): label = .moreNewPhotos
            default: label = .newPhotos
            }
        } else {
            guard tooSlow || Self.isMuchMore(work, than: leftThen) else { return false }
            label = cause
        }
        newWork = label
        ownStart = true
        return true
    }

    /// The work added since the stop is mostly labels: "Themen" or "Dokumente" was turned on
    /// since, and the photos analysed before that get only their labels now
    /// (`AnalysisWorkload.labelsLeft`) are at least as many as the rest of what was added (new
    /// photos, screenshots to read). Not when the phase shown is about them already: their
    /// labels were part of the work left then, so what was added is something else.
    /// How many labels were left at the stop itself is not known (a run that stopped while
    /// catching up labels without a phase of its own): its labels count as added, and a phase
    /// that new photos started then may be named after the labels it also gives.
    func addsMostlyLabels(_ workload: AnalysisWorkload, work: Int, leftThen: Int) -> Bool {
        let labels = workload.labelsLeft
        guard labels > 0, newWork != .newAreas else { return false }
        return labels >= work - labels - leftThen
    }

    /// Every report of the run until it is back: `true` for the first one at or past the
    /// stopped position (`hasPassed`), once. Nothing is re-spread (review of 0305d20): the
    /// time share already moves the value, and the real value takes over once it is ahead,
    /// so the work done before the stop is never counted again and no segment goes back.
    @discardableResult
    public mutating func back(at current: Int, completed: Int, total: Int) -> Bool {
        guard !isBack, !ownStart, hasPassed(at: current, completed: completed, total: total) else { return false }
        isBack = true
        return true
    }

    /// The value the card shows (never 100 %: `AnalysisPercent`). `stopped`: where the run
    /// ended, when it is not running. Never below the floor moved on by the time share
    /// (`spread`); the real value once it is ahead. A run paused while catching up keeps its
    /// value (the paused card said "3 %" after "64 %", while the bar stayed at 64 %). In a
    /// phase of its own the real value. (`catchingUp` is no longer needed.)
    public func shown(running: Bool, catchingUp _: Bool, overall: Double, stopped: Double?) -> Double {
        let value: Double
        if ownStart {
            value = running ? overall : (stopped ?? overall)
        } else if running {
            value = max(spread, overall)
        } else if let stopped {
            value = max(stopped, spread)
        } else {
            value = spread
        }
        return AnalysisPercent.value(value, isComplete: false)
    }
}

/// Whether the analysis is complete, for the 100 % (`AnalysisPercent`): only the last run's
/// own outcome counts. A run that ended with an error has none, so the report of an earlier
/// complete run cannot make the details say "100 %" (review of 11ef3e1, minor 2).
public struct LastRunOutcome: Sendable, Equatable {
    public private(set) var completed = false
    public init() {}
    /// A run starts: nothing is complete until it says so.
    public mutating func started() { completed = false }
    /// A run ended with its report (`nil`: it threw or was cancelled).
    public mutating func ended(with report: AnalysisPipeline.Report?) { completed = report?.isComplete == true }
    /// A background refinement after the analysis (towns, new photos) ended: it can make the
    /// analysis complete, but one cut off by iOS does not make a complete analysis read 99 %
    /// (review of 0305d20, 5): the work done before is still done. `true`: this refinement
    /// made the analysis complete, so nothing is left to go on with: the marker of an earlier
    /// unfinished run and its resume are cleared (review of c772325, 6: the card read 100 %,
    /// then "Macht da weiter · 37 %").
    @discardableResult
    public mutating func refined(with report: AnalysisPipeline.Report?) -> Bool {
        guard report?.isComplete == true else { return false }
        completed = true
        return true
    }
    public func isComplete(running: Bool) -> Bool { !running && completed }
}

// MARK: Card state

/// The card's state (spec "SwiftUI": running, slower, waiting, pausing since, paused,
/// finished, quick check). `nil` from `resolve`: the plain card ("Alle 5.683 Fotos analysiert").
public enum AnalysisCardState: Sendable, Equatable {
    public enum Wait: Sendable, Equatable {
        /// "Wartet, bis dein iPhone abkühlt"
        case cooling
        /// "Wartet aufs Laden"
        case charging
        /// "Fotos antwortet gerade nicht": a call into Photos has had no answer for 10 s or
        /// more, or the run ended on one and goes on by itself a little later (app-speed,
        /// `PhotosDeadline`).
        case photos
        /// "Albumist war gerade ausgelastet": the run ended because a call into Photos never
        /// got a thread (Albumist's own work kept them all busy; Photos was not asked), and it
        /// goes on by itself a little later (review of f7439fb, MF1).
        case busy
    }

    public struct Position: Sendable, Equatable {
        public var step: AnalysisStep
        public var completed: Int
        public var total: Int
        public init(step: AnalysisStep, completed: Int, total: Int) {
            self.step = step
            self.completed = completed
            self.total = total
        }
        /// A count to show ("2.431 von 5.683 Fotos"); steps without one show only their name.
        public var hasCount: Bool { total > 1 && step.unit != .none }
    }

    case quickCheck(showsPause: Bool)
    /// `catchingUp`: a run that goes on from step n is still on the quick steps before it.
    case running(Position?, slower: SlowReason?, appleWait: Bool, catchingUp: Int?)
    case waiting(Wait, Position?)
    /// Pause was tapped; `longer` after 10 s ("Dauert noch einen Moment.").
    case pausing(Position?, longer: Bool)
    case paused(Position?)
    case finished(photos: Int, proposals: Int)

    public struct Inputs: Sendable {
        public var isRunning = false
        /// A check for new photos after everything was analysed once, with little to do.
        public var isQuickCheck = false
        public var runningFor: Duration = .zero
        public var position: Position?
        /// A run that goes on is still on the steps before the one it stopped in
        /// (`ResumedRun.isCatchingUp`): that step's number ("Gleich wieder bei Schritt 4 von 6")
        /// and where in it the run stopped (`catchingUp(stage:completed:total:)`).
        public var catchingUpTo: Int?
        public var catchingUpAt: Position?
        public var waiting: PauseReason?
        public var slower: SlowReason?
        /// The places step waits for Apple's geocoder (the overnight refinement only): the card
        /// shows the wait's countdown instead of the finish time.
        public var appleWait = false
        /// Photos has not answered for a while (`PhotosDeadline.slowFor`), or the last run ended
        /// on it and the next try is due (`AppModel`): said instead of a count standing still.
        public var photosNotResponding = false
        /// The last run ended because a call into Photos never got a thread (`UnattendedRetry
        /// .Cause.busy`), and the next try is due.
        public var albumistBusy = false
        /// Pause was tapped this long ago (the run is finishing the photos in work).
        public var pausingFor: Duration?
        /// The last run ended because the user paused it, at this position.
        public var pausedByUser = false
        public var pausedAt: Position?
        /// A long run just finished while the app was open.
        public var finished: (photos: Int, proposals: Int)?
        public init() {}

        /// The run goes on from pipeline `stage` (1…7), where the run before stopped at
        /// `completed` of `total` (`AnalysisMarker`; `nil` in markers of older versions: no count).
        public mutating func catchingUp(stage: Int, completed: Int?, total: Int?) {
            let stages = AnalysisPipeline.Stage.allCases
            guard stages.indices.contains(stage - 1) else { return }
            let step = AnalysisStep(stages[stage - 1])
            catchingUpTo = step.number
            catchingUpAt = Position(step: step, completed: completed ?? 0, total: completed == nil ? 0 : total ?? 0)
        }
    }

    public static let pauseShownAfter: Duration = .seconds(5)

    /// How often the overview looks again for the early suggestions during the image step
    /// while none are shown: 10 s for each full 5,000 photos, at least 10 s (5,683 photos:
    /// 10 s; 50,000: 100 s). Each look derives the status of every photo (review of d612bc0:
    /// every 10 s with 50,000 photos).
    public static func earlyLookInterval(photos: Int) -> Duration {
        .seconds(10 * max(1, photos / 5_000))
    }
    public static let pausingLongerAfter: Duration = .seconds(10)

    public static func resolve(_ i: Inputs) -> AnalysisCardState? {
        if i.isRunning {
            if let pausing = i.pausingFor {
                return .pausing(i.position, longer: pausing >= pausingLongerAfter)
            }
            // Before the quick check too: a check that waits for Photos says so.
            if i.photosNotResponding { return .waiting(.photos, i.position) }
            if i.isQuickCheck { return .quickCheck(showsPause: i.runningFor >= pauseShownAfter) }
            switch i.waiting {
            case .thermal?: return .waiting(.cooling, i.position)
            case .batteryLow?: return .waiting(.charging, i.position)
            default: break
            }
            // Catching up, the card names the step it goes back to: its count is where the run
            // stopped there, not the count of the step it re-reads ("246 von 246 Fotos" from the
            // library read beside "Gleich wieder bei Schritt 4", then "36 von 246": TestFlight
            // run 44461253154, DeviceConditionUITests.test06).
            let shown = i.catchingUpTo != nil ? i.catchingUpAt : i.position
            return .running(shown, slower: i.slower, appleWait: i.appleWait, catchingUp: i.catchingUpTo)
        }
        if i.pausedByUser { return .paused(i.pausedAt) }
        // The run ended because Photos did not answer; the next try comes by itself. Never
        // "fertig" meanwhile.
        if i.photosNotResponding { return .waiting(.photos, i.pausedAt) }
        // The run ended because Albumist's own work kept every thread busy; the next try comes
        // by itself. Said, never the card of an earlier finished run (review of f7439fb, MF1).
        if i.albumistBusy { return .waiting(.busy, i.pausedAt) }
        if let finished = i.finished { return .finished(photos: finished.photos, proposals: finished.proposals) }
        return nil
    }

    /// The finish moment (point 4: check mark, light haptic, "Analyse fertig" card, or the
    /// notification when the app is not open): only for a run that really finished (not paused,
    /// stopped, failed or cut off by Vision errors), was not a quick check, and ran long enough
    /// that someone waited for it.
    public static let finishMomentAfter: Duration = .seconds(30)

    public static func celebratesFinish(isComplete: Bool, wasQuickCheck: Bool, ranFor: Duration) -> Bool {
        isComplete && !wasQuickCheck && ranFor >= finishMomentAfter
    }

    /// Fill in accent, or grey only while paused (M5).
    public var isGrey: Bool { if case .paused = self { true } else { false } }
    /// Motion (the light sweep, the gliding bar) only while really working (rule 4); not
    /// while Apple's geocoder is waited for (review minor: the sweep ran during that wait).
    public var isWorking: Bool { if case .running(_, _, let appleWait, _) = self { !appleWait } else { false } }
}

/// The "Analyse fertig" moment (point 4) of runs in the app (`AppModel`): owed by the run that
/// finished the analysis until it was seen.
///
/// Before, a short run that slipped in right after the run that finished took it away: the end
/// of the finished run waits for the overview, saw the newer run there
/// (`AnalysisRunEnd.afterWait(isNewest: false)`) and said nothing; the newer run (a trip change,
/// "Neu prüfen", photos added meanwhile) was a quick check, which never celebrates
/// (`AnalysisCardState.celebratesFinish`); and each start cleared a finish card that had not been
/// seen yet (shown while the app was in the background). Now:
/// - the end of a run says what it owes before it waits (`runEnded`), so a run that starts during
///   the wait cannot drop it;
/// - the moment comes at the end of the newest run that ends finished (`afterWait`), whichever
///   run owed it; never while work is left (paused, a change left, an error);
/// - a start hides the finish card for its own card, the moment stays owed until the card was on
///   screen (`claim`); the notification outside the app is sent once.
public struct FinishMoment: Sendable, Equatable {
    /// What the end of a run shows: the finish card, and outside the app the notification.
    public struct Shown: Sendable, Equatable {
        public var card: Bool
        public var notification: Bool
        public init(card: Bool, notification: Bool) {
            self.card = card
            self.notification = notification
        }
        public static let nothing = Shown(card: false, notification: false)
    }

    /// A run finished the analysis and celebrates (`celebratesFinish`), and its card has not been
    /// on screen yet.
    public private(set) var owed = false
    /// The notification for the moment owed was sent.
    public private(set) var notified = false
    /// The check mark and haptic of the card shown now have played.
    public private(set) var played = false
    public init() {}

    /// A run in the app starts: its own card replaces the finish card; a moment nobody saw stays
    /// owed.
    public mutating func runStarted() { played = false }

    /// The end of a run is decided, before it waits for the overview.
    public mutating func runEnded(finished: Bool, celebrates: Bool) {
        guard finished && celebrates else { return }
        owed = true
        notified = false
    }

    /// After the wait. `settled`: `AnalysisRunEnd.afterWait(isNewest:).finishMoment` of this end
    /// (it finished the analysis, and no newer run started meanwhile). `appActive`: the app is in
    /// front (otherwise the notification, once).
    public mutating func afterWait(settled: Bool, appActive: Bool) -> Shown {
        guard owed && settled else { return .nothing }
        let notify = !appActive && !notified
        // Shown in the app (even if not looked at yet, another tab): no notification for it
        // later (second review of 4e26e08, S1: a check ending in the background hours later
        // notified a finish that had been on screen).
        notified = true
        return Shown(card: true, notification: notify)
    }

    /// The finish card is on screen (`AppModel.claimFinishMoment`): the check mark plays once,
    /// and the moment is no longer owed.
    public mutating func claim() -> Bool {
        guard !played else { return false }
        played = true
        owed = false
        return true
    }
}

// MARK: Photo mosaic

/// The photo mosaic with the trips found ("Erster Scan als Show", `ScanShow`) above the
/// progress card. Fuchs decided on 16.11.: only during the first analysis; later analyses show
/// only the calm card. One switch turns it off for the first analysis too.
public enum ScanShowRule {
    /// The switch: `false` shows the mosaic never.
    public static let onFirstAnalysis = true

    /// `firstAnalysis`: no analysis was completed yet (also when the first one goes on after a
    /// pause or a restart). `AnalysisMarker.reset()` ("Analyse neu aufbauen", another part of
    /// the library) clears that, so the next full analysis counts as a first one again.
    public static func shows(isRunning: Bool, firstAnalysis: Bool, isQuickCheck: Bool,
                             enabled: Bool = onFirstAnalysis) -> Bool {
        enabled && isRunning && firstAnalysis && !isQuickCheck
    }

    /// The mosaic's light sweep moves only while the analysis really works (rule 4, S1): not
    /// while it waits (heat, battery), is pausing or paused, not while Apple's geocoder is
    /// waited for, not off screen, and not from serious heat up (re-review N1: it ran at
    /// 10 Hz the whole run, also while the iPhone cooled down).
    public static func animates(card: AnalysisCardState?, isOnScreen: Bool, thermal: DeviceState.Thermal,
                                reduceMotion: Bool) -> Bool {
        (card?.isWorking ?? false) && isOnScreen && thermal < .serious && !reduceMotion
    }
}

// MARK: Already done

/// "Schon fertig: 51 Reisen, 38 Orte" (point 3): suggestions of the steps that are done, while
/// the analysis goes on. Trips and places are known after the places step; before, nothing.
public struct AlreadyDone: Sendable, Equatable {
    public var trips = 0
    public var places = 0
    public var isEmpty: Bool { trips == 0 && places == 0 }

    public init(trips: Int = 0, places: Int = 0) {
        self.trips = trips
        self.places = places
    }

    /// `step`: the running step; trips and places count from the image step on.
    public static func counts(proposals: [AlbumProposal], step: AnalysisStep?) -> AlreadyDone {
        guard let step, step >= .content else { return AlreadyDone() }
        var done = AlreadyDone()
        for proposal in proposals {
            switch proposal.kind {
            case .trip: done.trips += 1
            case .placeCollection, .frequentPlace: done.places += 1
            default: break
            }
        }
        return done
    }
}

// MARK: Throttled progress

/// Progress from the pipeline, kept here without a hop to the main actor for every report
/// (S2): the app takes the newest value once per tick (250 ms). The workload, said once, and
/// the photos just looked at are kept until taken.
public final class ProgressMailbox: Sendable {
    public struct Taken: Sendable {
        public var progress: AnalysisPipeline.Progress?
        public var workload: AnalysisWorkload?
        public var recent: [AssetID]
        /// The early suggestions were saved (kept until taken, like the workload).
        public var earlyProposals = false
        /// What the run waits for (hot iPhone, battery nearly empty), as the pipeline said it
        /// last (`onWaiting`); `nil` while it works. A state, not a report: it stays until the
        /// pipeline says otherwise, and every take carries it.
        public var waiting: PauseReason?
    }

    private let state = Locked(Taken(progress: nil, workload: nil, recent: []))

    public init() {}

    public func post(_ progress: AnalysisPipeline.Progress) {
        state.withLock {
            if let workload = progress.workload { $0.workload = workload }
            if !progress.recent.isEmpty { $0.recent = progress.recent }
            if progress.earlyProposals { $0.earlyProposals = true }
            $0.progress = progress
        }
    }

    /// The run begins or ends a wait for the device (`AnalysisPipeline.run`'s `onWaiting`).
    /// Kept in the same box as the progress, so the order the pipeline said them in holds: a
    /// report sent just before the wait began, and taken by the next tick after it, no longer
    /// hides the wait (UI run 43930271358: the last report of the places step was taken after
    /// "Wartet aufs Laden" was set, cleared it, and the card said "running" for the whole wait).
    public func wait(_ reason: PauseReason?) {
        state.withLock { $0.waiting = reason }
    }

    /// The newest progress since the last call (`nil` if none came), and the rest.
    public func take() -> Taken {
        state.withLock {
            let taken = $0
            $0.progress = nil
            $0.workload = nil
            $0.recent = []
            $0.earlyProposals = false
            return taken
        }
    }
}

// MARK: The overnight refinement on the card

/// The countdown of a wait for Apple's geocoder ("weiter in 25 s", "weiter in 2 Minuten"): whole
/// seconds up to a minute, whole minutes above (a wait after a refusal can last up to 10 min),
/// always rounded up, so it never says less than is left and never 0 while it still waits.
public enum AppleWaitCountdown: Sendable, Equatable {
    case seconds(Int)
    case minutes(Int)

    public init(_ left: Duration) {
        let seconds = max(1, Int(left.seconds.rounded(.up)))
        self = seconds <= 60 ? .seconds(seconds) : .minutes((seconds + 59) / 60)
    }
}

/// The card while the overnight refinement runs and the app is opened (second review of the
/// no-wait fix for the geocoder, device test 18.11., build 36). Before, the refinement's
/// reports reached no one: the card stood on the last run's position without a word, and the
/// countdown of its wait for Apple never showed. The refinement is shown as a run of its own:
/// its step and count, the countdown while it waits for Apple's limit, a wait for the device,
/// and a bar that moves with it from its own start. Nothing of the analysis before it is
/// touched (the marker a later run goes on from, its bar and widths, its finish time:
/// `AppModel.refinePass` gives them back when the refinement ends). Fed like a run in the app:
/// the pipeline's reports into a `ProgressMailbox`, taken by a tick every 250 ms.
public struct RefinementCard: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public struct Shown: Sendable, Equatable {
        public var stage: AnalysisPipeline.Stage?
        public var completed = 0
        public var total = 0
        /// The places step's pass over the offline map.
        public var mapPass: AnalysisPipeline.MapPass?
        /// The refinement waits for Apple's geocoder: about how long still, as the pipeline
        /// said it last (every 2 s); `nil` once the lookups go on.
        public var waitLeft: Duration?
        /// The device asked for a break (heat, battery).
        public var waiting: PauseReason?
        /// The bar's segments for the refinement (from its own workload, once said).
        public var widths: StepWidths = .standard
        /// The bar (0…0.99): gliding between reports while the refinement works.
        public var bar = 0.0

        public var position: AnalysisCardState.Position? {
            stage.map { AnalysisCardState.Position(step: AnalysisStep($0), completed: completed, total: total) }
        }
        public var countdown: AppleWaitCountdown? { waitLeft.map(AppleWaitCountdown.init) }
        public init() {}
    }

    public private(set) var shown = Shown()
    private var estimator = ProgressEstimator()
    private var glide = BarGlide()
    private var widthsFixed = false

    public init() {}

    /// One tick: what the mailbox held since the last one. `gliding`: on screen, without
    /// Reduce Motion, not pausing (the bar then shows the real value only).
    @discardableResult
    public mutating func take(_ taken: ProgressMailbox.Taken, at now: Instant, gliding: Bool) -> Shown {
        shown.waiting = taken.waiting
        if let workload = taken.workload {
            estimator.setWorkload(workload)
            if !widthsFixed {
                // As a run in the app: the widths from the workload, continued from the bar
                // drawn so far, so the bar neither falls nor stands until the real value passes it.
                var widths = StepWidths(workload: workload)
                if let stage = shown.stage,
                   let continued = widths.continuing(held: shown.bar, step: AnalysisStep(stage),
                                                     completed: shown.completed, total: shown.total) {
                    widths = continued
                }
                shown.widths = widths
                widthsFixed = true
                glide.reset(keeping: shown.bar)
            }
        }
        if let p = taken.progress, accepts(p) {
            shown.stage = p.stage
            shown.completed = p.completed
            shown.total = p.total
            shown.mapPass = p.stage == .places ? p.mapPass : nil
            shown.waitLeft = p.waitLeft
            let step = AnalysisStep(p.stage)
            estimator.record(step: step, completed: p.completed, total: p.total, at: now, appleWait: p.waitLeft != nil)
            glide.update(real: shown.widths.overall(step: step, completed: p.completed, total: p.total), at: now,
                         step: step, widths: shown.widths, itemsPerSecond: estimator.rate, total: p.total)
        }
        let working = shown.waiting == nil && shown.waitLeft == nil
        if !working { estimator.idle() }
        shown.bar = glide.value(at: now, gliding: gliding && working)
        return shown
    }

    /// A step never goes back, nor a count within its step (a late report of the same run).
    private func accepts(_ p: AnalysisPipeline.Progress) -> Bool {
        guard let stage = shown.stage else { return true }
        if p.stage.number < stage.number { return false }
        return !(p.stage == stage && p.completed < shown.completed)
    }
}
