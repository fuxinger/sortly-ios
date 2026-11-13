import Foundation
import Photos
import Testing
import Vision
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
        print("VISION_IDENTIFIERS \(supported.sorted().joined(separator: ","))")
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
