import Foundation

/// Chronological granularities (prompt §4.9).
public enum ChronologyGranularity: String, Sendable, Codable, CaseIterable, Comparable {
    case decade, year, halfYear, quarter, season, month, isoWeek, day

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Meteorological seasons. Hemisphere-aware: a photo taken in Sydney in January is summer.
public enum Season: String, Sendable, Codable, CaseIterable {
    case spring, summer, autumn, winter
}

/// Identity of one chronological bucket, e.g. year 2026 / month 3.
public struct ChronologyKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var granularity: ChronologyGranularity
    /// Sortable components, e.g. [2026, 3] for March 2026, [2020] for the 2020s.
    public var components: [Int]

    public init(_ granularity: ChronologyGranularity, _ components: [Int]) {
        self.granularity = granularity
        self.components = components
    }

    public var description: String { "\(granularity.rawValue):" + components.map(String.init).joined(separator: "-") }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.granularity != rhs.granularity { return lhs.granularity < rhs.granularity }
        return lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct ChronologyGrouper: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .sortlyDefault) {
        self.calendar = calendar
    }

    /// Bucket for a date. Returns `nil` when the asset has no capture date –
    /// unknown dates are never invented (§4.9).
    public func key(for date: Date?, granularity: ChronologyGranularity, latitude: Double? = nil) -> ChronologyKey? {
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .weekOfYear, .yearForWeekOfYear], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        switch granularity {
        case .decade: return ChronologyKey(.decade, [Int((Double(year) / 10).rounded(.down)) * 10])
        case .year: return ChronologyKey(.year, [year])
        case .halfYear: return ChronologyKey(.halfYear, [year, month <= 6 ? 1 : 2])
        case .quarter: return ChronologyKey(.quarter, [year, (month - 1) / 3 + 1])
        case .month: return ChronologyKey(.month, [year, month])
        case .day: return ChronologyKey(.day, [year, month, day])
        case .isoWeek:
            guard let week = c.weekOfYear, let weekYear = c.yearForWeekOfYear else { return nil }
            return ChronologyKey(.isoWeek, [weekYear, week])
        case .season:
            let (season, seasonYear) = Self.season(month: month, year: year, southernHemisphere: (latitude ?? 1) < 0)
            return ChronologyKey(.season, [seasonYear, Season.allCases.firstIndex(of: season)!])
        }
    }

    /// Meteorological season; December belongs to the winter of the following year
    /// (Winter 2025/26 is keyed as 2026) so a winter is never split in two.
    public static func season(month: Int, year: Int, southernHemisphere: Bool) -> (Season, Int) {
        let northern: Season
        switch month {
        case 3...5: northern = .spring
        case 6...8: northern = .summer
        case 9...11: northern = .autumn
        default: northern = .winter
        }
        let season: Season
        if southernHemisphere {
            switch northern {
            case .spring: season = .autumn
            case .summer: season = .winter
            case .autumn: season = .spring
            case .winter: season = .summer
            }
        } else {
            season = northern
        }
        let seasonYear = (month == 12 && northern == .winter) ? year + 1 : year
        return (season, seasonYear)
    }

    /// Groups assets into nested buckets. `levels` must be ordered coarse → fine,
    /// e.g. [.year, .month]. Assets without date land in `undated`.
    public func group(_ assets: [AssetSnapshot], levels: [ChronologyGranularity]) -> (buckets: [[ChronologyKey]: [AssetID]], undated: [AssetID]) {
        var buckets: [[ChronologyKey]: [AssetID]] = [:]
        var undated: [AssetID] = []
        for asset in assets {
            var path: [ChronologyKey] = []
            for level in levels {
                guard let key = key(for: asset.creationDate, granularity: level, latitude: asset.usableLocation?.latitude) else { break }
                path.append(key)
            }
            if path.count == levels.count {
                buckets[path, default: []].append(asset.id)
            } else {
                undated.append(asset.id)
            }
        }
        return (buckets, undated)
    }
}

/// A user-defined period ("Elternzeit", "Hausbau 2024–2025").
public struct CustomPeriod: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var title: String
    public var start: Date
    public var end: Date

    public init(id: SortlyID = SortlyID(), title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public func contains(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date >= start && date <= end
    }
}
