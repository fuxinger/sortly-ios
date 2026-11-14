import Foundation

/// The only write interface to the photo library. Implemented with PhotoKit in the app
/// and in memory for tests. It has no method that could delete or alter original media.
public protocol PhotoLibraryWriting: Sendable {
    func canWrite() async -> Bool
    func currentInventory() async throws -> CollectionInventory
    /// Which of the given assets still exist and are accessible.
    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID>
    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID
    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID
    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws
    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws
    func renameCollection(_ id: CollectionID, to title: String) async throws
    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws
    /// Removes an album or folder container. Media stay in the library.
    func deleteCollection(_ id: CollectionID) async throws
    /// Removes several albums and folders in one request. Photos asks the user before it
    /// deletes albums, once per request: one request means one question instead of one per album.
    func deleteCollections(_ ids: [CollectionID]) async throws
    /// One album or folder, read on its own. Execution checks every step this way instead of
    /// reading the whole album list (minutes saved on large plans).
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot?
}

extension PhotoLibraryWriting {
    public func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        try await currentInventory()[id]
    }

    /// One by one: albums first, then folders from the inside out.
    public func deleteCollections(_ ids: [CollectionID]) async throws {
        let inventory = try await currentInventory()
        func depth(_ id: CollectionID) -> Int {
            var d = 0, cursor = inventory[id]?.parentID
            while let parent = cursor { d += 1; cursor = inventory[parent]?.parentID }
            return d
        }
        let ordered = ids.sorted { a, b in
            let fa = inventory[a]?.kind == .folder, fb = inventory[b]?.kind == .folder
            if fa != fb { return !fa }
            return depth(a) > depth(b)
        }
        for id in ordered { try await deleteCollection(id) }
    }
}

/// Persists plans so execution can resume after a crash (prompt §16.3).
public protocol ChangePlanStoring: Sendable {
    func save(_ plan: ChangePlan) async throws
}

public enum ExecutionEvent: Sendable, Hashable {
    case stepStarted(index: Int, total: Int)
    case stepFinished(index: Int, state: StepState)
}

/// Validates a plan against the current library right before execution (prompt §16.2).
public struct PlanValidator: Sendable {
    public init() {}

    public func validate(_ plan: ChangePlan, current: CollectionInventory, canWrite: Bool, availableAssets: Set<AssetID>) -> [PlanConflict] {
        var conflicts: [PlanConflict] = []
        if !canWrite { conflicts.append(.writeAccessMissing) }
        for (id, fingerprint) in plan.baseline.sorted(by: { $0.key < $1.key }) {
            guard let c = current[id] else { conflicts.append(.albumMissing(id)); continue }
            if c.kind != .folder && !c.isEditableAlbum { conflicts.append(.albumNotEditable(id)) }
            if c.fingerprint != fingerprint { conflicts.append(.albumChangedSincePreview(id)) }
        }
        var requested = Set<AssetID>()
        for step in plan.steps where !step.state.isFinished {
            if case .addAssets(_, let assets) = step.operation { requested.formUnion(assets) }
        }
        let unavailable = requested.subtracting(availableAssets).count
        if unavailable > 0 { conflicts.append(.assetsUnavailable(count: unavailable)) }
        return conflicts
    }
}

