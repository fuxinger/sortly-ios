import Foundation

/// Input to proposal generation: everything the analysis produced.
public struct AnalysisSnapshot: Sendable {
    public var facts: [AssetFacts]
    public var trips: [Trip]
    public var frequentPlaces: [FrequentPlace]
    /// Person/pet groups (confirmed and unconfirmed).
    public var groups: [ObservationGroup]

    public init(facts: [AssetFacts], trips: [Trip] = [], frequentPlaces: [FrequentPlace] = [], groups: [ObservationGroup] = []) {
        self.facts = facts
        self.trips = trips
        self.frequentPlaces = frequentPlaces
        self.groups = groups
    }
}

/// Generates album proposals for all enabled areas (prompt §4, §7 Schritt 4–6).
/// Pure and deterministic: the same analysis produces the same proposal ids, so user
/// decisions stay attached across re-analysis.
public struct ProposalEngine: Sendable {
    public var settings: OrganizationSettings
    public var calendar: Calendar

    public init(settings: OrganizationSettings, calendar: Calendar = .sortlyDefault) {
        self.settings = settings
        self.calendar = calendar
    }

    private var labels: Labels { Labels(settings.titleLanguage) }

    public func proposals(for analysis: AnalysisSnapshot, overrides: OverrideSet = OverrideSet()) -> [AlbumProposal] {
        let usable = analysis.facts.filter { !overrides.isExcluded($0.id) && !overrides.isIgnored($0.id) }
        var result: [AlbumProposal] = []
        let areas = settings.enabledAreas
        if areas.contains(.places) { result += placeProposals(usable) }
        if areas.contains(.trips) { result += tripProposals(analysis.trips, facts: usable) }
        if areas.contains(.frequentPlaces) { result += frequentPlaceProposals(analysis.frequentPlaces) }
        if areas.contains(.chronology) { result += chronologyProposals(usable) }
        if areas.contains(.mediaTypes) { result += mediaTypeProposals(usable) }
        if areas.contains(.screenshots) { result += screenshotProposals(usable) }
        if areas.contains(.imageCategories) { result += imageCategoryProposals(usable) }
        if areas.contains(.documents) { result += documentProposals(usable) }
        if areas.contains(.messenger) { result += messengerProposals(usable) }
        if areas.contains(.peopleAndPets) { result += groupProposals(analysis.groups) }
        return result.filter { !overrides.isRejected($0.id) && !overrides.mustNotRecreate($0.id) }
    }

    // MARK: Places (4.1)

