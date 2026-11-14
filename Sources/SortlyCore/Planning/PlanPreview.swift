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
    /// The suggestion the album comes from (first step that creates or fills it).
    public var sourceID: SortlyID?
}

extension ChangePlan {
    /// Every album the plan creates or extends, with its folder path. Albums follow `order`
    /// (suggestion ids, e.g. the order of the suggestions list) so the preview reads like the
    /// list the user chose from; albums without a place in `order` keep plan order at the end.
    public func albumPreview(inventory: CollectionInventory, order: [SortlyID] = []) -> [PlannedAlbumPreview] {
        var folders: [String: (title: String, parent: FolderRef)] = [:]
        var albums: [String: (title: String, parent: FolderRef)] = [:]
        var refs: [AlbumRef] = []
        var seen = Set<AlbumRef>()
        var added: [AlbumRef: [AssetID]] = [:]
        var source: [AlbumRef: SortlyID] = [:]
        for step in steps {
            switch step.operation {
            case let .createFolder(key, title, parent):
                folders[key] = (title, parent)
            case let .createAlbum(key, title, parent):
                albums[key] = (title, parent)
                if seen.insert(.planned(key)).inserted { refs.append(.planned(key)) }
                if source[.planned(key)] == nil { source[.planned(key)] = step.sourceID }
            case let .addAssets(ref, ids):
                if seen.insert(ref).inserted { refs.append(ref) }
                if source[ref] == nil { source[ref] = step.sourceID }
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

        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let sorted = refs.enumerated().sorted { a, b in
            let ra = source[a.element].flatMap { rank[$0] } ?? Int.max
            let rb = source[b.element].flatMap { rank[$0] } ?? Int.max
            return (ra, a.offset) < (rb, b.offset)
        }.map(\.element)

        return sorted.map { ref in
            let ids = added[ref] ?? []
            switch ref {
            case .planned(let key):
                let album = albums[key]
                return PlannedAlbumPreview(id: ref, title: album?.title ?? "", folderPath: album.map { path($0.parent) } ?? [],
                                           addedCount: Set(ids).count, isNew: true, coverAssetID: ids.first, sourceID: source[ref])
            case .existing(let id):
                let album = inventory[id]
                return PlannedAlbumPreview(id: ref, title: album?.title ?? "", folderPath: existingPath(album?.parentID),
                                           addedCount: Set(ids).count, isNew: false, coverAssetID: ids.first, sourceID: source[ref])
            }
        }
    }
}
