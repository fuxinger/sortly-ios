import Foundation

/// Reference to a folder that already exists or is created earlier in the same plan.
public enum FolderRef: Hashable, Sendable, Codable {
    case topLevel
    case existing(CollectionID)
    case planned(String)
}

/// Reference to an album that already exists or is created earlier in the same plan.
public enum AlbumRef: Hashable, Sendable, Codable {
    case existing(CollectionID)
    case planned(String)
}

/// The complete, closed set of operations Albumist can perform (prompt §16.1).
/// There is deliberately no operation that deletes, modifies or copies original media.
public enum PlannedOperation: Hashable, Sendable, Codable {
    case createFolder(key: String, title: String, parent: FolderRef)
    case createAlbum(key: String, title: String, parent: FolderRef)
    case addAssets(album: AlbumRef, assets: [AssetID])
    case renameCollection(CollectionID, from: String, to: String)
    case moveCollection(CollectionID, from: CollectionID?, to: FolderRef)
    /// Removes album *memberships* only (merge or undo). Originals stay in the library.
    case removeAssets(album: CollectionID, assets: [AssetID])
    /// Deletes an album or folder *container*. Originals stay in the library.
    case deleteCollection(CollectionID, title: String)

    public var isStructural: Bool {
        switch self {
        case .renameCollection, .moveCollection, .removeAssets, .deleteCollection: true
        default: false
        }
    }
}

public enum StepState: Hashable, Sendable, Codable {
    case pending
    /// Started but not confirmed – must be reconciled with the library before retrying.
    case running(startedAt: Date)
    case succeeded(createdID: CollectionID?, verifiedAt: Date)
    case failed(reason: String)
    case skipped(reason: String)

    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .skipped: true
        default: false
        }
    }

    var isFailedOrSkipped: Bool {
        switch self {
        case .failed, .skipped: true
        default: false
        }
    }
}

public struct PlanStep: Hashable, Sendable, Codable, Identifiable {
    /// Deterministic idempotency key: plan id + index + content hash.
    public var id: String
    public var operation: PlannedOperation
    public var sourceID: SortlyID?
    public var state: StepState

    public init(id: String, operation: PlannedOperation, sourceID: SortlyID?, state: StepState = .pending) {
        self.id = id
        self.operation = operation
        self.sourceID = sourceID
        self.state = state
    }
}

public enum PlanConflict: Hashable, Sendable, Codable {
    /// Two new albums with the same title in the same folder.
    case duplicatePlannedTitle(title: String, folderPath: [String], sources: [SortlyID])
    /// An unrelated album with this title already exists in the target folder.
    case titleExistsInFolder(title: String, existing: CollectionID)
    case albumMissing(CollectionID)
    case albumNotEditable(CollectionID)
    case albumChangedSincePreview(CollectionID)
    case assetsUnavailable(count: Int)
    case writeAccessMissing

    /// Blocking conflicts prevent execution until the user decides again (prompt §7, Schritt 7/9).
    public var isBlocking: Bool {
        switch self {
        case .titleExistsInFolder: false
        default: true
        }
    }
}

/// Non-blocking information shown with the plan.
public enum PlanNote: Hashable, Sendable, Codable {
    case respectedManualRemovals(count: Int)
    case skippedDeletedByUser(SortlyID)
    case skippedRejected(SortlyID)
    case optionalItemsNotIncluded(count: Int)
}

public enum PlanStatus: String, Sendable, Codable {
    case draft, confirmed, running, completed, completedWithErrors, cancelled
}

/// A concrete, persisted change plan. Only confirmed plans are executed (prompt §16).
public struct ChangePlan: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var createdAt: Date
    public var confirmedAt: Date?
    public var status: PlanStatus
    /// Fingerprints of every existing collection the plan touches, taken at preview time.
    public var baseline: [CollectionID: String]
    /// Collection ids that existed at preview time (to recognize albums created by us).
    public var baselineCollectionIDs: Set<CollectionID>
    public var steps: [PlanStep]
    public var conflicts: [PlanConflict]
    public var notes: [PlanNote]
    /// Planned key → created collection id, filled during execution.
    public var resolvedKeys: [String: CollectionID]
    /// Set on an undo plan: the plan whose changes it takes back.
    public var reverts: SortlyID? = nil
    /// What execution really did, step by step (written before every library call, settled
    /// after it). Undo, the managed-album records, the result screen and the free-album count
    /// use it instead of the planned operations. Missing in plans saved by older versions.
    public var record: ExecutionRecord? = nil
    /// Albums this plan may delete only while they hold nothing but these media (undo and
    /// removal plans). An album that got other photos meanwhile is kept; only these leave it.
    public var deleteGuards: [CollectionID: Set<AssetID>]? = nil
    /// Set once everything that follows a run (managed albums, decisions, free albums) is
    /// stored. A finished plan without it is completed again at the next launch.
    public var finalizedAt: Date? = nil
    /// Set on a retry plan ("Erneut versuchen"): the plan whose unfinished steps it runs.
    public var retries: SortlyID? = nil
    /// Albums the retried plan created. Adding to them now does not use another free album.
    public var albumsFromRetriedPlan: Set<CollectionID>? = nil

    public var summary: PlanSummary { PlanSummary(self) }

    /// Albums this plan uses from the free allowance: new albums and extended existing ones,
    /// except albums an earlier run of the same changes created (counted with that run).
    /// `applied` counts what really happened, otherwise what is planned.
    public func freeAlbumUse(applied: Bool) -> Int {
        var newAlbums = 0
        var extended = Set<CollectionID>()
        for step in steps {
            let succeeded: Bool = if case .succeeded = step.state { true } else { false }
            switch step.operation {
            case .createAlbum:
                if !applied || succeeded { newAlbums += 1 }
            case .addAssets(.existing(let id), let assets):
                let added = applied ? (record?.media[step.id] ?? (succeeded ? assets : [])) : assets
                if !added.isEmpty { extended.insert(id) }
            default:
                break
            }
        }
        return newAlbums + extended.subtracting(albumsFromRetriedPlan ?? []).count
    }
    /// What really happened (planned counts for plans from older versions).
    public var appliedSummary: PlanSummary { PlanSummary(applied: self) }
}

