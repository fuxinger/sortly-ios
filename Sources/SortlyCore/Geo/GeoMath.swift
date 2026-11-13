import Foundation

public enum GeoMath {
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Spherical centroid – correct across the antimeridian.
    public static func centroid<S: Sequence>(_ coordinates: S) -> GeoCoordinate? where S.Element == GeoCoordinate {
        var x = 0.0, y = 0.0, z = 0.0, n = 0.0
        for c in coordinates {
            let lat = c.latitude * .pi / 180
            let lon = c.longitude * .pi / 180
            x += cos(lat) * cos(lon)
            y += cos(lat) * sin(lon)
            z += sin(lat)
            n += 1
        }
        guard n > 0 else { return nil }
        x /= n; y /= n; z /= n
        let hyp = sqrt(x * x + y * y)
        guard hyp > 1e-12 || abs(z) > 1e-12 else { return nil }
        return GeoCoordinate(latitude: atan2(z, hyp) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
    }

    /// Metres per degree of latitude (approximately constant).
    public static let metersPerDegreeLatitude = 111_320.0
}

/// Quantized geographic cell. Used as spatial index for clustering and as cache key for
/// reverse geocoding ("a resolved place is not re-requested for every photo", §4.1).
public struct GeoCell: Hashable, Sendable, Codable, CustomStringConvertible {
    public let x: Int
    public let y: Int
    public let sizeMeters: Double

    public init(x: Int, y: Int, sizeMeters: Double) {
        self.x = x
        self.y = y
        self.sizeMeters = sizeMeters
    }

    public init(_ c: GeoCoordinate, sizeMeters: Double) {
        let latStep = sizeMeters / GeoMath.metersPerDegreeLatitude
        let yIndex = Int((c.latitude / latStep).rounded(.down))
        // Use the cell's latitude band so the longitude step is stable within a band.
        let bandLat = (Double(yIndex) + 0.5) * latStep
        let lonStep = latStep / max(cos(bandLat * .pi / 180), 0.01)
        self.x = Int((c.longitude / lonStep).rounded(.down))
        self.y = yIndex
        self.sizeMeters = sizeMeters
    }

    public var description: String { "\(Int(sizeMeters))m:\(x):\(y)" }

    /// The 3×3 neighbourhood including this cell.
    public var neighbourhood: [GeoCell] {
        var cells: [GeoCell] = []
        cells.reserveCapacity(9)
        for dy in -1...1 {
            let ny = y + dy
            for dx in -1...1 {
                cells.append(GeoCell(x: x + dx, y: ny, sizeMeters: sizeMeters))
            }
        }
        return cells
    }
}
