import Foundation

/// Technical media categories (prompt §4.10). Only categories backed by public PhotoKit
/// metadata are produced. "Large files" is intentionally absent: PhotoKit offers no public,
/// reliable file size without reading the full resource (see KNOWN_LIMITATIONS.md).
public enum MediaTypeCategory: String, Sendable, Codable, CaseIterable {
    case photos, videos, livePhotos, screenshots, screenRecordings, panoramas, bursts,
         slowMotion, timelapse, raw, hdr, portraitMode, spatial, cinematic,
         portraitOrientation, landscapeOrientation, square, shortVideos, longVideos
}

public struct MediaTypeClassifier: Sendable {
    /// Videos shorter than this count as short, longer than `longVideo` as long.
    public var shortVideo: TimeInterval = 30
    public var longVideo: TimeInterval = 5 * 60

    public init() {}

    public func categories(for asset: AssetSnapshot) -> Set<MediaTypeCategory> {
        var result = Set<MediaTypeCategory>()
        let s = asset.subtypes
        switch asset.kind {
        case .image:
            if s.contains(.screenshot) { result.insert(.screenshots) } else { result.insert(.photos) }
            // A Live Photo stays one asset; SORTLY never splits its components.
            if s.contains(.livePhoto) { result.insert(.livePhotos) }
            if s.contains(.panorama) { result.insert(.panoramas) }
            if s.contains(.burst) { result.insert(.bursts) }
            if s.contains(.raw) { result.insert(.raw) }
            if s.contains(.hdr) { result.insert(.hdr) }
            if s.contains(.depthEffect) { result.insert(.portraitMode) }
        case .video:
            if s.contains(.screenRecording) { result.insert(.screenRecordings) } else { result.insert(.videos) }
            if s.contains(.slowMotion) { result.insert(.slowMotion) }
            if s.contains(.timelapse) { result.insert(.timelapse) }
            if s.contains(.cinematic) { result.insert(.cinematic) }
            if asset.duration > 0 && asset.duration < shortVideo { result.insert(.shortVideos) }
            if asset.duration >= longVideo { result.insert(.longVideos) }
        case .audio, .unknown:
            break
        }
        if s.contains(.spatial) { result.insert(.spatial) }
        if asset.kind == .image || asset.kind == .video, !s.contains(.screenshot), !s.contains(.screenRecording) {
            switch asset.orientation {
            case .portrait: result.insert(.portraitOrientation)
            case .landscape: result.insert(.landscapeOrientation)
            case .square: result.insert(.square)
            case .unknown: break
            }
        }
        return result
    }
}
