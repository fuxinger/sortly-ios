import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Organization status")
struct StatusTests {
    @Test("Scenario M: in a year album but missing the wanted trip assignment = partially organized")
    func scenarioM() {
        let resolver = OrganizationStatusResolver(primaryAreas: [.trips, .chronology])
        let state = resolver.state(for: "a", facts: [
            .chronology: AreaFacts(inMatchingExistingAlbum: true),
            .trips: AreaFacts(proposed: true),
        ])
        #expect(resolver.overall(state) == .partiallyOrganized)
        #expect(resolver.buckets(state) == [.all, .unorganized, .suggestions])
    }

    @Test func onlyPrimaryAreasCount() {
        let resolver = OrganizationStatusResolver(primaryAreas: [.chronology])
        let state = resolver.state(for: "a", facts: [
            .chronology: AreaFacts(organizedBySortly: true),
            .trips: AreaFacts(),
        ])
        #expect(resolver.overall(state) == .fullyOrganized)
    }

    @Test func notApplicableAreasDoNotBlockAndInboxIsNotEmptiedArtificially() {
        let resolver = OrganizationStatusResolver(primaryAreas: [.trips, .screenshots])
        let screenshot = resolver.state(for: "s", facts: [
            .trips: AreaFacts(applicable: false),
            .screenshots: AreaFacts(organizedBySortly: true),
        ])
        #expect(resolver.overall(screenshot) == .fullyOrganized)
        let open = resolver.state(for: "o", facts: [.trips: AreaFacts(), .screenshots: AreaFacts(applicable: false)])
        #expect(resolver.overall(open) == .unorganized)
    }

    @Test func ignoredAndExcludedWin() {
        let resolver = OrganizationStatusResolver(primaryAreas: [.trips])
        #expect(resolver.overall(resolver.state(for: "a", facts: [.trips: AreaFacts()], ignored: true)) == .ignored)
        #expect(resolver.overall(resolver.state(for: "a", facts: [.trips: AreaFacts()], excluded: true)) == .excluded)
    }

    @Test func progressCounts() {
        let resolver = OrganizationStatusResolver(primaryAreas: [.trips])
        let states = [
            resolver.state(for: "1", facts: [.trips: AreaFacts(organizedBySortly: true)]),
            resolver.state(for: "2", facts: [.trips: AreaFacts()]),
            resolver.state(for: "3", facts: [.trips: AreaFacts(analyzed: false)]),
        ]
        let p = resolver.progress(states)
        #expect(p.total == 3 && p.fully == 1 && p.unorganized == 1 && p.pending == 1)
    }

    @Test func photosOutsideTheMainAreasDoNotCountAsSorted() {
        let resolver = OrganizationStatusResolver(primaryAreas: [.trips, .places])
        let screenshot = resolver.state(for: "s", facts: [.trips: AreaFacts(applicable: false), .places: AreaFacts(applicable: false)])
        let open = resolver.state(for: "o", facts: [.trips: AreaFacts(), .places: AreaFacts()])
        let p = resolver.progress([screenshot, open])
        #expect(p.total == 1 && p.fully == 0 && p.outsideMainAreas == 1 && p.allPhotos == 2)
    }
}

@Suite("Rules and automation")
struct RuleTests {
    let evaluator = RuleEvaluator(calendar: Fixture.calendar)

    func facts(_ id: AssetID, country: String?, car: Bool, year: Int, screenshot: Bool = false) -> AssetFacts {
        AssetFacts(
            asset: AssetSnapshot(id: id, subtypes: screenshot ? .screenshot : [], creationDate: Fixture.date("\(year)-06-01"),
                                 location: GeoCoordinate(latitude: 41.9, longitude: 12.5)),
            place: country.map { PlaceComponents(isoCountryCode: $0, country: $0) },
            placeSource: country == nil ? nil : .gpsReverseGeocoded,
            categories: car ? ["vehicle.car": .likely] : [:]
        )
    }

    var italyCars2026: OrganizationRule {
        OrganizationRule(
            name: "Italien – Autos · 2026",
            area: .imageCategories,
            condition: .all([
                .predicate(.country(isoCode: "IT")),
                .predicate(.imageCategory("vehicle.car", minimum: .likely)),
                .predicate(.year(2026)),
                .not(.predicate(.subtype(MediaSubtypes.screenshot.rawValue))),
            ]),
            target: .newAlbum(titleTemplate: "Italien – Autos · 2026", folderPath: ["Themen"])
        )
    }

