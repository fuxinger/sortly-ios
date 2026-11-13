import Foundation

/// Language used for generated album titles. Album titles are user data and are
/// generated once; they are not re-translated when the device language changes.
public enum TitleLanguage: String, Sendable, Codable, CaseIterable {
    case german = "de"
    case english = "en"

    public static var deviceDefault: TitleLanguage {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "de"
        return TitleLanguage(rawValue: code) ?? .english
    }
}

/// Formats date ranges in the product's preferred style (prompt §4.2):
/// - same day:          `12.07.2026`
/// - same year:         `03.08.–14.08.2026`
/// - across years:      `28.12.2025–04.01.2026`
/// The range describes the span of the photos, not a proven arrival/departure.
public struct DateRangeFormatter: Sendable {
    public var language: TitleLanguage
    public var timeZone: TimeZone

    public init(language: TitleLanguage = .german, timeZone: TimeZone = .current) {
        self.language = language
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func parts(_ date: Date) -> (y: Int, m: Int, d: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func format(start: Date, end: Date) -> String {
        let a = parts(min(start, end))
        let b = parts(max(start, end))
        switch language {
        case .german:
            func dm(_ p: (y: Int, m: Int, d: Int)) -> String { String(format: "%02d.%02d.", p.d, p.m) }
            if a == b { return dm(a) + String(a.y) }
            if a.y == b.y { return "\(dm(a))–\(dm(b))\(b.y)" }
            return "\(dm(a))\(a.y)–\(dm(b))\(b.y)"
        case .english:
            // Unambiguous ISO-like order avoids the US/UK day-month confusion.
            func iso(_ p: (y: Int, m: Int, d: Int)) -> String { String(format: "%04d-%02d-%02d", p.y, p.m, p.d) }
            if a == b { return iso(a) }
            if a.y == b.y && a.m == b.m { return iso(a) + "–" + String(format: "%02d", b.d) }
            return "\(iso(a))–\(iso(b))"
        }
    }

    public func monthName(_ month: Int) -> String {
        let names: [String]
        switch language {
        case .german: names = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
        case .english: names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        }
        return (1...12).contains(month) ? names[month - 1] : ""
    }

    public func seasonName(_ season: Season) -> String {
        switch (language, season) {
        case (.german, .spring): "Frühling"
        case (.german, .summer): "Sommer"
        case (.german, .autumn): "Herbst"
        case (.german, .winter): "Winter"
        case (.english, .spring): "Spring"
        case (.english, .summer): "Summer"
        case (.english, .autumn): "Autumn"
        case (.english, .winter): "Winter"
        }
    }

    public func continentName(_ continent: Continent) -> String {
        switch (language, continent) {
        case (.german, .africa): "Afrika"
        case (.german, .antarctica): "Antarktis"
        case (.german, .asia): "Asien"
        case (.german, .europe): "Europa"
        case (.german, .northAmerica): "Nordamerika"
        case (.german, .oceania): "Ozeanien"
        case (.german, .southAmerica): "Südamerika"
        case (.english, .africa): "Africa"
        case (.english, .antarctica): "Antarctica"
        case (.english, .asia): "Asia"
        case (.english, .europe): "Europe"
        case (.english, .northAmerica): "North America"
        case (.english, .oceania): "Oceania"
        case (.english, .southAmerica): "South America"
        }
    }

    /// Human readable label of a chronology bucket.
    public func label(for key: ChronologyKey) -> String {
        let c = key.components
        switch key.granularity {
        case .decade: return language == .german ? "\(c[0])er" : "\(c[0])s"
        case .year: return String(c[0])
        case .halfYear: return language == .german ? "\(c[1]). Halbjahr \(c[0])" : "H\(c[1]) \(c[0])"
        case .quarter: return "Q\(c[1]) \(c[0])"
        case .month: return "\(monthName(c[1])) \(c[0])"
        case .isoWeek: return language == .german ? "KW \(c[1]) / \(c[0])" : "Week \(c[1]) / \(c[0])"
        case .day: return language == .german ? String(format: "%02d.%02d.%04d", c[2], c[1], c[0]) : String(format: "%04d-%02d-%02d", c[0], c[1], c[2])
        case .season:
            let season = Season.allCases[c[1]]
            if season == .winter {
                return "\(seasonName(season)) \(c[0] - 1)/\(String(format: "%02d", c[0] % 100))"
            }
            return "\(seasonName(season)) \(c[0])"
        }
    }
}

/// Configurable album naming template (prompt §4.2).
///
/// Variables: `{place}` `{country}` `{region}` `{city}` `{year}` `{month}` `{start}`
/// `{end}` `{range}`. Unknown or empty variables are removed together with dangling
/// separators, so a template never produces "Rom ·" or "– 2026".
public struct NamingTemplate: Hashable, Sendable, Codable {
    public var pattern: String

    public init(_ pattern: String) { self.pattern = pattern }

    public static let tripDefault = NamingTemplate("{place} · {range}")
    public static let tripWithCountry = NamingTemplate("{country} – {place} · {range}")
    public static let tripMonth = NamingTemplate("{place} – {month} {year}")
    public static let tripYearFirst = NamingTemplate("{year} – {place}")
    public static let placeOnly = NamingTemplate("{place}")

    public struct Values: Sendable {
        public var place: String?
        public var country: String?
        public var region: String?
        public var city: String?
        public var start: Date?
        public var end: Date?

        public init(place: String? = nil, country: String? = nil, region: String? = nil, city: String? = nil, start: Date? = nil, end: Date? = nil) {
            self.place = place
            self.country = country
            self.region = region
            self.city = city
            self.start = start
            self.end = end
        }
    }

    public func render(_ values: Values, formatter: DateRangeFormatter) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let startParts = values.start.map { calendar.dateComponents([.year, .month, .day], from: $0) }
        func dayString(_ d: Date?) -> String? {
            guard let d else { return nil }
            return formatter.format(start: d, end: d)
        }
        let replacements: [String: String?] = [
            "place": values.place,
            "country": values.country,
            "region": values.region,
            "city": values.city,
            "year": startParts?.year.map(String.init),
            "month": startParts?.month.map(formatter.monthName),
            "start": dayString(values.start),
            "end": dayString(values.end),
            "range": {
                guard let s = values.start else { return nil }
                return formatter.format(start: s, end: values.end ?? s)
            }(),
        ]

        // Tokenize into literal and variable segments.
        var segments: [(isVariable: Bool, text: String)] = []
        var buffer = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let ch = pattern[index]
            if ch == "{", let close = pattern[index...].firstIndex(of: "}") {
                if !buffer.isEmpty { segments.append((false, buffer)); buffer = "" }
                let name = String(pattern[pattern.index(after: index)..<close])
                let value = replacements[name].flatMap { $0 }?.trimmingCharacters(in: .whitespaces)
                segments.append((true, value ?? ""))
                index = pattern.index(after: close)
            } else {
                buffer.append(ch)
                index = pattern.index(after: index)
            }
        }
        if !buffer.isEmpty { segments.append((false, buffer)) }

        // Drop literal separators adjacent to empty variables.
        var output = ""
        for (i, seg) in segments.enumerated() {
            if seg.isVariable {
                output += seg.text
                continue
            }
            let prevEmpty = i > 0 && segments[i - 1].isVariable && segments[i - 1].text.isEmpty
            let nextEmpty = i + 1 < segments.count && segments[i + 1].isVariable && segments[i + 1].text.isEmpty
            let isSeparator = seg.text.trimmingCharacters(in: CharacterSet(charactersIn: " ·–-—/|,")).isEmpty
            if isSeparator && (prevEmpty || nextEmpty || output.isEmpty) { continue }
            output += seg.text
        }
        return AlbumTitle.sanitize(output)
    }
}

public enum AlbumTitle {
    public static let maxLength = 120

    /// Trims, collapses whitespace and strips dangling separators.
    public static func sanitize(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ·–-—/|,").union(.whitespacesAndNewlines))
        if t.count > maxLength { t = String(t.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// Normalized form used for name-similarity checks (never for identity).
    public static func normalized(_ title: String) -> String {
        PlaceKey.normalize(title)
    }

    /// Token set for fuzzy comparison.
    public static func tokens(_ title: String) -> Set<String> {
        Set(normalized(title).split(separator: "-").map(String.init).filter { $0.count > 1 })
    }
}