    func placeProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        let levels = settings.places.levels.sorted()
        guard !levels.isEmpty else { return [] }
        var groups: [PlaceKey: (components: PlaceComponents, assets: Set<AssetID>)] = [:]
        for f in facts {
            guard let place = f.gpsPlace else { continue }
            var deepest: PlaceKey?
            for level in levels {
                guard let key = place.key(at: level) else { continue }
                deepest = key
                if settings.allowMultipleAssignments {
                    groups[key, default: (place, [])].assets.insert(f.id)
                }
            }
            if !settings.allowMultipleAssignments, let deepest {
                groups[deepest, default: (place, [])].assets.insert(f.id)
            }
        }
        let base = labels.folder(for: .places)
        return groups.compactMap { key, value -> AlbumProposal? in
            guard value.assets.count >= settings.places.minPhotos, let name = displayName(value.components, level: key.level) else { return nil }
            var path = [base]
            if settings.places.hierarchical {
                for parent in levels where parent < key.level {
                    if let n = displayName(value.components, level: parent) { path.append(n) }
                }
            }
            return AlbumProposal(
                id: .stable("place", key.description),
                kind: .placeCollection(key.level),
                title: name,
                folderPath: path,
                assetIDs: value.assets,
                reliability: .certain,
                reasons: [.photosInPlace(count: value.assets.count, place: name)],
                placeKeys: [key]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func displayName(_ c: PlaceComponents, level: PlaceLevel) -> String? {
        if level == .continent, let continent = c.continent {
            return DateRangeFormatter(language: settings.titleLanguage).continentName(continent)
        }
        return c.name(at: level)
    }

    // MARK: Trips (4.2)

    func tripProposals(_ trips: [Trip], facts: [AssetFacts]) -> [AlbumProposal] {
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        var result: [AlbumProposal] = []
        var tripsPerPlace: [PlaceKey: [Trip]] = [:]

        for trip in trips where trip.geotaggedAssetIDs.count >= settings.trips.minPhotos {
            if trip.kind == .dayTrip && !settings.trips.includeDayTrips { continue }
            let places = trip.geotaggedAssetIDs.compactMap { byID[$0]?.gpsPlace }
            let (name, key, country) = Self.primaryPlaceName(places, kind: trip.kind, labels: labels)
            let timeZone = places.compactMap(\.timeZoneIdentifier).first.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
            let formatter = DateRangeFormatter(language: settings.titleLanguage, timeZone: timeZone)
            let placeLabel = name ?? labels.unknownPlace
            let title = settings.trips.template.render(
                .init(place: placeLabel, country: country, region: places.first?.administrativeArea, city: places.first?.locality, start: trip.start, end: trip.end),
                formatter: formatter
            )
            var path = [labels.folder(for: .trips)]
            if settings.trips.folderPerYear {
                var cal = calendar
                cal.timeZone = timeZone
                path.append(String(cal.component(.year, from: trip.start)))
            }
            result.append(AlbumProposal(
                id: trip.id,
                kind: .trip,
                title: title,
                folderPath: path,
                assetIDs: Set(trip.geotaggedAssetIDs),
                optionalAssetIDs: Set(trip.inferredAssetIDs),
                reliability: name == nil ? .plausible : .likely,
                reasons: [.photosInPlaceDuringPeriod(count: trip.geotaggedAssetIDs.count, place: placeLabel, start: trip.start, end: trip.end)]
                    + (trip.inferredAssetIDs.isEmpty ? [] : [.inferredWithoutLocation(count: trip.inferredAssetIDs.count)]),
                dateRange: DateInterval(start: trip.start, end: trip.end),
                placeKeys: key.map { [$0] } ?? []
            ))
            if let key { tripsPerPlace[key, default: []].append(trip) }
        }

        // Scenario B: one permanent place album next to repeated visits.
        if settings.trips.placeCollectionForRepeatedTrips {
            for (key, repeated) in tripsPerPlace where repeated.count >= 2 {
                let assets = Set(repeated.flatMap(\.geotaggedAssetIDs))
                let name = repeated.lazy.flatMap(\.geotaggedAssetIDs).compactMap { byID[$0]?.gpsPlace?.name(at: key.level) }.first ?? labels.unknownPlace
                result.append(AlbumProposal(
                    id: .stable("trip-place", key.description),
                    kind: .placeCollection(key.level),
                    title: name,
                    folderPath: [labels.folder(for: .trips)],
                    assetIDs: assets,
                    reliability: .likely,
                    reasons: [.photosInPlace(count: assets.count, place: name)],
                    placeKeys: [key]
                ))
            }
        }
        return result.sorted { ($0.dateRange?.start ?? .distantPast, $0.id.rawValue) < ($1.dateRange?.start ?? .distantPast, $1.id.rawValue) }
    }

    /// Most fitting name for a set of places: city if ≥ 60 % share one, else region, else
    /// country, else "Country-Roadtrip" / several countries joined.
    static func primaryPlaceName(_ places: [PlaceComponents], kind: TripKind, labels: Labels) -> (String?, PlaceKey?, String?) {
        guard !places.isEmpty else { return (nil, nil, nil) }
        func dominant(_ level: PlaceLevel) -> (String, PlaceKey)? {
            var counts: [PlaceKey: (String, Int)] = [:]
            for p in places {
                guard let key = p.key(at: level), let name = p.name(at: level) else { continue }
                counts[key, default: (name, 0)].1 += 1
            }
            guard let best = counts.max(by: { ($0.value.1, $1.key) < ($1.value.1, $0.key) }) else { return nil }
            return Double(best.value.1) / Double(places.count) >= 0.6 ? (best.value.0, best.key) : nil
        }
        let country = dominant(.country)
        if kind != .roadTrip, let city = dominant(.locality) { return (city.0, city.1, country?.0) }
        if let area = places.compactMap(\.inlandWater).first, kind != .roadTrip,
           Double(places.filter { $0.inlandWater == area }.count) / Double(places.count) >= 0.6 {
            return (area, places.first { $0.inlandWater == area }?.key(at: .pointOfInterest), country?.0) // e.g. "Gardasee"
        }
        if kind != .roadTrip, let region = dominant(.administrativeArea) { return (region.0, region.1, country?.0) }
        if let country {
            return (kind == .roadTrip ? "\(country.0)-\(labels.roadTripSuffix)" : country.0, country.1, country.0)
        }
        let names = Array(Set(places.compactMap(\.country))).sorted().prefix(3)
        return (names.isEmpty ? nil : names.joined(separator: " & "), nil, nil)
    }

    // MARK: Frequent places (4.3)

    func frequentPlaceProposals(_ places: [FrequentPlace]) -> [AlbumProposal] {
        places.enumerated().map { index, place in
            let name = settings.frequentPlaces.names[place.id] ?? place.userName
            return AlbumProposal(
                id: place.id,
                kind: .frequentPlace,
                title: name ?? labels.frequentPlacePlaceholder(number: index + 1),
                folderPath: [labels.folder(for: .frequentPlaces)],
                assetIDs: Set(place.assetIDs),
                reliability: .likely,
                reasons: [.recurringPlace(count: place.photoCount, days: place.distinctDays)],
                dateRange: DateInterval(start: place.firstDate, end: place.lastDate),
                isSensitive: true,
                requiresUserName: name == nil
            )
        }
    }

    // MARK: Chronology (4.9)

    func chronologyProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        let levels = settings.chronology.levels.sorted()
        guard let leaf = levels.last else { return [] }
        let grouper = ChronologyGrouper(calendar: calendar)
        let formatter = DateRangeFormatter(language: settings.titleLanguage, timeZone: calendar.timeZone)
        let (buckets, _) = grouper.group(facts.map(\.asset), levels: levels)
        var result: [AlbumProposal] = buckets.compactMap { path, assets in
            guard assets.count >= settings.chronology.minPhotos, let key = path.last else { return nil }
            let folders = [labels.folder(for: .chronology)] + path.dropLast().map(formatter.label(for:))
            return AlbumProposal(
                id: .stable("chrono", path.map(\.description).joined(separator: "/")),
                kind: .chronology(leaf),
                title: formatter.label(for: key),
                folderPath: folders,
                assetIDs: Set(assets),
                reliability: .certain,
                reasons: [.mediaType(count: assets.count, label: formatter.label(for: key))]
            )
        }
        for period in settings.chronology.customPeriods {
            let assets = Set(facts.filter { period.contains($0.asset.creationDate) }.map(\.id))
            guard !assets.isEmpty else { continue }
            result.append(AlbumProposal(
                id: period.id, kind: .customPeriod, title: period.title, folderPath: [labels.folder(for: .chronology)],
                assetIDs: assets, reliability: .certain,
                reasons: [.photosInPeriod(count: assets.count, start: period.start, end: period.end)],
                dateRange: DateInterval(start: period.start, end: period.end)
            ))
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Media types (4.10)

    func mediaTypeProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        let classifier = MediaTypeClassifier()
        var groups: [MediaTypeCategory: Set<AssetID>] = [:]
        for f in facts {
            for c in classifier.categories(for: f.asset) where settings.mediaTypes.categories.contains(c) {
                groups[c, default: []].insert(f.id)
            }
        }
        return groups.compactMap { category, assets in
            guard assets.count >= settings.mediaTypes.minItems else { return nil }
            return AlbumProposal(
                id: .stable("mediatype", category.rawValue), kind: .mediaType(category.rawValue), title: labels.name(category),
                folderPath: [labels.folder(for: .mediaTypes)], assetIDs: assets, reliability: .certain,
                reasons: [.mediaType(count: assets.count, label: labels.name(category))]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Screenshots (4.6)

    func screenshotProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        var groups: [ScreenshotCategory: Set<AssetID>] = [:]
        for f in facts where f.asset.subtypes.contains(.screenshot) {
            for raw in f.textCategories {
                if let c = ScreenshotCategory(rawValue: raw) { groups[c, default: []].insert(f.id) }
            }
        }
        return groups.compactMap { category, assets in
            guard assets.count >= settings.screenshots.minItems else { return nil }
            return AlbumProposal(
                id: .stable("screenshot", category.rawValue), kind: .screenshotCategory(category.rawValue), title: labels.name(category),
                folderPath: [labels.folder(for: .screenshots)], assetIDs: assets, reliability: .likely,
                reasons: [.recognizedText(count: assets.count, label: labels.name(category))]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Image categories (4.7)

    func imageCategoryProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        var groups: [String: Set<AssetID>] = [:]
        for f in facts where !f.asset.isScreenshotLike {
            for (id, reliability) in f.categories where reliability >= settings.imageCategories.minimumReliability {
                groups[id, default: []].insert(f.id)
            }
        }
        return groups.compactMap { id, assets -> AlbumProposal? in
            guard let category = ImageTaxonomy.byID[id], !settings.imageCategories.disabledCategories.contains(id),
                  assets.count >= settings.imageCategories.minPhotos else { return nil }
            if settings.imageCategories.leafCategoriesOnly && category.parentID == nil { return nil }
            let parentName = category.parentID.flatMap { ImageTaxonomy.byID[$0] }.map(labels.name)
            return AlbumProposal(
                id: .stable("category", id), kind: .imageCategory(id), title: labels.name(category),
                folderPath: [labels.folder(for: .imageCategories)] + (parentName.map { [$0] } ?? []),
                assetIDs: assets, reliability: settings.imageCategories.minimumReliability,
                reasons: [.recognizedContent(count: assets.count, label: labels.name(category))]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Documents (4.8)

    func documentProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        var groups: [DocumentType: (assets: Set<AssetID>, sensitive: Bool)] = [:]
        for f in facts {
            guard let doc = f.document, doc.typeReliability >= .plausible else { continue }
            let sensitive = doc.sensitivity != .normal
            if sensitive && !settings.documents.includeSensitive { continue }
            groups[doc.type, default: ([], false)].assets.insert(f.id)
            if sensitive { groups[doc.type]?.sensitive = true }
        }
        return groups.compactMap { type, value in
            guard value.assets.count >= settings.documents.minItems else { return nil }
            return AlbumProposal(
                id: .stable("document", type.rawValue), kind: .documentCategory(type.rawValue), title: labels.name(type),
                folderPath: [labels.folder(for: .documents)], assetIDs: value.assets, reliability: .plausible,
                reasons: [.recognizedText(count: value.assets.count, label: labels.name(type))],
                isSensitive: true
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Messenger (4.5)

    func messengerProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        var groups: [String: (app: MessengerApp, evidence: MessengerEvidence, assets: Set<AssetID>)] = [:]
        for f in facts {
            guard let m = f.messenger, m.evidence > .unknownOrigin else { continue }
            if m.evidence == .plausibleHint && !settings.messenger.includeHints { continue }
            let key = "\(m.app.rawValue).\(m.evidence.rawValue)"
            groups[key, default: (m.app, m.evidence, [])].assets.insert(f.id)
        }
        return groups.compactMap { key, value in
            guard value.assets.count >= settings.messenger.minItems else { return nil }
            let title = labels.name(value.app, evidence: value.evidence)
            return AlbumProposal(
                id: .stable("messenger", key), kind: .messenger(key), title: title,
                folderPath: [labels.folder(for: .messenger)], assetIDs: value.assets,
                reliability: value.evidence >= .existingAlbum ? .likely : .uncertain,
                reasons: [.recognizedContent(count: value.assets.count, label: title)],
                isSensitive: value.evidence < .existingAlbum
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: People and pets (4.4)

    func groupProposals(_ groups: [ObservationGroup]) -> [AlbumProposal] {
        var counters: [GroupKind: Int] = [:]
        return groups.compactMap { group in
            if group.kind == .person && !settings.people.faceGroupingEnabled { return nil }
            if group.kind != .person && !settings.people.petGroupingEnabled { return nil }
            counters[group.kind, default: 0] += 1
            let name = group.confirmedName ?? labels.groupPlaceholder(group.kind, number: counters[group.kind]!)
            return AlbumProposal(
                id: group.id, kind: .personOrPet, title: name, folderPath: [labels.folder(for: .peopleAndPets)],
                assetIDs: group.assetIDs, reliability: group.isConfirmed ? .certain : .uncertain,
                reasons: [.confirmedGroup(count: group.assetIDs.count, name: name)],
                isSensitive: true,
                requiresUserName: group.confirmedName == nil
            )
        }
    }
}

/// Figures for the result overview (prompt §7, Schritt 4).
public struct AreaOverview: Hashable, Sendable, Identifiable {
    public var area: OrganizationArea
    public var proposalCount: Int
    public var distinctAssets: Int
    public var existingMatches: Int
    public var newAlbumsNeeded: Int
    public var extendable: Int
    public var uncertain: Int
    public var id: OrganizationArea { area }

    public static func make(proposals: [AlbumProposal], matches: [SortlyID: MatchResult]) -> [AreaOverview] {
        var byArea: [OrganizationArea: [AlbumProposal]] = [:]
        for p in proposals { byArea[p.kind.area, default: []].append(p) }
        return OrganizationArea.allCases.compactMap { area in
            guard let ps = byArea[area] else { return nil }
            var assets = Set<AssetID>()
            var existing = 0, new = 0, extendable = 0, uncertain = 0
            for p in ps {
                assets.formUnion(p.assetIDs)
                let status = matches[p.id]?.status
                switch status {
                case .alreadyComplete, .possibleMatch, .multipleMatches: existing += 1
                case .extendable: existing += 1; extendable += 1
                case .newAlbumRequired, .nameConflict, .notEditable, .none: new += 1
                case .ambiguous: break
                }
                // One count per suggestion, whatever makes it uncertain.
                if status == .ambiguous || p.reliability < .likely || p.requiresUserName { uncertain += 1 }
            }
            return AreaOverview(area: area, proposalCount: ps.count, distinctAssets: assets.count, existingMatches: existing,
                                newAlbumsNeeded: new, extendable: extendable, uncertain: uncertain)
        }
    }
}
