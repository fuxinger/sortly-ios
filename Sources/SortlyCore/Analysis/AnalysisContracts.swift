import Foundation

// Contracts between the platform-independent pipeline and the iOS implementations
// (PhotoKit, Vision, MapKit). The app provides conforming types; tests provide fakes.

/// Photo library access as granted by the user (prompt §7, Schritt 1).
public enum LibraryAccess: String, Sendable, Codable {
    case notDetermined, full, limited, denied, restricted

    /// Full access is needed to organize the whole library; limited access works on the
    /// selected photos only and says so in the UI.
    public var canRead: Bool { self == .full || self == .limited }
}

public protocol PhotoLibraryReading: Sendable {
    func access() async -> LibraryAccess
    /// Snapshots of all readable assets. Hidden assets only when the user opted in.
    func fetchAssets(includeHidden: Bool) async throws -> [AssetSnapshot]
    func currentInventory() async throws -> CollectionInventory
}

/// One classifier label as produced by the image classifier.
public struct LabelScore: Hashable, Sendable, Codable {
    public var identifier: String
    public var confidence: Double
    public init(_ identifier: String, _ confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

public enum AnalysisImageSource: String, Hashable, Sendable, Codable {
    /// Small preview that is always on the device, even with "Optimize iPhone Storage".
    case localPreview
    /// Full-resolution original (may have been downloaded from iCloud).
    case original
}

public struct AnimalObservation: Hashable, Sendable, Codable {
    public var kind: GroupKind
    public var observation: Observation
    public init(kind: GroupKind, observation: Observation) {
        self.kind = kind
        self.observation = observation
    }
}

/// Image content found on the local preview (speed-up 4: no iCloud download needed).
public struct ContentAnalysis: Hashable, Sendable, Codable {
    public var labels: [LabelScore]
    /// Face observations with embeddings; only when face grouping is enabled (GDPR Art. 9).
    public var faces: [Observation]
    public var animals: [AnimalObservation]
    public var featurePrint: Embedding?
    /// The analyzer saw a page-like document (receipt, letter, form).
    public var looksLikeDocument: Bool
    /// The preview contains text regions worth reading in full.
    public var containsText: Bool
    public var source: AnalysisImageSource

    public init(
        labels: [LabelScore] = [],
        faces: [Observation] = [],
        animals: [AnimalObservation] = [],
        featurePrint: Embedding? = nil,
        looksLikeDocument: Bool = false,
        containsText: Bool = false,
        source: AnalysisImageSource = .localPreview
    ) {
        self.labels = labels
        self.faces = faces
        self.animals = animals
        self.featurePrint = featurePrint
        self.looksLikeDocument = looksLikeDocument
        self.containsText = containsText
        self.source = source
    }

    /// Labels that indicate a document even if the analyzer did not flag one.
    static let documentLabels: Set<String> = ["document", "receipt", "printed_page", "paper", "envelope", "letter", "text", "menu", "ticket", "invoice"]

    /// Speed-up 5: full text recognition only for screenshots and document-like images.
    public func needsTextRecognition(for asset: AssetSnapshot) -> Bool {
        if asset.kind == .video { return false }
        if asset.isScreenshotLike { return true }
        if looksLikeDocument { return true }
        return labels.contains { Self.documentLabels.contains($0.identifier) && $0.confidence >= 0.5 }
    }
}

public struct ContentAnalysisRequest: Hashable, Sendable {
    public var classify = true
    public var detectFaces = false
    public var detectAnimals = true
    public var featurePrint = true
    public init(classify: Bool = true, detectFaces: Bool = false, detectAnimals: Bool = true, featurePrint: Bool = true) {
        self.classify = classify
        self.detectFaces = detectFaces
        self.detectAnimals = detectAnimals
        self.featurePrint = featurePrint
    }
}

/// Recognized text of a screenshot or document.
public struct TextAnalysis: Hashable, Sendable, Codable {
    public var text: String
    public var barcodePayloads: [String]
    public var source: AnalysisImageSource
    public init(text: String, barcodePayloads: [String] = [], source: AnalysisImageSource) {
        self.text = text
        self.barcodePayloads = barcodePayloads
        self.source = source
    }
}

public enum AnalysisError: Error, Equatable, Sendable {
    /// The original is only in iCloud and downloading is not allowed right now.
    case originalNotAvailable
    /// The asset vanished or cannot be decoded.
    case unreadable
}

public protocol ContentAnalyzing: Sendable {
    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis
    /// Reads text from the best available image. Throws `AnalysisError.originalNotAvailable`
    /// when the original would have to be downloaded and `allowNetwork` is false.
    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis
}

public enum PauseReason: String, Sendable, Codable {
    case userPaused, thermal, lowPower, batteryLow, timeBudget, accessRevoked
}

/// Device conditions (thermal state, power, network). Implemented with ProcessInfo,
/// UIDevice and NWPathMonitor in the app.
public protocol AnalysisConditions: Sendable {
    func pauseReason() async -> PauseReason?
    func isOnWiFi() async -> Bool
}
