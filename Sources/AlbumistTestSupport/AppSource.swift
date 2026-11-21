import Foundation
import Synchronization
import AlbumistCore

/// The App target's sources, for tests that check how the App uses a rule tested here: the App
/// does not build on Linux, so these tests read its code (`AnalysisStartCauseTests`,
/// `TripWorkshopTests`). Comments and string literals are told apart from code (`code`), so a
/// line left only in a comment or a string never passes for code, and braces in them never
/// end a body early (`AppSourceTests`). Regex literals (`/…/`, `#/…/#`) are not told apart:
/// none of the App code these tests read has one today (UI tests do, and are not read here).
public enum AppSource {
    /// The repository root.
    public static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A file under the repository root, e.g. "App/Albumist/Model/AppModel.swift".
    public static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file under `folder` (e.g. "App"), as paths from the root, sorted.
    public static func swiftFiles(under folder: String) -> [String] {
        let base = root.appendingPathComponent(folder)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return files.filter { $0.pathExtension == "swift" }
            .map { $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : $0.path }
            .sorted()
    }

    // MARK: Code, comments and strings

    private enum Kind { case code, comment, string }

    private enum Context {
        /// Code; `interpolation`: inside `\(…)` of a string, ended by the `)` at `parens` 0.
        case code(parens: Int, interpolation: Bool)
        case string(hashes: Int, multiline: Bool)
    }

    /// What each Unicode scalar of `scalars` is: code, a comment (`//`, nested `/* */`) or a
    /// string literal (`"…"`, `"""…"""`, raw `#"…"#`; the code in `\(…)` is code).
    private static func kinds(_ s: [Unicode.Scalar]) -> [Kind] {
        let n = s.count
        var kinds = [Kind](repeating: .code, count: n)
        var stack: [Context] = [.code(parens: 0, interpolation: false)]
        func at(_ i: Int) -> Unicode.Scalar? { i < n ? s[i] : nil }
        func hashes(from i: Int, count: Int) -> Bool { (0..<count).allSatisfy { at(i + $0) == "#" } }
        func mark(_ range: Range<Int>, _ kind: Kind) { for k in range where k < n { kinds[k] = kind } }
        var i = 0
        while i < n {
            switch stack[stack.count - 1] {
            case .code(let parens, let interpolation):
                if s[i] == "/", at(i + 1) == "/" {
                    var j = i
                    while j < n, s[j] != "\n" { j += 1 }
                    mark(i..<j, .comment)
                    i = j
                    continue
                }
                if s[i] == "/", at(i + 1) == "*" {
                    var depth = 0
                    var j = i
                    while j < n {
                        if s[j] == "/", at(j + 1) == "*" { depth += 1; j += 2; continue }
                        if s[j] == "*", at(j + 1) == "/" {
                            depth -= 1
                            j += 2
                            if depth == 0 { break }
                            continue
                        }
                        j += 1
                    }
                    mark(i..<j, .comment)
                    i = j
                    continue
                }
                var j = i
                while at(j) == "#" { j += 1 }
                if at(j) == "\"" {
                    let multiline = at(j + 1) == "\"" && at(j + 2) == "\""
                    let end = j + (multiline ? 3 : 1)
                    mark(i..<end, .string)
                    stack.append(.string(hashes: j - i, multiline: multiline))
                    i = end
                    continue
                }
                if interpolation {
                    if s[i] == "(" {
                        stack[stack.count - 1] = .code(parens: parens + 1, interpolation: true)
                    } else if s[i] == ")" {
                        if parens == 0 {
                            stack.removeLast()
                            mark(i..<(i + 1), .string)
                            i += 1
                            continue
                        }
                        stack[stack.count - 1] = .code(parens: parens - 1, interpolation: true)
                    }
                }
                i += 1
            case .string(let count, let multiline):
                if s[i] == "\\", hashes(from: i + 1, count: count) {
                    let next = i + 1 + count
                    if at(next) == "(" {
                        mark(i..<(next + 1), .string)
                        stack.append(.code(parens: 0, interpolation: true))
                        i = next + 1
                    } else {
                        mark(i..<(next + 1), .string)
                        i = next + 1
                    }
                    continue
                }
                if multiline, s[i] == "\"", at(i + 1) == "\"", at(i + 2) == "\"", hashes(from: i + 3, count: count) {
                    mark(i..<(i + 3 + count), .string)
                    stack.removeLast()
                    i += 3 + count
                    continue
                }
                if !multiline, s[i] == "\"", hashes(from: i + 1, count: count) {
                    mark(i..<(i + 1 + count), .string)
                    stack.removeLast()
                    i += 1 + count
                    continue
                }
                mark(i..<(i + 1), .string)
                i += 1
            }
        }
        return kinds
    }

    /// `source` with its comments blanked, and its string literals too unless `keepStrings`:
    /// each of their characters becomes a space, line breaks stay, so every position and line
    /// stays where it was.
    public static func code(_ source: String, keepStrings: Bool = false) -> String {
        let key = CacheKey(source: source, keepStrings: keepStrings)
        if let known = cache.withLock({ $0[key] }) { return known }
        let made = blanked(source, keepStrings: keepStrings)
        cache.withLock { $0[key] = made }
        return made
    }

    /// The tests ask for the same files many times (each body, each call): each is read once.
    private struct CacheKey: Hashable {
        var source: String
        var keepStrings: Bool
    }

