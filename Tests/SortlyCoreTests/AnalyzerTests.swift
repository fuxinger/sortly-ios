import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Documents")
struct DocumentTests {
    let analyzer = DocumentAnalyzer()

    @Test func amazonInvoice() throws {
        let text = """
        Amazon EU S.à r.l.
        Rechnung
        Rechnungsnummer: DE4ABC12345
        Bestellnummer: 302-1234567-7654321
        Rechnungsdatum 14.03.2024
        Zwischensumme 41,99 €
        Gesamtbetrag 49,98 €
        USt-ID DE814584193
        """
        let info = try #require(analyzer.analyze(text: text))
        #expect(info.type == .invoice)
        #expect(info.merchant == "Amazon")
        #expect(info.invoiceNumber == "DE4ABC12345")
        #expect(info.orderNumber == "302-1234567-7654321")
        #expect(info.totalAmount == MoneyAmount(minorUnits: 4998, currency: "EUR"))
        #expect(info.documentDate == Fixture.date("2024-03-14 12:00"))
        #expect(info.sensitivity == .normal)
    }

    @Test func receiptWithThousandsSeparator() throws {
        let text = "MediaMarkt\nKassenbon\nBon-Nr. 4711\nSUMME EUR 1.299,00\nGirocard\n02.01.2025"
        let info = try #require(analyzer.analyze(text: text))
        #expect(info.type == .receipt)
        #expect(info.totalAmount?.minorUnits == 129_900)
        #expect(info.merchant == "Mediamarkt")
    }

    @Test func documentDateIsSeparateFromCaptureDate() throws {
        let info = try #require(analyzer.analyze(text: "Sehr geehrte Damen und Herren,\nBetreff: Kündigung\nMünchen, 3. Mai 1998\nMit freundlichen Grüßen"))
        #expect(info.type == .letter)
        #expect(info.subject == "Kündigung")
        #expect(info.documentDate == Fixture.date("1998-05-03 12:00"))
    }

    @Test func sensitiveDocumentsAreFlagged() throws {
        let bank = try #require(analyzer.analyze(text: "Kontoauszug Nr. 3\nRechnung\nIBAN DE89 3704 0044 0532 0130 00\nKontostand 1.234,56 EUR"))
        #expect(bank.sensitivity == .financial)
        let id = try #require(analyzer.analyze(text: "Vertrag zur Kopie\nPersonalausweis\nGeburtsdatum 01.01.1980\nUnterschrift"))
        #expect(id.sensitivity == .identity)
        let medical = try #require(analyzer.analyze(text: "Arztbrief\nDiagnose: ...\nKrankenkasse AOK\nRechnung für Patient"))
        #expect(medical.sensitivity == .medical)
    }

    @Test func ibanChecksumAvoidsFalsePositives() {
        #expect(DocumentAnalyzer.containsIBAN("DE89 3704 0044 0532 0130 00"))
        #expect(!DocumentAnalyzer.containsIBAN("DE12 3456 7890 1234 5678 90"))
    }

    @Test func noDocumentForRandomText() {
        #expect(analyzer.analyze(text: "Schöner Tag am See mit Freunden und Eis") == nil)
        #expect(analyzer.analyze(text: "kurz") == nil)
    }

    @Test func invalidDatesAreIgnored() {
        #expect(DocumentAnalyzer.firstDate(in: "Datum 31.02.2024") == nil)
    }
}

@Suite("Screenshots and messenger")
struct ScreenshotMessengerTests {
    @Test func flightBookingIsMultiLabel() {
        let r = ScreenshotClassifier().classify(text: "Lufthansa Boarding Pass\nFlight LH 1234\nGate B12 Seat 14A\nDeparture 10:35\nTerminal 2", barcodePayloads: ["M1MUSTER"])
        #expect(r.categories[.flight] != nil)
        #expect(r.categories[.ticket] != nil)
        #expect(r.categories[.qrCode] == .certain)
    }

    @Test func orderAndRecipe() {
        let classifier = ScreenshotClassifier()
        #expect(classifier.classify(text: "Ihre Bestellung\nBestellnummer 123-456\nVersandt").categories[.order] != nil)
        #expect(classifier.classify(text: "Zutaten: 200 g Mehl, 2 Esslöffel Zucker\nZubereitung: Backofen vorheizen").categories[.recipe] != nil)
        #expect(classifier.classify(text: "Hallo").categories.isEmpty)
    }

    @Test("Scenario H: file name pattern is only a hint")
    func scenarioH() {
        let asset = AssetSnapshot(id: "a", creationDate: Date(), originalFilename: "IMG-20240512-WA0003.jpg")
        let r = MessengerClassifier().assess(asset: asset, recognizedText: nil, albumTitles: [])
        #expect(r.app == .whatsApp)
        #expect(r.evidence == .plausibleHint)
        #expect(!r.allowsAutomaticAssignment)
    }

    @Test func missingGPSAloneIsNoEvidence() {
        let asset = AssetSnapshot(id: "a", creationDate: Date(), location: nil, pixelWidth: 1600, pixelHeight: 1200)
        #expect(MessengerClassifier().assess(asset: asset, recognizedText: nil, albumTitles: []).evidence == .unknownOrigin)
    }

