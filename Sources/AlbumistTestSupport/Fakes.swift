import Foundation
import Synchronization
import AlbumistCore

/// Fake geocoder: answers from a table of nearest fixture places, records calls.
public final class FakeGeocoder: ReverseGeocoding, @unchecked Sendable {
    public let lock = Locked<[GeoCoordinate]>([])
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
    public let now = Locked<Duration>(.zero)
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


/// `InMemoryLibraryReader.changes(since:)` set to fail.
public struct ChangesUnanswered: Error {}

/// Photo library reader backed by fixtures.
///
/// Keeps a change history like PhotoKit's (`changes(since:)`): every `set` notes what it
/// changed. `expireHistory()` forgets it (an expired token), `history: false` has none (every
/// run reads the whole library). Counts its work: whole reads, photos read, album walks.
public actor InMemoryLibraryReader: PhotoLibraryReading {
    public private(set) var assets: [AssetSnapshot]
    public private(set) var inventory: CollectionInventory
    public var accessLevel: LibraryAccess
    /// Photos in the Hidden album: only read when the user lets Albumist see them.
    public private(set) var hidden: Set<AssetID>

    /// Whole reads of the library (`fetchAssets(includeHidden:knownDetails:)`).
    public private(set) var wholeReads = 0
    /// Photos read, in whole reads and in reads of changed photos.
    public private(set) var photosRead = 0
    /// Walks over all albums (`currentInventory`).
    public private(set) var inventoryReads = 0

    private let hasHistory: Bool
    /// Tells this library's marks from another one's.
    private let libraryID = UUID()
    private var history: [LibraryChanges] = []
    /// Marks of an earlier epoch are gone (`expireHistory`).
    private var epoch = 0

    /// `progressEvery`: the whole read says how far it is every this many photos, at its
    /// start and at its end, and stops at a Pause, like PhotoKit's (every 250 there). `nil`:
    /// it says nothing (most tests count the progress reports).
    private let progressEvery: Int?

    public init(assets: [AssetSnapshot], inventory: CollectionInventory = CollectionInventory(), access: LibraryAccess = .full,
                hidden: Set<AssetID> = [], history: Bool = true, progressEvery: Int? = nil) {
        self.assets = assets
        self.inventory = inventory
        self.accessLevel = access
        self.hidden = hidden
        self.hasHistory = history
        self.progressEvery = progressEvery
    }

    /// The marks `changes(since:)` was asked for, in order.
    public private(set) var changesAsked: [LibraryChangeMark] = []
    /// `changes(since:)` throws (Photos does not answer).
    private var changesError: (any Error & Sendable)?
    public func set(changesFail: Bool) { changesError = changesFail ? ChangesUnanswered() : nil }
    /// `changes(since:)` throws this (`PhotosNotResponding`, `CancellationError`, ...).
    public func set(changesThrow error: (any Error & Sendable)?) { changesError = error }
    /// Photos a fetch by identifier does not return although they are in the library (a
    /// reader that gets it wrong): only the count says so.
    private var missingFromFetchByID: Set<AssetID> = []
    public func set(missingFromFetchByID ids: Set<AssetID>) { missingFromFetchByID = ids }
    /// Added to the library while the next whole read reads (after it took its list).
    private var arrivingDuringWholeRead: [AssetSnapshot] = []
    public func set(arrivingDuringWholeRead new: [AssetSnapshot]) { arrivingDuringWholeRead = new }
    /// Called at each progress report of a whole read with the photos read so far (a test
    /// pauses there).
    private var onWholeReadProgress: (@Sendable (Int) -> Void)?
    public func set(onWholeReadProgress hook: (@Sendable (Int) -> Void)?) { onWholeReadProgress = hook }

    public func set(assets new: [AssetSnapshot]) {
        let old = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.map(\.id))
        note(assets: Set(new.filter { old[$0.id] != $0 }.map(\.id)), deleted: Set(old.keys).subtracting(newIDs))
        assets = new
    }
    public func set(inventory new: CollectionInventory) {
        if new != inventory { note(other: true) }
        inventory = new
    }
    public func set(access: LibraryAccess) { accessLevel = access }
    /// The photos the user chose under "Ausgewählte Fotos": with `.limited` access only these
    /// are read, and albums show only these of their photos, like PhotoKit. The library itself
    /// does not change (no entry in its history). `nil`: every photo.
    public private(set) var selection: Set<AssetID>?
    public func set(selection new: Set<AssetID>?) { selection = new }
    /// The access the user switches to while the next whole read reads (it reads with it).
    private var accessDuringWholeRead: LibraryAccess?
    public func set(accessDuringNextWholeRead access: LibraryAccess?) { accessDuringWholeRead = access }
    /// Called for each photo a read of changed photos reads (a test pauses there).
    private var onChangedRead: (@Sendable (AssetID) -> Void)?
    public func set(onChangedRead hook: (@Sendable (AssetID) -> Void)?) { onChangedRead = hook }
    public func set(hidden new: Set<AssetID>) {
        note(assets: new.symmetricDifference(hidden))
        hidden = new
    }
    /// The history before now is gone: a mark from before gets no answer (PhotoKit's
    /// `persistentChangeTokenExpired`).
    public func expireHistory() { epoch += 1 }

    private func note(assets changed: Set<AssetID> = [], deleted: Set<AssetID> = [], other: Bool = false) {
        guard !changed.isEmpty || !deleted.isEmpty || other else { return }
        history.append(LibraryChanges(assets: changed, deleted: deleted, other: other, mark: mark(history.count + 1)))
    }

    private func mark(_ position: Int) -> LibraryChangeMark {
        LibraryChangeMark(Data("\(libraryID.uuidString)|\(epoch)|\(position)".utf8))
    }

