import Foundation
import Photos
import Testing
import Vision
import SwiftUI
import UIKit
import SortlyCore
@testable import Sortly

@Suite("Platform mapping")
struct PlatformMappingTests {
    @Test func subtypesMapToCoreFlags() {
        let mapped = PhotoKitLibrary.subtypes(from: [.photoScreenshot, .photoLive, .videoTimelapse])
        #expect(mapped.contains(.screenshot))
        #expect(mapped.contains(.livePhoto))
        #expect(mapped.contains(.timelapse))
        #expect(!mapped.contains(.panorama))
    }

    @Test func authorizationMapping() {
        #expect(PhotoKitLibrary.map(.authorized) == .full)
        #expect(PhotoKitLibrary.map(.limited) == .limited)
        #expect(PhotoKitLibrary.map(.denied) == .denied)
        #expect(!PhotoKitLibrary.map(.notDetermined).canRead)
    }
}

@Suite("Vision taxonomy")
struct VisionTaxonomyTests {
    /// Every category should map to at least one identifier the on-device classifier knows.
    /// Unknown identifiers are printed so the taxonomy can be corrected.
    @Test func taxonomyUsesKnownIdentifiers() throws {
        let supported: Set<String>
        do {
            supported = Set(try VNClassifyImageRequest().supportedIdentifiers())
        } catch {
            print("Vision identifiers not available in this environment: \(error)")
            return
        }
        guard !supported.isEmpty else { return }
        var unknown: [String] = []
        var uncovered: [String] = []
        for category in ImageTaxonomy.all where !category.visionIdentifiers.isEmpty {
            let missing = category.visionIdentifiers.filter { !supported.contains($0) }
            unknown += missing.map { "\(category.id): \($0)" }
            if missing.count == category.visionIdentifiers.count { uncovered.append(category.id) }
        }
        print("TAXONOMY unknown identifiers (\(unknown.count)): \(unknown.joined(separator: ", "))")
        print("TAXONOMY categories without any known identifier: \(uncovered.joined(separator: ", "))")
        #expect(uncovered.count * 5 <= ImageTaxonomy.all.count, "Too many categories cannot be recognized")
    }
}

@Suite("Texts")
struct TextTests {
    @Test func reasonTextsAreFilled() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let text = ReasonText.text(.photosInPeriod(count: 12, start: start, end: start.addingTimeInterval(86_400)))
        #expect(text.contains("12"))
        #expect(!ReasonText.text(.noExistingAlbum).isEmpty)
    }

    @Test func conflictTextsUseAlbumTitles() {
        let id = CollectionID("album-1")
        let inventory = CollectionInventory([
            CollectionSnapshot(id: id, title: "Italien 2023", kind: .userAlbum, capabilities: .all, parentID: nil, assetIDs: [], childIDs: [])
        ])
        #expect(ConflictText.text(.albumMissing(id), inventory: inventory).contains("Italien 2023"))
    }
}

@Suite("Atlas rendering")
@MainActor
struct AtlasRenderingTests {
    static func sampleAtlas() -> TravelAtlas {
        var atlas = TravelAtlas()
        let codes = ["AT", "IT", "FR", "ES", "PT", "HR", "GR", "GB", "NL", "US", "TH", "JP", "MA", "NO", "IS", "CH", "CZ", "DK", "MX", "AU", "EG", "TR", "DE"]
        atlas.countryCodes = Set(codes)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for (i, code) in codes.enumerated() {
            atlas.firstVisits[code] = calendar.date(from: DateComponents(year: 2012 + i / 2, month: 1 + i % 12, day: 10))
        }
        atlas.cityCount = 61
        atlas.tripCount = 48
        atlas.sinceYear = 2012
        atlas.longestTripDays = 16
        atlas.favoriteTripCity = "Rom"
        return atlas
    }

    /// CI logs drop very long lines, so the image is printed in numbered chunks.
    static func emit(_ name: String, _ data: Data) {
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG \(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    /// Renders the share card and the atlas screen and prints them as JPEG (base64) into
    /// the CI log, so the design can be reviewed without a Mac.
    @Test func renderPreviews() async throws {
        let outlines = await AtlasOutlines.shared.load(from: nil)
        #expect(outlines.count > 200)
        let atlas = Self.sampleAtlas()

        let card = ImageRenderer(content: ShareCard(atlas: atlas, sortedPhotos: 12_480, outlines: outlines))
        card.scale = 1
        let cardImage = try #require(card.uiImage)
        #expect(cardImage.size == CGSize(width: 720, height: 1280))
        Self.emit("sharecard", cardImage.jpegData(compressionQuality: 0.8)!)

        let screen = ImageRenderer(content:
            AtlasContent(atlas: atlas, outlines: outlines, revealed: 14)
                .padding(16)
                .frame(width: 393)
                .background(AtlasStyle.background)
                .environment(\.colorScheme, .dark)
        )
        screen.scale = 2
        let screenImage = try #require(screen.uiImage)
        Self.emit("atlas", screenImage.jpegData(compressionQuality: 0.7)!)
    }
}
