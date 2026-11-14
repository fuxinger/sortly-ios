import Foundation

/// The change receipt of an executed plan (I01): what Albumist really changed, album by album,
/// read from the execution journal, and what it cannot have changed. Planned changes that the
/// library never confirmed are counted apart, never as done.
public struct PlanReceipt: Hashable, Sendable {
    public struct Album: Hashable, Sendable, Identifiable {
        public enum Change: Hashable, Sendable {
            /// Created by this plan.
            case created
            /// Found after an interruption instead of being created verifiably (kept by undo).
            case adopted
            /// An album that existed before; photos were added.
            case extended
            /// Photos were taken out (merge or undo).
            case reduced
            /// The album container was removed (its photos stay in the library).
            case deleted
        }

        public var id: String
        public var title: String
        /// Folder titles from the top, as at the time of the plan.
        public var folderPath: [String]
        public var change: Change
        /// Distinct photos really added.
        public var added: Int
        /// Album memberships really removed.
        public var removed: Int
        /// Planned photos that were no longer in the library.
        public var unavailable: Int
        /// A step for this album failed or was skipped.
        public var failed: Bool
        /// A step for this album may or may not have happened (the library did not confirm it).
        public var unconfirmed: Bool
        public var coverAssetID: AssetID?
    }

    public var planID: SortlyID
    public var isUndo: Bool
    public var startedAt: Date
    /// When the results were stored; nil for plans from versions without that time.
    public var finishedAt: Date?
    public var albums: [Album]
    /// Confirmed totals. Photos count once even when they went into several albums.
    public var photosAdded = 0
    public var assignmentsAdded = 0
    public var membershipsRemoved = 0
    public var albumsCreated = 0
    public var albumsExtended = 0
    /// Albums and folders removed (their photos stay in the library).
    public var containersDeleted = 0
    public var renamed = 0
    public var moved = 0
    public var unavailablePhotos = 0
    public var failedSteps = 0
    /// There is no operation that deletes, edits or copies an original (`PlannedOperation`),
    /// so these are zero by construction, not by counting.
    public let originalsDeleted = 0
    public let originalsEdited = 0
    public let originalCopiesCreated = 0
    /// Titles of the folders the plan created.
    public var createdFolders: [String]
    /// Distinct reasons of failed or skipped steps.
    public var problems: [String]
    /// Steps whose outcome the library did not confirm.
    public var unconfirmedSteps: Int

