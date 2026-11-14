import Foundation
import SortlyCore

/// Sentences with several counts ("1 Land · 5 Städte · 2 Reisen") are built from parts that
/// are each a plural string in the catalog, so German gets "1 Reise" and not "1 Reisen".
/// (One catalog entry with three numbers cannot pick a singular per number.)
enum Counted {
    static func join(_ parts: [String], separator: String = " · ") -> String {
        parts.joined(separator: separator)
    }

    /// "25 neue Alben, 236 Fotos einsortiert." Parts that are zero are left out
    /// ("0 ergänzt" only raised the question what that means).
    static func resultLine(_ summary: PlanSummary) -> String {
        var parts: [String] = []
        if summary.newAlbums > 0 { parts.append(String(localized: "\(summary.newAlbums) neue Alben")) }
        if summary.extendedAlbums > 0 { parts.append(String(localized: "\(summary.extendedAlbums) ergänzt")) }
        parts.append(String(localized: "\(summary.distinctAssets) Fotos einsortiert"))
        return join(parts, separator: ", ") + "."
    }

    /// History row in Settings: "25 neu, 236 Fotos", zero parts left out.
    static func historyLine(_ summary: PlanSummary) -> String {
        var parts: [String] = []
        if summary.newAlbums > 0 { parts.append(String(localized: "\(summary.newAlbums) neu")) }
        if summary.extendedAlbums > 0 { parts.append(String(localized: "\(summary.extendedAlbums) ergänzt")) }
        parts.append(String(localized: "\(summary.distinctAssets) Fotos"))
        return join(parts, separator: ", ")
    }
}
