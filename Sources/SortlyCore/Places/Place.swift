import Foundation

/// Geographic hierarchy levels Albumist can organize by (prompt §4.1).
public enum PlaceLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case continent = 0
    case country
    case administrativeArea      // Bundesland / state
    case subAdministrativeArea   // Region / Landkreis / province
    case locality                // Stadt / Gemeinde
    case subLocality             // Stadtviertel
    case thoroughfare            // Straßenbereich
    case pointOfInterest         // Sehenswürdigkeit / area of interest

    public static func < (lhs: PlaceLevel, rhs: PlaceLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where place information came from. Content-based guesses are kept strictly apart
/// from GPS-based results (prompt §4.1).
public enum PlaceSource: String, Sendable, Codable {
    case gpsReverseGeocoded
    case gpsUnresolved     // has GPS but geocoding not (yet) possible
    case contentInferred   // guessed from image content/text, never mixed with GPS
    case userAssigned
}

/// Address components of a resolved place. Mirrors what reverse geocoding provides
/// (`CLPlacemark` / MapKit address representations). Every field is optional: Albumist
/// never fills a gap with a guess.
public struct PlaceComponents: Hashable, Sendable, Codable {
    public var isoCountryCode: String?
    public var country: String?
    public var administrativeArea: String?
    public var subAdministrativeArea: String?
    public var locality: String?
    public var subLocality: String?
    public var thoroughfare: String?
    public var areaOfInterest: String?
    public var inlandWater: String?
    public var ocean: String?
    /// IANA identifier of the local time zone, used to format trip dates in local time.
    public var timeZoneIdentifier: String?

    public init(
        isoCountryCode: String? = nil,
        country: String? = nil,
        administrativeArea: String? = nil,
        subAdministrativeArea: String? = nil,
        locality: String? = nil,
        subLocality: String? = nil,
        thoroughfare: String? = nil,
        areaOfInterest: String? = nil,
        inlandWater: String? = nil,
        ocean: String? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.isoCountryCode = isoCountryCode?.uppercased()
        self.country = country
        self.administrativeArea = administrativeArea
        self.subAdministrativeArea = subAdministrativeArea
        self.locality = locality
        self.subLocality = subLocality
        self.thoroughfare = thoroughfare
        self.areaOfInterest = areaOfInterest
        self.inlandWater = inlandWater
        self.ocean = ocean
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var continent: Continent? {
        isoCountryCode.flatMap(Continent.forCountryCode)
    }

    /// Display name for a level (continent names are localized by the app layer).
    public func name(at level: PlaceLevel) -> String? {
        switch level {
        case .continent: continent?.rawValue
        case .country: country
        case .administrativeArea: administrativeArea
        case .subAdministrativeArea: subAdministrativeArea
        case .locality: locality
        case .subLocality: subLocality
        case .thoroughfare: thoroughfare
        case .pointOfInterest: areaOfInterest ?? inlandWater
        }
    }

    /// Normalized identity for a level, including all parent levels, e.g.
    /// `it/lazio/roma` for a locality. Two photos share a place at a level only if their
    /// keys are equal – this avoids merging "Frankfurt am Main" and "Frankfurt (Oder)".
    public func key(at level: PlaceLevel) -> PlaceKey? {
        guard name(at: level) != nil else { return nil }
        var parts: [String] = []
        for current in PlaceLevel.allCases where current <= level {
            if current == .continent {
                if level == .continent, let c = continent { parts.append(c.rawValue) }
                continue
            }
            if current == .country {
                guard let code = isoCountryCode ?? country.map(PlaceKey.normalize) else { return nil }
                parts.append(code.lowercased())
                continue
            }
            if let value = name(at: current) {
                parts.append(PlaceKey.normalize(value))
            } else if current == level {
                return nil
            }
        }
        return parts.isEmpty ? nil : PlaceKey(level: level, path: parts.joined(separator: "/"))
    }

    /// Most specific human-readable name that is available, up to `maxLevel`.
    public func bestName(maxLevel: PlaceLevel = .locality) -> String? {
        for level in PlaceLevel.allCases.reversed() where level <= maxLevel && level >= .country {
            if let n = name(at: level) { return n }
        }
        return nil
    }
}

/// Normalized place identity at a given level.
public struct PlaceKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var level: PlaceLevel
    public var path: String

    public init(level: PlaceLevel, path: String) {
        self.level = level
        self.path = path
    }

    public var description: String { "\(level):\(path)" }

    public static func < (lhs: PlaceKey, rhs: PlaceKey) -> Bool {
        (lhs.level, lhs.path) < (rhs.level, rhs.path)
    }

    /// Case- and diacritic-insensitive normalization.
    public static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ß", with: "ss")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

/// A geocoded place attached to an asset.
public struct ResolvedPlace: Hashable, Sendable, Codable {
    public var components: PlaceComponents
    public var source: PlaceSource
    public var resolvedAt: Date
    /// Raster (metres) the town-level name was resolved with. `nil` = only country and
    /// region are known (offline map), so the overnight refinement pass revisits it.
    public var precisionMeters: Double?

    public init(components: PlaceComponents, source: PlaceSource, resolvedAt: Date = Date(), precisionMeters: Double? = nil) {
        self.components = components
        self.source = source
        self.resolvedAt = resolvedAt
        self.precisionMeters = precisionMeters
    }

    /// Needs another lookup to reach `cellMeters` precision.
    public func needsRefinement(to cellMeters: Double) -> Bool {
        guard source == .gpsReverseGeocoded else { return false }
        guard let precisionMeters else { return true }
        return precisionMeters > cellMeters
    }
}
