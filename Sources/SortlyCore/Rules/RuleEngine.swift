import Foundation

/// A single rule predicate (prompt §8).
public enum RulePredicate: Hashable, Sendable, Codable {
    case country(isoCode: String)
    case region(String)
    case city(String)
    case geoCluster(SortlyID)            // frequent place
    case trip(SortlyID)
    case dateRange(start: Date, end: Date)
    case year(Int)
    case month(Int)
    case mediaKind(MediaKind)
    case subtype(UInt32)                 // MediaSubtypes raw value
    case imageCategory(String, minimum: Reliability)
    case textCategory(String)
    case documentType(String)
    case group(SortlyID)                 // confirmed person/pet group
    case inAlbum(CollectionID)
    case hasLocation
    case keyword(String)
}

/// Logical combination of predicates with AND / OR / NOT.
public indirect enum RuleCondition: Hashable, Sendable, Codable {
    case always
    case predicate(RulePredicate)
    case all([RuleCondition])
    case any([RuleCondition])
    case not(RuleCondition)
}

public enum RuleTarget: Hashable, Sendable, Codable {
    case existingAlbum(CollectionID)
    /// New album created from the naming template inside the folder path.
    case newAlbum(titleTemplate: String, folderPath: [String])
}

/// A versioned, editable organization rule.
public struct OrganizationRule: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var version: Int
    public var name: String
    public var area: OrganizationArea
    public var condition: RuleCondition
    /// Assets explicitly excluded from this rule.
    public var excludedAssets: Set<AssetID>
    public var target: RuleTarget
    /// `nil` = inherit from area / global setting.
    public var automationMode: AutomationMode?
    public var priority: Int
    public var isEnabled: Bool
    public var updatedAt: Date

    public init(
        id: SortlyID = SortlyID(),
        version: Int = 1,
        name: String,
        area: OrganizationArea,
        condition: RuleCondition,
        excludedAssets: Set<AssetID> = [],
        target: RuleTarget,
        automationMode: AutomationMode? = nil,
        priority: Int = 0,
        isEnabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.area = area
        self.condition = condition
        self.excludedAssets = excludedAssets
        self.target = target
        self.automationMode = automationMode
        self.priority = priority
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }

    /// Returns the next version with the given modification applied. Old versions are kept
    /// by the store so every change stays traceable (prompt §8: versioniert, nachvollziehbar).
    public func revised(at date: Date = Date(), _ change: (inout OrganizationRule) -> Void) -> OrganizationRule {
        var copy = self
        change(&copy)
        copy.version = version + 1
        copy.updatedAt = date
        return copy
    }
}

