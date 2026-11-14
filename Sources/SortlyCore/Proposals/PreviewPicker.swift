import Foundation

/// Picks the photos a suggestion shows as its preview: spread evenly over its time span
/// (a trip shows its first day, its middle and its last evening, not eight photos from one
/// morning), oldest first, and always including the cover photo.
public enum PreviewPicker {
    /// All members in time order (undated last, ties by id so the order never jumps).
    public static func chronological(_ ids: some Collection<AssetID>, dates: [AssetID: Date]) -> [AssetID] {
        ids.sorted { a, b in
            switch (dates[a], dates[b]) {
            case let (x?, y?): x == y ? a < b : x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a < b
            }
        }
    }

    public static func pick(_ ids: some Collection<AssetID>, dates: [AssetID: Date], cover: AssetID?, count: Int) -> [AssetID] {
        let ordered = chronological(ids, dates: dates)
        guard count > 0, ordered.count > count else { return ordered }
        var indices = count == 1 ? [0] : (0..<count).map { $0 * (ordered.count - 1) / (count - 1) }
        if let cover, let coverIndex = ordered.firstIndex(of: cover), !indices.contains(coverIndex) {
            // The closest pick makes room for the cover; first and last stay when possible.
            let replace = indices.indices.min { abs(indices[$0] - coverIndex) < abs(indices[$1] - coverIndex) } ?? 0
            indices[replace] = coverIndex
            indices.sort()
        }
        return indices.map { ordered[$0] }
    }
}
