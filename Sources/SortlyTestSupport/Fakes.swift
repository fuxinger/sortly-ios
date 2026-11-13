import Foundation
import Synchronization
import SortlyCore

/// Fake geocoder: answers from a table of nearest fixture places, records calls.
public final class FakeGeocoder: ReverseGeocoding, @unchecked Sendable {
    public let lock = Mutex<[GeoCoordinate]>([])
    public var failures: [GeocodingError] = []
    public let answers: [(GeoCoordinate, PlaceComponents)]

    public init(failures: [GeocodingError] = [], answers: [(GeoCoordinate, PlaceComponents)] = FakeGeocoder.defaultAnswers) {
        self.failures = failures
        self.answers = answers
    }

    public static let defaultAnswers: [(GeoCoordinate, PlaceComponents)] = [
        (Fixture.Places.munichHome, .init(isoCountryCode: "DE", country: "Germany", administrativeArea: "Bavaria", locality: "München")),
        (Fixture.Places.rome, .init(isoCountryCode: "IT", country: "Italy", administrativeArea: "Lazio", locality: "Rom")),
        (GeoCoordinate(latitude: 47.5903, longitude: 7.5893), .init(isoCountryCode: "CH", country: "Switzerland", administrativeArea: "Basel-City", locality: "Basel")),
        (Fixture.Places.gardaLake, .init(isoCountryCode: "IT", country: "Italy", administrativeArea: "Veneto", locality: "Malcesine")),
    ]

    public var calls: [GeoCoordinate] { lock.withLock { $0 } }

    public func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        let failure: GeocodingError? = lock.withLock { calls in
            calls.append(coordinate)
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure { throw failure }
        return answers.min { GeoMath.distance(coordinate, $0.0) < GeoMath.distance(coordinate, $1.0) }?.1
    }
}

public actor MemoryPlaceCache: PlaceCaching {
    public var cells: [String: PlaceComponents] = [:]
    public init() {}
    public func cachedPlace(cell: GeoCell) async throws -> PlaceComponents? { cells[cell.description] }
    public func cachePlace(_ components: PlaceComponents, cell: GeoCell, resolvedAt: Date) async throws { cells[cell.description] = components }
}

/// Manual time: sleeping advances the clock instantly.
public final class ManualTime: @unchecked Sendable {
    public let now = Mutex<Duration>(.zero)
    public init() {}
    public var source: TimeSource {
        TimeSource(elapsed: { self.now.withLock { $0 } }, sleep: { d in self.now.withLock { $0 += d } })
    }
}

public actor ResultCollector {
    public var places: [AssetID: ResolvedPlace] = [:]
    public init() {}
    public func add(_ batch: [AssetID: ResolvedPlace]) { places.merge(batch) { $1 } }
}


/// Photo library reader backed by fixtures.
public actor InMemoryLibraryReader: PhotoLibraryReading {
    public var assets: [AssetSnapshot]
    public var inventory: CollectionInventory
    public var accessLevel: LibraryAccess

    public init(assets: [AssetSnapshot], inventory: CollectionInventory = CollectionInventory(), access: LibraryAccess = .full) {
        self.assets = assets
        self.inventory = inventory
        self.accessLevel = access
    }

    public func set(assets: [AssetSnapshot]) { self.assets = assets }
    public func set(inventory: CollectionInventory) { self.inventory = inventory }
    public func set(access: LibraryAccess) { accessLevel = access }

    public func access() async -> LibraryAccess { accessLevel }
    public func fetchAssets(includeHidden: Bool) async throws -> [AssetSnapshot] { assets }
    public func currentInventory() async throws -> CollectionInventory { inventory }
}

/// Deterministic content analyzer: labels and text come from closures, chosen assets are
/// "only in iCloud" and need the network for text recognition.
public final class FakeContentAnalyzer: ContentAnalyzing, @unchecked Sendable {
    public let labels: @Sendable (AssetSnapshot) -> [LabelScore]
    public let text: @Sendable (AssetSnapshot) -> String
    public let cloudOnly: Set<AssetID>
    public let counts = Mutex<(content: Int, text: Int)>((0, 0))

    public init(
        cloudOnly: Set<AssetID> = [],
        labels: @escaping @Sendable (AssetSnapshot) -> [LabelScore] = { _ in [] },
        text: @escaping @Sendable (AssetSnapshot) -> String = { _ in "" }
    ) {
        self.cloudOnly = cloudOnly
        self.labels = labels
        self.text = text
    }

    public func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        counts.withLock { $0.content += 1 }
        let labels = request.classify ? labels(asset) : []
        return ContentAnalysis(labels: labels, looksLikeDocument: labels.contains { $0.identifier == "document" }, source: .localPreview)
    }

    public func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        counts.withLock { $0.text += 1 }
        if cloudOnly.contains(asset.id) && !allowNetwork { throw AnalysisError.originalNotAvailable }
        return TextAnalysis(text: text(asset), source: cloudOnly.contains(asset.id) ? .original : .localPreview)
    }
}

/// Device conditions for tests: optionally pauses after a number of checks.
public final class FakeConditions: AnalysisConditions, @unchecked Sendable {
    public let state = Mutex<(checks: Int, pauseAfter: Int?, wifi: Bool)>((0, nil, true))

    public init(pauseAfterChecks: Int? = nil, wifi: Bool = true) {
        state.withLock { $0 = (0, pauseAfterChecks, wifi) }
    }

    public func set(pauseAfterChecks: Int?, wifi: Bool = true) {
        state.withLock { $0 = (0, pauseAfterChecks, wifi) }
    }

    public func pauseReason() async -> PauseReason? {
        state.withLock { s in
            s.checks += 1
            if let limit = s.pauseAfter, s.checks > limit { return .thermal }
            return nil
        }
    }

    public func isOnWiFi() async -> Bool { state.withLock { $0.wifi } }
}
