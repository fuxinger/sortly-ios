import Foundation
import ImageIO
import Photos
import UIKit
import Vision
import SortlyCore

/// CGImage plus orientation, safe to pass between tasks (the image is immutable).
struct LoadedImage: @unchecked Sendable {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
}

enum ImageQuality {
    /// The small preview Photos always keeps on the device (no download, speed-up 4).
    case localPreview
    /// The full original; may need iCloud.
    case original
}

/// Loads images from PhotoKit for analysis.
enum ImageLoader {
    static func image(for id: AssetID, quality: ImageQuality, allowNetwork: Bool) async throws -> LoadedImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else {
            throw AnalysisError.unreadable
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = allowNetwork
        options.version = .current
        let target: CGSize
        switch quality {
        case .localPreview:
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            target = CGSize(width: 512, height: 512)
        case .original:
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            target = CGSize(width: 2_400, height: 2_400)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBox(false)
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded && quality == .original { return } // wait for the final image
                guard !resumed.value else { return }
                resumed.value = true
                if let image, let cg = image.cgImage {
                    continuation.resume(returning: LoadedImage(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation)))
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    continuation.resume(throwing: AnalysisError.originalNotAvailable)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// On-device image understanding with Apple's Vision framework (no network, no upload).
struct VisionAnalyzer: ContentAnalyzing {
    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        guard asset.kind == .image || asset.kind == .video else { return ContentAnalysis() }
        guard let image = try await ImageLoader.image(for: asset.id, quality: .localPreview, allowNetwork: false) else {
            throw AnalysisError.unreadable
        }
        var labels: [LabelScore] = []
        if request.classify {
            let observations = try await ClassifyImageRequest().perform(on: image.cgImage, orientation: image.orientation)
            labels = observations
                .filter { $0.confidence >= 0.1 }
                .map { LabelScore($0.identifier, Double($0.confidence)) }
        }
        // Individual faces and pets need identity embeddings; they are produced only after
        // the user opted in (GDPR Art. 9). The grouping UI ships in a later iteration.
        return ContentAnalysis(labels: labels, source: .localPreview)
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        // Screenshots are always local and small; documents may need the original.
        let quality: ImageQuality = asset.isScreenshotLike ? .localPreview : .original
        var loaded = try await ImageLoader.image(for: asset.id, quality: .original, allowNetwork: allowNetwork && quality == .original)
        if loaded == nil, quality == .original {
            loaded = try await ImageLoader.image(for: asset.id, quality: .localPreview, allowNetwork: false)
        }
        guard let image = loaded else { throw AnalysisError.unreadable }

        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        let lines = try await textRequest.perform(on: image.cgImage, orientation: image.orientation)
            .compactMap { $0.topCandidates(1).first?.string }
        let barcodes = (try? await DetectBarcodesRequest().perform(on: image.cgImage, orientation: image.orientation))?
            .compactMap(\.payloadString) ?? []
        return TextAnalysis(text: lines.joined(separator: "\n"), barcodePayloads: barcodes, source: .original)
    }
}
