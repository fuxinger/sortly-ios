import Foundation
import SortlyCore

/// Bundled offline world map (Natural Earth, public domain – "Made with Natural Earth").
/// Kept in its own module so the core stays free of large resources.
public enum WorldMapResource {
    public static var url: URL? { Bundle.module.url(forResource: "world", withExtension: "sortlymap") }

    /// Loads the bundled map. Callers should keep one instance (≈ 5 MB in memory).
    public static func load(borderMarginMeters: Double = 1_500) throws -> OfflineWorldMap {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try OfflineWorldMap(data: try Data(contentsOf: url, options: .mappedIfSafe), borderMarginMeters: borderMarginMeters)
    }
}
