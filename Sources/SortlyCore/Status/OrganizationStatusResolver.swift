import Foundation

/// Per-area status of one asset plus derived overall status (prompt §6.1).
public struct AssetOrganizationState: Hashable, Sendable, Codable {
    public var assetID: AssetID
    public var areas: [OrganizationArea: AreaStatus]
    public var isUncertain: Bool

    public init(assetID: AssetID, areas: [OrganizationArea: AreaStatus] = [:], isUncertain: Bool = false) {
        self.assetID = assetID
        self.areas = areas
        self.isUncertain = isUncertain
    }
}

/// Facts the resolver needs about an asset in one area. Produced by the analysis layer.
public struct AreaFacts: Hashable, Sendable {
    /// The area does not apply (e.g. trips for a screenshot, places without location for chronology).
    public var applicable: Bool
    /// Analysis finished for this area.
    public var analyzed: Bool
    /// Analysis cannot run (no GPS for places, original unavailable, ...).
    public var analysisImpossible: Bool
    /// A user album that Albumist matched to the asset's proposal already holds it.
    public var inMatchingExistingAlbum: Bool
    /// A Albumist-applied, verified assignment exists.
    public var organizedBySortly: Bool
    /// An open proposal includes the asset.
    public var proposed: Bool
    /// Part of a confirmed but not yet executed plan.
    public var pendingInPlan: Bool
    /// Classification is contradictory or below the reliability needed.
    public var uncertain: Bool

    public init(
        applicable: Bool = true,
        analyzed: Bool = true,
        analysisImpossible: Bool = false,
        inMatchingExistingAlbum: Bool = false,
        organizedBySortly: Bool = false,
        proposed: Bool = false,
        pendingInPlan: Bool = false,
        uncertain: Bool = false
    ) {
        self.applicable = applicable
        self.analyzed = analyzed
        self.analysisImpossible = analysisImpossible
        self.inMatchingExistingAlbum = inMatchingExistingAlbum
        self.organizedBySortly = organizedBySortly
        self.proposed = proposed
        self.pendingInPlan = pendingInPlan
        self.uncertain = uncertain
    }
}

/// Derives organization states. The status depends on the *areas the user chose as primary*,
/// never on "is in any album" (prompt §6.1, Scenario M).
public struct OrganizationStatusResolver: Sendable {
    public var primaryAreas: Set<OrganizationArea>

    public init(primaryAreas: Set<OrganizationArea>) {
        self.primaryAreas = primaryAreas
    }

    public func areaStatus(_ facts: AreaFacts, ignored: Bool, excluded: Bool) -> AreaStatus {
        if excluded { return .excluded }
        if ignored { return .ignored }
        if !facts.applicable { return .notApplicable }
        if facts.organizedBySortly { return .organized }
        if facts.inMatchingExistingAlbum { return .preExisting }
        if facts.pendingInPlan { return .pendingConfirmation }
        if facts.analysisImpossible { return .analysisImpossible }
        if !facts.analyzed { return .analysisPending }
        if facts.proposed { return .proposed }
        return .unorganized
    }

    public func state(
        for assetID: AssetID,
        facts: [OrganizationArea: AreaFacts],
        ignored: Bool = false,
        excluded: Bool = false
    ) -> AssetOrganizationState {
        var areas: [OrganizationArea: AreaStatus] = [:]
        var uncertain = false
        for (area, f) in facts {
            areas[area] = areaStatus(f, ignored: ignored, excluded: excluded)
            if f.uncertain && f.applicable && primaryAreas.contains(area) { uncertain = true }
        }
        return AssetOrganizationState(assetID: assetID, areas: areas, isUncertain: uncertain)
    }

    public func overall(_ state: AssetOrganizationState) -> OverallStatus {
        let statuses = state.areas.filter { primaryAreas.contains($0.key) }.map(\.value)
        if statuses.contains(.excluded) { return .excluded }
        if statuses.contains(.ignored) { return .ignored }
        let relevant = statuses.filter { $0 != .notApplicable && $0 != .analysisImpossible }
        if relevant.isEmpty {
            // Nothing the user cares about applies – counts as organized, never as an open task.
            return statuses.isEmpty ? .unorganized : .fullyOrganized
        }
        let done = relevant.filter { $0 == .organized || $0 == .preExisting }.count
        if relevant.contains(.analysisPending) && done == 0 { return .pending }
        if done == relevant.count { return .fullyOrganized }
        return done > 0 ? .partiallyOrganized : .unorganized
    }

    /// Inbox buckets an asset belongs to (an asset can be in "all" plus one more).
    public func buckets(_ state: AssetOrganizationState) -> Set<InboxBucket> {
        var result: Set<InboxBucket> = [.all]
        switch overall(state) {
        case .excluded: result.insert(.excluded); return result
        case .ignored: result.insert(.ignored); return result
        case .fullyOrganized: result.insert(.organized)
        case .partiallyOrganized, .unorganized, .pending: result.insert(.unorganized)
        }
        let primary = state.areas.filter { primaryAreas.contains($0.key) }.map(\.value)
        if primary.contains(.proposed) || primary.contains(.pendingConfirmation) { result.insert(.suggestions) }
        if state.isUncertain { result.insert(.uncertain) }
        return result
    }

    /// Library-wide progress figures for the overview screen.
    public struct Progress: Hashable, Sendable {
        public init() {}
        public var total = 0
        public var fully = 0
        public var partially = 0
        public var unorganized = 0
        public var pending = 0
        public var ignored = 0
        public var excluded = 0

        public var fullyShare: Double { total == 0 ? 0 : Double(fully) / Double(total) }
        public var partiallyShare: Double { total == 0 ? 0 : Double(partially) / Double(total) }
    }

    public func progress<S: Sequence>(_ states: S) -> Progress where S.Element == AssetOrganizationState {
        var p = Progress()
        for s in states {
            p.total += 1
            switch overall(s) {
            case .fullyOrganized: p.fully += 1
            case .partiallyOrganized: p.partially += 1
            case .unorganized: p.unorganized += 1
            case .pending: p.pending += 1
            case .ignored: p.ignored += 1
            case .excluded: p.excluded += 1
            }
        }
        return p
    }
}