/// Executes confirmed plans step by step with journaling, verification and safe resume.
///
/// Guarantees (tested in `ExecutionTests`):
/// - every step is persisted as `running` before it touches the library;
/// - a step found `running` after a restart is reconciled with the real library first,
///   so a repeated run never creates duplicate albums (Scenario J);
/// - success is recorded only after the change was read back and verified.
public actor ChangeExecutor {
    private let library: any PhotoLibraryWriting
    private let store: any ChangePlanStoring
    private let clock: @Sendable () -> Date

    public init(library: any PhotoLibraryWriting, store: any ChangePlanStoring, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.store = store
        self.clock = clock
    }

    public enum ExecutionError: Error, Equatable {
        case notConfirmed
        case blocked([PlanConflict])
    }

    /// Runs (or resumes) a plan. `onEvent` reports progress for the UI.
    public func execute(_ input: ChangePlan, onEvent: @Sendable (ExecutionEvent) -> Void = { _ in }) async throws -> ChangePlan {
        guard input.confirmedAt != nil, input.status != .draft, input.status != .cancelled else { throw ExecutionError.notConfirmed }
        var plan = input

        let inventory = try await library.currentInventory()
        var requested: [AssetID] = []
        for step in plan.steps where !step.state.isFinished {
            if case .addAssets(_, let assets) = step.operation { requested.append(contentsOf: assets) }
        }
        let available = try await library.availableAssets(requested)
        // Fingerprint checks only apply before the first step ran; afterwards our own
        // changes legitimately alter the fingerprints.
        let started = plan.steps.contains { $0.state != .pending }
        let conflicts = PlanValidator()
            .validate(started ? plan.withoutBaseline : plan, current: inventory, canWrite: await library.canWrite(), availableAssets: available)
            .filter { if case .assetsUnavailable = $0 { return false }; return true }
        if !conflicts.isEmpty {
            throw ExecutionError.blocked(conflicts)
        }

        plan.status = .running
        try await store.save(plan)

        for index in plan.steps.indices {
            if Task.isCancelled { break }
            let step = plan.steps[index]
            if case .succeeded = step.state { continue }
            if case .skipped = step.state { continue }
            if case .failed = step.state { continue }

            // Consecutive deletions run as one request (one question from Photos, not one per album).
            if case .deleteCollection = step.operation {
                var batch = [index]
                var next = index + 1
                while next < plan.steps.count, case .deleteCollection = plan.steps[next].operation, !plan.steps[next].state.isFinished {
                    batch.append(next)
                    next += 1
                }
                try await deleteBatch(batch, plan: &plan, onEvent: onEvent)
                continue
            }

            onEvent(.stepStarted(index: index, total: plan.steps.count))
            let wasRunning: Bool
            if case .running = step.state { wasRunning = true } else { wasRunning = false }

            if !wasRunning {
                plan.steps[index].state = .running(startedAt: clock())
                try await store.save(plan)
            }

            let state: StepState
            do {
                state = try await perform(step.operation, plan: &plan, reconcile: wasRunning, available: available)
            } catch {
                state = .failed(reason: String(describing: error))
            }
            plan.steps[index].state = state
            if case .succeeded(let created?, _) = state, let key = step.operation.plannedKey {
                plan.resolvedKeys[key] = created
            }
            try await store.save(plan)
            onEvent(.stepFinished(index: index, state: state))
        }

        let finished = plan.steps.allSatisfy(\.state.isFinished)
        let anyFailed = plan.steps.contains { if case .failed = $0.state { return true }; return false }
        plan.status = finished ? (anyFailed ? .completedWithErrors : .completed) : .running
        try await store.save(plan)
        return plan
    }

    private func resolve(_ ref: FolderRef, _ plan: ChangePlan) -> CollectionID?? {
        switch ref {
        case .topLevel: return .some(nil)
        case .existing(let id): return .some(id)
        case .planned(let key): return plan.resolvedKeys[key].map { .some($0) } ?? nil
        }
    }

    private func resolve(_ ref: AlbumRef, _ plan: ChangePlan) -> CollectionID? {
        switch ref {
        case .existing(let id): id
        case .planned(let key): plan.resolvedKeys[key]
        }
    }

    private func perform(_ op: PlannedOperation, plan: inout ChangePlan, reconcile: Bool, available: Set<AssetID>) async throws -> StepState {
        let now = clock()
        switch op {
        case .createFolder(_, let title, let parentRef), .createAlbum(_, let title, let parentRef):
            let isFolder: Bool = if case .createFolder = op { true } else { false }
            guard let parent = resolve(parentRef, plan) else {
                return .skipped(reason: "parent folder was not created")
            }
            if reconcile, let adopted = try await findCreatedByUs(title: title, parent: parent, folder: isFolder, plan: plan) {
                return .succeeded(createdID: adopted, verifiedAt: now)
            }
            // The folder may have been deleted meanwhile (e.g. on another device): never fall
            // back to the top level of the library.
            if let parent, try await library.collection(parent) == nil {
                return .failed(reason: "parent folder no longer exists")
            }
            let id = isFolder
                ? try await library.createFolder(title: title, parent: parent)
                : try await library.createAlbum(title: title, parent: parent)
            guard let created = try await library.collection(id), created.title == title, created.parentID == parent else {
                return .failed(reason: "created collection could not be verified")
            }
            return .succeeded(createdID: id, verifiedAt: now)

        case .addAssets(let albumRef, let assets):
            guard let albumID = resolve(albumRef, plan) else { return .skipped(reason: "target album was not created") }
            guard let album = try await library.collection(albumID) else { return .failed(reason: "album no longer exists") }
            // Idempotent: only add what is missing and still available.
            let missing = assets.filter { !album.assetIDs.contains($0) && available.contains($0) }
            if !missing.isEmpty { try await library.addAssets(missing, to: albumID) }
            let expected = Set(assets).intersection(available)
            guard let verified = try await library.collection(albumID), expected.isSubset(of: verified.assetIDs) else {
                return .failed(reason: "added media could not be verified")
            }
            if expected.count < assets.count {
                return .succeeded(createdID: nil, verifiedAt: now) // unavailable media are reported by the validator
            }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .renameCollection(let id, _, let to):
            guard let c = try await library.collection(id) else { return .failed(reason: "album no longer exists") }
            if c.title != to { try await library.renameCollection(id, to: to) }
            guard try await library.collection(id)?.title == to else { return .failed(reason: "rename could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .moveCollection(let id, let from, let toRef):
            guard let target = resolve(toRef, plan) else { return .skipped(reason: "target folder was not created") }
            guard let c = try await library.collection(id) else { return .failed(reason: "album no longer exists") }
            if c.parentID != target { try await library.moveCollection(id, from: from, to: target) }
            guard try await library.collection(id)?.parentID == target else { return .failed(reason: "move could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .removeAssets(let albumID, let assets):
            guard let album = try await library.collection(albumID) else { return .failed(reason: "album no longer exists") }
            let present = assets.filter { album.assetIDs.contains($0) }
            if !present.isEmpty { try await library.removeAssets(present, from: albumID) }
            guard let after = try await library.collection(albumID), after.assetIDs.isDisjoint(with: assets) else {
                return .failed(reason: "removal could not be verified")
            }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .deleteCollection(let id, _):
            let inventory = try await library.currentInventory()
            // Never delete a folder that is not empty: Photos would delete its contents too.
            if inventory.collections.values.contains(where: { $0.parentID == id }) {
                return .failed(reason: "folder is not empty")
            }
            if inventory[id] != nil { try await library.deleteCollection(id) }
            guard (try await library.currentInventory())[id] == nil else { return .failed(reason: "deletion could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)
        }
    }

    /// Deletes the albums and folders of several steps together. A folder goes only if
    /// everything inside it goes too: Photos deletes a folder's contents with it.
    private func deleteBatch(_ indices: [Int], plan: inout ChangePlan, onEvent: @Sendable (ExecutionEvent) -> Void) async throws {
        let now = clock()
        for i in indices {
            onEvent(.stepStarted(index: i, total: plan.steps.count))
            if case .running = plan.steps[i].state { continue }
            plan.steps[i].state = .running(startedAt: now)
        }
        try await store.save(plan)

        var targets: [Int: CollectionID] = [:]
        for i in indices {
            if case .deleteCollection(let id, _) = plan.steps[i].operation { targets[i] = id }
        }
        var states: [Int: StepState] = [:]
        var before = CollectionInventory([])
        var allowed = Set<CollectionID>()
        do {
            before = try await library.currentInventory()
            let requested = Set(targets.values)
            var changed = true
            while changed {
                changed = false
                for id in requested.sorted() where !allowed.contains(id) && before[id] != nil {
                    let inside = before.collections.values.filter { $0.parentID == id }
                    if inside.allSatisfy({ allowed.contains($0.id) }) {
                        allowed.insert(id)
                        changed = true
                    }
                }
            }
            if !allowed.isEmpty { try await library.deleteCollections(allowed.sorted()) }
        } catch {
            for i in indices { states[i] = .failed(reason: String(describing: error)) }
        }
        // Read back: success only for what is really gone.
        if let after = try? await library.currentInventory() {
            for (i, id) in targets {
                if after[id] == nil {
                    states[i] = .succeeded(createdID: nil, verifiedAt: now)
                } else if states[i] == nil {
                    states[i] = .failed(reason: allowed.contains(id) ? "deletion could not be verified" : "folder is not empty")
                }
            }
        }
        for i in indices { plan.steps[i].state = states[i] ?? .failed(reason: "deletion could not be verified") }
        try await store.save(plan)
        for i in indices { onEvent(.stepFinished(index: i, state: plan.steps[i].state)) }
    }

    /// After a crash: was the collection already created by this plan?
    private func findCreatedByUs(title: String, parent: CollectionID?, folder: Bool, plan: ChangePlan) async throws -> CollectionID? {
        let inventory = try await library.currentInventory()
        let alreadyResolved = Set(plan.resolvedKeys.values)
        return inventory.collections.values
            .filter { ($0.kind == .folder) == folder && $0.title == title && $0.parentID == parent }
            .filter { !plan.baselineCollectionIDs.contains($0.id) && !alreadyResolved.contains($0.id) }
            .map(\.id)
            .sorted()
            .first
    }
}

extension PlannedOperation {
    var plannedKey: String? {
        switch self {
        case .createFolder(let key, _, _), .createAlbum(let key, _, _): key
        default: nil
        }
    }
}

extension ChangePlan {
    var withoutBaseline: ChangePlan {
        var copy = self
        copy.baseline = [:]
        return copy
    }
}

/// Builds a plan that safely reverts the changes of an executed plan (prompt §16.5).
/// Manual changes made in between are respected: user-added media are never removed and
/// albums the user filled with own content are not deleted.
public struct UndoPlanner: Sendable {
    public init() {}

    public func undoPlan(for executed: ChangePlan, current: CollectionInventory, id: SortlyID = SortlyID(), now: Date = Date()) -> ChangePlan {
        var steps: [PlanStep] = []
        var notes: [PlanNote] = []
        func append(_ op: PlannedOperation) {
            steps.append(PlanStep(id: "\(id.rawValue)-\(steps.count)-\(StableHash.hex(String(describing: op)).prefix(12))", operation: op, sourceID: executed.id))
        }

        var addedByUs: [CollectionID: Set<AssetID>] = [:]
        var createdAlbums: [CollectionID] = []
        var createdFolders: [CollectionID] = []
        for step in executed.steps {
            guard case .succeeded(let created, _) = step.state else { continue }
            switch step.operation {
            case .createAlbum: if let created { createdAlbums.append(created) }
            case .createFolder: if let created { createdFolders.append(created) }
            case .addAssets(let ref, let assets):
                let albumID: CollectionID? = switch ref {
                case .existing(let id): id
                case .planned(let key): executed.resolvedKeys[key]
                }
                if let albumID { addedByUs[albumID, default: []].formUnion(assets) }
            default: break
            }
        }

        // 1. Revert renames and moves if nobody changed them again.
        for step in executed.steps.reversed() {
            guard case .succeeded = step.state else { continue }
            switch step.operation {
            case .renameCollection(let cid, let from, let to):
                if current[cid]?.title == to { append(.renameCollection(cid, from: to, to: from)) }
            case .moveCollection(let cid, let from, let toRef):
                let to: CollectionID? = switch toRef {
                case .topLevel: nil
                case .existing(let id): id
                case .planned(let key): executed.resolvedKeys[key]
                }
                if let c = current[cid], c.parentID == to {
                    append(.moveCollection(cid, from: to, to: from.map { .existing($0) } ?? .topLevel))
                }
            default: break
            }
        }

        // 2. Created albums: delete only if they contain nothing the user added himself.
        //    Deletions are collected and run together at the end (one question from Photos).
        let createdSet = Set(createdAlbums)
        var albumDeletions: [PlannedOperation] = []
        for albumID in createdAlbums {
            guard let album = current[albumID] else { continue }
            let ours = addedByUs[albumID] ?? []
            if album.assetIDs.isSubset(of: ours) {
                albumDeletions.append(.deleteCollection(albumID, title: album.title))
            } else {
                let removable = album.assetIDs.intersection(ours).sorted()
                if !removable.isEmpty { append(.removeAssets(album: albumID, assets: removable)) }
                notes.append(.respectedManualRemovals(count: album.assetIDs.subtracting(ours).count))
            }
        }
        // 3. Extended existing albums: remove only our additions that are still there.
        for (albumID, ours) in addedByUs.sorted(by: { $0.key < $1.key }) where !createdSet.contains(albumID) {
            guard let album = current[albumID] else { continue }
            let removable = album.assetIDs.intersection(ours).sorted()
            if !removable.isEmpty { append(.removeAssets(album: albumID, assets: removable)) }
        }
        albumDeletions.forEach(append)
        // 4. Folders we created, deepest first, only if nothing else is left inside. Deleting a
        //    folder in Photos also deletes everything in it, so a folder that still holds any
        //    album or folder (the user's own, or one from a later plan) is always kept, and
        //    so are all folders above it.
        var goingAway = Set(steps.compactMap { if case .deleteCollection(let id, _) = $0.operation { return id }; return nil })
        for folderID in createdFolders.reversed() {
            guard let folder = current[folderID] else { continue }
            let keepsSomething = current.collections.values.contains { $0.parentID == folderID && !goingAway.contains($0.id) }
            if !keepsSomething {
                append(.deleteCollection(folderID, title: folder.title))
                goingAway.insert(folderID)
            }
        }

        return ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: [:],
            baselineCollectionIDs: Set(current.collections.keys),
            steps: steps,
            conflicts: [],
            notes: notes,
            resolvedKeys: [:],
            reverts: executed.id
        )
    }
}
