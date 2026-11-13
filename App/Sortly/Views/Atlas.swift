import SwiftUI
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
    static let top = Color(red: 0.02, green: 0.20, blue: 0.27)
    static let bottom = Color(red: 0.01, green: 0.06, blue: 0.10)
    static let glow = Color(red: 0.33, green: 0.92, blue: 0.84)
    static let warm = Color(red: 1.00, green: 0.80, blue: 0.42)
    static var background: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

// MARK: - Map

/// World map with glowing visited countries. `highlighted` may grow during the animation.
struct AtlasMap: View {
    var outlines: [AtlasOutlines.Country]
    var highlighted: Set<String>
    /// The most recently revealed country gets a warm accent.
    var latest: String? = nil

    var body: some View {
        Canvas { context, size in
            let north = 83.0, south = -56.0
            func point(_ c: GeoCoordinate) -> CGPoint {
                CGPoint(x: (c.longitude + 180) / 360 * size.width,
                        y: (north - min(max(c.latitude, south), north)) / (north - south) * size.height)
            }
            // Graticule: faint dotted lines every 30°.
            var grid = Path()
            for lon in stride(from: -150.0, through: 150.0, by: 30) {
                let x = (lon + 180) / 360 * size.width
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for lat in stride(from: -30.0, through: 60.0, by: 30) {
                let y = (north - lat) / (north - south) * size.height
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 0.6, dash: [1.5, 3]))

            var land = Path(), visited = Path(), recent = Path()
            for country in outlines {
                var path = Path()
                for ring in country.rings {
                    guard let first = ring.first else { continue }
                    path.move(to: point(first))
                    for c in ring.dropFirst() { path.addLine(to: point(c)) }
                    path.closeSubpath()
                }
                if country.code == latest { recent.addPath(path) }
                else if highlighted.contains(country.code) { visited.addPath(path) }
                else { land.addPath(path) }
            }
            context.fill(land, with: .color(.white.opacity(0.13)), style: FillStyle(eoFill: true))
            // Glow layer underneath the visited countries.
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: max(3, size.width / 90)))
                glow.fill(visited, with: .color(AtlasStyle.glow.opacity(0.9)), style: FillStyle(eoFill: true))
                glow.fill(recent, with: .color(AtlasStyle.warm), style: FillStyle(eoFill: true))
            }
            context.fill(visited, with: .linearGradient(Gradient(colors: [AtlasStyle.glow, Color(red: 0.55, green: 1, blue: 0.9)]),
                                                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)),
                         style: FillStyle(eoFill: true))
            context.fill(recent, with: .color(AtlasStyle.warm), style: FillStyle(eoFill: true))
        }
        .aspectRatio(360 / 139, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Screen

/// "Dein Reise-Atlas": countries light up in the order of the first visit.
struct AtlasView: View {
    @Environment(AppModel.self) private var model
    @State private var outlines: [AtlasOutlines.Country] = []
    @State private var revealed = 0
    @State private var story: String?
    @State private var writing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var atlas: TravelAtlas { TravelAtlas.compute(facts: model.facts) }

    var body: some View {
        let atlas = atlas
        let order = atlas.countriesByFirstVisit
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                AtlasContent(atlas: atlas, outlines: outlines, revealed: revealed)
                if SmartAssistant.isAvailable && !order.isEmpty {
                    storySection(atlas)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, 40)
        }
        .background(AtlasStyle.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle("Reise-Atlas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: ShareCardImage(atlas: atlas, sortedPhotos: model.progress.fully, map: model.worldMap),
                          preview: SharePreview(Text("Mein Reise-Atlas"), image: Image(systemName: "globe.europe.africa.fill"))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Reise-Atlas teilen")
            }
        }
        .task {
            outlines = await AtlasOutlines.shared.load(from: model.worldMap)
            guard revealed == 0 else { return }
            if reduceMotion { revealed = order.count; return }
            // Light up one country after another; long lists speed up.
            let step = order.count > 40 ? 0.06 : (order.count > 15 ? 0.12 : 0.25)
            for index in 1...max(order.count, 1) {
                try? await Task.sleep(for: .seconds(step))
                withAnimation(.easeOut(duration: 0.25)) { revealed = index }
            }
        }
    }
}