    @Test("Prompt example: Land = Italien UND Auto UND 2026 NICHT Screenshot")
    func combinedRule() {
        let all = [
            facts("match", country: "IT", car: true, year: 2026),
            facts("wrongYear", country: "IT", car: true, year: 2025),
            facts("noCar", country: "IT", car: false, year: 2026),
            facts("germany", country: "DE", car: true, year: 2026),
            facts("screenshot", country: "IT", car: true, year: 2026, screenshot: true),
        ]
        #expect(evaluator.matches(italyCars2026, in: all, overrides: OverrideSet()) == ["match"])
    }

    @Test func parentCategoryMatchesChildren() {
        #expect(evaluator.evaluate(.imageCategory("vehicle", minimum: .likely), facts("a", country: nil, car: true, year: 2026)))
    }

    @Test func manualExceptionBeatsRule() {
        let rule = italyCars2026
        let overrides = OverrideSet([UserOverride(scope: .assetInSource("match", rule.id), decision: .neverAdd)])
        #expect(evaluator.matches(rule, in: [facts("match", country: "IT", car: true, year: 2026)], overrides: overrides).isEmpty)
    }

    @Test func contentGuessedPlacesAreNotUsedForGeoRules() {
        var f = facts("a", country: "IT", car: false, year: 2026)
        f.placeSource = .contentInferred
        #expect(!evaluator.evaluate(.predicate(.country(isoCode: "IT")), f))
    }

    @Test func rulesAreVersioned() {
        let v1 = italyCars2026
        let v2 = v1.revised { $0.name = "Autos in Italien" }
        #expect(v2.version == 2 && v2.id == v1.id && v2.name == "Autos in Italien")
    }

    @Test func detectsContradictionsAndConflictingModes() {
        let contradiction = OrganizationRule(name: "x", area: .places, condition: .all([.predicate(.hasLocation), .not(.predicate(.hasLocation))]), target: .existingAlbum("a"))
        let r1 = OrganizationRule(name: "a", area: .places, condition: .always, target: .existingAlbum("b"), automationMode: .automatic)
        let r2 = OrganizationRule(name: "b", area: .places, condition: .always, target: .existingAlbum("b"), automationMode: .suggestOnly)
        let conflicts = evaluator.conflicts([contradiction, r1, r2])
        #expect(conflicts.contains(.unsatisfiable(contradiction.id)))
        #expect(conflicts.contains { if case .sameTargetDifferentAutomation = $0 { true } else { false } })
    }

    @Test func automationModes() {
        let a = AutomationPolicy(globalMode: .suggestOnly)
        let b = AutomationPolicy(globalMode: .semiAutomatic)
        let c = AutomationPolicy(globalMode: .automatic)
        let extend = AutomationPolicy.ChangeKind.extendConfirmedAlbum("x")
        #expect(a.verdict(for: extend, area: .trips, reliability: .certain, isSensitive: false, hasConflict: false) == .needsConfirmation)
        #expect(b.verdict(for: extend, area: .trips, reliability: .certain, isSensitive: false, hasConflict: false) == .automatic)
        #expect(b.verdict(for: .createAlbumFromApprovedRule, area: .trips, reliability: .certain, isSensitive: false, hasConflict: false, rule: italyCars2026) == .needsConfirmation)
        #expect(c.verdict(for: .createAlbumFromApprovedRule, area: .trips, reliability: .certain, isSensitive: false, hasConflict: false, rule: italyCars2026) == .automatic)
        // Never automatic: uncertain, sensitive, conflicts, restructuring.
        #expect(c.verdict(for: extend, area: .trips, reliability: .plausible, isSensitive: false, hasConflict: false) == .needsConfirmation)
        #expect(c.verdict(for: extend, area: .peopleAndPets, reliability: .certain, isSensitive: false, hasConflict: false) == .needsConfirmation)
        #expect(c.verdict(for: extend, area: .trips, reliability: .certain, isSensitive: false, hasConflict: true) == .needsConfirmation)
        #expect(c.verdict(for: .restructure, area: .trips, reliability: .certain, isSensitive: false, hasConflict: false) == .needsConfirmation)
        // Per-album override is most specific.
        let perAlbum = AutomationPolicy(globalMode: .automatic, albumModes: ["x": .suggestOnly])
        #expect(perAlbum.verdict(for: extend, area: .trips, reliability: .certain, isSensitive: false, hasConflict: false) == .needsConfirmation)
    }
}