    private static let cache = Locked<[CacheKey: String]>([:])

    private static func blanked(_ source: String, keepStrings: Bool) -> String {
        let scalars = Array(source.unicodeScalars)
        let kinds = kinds(scalars)
        var out = String.UnicodeScalarView()
        for (scalar, kind) in zip(scalars, kinds) {
            let blank = kind == .comment || (kind == .string && !keepStrings)
            out.append(blank && scalar != "\n" ? " " : scalar)
        }
        return String(out)
    }

    // MARK: Declarations and calls

    /// Where the body of the first declaration that starts with `declaration` (e.g. "func
    /// changeTrips(") is, in Unicode scalars of `source`: from the first "{" after it outside
    /// its parameter list (a default argument `= { $0 }` is not the body) to the matching "}".
    /// Found in code only (not in a comment or a string), and only inside `within` when given.
    public static func bodyRange(of declaration: String, in source: String, within: Range<Int>? = nil) -> Range<Int>? {
        bodyRange(of: declaration, masked: Array(code(source).unicodeScalars), within: within)
    }

    /// The first position of `wanted` in `scalars` within `range`.
    private static func find(_ wanted: [Unicode.Scalar], in scalars: [Unicode.Scalar], within range: Range<Int>) -> Int? {
        guard let first = wanted.first, range.count >= wanted.count else { return nil }
        var i = range.lowerBound
        let last = range.upperBound - wanted.count
        while i <= last {
            if scalars[i] == first {
                var k = 1
                while k < wanted.count, scalars[i + k] == wanted[k] { k += 1 }
                if k == wanted.count { return i }
            }
            i += 1
        }
        return nil
    }

    private static func bodyRange(of declaration: String, masked: [Unicode.Scalar], within: Range<Int>?) -> Range<Int>? {
        let wanted = Array(declaration.unicodeScalars)
        let range = within ?? 0..<masked.count
        guard let start = find(wanted, in: masked, within: range) else { return nil }
        // Parentheses the declaration opened ("func changeTrips(") and those after it.
        var parens = wanted.filter { $0 == "(" }.count - wanted.filter { $0 == ")" }.count
        var open: Int?
        for index in (start + wanted.count)..<range.upperBound {
            let scalar = masked[index]
            if scalar == "(" { parens += 1 }
            if scalar == ")" { parens -= 1 }
            if scalar == "{", parens <= 0 {
                open = index
                break
            }
        }
        guard let open else { return nil }
        var depth = 0
        for index in open..<range.upperBound {
            if masked[index] == "{" { depth += 1 }
            if masked[index] == "}" {
                depth -= 1
                if depth == 0 { return open..<(index + 1) }
            }
        }
        return nil
    }

    /// The body of a declaration (`bodyRange`), as written: with its comments and strings.
    /// `path`: declarations inside each other, outermost first (a struct, then its `body`).
    public static func body(of path: [String], in source: String) -> String? {
        guard let range = bodyRange(of: path, in: source) else { return nil }
        let scalars = Array(source.unicodeScalars)
        return String(String.UnicodeScalarView(scalars[range]))
    }

    /// The body of the first declaration that starts with `declaration`, as written.
    public static func body(of declaration: String, in source: String) -> String? {
        body(of: [declaration], in: source)
    }

    /// The scalar range of a declaration path's body (see `body(of:in:)`).
    public static func bodyRange(of path: [String], in source: String) -> Range<Int>? {
        let masked = Array(code(source).unicodeScalars)
        var range: Range<Int>?
        for declaration in path {
            guard let inner = bodyRange(of: declaration, masked: masked, within: range) else { return nil }
            range = inner
        }
        return range
    }

    /// Every call of `function` (e.g. "startAnalysis(") in the code of `source`, not in comments
    /// or strings and not its own declaration (`func startAnalysis(`): where it is (in Unicode
    /// scalars) and its arguments ("" for `startAnalysis()`, "cause: .tap" for
    /// `startAnalysis(cause: .tap)`).
    public static func callSites(of function: String, in source: String) -> [(offset: Int, arguments: String)] {
        let masked = Array(code(source).unicodeScalars)
        let wanted = Array(function.unicodeScalars)
        let declaration = Array("func ".unicodeScalars)
        var found: [(offset: Int, arguments: String)] = []
        var i = 0
        while let at = find(wanted, in: masked, within: i..<masked.count) {
            i = at
            // Not a longer name that ends the same way ("restartAnalysis(").
            if i > 0, let before = Character(masked[i - 1]).unicodeScalars.first,
               CharacterSet.alphanumerics.contains(before) || before == "_" {
                i += 1
                continue
            }
            var depth = 1
            var j = i + wanted.count
            while j < masked.count, depth > 0 {
                if masked[j] == "(" { depth += 1 }
                if masked[j] == ")" { depth -= 1 }
                if depth > 0 { j += 1 }
            }
            let isDeclaration = i >= declaration.count && Array(masked[(i - declaration.count)..<i]) == declaration
            if !isDeclaration {
                let arguments = String(String.UnicodeScalarView(masked[(i + wanted.count)..<min(j, masked.count)]))
                found.append((i, arguments.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            i = j
        }
        return found
    }

    /// The argument lists of every call of `function` in the code of `text` (see `callSites`).
    public static func calls(of function: String, in text: String) -> [String] {
        callSites(of: function, in: text).map(\.arguments)
    }
}
