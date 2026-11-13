import Foundation

/// A feature vector produced on device (e.g. Vision feature print of a face or pet crop).
public struct Embedding: Hashable, Sendable, Codable {
    public var values: [Float]
    public init(_ values: [Float]) { self.values = values }

    public var norm: Float { values.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    public func normalized() -> Embedding {
        let n = norm
        guard n > 0 else { return self }
        return Embedding(values.map { $0 / n })
    }

    /// Cosine distance in [0, 2]; expects normalized vectors for speed.
    public func cosineDistance(to other: Embedding) -> Float {
        precondition(values.count == other.values.count, "embedding dimension mismatch")
        var dot: Float = 0
        for i in values.indices { dot += values[i] * other.values[i] }
        return 1 - dot
    }

    public static func mean(_ embeddings: [Embedding]) -> Embedding? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for e in embeddings { for i in sum.indices { sum[i] += e.values[i] } }
        return Embedding(sum.map { $0 / Float(embeddings.count) }).normalized()
    }
}

/// One detected face or animal on one asset.
public struct VisualObservation: Hashable, Sendable, Codable, Identifiable {
    public var id: String          // "\(assetID)#\(index)"
    public var assetID: AssetID
    public var embedding: Embedding
    /// Detection quality in 0...1 (face capture quality / box size); low-quality crops are
    /// still kept but never used as group anchors.
    public var quality: Float

    public init(id: String, assetID: AssetID, embedding: Embedding, quality: Float) {
        self.id = id
        self.assetID = assetID
        self.embedding = embedding.normalized()
        self.quality = quality
    }
}

public enum GroupKind: String, Sendable, Codable, CaseIterable { case person, dog, cat, otherAnimal }

/// A probabilistic group of observations (prompt §4.4). Names come only from the user.
public struct ObservationGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var kind: GroupKind
    public var observationIDs: [String]
    public var assetIDs: Set<AssetID>
    /// Name typed by the user; `nil` → shown as "Person 1", "Hund 1", ...
    public var confirmedName: String?
    public var isConfirmed: Bool
}

/// User feedback that constrains grouping. Persisted and re-applied on every run, so
/// confirmed facts are stable while unconfirmed guesses never reinforce themselves (§9).
public struct GroupingFeedback: Hashable, Sendable, Codable {
    /// Observations the user confirmed as belonging together (anchor → members).
    public var confirmedGroups: [SortlyID: Set<String>] = [:]
    public var confirmedNames: [SortlyID: String] = [:]
    /// Pairs the user separated ("not the same person").
    public var cannotLink: Set<[String]> = []
    /// Observations the user removed from all groups (e.g. a stranger).
    public var rejected: Set<String> = []

    public init() {}
}

/// Constrained agglomerative grouping for faces and pets.
///
/// - Two observations from the same asset can never be the same individual (cannot-link).
/// - User-confirmed groups are fixed anchors; their centroid comes only from confirmed members.
/// - Threshold-based average-linkage merging, processed in blocks to bound memory.
public struct ObservationGrouper: Sendable {
    public var distanceThreshold: Float
    public var minGroupSize: Int
    public var minAnchorQuality: Float

    public init(distanceThreshold: Float = 0.35, minGroupSize: Int = 3, minAnchorQuality: Float = 0.3) {
        self.distanceThreshold = distanceThreshold
        self.minGroupSize = minGroupSize
        self.minAnchorQuality = minAnchorQuality
    }

    public func group(_ observations: [VisualObservation], kind: GroupKind, feedback: GroupingFeedback = .init()) -> [ObservationGroup] {
        let usable = observations.filter { !feedback.rejected.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })

        struct Cluster {
            var id: SortlyID?
            var members: [String]
            var assets: Set<AssetID>
            var centroid: Embedding
            var locked: Bool
        }

        var clusters: [Cluster] = []
        var assigned = Set<String>()

