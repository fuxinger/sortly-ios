import Foundation

/// What Albumist remembers about an album it created or extended (prompt §5.6).
public struct ManagedAlbumState: Hashable, Sendable, Codable {
    public var albumID: CollectionID
    /// Internal proposal/rule identity the album belongs to.
    public var sourceID: SortlyID
    public var lastKnownTitle: String
    public var lastKnownParentID: CollectionID?
    /// Members as of the last reconciliation.
    public var lastKnownMembers: Set<AssetID>
    /// Members Albumist added itself (needed for safe undo).
    public var addedBySortly: Set<AssetID>
    /// True if Albumist created the album (vs. extended an existing user album).
    public var createdBySortly: Bool
    /// Further suggestions that were applied to this album (two suggestions put into one album).
    public var otherSourceIDs: Set<SortlyID> = []

    /// Every suggestion this album stands for.
    public var allSourceIDs: Set<SortlyID> { otherSourceIDs.union([sourceID]) }

    enum CodingKeys: String, CodingKey {
        case albumID, sourceID, lastKnownTitle, lastKnownParentID, lastKnownMembers, addedBySortly, createdBySortly, otherSourceIDs
    }

    public init(
        albumID: CollectionID,
        sourceID: SortlyID,
        lastKnownTitle: String,
        lastKnownParentID: CollectionID?,
        lastKnownMembers: Set<AssetID>,
        addedBySortly: Set<AssetID>,
        createdBySortly: Bool
    ) {
        self.albumID = albumID
        self.sourceID = sourceID
        self.lastKnownTitle = lastKnownTitle
        self.lastKnownParentID = lastKnownParentID
        self.lastKnownMembers = lastKnownMembers
        self.addedBySortly = addedBySortly
        self.createdBySortly = createdBySortly
    }
}

extension ManagedAlbumState {
    /// Records saved before `otherSourceIDs` existed still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albumID = try c.decode(CollectionID.self, forKey: .albumID)
        sourceID = try c.decode(SortlyID.self, forKey: .sourceID)
        lastKnownTitle = try c.decode(String.self, forKey: .lastKnownTitle)
        lastKnownParentID = try c.decodeIfPresent(CollectionID.self, forKey: .lastKnownParentID)
        lastKnownMembers = try c.decode(Set<AssetID>.self, forKey: .lastKnownMembers)
        addedBySortly = try c.decode(Set<AssetID>.self, forKey: .addedBySortly)
        createdBySortly = try c.decode(Bool.self, forKey: .createdBySortly)
        otherSourceIDs = try c.decodeIfPresent(Set<SortlyID>.self, forKey: .otherSourceIDs) ?? []
    }
}

/// External change detected on a managed album.
public enum ExternalAlbumChange: Hashable, Sendable, Codable {
    case renamed(albumID: CollectionID, from: String, to: String)
    case moved(albumID: CollectionID, from: CollectionID?, to: CollectionID?)
    case assetsAddedByUser(albumID: CollectionID, assets: Set<AssetID>)
    case assetsRemovedByUser(albumID: CollectionID, assets: Set<AssetID>)
    case deleted(albumID: CollectionID, sourceID: SortlyID)
}

/// Compares stored managed-album states with the current inventory and turns the
/// differences into user overrides, so manual decisions win (Scenarios E and F).
public struct ManagedAlbumTracker: Sendable {
    public init() {}

    public struct Reconciliation: Sendable {
        public var changes: [ExternalAlbumChange]
        public var updatedStates: [ManagedAlbumState]
        /// Overrides derived from the user's manual actions.
        public var newOverrides: [UserOverride]
    }

    public func reconcile(_ states: [ManagedAlbumState], with inventory: CollectionInventory, now: Date = Date()) -> Reconciliation {
        var changes: [ExternalAlbumChange] = []
        var updated: [ManagedAlbumState] = []
        var overrides: [UserOverride] = []

        for var state in states {
            guard let album = inventory[state.albumID] else {
                // Deleted on purpose by the user: never silently re-create it (for any of the
                // suggestions it stood for).
                changes.append(.deleted(albumID: state.albumID, sourceID: state.sourceID))
                for source in state.allSourceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
                    overrides.append(UserOverride(scope: .source(source), decision: .doNotRecreateAlbum, createdAt: now))
                }
                continue
            }
            if album.title != state.lastKnownTitle {
                changes.append(.renamed(albumID: album.id, from: state.lastKnownTitle, to: album.title))
                state.lastKnownTitle = album.title
            }
            if album.parentID != state.lastKnownParentID {
                changes.append(.moved(albumID: album.id, from: state.lastKnownParentID, to: album.parentID))
                state.lastKnownParentID = album.parentID
            }
            let removed = state.lastKnownMembers.subtracting(album.assetIDs)
            let added = album.assetIDs.subtracting(state.lastKnownMembers)
            if !removed.isEmpty {
                changes.append(.assetsRemovedByUser(albumID: album.id, assets: removed))
                for asset in removed {
                    overrides.append(UserOverride(scope: .assetInAlbum(asset, album.id), decision: .neverAdd, createdAt: now))
                }
                state.addedBySortly.subtract(removed)
            }
            if !added.isEmpty {
                changes.append(.assetsAddedByUser(albumID: album.id, assets: added))
            }
            state.lastKnownMembers = album.assetIDs
            updated.append(state)
        }
        return Reconciliation(changes: changes, updatedStates: updated, newOverrides: overrides)
    }
}

