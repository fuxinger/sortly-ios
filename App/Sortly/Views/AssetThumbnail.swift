import Photos
import SwiftUI
import UIKit
import SortlyCore

/// Thumbnails come straight from Photos every time; SORTLY stores no copies.
/// The in-memory cache is limited by decoded bytes, asset lookups are cached, and requests for
/// cells scrolled out of view are cancelled so fast scrolling stays smooth.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let manager = ThumbnailRequest.Manager(PHCachingImageManager())
    private let cache = NSCache<NSString, UIImage>()
    private let assets = NSCache<NSString, PHAsset>()

    init() {
        cache.totalCostLimit = 80 * 1024 * 1024
        cache.countLimit = 2000
        assets.countLimit = 6000
    }

    func image(for id: AssetID, side: CGFloat) async -> UIImage? {
        let key = "\(id.rawValue)#\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let asset: PHAsset
        if let known = assets.object(forKey: id.rawValue as NSString) {
            asset = known
        } else {
            guard let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else { return nil }
            assets.setObject(fetched, forKey: id.rawValue as NSString)
            asset = fetched
        }
        let scale = UITraitCollection.current.displayScale
        let size = CGSize(width: side * scale, height: side * scale)
        let image = await ThumbnailRequest.load(ThumbnailRequest.Asset(asset), size: size, manager: manager)
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}

/// PhotoKit request outside the main actor (its callbacks must not inherit main-actor
/// isolation, see the demo-library crash) with proper cancellation.
enum ThumbnailRequest {
    /// PHImageManager and PHAsset are thread-safe but not marked Sendable.
    struct Manager: @unchecked Sendable {
        let value: PHCachingImageManager
        init(_ value: PHCachingImageManager) { self.value = value }
    }
    struct Asset: @unchecked Sendable {
        let value: PHAsset
        init(_ value: PHAsset) { self.value = value }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UIImage?, Never>?
        private var requestID: PHImageRequestID?
        private var cancelled = false

        /// Returns false if the task was cancelled before the request could start.
        func begin(_ c: CheckedContinuation<UIImage?, Never>) -> Bool {
            lock.withLock {
                if cancelled { return false }
                continuation = c
                return true
            }
        }
        func started(_ id: PHImageRequestID) { lock.withLock { requestID = id } }
        func finish(_ image: UIImage?) {
            let c: CheckedContinuation<UIImage?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: image)
        }
        func cancel() -> PHImageRequestID? {
            lock.withLock {
                cancelled = true
                return requestID
            }
        }
    }

    nonisolated static func load(_ asset: Asset, size: CGSize, manager: Manager) async -> UIImage? {
        let state = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.begin(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                let id = manager.value.requestImage(for: asset.value, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    let failed = (info?[PHImageCancelledKey] as? Bool) ?? false || info?[PHImageErrorKey] != nil
                    // Take the first usable image; an opportunistic final image would arrive later.
                    if degraded && image == nil && !failed { return }
                    state.finish(image)
                }
                state.started(id)
            }
        } onCancel: {
            if let id = state.cancel() { manager.value.cancelImageRequest(id) }
            state.finish(nil)
        }
    }
}

struct AssetThumbnail: View {
    var id: AssetID
    var side: CGFloat = 80
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: id) { image = await ThumbnailCache.shared.image(for: id, side: side) }
            .accessibilityHidden(true)
    }
}

/// Grid of thumbnails with a "+N" tile.
struct ThumbnailGrid: View {
    var ids: [AssetID]
    var columns = 4
    var limit = 12

    var body: some View {
        let shown = Array(ids.prefix(limit))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                AssetThumbnail(id: id, side: 100)
                    .aspectRatio(1, contentMode: .fill)
                    .overlay {
                        if index == shown.count - 1 && ids.count > limit {
                            Color.black.opacity(0.45)
                            Text("+\(ids.count - limit + 1)").font(.headline).foregroundStyle(.white)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
