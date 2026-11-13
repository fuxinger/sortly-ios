import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Naming and dates")
struct NamingTests {
    let de = DateRangeFormatter(language: .german, timeZone: Fixture.utc)

    @Test func rangeFormatsMatchProductSpec() {
        #expect(de.format(start: Fixture.date("2026-08-03"), end: Fixture.date("2026-08-14")) == "03.08.–14.08.2026")
        #expect(de.format(start: Fixture.date("2026-07-12 09:00"), end: Fixture.date("2026-07-12 18:00")) == "12.07.2026")
        #expect(de.format(start: Fixture.date("2025-12-28"), end: Fixture.date("2026-01-04")) == "28.12.2025–04.01.2026")
    }

    @Test func defaultTripTemplate() {
        let title = NamingTemplate.tripDefault.render(
            .init(place: "Gardasee", start: Fixture.date("2026-08-03"), end: Fixture.date("2026-08-14")), formatter: de)
        #expect(title == "Gardasee · 03.08.–14.08.2026")
    }

    @Test func alternativeTemplates() {
        let values = NamingTemplate.Values(place: "Rom", country: "Italien", start: Fixture.date("2026-05-12"), end: Fixture.date("2026-05-19"))
        #expect(NamingTemplate.tripWithCountry.render(values, formatter: de) == "Italien – Rom · 12.05.–19.05.2026")
        #expect(NamingTemplate.tripMonth.render(values, formatter: de) == "Rom – Mai 2026")
        #expect(NamingTemplate.tripYearFirst.render(values, formatter: de) == "2026 – Rom")
        #expect(NamingTemplate.placeOnly.render(values, formatter: de) == "Rom")
        #expect(NamingTemplate("{place}-Roadtrip · {range}").render(.init(place: "Italien", start: Fixture.date("2026-08-03"), end: Fixture.date("2026-08-18")), formatter: de) == "Italien-Roadtrip · 03.08.–18.08.2026")
    }

    @Test func missingVariablesDropSeparators() {
        let title = NamingTemplate.tripWithCountry.render(.init(place: "Rom", start: Fixture.date("2026-05-12"), end: Fixture.date("2026-05-12")), formatter: de)
        #expect(title == "Rom · 12.05.2026")
        let noDate = NamingTemplate.tripDefault.render(.init(place: "Rom"), formatter: de)
        #expect(noDate == "Rom")
    }

    @Test func titleSanitizing() {
        #expect(AlbumTitle.sanitize("  Rom  ·  ") == "Rom")
        #expect(AlbumTitle.sanitize(String(repeating: "x", count: 300)).count == AlbumTitle.maxLength)
        #expect(AlbumTitle.tokens("Sommer-Urlaub 2026 Gardasee") == ["sommer", "urlaub", "2026", "gardasee"])
    }

    @Test func englishRange() {
        let en = DateRangeFormatter(language: .english, timeZone: Fixture.utc)
        #expect(en.format(start: Fixture.date("2026-05-12"), end: Fixture.date("2026-05-19")) == "2026-05-12–19")
    }
}

@Suite("Chronology")
struct ChronologyTests {
    let grouper = ChronologyGrouper(calendar: Fixture.calendar)
    let de = DateRangeFormatter(language: .german, timeZone: Fixture.utc)

    @Test func keysForAllGranularities() throws {
        let d = Fixture.date("2026-03-15 10:00")
        #expect(grouper.key(for: d, granularity: .decade)?.components == [2020])
        #expect(grouper.key(for: d, granularity: .year)?.components == [2026])
        #expect(grouper.key(for: d, granularity: .halfYear)?.components == [2026, 1])
        #expect(grouper.key(for: d, granularity: .quarter)?.components == [2026, 1])
        #expect(grouper.key(for: d, granularity: .month)?.components == [2026, 3])
        #expect(grouper.key(for: d, granularity: .isoWeek)?.components == [2026, 11])
        #expect(grouper.key(for: d, granularity: .day)?.components == [2026, 3, 15])
        #expect(grouper.key(for: nil, granularity: .year) == nil)
    }

    @Test func isoWeekAtYearBoundary() {
        // 2027-01-01 is a Friday → ISO week 53 of 2026.
        #expect(grouper.key(for: Fixture.date("2027-01-01"), granularity: .isoWeek)?.components == [2026, 53])
    }

    @Test func seasonsAreHemisphereAware() throws {
        let jan = Fixture.date("2026-01-10")
        let north = try #require(grouper.key(for: jan, granularity: .season, latitude: 48))
        let south = try #require(grouper.key(for: jan, granularity: .season, latitude: -33))
        #expect(de.label(for: north) == "Winter 2025/26")
        #expect(de.label(for: south) == "Sommer 2026")
        let december = try #require(grouper.key(for: Fixture.date("2025-12-20"), granularity: .season, latitude: 48))
        #expect(december == north) // December belongs to the same winter
    }

    @Test func nestedGroupingKeepsUndatedSeparate() {
        let assets = [
            AssetSnapshot(id: "a", creationDate: Fixture.date("2026-01-05")),
            AssetSnapshot(id: "b", creationDate: Fixture.date("2026-02-05")),
            AssetSnapshot(id: "c", creationDate: nil),
        ]
        let result = grouper.group(assets, levels: [.year, .month])
        #expect(result.buckets.count == 2)
        #expect(result.undated == ["c"])
        #expect(de.label(for: ChronologyKey(.month, [2026, 2])) == "Februar 2026")
    }
}
