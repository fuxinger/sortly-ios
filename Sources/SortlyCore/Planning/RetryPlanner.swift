import Foundation

extension StepState {
    /// Reason of the steps the user chose to leave undone ("So lassen" after an interruption).
    public static let leftByUserReason = "left by user"

    /// Reasons of steps that were skipped only because an earlier step of the same plan
    /// failed; they can run once that step works.
    static let dependencyReasons: Set<String> = [
        "parent folder was not created", "target album was not created", "target folder was not created",
    ]

    /// Failed, skipped because an earlier step failed, or left undone by the user: a retry
    /// may run it again. A deliberate skip (an album kept because it holds the user's photos)
    /// is not retried.
    public var canBeRetried: Bool {
        switch self {
        case .failed: true
        case .skipped(let reason): reason == Self.leftByUserReason || Self.dependencyReasons.contains(reason)
        default: false
        }
    }
}

/// "Erneut versuchen" for a plan that did not finish everything (I16): a new plan with only
/// the steps that did not happen. What the first run created is referred to by its real id
/// now, what it could not create is created again, and a step that already succeeded never
/// runs twice. Albums the user deleted since then are respected: nothing is added to them.
public struct RetryPlanner: Sendable {
    public init() {}

    public func retryPlan(for executed: ChangePlan, current: CollectionInventory,
                          id: SortlyID = SortlyID(), now: Date = Date()) -> ChangePlan? {
        guard executed.reverts == nil else { return nil }
        let retried = executed.steps.filter { $0.state.canBeRetried }
        guard !retried.isEmpty else { return nil }

        // Planned keys that this retry creates again (their create step did not happen).
        var recreated = Set<String>()
        for step in retried {
            switch step.operation {
            case .createFolder(let key, _, _), .createAlbum(let key, _, _): recreated.insert(key)
            default: break
            }
        }

        /// A planned key becomes the album the first run created, if it still exists; it
        /// stays planned if this retry creates it; otherwise (deleted by the user since) the
        /// step that needs it is dropped.
        enum Resolution<Ref> { case ref(Ref), drop }
        func folder(_ ref: FolderRef) -> Resolution<FolderRef> {
            guard case .planned(let key) = ref else { return .ref(ref) }
            if recreated.contains(key) { return .ref(ref) }
            if let id = executed.resolvedKeys[key], current[id] != nil { return .ref(.existing(id)) }
            return .drop
        }
        func album(_ ref: AlbumRef) -> Resolution<AlbumRef> {
            guard case .planned(let key) = ref else { return .ref(ref) }
            if recreated.contains(key) { return .ref(ref) }
            if let id = executed.resolvedKeys[key], current[id] != nil { return .ref(.existing(id)) }
            return .drop
        }

        var steps: [PlanStep] = []
        var touched = Set<CollectionID>()
        func append(_ op: PlannedOperation, _ source: SortlyID?) {
            steps.append(PlanStep(id: "\(id.rawValue)-\(steps.count)-\(StableHash.hex(String(describing: op)).prefix(12))",
                                  operation: op, sourceID: source))
        }
        for step in retried {
            switch step.operation {
            case let .createFolder(key, title, parent):
                guard case .ref(let p) = folder(parent) else { continue }
                if case .existing(let pid) = p { touched.insert(pid) }
                append(.createFolder(key: key, title: title, parent: p), step.sourceID)
            case let .createAlbum(key, title, parent):
                guard case .ref(let p) = folder(parent) else { continue }
                if case .existing(let pid) = p { touched.insert(pid) }
                append(.createAlbum(key: key, title: title, parent: p), step.sourceID)
            case let .addAssets(ref, assets):
                guard case .ref(let a) = album(ref) else { continue }
                // Photos the first run already added (and the user kept) are not added again.
                var wanted = assets
                if case .existing(let albumID) = a, let members = current[albumID]?.assetIDs {
                    wanted = assets.filter { !members.contains($0) }
                }
                guard !wanted.isEmpty else { continue }
                if case .existing(let albumID) = a { touched.insert(albumID) }
                append(.addAssets(album: a, assets: wanted), step.sourceID)
            case let .renameCollection(cid, from, to):
                guard current[cid] != nil else { continue }
                touched.insert(cid)
                append(.renameCollection(cid, from: from, to: to), step.sourceID)
            case let .moveCollection(cid, from, to):
                guard current[cid] != nil, case .ref(let target) = folder(to) else { continue }
                touched.insert(cid)
                append(.moveCollection(cid, from: from, to: target), step.sourceID)
            case let .removeAssets(cid, assets):
                guard let members = current[cid]?.assetIDs else { continue }
                let still = assets.filter { members.contains($0) }
                guard !still.isEmpty else { continue }
                touched.insert(cid)
                append(.removeAssets(album: cid, assets: still), step.sourceID)
            case let .deleteCollection(cid, title):
                guard current[cid] != nil else { continue }
                append(.deleteCollection(cid, title: title), step.sourceID)
            }
        }
        guard !steps.isEmpty else { return nil }

        var baseline: [CollectionID: String] = [:]
        for cid in touched { if let c = current[cid] { baseline[cid] = c.fingerprint } }
        var plan = ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: baseline,
            baselineCollectionIDs: Set(current.collections.keys),
            steps: steps,
            conflicts: [],
            notes: [],
            resolvedKeys: [:]
        )
        plan.retries = executed.id
        // Albums the first run made were counted against the free albums with it.
        plan.albumsFromRetriedPlan = Set(executed.resolvedKeys.values)
        if let guards = executed.deleteGuards {
            let deleting = Set(steps.compactMap { if case .deleteCollection(let cid, _) = $0.operation { return cid }; return nil })
            plan.deleteGuards = guards.filter { deleting.contains($0.key) }
        }
        return plan
    }
}
