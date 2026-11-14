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
/// Guarantees (tested in `PlanningExecutionTests` and `ExecutionSafetyTests`):
/// - every step is persisted as `running` before it touches the library, together with the
///   media it is about to add or remove (the intent);
/// - a step found `running` after a restart is reconciled with the real library first:
///   nothing is created twice (Scenario J), media the user took out after an interrupted
///   add stay out, and an album found by name is never claimed as Albumist's own;
/// - success is recorded only after the change was read back and verified, and the record
///   keeps exactly what changed, so undo and the managed-album list never act on media the
///   user added or removed by hand;
/// - an album is deleted only while it holds nothing but the media its guard allows.
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
        if plan.record == nil { plan.record = ExecutionRecord() }

        let inventory = try await library.currentInventory()
        var requested: [AssetID] = []
        for step in plan.steps where !step.state.isFinished {
            if case .addAssets(_, let assets) = step.operation { requested.append(contentsOf: assets) }
        }
        let available = try await library.availableAssets(requested)
        // Fingerprint checks only apply before the first step ran; afterwards our own
        // changes legitimately alter the fingerprints. Interrupted steps are reconciled one
        // by one instead (see `perform`).
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
            if step.state.isFinished { continue }

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

            // Adding and removing media journal `running` together with their intent (in
            // `perform`); the other steps are journaled here.
            if !wasRunning && !step.operation.changesMembership {
                plan.steps[index].state = .running(startedAt: clock())
                try await store.save(plan)
            }

            let state: StepState
            do {
                state = try await perform(index, plan: &plan, reconcile: wasRunning, available: available)
            } catch {
                await settleAfterError(step, plan: &plan)
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

    /// Settles every step an interruption left `running`, by reading the library only (it
    /// writes nothing). Used before an interrupted plan is taken back, so the undo sees what
    /// the interrupted run really did (an album created or media added right before the app
    /// was closed). Steps that never started stay as they are.
    public func reconcileInterrupted(_ input: ChangePlan) async throws -> ChangePlan {
        var plan = input
        if plan.record == nil { plan.record = ExecutionRecord() }
        let inventory = try await library.currentInventory()
        let now = clock()
        for index in plan.steps.indices {
            guard case .running = plan.steps[index].state else { continue }
            let step = plan.steps[index]
            var state: StepState = .failed(reason: "interrupted")
            switch step.operation {
            case .createFolder(let key, let title, let parentRef), .createAlbum(let key, let title, let parentRef):
                let isFolder: Bool = if case .createFolder = step.operation { true } else { false }
                if let parent = resolve(parentRef, plan),
                   let found = adoptionCandidate(title: title, parent: parent, folder: isFolder, plan: plan, inventory: inventory) {
                    plan.resolvedKeys[key] = found
                    plan.record?.adoptedKeys.insert(key)
                    state = .succeeded(createdID: found, verifiedAt: now)
                }
            case .addAssets(let ref, _):
                if let albumID = resolve(ref, plan), let album = inventory[albumID], let intent = plan.record?.media[step.id] {
                    let arrived = intent.filter { album.assetIDs.contains($0) }
                    plan.record?.settle(step.id, arrived)
                    if !arrived.isEmpty { state = .succeeded(createdID: nil, verifiedAt: now) }
                }
            case .removeAssets(let albumID, _):
                if let album = inventory[albumID], let intent = plan.record?.media[step.id] {
                    let gone = intent.filter { !album.assetIDs.contains($0) }
                    plan.record?.settle(step.id, gone)
                    if !gone.isEmpty { state = .succeeded(createdID: nil, verifiedAt: now) }
                }
            case .renameCollection(let id, _, let to):
                if inventory[id]?.title == to { state = .succeeded(createdID: nil, verifiedAt: now) }
            case .moveCollection(let id, _, let toRef):
                if let target = resolve(toRef, plan), let c = inventory[id], c.parentID == target {
                    state = .succeeded(createdID: nil, verifiedAt: now)
                }
            case .deleteCollection(let id, _):
                if inventory[id] == nil {
                    state = .succeeded(createdID: nil, verifiedAt: now)
                } else {
                    plan.record?.deletedAlbums[id] = nil
                }
            }
            plan.steps[index].state = state
        }
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

    private func perform(_ index: Int, plan: inout ChangePlan, reconcile: Bool, available: Set<AssetID>) async throws -> StepState {
        let now = clock()
        let step = plan.steps[index]
        switch step.operation {
        case .createFolder(let key, let title, let parentRef), .createAlbum(let key, let title, let parentRef):
            let isFolder: Bool = if case .createFolder = step.operation { true } else { false }
            guard let parent = resolve(parentRef, plan) else {
                return .skipped(reason: "parent folder was not created")
            }
            if reconcile {
                // The app stopped while this was being created. A collection with the same
                // title in the same place is not proof that Albumist made it (the user may
                // have made one meanwhile). Only a single, still empty candidate is taken
                // over, and it is marked as adopted: undo will never delete it.
                let inventory = try await library.currentInventory()
                let same = inventory.collections.values.filter {
                    ($0.kind == .folder) == isFolder && $0.title == title && $0.parentID == parent
                        && !plan.baselineCollectionIDs.contains($0.id) && !Set(plan.resolvedKeys.values).contains($0.id)
                }
                if let found = adoptionCandidate(title: title, parent: parent, folder: isFolder, plan: plan, inventory: inventory) {
                    plan.record?.adoptedKeys.insert(key)
                    return .succeeded(createdID: found, verifiedAt: now)
                }
                if !same.isEmpty {
                    return .failed(reason: "a collection with this title appeared meanwhile")
                }
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
            if reconcile, plan.record?.unverified.contains(step.id) == true, let intent = plan.record?.media[step.id] {
                let arrived = intent.filter { album.assetIDs.contains($0) }
                if intent.isEmpty || !arrived.isEmpty {
                    // The interrupted request went through (a Photos change is all or nothing),
                    // or there was nothing to add. Whatever is missing now was taken out by
                    // the user afterwards and stays out.
                    plan.record?.settle(step.id, arrived)
                    return .succeeded(createdID: nil, verifiedAt: now)
                }
            }
            // Idempotent: only add what is missing and still available.
            let missing = assets.filter { !album.assetIDs.contains($0) && available.contains($0) }
            let unavailable = assets.count - assets.filter { available.contains($0) }.count
            if unavailable > 0 { plan.record?.unavailable[step.id] = unavailable }
            plan.record?.begin(step.id, missing)
            plan.steps[index].state = .running(startedAt: now)
            try await store.save(plan)
            if !missing.isEmpty { try await library.addAssets(missing, to: albumID) }
            guard let verified = try await library.collection(albumID) else {
                plan.record?.settle(step.id, [])
                return .failed(reason: "album no longer exists")
            }
            let arrived = missing.filter { verified.assetIDs.contains($0) }
            plan.record?.settle(step.id, arrived)
            guard arrived.count == missing.count else { return .failed(reason: "added media could not be verified") }
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
            if reconcile, plan.record?.unverified.contains(step.id) == true, let intent = plan.record?.media[step.id] {
                let gone = intent.filter { !album.assetIDs.contains($0) }
                if intent.isEmpty || !gone.isEmpty {
                    // Went through before the interruption (or had nothing to do); media back
                    // in the album now were put there by the user and stay.
                    plan.record?.settle(step.id, gone)
                    return .succeeded(createdID: nil, verifiedAt: now)
                }
            }
            let present = assets.filter { album.assetIDs.contains($0) }
            plan.record?.begin(step.id, present)
            plan.steps[index].state = .running(startedAt: now)
            try await store.save(plan)
            if !present.isEmpty { try await library.removeAssets(present, from: albumID) }
            guard let after = try await library.collection(albumID) else {
                plan.record?.settle(step.id, [])
                return .failed(reason: "album no longer exists")
            }
            let gone = present.filter { !after.assetIDs.contains($0) }
            plan.record?.settle(step.id, gone)
            guard gone.count == present.count else { return .failed(reason: "removal could not be verified") }
            return .succeeded(createdID: nil, verifiedAt: now)

        case .deleteCollection:
            // Deletions always run through `deleteBatch` (guards, one request, read-back).
            try await deleteBatch([index], plan: &plan, onEvent: { _ in })
            return plan.steps[index].state
        }
    }

    /// A library call threw: whatever of the intent is visible in the library now did happen.
    /// If the album cannot even be read, the intent stays unverified (undo checks it again).
    private func settleAfterError(_ step: PlanStep, plan: inout ChangePlan) async {
        guard plan.record?.unverified.contains(step.id) == true, let intent = plan.record?.media[step.id] else { return }
        switch step.operation {
        case .addAssets(let ref, _):
            guard let albumID = resolve(ref, plan), let album = try? await library.collection(albumID) else { return }
            plan.record?.settle(step.id, intent.filter { album.assetIDs.contains($0) })
        case .removeAssets(let albumID, _):
            guard let album = try? await library.collection(albumID) else { return }
            plan.record?.settle(step.id, intent.filter { !album.assetIDs.contains($0) })
        default:
            break
        }
    }

    /// Deletes the albums and folders of several steps together. A folder goes only if
    /// everything inside it goes too: Photos deletes a folder's contents with it. An album
    /// with a delete guard goes only while it holds nothing but the guarded media; otherwise
    /// it stays and only those media leave it.
    private func deleteBatch(_ indices: [Int], plan: inout ChangePlan, onEvent: @Sendable (ExecutionEvent) -> Void) async throws {
        let now = clock()
        for i in indices {
            onEvent(.stepStarted(index: i, total: plan.steps.count))
            if case .running = plan.steps[i].state { continue }
            plan.steps[i].state = .running(startedAt: now)
        }

        var targets: [Int: CollectionID] = [:]
        for i in indices {
            if case .deleteCollection(let id, _) = plan.steps[i].operation { targets[i] = id }
        }
        var states: [Int: StepState] = [:]
        var allowed = Set<CollectionID>()
        var kept: [Int: (album: CollectionID, ours: [AssetID])] = [:]
        do {
            let before = try await library.currentInventory()
            for (i, id) in targets {
                guard let album = before[id], album.kind != .folder, let guarded = plan.deleteGuards?[id] else { continue }
                if !album.assetIDs.isSubset(of: guarded) {
                    kept[i] = (id, album.assetIDs.intersection(guarded).sorted())
                }
            }
            let keptIDs = Set(kept.values.map(\.album))
            let requested = Set(targets.values).subtracting(keptIDs)
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
            // What goes is written down first, so the deletion can be taken back later.
            for id in allowed {
                guard let c = before[id], c.kind != .folder else { continue }
                plan.record?.deletedAlbums[id] = DeletedAlbumRecord(title: c.title, parentID: c.parentID, members: c.assetIDs.sorted())
            }
            for (i, k) in kept {
                // An interrupted earlier attempt may already have taken some of them out.
                let stepID = plan.steps[i].id
                let earlier = plan.record?.unverified.contains(stepID) == true ? plan.record?.media[stepID] ?? [] : []
                plan.record?.begin(stepID, Array(Set(earlier).union(k.ours)).sorted())
            }
            try await store.save(plan)
            if !allowed.isEmpty { try await library.deleteCollections(allowed.sorted()) }
            for (_, k) in kept.sorted(by: { $0.key < $1.key }) where !k.ours.isEmpty {
                try await library.removeAssets(k.ours, from: k.album)
            }
        } catch {
            for i in indices { states[i] = .failed(reason: String(describing: error)) }
        }
        // Read back: success only for what is really gone.
        if let after = try? await library.currentInventory() {
            for (i, id) in targets {
                if let k = kept[i] {
                    let stepID = plan.steps[i].id
                    let intent = plan.record?.media[stepID] ?? k.ours
                    let gone = intent.filter { !(after[id]?.assetIDs.contains($0) ?? false) }
                    plan.record?.settle(stepID, gone)
                    if states[i] == nil {
                        states[i] = k.ours.allSatisfy({ !(after[id]?.assetIDs.contains($0) ?? false) })
                            ? .skipped(reason: "kept: the album holds photos added meanwhile; only Albumist's photos were taken out")
                            : .failed(reason: "removal could not be verified")
                    }
                } else if after[id] == nil {
                    states[i] = .succeeded(createdID: nil, verifiedAt: now)
                } else {
                    plan.record?.deletedAlbums[id] = nil
                    if states[i] == nil {
                        states[i] = .failed(reason: allowed.contains(id) ? "deletion could not be verified" : "folder is not empty")
                    }
                }
            }
        }
        for i in indices { plan.steps[i].state = states[i] ?? .failed(reason: "deletion could not be verified") }
        try await store.save(plan)
        for i in indices { onEvent(.stepFinished(index: i, state: plan.steps[i].state)) }
    }

    /// After an interruption: the one collection this step may have created. It must be new
    /// since planning, not yet used by this plan, the only one with this title in this place,
    /// and still empty. Anything else is not taken over.
    private func adoptionCandidate(title: String, parent: CollectionID?, folder: Bool, plan: ChangePlan, inventory: CollectionInventory) -> CollectionID? {
        let alreadyResolved = Set(plan.resolvedKeys.values)
        let candidates = inventory.collections.values
            .filter { ($0.kind == .folder) == folder && $0.title == title && $0.parentID == parent }
            .filter { !plan.baselineCollectionIDs.contains($0.id) && !alreadyResolved.contains($0.id) }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        let isEmpty = folder
            ? !inventory.collections.values.contains { $0.parentID == only.id }
            : only.assetIDs.isEmpty
        return isEmpty ? only.id : nil
    }
}

extension PlannedOperation {
    var plannedKey: String? {
        switch self {
        case .createFolder(let key, _, _), .createAlbum(let key, _, _): key
        default: nil
        }
    }

    /// Adds or removes album memberships (journaled together with their intent).
    var changesMembership: Bool {
        switch self {
        case .addAssets, .removeAssets: true
        default: false
        }
    }

    var removedAssets: [AssetID] {
        if case .removeAssets(_, let assets) = self { return assets }
        return []
    }
}

extension ChangePlan {
    var withoutBaseline: ChangePlan {
        var copy = self
        copy.baseline = [:]
        return copy
    }

    /// Distinct media this plan really put into albums (planned media of succeeded steps for
    /// plans saved by older versions).
    public var appliedAssets: Set<AssetID> {
        var result = Set<AssetID>()
        for step in steps {
            guard case .addAssets(_, let assets) = step.operation else { continue }
            if let media = record?.media[step.id], record?.unverified.contains(step.id) != true {
                result.formUnion(media)
            } else if case .succeeded = step.state, record?.media[step.id] == nil {
                result.formUnion(assets)
            }
        }
        return result
    }

    /// Suggestions whose album a plan took photos out of or deleted (a removal from the list
    /// of Albumist's albums). Taking such a plan back lets these suggestions return.
    public var removalSources: Set<SortlyID> {
        Set(steps.compactMap { step in
            switch step.operation {
            case .removeAssets, .deleteCollection: step.sourceID
            default: nil
            }
        })
    }

    /// The plan with the user's newer decisions applied to the steps that have not run yet:
    /// before an interrupted plan is resumed, photos the user has taken out of an album since
    /// (or excluded) are not added anymore.
    public func respecting(_ overrides: OverrideSet) -> ChangePlan {
        var copy = self
        for index in copy.steps.indices {
            guard copy.steps[index].state == .pending, case .addAssets(let ref, let assets) = copy.steps[index].operation else { continue }
            let album: CollectionID? = switch ref {
            case .existing(let id): id
            case .planned(let key): resolvedKeys[key]
            }
            let source = copy.steps[index].sourceID
            let kept = assets.filter { asset in
                if let album, !overrides.mayAdd(asset, toAlbum: album) { return false }
                if let source, !overrides.mayAdd(asset, toSource: source) { return false }
                return true
            }
            if kept.count != assets.count {
                copy.steps[index].operation = .addAssets(album: ref, assets: kept)
            }
        }
        return copy
    }
}

/// Builds a plan that safely reverts the changes of an executed plan (prompt §16.5).
/// Manual changes made in between are respected: user-added media are never removed and
/// albums the user filled with own content are not deleted.
///
/// It works from what execution really did (`ChangePlan.record`), not from what was planned:
/// media that were already in an album, or were added by the user while the plan ran, are
/// not Albumist's and stay. Plans saved by older versions fall back to their succeeded steps.
public struct UndoPlanner: Sendable {
    public init() {}

    /// - Parameter owned: media Albumist still owns per album, from the managed-album records
    ///   after the latest reconciliation. Media the user took out and later put back by hand
    ///   are no longer Albumist's and stay. Pass `nil` for a plan that was never recorded
    ///   (an interrupted one).
    public func undoPlan(for executed: ChangePlan, current: CollectionInventory, owned: [CollectionID: Set<AssetID>]? = nil,
                         id: SortlyID = SortlyID(), now: Date = Date()) -> ChangePlan {
        var steps: [PlanStep] = []
        var notes: [PlanNote] = []
        var guards: [CollectionID: Set<AssetID>] = [:]
        func append(_ op: PlannedOperation, source: SortlyID? = nil) {
            steps.append(PlanStep(id: "\(id.rawValue)-\(steps.count)-\(StableHash.hex(String(describing: op)).prefix(12))", operation: op, sourceID: source ?? executed.id))
        }
        let record = executed.record
        func resolved(_ ref: AlbumRef) -> CollectionID? {
            switch ref {
            case .existing(let id): id
            case .planned(let key): executed.resolvedKeys[key]
            }
        }
        /// What a membership step really changed. An unverified intent counts as far as the
        /// library shows it happened (a Photos change is all or nothing).
        func changed(_ step: PlanStep, album: CollectionID, planned: [AssetID], added: Bool) -> [AssetID] {
            if let media = record?.media[step.id] {
                guard record?.unverified.contains(step.id) == true else { return media }
                let members = current[album]?.assetIDs ?? []
                return media.filter { members.contains($0) == added }
            }
            if case .succeeded = step.state { return planned }
            return []
        }

        var addedByUs: [CollectionID: Set<AssetID>] = [:]
        var createdAlbums: [CollectionID] = []
        var createdFolders: [CollectionID] = []
        for step in executed.steps {
            switch step.operation {
            case .createAlbum(let key, _, _), .createFolder(let key, _, _):
                // An album found after an interruption is never deleted: Albumist cannot prove it made it.
                guard case .succeeded(let created, _) = step.state, let created = created ?? executed.resolvedKeys[key],
                      record?.adoptedKeys.contains(key) != true else { continue }
                if case .createAlbum = step.operation { createdAlbums.append(created) } else { createdFolders.append(created) }
            case .addAssets(let ref, let assets):
                guard let albumID = resolved(ref) else { continue }
                let added = changed(step, album: albumID, planned: assets, added: true)
                if !added.isEmpty { addedByUs[albumID, default: []].formUnion(added) }
            default: break
            }
        }
        if let owned {
            for (albumID, ours) in addedByUs { addedByUs[albumID] = ours.intersection(owned[albumID] ?? []) }
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

        // 2. Created albums: delete only if they contain nothing the user added himself. The
        //    deletion carries a guard: if the user puts a photo in before it runs, the album
        //    stays and only Albumist's photos leave it. Deletions are collected and run
        //    together at the end (one question from Photos).
        let createdSet = Set(createdAlbums)
        var albumDeletions: [PlannedOperation] = []
        for albumID in createdAlbums {
            guard let album = current[albumID] else { continue }
            let ours = addedByUs[albumID] ?? []
            if album.assetIDs.isSubset(of: ours) {
                albumDeletions.append(.deleteCollection(albumID, title: album.title))
                guards[albumID] = ours
            } else {
                let removable = album.assetIDs.intersection(ours).sorted()
                if !removable.isEmpty { append(.removeAssets(album: albumID, assets: removable)) }
                notes.append(.respectedManualRemovals(count: album.assetIDs.subtracting(ours).count))
            }
        }
        // 3. Extended existing albums (and adopted ones): remove only our additions that are still there.
        for (albumID, ours) in addedByUs.sorted(by: { $0.key < $1.key }) where !createdSet.contains(albumID) {
            guard let album = current[albumID] else { continue }
            let removable = album.assetIDs.intersection(ours).sorted()
            if !removable.isEmpty { append(.removeAssets(album: albumID, assets: removable)) }
        }
        // 4. A plan that took Albumist's photos back out of albums (or deleted its album) is
        //    reverted too: the photos go back, a deleted album comes back with its photos (as
        //    a new album: Photos cannot restore the old one). Undo plans themselves are not
        //    reverted this way.
        if executed.reverts == nil {
            for step in executed.steps {
                let albumID: CollectionID
                switch step.operation {
                case .removeAssets(let cid, _): albumID = cid
                case .deleteCollection(let cid, _):
                    // A deletion that kept the album (it held the user's photos) only took
                    // Albumist's photos out.
                    if case .succeeded = step.state { continue }
                    albumID = cid
                default: continue
                }
                guard let album = current[albumID] else { continue }
                let removed = changed(step, album: albumID, planned: step.operation.removedAssets, added: false)
                let back = removed.filter { !album.assetIDs.contains($0) }
                if !back.isEmpty { append(.addAssets(album: .existing(albumID), assets: back), source: step.sourceID) }
            }
            for step in executed.steps {
                guard case .deleteCollection(let cid, _) = step.operation, case .succeeded = step.state,
                      let gone = record?.deletedAlbums[cid], current[cid] == nil else { continue }
                let key = "restore-\(cid.rawValue)"
                let parent: FolderRef = gone.parentID.flatMap { current[$0] != nil ? FolderRef.existing($0) : nil } ?? .topLevel
                append(.createAlbum(key: key, title: gone.title, parent: parent), source: step.sourceID)
                if !gone.members.isEmpty { append(.addAssets(album: .planned(key), assets: gone.members), source: step.sourceID) }
            }
        }
        albumDeletions.forEach { append($0) }
        // 5. Folders we created, deepest first, only if nothing else is left inside. Deleting a
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

        var plan = ChangePlan(
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
        plan.deleteGuards = guards
        return plan
    }
}
