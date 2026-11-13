import Foundation

/// The user's decision for one proposal (prompt §5.4).
public enum ProposalDecision: Hashable, Sendable, Codable {
    case undecided
    case reject
    /// Create a new album (also used for "zusätzliches Album erstellen").
    case createNew(title: String?, folderPath: [String]?)
    /// Keep the existing album unchanged (counts as organized).
    case keepExisting(CollectionID)
    /// Add missing matching media to the existing album (default for "ergänzbar").
    case extendExisting(CollectionID)
    case renameExisting(CollectionID, newTitle: String, extend: Bool)
    case moveExisting(CollectionID, folderPath: [String], extend: Bool)
    /// Merge several albums into one target. `removeSourceAlbums` deletes only the old
    /// album containers after all their media were added to the target.
    case merge(target: CollectionID?, sources: [CollectionID], title: String, folderPath: [String]?, removeSourceAlbums: Bool)
}

/// A proposal together with the user's selection.
public struct ConfirmedProposal: Hashable, Sendable, Codable {
    public var proposal: AlbumProposal
    public var decision: ProposalDecision
    /// Optional (weak-evidence) members the user accepted.
    public var acceptedOptional: Set<AssetID>
    /// Members the user deselected.
    public var excluded: Set<AssetID>

    public init(proposal: AlbumProposal, decision: ProposalDecision, acceptedOptional: Set<AssetID> = [], excluded: Set<AssetID> = []) {
        self.proposal = proposal
        self.decision = decision
        self.acceptedOptional = acceptedOptional
        self.excluded = excluded
    }

    public var selectedAssets: Set<AssetID> {
        proposal.assetIDs.union(acceptedOptional.intersection(proposal.optionalAssetIDs)).subtracting(excluded)
    }
}

/// Turns confirmed decisions into a concrete `ChangePlan`. Pure function of its inputs:
/// planning never touches the photo library (prompt §16).
public struct OrganizationPlanner: Sendable {
    /// Root folder for everything SORTLY creates ("SORTLY"). Empty = top level.
    public var rootFolderTitle: String
    /// Maximum assets per add step – keeps each PhotoKit transaction small and resumable.
    public var chunkSize: Int

    public init(rootFolderTitle: String = "SORTLY", chunkSize: Int = 500) {
        self.rootFolderTitle = rootFolderTitle
        self.chunkSize = max(1, chunkSize)
    }