/// A manual user decision that takes precedence over every automatic rule (prompt §8, §9).
public struct UserOverride: Hashable, Sendable, Codable, Identifiable {
    public enum Scope: Hashable, Sendable, Codable {
        case asset(AssetID)
        case assetInAlbum(AssetID, CollectionID)
        case assetInSource(AssetID, SortlyID)
        case album(CollectionID)
        case source(SortlyID)
        case area(OrganizationArea)
        /// One existing album for one suggestion.
        case albumForSource(CollectionID, SortlyID)
    }

    public enum Decision: String, Hashable, Sendable, Codable {
        case neverAdd            // do not add this asset to that album again
        case alwaysAdd           // manual inclusion
        case ignoreAsset         // user does not want this asset organized
        case excludeFromAnalysis // do not analyze at all (sensitive)
        case doNotRecreateAlbum  // album was deleted by the user
        case rejectProposal      // proposal rejected, do not suggest again
        case notMatchingAlbum    // this album does not fit this suggestion, never offer it again
    }

    public var id: SortlyID
    public var scope: Scope
    public var decision: Decision
    public var ruleID: SortlyID?
    public var createdAt: Date

    public init(id: SortlyID = SortlyID(), scope: Scope, decision: Decision, ruleID: SortlyID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.scope = scope
        self.decision = decision
        self.ruleID = ruleID
        self.createdAt = createdAt
    }
}

/// Fast lookup over all overrides.
public struct OverrideSet: Sendable {
    private var neverAddInAlbum: Set<String> = []
    private var neverAddInSource: Set<String> = []
    private var alwaysAddInAlbum: Set<String> = []
    private var ignoredAssets: Set<AssetID> = []
    private var excludedAssets: Set<AssetID> = []
    private var excludedAlbums: Set<CollectionID> = []
    private var rejectedSources: Set<SortlyID> = []
    private var deletedSources: Set<SortlyID> = []
    private var rejectedMatches: Set<String> = []

    public init(_ overrides: [UserOverride] = []) {
        for o in overrides { insert(o) }
    }

    public mutating func insert(_ o: UserOverride) {
        switch (o.scope, o.decision) {
        case let (.assetInAlbum(a, c), .neverAdd): neverAddInAlbum.insert(a.rawValue + "|" + c.rawValue)
        case let (.assetInAlbum(a, c), .alwaysAdd): alwaysAddInAlbum.insert(a.rawValue + "|" + c.rawValue)
        case let (.assetInSource(a, s), .neverAdd): neverAddInSource.insert(a.rawValue + "|" + s.rawValue)
        case let (.asset(a), .ignoreAsset): ignoredAssets.insert(a)
        case let (.asset(a), .excludeFromAnalysis): excludedAssets.insert(a)
        case let (.album(c), .excludeFromAnalysis): excludedAlbums.insert(c)
        case let (.source(s), .rejectProposal): rejectedSources.insert(s)
        case let (.source(s), .doNotRecreateAlbum): deletedSources.insert(s)
        case let (.albumForSource(c, s), .notMatchingAlbum): rejectedMatches.insert(c.rawValue + "|" + s.rawValue)
        default: break
        }
    }

    public func mayAdd(_ asset: AssetID, toAlbum album: CollectionID) -> Bool {
        !neverAddInAlbum.contains(asset.rawValue + "|" + album.rawValue) && !ignoredAssets.contains(asset) && !excludedAssets.contains(asset)
    }
    public func mayAdd(_ asset: AssetID, toSource source: SortlyID) -> Bool {
        !neverAddInSource.contains(asset.rawValue + "|" + source.rawValue) && !ignoredAssets.contains(asset) && !excludedAssets.contains(asset)
    }
    public func isForcedIn(_ asset: AssetID, album: CollectionID) -> Bool {
        alwaysAddInAlbum.contains(asset.rawValue + "|" + album.rawValue)
    }
    public func isIgnored(_ asset: AssetID) -> Bool { ignoredAssets.contains(asset) }
    public func isExcluded(_ asset: AssetID) -> Bool { excludedAssets.contains(asset) }
    public func isExcludedAlbum(_ album: CollectionID) -> Bool { excludedAlbums.contains(album) }
    public func isRejected(_ source: SortlyID) -> Bool { rejectedSources.contains(source) }
    public func mustNotRecreate(_ source: SortlyID) -> Bool { deletedSources.contains(source) }
    /// The user said this album does not fit this suggestion.
    public func isRejectedMatch(_ album: CollectionID, for source: SortlyID) -> Bool {
        rejectedMatches.contains(album.rawValue + "|" + source.rawValue)
    }
}

