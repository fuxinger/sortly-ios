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

/// The complete, closed set of operations SORTLY can perform (prompt §16.1).
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

    public var summary: PlanSummary { PlanSummary(self) }
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
    /// Structural guarantees – there is no operation type that could change these.
    public let originalsDeleted = 0
    public let originalCopiesCreated = 0

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