        // 1. Confirmed groups become locked anchors.
        for (groupID, memberIDs) in feedback.confirmedGroups.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let members = memberIDs.compactMap { byID[$0] }
            guard let centroid = Embedding.mean(members.map(\.embedding)) else { continue }
            clusters.append(Cluster(id: groupID, members: members.map(\.id), assets: Set(members.map(\.assetID)), centroid: centroid, locked: true))
            assigned.formUnion(members.map(\.id))
        }

        let cannotLink = feedback.cannotLink
        func violates(_ obs: VisualObservation, _ cluster: Cluster) -> Bool {
            if cluster.assets.contains(obs.assetID) { return true }
            return cluster.members.contains { cannotLink.contains([obs.id, $0].sorted()) }
        }

        // 2. Greedy assignment in quality order: good crops first so anchors are clean.
        let remaining = usable.filter { !assigned.contains($0.id) }.sorted { ($0.quality, $0.id) > ($1.quality, $1.id) }
        for obs in remaining {
            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for (i, cluster) in clusters.enumerated() {
                let d = obs.embedding.cosineDistance(to: cluster.centroid)
                if d < bestDistance && d <= distanceThreshold && !violates(obs, cluster) {
                    bestDistance = d
                    bestIndex = i
                }
            }
            if let i = bestIndex {
                clusters[i].members.append(obs.id)
                clusters[i].assets.insert(obs.assetID)
                // Locked (confirmed) centroids stay fixed: unconfirmed members never move them.
                if !clusters[i].locked && obs.quality >= minAnchorQuality {
                    let anchorMembers = clusters[i].members.compactMap { byID[$0] }.filter { $0.quality >= minAnchorQuality }
                    clusters[i].centroid = Embedding.mean(anchorMembers.map(\.embedding)) ?? clusters[i].centroid
                }
            } else if obs.quality >= minAnchorQuality {
                clusters.append(Cluster(id: nil, members: [obs.id], assets: [obs.assetID], centroid: obs.embedding, locked: false))
            }
        }

        return clusters
            .filter { $0.locked || $0.members.count >= minGroupSize }
            .map { c in
                let id = c.id ?? .stable("group", kind.rawValue, c.members.sorted().first ?? "")
                return ObservationGroup(
                    id: id,
                    kind: kind,
                    observationIDs: c.members.sorted(),
                    assetIDs: c.assets,
                    confirmedName: feedback.confirmedNames[id],
                    isConfirmed: c.locked
                )
            }
            .sorted { ($0.isConfirmed ? 1 : 0, $0.assetIDs.count) > ($1.isConfirmed ? 1 : 0, $1.assetIDs.count) }
    }
}

/// Example-based personal categories ("Mein Auto", prompt §9): similarity search seeded only
/// with user-confirmed positives and negatives. Suggestions are never added as examples
/// automatically, so wrong guesses cannot reinforce themselves.
public struct ExampleSimilaritySearch: Sendable {
    public var maxDistance: Float

    public init(maxDistance: Float = 0.3) {
        self.maxDistance = maxDistance
    }

    public struct Suggestion: Hashable, Sendable {
        public var assetID: AssetID
        public var distance: Float
    }

    public func suggestions(
        positives: [Embedding],
        negatives: [Embedding],
        candidates: [(AssetID, Embedding)],
        excluding: Set<AssetID>,
        limit: Int = 200
    ) -> [Suggestion] {
        let pos = positives.map { $0.normalized() }
        let neg = negatives.map { $0.normalized() }
        guard !pos.isEmpty else { return [] }
        var result: [Suggestion] = []
        for (id, raw) in candidates where !excluding.contains(id) {
            let e = raw.normalized()
            let dPos = pos.map { e.cosineDistance(to: $0) }.min()!
            guard dPos <= maxDistance else { continue }
            if let dNeg = neg.map({ e.cosineDistance(to: $0) }).min(), dNeg < dPos { continue }
            result.append(Suggestion(assetID: id, distance: dPos))
        }
        return Array(result.sorted { ($0.distance, $0.assetID) < ($1.distance, $1.assetID) }.prefix(limit))
    }
}
