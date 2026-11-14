import Foundation

/// Data minimization for recognized text before it is stored (search index and analysis
/// results). Analysis itself still sees the full text; only what is kept on disk shrinks:
/// - ID documents and medical papers: no text is stored at all (only the classification).
/// - IBANs and valid card numbers are masked in every other text.
public enum TextMinimizer {
    public static func sensitivity(of rawText: String) -> DocumentSensitivity {
        let text = rawText.lowercased()
        var level = DocumentSensitivity.normal
        for (candidate, words) in DocumentAnalyzer.sensitivityKeywords where words.contains(where: { text.contains($0) }) {
            level = max(level, candidate)
        }
        return level
    }

    /// The text that may be stored for `rawText`.
    public static func storable(_ rawText: String) -> String {
        switch sensitivity(of: rawText) {
        case .identity, .medical:
            return ""
        case .normal, .financial:
            return maskCardNumbers(maskIBANs(rawText))
        }
    }

    // MARK: Masks

    nonisolated(unsafe) private static let ibanPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#)
    nonisolated(unsafe) private static let digitRunPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#)

    static func maskIBANs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ibanPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "IBAN ••••")
    }

    static func maskCardNumbers(_ text: String) -> String {
        var result = text
        let matches = digitRunPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let digits = result[range].filter(\.isNumber).compactMap(\.wholeNumberValue)
            if luhnValid(digits) { result.replaceSubrange(range, with: "•••• ••••") }
        }
        return result
    }

    static func luhnValid(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
