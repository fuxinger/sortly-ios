import Foundation

public enum DocumentType: String, Sendable, Codable, CaseIterable {
    case invoice, receipt, contract, warranty, order, ticket, booking, letter, manual, offer, craftsman, vehicle, other
}

/// How carefully a document must be handled (prompt §4.8).
public enum DocumentSensitivity: String, Sendable, Codable, Comparable {
    case normal
    /// Bank statements, IBAN, salary slips, contracts.
    case financial
    /// Passports, ID cards, driving licences.
    case identity
    /// Diagnoses, prescriptions, health insurance.
    case medical

    private var rank: Int { [.normal: 0, .financial: 1, .identity: 2, .medical: 2][self]! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct MoneyAmount: Hashable, Sendable, Codable {
    /// Amount in minor units (cents) to avoid floating point errors.
    public var minorUnits: Int
    public var currency: String

    public var decimalString: String {
        String(format: "%d.%02d", minorUnits / 100, abs(minorUnits % 100))
    }
}

/// Structured information extracted from recognized document text.
/// Every field is optional – nothing is guessed when the text does not contain it.
public struct DocumentInfo: Hashable, Sendable, Codable {
    public var type: DocumentType
    public var typeReliability: Reliability
    /// Date printed on the document. Kept apart from the photo's capture date.
    public var documentDate: Date?
    public var merchant: String?
    public var orderNumber: String?
    public var invoiceNumber: String?
    public var totalAmount: MoneyAmount?
    public var subject: String?
    public var keywords: [String]
    public var sensitivity: DocumentSensitivity
}

/// Rule-based document understanding on top of on-device OCR output.
/// Deterministic and testable; bilingual (German / English) keyword sets.
public struct DocumentAnalyzer: Sendable {
    public init() {}

    static let typeKeywords: [(DocumentType, [String])] = [
        (.invoice, ["rechnung", "rechnungsnummer", "rechnungsnr", "invoice", "invoice no", "ust-id", "umsatzsteuer", "zahlbar bis", "amount due"]),
        (.receipt, ["kassenbon", "bon-nr", "beleg-nr", "summe eur", "bar ", "ec-karte", "girocard", "receipt", "change due", "kassierer", "mwst"]),
        (.contract, ["vertrag", "vertragsnummer", "vertragspartner", "laufzeit", "kündigungsfrist", "contract", "agreement", "unterschrift"]),
        (.warranty, ["garantie", "gewährleistung", "garantieschein", "warranty", "guarantee"]),
        (.order, ["bestellung", "bestellnummer", "bestellbestätigung", "order number", "order confirmation", "your order", "lieferung", "versandbestätigung"]),
        (.ticket, ["ticket", "fahrkarte", "eintrittskarte", "boarding pass", "bordkarte", "gate", "sitzplatz", "seat", "zug", "gleis", "einlass"]),
        (.booking, ["buchungsbestätigung", "buchungsnummer", "reservierung", "booking", "reservation", "check-in", "check-out", "hotel", "unterkunft", "flugnummer", "flight"]),
        (.letter, ["sehr geehrte", "mit freundlichen grüßen", "dear ", "sincerely", "betreff:", "ihr zeichen"]),
        (.manual, ["bedienungsanleitung", "gebrauchsanweisung", "sicherheitshinweise", "user manual", "instructions", "installation"]),
        (.offer, ["angebot", "angebotsnummer", "kostenvoranschlag", "quotation", "quote", "gültig bis"]),
        (.craftsman, ["handwerker", "montage", "arbeitszeit", "material", "meisterbetrieb", "stundenlohn", "anfahrt"]),
        (.vehicle, ["fahrzeugschein", "zulassungsbescheinigung", "fahrgestellnummer", "tüv", "hauptuntersuchung", "kfz", "kennzeichen", "inspektion", "ölwechsel"]),
    ]

    static let sensitivityKeywords: [(DocumentSensitivity, [String])] = [
        (.identity, ["personalausweis", "reisepass", "passport", "identity card", "führerschein", "driving licence", "aufenthaltstitel", "nationalität", "date of birth", "geburtsdatum"]),
        (.medical, ["diagnose", "befund", "rezept", "arztbrief", "krankenkasse", "versichertennummer", "arbeitsunfähigkeit", "patient", "medikament", "prescription"]),
        (.financial, ["kontoauszug", "iban", "bic", "lohnabrechnung", "gehaltsabrechnung", "kreditkarte", "steuerbescheid", "kontostand", "bank statement", "salary"]),
    ]

    static let knownMerchants = [
        "amazon", "ikea", "mediamarkt", "media markt", "saturn", "zalando", "otto", "lidl", "aldi", "rewe", "edeka", "dm", "rossmann",
        "obi", "bauhaus", "hornbach", "apple", "deutsche bahn", "db fernverkehr", "lufthansa", "ryanair", "easyjet", "booking.com",
        "airbnb", "ebay", "paypal", "decathlon", "h&m", "tchibo", "kaufland", "netto", "penny", "telekom", "vodafone", "o2",
    ]

    public func analyze(text rawText: String) -> DocumentInfo? {
        let text = rawText.lowercased()
        guard text.count >= 20 else { return nil }

        var scores: [DocumentType: Int] = [:]
        for (type, words) in Self.typeKeywords {
            let hits = words.filter { text.contains($0) }.count
            if hits > 0 { scores[type] = hits }
        }
        let amount = Self.totalAmount(in: rawText)
        if amount != nil { scores[.invoice, default: 0] += scores[.invoice] != nil ? 1 : 0; scores[.receipt, default: 0] += scores[.receipt] != nil ? 1 : 0 }

        guard let best = scores.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }) else {
            // Text but no document markers: only report if it looks like a letter-sized text block.
            return nil
        }
        let reliability: Reliability = best.value >= 3 ? .likely : (best.value == 2 ? .plausible : .uncertain)

        var sensitivity = DocumentSensitivity.normal
        for (level, words) in Self.sensitivityKeywords where words.contains(where: { text.contains($0) }) {
            sensitivity = max(sensitivity, level)
        }
        if Self.containsIBAN(rawText) { sensitivity = max(sensitivity, .financial) }

        return DocumentInfo(
            type: best.key,
            typeReliability: reliability,
            documentDate: Self.firstDate(in: rawText),
            merchant: Self.merchant(in: text),
            orderNumber: Self.labeledNumber(in: rawText, labels: ["bestellnummer", "bestell-nr", "bestellnr", "order number", "order no", "order #", "auftragsnummer"]),
            invoiceNumber: Self.labeledNumber(in: rawText, labels: ["rechnungsnummer", "rechnungs-nr", "rechnungsnr", "invoice number", "invoice no", "invoice #"]),
            totalAmount: amount,
            subject: Self.subject(in: rawText),
            keywords: Self.typeKeywords.flatMap(\.1).filter { text.contains($0) }.prefix(8).map { $0 },
            sensitivity: sensitivity
        )
    }