    @Test func screenshotOfChatIsStrongEvidence() {
        let asset = AssetSnapshot(id: "a", subtypes: .screenshot, creationDate: Date())
        let r = MessengerClassifier().assess(asset: asset, recognizedText: "Anna\nzuletzt online heute um 10:12\nNachrichten sind Ende-zu-Ende-verschlüsselt", albumTitles: [])
        #expect(r.app == .whatsApp && r.evidence == .recognizedScreenshot)
        #expect(r.allowsAutomaticAssignment)
    }

    @Test func existingMessengerAlbum() {
        let asset = AssetSnapshot(id: "a", creationDate: Date())
        let r = MessengerClassifier().assess(asset: asset, recognizedText: nil, albumTitles: ["WhatsApp"])
        #expect(r.evidence == .existingAlbum)
    }
}

@Suite("Media types and taxonomy")
struct MediaTaxonomyTests {
    @Test func mediaTypeCategories() {
        let c = MediaTypeClassifier()
        let live = AssetSnapshot(id: "l", kind: .image, subtypes: [.livePhoto, .hdr], pixelWidth: 3024, pixelHeight: 4032)
        #expect(c.categories(for: live) == [.photos, .livePhotos, .hdr, .portraitOrientation])
        let shot = AssetSnapshot(id: "s", kind: .image, subtypes: .screenshot, pixelWidth: 1179, pixelHeight: 2556)
        #expect(c.categories(for: shot) == [.screenshots])
        let long = AssetSnapshot(id: "v", kind: .video, subtypes: .slowMotion, pixelWidth: 1920, pixelHeight: 1080, duration: 600)
        #expect(c.categories(for: long) == [.videos, .slowMotion, .longVideos, .landscapeOrientation])
    }

    @Test func taxonomyIsConsistent() {
        let ids = Set(ImageTaxonomy.all.map(\.id))
        #expect(ids.count == ImageTaxonomy.all.count)
        for category in ImageTaxonomy.all {
            if let parent = category.parentID { #expect(ids.contains(parent), "missing parent for \(category.id)") }
        }
    }

    @Test func classifierObservationsMapToHierarchy() {
        let r = ImageTaxonomy.categories(from: [("dog", 0.92), ("car", 0.6), ("mountain", 0.2), ("unknown_label", 0.99)])
        #expect(r["animal.dog"] == .likely)
        #expect(r["animal"] == .likely)
        #expect(r["vehicle.car"] == .plausible)
        #expect(r["nature.mountain"] == nil)
        #expect(r.count == 4)
    }
}

@Suite("People, pets and personal categories")
struct SimilarityTests {
    func vec(_ base: Int, noise: Float, dim: Int = 16, seed: Int) -> Embedding {
        var v = [Float](repeating: 0, count: dim)
        v[base % dim] = 1
        v[(base + 1) % dim] = 0.5
        for i in 0..<dim { v[i] += noise * Float(((seed &* 31 &+ i &* 17) % 11) - 5) / 50 }
        return Embedding(v)
    }

    @Test func groupsSimilarFacesAndRespectsSameAssetConstraint() {
        var obs: [Observation] = []
        for i in 0..<6 { obs.append(Observation(id: "p1-\(i)", assetID: AssetID("img\(i)"), embedding: vec(0, noise: 0.2, seed: i), quality: 0.9)) }
        for i in 0..<5 { obs.append(Observation(id: "p2-\(i)", assetID: AssetID("img\(i)"), embedding: vec(6, noise: 0.2, seed: i + 50), quality: 0.9)) }
        let groups = ObservationGrouper(distanceThreshold: 0.3, minGroupSize: 3).group(obs, kind: .person)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.confirmedName == nil && !$0.isConfirmed })
        // A group never contains two faces from the same photo.
        for g in groups { #expect(g.assetIDs.count == g.observationIDs.count) }
    }

    @Test func confirmedGroupsAreAnchorsAndKeepNames() {
        let obs = (0..<5).map { Observation(id: "o\($0)", assetID: AssetID("a\($0)"), embedding: vec(2, noise: 0.1, seed: $0), quality: 0.8) }
        var feedback = GroupingFeedback()
        let groupID = SortlyID("bello")
        feedback.confirmedGroups[groupID] = ["o0", "o1"]
        feedback.confirmedNames[groupID] = "Bello"
        feedback.rejected = ["o4"]
        let groups = ObservationGrouper(minGroupSize: 3).group(obs, kind: .dog, feedback: feedback)
        let bello = groups.first { $0.id == groupID }
        #expect(bello?.confirmedName == "Bello")
        #expect(bello?.observationIDs == ["o0", "o1", "o2", "o3"])
    }

    @Test func personalCategoryUsesOnlyConfirmedExamples() {
        let positives = [vec(3, noise: 0.05, seed: 1), vec(3, noise: 0.05, seed: 2)]
        let negatives = [vec(9, noise: 0.05, seed: 3)]
        let candidates: [(AssetID, Embedding)] = [("near", vec(3, noise: 0.1, seed: 7)), ("far", vec(12, noise: 0.1, seed: 8)), ("neg", vec(9, noise: 0.05, seed: 9))]
        let s = ExampleSimilaritySearch(maxDistance: 0.3).suggestions(positives: positives, negatives: negatives, candidates: candidates, excluding: [])
        #expect(s.map(\.assetID) == ["near"])
    }
}
