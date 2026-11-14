import Foundation

/// What Albumist remembers about a trip from one analysis to the next, so the trip keeps its
/// identity when its photos change a little: an older photo imported later, the first photo
/// deleted, a day added at the end. Decisions, "do not create again" and the link to the album
/// Albumist made are all bound to the trip's id; a new id would bring a deleted trip album back.
public struct TripIdentity: Hashable, Sendable, Codable {
    public var id: SortlyID
    public var members: [AssetID]

    public init(id: SortlyID, members: [AssetID]) {
        self.id = id
        self.members = members
    }

    public init(_ trip: Trip) {
        self.init(id: trip.id, members: trip.geotaggedAssetIDs)
    }

    /// Gives each newly detected trip the id of the remembered trip it mostly is. A pair
    /// counts when they share at least half of the smaller one's photos; the biggest overlaps
    /// are paired first, each remembered trip is used once (after a split, the bigger part
    /// keeps the id). Trips without a match keep their own id, made unique if needed.
    public static func carryOver(_ trips: [Trip], from previous: [TripIdentity]) -> [Trip] {
        guard !previous.isEmpty, !trips.isEmpty else { return trips }
        var owner: [AssetID: Int] = [:]
        for (index, identity) in previous.enumerated() {
            for asset in identity.members { owner[asset] = index }
        }
        struct Pair { var overlap: Int; var current: Int; var previous: Int }
        var pairs: [Pair] = []
        for (c, trip) in trips.enumerated() {
            var counts: [Int: Int] = [:]
            for asset in trip.geotaggedAssetIDs {
                if let p = owner[asset] { counts[p, default: 0] += 1 }
            }
            for (p, shared) in counts {
                let smaller = min(trip.geotaggedAssetIDs.count, previous[p].members.count)
                if shared * 2 >= smaller { pairs.append(Pair(overlap: shared, current: c, previous: p)) }
            }
        }
        pairs.sort { a, b in
            if a.overlap != b.overlap { return a.overlap > b.overlap }
            if a.current != b.current { return a.current < b.current }
            return a.previous < b.previous
        }
        var result = trips
        var carried = Set<Int>()
        var usedPrevious = Set<Int>()
        for pair in pairs where !carried.contains(pair.current) && !usedPrevious.contains(pair.previous) {
            carried.insert(pair.current)
            usedPrevious.insert(pair.previous)
            result[pair.current].id = previous[pair.previous].id
        }
        // A trip that kept its own id must not collide with an id carried over to another one
        // (after a split the first photo can end up in the smaller part).
        var taken = Set(carried.map { result[$0].id })
        for index in result.indices where !carried.contains(index) {
            var id = result[index].id
            var salt = 1
            while taken.contains(id) {
                id = .stable("trip", result[index].geotaggedAssetIDs.first?.rawValue ?? "", String(salt))
                salt += 1
            }
            result[index].id = id
            taken.insert(id)
        }
        return result
    }
}