    // MARK: - Field extraction

    static func labeledNumber(in text: String, labels: [String]) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            for label in labels {
                guard let range = lower.range(of: label) else { continue }
                let rest = String(line[range.upperBound...])
                if let token = firstIdentifier(in: rest) { return token }
                if i + 1 < lines.count, let token = firstIdentifier(in: lines[i + 1]) { return token }
            }
        }
        return nil
    }

    /// First token with at least 4 characters that contains a digit, e.g. "302-1234567-1234567".
    static func firstIdentifier(in text: String) -> String? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":;,"))
        for raw in text.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".#()"))
            if token.count >= 4, token.rangeOfCharacter(from: .decimalDigits) != nil,
               token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }) {
                return token
            }
        }
        return nil
    }

    /// Amount following "Summe/Gesamt/Total/Betrag", else the largest amount with a currency.
    static func totalAmount(in text: String) -> MoneyAmount? {
        let pattern = #"(?:(EUR|€|USD|\$|CHF|GBP|£)\s?)?(\d{1,3}(?:[.\s']\d{3})*(?:[.,]\d{2})|\d+[.,]\d{2})\s?(EUR|€|USD|\$|CHF|GBP|£)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var labeled: [MoneyAmount] = []
        var all: [MoneyAmount] = []
        for line in lines {
            let ns = line as NSString
            let lower = line.lowercased()
            let isTotal = ["summe", "gesamt", "total", "betrag", "zu zahlen", "amount due", "endbetrag"].contains { lower.contains($0) }
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let currencyRaw = [1, 3].compactMap { idx -> String? in
                    let r = m.range(at: idx)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }.first
                guard let currencyRaw, let currency = normalizeCurrency(currencyRaw) else { continue }
                let numberRange = m.range(at: 2)
                guard numberRange.location != NSNotFound, let minor = parseMinorUnits(ns.substring(with: numberRange)) else { continue }
                let amount = MoneyAmount(minorUnits: minor, currency: currency)
                all.append(amount)
                if isTotal { labeled.append(amount) }
            }
        }
        return labeled.last ?? all.max { $0.minorUnits < $1.minorUnits }
    }

    static func normalizeCurrency(_ raw: String) -> String? {
        switch raw {
        case "EUR", "€": "EUR"
        case "USD", "$": "USD"
        case "CHF": "CHF"
        case "GBP", "£": "GBP"
        default: nil
        }
    }

    /// Parses "1.234,56", "1,234.56", "12,99", "12.99" into minor units.
    static func parseMinorUnits(_ s: String) -> Int? {
        let cleaned = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        guard cleaned.count >= 4 else { return nil }
        let decimalSeparator = cleaned[cleaned.index(cleaned.endIndex, offsetBy: -3)]
        guard decimalSeparator == "," || decimalSeparator == "." else { return nil }
        let integerPart = cleaned[..<cleaned.index(cleaned.endIndex, offsetBy: -3)].filter(\.isNumber)
        let fraction = cleaned.suffix(2)
        guard let i = Int(integerPart.isEmpty ? "0" : String(integerPart)), let f = Int(fraction) else { return nil }
        return i * 100 + f
    }

    static func firstDate(in text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let numeric = #"\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})\b"#
        let iso = #"\b(\d{4})-(\d{2})-(\d{2})\b"#
        let months = ["januar": 1, "january": 1, "februar": 2, "february": 2, "märz": 3, "march": 3, "april": 4, "mai": 5, "may": 5,
                      "juni": 6, "june": 6, "juli": 7, "july": 7, "august": 8, "september": 9, "oktober": 10, "october": 10,
                      "november": 11, "dezember": 12, "december": 12]
        let named = #"\b(\d{1,2})\.?\s+([A-Za-zäÄ]+)\s+(\d{4})\b"#

        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            let year = y < 100 ? 2000 + y : y
            guard (1...12).contains(m), (1...31).contains(d), (1900...2100).contains(year) else { return nil }
            let comps = DateComponents(year: year, month: m, day: d, hour: 12)
            guard let date = calendar.date(from: comps), calendar.component(.day, from: date) == d else { return nil }
            return date
        }

        var candidates: [(Int, Date)] = []
        let ns = text as NSString
        if let r = try? NSRegularExpression(pattern: numeric) {
            for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))), let y = Int(ns.substring(with: m.range(at: 3))), let date = make(y, mo, d) {
                    candidates.append((m.range.location, date))
                }
            }
        }
        if let r = try? NSRegularExpression(pattern: iso) {
            for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let y = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))), let d = Int(ns.substring(with: m.range(at: 3))), let date = make(y, mo, d) {
                    candidates.append((m.range.location, date))
                }
            }
        }
        if let r = try? NSRegularExpression(pattern: named) {
            for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = Int(ns.substring(with: m.range(at: 1))), let mo = months[ns.substring(with: m.range(at: 2)).lowercased()],
                   let y = Int(ns.substring(with: m.range(at: 3))), let date = make(y, mo, d) {
                    candidates.append((m.range.location, date))
                }
            }
        }
        return candidates.min { $0.0 < $1.0 }?.1
    }

    static func merchant(in lowercasedText: String) -> String? {
        let hits = knownMerchants.compactMap { name -> (String, String.Index)? in
            guard let r = lowercasedText.range(of: name) else { return nil }
            // Require a word boundary to avoid "dm" in "admin".
            let before = r.lowerBound == lowercasedText.startIndex ? " " : lowercasedText[lowercasedText.index(before: r.lowerBound)]
            let after = r.upperBound == lowercasedText.endIndex ? " " : lowercasedText[r.upperBound]
            guard !before.isLetter, !after.isLetter else { return nil }
            return (name, r.lowerBound)
        }
        guard let first = hits.min(by: { $0.1 < $1.1 }) else { return nil }
        return first.0.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            .replacingOccurrences(of: "Db ", with: "DB ").replacingOccurrences(of: "H&m", with: "H&M")
    }

    static func subject(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            for label in ["betreff:", "betreff", "subject:", "re:"] where lower.hasPrefix(label) {
                let value = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
                if !value.isEmpty { return String(value.prefix(120)) }
            }
        }
        return nil
    }

    /// IBAN with checksum validation (mod 97) to avoid false positives.
    static func containsIBAN(_ text: String) -> Bool {
        let compact = text.uppercased().replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"[A-Z]{2}\d{2}[A-Z0-9]{11,30}"#) else { return false }
        let ns = compact as NSString
        for m in regex.matches(in: compact, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: m.range)
            for length in stride(from: min(candidate.count, 34), through: 15, by: -1) {
                if isValidIBAN(String(candidate.prefix(length))) { return true }
            }
        }
        return false
    }

    static func isValidIBAN(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue { value = d }
            else if let a = ch.asciiValue, (65...90).contains(a) { value = Int(a) - 55 }
            else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }
}