    public func makePlan(
        id: SortlyID = SortlyID(),
        from items: [ConfirmedProposal],
        inventory: CollectionInventory,
        overrides: OverrideSet = OverrideSet(),
        now: Date = Date()
    ) -> ChangePlan {
        var builder = Builder(inventory: inventory, root: rootFolderTitle, planID: id, chunkSize: chunkSize)
        var conflicts: [PlanConflict] = []
        var notes: [PlanNote] = []
        var respectedRemovals = 0
        var optionalNotIncluded = 0

        // Detect duplicate titles among new albums before building.
        var newTitles: [String: [SortlyID]] = [:]
        for item in items {
            if case .createNew(let title, let path) = item.decision {
                let t = title ?? item.proposal.title
                let p = path ?? item.proposal.folderPath
                newTitles[(p + [AlbumTitle.normalized(t)]).joined(separator: "/"), default: []].append(item.proposal.id)
            }
        }
        for (key, sources) in newTitles where sources.count > 1 {
            let parts = key.split(separator: "/").map(String.init)
            let title = items.first { $0.proposal.id == sources[0] }.map { item -> String in
                if case .createNew(let t, _) = item.decision { return t ?? item.proposal.title }
                return item.proposal.title
            } ?? parts.last ?? key
            conflicts.append(.duplicatePlannedTitle(title: title, folderPath: Array(parts.dropLast()), sources: sources))
        }

        for item in items.sorted(by: { $0.proposal.id.rawValue < $1.proposal.id.rawValue }) {
            let sourceID = item.proposal.id
            if overrides.isRejected(sourceID) { notes.append(.skippedRejected(sourceID)); continue }
            optionalNotIncluded += item.proposal.optionalAssetIDs.subtracting(item.acceptedOptional).count

            func filtered(for album: CollectionID?) -> [AssetID] {
                let candidates = item.selectedAssets.filter { overrides.mayAdd($0, toSource: sourceID) && !overrides.isIgnored($0) && !overrides.isExcluded($0) }
                guard let album else { return candidates.sorted() }
                let allowed = candidates.filter { overrides.mayAdd($0, toAlbum: album) }
                respectedRemovals += candidates.count - allowed.count
                return allowed.sorted()
            }

            func requireEditable(_ id: CollectionID) -> Bool {
                guard let album = inventory[id] else { conflicts.append(.albumMissing(id)); return false }
                guard album.isEditableAlbum else { conflicts.append(.albumNotEditable(id)); return false }
                builder.touch(id)
                return true
            }

            switch item.decision {
            case .undecided, .reject, .keepExisting:
                continue

            case .createNew(let title, let path):
                if overrides.mustNotRecreate(sourceID) { notes.append(.skippedDeletedByUser(sourceID)); continue }
                let albumTitle = AlbumTitle.sanitize(title ?? item.proposal.title)
                let folderPath = path ?? item.proposal.folderPath
                let parent = builder.folder(for: folderPath, source: sourceID)
                if let existing = builder.existingAlbum(titled: albumTitle, in: parent) {
                    conflicts.append(.titleExistsInFolder(title: albumTitle, existing: existing))
                }
                let key = builder.createAlbum(title: albumTitle, parent: parent, source: sourceID)
                builder.add(filtered(for: nil), to: .planned(key), source: sourceID)

            case .extendExisting(let albumID):
                guard requireEditable(albumID) else { continue }
                let missing = filtered(for: albumID).filter { !(inventory[albumID]?.assetIDs.contains($0) ?? false) }
                builder.add(missing, to: .existing(albumID), source: sourceID)

            case .renameExisting(let albumID, let newTitle, let extend):
                guard requireEditable(albumID), let album = inventory[albumID] else { continue }
                let clean = AlbumTitle.sanitize(newTitle)
                if clean != album.title {
                    builder.append(.renameCollection(albumID, from: album.title, to: clean), source: sourceID)
                }
                if extend {
                    builder.add(filtered(for: albumID).filter { !album.assetIDs.contains($0) }, to: .existing(albumID), source: sourceID)
                }

            case .moveExisting(let albumID, let path, let extend):
                guard requireEditable(albumID), let album = inventory[albumID] else { continue }
                let target = builder.folder(for: path, source: sourceID)
                if target != builder.currentParentRef(of: album) {
                    builder.append(.moveCollection(albumID, from: album.parentID, to: target), source: sourceID)
                }
                if extend {
                    builder.add(filtered(for: albumID).filter { !album.assetIDs.contains($0) }, to: .existing(albumID), source: sourceID)
                }

            case .merge(let target, let sources, let title, let path, let removeSources):
                let validSources = sources.filter { requireEditable($0) }
                guard validSources.count == sources.count else { continue }
                var union = Set<AssetID>()
                for s in validSources { union.formUnion(inventory[s]?.assetIDs ?? []) }
                union.formUnion(item.selectedAssets)
                let ref: AlbumRef
                let targetMembers: Set<AssetID>
                if let target, requireEditable(target), let album = inventory[target] {
                    ref = .existing(target)
                    targetMembers = album.assetIDs
                    let clean = AlbumTitle.sanitize(title)
                    if clean != album.title { builder.append(.renameCollection(target, from: album.title, to: clean), source: sourceID) }
                } else {
                    let parent = builder.folder(for: path ?? item.proposal.folderPath, source: sourceID)
                    ref = .planned(builder.createAlbum(title: AlbumTitle.sanitize(title), parent: parent, source: sourceID))
                    targetMembers = []
                }
                builder.add(union.subtracting(targetMembers).sorted(), to: ref, source: sourceID)
                if removeSources {
                    for s in validSources where AlbumRef.existing(s) != ref {
                        builder.append(.deleteCollection(s, title: inventory[s]?.title ?? ""), source: sourceID)
                    }
                }
            }
        }

        if respectedRemovals > 0 { notes.append(.respectedManualRemovals(count: respectedRemovals)) }
        if optionalNotIncluded > 0 { notes.append(.optionalItemsNotIncluded(count: optionalNotIncluded)) }

        return ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: builder.baseline,
            baselineCollectionIDs: Set(inventory.collections.keys),
            steps: builder.steps,
            conflicts: conflicts,
            notes: notes,
            resolvedKeys: [:]
        )
    }

    // MARK: - Builder

    struct Builder {
        let inventory: CollectionInventory
        let root: String
        let planID: SortlyID
        let chunkSize: Int
        var steps: [PlanStep] = []
        var baseline: [CollectionID: String] = [:]
        var plannedFolders: [String: String] = [:]           // path → key
        var plannedAlbums: [String: [String: String]] = [:]  // parent → normalized title → key

        init(inventory: CollectionInventory, root: String, planID: SortlyID, chunkSize: Int) {
            self.inventory = inventory
            self.root = root
            self.planID = planID
            self.chunkSize = chunkSize
        }

        mutating func touch(_ id: CollectionID) {
            if let c = inventory[id] { baseline[id] = c.fingerprint }
        }

        mutating func append(_ op: PlannedOperation, source: SortlyID?) {
            let index = steps.count
            let content = String(describing: op)
            steps.append(PlanStep(id: "\(planID.rawValue)-\(index)-\(StableHash.hex(content).prefix(12))", operation: op, sourceID: source))
        }

        func refKey(_ ref: FolderRef) -> String {
            switch ref {
            case .topLevel: "top"
            case .existing(let id): "e:\(id.rawValue)"
            case .planned(let k): "p:\(k)"
            }
        }

        func currentParentRef(of album: CollectionSnapshot) -> FolderRef {
            album.parentID.map { .existing($0) } ?? .topLevel
        }

        /// Resolves `[root] + path` to existing folders where possible, planning the rest.
        mutating func folder(for path: [String], source: SortlyID?) -> FolderRef {
            let full = (root.isEmpty ? [] : [root]) + path
            var parent: FolderRef = .topLevel
            var walked: [String] = []
            for title in full {
                walked.append(title)
                let pathKey = walked.joined(separator: "/")
                if case .existing(let parentID) = parent, let match = childFolder(titled: title, parentID: parentID) {
                    parent = .existing(match)
                    continue
                }
                if case .topLevel = parent, let match = childFolder(titled: title, parentID: nil) {
                    parent = .existing(match)
                    continue
                }
                if let key = plannedFolders[pathKey] {
                    parent = .planned(key)
                    continue
                }
                let key = "folder:" + pathKey
                append(.createFolder(key: key, title: title, parent: parent), source: source)
                plannedFolders[pathKey] = key
                parent = .planned(key)
            }
            return parent
        }

        func childFolder(titled title: String, parentID: CollectionID?) -> CollectionID? {
            inventory.folders.first { $0.title == title && $0.parentID == parentID }?.id
        }

        func existingAlbum(titled title: String, in parent: FolderRef) -> CollectionID? {
            let parentID: CollectionID?
            switch parent {
            case .topLevel: parentID = nil
            case .existing(let id): parentID = id
            case .planned: return nil
            }
            let normalized = AlbumTitle.normalized(title)
            return inventory.albums.first { $0.parentID == parentID && AlbumTitle.normalized($0.title) == normalized }?.id
        }

        mutating func createAlbum(title: String, parent: FolderRef, source: SortlyID?) -> String {
            let parentKey = refKey(parent)
            let normalized = AlbumTitle.normalized(title)
            var key = "album:\(parentKey)/\(normalized)"
            var suffix = 2
            while plannedAlbums[parentKey]?.values.contains(key) == true {
                key = "album:\(parentKey)/\(normalized)#\(suffix)"
                suffix += 1
            }
            plannedAlbums[parentKey, default: [:]][normalized + "#\(steps.count)"] = key
            append(.createAlbum(key: key, title: title, parent: parent), source: source)
            return key
        }

        mutating func add(_ assets: [AssetID], to album: AlbumRef, source: SortlyID?) {
            guard !assets.isEmpty else { return }
            var start = 0
            while start < assets.count {
                let chunk = Array(assets[start..<min(start + chunkSize, assets.count)])
                append(.addAssets(album: album, assets: chunk), source: source)
                start += chunkSize
            }
        }
    }
}
