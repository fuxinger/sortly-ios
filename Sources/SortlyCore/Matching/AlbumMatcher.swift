import Foundation

/// Set-overlap metrics between a proposal P and an existing album A (prompt §5.2).
public struct OverlapMetrics: Hashable, Sendable, Codable {
    public var proposalCount: Int
    public var albumCount: Int
    public var intersection: Int

    public init(proposalCount: Int, albumCount: Int, intersection: Int) {
        self.proposalCount = proposalCount
        self.albumCount = albumCount
        self.intersection = intersection
    }

    /// Share of the proposal already contained in the album: |P∩A| / |P|.
    public var coverage: Double { proposalCount == 0 ? 0 : Double(intersection) / Double(proposalCount) }
    /// Share of the album that belongs to the proposal: |P∩A| / |A|.
    public var purity: Double { albumCount == 0 ? 0 : Double(intersection) / Double(albumCount) }
    /// |P∩A| / |P∪A|.
    public var jaccard: Double {
        let union = proposalCount + albumCount - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
    /// Proposal members missing in the album: |P \ A|.
    public var missing: Int { proposalCount - intersection }
    /// Album members outside the proposal: |A \ P|.
    public var extra: Int { albumCount - intersection }
}

/// How an existing album relates to a proposal.
public enum AlbumRelation: String, Sendable, Codable {
    case equivalent            // essentially the same set
    case partOfProposal        // album is a (mostly pure) subset → can be extended
    case broaderCollection     // album spans several sibling proposals (e.g. all Italy trips)
    case partialOverlap
}

/// Status of a proposal with respect to existing albums (prompt §5.3).
public enum MatchStatus: String, Sendable, Codable, CaseIterable {
    case alreadyComplete       // Bereits vollständig vorhanden
    case extendable            // Bestehendes Album ergänzbar
    case possibleMatch         // Bestehendes Album möglicherweise passend
    case multipleMatches       // Mehrere passende Alben gefunden
    case nameConflict          // Namenskonflikt ohne ausreichende Inhaltsübereinstimmung
    case newAlbumRequired      // Neues Album erforderlich
    case ambiguous             // Nicht eindeutig zuordenbar
    case notEditable           // Nicht bearbeitbar
}

/// Explanation building blocks; the app renders them as sentences such as
/// "Das bestehende Album enthält bereits 248 dieser Aufnahmen. 38 weitere Bilder passen."
public enum MatchReason: Hashable, Sendable, Codable {
    case albumContains(album: String, contained: Int, total: Int)
    case missingItems(count: Int)
    case albumHasOtherItems(album: String, count: Int)
    case albumIsBroaderCollection(album: String, siblingCount: Int)
    case sameNameDifferentContent(album: String, sharedItems: Int)
    case albumNotEditable(album: String)
    case severalAlbumsMatch(count: Int)
    case weakOverlapOnly(album: String, shared: Int)
    case noExistingAlbum
}

public struct MatchCandidate: Hashable, Sendable, Codable {
    public var albumID: CollectionID
    public var albumTitle: String
    public var metrics: OverlapMetrics
    public var relation: AlbumRelation
    public var nameSimilarity: Double
    public var score: Double
    public var isEditable: Bool
}

public struct MatchResult: Hashable, Sendable, Codable {
    public var proposalID: SortlyID
    public var status: MatchStatus
    public var best: MatchCandidate?
    public var alternatives: [MatchCandidate]
    public var sameNameAlbums: [CollectionID]
    public var reasons: [MatchReason]
}

/// Content-based matching of proposals against the existing album inventory.
///
/// The decision never relies on album names alone (prompt §5.2). Names only break ties
/// and reveal name conflicts. All thresholds are explicit, documented in
/// `docs/ALBUM_MATCHING.md`, and covered by unit tests.
public struct AlbumMatcher: Sendable {
    public struct Thresholds: Hashable, Sendable, Codable {
        /// Minimum share for an album to be considered at all.
        public var candidatePurity = 0.5
        public var candidateCoverage = 0.5
        /// Complete: nothing missing and the album is almost purely this proposal.
        public var completePurity = 0.9
        public var completeCoverage = 0.98
        /// Extendable: album is mostly this proposal and already holds a relevant part.
        public var extendablePurity = 0.8
        public var extendableCoverage = 0.25
        /// Share of an album that lies in *other* sibling proposals before it is
        /// treated as a broader collection (Scenario C).
        public var broaderCollectionShare = 0.2
        /// Two candidates closer than this in score are reported as multiple matches.
        public var multipleMatchScoreGap = 0.15
        public var minimumSharedItems = 3

