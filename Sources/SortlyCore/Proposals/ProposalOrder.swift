import Foundation

extension Array where Element == AlbumProposal {
    /// The order in which the app lists suggestions everywhere (suggestions list, "Dein
    /// Startpaket", plan preview): areas in app order, trips newest first, everything else
    /// biggest first, then by title. A stable order: rows never jump when one is accepted, and
    /// a name mentioned first on a card also comes first in the preview it opens
    /// (first-time-user walk, 14.11.).
    public func inDisplayOrder() -> [AlbumProposal] {
        let areaRank = Dictionary(uniqueKeysWithValues: OrganizationArea.allCases.enumerated().map { ($0.element, $0.offset) })
        return sorted { lhs, rhs in
            let la = areaRank[lhs.kind.area] ?? Int.max
            let ra = areaRank[rhs.kind.area] ?? Int.max
            if la != ra { return la < ra }
            if lhs.kind.area == .trips, let l = lhs.dateRange?.start, let r = rhs.dateRange?.start, l != r { return l > r }
            if lhs.assetIDs.count != rhs.assetIDs.count { return lhs.assetIDs.count > rhs.assetIDs.count }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }
}
