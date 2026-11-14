import Foundation

/// What the travel atlas shows when a country is tapped: its photos grouped by year
/// (newest first), the places photographed most and how many trips led there.
public struct CountryPhotos: Hashable, Sendable {
    public struct YearGroup: Hashable, Sendable, Identifiable {
        /// Calendar year, `nil` for photos without a capture date.
        public var year: Int?
        /// Newest first.
        public var photos: [AssetFacts]
        public var id: Int { year ?? 0 }
    }

    public var countryCode: String
    public var years: [YearGroup] = []
    public var photoCount = 0
    public var firstVisit: Date?
    public var lastVisit: Date?
    /// Cities and towns by number of photos, most photographed first (at most five).
    public var topPlaces: [String] = []
    public var tripCount = 0

    public var assetIDs: Set<AssetID> { Set(years.flatMap { $0.photos.map(\.id) }) }

    /// Collects the photos taken in `countryCode`, optionally only those of one calendar year
    /// (same filter as `TravelAtlas.compute(facts:year:)`, so the numbers match the atlas).
    public static func collect(countryCode: String, facts: [AssetFacts], year: Int? = nil,
                               calendar: Calendar = .current) -> CountryPhotos {
        var result = CountryPhotos(countryCode: countryCode)
        var byYear: [Int?: [AssetFacts]] = [:]
        var places: [String: Int] = [:]
        var trips = Set<SortlyID>()
        let code = countryCode.uppercased()
        for f in facts {
            guard let place = f.place, place.isoCountryCode?.uppercased() == code else { continue }
            let photoYear = f.asset.creationDate.map { calendar.component(.year, from: $0) }
            if let year, photoYear != year { continue }
            byYear[photoYear, default: []].append(f)
            if let date = f.asset.creationDate {
                result.firstVisit = min(result.firstVisit ?? date, date)
                result.lastVisit = max(result.lastVisit ?? date, date)
            }
            if let city = place.locality { places[city, default: 0] += 1 }
            if let trip = f.tripID { trips.insert(trip) }
        }
        result.years = byYear.map { year, photos in
            YearGroup(year: year, photos: photos.sorted(by: newestFirst))
        }
        .sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
        result.photoCount = byYear.values.reduce(0) { $0 + $1.count }
        result.topPlaces = places.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)
        result.tripCount = trips.count
        return result
    }

    private static func newestFirst(_ a: AssetFacts, _ b: AssetFacts) -> Bool {
        switch (a.asset.creationDate, b.asset.creationDate) {
        case let (x?, y?): x != y ? x > y : a.id.rawValue < b.id.rawValue
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): a.id.rawValue < b.id.rawValue
        }
    }
}