        public init() {}
    }

    public var thresholds: Thresholds

    public init(thresholds: Thresholds = .init()) {
        self.thresholds = thresholds
    }

    /// Matches all proposals in one pass using an inverted membership index.
    /// - Parameters:
    ///   - overrides: albums the user marked as "passt nicht" for a suggestion are never offered
    ///     for it again (neither as best match nor as alternative); photos the user took out
    ///     of an album do not count as missing.
    ///   - assignments: the album a suggestion was already applied to (from the managed-album
    ///     records). That album stays the suggestion's album even if it holds many other photos
    ///     or another album has the same content, so an applied suggestion never comes back.
    public func match(_ proposals: [AlbumProposal], against inventory: CollectionInventory,
                      overrides: OverrideSet = OverrideSet(),
                      assignments: [SortlyID: CollectionID] = [:]) -> [SortlyID: MatchResult] {
        let membership = inventory.albumMembershipIndex()

        // Sibling map per proposal family, to detect albums that span several siblings.
        var siblingOf: [String: [AssetID: SortlyID]] = [:]
        for p in proposals {
            var map = siblingOf[p.kind.familyKey, default: [:]]
            for a in p.assetIDs where map[a] == nil { map[a] = p.id }
            siblingOf[p.kind.familyKey] = map
        }

        var titleIndex: [String: [CollectionID]] = [:]
        for album in inventory.albums {
            titleIndex[AlbumTitle.normalized(album.title), default: []].append(album.id)
        }

        var results: [SortlyID: MatchResult] = [:]
        for proposal in proposals {
            results[proposal.id] = match(
                proposal,
                inventory: inventory,
                overrides: overrides,
                assigned: assignments[proposal.id],
                membership: membership,
                siblings: siblingOf[proposal.kind.familyKey] ?? [:],
                titleIndex: titleIndex
            )
        }
        return results
    }

