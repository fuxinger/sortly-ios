import Foundation

/// Kind of a photo-library collection, mirroring the public PhotoKit distinctions.
public enum CollectionKind: String, Sendable, Codable {
    /// `PHAssetCollection` of type `.album`, subtype `.albumRegular` – a normal user album.
    case userAlbum
    /// `PHCollectionList` folder created by the user (or by SORTLY).
    case folder
    /// Smart album maintained by Photos (Favorites, Screenshots, ...). Read-only.
    case smartAlbum
    /// Shared / synced / imported albums with restricted editing.
    case restrictedAlbum
}

/// Editing capabilities as reported by `PHCollection.canPerform(_:)`.
public struct CollectionCapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let addContent    = CollectionCapabilities(rawValue: 1 << 0)
    public static let removeContent = CollectionCapabilities(rawValue: 1 << 1)
    public static let rename        = CollectionCapabilities(rawValue: 1 << 2)
    public static let delete        = CollectionCapabilities(rawValue: 1 << 3)
    public static let createContent = CollectionCapabilities(rawValue: 1 << 4) // folders: add children
    public static let all: CollectionCapabilities = [.addContent, .removeContent, .rename, .delete, .createContent]
}

/// Snapshot of one existing album or folder in the photo library.
public struct CollectionSnapshot: Hashable, Sendable, Codable, Identifiable {
    public var id: CollectionID
    public var title: String
    public var kind: CollectionKind
    public var capabilities: CollectionCapabilities
    /// Parent folder identity, `nil` for top level.
    public var parentID: CollectionID?
    /// Members (albums only). Empty for folders.
    public var assetIDs: Set<AssetID>
    /// Children (folders only).
    public var childIDs: [CollectionID]

    public init(
        id: CollectionID,
        title: String,
        kind: CollectionKind = .userAlbum,
        capabilities: CollectionCapabilities = .all,
        parentID: CollectionID? = nil,
        assetIDs: Set<AssetID> = [],
        childIDs: [CollectionID] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.capabilities = capabilities
        self.parentID = parentID
        self.assetIDs = assetIDs
        self.childIDs = childIDs
    }

    public var isEditableAlbum: Bool {
        kind == .userAlbum && capabilities.contains(.addContent)
    }

    /// Fingerprint used to detect changes made outside SORTLY between preview and execution.
    public var fingerprint: String {
        StableHash.hex([title, parentID?.rawValue ?? "-", StableHash.setFingerprint(assetIDs.map(\.rawValue))].joined(separator: "|"))
    }
}

/// The full album/folder inventory at one point in time.
public struct CollectionInventory: Sendable, Codable, Hashable {
    public private(set) var collections: [CollectionID: CollectionSnapshot]

    public init(_ collections: [CollectionSnapshot] = []) {
        self.collections = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public subscript(id: CollectionID) -> CollectionSnapshot? { collections[id] }

    public var albums: [CollectionSnapshot] {
        collections.values.filter { $0.kind != .folder }.sorted { $0.id < $1.id }
    }
    public var folders: [CollectionSnapshot] {
        collections.values.filter { $0.kind == .folder }.sorted { $0.id < $1.id }
    }

    public mutating func upsert(_ collection: CollectionSnapshot) {
        collections[collection.id] = collection
    }

    public mutating func remove(_ id: CollectionID) {
        collections[id] = nil
    }

    /// Folder titles from the top level down to (excluding) the collection itself.
    public func path(of id: CollectionID) -> [String] {
        var result: [String] = []
        var current = collections[id]?.parentID
        var guardCount = 0
        while let parentID = current, let parent = collections[parentID], guardCount < 64 {
            result.insert(parent.title, at: 0)
            current = parent.parentID
            guardCount += 1
        }
        return result
    }

    /// Finds a folder by its title path (exact, case-sensitive like Photos itself).
    public func folder(atPath path: [String]) -> CollectionSnapshot? {
        guard !path.isEmpty else { return nil }
        return folders.first { self.path(of: $0.id) + [$0.title] == path }
    }

    /// Inverted index asset -> albums containing it (user albums only).
    public func albumMembershipIndex() -> [AssetID: [CollectionID]] {
        var index: [AssetID: [CollectionID]] = [:]
        for album in albums where album.kind == .userAlbum || album.kind == .restrictedAlbum {
            for asset in album.assetIDs {
                index[asset, default: []].append(album.id)
            }
        }
        return index
    }
}
