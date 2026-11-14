import Foundation
import Photos
import UniformTypeIdentifiers
import SortlyCore

enum PhotoKitError: Error, LocalizedError {
    case collectionNotFound(String)
    case changeFailed(String)

    var errorDescription: String? {
        switch self {
        case .collectionNotFound: String(localized: "Das Album wurde inzwischen gelöscht oder verschoben.")
        case .changeFailed(let message): message
        }
    }
}

/// Small thread-safe box for values produced inside PhotoKit change blocks.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Reads and writes the user's photo library through PhotoKit. Only the closed set of
/// album/folder operations exists here: no API that deletes or modifies media.
struct PhotoKitLibrary: PhotoLibraryReading, PhotoLibraryWriting {
    private static let lastResourceScanKey = "photokit.lastResourceScan"

    // MARK: Access

    func access() async -> LibraryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> LibraryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Reading

    func fetchAssets(includeHidden: Bool) async throws -> [AssetSnapshot] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = includeHidden
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)

        // Original file names and RAW detection need PHAssetResource, which costs a few
        // milliseconds per asset. Only new or modified assets are scanned after the first
        // run; the store keeps the earlier values (COALESCE on update).
        let lastScan = UserDefaults.standard.object(forKey: Self.lastResourceScanKey) as? Date
        let scanStart = Date()
        var snapshots: [AssetSnapshot] = []
        snapshots.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let needsResources = lastScan.map { last in
                (asset.creationDate ?? .distantFuture) > last || (asset.modificationDate ?? .distantFuture) > last
            } ?? true
            snapshots.append(Self.snapshot(asset, withResources: needsResources))
        }
        UserDefaults.standard.set(scanStart, forKey: Self.lastResourceScanKey)
        return snapshots
    }

    static func snapshot(_ asset: PHAsset, withResources: Bool) -> AssetSnapshot {
        var subtypes = subtypes(from: asset.mediaSubtypes)
        if asset.burstIdentifier != nil { subtypes.insert(.burst) }
        var filename: String?
        var uti: String?
        if withResources {
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            filename = primary?.originalFilename
            uti = primary?.uniformTypeIdentifier
            if resources.contains(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }) {
                subtypes.insert(.raw)
            }
        }
        return AssetSnapshot(
            id: AssetID(asset.localIdentifier),
            kind: kind(asset.mediaType),
            subtypes: subtypes,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            location: asset.location.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            locationAccuracy: asset.location.map { $0.horizontalAccuracy },
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite,
            originalFilename: filename,
            uniformTypeIdentifier: uti
        )
    }

    static func kind(_ type: PHAssetMediaType) -> MediaKind {
        switch type {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default: .unknown
        }
    }

    static func subtypes(from s: PHAssetMediaSubtype) -> MediaSubtypes {
        var result: MediaSubtypes = []
        if s.contains(.photoPanorama) { result.insert(.panorama) }
        if s.contains(.photoHDR) { result.insert(.hdr) }
        if s.contains(.photoScreenshot) { result.insert(.screenshot) }
        if s.contains(.photoLive) { result.insert(.livePhoto) }
        if s.contains(.photoDepthEffect) { result.insert(.depthEffect) }
        if s.contains(.videoStreamed) { result.insert(.streamed) }
        if s.contains(.videoHighFrameRate) { result.insert(.slowMotion) }
        if s.contains(.videoTimelapse) { result.insert(.timelapse) }
        if s.contains(.videoCinematic) { result.insert(.cinematic) }
        if s.contains(.spatialMedia) { result.insert(.spatial) }
        if s.contains(.videoScreenRecording) { result.insert(.screenRecording) }
        return result
    }

    func currentInventory() async throws -> CollectionInventory {
        let collector = InventoryCollector()
        collector.walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), parent: nil)
        return CollectionInventory(collector.snapshots)
    }

    /// One album or folder without reading the whole list (used to verify every plan step).
    func collection(_ id: CollectionID) async throws -> CollectionSnapshot? {
        let raw = id.rawValue
        let found: PHCollection? = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil).firstObject
            ?? PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject
        guard let found else { return nil }
        let parent = PHCollectionList.fetchCollectionListsContaining(found, options: nil).firstObject.map { CollectionID($0.localIdentifier) }
        return InventoryCollector.snapshot(of: found, parent: parent)
    }

    func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> {
        guard !ids.isEmpty else { return [] }
        var found = Set<AssetID>()
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: chunk.map(\.rawValue), options: nil)
            result.enumerateObjects { asset, _, _ in found.insert(AssetID(asset.localIdentifier)) }
        }
        return found
    }

    // MARK: Writing (closed operation set, prompt §16)

    /// A missing parent folder (deleted on another device) must stop the step: creating the
    /// album anyway would put it at the top level of the library.
    private static func requireFolder(_ id: String?) throws {
        guard let id else { return }
        guard PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject != nil else {
            throw PhotoKitError.collectionNotFound(id)
        }
    }

    func canWrite() async -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID {
        let created = LockedBox<String?>(nil)
        let parentID = parent?.rawValue
        try Self.requireFolder(parentID)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let placeholder = request.placeholderForCreatedCollectionList
            created.value = placeholder.localIdentifier
            if let parentID, let parentList = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [parentID], options: nil).firstObject {
                PHCollectionListChangeRequest(for: parentList)?.addChildCollections([placeholder] as NSArray)
            }
        }
        guard let id = created.value else { throw PhotoKitError.changeFailed("folder") }
        return CollectionID(id)
    }

    func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID {
        let created = LockedBox<String?>(nil)
        let parentID = parent?.rawValue
        try Self.requireFolder(parentID)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let placeholder = request.placeholderForCreatedAssetCollection
            created.value = placeholder.localIdentifier
            if let parentID, let parentList = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [parentID], options: nil).firstObject {
                PHCollectionListChangeRequest(for: parentList)?.addChildCollections([placeholder] as NSArray)
            }
        }
        guard let id = created.value else { throw PhotoKitError.changeFailed("album") }
        return CollectionID(id)
    }

    func addAssets(_ assets: [AssetID], to album: CollectionID) async throws {
        let albumID = album.rawValue
        let ids = assets.map(\.rawValue)
        guard PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject != nil else {
            throw PhotoKitError.collectionNotFound(albumID)
        }
        try await PHPhotoLibrary.shared().performChanges {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetCollectionChangeRequest(for: collection)?.addAssets(fetched)
        }
    }

    func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws {
        let albumID = album.rawValue
        let ids = assets.map(\.rawValue)
        try await PHPhotoLibrary.shared().performChanges {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            // Removes only the album membership; the media stay in the library.
            PHAssetCollectionChangeRequest(for: collection)?.removeAssets(fetched)
        }
    }

    func renameCollection(_ id: CollectionID, to title: String) async throws {
        let raw = id.rawValue
        try await PHPhotoLibrary.shared().performChanges {
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil).firstObject {
                PHAssetCollectionChangeRequest(for: album)?.title = title
            } else if let list = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject {
                PHCollectionListChangeRequest(for: list)?.title = title
            }
        }
    }

    func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
        let raw = id.rawValue
        let oldRaw = oldParent?.rawValue
        let newRaw = newParent?.rawValue
        try await PHPhotoLibrary.shared().performChanges {
            let collection: PHCollection? = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil).firstObject
                ?? PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject
            guard let collection else { return }
            if let oldRaw, let old = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [oldRaw], options: nil).firstObject {
                PHCollectionListChangeRequest(for: old)?.removeChildCollections([collection] as NSArray)
            }
            if let newRaw, let new = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [newRaw], options: nil).firstObject {
                PHCollectionListChangeRequest(for: new)?.addChildCollections([collection] as NSArray)
            }
        }
    }

    func deleteCollection(_ id: CollectionID) async throws {
        let raw = id.rawValue
        // Never delete a folder that still holds something: Photos would delete its contents.
        if let list = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil).firstObject,
           PHCollection.fetchCollections(in: list, options: nil).count > 0 {
            return
        }
        try await PHPhotoLibrary.shared().performChanges {
            // Deletes only the album/folder container. PhotoKit keeps the media.
            let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [raw], options: nil)
            if albums.count > 0 {
                PHAssetCollectionChangeRequest.deleteAssetCollections(albums)
            } else {
                let lists = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [raw], options: nil)
                if lists.count > 0 { PHCollectionListChangeRequest.deleteCollectionLists(lists) }
            }
        }
    }
}

