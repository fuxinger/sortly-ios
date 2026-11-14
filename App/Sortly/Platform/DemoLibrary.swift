#if targetEnvironment(simulator)
import CoreLocation
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Simulator only (browser testing on Appetize, App Store screenshots): fills the empty
/// simulator library with a realistic example library. Travel photos are crops of the
/// simulator's own sample photos with dates and GPS of real trips; screenshots and
/// paper documents are rendered text. Never part of a device build.
@MainActor
@Observable
final class DemoLibrary {
    static let shared = DemoLibrary()

    private(set) var isSeeding = false
    private(set) var created = 0
    private(set) var total = 0
    private(set) var isDone = UserDefaults.standard.bool(forKey: "demo.seeded")

    struct Spot { var lat: Double; var lon: Double }
    struct Trip { var spot: Spot; var year: Int; var month: Int; var day: Int; var days: Int; var photos: Int }

    static let home = Spot(lat: 48.1374, lon: 11.5755)          // München
    static let grandma = Spot(lat: 48.3520, lon: 11.7930)       // a second frequent place
    static let trips: [Trip] = [
        Trip(spot: Spot(lat: 48.8566, lon: 2.3522), year: 2018, month: 10, day: 5, days: 3, photos: 12),      // Paris
        Trip(spot: Spot(lat: 41.3874, lon: 2.1686), year: 2019, month: 6, day: 20, days: 5, photos: 14),     // Barcelona
        Trip(spot: Spot(lat: 40.7128, lon: -74.0060), year: 2019, month: 11, day: 2, days: 6, photos: 16),   // New York
        Trip(spot: Spot(lat: 48.2082, lon: 16.3738), year: 2020, month: 2, day: 21, days: 2, photos: 10),     // Wien
        Trip(spot: Spot(lat: 62.1008, lon: 7.2059), year: 2021, month: 7, day: 12, days: 5, photos: 14),     // Geiranger
        Trip(spot: Spot(lat: 43.5081, lon: 16.4402), year: 2021, month: 8, day: 20, days: 7, photos: 14),    // Split
        Trip(spot: Spot(lat: 38.7223, lon: -9.1393), year: 2022, month: 4, day: 14, days: 4, photos: 12),    // Lissabon
        Trip(spot: Spot(lat: 43.7696, lon: 11.2558), year: 2022, month: 9, day: 3, days: 3, photos: 11),      // Florenz
        Trip(spot: Spot(lat: 55.6761, lon: 12.5683), year: 2023, month: 5, day: 18, days: 3, photos: 10),     // Kopenhagen
        Trip(spot: Spot(lat: 64.1466, lon: -21.9426), year: 2023, month: 8, day: 1, days: 4, photos: 12),    // Reykjavík
        Trip(spot: Spot(lat: 63.4186, lon: -19.0060), year: 2023, month: 8, day: 5, days: 3, photos: 10),     // Vík
        Trip(spot: Spot(lat: 41.8902, lon: 12.4922), year: 2024, month: 5, day: 10, days: 5, photos: 20),    // Rom
        Trip(spot: Spot(lat: 35.0116, lon: 135.7681), year: 2024, month: 10, day: 8, days: 6, photos: 16),   // Kyoto
    ]

    static let screenshots: [[String]] = [
        ["Bestellung bestätigt", "Bestellnummer 304-1188274", "Wanderschuhe, Größe 43", "Lieferung: Donnerstag", "Gesamtbetrag: 89,90 €"],
        ["Bordkarte", "MUC → FCO", "Flug SX 1234", "Sitz 14A · Gate G22", "Boarding 07:35"],
        ["Rezept: Pasta al limone", "200 g Spaghetti", "1 Bio-Zitrone", "50 g Parmesan", "Butter, Pfeffer, Salz"],
        ["Konzertticket", "Olympiahalle München", "Einlass 19:00 Uhr", "Block C · Reihe 12 · Platz 8"],
        ["Hotelbuchung bestätigt", "Hotel Campo de’ Fiori, Rom", "10.–15. Mai", "Buchungsnummer 77120934"],
        ["Bahnticket", "München Hbf → Salzburg Hbf", "Sparpreis · 2. Klasse", "Zug fährt 08:24 ab Gleis 12"],
        ["WLAN-Zugang", "Netzwerk: Ferienwohnung-Split", "Passwort: sonne2021"],
        ["Bestellung versandt", "Bestellnummer 112-5534", "Kaffeemaschine", "Sendungsnummer 00340434161094"],
    ]

    static let documents: [[String]] = [
        ["Rechnung Nr. 2024-118", "Stadtwerke Musterstadt", "Abrechnungszeitraum 01.01.–31.12.2024", "Strom 2.340 kWh", "Rechnungsbetrag 812,40 €"],
        ["Kassenbon", "Supermarkt am Markt", "Äpfel 2,49", "Brot 3,20", "Milch 1,19", "Summe EUR 6,88"],
        ["Garantiekarte", "Waschmaschine WM 8000", "Kaufdatum 14.03.2023", "Garantie bis 14.03.2025"],
        ["Rechnung Nr. 5531", "Autowerkstatt Huber", "Inspektion und Ölwechsel", "Gesamt 289,00 €"],
    ]

