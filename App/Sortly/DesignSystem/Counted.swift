import Foundation

/// Sentences with several counts ("1 Land · 5 Städte · 2 Reisen") are built from parts that
/// are each a plural string in the catalog, so German gets "1 Reise" and not "1 Reisen".
/// (One catalog entry with three numbers cannot pick a singular per number.)
enum Counted {
    static func join(_ parts: [String], separator: String = " · ") -> String {
        parts.joined(separator: separator)
    }
}
