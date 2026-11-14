import Foundation

/// A WGS84 coordinate. Kept independent from CoreLocation so the core runs everywhere.
public struct GeoCoordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// PhotoKit occasionally reports (0,0) or out-of-range values for broken EXIF data.
    /// Those are treated as "no location" – Albumist never invents a place.
    public var isPlausible: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(abs(latitude) < 0.000_1 && abs(longitude) < 0.000_1)
    }
}

/// Mirrors `PHAssetMediaType`.
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case image, video, audio, unknown
}

/// Mirrors the public `PHAssetMediaSubtype` values plus facts Albumist derives from public
/// resource information (RAW, burst). Every flag here must be backed by a public API.
public struct MediaSubtypes: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let panorama        = MediaSubtypes(rawValue: 1 << 0)
    public static let hdr             = MediaSubtypes(rawValue: 1 << 1)
    public static let screenshot      = MediaSubtypes(rawValue: 1 << 2)
    public static let livePhoto       = MediaSubtypes(rawValue: 1 << 3)
    public static let depthEffect     = MediaSubtypes(rawValue: 1 << 4)
    public static let slowMotion      = MediaSubtypes(rawValue: 1 << 5)   // videoHighFrameRate
    public static let timelapse       = MediaSubtypes(rawValue: 1 << 6)
    public static let screenRecording = MediaSubtypes(rawValue: 1 << 7)
    public static let streamed        = MediaSubtypes(rawValue: 1 << 8)
    public static let spatial         = MediaSubtypes(rawValue: 1 << 9)
    public static let cinematic       = MediaSubtypes(rawValue: 1 << 10)
    /// Derived from `PHAssetResource.uniformTypeIdentifier` (RAW / ProRAW resource present).
    public static let raw             = MediaSubtypes(rawValue: 1 << 16)
    /// Derived from `PHAsset.burstIdentifier != nil`.
    public static let burst           = MediaSubtypes(rawValue: 1 << 17)
}

/// Where the pixel data needed for content analysis is available.
public enum AnalysisAvailability: String, Sendable, Codable {
    case unknown
    case local            // a local derivative could be read without network
    case cloudOnly        // only in iCloud; download needed
    case downloadFailed
    case notAnalyzable    // e.g. audio, corrupt
}

/// Immutable snapshot of one asset's metadata, as read from the photo library.
public struct AssetSnapshot: Hashable, Sendable, Codable, Identifiable {
    public var id: AssetID
    public var kind: MediaKind
    public var subtypes: MediaSubtypes
    /// Capture date. `nil` when the library has none – never substituted.
    public var creationDate: Date?
    public var modificationDate: Date?
    public var location: GeoCoordinate?
    /// Horizontal accuracy in metres if known (`CLLocation.horizontalAccuracy`).
    public var locationAccuracy: Double?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: TimeInterval
    public var burstIdentifier: String?
    public var isFavorite: Bool
    /// Original file name from `PHAssetResource`, loaded lazily and only used as a hint.
    public var originalFilename: String?
    public var uniformTypeIdentifier: String?

    public init(
        id: AssetID,
        kind: MediaKind = .image,
        subtypes: MediaSubtypes = [],
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        location: GeoCoordinate? = nil,
        locationAccuracy: Double? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        duration: TimeInterval = 0,
        burstIdentifier: String? = nil,
        isFavorite: Bool = false,
        originalFilename: String? = nil,
        uniformTypeIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.subtypes = subtypes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.location = location
        self.locationAccuracy = locationAccuracy
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.burstIdentifier = burstIdentifier
        self.isFavorite = isFavorite
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
    }

    /// Whether a stored modification date (`.distantPast` for none) is the asset's current
    /// one. Dates pass through the database as seconds since 1970, which can move the last
    /// bit, so they count as equal within a millisecond.
    public static func sameModification(_ stored: Date, _ current: Date?) -> Bool {
        abs(stored.timeIntervalSince1970 - (current ?? .distantPast).timeIntervalSince1970) < 0.001
    }

    /// A location that is safe to use for geographic decisions.
    public var usableLocation: GeoCoordinate? {
        guard let location, location.isPlausible else { return nil }
        if let accuracy = locationAccuracy, accuracy > 5_000 { return nil }
        return location
    }

    public var isScreenshotLike: Bool {
        subtypes.contains(.screenshot) || subtypes.contains(.screenRecording)
    }

    public enum Orientation: String, Sendable, Codable { case portrait, landscape, square, unknown }

    public var orientation: Orientation {
        guard pixelWidth > 0, pixelHeight > 0 else { return .unknown }
        let ratio = Double(pixelWidth) / Double(pixelHeight)
        if abs(ratio - 1) < 0.02 { return .square }
        return ratio > 1 ? .landscape : .portrait
    }
}
