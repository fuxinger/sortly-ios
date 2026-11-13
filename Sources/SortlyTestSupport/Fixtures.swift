import Foundation
import SortlyCore

/// Deterministic fixtures for tests and SwiftUI previews. Never used in production code paths.
public enum Fixture {
    public static let utc: TimeZone = TimeZone(identifier: "UTC")!

    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// `"2024-05-12 10:30"` or `"2024-05-12"` in UTC.
    public static func date(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = string.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        guard let d = f.date(from: string) else { fatalError("bad fixture date \(string)") }
        return d
    }

    public enum Places {
        public static let munichHome = GeoCoordinate(latitude: 48.1371, longitude: 11.5754)
        public static let munichWork = GeoCoordinate(latitude: 48.1500, longitude: 11.5600)
        public static let rome = GeoCoordinate(latitude: 41.8986, longitude: 12.4769)
        public static let florence = GeoCoordinate(latitude: 43.7696, longitude: 11.2558)
        public static let naples = GeoCoordinate(latitude: 40.8518, longitude: 14.2681)
        public static let gardaLake = GeoCoordinate(latitude: 45.6389, longitude: 10.7203)
        public static let tegernsee = GeoCoordinate(latitude: 47.7128, longitude: 11.7584)
        public static let sydney = GeoCoordinate(latitude: -33.8688, longitude: 151.2093)
    }

    /// Small deterministic jitter (metres) so clustered points are not identical.
    public static func jitter(_ c: GeoCoordinate, seed: Int, meters: Double = 60) -> GeoCoordinate {
        let a = Double((seed &* 2_654_435_761) % 1000) / 1000.0 - 0.5
        let b = Double((seed &* 40_503 &+ 17) % 1000) / 1000.0 - 0.5
        let dLat = a * meters / GeoMath.metersPerDegreeLatitude
        let dLon = b * meters / (GeoMath.metersPerDegreeLatitude * cos(c.latitude * .pi / 180))
        return GeoCoordinate(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}

/// Builds realistic synthetic libraries: daily life at home plus trips.
public struct LibraryBuilder {
    public private(set) var assets: [AssetSnapshot] = []
    private var counter = 0

    public init() {}

    public mutating func photo(
        at date: Date,
        _ location: GeoCoordinate?,
        kind: MediaKind = .image,
        subtypes: MediaSubtypes = [],
        filename: String? = nil,
        jitterMeters: Double = 60
    ) -> AssetID {
        counter += 1
        let id = AssetID(String(format: "asset-%06d", counter))
        assets.append(AssetSnapshot(
            id: id,
            kind: kind,
            subtypes: subtypes,
            creationDate: date,
            location: location.map { Fixture.jitter($0, seed: counter, meters: jitterMeters) },
            pixelWidth: 4032,
            pixelHeight: 3024,
            originalFilename: filename
        ))
        return id
    }

    /// `perDay` photos every day from `from` to `to` (inclusive) at `location`.
    @discardableResult
    public mutating func daily(from: String, to: String, at location: GeoCoordinate?, perDay: Int = 2, everyNthDay: Int = 1, hour: Int = 12, skipping: [(String, String)] = []) -> [AssetID] {
        var ids: [AssetID] = []
        let cal = Fixture.calendar
        var day = Fixture.date(from)
        let end = Fixture.date(to)
        let skipRanges = skipping.map { Fixture.date($0.0)...Fixture.date($0.1) }
        var index = 0
        while day <= end {
            if index % everyNthDay == 0 && !skipRanges.contains(where: { $0.contains(day) }) {
                for p in 0..<perDay {
                    let date = cal.date(byAdding: .minute, value: hour * 60 + p * 37, to: day)!
                    ids.append(photo(at: date, location))
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
            index += 1
        }
        return ids
    }
}
