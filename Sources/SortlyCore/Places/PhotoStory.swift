import Foundation

/// Plain German facts for the on-device language model that writes "Deine Foto-Geschichte".
/// Only counts, place names, topic names and months are passed on; never images or text
/// recognized in photos.
public enum PhotoStory {
    public enum Scope: Hashable, Sendable {
        case trips
        case year(Int)
        case all
    }

    public static func availableYears(_ facts: [AssetFacts], calendar: Calendar = .current) -> [Int] {
        Set(facts.compactMap { $0.asset.creationDate.map { calendar.component(.year, from: $0) } }).sorted(by: >)
    }

    public static func facts(_ scope: Scope, facts all: [AssetFacts], calendar: Calendar = .current) -> [String] {
        let german = Locale(identifier: "de_DE")
        func country(_ code: String) -> String { german.localizedString(forRegionCode: code) ?? code }
        func year(_ date: Date) -> String { String(calendar.component(.year, from: date)) }
        let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
        let weekdays = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]

        let facts: [AssetFacts]
        switch scope {
        case .year(let y): facts = all.filter { $0.asset.creationDate.map { calendar.component(.year, from: $0) == y } ?? false }
        default: facts = all
        }
        guard !facts.isEmpty else { return [] }
        let atlas = TravelAtlas.compute(facts: facts, calendar: calendar)
        var lines: [String] = []

        func topics(limit: Int) -> [String] {
            var counts: [String: Int] = [:]
            for f in facts {
                for (id, reliability) in f.categories where reliability >= .likely && id.contains(".") {
                    counts[id, default: 0] += 1
                }
            }
            return counts.filter { $0.value >= 5 }
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(limit)
                .compactMap { id, n in ImageTaxonomy.byID[id].map { "\($0.german) (\(n) Fotos)" } }
        }

        switch scope {
        case .trips:
            lines.append("Länder insgesamt: \(atlas.countryCodes.count), Kontinente: \(atlas.continents.count), Städte: \(atlas.cityCount), Reisen: \(atlas.tripCount)")
            if let since = atlas.sinceYear { lines.append("Fotos mit Ort seit: \(since)") }
            let firsts = atlas.countriesByFirstVisit.prefix(12).compactMap { code in atlas.firstVisits[code].map { "\(country(code)) (\(year($0)))" } }
            if !firsts.isEmpty { lines.append("Länder in der Reihenfolge des ersten Besuchs: " + firsts.joined(separator: ", ")) }
            if let first = atlas.trips.first { lines.append("Erste Reise: \(first.place), \(country(first.countryCode)), \(year(first.start)), \(first.days) Tage") }
            if let longest = atlas.trips.max(by: { $0.days < $1.days }) {
                lines.append("Längste Reise: \(longest.place), \(country(longest.countryCode)), \(year(longest.start)), \(longest.days) Tage")
            }
            if let latest = atlas.trips.last { lines.append("Letzte Reise: \(latest.place), \(country(latest.countryCode)), \(year(latest.start))") }
            if let city = atlas.favoriteTripCity { lines.append("Meistfotografierter Reiseort: \(city)") }

        case .year(let y):
            let videos = facts.filter { $0.asset.kind == .video }.count
            lines.append("Jahr: \(y). Fotos: \(facts.count - videos), Videos: \(videos)")
            var perMonth = [Int](repeating: 0, count: 12), perWeekday = [Int](repeating: 0, count: 7)
            for f in facts { if let d = f.asset.creationDate {
                perMonth[calendar.component(.month, from: d) - 1] += 1
                perWeekday[calendar.component(.weekday, from: d) - 1] += 1
            } }
            if let m = perMonth.indices.max(by: { perMonth[$0] < perMonth[$1] }) { lines.append("Monat mit den meisten Aufnahmen: \(months[m]) (\(perMonth[m]))") }
            if let w = perWeekday.indices.max(by: { perWeekday[$0] < perWeekday[$1] }) { lines.append("Häufigster Wochentag: \(weekdays[w])") }
            let t = topics(limit: 4)
            if !t.isEmpty { lines.append("Häufigste Motive: " + t.joined(separator: ", ")) }
            if !atlas.trips.isEmpty {
                lines.append("Reisen in diesem Jahr: " + atlas.trips.prefix(8).map { "\($0.place) (\(country($0.countryCode)), \($0.days) Tage)" }.joined(separator: ", "))
            }
            if !atlas.countryCodes.isEmpty { lines.append("Länder in diesem Jahr: " + atlas.countryCodes.sorted().map(country).joined(separator: ", ")) }

        case .all:
            let years = availableYears(facts, calendar: calendar)
            var perYear: [Int: Int] = [:]
            for f in facts { if let d = f.asset.creationDate { perYear[calendar.component(.year, from: d), default: 0] += 1 } }
            lines.append("Aufnahmen insgesamt: \(facts.count), von \(years.last.map(String.init) ?? "?") bis \(years.first.map(String.init) ?? "?")")
            if let peak = perYear.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { lines.append("Jahr mit den meisten Aufnahmen: \(peak.key) (\(peak.value))") }
            let t = topics(limit: 5)
            if !t.isEmpty { lines.append("Lieblingsmotive: " + t.joined(separator: ", ")) }
            lines.append("Länder: \(atlas.countryCodes.count), Reisen: \(atlas.tripCount), Städte: \(atlas.cityCount)")
            var tripsPerCountry: [String: Int] = [:]
            for trip in atlas.trips { tripsPerCountry[trip.countryCode, default: 0] += 1 }
            if let fav = tripsPerCountry.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), fav.value > 1 {
                lines.append("Am häufigsten bereistes Land: \(country(fav.key)) (\(fav.value) Reisen)")
            }
            let screenshots = facts.filter { $0.asset.subtypes.contains(.screenshot) }.count
            if screenshots > 0 { lines.append("Screenshots: \(screenshots)") }
        }
        return lines
    }
}
