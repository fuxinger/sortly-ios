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
        // One request resumes the caller exactly once: with the final image, with an error, or
        // with CancellationError when the analysis stops (the PhotoKit request, maybe an
        // iCloud download, is cancelled with it instead of running on).
        let request = ImageRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LoadedImage?, Error>) in
                guard request.start(continuation) else { return }
                let id = PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        request.finish(.failure(CancellationError()))
                        return
                    }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if isDegraded && quality == .original { return } // wait for the final image
                    if let image, let cg = image.cgImage {
                        request.finish(.success(LoadedImage(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))))
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                        request.finish(.failure(AnalysisError.originalNotAvailable))
                    } else {
                        request.finish(.success(nil))
                    }
                }
                request.attach(id)
            }
        } onCancel: {
            request.cancel()
        }
    }
}

/// State of one PhotoKit image request. PhotoKit may call back more than once (degraded,
/// then final), on any thread, even before `requestImage` returns; cancellation can come at
/// any point in between. Every path goes through the lock, so the continuation is resumed
/// once and a cancelled request is cancelled in PhotoKit too.
private final class ImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LoadedImage?, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    /// Stores the continuation, or resumes it at once when the task was already cancelled.
    func start(_ continuation: CheckedContinuation<LoadedImage?, Error>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { PHImageManager.default().cancelImageRequest(id) }
    }

    func finish(_ result: Result<LoadedImage?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
        pending?.resume(throwing: CancellationError())
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
        // OCR needs the full resolution. Screenshots are usually on the device anyway; other
        // originals come from iCloud only with consent (allowNetwork). Fallback: local preview.
        var source: AnalysisImageSource = .original
        var loaded = try? await ImageLoader.image(for: asset.id, quality: .original, allowNetwork: allowNetwork)
        if loaded == nil {
            loaded = try await ImageLoader.image(for: asset.id, quality: .localPreview, allowNetwork: false)
            source = .localPreview
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
        return TextAnalysis(text: lines.joined(separator: "\n"), barcodePayloads: barcodes, source: source)
    }
}
