import Foundation

/// One album of a plan as the preview lists it before anything changes
/// (Fuchs, 14.11.: the numbers alone did not say which albums Albumist would make).
public struct PlannedAlbumPreview: Hashable, Sendable, Identifiable {
    public var id: AlbumRef
    public var title: String
    /// Folder titles from the top, e.g. ["Albumist", "Länder"]. Empty at the top level.
    public var folderPath: [String]
    /// Distinct photos the plan adds to the album.
    public var addedCount: Int
    /// A new album (otherwise an existing album is extended).
    public var isNew: Bool
    public var coverAssetID: AssetID?
}

extension ChangePlan {
    /// Every album the plan creates or extends, in plan order, with its folder path.
    public func albumPreview(inventory: CollectionInventory) -> [PlannedAlbumPreview] {
        var folders: [String: (title: String, parent: FolderRef)] = [:]
        var albums: [String: (title: String, parent: FolderRef)] = [:]
        var order: [AlbumRef] = []
        var seen = Set<AlbumRef>()
        var added: [AlbumRef: [AssetID]] = [:]
        for step in steps {
            switch step.operation {
            case let .createFolder(key, title, parent):
                folders[key] = (title, parent)
            case let .createAlbum(key, title, parent):
                albums[key] = (title, parent)
                if seen.insert(.planned(key)).inserted { order.append(.planned(key)) }
            case let .addAssets(ref, ids):
                if seen.insert(ref).inserted { order.append(ref) }
                added[ref, default: []].append(contentsOf: ids)
            default:
                break
            }
        }

        func existingPath(_ id: CollectionID?) -> [String] {
            var titles: [String] = []
            var current = id
            // Bounded: a damaged inventory must never loop forever.
            while let c = current, let node = inventory[c], titles.count < 32 {
                titles.insert(node.title, at: 0)
                current = node.parentID
            }
            return titles
        }
        func path(_ folder: FolderRef, depth: Int = 0) -> [String] {
            switch folder {
            case .topLevel:
                return []
            case .existing(let id):
                return existingPath(id)
            case .planned(let key):
                guard let f = folders[key], depth < 32 else { return [] }
                return path(f.parent, depth: depth + 1) + [f.title]
            }
        }

        return order.map { ref in
            let ids = added[ref] ?? []
            switch ref {
            case .planned(let key):
                let album = albums[key]
                return PlannedAlbumPreview(id: ref, title: album?.title ?? "", folderPath: album.map { path($0.parent) } ?? [],
                                           addedCount: Set(ids).count, isNew: true, coverAssetID: ids.first)
            case .existing(let id):
                let album = inventory[id]
                return PlannedAlbumPreview(id: ref, title: album?.title ?? "", folderPath: existingPath(album?.parentID),
                                           addedCount: Set(ids).count, isNew: false, coverAssetID: ids.first)
            }
        }
    }
}
