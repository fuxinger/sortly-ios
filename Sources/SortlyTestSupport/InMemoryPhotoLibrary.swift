import Foundation
import SortlyCore

/// In-memory photo library for tests and previews. Mirrors the PhotoKit semantics Albumist
/// relies on: collections have identities, albums reference assets (no copies), deleting an
/// album never deletes media.
public actor InMemoryPhotoLibrary: PhotoLibraryWriting {
    public private(set) var assets: Set<AssetID>
    public private(set) var inventory: CollectionInventory
    public var writeAllowed = true
    /// Simulates a crash: the write call number `failAfterWrites + 1` fails.
    public var failAfterWrites: Int?
    /// If true the failing write is applied before the error is thrown (crash between the
    /// PhotoKit commit and Albumist's journal update).
    public var crashAfterApplying = false
    public private(set) var writeCount = 0
    private var nextID = 1

    public struct SimulatedCrash: Error {}

    public init(assets: Set<AssetID>, collections: [CollectionSnapshot] = []) {
        self.assets = assets
        self.inventory = CollectionInventory(collections)
    }

    public func setFailAfterWrites(_ n: Int?, afterApplying: Bool = false) {
        failAfterWrites = n
        crashAfterApplying = afterApplying
        writeCount = 0
    }
    public func setWriteAllowed(_ allowed: Bool) { writeAllowed = allowed }

    /// Simulates a manual change by the user in the Photos app.
    public func userEdit(_ change: (inout CollectionInventory) -> Void) { change(&inventory) }

    private var pendingCrash = false

    private func countWrite() throws {
        if let limit = failAfterWrites, writeCount >= limit {
            if crashAfterApplying { pendingCrash = true } else { throw SimulatedCrash() }
        }
        writeCount += 1
    }

    private func finishWrite() throws {
        if pendingCrash {
            pendingCrash = false
            failAfterWrites = 0
            crashAfterApplying = false
            writeCount = 0
            throw SimulatedCrash()
        }
    }

    private func newID(_ prefix: String) -> CollectionID {
        defer { nextID += 1 }
        return CollectionID("\(prefix)-mem-\(nextID)")
    }

    public func canWrite() async -> Bool { writeAllowed }
    public func currentInventory() async throws -> CollectionInventory { inventory }
    public func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { Set(ids).intersection(assets) }

    public func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
        try countWrite()
        let id = newID("folder")
        inventory.upsert(CollectionSnapshot(id: id, title: title, kind: .folder, parentID: parent))
        if let parent, var p = inventory[parent] { p.childIDs.append(id); inventory.upsert(p) }
        try finishWrite()
        return id
    }

    public func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        try countWrite()
        let id = newID("album")
        inventory.upsert(CollectionSnapshot(id: id, title: title, kind: .userAlbum, parentID: parent))
        if let parent, var p = inventory[parent] { p.childIDs.append(id); inventory.upsert(p) }
        try finishWrite()
        return id
    }

    public func addAssets(_ ids: [AssetID], to album: CollectionID) async throws {
        try countWrite()
        guard var a = inventory[album], a.isEditableAlbum else { throw CocoaLikeError.notEditable }
        a.assetIDs.formUnion(Set(ids).intersection(assets))
        inventory.upsert(a)
        try finishWrite()
    }

    public func removeAssets(_ ids: [AssetID], from album: CollectionID) async throws {
        try countWrite()
        guard var a = inventory[album] else { throw CocoaLikeError.missing }
        a.assetIDs.subtract(ids)
        inventory.upsert(a)
        try finishWrite()
    }

    public func renameCollection(_ id: CollectionID, to title: String) async throws {
        try countWrite()
        guard var c = inventory[id] else { throw CocoaLikeError.missing }
        c.title = title
        inventory.upsert(c)
        try finishWrite()
    }

    public func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        try countWrite()
        guard var c = inventory[id] else { throw CocoaLikeError.missing }
        if let old = c.parentID, var p = inventory[old] { p.childIDs.removeAll { $0 == id }; inventory.upsert(p) }
        c.parentID = newParent
        inventory.upsert(c)
        if let newParent, var p = inventory[newParent] { p.childIDs.append(id); inventory.upsert(p) }
        try finishWrite()
    }

    public func deleteCollection(_ id: CollectionID) async throws {
        try countWrite()
        guard let c = inventory[id] else { return }
        if let parent = c.parentID, var p = inventory[parent] { p.childIDs.removeAll { $0 == id }; inventory.upsert(p) }
        // Like Photos: deleting a folder deletes the albums and folders inside it as well.
        var doomed = [id]
        while let next = doomed.popLast() {
            doomed.append(contentsOf: inventory.collections.values.filter { $0.parentID == next }.map(\.id))
            inventory.remove(next)
        }
        try finishWrite()
        // Media are untouched – exactly like PhotoKit.
    }

    public enum CocoaLikeError: Error { case missing, notEditable }
}

/// Plan store that keeps every saved version (lets tests inspect the journal).
public actor InMemoryPlanStore: ChangePlanStoring {
    public private(set) var saved: [ChangePlan] = []
    public init() {}
    public func save(_ plan: ChangePlan) async throws { saved.append(plan) }
    public var latest: ChangePlan? { saved.last }
}