public struct RuleEvaluator: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .sortlyDefault) {
        self.calendar = calendar
    }

    public func evaluate(_ condition: RuleCondition, _ facts: AssetFacts) -> Bool {
        switch condition {
        case .always: return true
        case .predicate(let p): return evaluate(p, facts)
        case .all(let cs): return cs.allSatisfy { evaluate($0, facts) }
        case .any(let cs): return cs.contains { evaluate($0, facts) }
        case .not(let c): return !evaluate(c, facts)
        }
    }

    public func evaluate(_ predicate: RulePredicate, _ f: AssetFacts) -> Bool {
        switch predicate {
        case .country(let code): return f.gpsPlace?.isoCountryCode?.uppercased() == code.uppercased()
        case .region(let name):
            guard let p = f.gpsPlace else { return false }
            let n = PlaceKey.normalize(name)
            return [p.administrativeArea, p.subAdministrativeArea].compactMap { $0 }.map(PlaceKey.normalize).contains(n)
        case .city(let name):
            guard let city = f.gpsPlace?.locality else { return false }
            return PlaceKey.normalize(city) == PlaceKey.normalize(name)
        case .geoCluster(let id): return f.frequentPlaceID == id
        case .trip(let id): return f.tripID == id
        case .dateRange(let start, let end):
            guard let d = f.asset.creationDate else { return false }
            return d >= start && d <= end
        case .year(let y):
            guard let d = f.asset.creationDate else { return false }
            return calendar.component(.year, from: d) == y
        case .month(let m):
            guard let d = f.asset.creationDate else { return false }
            return calendar.component(.month, from: d) == m
        case .mediaKind(let k): return f.asset.kind == k
        case .subtype(let raw): return f.asset.subtypes.contains(MediaSubtypes(rawValue: raw))
        case .imageCategory(let id, let minimum): return f.hasCategory(id, minimum: minimum)
        case .textCategory(let id): return f.textCategories.contains(id)
        case .documentType(let t): return f.document?.type.rawValue == t
        case .group(let id): return f.groupIDs.contains(id)
        case .inAlbum(let id): return f.albumIDs.contains(id)
        case .hasLocation: return f.asset.usableLocation != nil
        case .keyword(let k): return f.keywords.contains(k.lowercased())
        }
    }

    /// Assets matched by a rule after rule exclusions and manual overrides
    /// (a manual exception always wins over the general rule – prompt §8).
    public func matches(_ rule: OrganizationRule, in facts: [AssetFacts], overrides: OverrideSet) -> [AssetID] {
        guard rule.isEnabled else { return [] }
        return facts.compactMap { f -> AssetID? in
            guard !rule.excludedAssets.contains(f.id),
                  !overrides.isIgnored(f.id), !overrides.isExcluded(f.id),
                  overrides.mayAdd(f.id, toSource: rule.id)
            else { return nil }
            if case .existingAlbum(let album) = rule.target, !overrides.mayAdd(f.id, toAlbum: album) { return nil }
            return evaluate(rule.condition, f) ? f.id : nil
        }
    }

    /// Finds contradicting rules: same target with different automation modes, or a rule
    /// whose condition can never match because it requires X AND NOT X.
    public func conflicts(_ rules: [OrganizationRule]) -> [RuleConflict] {
        var result: [RuleConflict] = []
        let enabled = rules.filter(\.isEnabled)
        var byTarget: [RuleTarget: [OrganizationRule]] = [:]
        for r in enabled { byTarget[r.target, default: []].append(r) }
        for (_, group) in byTarget where group.count > 1 {
            let modes = Set(group.map { $0.automationMode ?? .suggestOnly })
            if modes.count > 1 {
                result.append(.sameTargetDifferentAutomation(group.map(\.id)))
            }
        }
        for r in enabled where Self.isContradiction(r.condition) {
            result.append(.unsatisfiable(r.id))
        }
        return result
    }

    static func isContradiction(_ condition: RuleCondition) -> Bool {
        guard case .all(let parts) = condition else { return false }
        var positives = Set<RulePredicate>()
        var negatives = Set<RulePredicate>()
        for p in parts {
            switch p {
            case .predicate(let x): positives.insert(x)
            case .not(.predicate(let x)): negatives.insert(x)
            default: break
            }
        }
        return !positives.isDisjoint(with: negatives)
    }
}

public enum RuleConflict: Hashable, Sendable, Codable {
    case sameTargetDifferentAutomation([SortlyID])
    case unsatisfiable(SortlyID)
}

/// Decides whether a planned change may run automatically (prompt §8).
public struct AutomationPolicy: Sendable, Hashable, Codable {
    public var globalMode: AutomationMode
    public var areaModes: [OrganizationArea: AutomationMode]
    public var albumModes: [CollectionID: AutomationMode]

    public init(
        globalMode: AutomationMode = .suggestOnly,
        areaModes: [OrganizationArea: AutomationMode] = [:],
        albumModes: [CollectionID: AutomationMode] = [:]
    ) {
        self.globalMode = globalMode
        self.areaModes = areaModes
        self.albumModes = albumModes
    }

    public enum ChangeKind: Sendable, Hashable {
        case extendConfirmedAlbum(CollectionID)
        case createAlbumFromApprovedRule
        case restructure // rename, move, merge, remove
    }

    public enum Verdict: String, Sendable, Hashable { case automatic, needsConfirmation }

    /// Most specific mode wins: album > rule > area > global.
    public func effectiveMode(area: OrganizationArea, album: CollectionID? = nil, rule: OrganizationRule? = nil) -> AutomationMode {
        if let album, let m = albumModes[album] { return m }
        if let m = rule?.automationMode { return m }
        if let m = areaModes[area] { return m }
        return globalMode
    }

    public func verdict(
        for change: ChangeKind,
        area: OrganizationArea,
        reliability: Reliability,
        isSensitive: Bool,
        hasConflict: Bool,
        rule: OrganizationRule? = nil
    ) -> Verdict {
        // Never automatic: uncertain results, sensitive personal categories, conflicts,
        // and any structural change (prompt §8, Modus C).
        if hasConflict || isSensitive || area.isSensitive || reliability < .likely { return .needsConfirmation }
        let album: CollectionID? = if case .extendConfirmedAlbum(let id) = change { id } else { nil }
        let mode = effectiveMode(area: area, album: album, rule: rule)
        switch (change, mode) {
        case (.restructure, _): return .needsConfirmation
        case (_, .suggestOnly): return .needsConfirmation
        case (.extendConfirmedAlbum, .semiAutomatic), (.extendConfirmedAlbum, .automatic): return .automatic
        case (.createAlbumFromApprovedRule, .automatic): return rule != nil ? .automatic : .needsConfirmation
        case (.createAlbumFromApprovedRule, .semiAutomatic): return .needsConfirmation
        }
    }
}