    var expectedCount: Int {
        Self.trips.reduce(0) { $0 + $1.photos } + 45 + 12 + Self.screenshots.count + Self.documents.count
    }


    enum Spec {
        case photo(Spot, spread: Double, date: Date)
        case screenshot([String], date: Date)
        case document([String], date: Date)
    }

    /// Creates the example library and starts the analysis.
    func seed(then model: AppModel) async {
        guard !isSeeding else { return }
        isSeeding = true
        defer { isSeeding = false }
        created = 0
        var rng = SeededRandom(seed: 2026)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func date(_ y: Int, _ m: Int, _ d: Int, plusDays: Int = 0, hour: Int, minute: Int) -> Date {
            let start = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
            return calendar.date(byAdding: .day, value: plusDays, to: start)!
        }

        var specs: [Spec] = []
        for trip in Self.trips {
            for i in 0..<trip.photos {
                specs.append(.photo(trip.spot, spread: 0.02, date: date(trip.year, trip.month, trip.day, plusDays: i % trip.days,
                                                                         hour: 9 + Int(rng.next(in: 0...10)), minute: Int(rng.next(in: 0...59)))))
            }
        }
        for i in 0..<45 {   // everyday life at home, spread over several years
            specs.append(.photo(Self.home, spread: 0.03, date: date(2018 + i % 7, 1 + (i * 5) % 12, 1 + (i * 7) % 27, hour: 10 + i % 9, minute: (i * 13) % 60)))
        }
        for i in 0..<12 {   // regular visits to the same place
            specs.append(.photo(Self.grandma, spread: 0.0005, date: date(2020 + i % 5, 1 + (i * 3) % 12, 5 + i, hour: 15, minute: 10 + i)))
        }
        for (i, lines) in Self.screenshots.enumerated() {
            specs.append(.screenshot(lines, date: date(2024, 1 + i, 3 + i, hour: 18, minute: 2 * i)))
        }
        for (i, lines) in Self.documents.enumerated() {
            specs.append(.document(lines, date: date(2024, 2 + 2 * i, 10, hour: 20, minute: 15)))
        }
        total = specs.count

        let sources = await sampleImages()
        var number = 1000
        for start in stride(from: 0, to: specs.count, by: 15) {
            var chunk: [Item] = []
            for spec in specs[start..<min(start + 15, specs.count)] {
                number += 1
                switch spec {
                case let .photo(spot, spread, day):
                    let location = CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: spot.lat + rng.next(in: -spread...spread),
                                                           longitude: spot.lon + rng.next(in: -spread...spread)),
                        altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 8, timestamp: day)
                    let source = sources.isEmpty ? Self.fallbackImage() : sources[Int(rng.next(in: 0...999)) % sources.count]
                    let image = Self.crop(source, rng: &rng)
                    chunk.append(Item(data: image.jpegData(compressionQuality: 0.85)!, type: .jpeg, name: "IMG_\(number).JPG", date: day, location: location))
                case let .screenshot(lines, day):
                    chunk.append(Item(data: Self.screenshotPNG(lines), type: .png, name: "IMG_\(number).PNG", date: day, location: nil))
                case let .document(lines, day):
                    chunk.append(Item(data: Self.documentPhoto(lines).jpegData(compressionQuality: 0.85)!, type: .jpeg,
                                      name: "IMG_\(number).JPG", date: day, location: nil))
                }
            }
            let items = chunk
            do {
                try await Self.save(items)
                created += items.count
            } catch {
                model.message = error.localizedDescription
                return
            }
            await Task.yield()
        }
        isDone = true
        UserDefaults.standard.set(true, forKey: "demo.seeded")
        model.startAnalysis(userInitiated: true)
    }

    /// Nonisolated on purpose: PhotoKit runs the change block on its own queue, and a
    /// main-actor closure there traps at runtime (Swift 6 isolation check).
    nonisolated static func save(_ items: [Item]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = item.name
                options.uniformTypeIdentifier = item.type.identifier
                request.addResource(with: .photo, data: item.data, options: options)
                request.creationDate = item.date
                request.location = item.location
            }
        }
    }

    /// Nonisolated for the same reason: the result handler may arrive on a background queue.
    nonisolated static func requestImage(_ identifier: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    struct Item: @unchecked Sendable {
        var data: Data
        var type: UTType
        var name: String
        var date: Date
        var location: CLLocation?
    }

    // MARK: Images

    private func sampleImages() async -> [UIImage] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 12
        let assets = PHAsset.fetchAssets(with: options)
        var images: [UIImage] = []
        for index in 0..<assets.count {
            if let image = await Self.requestImage(assets.object(at: index).localIdentifier, side: 2400) { images.append(image) }
        }
        return images
    }

    /// A random 50–85 % crop, sometimes mirrored, as a 1600 × 1200 (or portrait) photo.
    static func crop(_ source: UIImage, rng: inout SeededRandom) -> UIImage {
        let portrait = rng.next(in: 0...1) < 0.3
        let output = portrait ? CGSize(width: 1200, height: 1600) : CGSize(width: 1600, height: 1200)
        let scale = CGFloat(rng.next(in: 0.5...0.85))
        let w = source.size.width * scale, h = w * output.height / output.width
        let rectH = min(h, source.size.height), rectW = rectH * output.width / output.height
        let x = CGFloat(rng.next(in: 0...Double(max(0, source.size.width - rectW))))
        let y = CGFloat(rng.next(in: 0...Double(max(0, source.size.height - rectH))))
        let mirrored = rng.next(in: 0...1) < 0.4
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: output, format: format).image { ctx in
            if mirrored { ctx.cgContext.translateBy(x: output.width, y: 0); ctx.cgContext.scaleBy(x: -1, y: 1) }
            let factor = output.width / rectW
            source.draw(in: CGRect(x: -x * factor, y: -y * factor, width: source.size.width * factor, height: source.size.height * factor))
        }
    }

    static func fallbackImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
    }

    /// iPhone-sized screenshot with an EXIF "Screenshot" comment, as iOS writes it.
    static func screenshotPNG(_ lines: [String]) -> Data {
        // Looks like a real app screen: status bar, colored header with the title, the
        // details in a list and a button, so previews are recognizable at any crop.
        let size = CGSize(width: 1179, height: 2556)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let palette: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange, .systemPink, .systemGreen, .systemBlue, .systemPurple, .systemRed]
        let light = UITraitCollection(userInterfaceStyle: .light)
        let seed: Int = (lines.first ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let accent = palette[seed % palette.count].resolvedColor(with: light)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemGroupedBackground.resolvedColor(with: light).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            accent.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 760))
            let white: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 50, weight: .semibold), .foregroundColor: UIColor.white]
            ("9:41" as NSString).draw(at: CGPoint(x: 110, y: 52), withAttributes: white)
            let title = lines.first ?? ""
            (title as NSString).draw(in: CGRect(x: 72, y: 420, width: size.width - 144, height: 300),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 104, weight: .bold), .foregroundColor: UIColor.white])
            let details = Array(lines.dropFirst())
            let card = CGRect(x: 48, y: 820, width: size.width - 96, height: CGFloat(details.count) * 170 + 40)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 44).fill()
            for (i, line) in details.enumerated() {
                let y = card.minY + 20 + CGFloat(i) * 170
                (line as NSString).draw(in: CGRect(x: card.minX + 52, y: y + 50, width: card.width - 104, height: 90),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 62), .foregroundColor: UIColor.black])
                if i < details.count - 1 {
                    UIColor.separator.resolvedColor(with: light).setFill()
                    ctx.fill(CGRect(x: card.minX + 52, y: y + 169, width: card.width - 52, height: 2))
                }
            }
            let button = CGRect(x: 72, y: 2230, width: size.width - 144, height: 150)
            accent.setFill()
            UIBezierPath(roundedRect: button, cornerRadius: 75).fill()
            let label = "Details anzeigen" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 60, weight: .semibold), .foregroundColor: UIColor.white]
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: button.midX - labelSize.width / 2, y: button.midY - labelSize.height / 2), withAttributes: attributes)
        }
        let data = NSMutableData()
        guard let cg = image.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return image.pngData()!
        }
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A printed page photographed on a table.
    static func documentPhoto(_ lines: [String]) -> UIImage {
        let size = CGSize(width: 1500, height: 2000)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.55, green: 0.45, blue: 0.36, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let page = CGRect(x: 130, y: 150, width: 1240, height: 1700)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor(white: 0.97, alpha: 1).setFill()
            ctx.fill(page)
            ctx.cgContext.setShadow(offset: .zero, blur: 0)
            var y = page.minY + 120
            for (i, line) in lines.enumerated() {
                let font = i == 0 ? UIFont.systemFont(ofSize: 64, weight: .bold) : UIFont.systemFont(ofSize: 44)
                (line as NSString).draw(at: CGPoint(x: page.minX + 100, y: y), withAttributes: [.font: font, .foregroundColor: UIColor.black])
                y += i == 0 ? 160 : 90
            }
        }
    }
}

/// Small deterministic random generator, so the demo library is the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUnit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }
}

/// Card in the overview and in settings (simulator only).
struct DemoLibraryCard: View {
    @Environment(AppModel.self) private var model
    @State private var demo = DemoLibrary.shared

    var body: some View {
        Card {
            Label("Demo", systemImage: "wand.and.stars").font(.headline)
            if demo.isDone {
                Text("Beispiel-Mediathek ist angelegt.").font(.subheadline).foregroundStyle(.secondary)
            } else if demo.isSeeding {
                ProgressView(value: Double(demo.created), total: Double(max(demo.total, 1)))
                Text("Beispielfotos werden angelegt: \(demo.created) von \(demo.total)")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("Legt etwa \(demo.expectedCount) Beispielfotos mit Reisen, Screenshots und Dokumenten an. Nur im Simulator.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Beispiel-Mediathek anlegen") {
                    Task { await demo.seed(then: model) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.access.canRead)
            }
        }
    }
}
#endif