    /// Built from the journal (`ChangePlan.record`); plans from versions without a journal
    /// fall back to their succeeded steps. Steps that were not done add nothing.
    public init(plan: ChangePlan, inventory: CollectionInventory) {
        planID = plan.id
        isUndo = plan.reverts != nil
        startedAt = plan.confirmedAt ?? plan.createdAt
        finishedAt = plan.finalizedAt
        let record = plan.record
        unconfirmedSteps = record?.unverified.count ?? 0

        var folderTitles: [String: (title: String, parent: FolderRef)] = [:]
        var created: [String] = []
        var albumKeys: [String: (title: String, parent: FolderRef)] = [:]
        var order: [String] = []
        var lines: [String: Album] = [:]
        var problems: [String] = []
        var addedPhotos = Set<AssetID>()
        var extended = Set<CollectionID>()

        func existingPath(_ id: CollectionID?) -> [String] {
            var titles: [String] = []
            var current = id
            while let c = current, let node = inventory[c], titles.count < 32 {
                titles.insert(node.title, at: 0)
                current = node.parentID
            }
            return titles
        }
        func path(_ folder: FolderRef, depth: Int = 0) -> [String] {
            switch folder {
            case .topLevel: return []
            case .existing(let id): return existingPath(id)
            case .planned(let key):
                guard let f = folderTitles[key], depth < 32 else { return [] }
                return path(f.parent, depth: depth + 1) + [f.title]
            }
        }
        func line(_ id: String, title: @autoclosure () -> String, folder: @autoclosure () -> [String], change: Album.Change) -> Album {
            if let existing = lines[id] { return existing }
            order.append(id)
            return Album(id: id, title: title(), folderPath: folder(), change: change, added: 0, removed: 0,
                         unavailable: 0, failed: false, unconfirmed: false, coverAssetID: nil)
        }
        func existingTitle(_ id: CollectionID) -> String {
            inventory[id]?.title ?? record?.deletedAlbums[id]?.title ?? ""
        }

        for step in plan.steps {
            let succeeded: Bool = if case .succeeded = step.state { true } else { false }
            let failed: Bool
            switch step.state {
            case .failed(let reason), .skipped(let reason):
                failed = true
                if !reason.isEmpty && !problems.contains(reason) { problems.append(reason) }
            default:
                failed = false
            }
            if failed { failedSteps += 1 }
            let unconfirmed = record?.unverified.contains(step.id) ?? false
            // Only what the library confirmed counts as done.
            let done = succeeded && !unconfirmed

            switch step.operation {
            case let .createFolder(key, title, parent):
                folderTitles[key] = (title, parent)
                if done && !(record?.adoptedKeys.contains(key) ?? false) { created.append(title) }

            case let .createAlbum(key, title, parent):
                albumKeys[key] = (title, parent)
                guard succeeded || failed || unconfirmed else { continue }
                let adopted = record?.adoptedKeys.contains(key) == true
                if done && !adopted { albumsCreated += 1 }
                var album = line("planned:" + key, title: title, folder: path(parent), change: adopted ? .adopted : .created)
                album.failed = album.failed || failed
                album.unconfirmed = album.unconfirmed || unconfirmed
                lines[album.id] = album

            case let .addAssets(ref, assets):
                let added = unconfirmed ? [] : record?.media[step.id] ?? (succeeded ? assets : [])
                let unavailable = record?.unavailable[step.id] ?? 0
                addedPhotos.formUnion(added)
                assignmentsAdded += added.count
                unavailablePhotos += unavailable
                guard !added.isEmpty || failed || unconfirmed || unavailable > 0 else { continue }
                var album: Album
                switch ref {
                case .planned(let key):
                    let planned = albumKeys[key]
                    album = line("planned:" + key, title: planned?.title ?? "", folder: planned.map { path($0.parent) } ?? [],
                                 change: record?.adoptedKeys.contains(key) == true ? .adopted : .created)
                case .existing(let id):
                    album = line(id.rawValue, title: existingTitle(id), folder: existingPath(inventory[id]?.parentID), change: .extended)
                    if !added.isEmpty { extended.insert(id) }
                }
                album.added += Set(added).count
                album.unavailable += unavailable
                if album.coverAssetID == nil { album.coverAssetID = added.first }
                album.failed = album.failed || failed
                album.unconfirmed = album.unconfirmed || unconfirmed
                lines[album.id] = album

            case let .removeAssets(id, assets):
                let removed = unconfirmed ? [] : record?.media[step.id] ?? (succeeded ? assets : [])
                membershipsRemoved += removed.count
                guard !removed.isEmpty || failed || unconfirmed else { continue }
                var album = line(id.rawValue, title: existingTitle(id), folder: existingPath(inventory[id]?.parentID), change: .reduced)
                album.removed += removed.count
                album.failed = album.failed || failed
                album.unconfirmed = album.unconfirmed || unconfirmed
                lines[album.id] = album

            case let .deleteCollection(id, title):
                guard succeeded || failed || unconfirmed else { continue }
                var album = line(id.rawValue, title: title, folder: [], change: .deleted)
                if done {
                    album.change = .deleted
                    containersDeleted += 1
                }
                album.failed = album.failed || failed
                album.unconfirmed = album.unconfirmed || unconfirmed
                lines[album.id] = album

            case .renameCollection:
                if done { renamed += 1 }
            case .moveCollection:
                if done { moved += 1 }
            }
        }
        albums = order.compactMap { lines[$0] }
        photosAdded = addedPhotos.count
        albumsExtended = extended.count
        createdFolders = created
        self.problems = problems
    }

    /// Whether everything the plan set out to do was done and confirmed.
    public var isComplete: Bool { failedSteps == 0 && unconfirmedSteps == 0 && problems.isEmpty }
}