// MARK: - Recording executed plans

extension ManagedAlbumTracker {
    /// Updates the managed-album states after a plan ran: albums Albumist created or extended
    /// are remembered together with exactly the media Albumist added, so they can be listed,
    /// removed again and checked for manual changes later. `inventory` is read after the run.
    public func record(_ plan: ChangePlan, into states: [ManagedAlbumState], inventory: CollectionInventory) -> [ManagedAlbumState] {
        var byID: [CollectionID: ManagedAlbumState] = [:]
        for state in states where byID[state.albumID] == nil { byID[state.albumID] = state }
        var touched: Set<CollectionID> = []

        for step in plan.steps {
            guard case .succeeded(let createdID, _) = step.state else { continue }
            let source = step.sourceID ?? plan.id
            switch step.operation {
            case .createAlbum(let key, let title, _):
                guard let id = createdID ?? plan.resolvedKeys[key] else { continue }
                byID[id] = ManagedAlbumState(albumID: id, sourceID: source, lastKnownTitle: title, lastKnownParentID: nil,
                                             lastKnownMembers: [], addedBySortly: [], createdBySortly: true)
                touched.insert(id)
            case .addAssets(let ref, let assets):
                let albumID: CollectionID? = switch ref {
                case .existing(let id): id
                case .planned(let key): plan.resolvedKeys[key]
                }
                guard let albumID else { continue }
                var state = byID[albumID] ?? ManagedAlbumState(
                    albumID: albumID, sourceID: source, lastKnownTitle: inventory[albumID]?.title ?? "",
                    lastKnownParentID: nil, lastKnownMembers: [], addedBySortly: [], createdBySortly: false)
                state.addedBySortly.formUnion(assets)
                if source != state.sourceID { state.otherSourceIDs.insert(source) }
                byID[albumID] = state
                touched.insert(albumID)
            case .removeAssets(let album, let assets):
                byID[album]?.addedBySortly.subtract(assets)
                touched.insert(album)
            case .deleteCollection(let id, _):
                byID[id] = nil
            default:
                break
            }
        }

        var result: [ManagedAlbumState] = []
        for var state in byID.values {
            if touched.contains(state.albumID) {
                // Only albums this plan changed are refreshed; the others keep their last
                // known state so manual changes are still detected by `reconcile`.
                guard let album = inventory[state.albumID] else { continue }
                state.lastKnownTitle = album.title
                state.lastKnownParentID = album.parentID
                state.lastKnownMembers = album.assetIDs
                state.addedBySortly.formIntersection(album.assetIDs)
                if state.addedBySortly.isEmpty { continue }
            }
            result.append(state)
        }
        return result.sorted { ($0.lastKnownTitle, $0.albumID.rawValue) < ($1.lastKnownTitle, $1.albumID.rawValue) }
    }

    /// Plan that takes back what Albumist did to one album: an album Albumist created is deleted
    /// if it only holds media Albumist added, otherwise only Albumist's additions leave the album.
    /// Media the user added by hand always stay. Originals are never touched.
    public func removalPlan(for state: ManagedAlbumState, current: CollectionInventory, id: SortlyID = SortlyID(), now: Date = Date()) -> ChangePlan {
        var steps: [PlanStep] = []
        var notes: [PlanNote] = []
        func append(_ op: PlannedOperation) {
            steps.append(PlanStep(id: "\(id.rawValue)-\(steps.count)-\(StableHash.hex(String(describing: op)).prefix(12))", operation: op, sourceID: state.sourceID))
        }
        if let album = current[state.albumID], album.isEditableAlbum {
            let ours = album.assetIDs.intersection(state.addedBySortly)
            if state.createdBySortly && album.assetIDs.isSubset(of: state.addedBySortly) {
                append(.deleteCollection(album.id, title: album.title))
            } else if !ours.isEmpty {
                append(.removeAssets(album: album.id, assets: ours.sorted()))
                let manual = album.assetIDs.subtracting(ours).count
                if state.createdBySortly && manual > 0 { notes.append(.respectedManualRemovals(count: manual)) }
            }
        }
        return ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: current[state.albumID].map { [$0.id: $0.fingerprint] } ?? [:],
            baselineCollectionIDs: Set(current.collections.keys),
            steps: steps,
            conflicts: [],
            notes: notes,
            resolvedKeys: [:]
        )
    }
}