    private func readable(_ asset: AssetSnapshot, includeHidden: Bool) -> Bool {
        (includeHidden || !hidden.contains(asset.id)) && selected(asset.id)
    }

    private func selected(_ id: AssetID) -> Bool {
        guard accessLevel == .limited, let selection else { return true }
        return selection.contains(id)
    }

    /// Like PhotoKit: file details (name, type, RAW flag) only for assets that are new to the
    /// store or changed since their details were stored.
    private func read(_ asset: AssetSnapshot, knownDetails: [AssetID: Date]) -> AssetSnapshot {
        photosRead += 1
        guard let known = knownDetails[asset.id], AssetSnapshot.sameModification(known, asset.modificationDate) else { return asset }
        var bare = asset
        bare.uniformTypeIdentifier = nil
        bare.originalFilename = nil
        bare.subtypes.remove(.raw)
        return bare
    }

    public func access() async -> LibraryAccess { accessLevel }
    public func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot] {
        try await fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails) { _, _ in true }
    }
    public func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                            progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> [AssetSnapshot] {
        wholeReads += 1
        if let switched = accessDuringWholeRead {
            accessLevel = switched
            accessDuringWholeRead = nil
        }
        let visible = assets.filter { readable($0, includeHidden: includeHidden) }
        if !arrivingDuringWholeRead.isEmpty {
            set(assets: assets + arrivingDuringWholeRead)
            arrivingDuringWholeRead = []
        }
        guard let every = progressEvery else { return visible.map { self.read($0, knownDetails: knownDetails) } }
        var done: [AssetSnapshot] = []
        onWholeReadProgress?(0)
        if !progress(0, visible.count) { throw LibraryReadPaused(read: []) }
        for asset in visible {
            done.append(self.read(asset, knownDetails: knownDetails))
            if done.count % every == 0 {
                onWholeReadProgress?(done.count)
                if !progress(done.count, visible.count) { throw LibraryReadPaused(read: done) }
            }
        }
        _ = progress(done.count, visible.count)
        return done
    }
    public func currentInventory() async throws -> CollectionInventory {
        inventoryReads += 1
        guard accessLevel == .limited, let selection else { return inventory }
        return CollectionInventory(inventory.collections.values.map { album in
            var seen = album
            seen.assetIDs.formIntersection(selection)
            return seen
        })
    }

    public func changeMark() async -> LibraryChangeMark? {
        hasHistory ? mark(history.count) : nil
    }

    public func changes(since mark: LibraryChangeMark, limit: Int) async throws -> LibraryChanges? {
        changesAsked.append(mark)
        if let changesError { throw changesError }
        guard hasHistory else { return nil }
        let parts = String(decoding: mark.data, as: UTF8.self).split(separator: "|")
        guard parts.count == 3, parts[0] == Substring(libraryID.uuidString), Int(parts[1]) == epoch, let position = Int(parts[2]),
              position <= history.count else { return nil }
        var out = LibraryChanges(mark: self.mark(history.count))
        for change in history[position...] {
            // A photo deleted and back (or added after it was deleted) is read again; one
            // changed and then deleted is gone.
            out.assets.subtract(change.deleted)
            out.deleted.formUnion(change.deleted)
            out.deleted.subtract(change.assets)
            out.assets.formUnion(change.assets)
            out.other = out.other || change.other
            if out.assets.count + out.deleted.count > limit {
                return LibraryChanges(mark: out.mark, tooMany: true)
            }
        }
        return out
    }

    public func fetchAssets(_ ids: Set<AssetID>, includeHidden: Bool, knownDetails: [AssetID: Date],
                            progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> ChangedAssets {
        let visible = assets.filter { readable($0, includeHidden: includeHidden) }
        var read: [AssetSnapshot] = []
        for asset in visible where ids.contains(asset.id) && !missingFromFetchByID.contains(asset.id) {
            read.append(self.read(asset, knownDetails: knownDetails))
            onChangedRead?(asset.id)
            if !progress(read.count, ids.count) { throw LibraryReadPaused(read: read) }
        }
        return ChangedAssets(assets: read, libraryCount: visible.count)
    }
}

/// Deterministic content analyzer: labels and text come from closures, chosen assets are
/// "only in iCloud" and need the network for text recognition.
public final class FakeContentAnalyzer: ContentAnalyzing, @unchecked Sendable {
    public let labels: @Sendable (AssetSnapshot) -> [LabelScore]
    public let text: @Sendable (AssetSnapshot) -> String
    public let cloudOnly: Set<AssetID>
    public let counts = Locked<(content: Int, text: Int)>((0, 0))

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
        return TextAnalysis(text: text(asset), source: .original)
    }
}

/// Device conditions for tests: optionally pauses after a number of checks.
public final class FakeConditions: AnalysisConditions, @unchecked Sendable {
    public let state = Locked<(checks: Int, pauseAfter: Int?, wifi: Bool)>((0, nil, true))

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

    /// Scripted answers for runs in the app, one per check; the last one stays. Empty: the
    /// thermal pause above ends the run, as before.
    public let paces = Locked<[AnalysisPace]>([])
    public let paceChecks = Locked(0)

    public func pace() async -> AnalysisPace {
        paceChecks.withLock { $0 += 1 }
        let scripted: AnalysisPace? = paces.withLock { list in
            guard let first = list.first else { return nil }
            if list.count > 1 { list.removeFirst() }
            return first
        }
        if let scripted { return scripted }
        if let reason = await pauseReason() { return .stop(reason) }
        return .normal
    }

    public func isOnWiFi() async -> Bool { state.withLock { $0.wifi } }
}
