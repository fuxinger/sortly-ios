import Testing
@testable import SortlyCore

@Suite("Text minimization before storage")
struct TextMinimizerTests {
    @Test func identityAndMedicalTextIsNotStored() {
        #expect(TextMinimizer.storable("BUNDESREPUBLIK DEUTSCHLAND PERSONALAUSWEIS Name Mustermann Geburtsdatum 12.08.1964") == "")
        #expect(TextMinimizer.storable("Arztbrief Diagnose: Bronchitis, Patient Max Muster") == "")
    }

    @Test func ibanIsMasked() {
        let text = "Kontoauszug IBAN: DE89 3704 0044 0532 0130 00 Saldo 1.234,00 EUR"
        let stored = TextMinimizer.storable(text)
        #expect(!stored.contains("3704"))
        #expect(stored.contains("Kontoauszug"))
        #expect(stored.contains("1.234,00"))
        #expect(!TextMinimizer.storable("IBAN DE89370400440532013000").contains("370400"))
    }

    @Test func onlyValidCardNumbersAreMasked() {
        let card = TextMinimizer.storable("Visa 4111 1111 1111 1111 gültig bis 12/29")
        #expect(!card.contains("4111 1111"))
        #expect(card.contains("gültig bis 12/29"))
        // Order numbers that fail the Luhn check stay searchable.
        let order = "Bestellnummer 3021 4567 8901 2345"
        #expect(TextMinimizer.storable(order) == order)
        #expect(TextMinimizer.storable("Rechnung Nr. 2024-0815 Summe 49,90 EUR") == "Rechnung Nr. 2024-0815 Summe 49,90 EUR")
    }
}