    private func match(
        _ proposal: AlbumProposal,
        inventory: CollectionInventory,
        overrides: OverrideSet,
        assigned: CollectionID?,
        membership: [AssetID: [CollectionID]],
        siblings: [AssetID: SortlyID],
        titleIndex: [String: [CollectionID]]
    ) -> MatchResult {
        var intersections: [CollectionID: Int] = [:]
        for asset in proposal.assetIDs {
            for album in membership[asset] ?? [] { intersections[album, default: 0] += 1 }
        }

        let proposalTokens = AlbumTitle.tokens(proposal.title)
        var candidates: [MatchCandidate] = []
        var weak: [MatchCandidate] = []

        for (albumID, shared) in intersections {
            guard let album = inventory[albumID], shared >= min(thresholds.minimumSharedItems, proposal.assetIDs.count),
                  !overrides.isRejectedMatch(albumID, for: proposal.id) else { continue }
            let metrics = OverlapMetrics(proposalCount: proposal.assetIDs.count, albumCount: album.assetIDs.count, intersection: shared)

            // Broader collection: a substantial part of the album belongs to other siblings.
            var otherSiblingItems = 0
            var otherSiblings = Set<SortlyID>()
            for asset in album.assetIDs {
                if let s = siblings[asset], s != proposal.id {
                    otherSiblingItems += 1
                    otherSiblings.insert(s)
                }
            }
            let otherShare = album.assetIDs.isEmpty ? 0 : Double(otherSiblingItems) / Double(album.assetIDs.count)

            let relation: AlbumRelation
            if otherShare >= thresholds.broaderCollectionShare && !otherSiblings.isEmpty && proposal.kind.isEventLike {
                relation = .broaderCollection
            } else if metrics.purity >= thresholds.completePurity && metrics.coverage >= thresholds.completeCoverage {
                relation = .equivalent
            } else if metrics.purity >= thresholds.extendablePurity {
                relation = .partOfProposal
            } else {
                relation = .partialOverlap
            }

            let nameSimilarity = Self.tokenSimilarity(proposalTokens, AlbumTitle.tokens(album.title))
            let weights = Self.weights(for: proposal.kind)
            let score = weights.purity * metrics.purity + weights.coverage * metrics.coverage + weights.name * nameSimilarity

            let candidate = MatchCandidate(
                albumID: albumID,
                albumTitle: album.title,
                metrics: metrics,
                relation: relation,
                nameSimilarity: nameSimilarity,
                score: score,
                isEditable: album.isEditableAlbum
            )
            let qualifies = relation != .broaderCollection
                && (metrics.purity >= thresholds.candidatePurity || metrics.coverage >= thresholds.candidateCoverage)
            if qualifies { candidates.append(candidate) } else { weak.append(candidate) }
        }

        // The album this suggestion was applied to stays its album (first in line).
        if let assigned, let album = inventory[assigned], album.isEditableAlbum, !overrides.isRejectedMatch(assigned, for: proposal.id) {
            candidates.removeAll { $0.albumID == assigned }
            weak.removeAll { $0.albumID == assigned }
            let metrics = OverlapMetrics(proposalCount: proposal.assetIDs.count, albumCount: album.assetIDs.count,
                                         intersection: intersections[assigned] ?? 0)
            candidates.append(MatchCandidate(albumID: assigned, albumTitle: album.title, metrics: metrics, relation: .partOfProposal,
                                             nameSimilarity: Self.tokenSimilarity(proposalTokens, AlbumTitle.tokens(album.title)),
                                             score: 2, isEditable: true))
        }

        candidates.sort { ($0.score, $0.albumID.rawValue) > ($1.score, $1.albumID.rawValue) }
        weak.sort { ($0.score, $0.albumID.rawValue) > ($1.score, $1.albumID.rawValue) }

        let sameName = (titleIndex[AlbumTitle.normalized(proposal.title)] ?? []).sorted()
        var reasons: [MatchReason] = []

        // Prefer editable albums; a read-only smart album must not block a real album.
        let editable = candidates.filter(\.isEditable)
        guard let best = editable.first ?? candidates.first else {
            for broader in weak where broader.relation == .broaderCollection {
                reasons.append(.albumIsBroaderCollection(album: broader.albumTitle, siblingCount: 2))
            }
            if let conflict = sameName.first, let album = inventory[conflict] {
                let shared = intersections[conflict] ?? 0
                reasons.append(.sameNameDifferentContent(album: album.title, sharedItems: shared))
                return MatchResult(proposalID: proposal.id, status: .nameConflict, best: nil, alternatives: weak, sameNameAlbums: sameName, reasons: reasons)
            }
            if let w = weak.first(where: { $0.relation != .broaderCollection }) {
                reasons.append(.weakOverlapOnly(album: w.albumTitle, shared: w.metrics.intersection))
                return MatchResult(proposalID: proposal.id, status: .ambiguous, best: nil, alternatives: weak, sameNameAlbums: sameName, reasons: reasons)
            }
            reasons.append(.noExistingAlbum)
            return MatchResult(proposalID: proposal.id, status: .newAlbumRequired, best: nil, alternatives: weak, sameNameAlbums: sameName, reasons: reasons)
        }

        let alternatives = (candidates.filter { $0.albumID != best.albumID }) + weak
        // Missing photos Albumist may still add: photos the user took out of the album by hand stay out.
        let bestMembers = inventory[best.albumID]?.assetIDs ?? []
        let addable = best.metrics.missing == 0 ? 0 : proposal.assetIDs.filter {
            !bestMembers.contains($0) && overrides.mayAdd($0, toAlbum: best.albumID) && overrides.mayAdd($0, toSource: proposal.id)
        }.count
        // The album already holds everything: there is nothing to choose, even if other
        // albums hold the same photos (a country with one city, a trip that is the whole visit).
        let bestIsComplete = best.isEditable && addable == 0
            && (best.relation == .equivalent || best.relation == .partOfProposal)
        reasons.append(.albumContains(album: best.albumTitle, contained: best.metrics.intersection, total: best.metrics.proposalCount))
        if addable > 0 { reasons.append(.missingItems(count: addable)) }
        if best.metrics.extra > 0 { reasons.append(.albumHasOtherItems(album: best.albumTitle, count: best.metrics.extra)) }

        if !best.isEditable {
            reasons.append(.albumNotEditable(album: best.albumTitle))
            return MatchResult(proposalID: proposal.id, status: .notEditable, best: best, alternatives: alternatives, sameNameAlbums: sameName, reasons: reasons)
        }

        let strongRivals = bestIsComplete ? [] : editable.dropFirst().filter {
            $0.metrics.purity >= thresholds.extendablePurity && best.score - $0.score < thresholds.multipleMatchScoreGap
        }
        if !strongRivals.isEmpty {
            reasons.append(.severalAlbumsMatch(count: strongRivals.count + 1))
            return MatchResult(proposalID: proposal.id, status: .multipleMatches, best: best, alternatives: alternatives, sameNameAlbums: sameName, reasons: reasons)
        }

        let status: MatchStatus
        switch best.relation {
        case _ where bestIsComplete:
            status = .alreadyComplete
        case .equivalent:
            status = .alreadyComplete
        case .partOfProposal where addable == 0:
            status = .alreadyComplete
        case .partOfProposal where best.metrics.coverage >= thresholds.extendableCoverage:
            status = .extendable
        default:
            status = .possibleMatch
        }
        return MatchResult(proposalID: proposal.id, status: status, best: best, alternatives: alternatives, sameNameAlbums: sameName, reasons: reasons)
    }

