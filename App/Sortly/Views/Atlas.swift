import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SortlyCore
import SortlyWorldMap

// MARK: - Data

/// Country outlines for drawing, decoded once from the offline map and kept in memory.
@MainActor
final class AtlasOutlines {
    static let shared = AtlasOutlines()
    typealias Country = (code: String, rings: [[GeoCoordinate]])
    private(set) var countries: [Country] = []
    private var loading: Task<[Country], Never>?

    func load(from map: OfflineWorldMap?) async -> [Country] {
        if !countries.isEmpty { return countries }
        if let loading { return await loading.value }
        let task = Task.detached(priority: .userInitiated) { () -> [Country] in
            guard let map = map ?? (try? WorldMapResource.load()) else { return [] }
            return map.regions
                .filter { $0.level == .country && $0.isoCode != "AQ" }
                .map { (String($0.isoCode.prefix(2)).uppercased(), map.outline(of: $0, minimumStepDegrees: 0.3)) }
        }
        loading = task
        countries = await task.value
        loading = nil
        return countries
    }
}

enum AtlasStyle {
    /// Visited countries use the app tint; the newest one in the reveal animation is orange.
    static let visited = Theme.accent
    static let latest = Color.orange
    static let land = Color(uiColor: .systemGray5)

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

// MARK: - Map

/// Flat world map in system colors, like the map in the Photos app. `highlighted` may grow
/// during the reveal animation.
struct AtlasMap: View {
    var outlines: [AtlasOutlines.Country]
    var highlighted: Set<String>
    /// The most recently revealed country is drawn in orange.
    var latest: String? = nil
    /// Called with the visited country under the finger; nil = the map is not tappable.
    var onTapCountry: ((String) -> Void)? = nil
    @State private var size: CGSize = .zero

    private static func path(_ country: AtlasOutlines.Country, in size: CGSize) -> Path {
        let north = 83.0, south = -56.0
        func point(_ c: GeoCoordinate) -> CGPoint {
            CGPoint(x: (c.longitude + 180) / 360 * size.width,
                    y: (north - min(max(c.latitude, south), north)) / (north - south) * size.height)
        }
        var path = Path()
        for ring in country.rings {
            guard let first = ring.first else { continue }
            path.move(to: point(first))
            for c in ring.dropFirst() { path.addLine(to: point(c)) }
            path.closeSubpath()
        }
        return path
    }

    /// The visited country at `location`; small countries get a few points of slack.
    private func country(at location: CGPoint) -> String? {
        let visited = outlines.filter { highlighted.contains($0.code) }
        let paths = visited.map { ($0.code, Self.path($0, in: size)) }
        if let hit = paths.first(where: { $0.1.contains(location, eoFill: true) }) { return hit.0 }
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - location.x, 0, location.x - rect.maxX), max(rect.minY - location.y, 0, location.y - rect.maxY))
        }
        return paths.map { ($0.0, distance($0.1.boundingRect)) }
            .filter { $0.1 <= 12 }
            .min { $0.1 < $1.1 }?.0
    }

    var body: some View {
        Canvas { context, size in
            var land = Path(), visited = Path(), recent = Path()
            for country in outlines {
                let path = Self.path(country, in: size)
                if country.code == latest { recent.addPath(path) }
                else if highlighted.contains(country.code) { visited.addPath(path) }
                else { land.addPath(path) }
            }
            let fill = FillStyle(eoFill: true)
            context.fill(land, with: .color(AtlasStyle.land), style: fill)
            context.fill(visited, with: .color(AtlasStyle.visited), style: fill)
            context.fill(recent, with: .color(AtlasStyle.latest), style: fill)
        }
        .aspectRatio(360 / 139, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onTapGesture(coordinateSpace: .local) { location in
            guard let onTapCountry, let code = country(at: location) else { return }
            onTapCountry(code)
        }
        .allowsHitTesting(onTapCountry != nil)
        .accessibilityHidden(true) // the country list below is the accessible way in
    }
}

// MARK: - Screen

/// "Dein Reise-Atlas": countries fill in the order of the first visit.
struct AtlasView: View {
    @Environment(AppModel.self) private var model
    @State private var outlines: [AtlasOutlines.Country] = []
    @State private var revealed = 0
    @State private var story: String?
    @State private var storyScope: PhotoStory.Scope = .trips
    @State private var writing = false
    @State private var sharing = false
    /// nil = all years.
    @State private var year: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var atlas: TravelAtlas { model.travelAtlas(year: year) }