/// Walks the user's folder/album tree.
private final class InventoryCollector {
    var snapshots: [CollectionSnapshot] = []

    func walk(_ result: PHFetchResult<PHCollection>, parent: CollectionID?) {
        result.enumerateObjects { collection, _, _ in
            self.add(collection, parent: parent)
        }
    }

    private func add(_ collection: PHCollection, parent: CollectionID?) {
        guard let snapshot = Self.snapshot(of: collection, parent: parent) else { return }
        snapshots.append(snapshot)
        if let list = collection as? PHCollectionList {
            walk(PHCollection.fetchCollections(in: list, options: nil), parent: snapshot.id)
        }
    }

    /// One album or folder. Albums count hidden photos too: an album that holds a hidden
    /// photo of the user is not "only Albumist's" and must never be deleted by undo.
    static func snapshot(of collection: PHCollection, parent: CollectionID?) -> CollectionSnapshot? {
        let id = CollectionID(collection.localIdentifier)
        var capabilities: CollectionCapabilities = []
        if collection.canPerform(.addContent) { capabilities.insert(.addContent) }
        if collection.canPerform(.removeContent) { capabilities.insert(.removeContent) }
        if collection.canPerform(.rename) { capabilities.insert(.rename) }
        if collection.canPerform(.delete) { capabilities.insert(.delete) }
        if collection.canPerform(.createContent) { capabilities.insert(.createContent) }

        if let list = collection as? PHCollectionList {
            var childIDs: [CollectionID] = []
            PHCollection.fetchCollections(in: list, options: nil).enumerateObjects { child, _, _ in childIDs.append(CollectionID(child.localIdentifier)) }
            return CollectionSnapshot(id: id, title: list.localizedTitle ?? "", kind: .folder, capabilities: capabilities, parentID: parent, childIDs: childIDs)
        } else if let album = collection as? PHAssetCollection {
            var members = Set<AssetID>()
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in members.insert(AssetID(asset.localIdentifier)) }
            let kind: CollectionKind = switch album.assetCollectionType {
            case .smartAlbum: .smartAlbum
            default: album.assetCollectionSubtype == .albumRegular ? .userAlbum : .restrictedAlbum
            }
            return CollectionSnapshot(id: id, title: album.localizedTitle ?? "", kind: kind, capabilities: capabilities, parentID: parent, assetIDs: members)
        }
        return nil
    }
}
