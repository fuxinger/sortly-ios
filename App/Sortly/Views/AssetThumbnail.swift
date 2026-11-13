import Photos
import SwiftUI
import UIKit
import SortlyCore

/// Thumbnails come straight from Photos every time; SORTLY stores no copies.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 600 }

    func image(for id: AssetID, side: CGFloat) async -> UIImage? {
        let key = "\(id.rawValue)#\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let scale = UITraitCollection.current.displayScale
        let size = CGSize(width: side * scale, height: side * scale)
        let image: UIImage? = await withCheckedContinuation { continuation in
            let resumed = LockedBox(false)
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // Take the first image; an opportunistic final image would arrive later.
                guard !resumed.value else { return }
                if degraded && image == nil { return }
                resumed.value = true
                continuation.resume(returning: image)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
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