    var body: some View {
        let atlas = atlas
        let order = atlas.countriesByFirstVisit
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if model.atlasYears.count > 1 { yearPicker }
                AtlasContent(atlas: atlas, outlines: outlines, revealed: min(revealed, order.count))
                if SmartAssistant.isAvailable && !model.facts.isEmpty {
                    storySection(atlas)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .navigationTitle("Reise-Atlas")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Reise-Atlas teilen")
                    .disabled(order.isEmpty)
            }
        }
        .onChange(of: year) {
            // Switching the year shows the result at once (no fill animation).
            revealed = atlas.countriesByFirstVisit.count
        }
        .sheet(isPresented: $sharing) {
            ShareCardSheet(atlas: atlas, sortedPhotos: model.progress.fully, map: model.worldMap)
        }
        .task {
            outlines = await AtlasOutlines.shared.load(from: model.worldMap)
            guard revealed == 0 else { return }
            if reduceMotion { revealed = order.count; return }
            // Fill one country after another; long lists speed up.
            let step = order.count > 40 ? 0.06 : (order.count > 15 ? 0.12 : 0.25)
            for index in 1...max(order.count, 1) {
                try? await Task.sleep(for: .seconds(step))
                withAnimation(.easeOut(duration: 0.25)) { revealed = index }
            }
        }
    }
}

