import Foundation

/// What SORTLY remembers about an album it created or extended (prompt §5.6).
public struct ManagedAlbumState: Hashable, Sendable, Codable {
    public var albumID: CollectionID
    /// Internal proposal/rule identity the album belongs to.
    public var sourceID: SortlyID
    public var lastKnownTitle: String
    public var lastKnownParentID: CollectionID?
    /// Members as of the last reconciliation.
    public var lastKnownMembers: Set<AssetID>
    /// Members SORTLY added itself (needed for safe undo).
    public var addedBySortly: Set<AssetID>
    /// True if SORTLY created the album (vs. extended an existing user album).
    public var createdBySortly: Bool

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
                // Deleted on purpose by the user: never silently re-create it.
                changes.append(.deleted(albumID: state.albumID, sourceID: state.sourceID))
                overrides.append(UserOverride(
                    scope: .source(state.sourceID),
                    decision: .doNotRecreateAlbum,
                    createdAt: now
                ))
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
    }

    public enum Decision: String, Hashable, Sendable, Codable {
        case neverAdd            // do not add this asset to that album again
        case alwaysAdd           // manual inclusion
        case ignoreAsset         // user does not want this asset organized
        case excludeFromAnalysis // do not analyze at all (sensitive)
        case doNotRecreateAlbum  // album was deleted by the user
        case rejectProposal      // proposal rejected, do not suggest again
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
}
