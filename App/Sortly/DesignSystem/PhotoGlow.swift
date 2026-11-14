import SwiftUI
import UIKit
import SortlyCore

/// Soft colours taken from one of the user's photos ("Farben aus den Fotos"): every trip and
/// suggestion gets its own gentle colour wash behind it.
@MainActor
enum PhotoPalette {
    private static var cache: [AssetID: [Color]] = [:]

    /// Four colours, one per quarter of the photo (top left, top right, bottom left, bottom
    /// right), slightly richer and kept in a calm brightness range.
    static func colors(for id: AssetID) async -> [Color] {
        if let cached = cache[id] { return cached }
        guard let image = await ThumbnailCache.shared.image(for: id, side: 60), let cg = image.cgImage else { return [] }
        let colors = sample(cg)
        cache[id] = colors
        return colors
    }

    nonisolated static func sample(_ image: CGImage) -> [Color] {
        let side = 2
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return (0..<(side * side)).map { i in
            let color = UIColor(red: CGFloat(pixels[i * 4]) / 255, green: CGFloat(pixels[i * 4 + 1]) / 255,
                                blue: CGFloat(pixels[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: Double(h), saturation: Double(min(1, s * 1.25)), brightness: Double(min(0.95, max(0.55, b))))
        }
    }
}

/// A colour wash from a photo that fades into the screen background. Decorative only.
struct PhotoGlow: View {
    var id: AssetID?
    @State private var colors: [Color] = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if colors.count == 4 && !reduceTransparency {
                MeshGradient(width: 2, height: 3, points: [
                    [0, 0], [1, 0],
                    [0, 0.5], [1, 0.5],
                    [0, 1], [1, 1],
                ], colors: [
                    colors[0], colors[1],
                    colors[2].opacity(0.55), colors[3].opacity(0.55),
                    .clear, .clear,
                ])
                .opacity(scheme == .dark ? 0.5 : 0.36)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.8), value: colors.count)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: id) {
            guard let id else { return }
            colors = await PhotoPalette.colors(for: id)
        }
    }
}