extension AtlasView {
    /// "Alle Jahre" plus every year with travel photos, for a yearly review ("Mein Reisejahr").
    var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                yearChip(nil)
                ForEach(model.atlasYears, id: \.self) { yearChip($0) }
            }
        }
        .scrollClipDisabled()
    }

    private func yearChip(_ value: Int?) -> some View {
        let selected = value == year
        return Button {
            withAnimation(.snappy) { year = value }
        } label: {
            Group {
                if let value { Text(verbatim: String(value)) } else { Text("Alle Jahre") }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? Theme.accent : Theme.card, in: Capsule())
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    func storySection(_ atlas: TravelAtlas) -> some View {
        let years = PhotoStory.availableYears(model.facts)
        Card {
            HStack {
                Text("Deine Foto-Geschichte").font(.headline)
                Spacer()
                Picker("Geschichte über", selection: $storyScope) {
                    Text("Reisen").tag(PhotoStory.Scope.trips)
                    Text("Alles").tag(PhotoStory.Scope.all)
                    ForEach(years.prefix(10), id: \.self) { year in
                        Text(verbatim: String(year)).tag(PhotoStory.Scope.year(year))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: storyScope) { story = nil }
            }
            if let story {
                Text(story)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity)
                ShareLink(item: story) { Label("Text teilen", systemImage: "square.and.arrow.up") }
                    .font(.subheadline)
            }
            Button {
                Task { await tell() }
            } label: {
                if writing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label(story == nil ? "Erzähl meine Geschichte" : "Neu erzählen", systemImage: "apple.intelligence")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(writing)
            Text("Geschrieben von Apple Intelligence auf deinem Gerät, nur aus Zahlen, Orten und Themen.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    func tell() async {
        writing = true
        defer { writing = false }
        let facts = model.facts, scope = storyScope
        let lines = await Task.detached(priority: .userInitiated) { PhotoStory.facts(scope, facts: facts) }.value
        let text = await SmartAssistant.travelStory(facts: lines)
        withAnimation { story = text ?? String(localized: "Die Geschichte konnte gerade nicht geschrieben werden. Versuch es gleich noch einmal.") }
    }
}

/// The atlas content without scrolling (also used for rendering tests).
struct AtlasContent: View {
    var atlas: TravelAtlas
    var outlines: [AtlasOutlines.Country]
    var revealed: Int
    /// Country tapped on the map; opens its photos like a tap in the list.
    @State private var tappedCountry: String?
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 56

    var body: some View {
        let order = atlas.countriesByFirstVisit
        let shown = Array(order.prefix(revealed))
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Card {
                AtlasMap(outlines: outlines, highlighted: Set(shown), latest: revealed < order.count ? shown.last : nil) {
                    tappedCountry = $0
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(shown.count.formatted())
                            .font(.system(size: numberSize, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(shown.count == 1 ? "Land" : "Länder").font(.title2.weight(.semibold))
                    }
                    Text("\(Int(atlas.worldShare * 100)) % der Welt · \(atlas.continents.count) von 7 Kontinenten")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if atlas.year != nil && !atlas.newCountryCodes.isEmpty {
                        Label {
                            Text("\(atlas.newCountryCodes.count) zum ersten Mal besucht")
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible())], spacing: Theme.Spacing.m) {
                tile("building.2.fill", atlas.cityCount.formatted(), atlas.cityCount == 1 ? "Stadt" : "Städte")
                tile("airplane", atlas.tripCount.formatted(), atlas.tripCount == 1 ? "Reise" : "Reisen")
                if atlas.year == nil, let year = atlas.sinceYear { tile("calendar", String(year), "unterwegs seit") }
                if let days = atlas.longestTripDays { tile("clock.fill", "\(days)", days == 1 ? "Tag längste Reise" : "Tage längste Reise") }
            }

            if let city = atlas.favoriteTripCity {
                Card {
                    Label { Text("Lieblingsziel: \(city)") } icon: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                        .font(.headline)
                }
            }

            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, code in
                        // Destination-based link (see DECISIONS: no value-based links).
                        NavigationLink {
                            CountryPhotosView(code: code, year: atlas.year)
                        } label: {
                            HStack(spacing: Theme.Spacing.m) {
                                Text(TravelAtlas.flag(code)).font(.title2).accessibilityHidden(true)
                                Text(AtlasStyle.countryName(code))
                                Spacer()
                                if atlas.newCountryCodes.contains(code) {
                                    Text("Neu").font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Theme.accent.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Theme.accent)
                                } else if let date = atlas.firstVisits[code] {
                                    Text(verbatim: String(Calendar.current.component(.year, from: date)))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        if index < shown.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
        .navigationDestination(item: $tappedCountry) { code in
            CountryPhotosView(code: code, year: atlas.year)
        }
    }

    private func tile(_ symbol: String, _ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).font(.subheadline)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Overview teaser

struct AtlasTeaser: View {
    @Environment(AppModel.self) private var model
    @State private var outlines: [AtlasOutlines.Country] = []

    var body: some View {
        let atlas = model.travelAtlas()
        if !atlas.countryCodes.isEmpty {
            NavigationLink {
                AtlasView()
            } label: {
                Card {
                    AtlasMap(outlines: outlines, highlighted: atlas.countryCodes)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dein Reise-Atlas").font(.headline)
                            Text(Counted.join([String(localized: "\(atlas.countryCodes.count) Länder"), String(localized: "\(atlas.cityCount) Städte"),
                                               String(localized: "\(atlas.tripCount) Reisen")]))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .task { outlines = await AtlasOutlines.shared.load(from: model.worldMap) }
        }
    }
}

// MARK: - Share image (story format 1080 × 1920)

/// Light, bold share image with a real photo from the favorite destination on top.
/// Always rendered in light mode so it looks the same for everyone who receives it.
struct ShareCard: View {
    var atlas: TravelAtlas
    var sortedPhotos: Int
    var outlines: [AtlasOutlines.Country]
    var cover: UIImage? = nil

    var body: some View {
        let order = atlas.countriesByFirstVisit
        VStack(alignment: .leading, spacing: 0) {
            if let cover, let city = atlas.favoriteTripCity {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: cover).resizable().scaledToFill()
                        .frame(width: 720, height: 460).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lieblingsziel").font(.system(size: 24, weight: .semibold)).opacity(0.9)
                        Text(verbatim: city).font(.system(size: 60, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 52).padding(.bottom, 36)
                }
                .frame(width: 720, height: 460)
            }
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let year = atlas.year {
                        Text("Mein Reisejahr \(String(year))")
                    } else {
                        Text("Mein Reise-Atlas")
                    }
                }
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AtlasStyle.visited)
                if order.isEmpty {
                    Text(sortedPhotos.formatted()).font(.system(size: 120, weight: .bold)).monospacedDigit()
                    Text("Fotos sortiert").font(.system(size: 38, weight: .semibold))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(order.count.formatted()).font(.system(size: 116, weight: .bold)).monospacedDigit()
                                .minimumScaleFactor(0.5).lineLimit(1)
                            Text(order.count == 1 ? "Land" : "Länder").font(.system(size: 42, weight: .semibold))
                        }
                        if atlas.year != nil && !atlas.newCountryCodes.isEmpty {
                            Text("davon \(atlas.newCountryCodes.count) zum ersten Mal · \(atlas.continents.count) von 7 Kontinenten")
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                        } else {
                            Text("\(Int(atlas.worldShare * 100)) % der Welt · \(atlas.continents.count) von 7 Kontinenten")
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    AtlasMap(outlines: outlines, highlighted: atlas.countryCodes)
                        .padding(.vertical, cover == nil ? 24 : 4)
                    flags(order)
                    HStack(spacing: 40) {
                        stat(atlas.cityCount, atlas.cityCount == 1 ? "Stadt" : "Städte")
                        stat(atlas.tripCount, atlas.tripCount == 1 ? "Reise" : "Reisen")
                        if let days = atlas.longestTripDays, days > 1 { stat(days, "Tage am Stück") }
                    }
                    if cover == nil, let city = atlas.favoriteTripCity {
                        Label { Text("Lieblingsziel: \(city)") } icon: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                            .font(.system(size: 26, weight: .semibold))
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.fill").foregroundStyle(AtlasStyle.visited)
                    Text("\(AppInfo.name) · Fotos sortiert, alles auf dem Gerät")
                }
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 52)
            .padding(.top, cover == nil ? 110 : 40)
            .padding(.bottom, 56)
        }
        .frame(width: 720, height: 1280, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    /// One row of flags; the rest is summarized as "+N".
    private func flags(_ order: [String]) -> some View {
        let limit = order.count > 11 ? 10 : 11
        let shown = order.prefix(limit).map(TravelAtlas.flag).joined(separator: " ")
        return HStack(spacing: 10) {
            Text(verbatim: shown).font(.system(size: 36)).lineLimit(1)
            if order.count > limit {
                Text("+\(order.count - limit)").font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.system(size: 44, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

/// Preview of the share image before anything leaves the app; the photo can be turned off.
struct ShareCardSheet: View {
    var atlas: TravelAtlas
    var sortedPhotos: Int
    var map: OfflineWorldMap?
    @Environment(\.dismiss) private var dismiss
    @State private var outlines: [AtlasOutlines.Country] = []
    @State private var cover: UIImage?
    @State private var showPhoto = true

    private var image: ShareCardImage {
        ShareCardImage(atlas: atlas, sortedPhotos: sortedPhotos, map: map, cover: showPhoto ? cover : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.l) {
                GeometryReader { proxy in
                    let scale = min(proxy.size.width / 720, proxy.size.height / 1280)
                    ShareCard(atlas: atlas, sortedPhotos: sortedPhotos, outlines: outlines, cover: showPhoto ? cover : nil)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: 720 * scale, height: 1280 * scale, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 24 * scale * 2, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Vorschau des Teilen-Bilds"))
                if cover != nil {
                    Toggle("Foto vom Lieblingsziel zeigen", isOn: $showPhoto.animation())
                }
                ShareLink(item: image, preview: SharePreview(Text("Mein Reise-Atlas"), image: Image(systemName: "map.fill"))) {
                    Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(Theme.Spacing.l)
            .background(Theme.background)
            .navigationTitle("Reise-Atlas teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
            }
            .task {
                outlines = await AtlasOutlines.shared.load(from: map)
                if let id = atlas.favoriteTripCover { cover = await ShareCardImage.loadCover(id) }
            }
        }
        .presentationDetents([.large])
    }
}

/// Rendered to PNG only when the user actually shares.
struct ShareCardImage: Transferable {
    var atlas: TravelAtlas
    var sortedPhotos: Int
    var map: OfflineWorldMap?
    var cover: UIImage?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in
            try await card.pngData()
        }
    }

    @MainActor
    func pngData(scale: CGFloat = 1.5) async throws -> Data {
        let outlines = await AtlasOutlines.shared.load(from: map)
        let renderer = ImageRenderer(content: ShareCard(atlas: atlas, sortedPhotos: sortedPhotos, outlines: outlines, cover: cover))
        renderer.scale = scale  // 720 × 1280 pt × 1.5 = 1080 × 1920 px
        guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// Loads the cover photo in good quality from the device only (no iCloud download).
    /// Nonisolated: PhotoKit may call the result handler on a background queue.
    nonisolated static func loadCover(_ id: AssetID) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1080, height: 1080),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