extension AtlasView {
    @ViewBuilder
    func storySection(_ atlas: TravelAtlas) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let story {
                Text(story)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
            Button {
                Task { await tell(atlas) }
            } label: {
                if writing {
                    ProgressView().tint(.white)
                } else {
                    Label(story == nil ? "Erzähl meine Reisegeschichte" : "Neu erzählen", systemImage: "apple.intelligence")
                }
            }
            .font(.headline)
            .foregroundStyle(AtlasStyle.glow)
            .disabled(writing)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    func tell(_ atlas: TravelAtlas) async {
        writing = true
        defer { writing = false }
        let text = await SmartAssistant.travelStory(facts: Self.storyFacts(atlas))
        withAnimation { story = text ?? String(localized: "Die Geschichte konnte gerade nicht geschrieben werden. Versuch es gleich noch einmal.") }
    }

    /// Plain facts for the language model; nothing else is passed in.
    static func storyFacts(_ atlas: TravelAtlas) -> [String] {
        let year = { (date: Date) in String(Calendar.current.component(.year, from: date)) }
        var lines: [String] = []
        lines.append("Länder insgesamt: \(atlas.countryCodes.count), Kontinente: \(atlas.continents.count), Städte: \(atlas.cityCount), Reisen: \(atlas.tripCount)")
        if let since = atlas.sinceYear { lines.append("Fotos mit Ort seit: \(since)") }
        let firsts = atlas.countriesByFirstVisit.prefix(12).compactMap { code in
            atlas.firstVisits[code].map { "\(AtlasStyle.countryName(code)) (\(year($0)))" }
        }
        if !firsts.isEmpty { lines.append("Länder in der Reihenfolge des ersten Besuchs: " + firsts.joined(separator: ", ")) }
        if let first = atlas.trips.first {
            lines.append("Erste Reise: \(first.place), \(AtlasStyle.countryName(first.countryCode)), \(year(first.start)), \(first.days) Tage")
        }
        if let longest = atlas.trips.max(by: { $0.days < $1.days }) {
            lines.append("Längste Reise: \(longest.place), \(AtlasStyle.countryName(longest.countryCode)), \(year(longest.start)), \(longest.days) Tage")
        }
        if let latest = atlas.trips.last {
            lines.append("Letzte Reise: \(latest.place), \(AtlasStyle.countryName(latest.countryCode)), \(year(latest.start))")
        }
        if let city = atlas.favoriteTripCity { lines.append("Meistfotografierter Reiseort: \(city)") }
        return lines
    }
}

/// The atlas content without scrolling (also used for rendering tests).
struct AtlasContent: View {
    var atlas: TravelAtlas
    var outlines: [AtlasOutlines.Country]
    var revealed: Int

    var body: some View {
        let order = atlas.countriesByFirstVisit
        let shown = Array(order.prefix(revealed))
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            AtlasMap(outlines: outlines, highlighted: Set(shown), latest: revealed < order.count ? shown.last : nil)
                .padding(.top, Theme.Spacing.m)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(shown.count.formatted())
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(shown.count == 1 ? "Land" : "Länder").font(.title.weight(.bold))
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)

            HStack(spacing: Theme.Spacing.s) {
                pill("\(Int(atlas.worldShare * 100)) % der Welt")
                pill("\(atlas.continents.count) von 7 Kontinenten")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Spacing.s) {
                tile("building.2", atlas.cityCount.formatted(), "Städte")
                tile("airplane", atlas.tripCount.formatted(), "Reisen")
                if let year = atlas.sinceYear { tile("calendar", String(year), "unterwegs seit") }
                if let days = atlas.longestTripDays { tile("clock", "\(days)", days == 1 ? "Tag längste Reise" : "Tage längste Reise") }
            }

