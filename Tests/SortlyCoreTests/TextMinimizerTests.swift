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

    /// Audit 6.4: lower-case and differently spaced IBANs (OCR, chat screenshots) are masked too,
    /// but only with a valid checksum, so similar-looking words stay searchable.
    @Test func lowerCaseAndSpacedIBANsAreMasked() {
        #expect(!TextMinimizer.storable("iban de89 3704 0044 0532 0130 00").contains("3704"))
        #expect(!TextMinimizer.storable("Konto: De89370400440532013000 danke").contains("370400"))
        #expect(!TextMinimizer.storable("IBAN DE89\t3704\t0044\t0532\t0130\t00").contains("0532"))
        #expect(!TextMinimizer.storable("IBAN DE89\u{00A0}3704\u{00A0}0044\u{00A0}0532\u{00A0}0130\u{00A0}00").contains("0532"))
        let lookalike = "ab12 cdef ghij klmn"
        #expect(TextMinimizer.storable(lookalike) == lookalike)
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