    struct Weights { var purity: Double; var coverage: Double; var name: Double }

    /// Event albums must be pure; collections may be partial but should be on-topic.
    static func weights(for kind: ProposalKind) -> Weights {
        switch kind {
        case .trip, .customPeriod: Weights(purity: 0.5, coverage: 0.4, name: 0.1)
        case .placeCollection, .frequentPlace, .chronology: Weights(purity: 0.55, coverage: 0.35, name: 0.1)
        default: Weights(purity: 0.6, coverage: 0.3, name: 0.1)
        }
    }

    static func tokenSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }
}

/// Finds groups of existing albums with overlapping content (prompt §5.5).
/// The result only proposes *album structure* merges – never deletion of originals.
public struct AlbumOverlapAnalyzer: Sendable {
    public struct MergeSuggestion: Hashable, Sendable, Codable {
        public var albumIDs: [CollectionID]
        /// Number of distinct media in the union of all albums.
        public var distinctAssetCount: Int
        /// Sum of all album memberships (shows how much overlap there is).
        public var totalMemberships: Int
    }

    public var minJaccard = 0.3
    public var minContainment = 0.7
    public var minAlbumSize = 5

    public init() {}

    public func suggestions(in inventory: CollectionInventory) -> [MergeSuggestion] {
        let albums = inventory.albums.filter { $0.kind == .userAlbum && $0.assetIDs.count >= minAlbumSize }
        let index = Dictionary(uniqueKeysWithValues: albums.enumerated().map { ($1.id, $0) })
        var parent = Array(albums.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }

        // Pairwise intersections through the inverted index (sparse in practice).
        var pairCounts: [Int: [Int: Int]] = [:]
        for (_, albumIDs) in inventory.albumMembershipIndex() {
            let ids = albumIDs.compactMap { index[$0] }.sorted()
            guard ids.count > 1 else { continue }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    pairCounts[ids[i], default: [:]][ids[j], default: 0] += 1
                }
            }
        }
        for (i, row) in pairCounts {
            for (j, shared) in row {
                let a = albums[i].assetIDs.count, b = albums[j].assetIDs.count
                let jaccard = Double(shared) / Double(a + b - shared)
                let containment = Double(shared) / Double(min(a, b))
                if jaccard >= minJaccard || containment >= minContainment {
                    parent[find(i)] = find(j)
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in albums.indices { groups[find(i), default: []].append(i) }
        return groups.values
            .filter { $0.count > 1 }
            .map { members in
                var union = Set<AssetID>()
                var total = 0
                for m in members {
                    union.formUnion(albums[m].assetIDs)
                    total += albums[m].assetIDs.count
                }
                return MergeSuggestion(albumIDs: members.map { albums[$0].id }.sorted(), distinctAssetCount: union.count, totalMemberships: total)
            }
            .sorted { $0.distinctAssetCount > $1.distinctAssetCount }
    }
}