            if let city = atlas.favoriteTripCity {
                Label { Text("Lieblingsziel: \(city)") } icon: { Image(systemName: "heart.fill").foregroundStyle(AtlasStyle.warm) }
                    .font(.headline).foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, code in
                    HStack(spacing: Theme.Spacing.m) {
                        Text(TravelAtlas.flag(code)).font(.title2)
                        Text(AtlasStyle.countryName(code)).foregroundStyle(.white)
                        Spacer()
                        if let date = atlas.firstVisits[code] {
                            Text(String(Calendar.current.component(.year, from: date)))
                                .monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    if index < shown.count - 1 { Divider().overlay(.white.opacity(0.1)) }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func pill(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(AtlasStyle.glow)
            .background(AtlasStyle.glow.opacity(0.14), in: Capsule())
    }

    private func tile(_ symbol: String, _ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(AtlasStyle.glow)
            Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.footnote).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Overview teaser

struct AtlasTeaser: View {
    @Environment(AppModel.self) private var model
    @State private var outlines: [AtlasOutlines.Country] = []

    var body: some View {
        let atlas = TravelAtlas.compute(facts: model.facts)
        if !atlas.countryCodes.isEmpty {
            NavigationLink {
                AtlasView()
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    AtlasMap(outlines: outlines, highlighted: atlas.countryCodes)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dein Reise-Atlas").font(.headline).foregroundStyle(.white)
                            Text("\(atlas.countryCodes.count) Länder · \(atlas.cityCount) Städte · \(atlas.tripCount) Reisen")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(Theme.Spacing.l)
                .background(AtlasStyle.background, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .task { outlines = await AtlasOutlines.shared.load(from: model.worldMap) }
        }
    }
}

// MARK: - Share image (story format 1080 × 1920)

struct ShareCard: View {
    var atlas: TravelAtlas
    var sortedPhotos: Int
    var outlines: [AtlasOutlines.Country]

    var body: some View {
        let order = atlas.countriesByFirstVisit
        VStack(alignment: .leading, spacing: 26) {
            Text("MEIN REISE-ATLAS")
                .font(.system(size: 22, weight: .bold)).kerning(3)
                .foregroundStyle(AtlasStyle.glow)
            AtlasMap(outlines: outlines, highlighted: atlas.countryCodes)
                .padding(.horizontal, -24)
            if order.isEmpty {
                Text(sortedPhotos.formatted()).font(.system(size: 120, weight: .heavy, design: .rounded))
                Text("Fotos sortiert").font(.system(size: 38, weight: .bold))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(order.count.formatted()).font(.system(size: 140, weight: .heavy, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(order.count == 1 ? "Land" : "Länder").font(.system(size: 44, weight: .bold))
                }
                Text("\(Int(atlas.worldShare * 100)) % der Welt · \(atlas.continents.count) von 7 Kontinenten")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(AtlasStyle.glow)
                Text(order.prefix(28).map(TravelAtlas.flag).joined(separator: " "))
                    .font(.system(size: 38))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 34) {
                    stat(atlas.cityCount, "Städte")
                    stat(atlas.tripCount, "Reisen")
                    if let days = atlas.longestTripDays, days > 1 { stat(days, "Tage am Stück") }
                }
                if let city = atlas.favoriteTripCity {
                    Label { Text("Lieblingsziel: \(city)") } icon: { Image(systemName: "heart.fill").foregroundStyle(AtlasStyle.warm) }
                        .font(.system(size: 26, weight: .semibold))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill").foregroundStyle(AtlasStyle.glow)
                Text("\(AppInfo.name) · Fotos sortiert, alles auf dem iPhone")
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 60)
        .padding(.top, 110)
        .padding(.bottom, 90)
        .frame(width: 720, height: 1280, alignment: .topLeading)
        .background(AtlasStyle.background)
        .environment(\.colorScheme, .dark)
    }

    private func stat(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Rendered to PNG only when the user actually shares.
struct ShareCardImage: Transferable {
    var atlas: TravelAtlas
    var sortedPhotos: Int
    var map: OfflineWorldMap?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in
            try await card.pngData()
        }
    }

    @MainActor
    func pngData(scale: CGFloat = 1.5) async throws -> Data {
        let outlines = await AtlasOutlines.shared.load(from: map)
        let renderer = ImageRenderer(content: ShareCard(atlas: atlas, sortedPhotos: sortedPhotos, outlines: outlines))
        renderer.scale = scale  // 720 × 1280 pt × 1.5 = 1080 × 1920 px
        guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