/// The journal of what a plan really changed.
public struct ExecutionRecord: Hashable, Sendable, Codable {
    /// Step id → media the step added (addAssets) or removed (removeAssets, or our media
    /// taken out of an album that was kept instead of deleted). While a step id is in
    /// `unverified` this is the intent written before the library call; afterwards it is
    /// exactly what the library shows changed.
    public var media: [String: [AssetID]] = [:]
    /// Steps whose library call may or may not have happened (interrupted, or the read-back failed).
    public var unverified: Set<String> = []
    /// Planned keys whose album or folder was found after an interruption instead of being
    /// created verifiably by this run. Albumist cannot prove it made them, so it never
    /// deletes them; undo only takes its own media back out.
    public var adoptedKeys: Set<String> = []
    /// Albums this plan deleted, with what they held, so the deletion can be taken back.
    public var deletedAlbums: [CollectionID: DeletedAlbumRecord] = [:]
    /// Step id → number of planned media that were no longer in the library.
    public var unavailable: [String: Int] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case media, unverified, adoptedKeys, deletedAlbums, unavailable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decodeIfPresent([String: [AssetID]].self, forKey: .media) ?? [:]
        unverified = try c.decodeIfPresent(Set<String>.self, forKey: .unverified) ?? []
        adoptedKeys = try c.decodeIfPresent(Set<String>.self, forKey: .adoptedKeys) ?? []
        deletedAlbums = try c.decodeIfPresent([CollectionID: DeletedAlbumRecord].self, forKey: .deletedAlbums) ?? [:]
        unavailable = try c.decodeIfPresent([String: Int].self, forKey: .unavailable) ?? [:]
    }

    /// Writes the intent of a step before its library call.
    mutating func begin(_ step: String, _ assets: [AssetID]) {
        media[step] = assets
        unverified.insert(step)
    }

    /// Replaces the intent with what really changed.
    mutating func settle(_ step: String, _ assets: [AssetID]) {
        media[step] = assets
        unverified.remove(step)
    }
}

public struct DeletedAlbumRecord: Hashable, Sendable, Codable {
    public var title: String
    public var parentID: CollectionID?
    public var members: [AssetID]
}

/// What the final preview shows (prompt §7, Schritt 8).
public struct PlanSummary: Hashable, Sendable {
    public var newFolders = 0
    public var newAlbums = 0
    public var extendedAlbums = 0
    public var renamedCollections = 0
    public var movedCollections = 0
    public var removedMemberships = 0
    public var deletedContainers = 0
    /// Number of different media affected.
    public var distinctAssets = 0
    /// Number of album assignments (one photo in three albums = 3).
    public var totalAssignments = 0
    /// Planned media that were no longer in the library (applied summaries only).
    public var unavailableAssets = 0
    /// Steps that did not complete (applied summaries only).
    public var failedSteps = 0
    /// Structural guarantees – there is no operation type that could change these.
    public let originalsDeleted = 0
    public let originalCopiesCreated = 0

    /// What really happened in an executed plan: only verified changes count. Plans from
    /// versions without an execution record fall back to their succeeded steps.
    public init(applied plan: ChangePlan) {
        let record = plan.record
        var distinct = Set<AssetID>()
        var extended = Set<CollectionID>()
        for step in plan.steps {
            let succeeded: Bool = if case .succeeded = step.state { true } else { false }
            if case .failed = step.state { failedSteps += 1 }
            switch step.operation {
            case .createFolder: if succeeded { newFolders += 1 }
            case .createAlbum: if succeeded { newAlbums += 1 }
            case .addAssets(let album, let assets):
                let added = record?.media[step.id] ?? (succeeded ? assets : [])
                distinct.formUnion(added)
                totalAssignments += added.count
                if case .existing(let id) = album, !added.isEmpty { extended.insert(id) }
                unavailableAssets += record?.unavailable[step.id] ?? 0
            case .renameCollection: if succeeded { renamedCollections += 1 }
            case .moveCollection: if succeeded { movedCollections += 1 }
            case .removeAssets(_, let assets):
                removedMemberships += (record?.media[step.id] ?? (succeeded ? assets : [])).count
            case .deleteCollection: if succeeded { deletedContainers += 1 }
            }
        }
        extendedAlbums = extended.count
        distinctAssets = distinct.count
    }

    public init(_ plan: ChangePlan) {
        var distinct = Set<AssetID>()
        var extended = Set<CollectionID>()
        for step in plan.steps {
            switch step.operation {
            case .createFolder: newFolders += 1
            case .createAlbum: newAlbums += 1
            case .addAssets(let album, let assets):
                distinct.formUnion(assets)
                totalAssignments += assets.count
                if case .existing(let id) = album { extended.insert(id) }
            case .renameCollection: renamedCollections += 1
            case .moveCollection: movedCollections += 1
            case .removeAssets(_, let assets): removedMemberships += assets.count
            case .deleteCollection: deletedContainers += 1
            }
        }
        extendedAlbums = extended.count
        distinctAssets = distinct.count
    }
}
