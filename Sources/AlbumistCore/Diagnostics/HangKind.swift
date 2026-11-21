/// What a hang of the app's main thread (250 ms or more) was about, read from the main thread's
/// stack 200 ms into it (UI runs only, `MainThreadWatch` in the app; owner's decision 16.11.2026:
/// "Hänger-Wächter 250 ms"). `ui_tests.py` (`hang_report`) counts the hangs by kind, and only
/// `app` can turn a run red (`.github/hang-gate.json`): the others are not Albumist's to fix.
///
/// A frame is a line as `MainThreadWatch.symbol` writes it: the image first ("Albumist.debug.dylib
/// AppModel.tick(run:) + 120", "SwiftUICore … + 44", "?? 0x1234"). Pure, so the rule is tested
/// on Linux (`HangKindTests`).
public enum HangKind: String, Sendable, CaseIterable {
    /// Albumist's own code is on the stack: a view body, a model method, a closure of ours.
    case app
    /// XCTest reads the screen (accessibility snapshot, element query, audit): it runs on the
    /// app's main thread and only exists in UI tests. Wins over `app`, because a view's body that
    /// XCTest's snapshot asked for has our frames too.
    case test
    /// Before the app was foreground-active for the first time: the start, which Apple measures
    /// as launch time, not as hangs.
    case start
    /// The app was in the background or behind a system alert in the hang: iOS may hold back a
    /// main thread then.
    case inactive
    /// The whole process got no time in the hang (the watch's own sleep overran: a busy Mac),
    /// so the main thread's stack says nothing about who blocked it.
    case starved
    /// Only iOS frames (drawing, layout, a system call).
    case system
    /// No stack: the hang ended before the watch could take one.
    case unknown

    /// `inactive` and `start` win over the stack by design: work of ours in `willResignActive`,
    /// behind a system alert or at launch is not counted (Apple measures launch time on its own,
    /// and iOS may hold back a main thread in the background).
    public init(frames: [String], inactive: Bool, beforeFirstActive: Bool, starved: Bool = false) {
        let own = frames.firstIndex(where: Self.isAppFrame)
        // XCTest only when it is a caller of our code (or there is none of ours): our code that
        // calls into the accessibility runtime itself (posts a notification) stays ours.
        let test = frames.indices.contains { Self.isTestFrame(frames[$0]) && (own == nil || $0 > own!) }
        if beforeFirstActive {
            self = .start
        } else if inactive {
            self = .inactive
        } else if starved {
            self = .starved
        } else if frames.isEmpty {
            self = .unknown
        } else if test {
            self = .test
        } else if own != nil {
            self = .app
        } else {
            self = .system
        }
    }

    /// The image a frame line names ("Albumist.debug.dylib", "XCTAutomationSupport").
    static func image(_ frame: String) -> Substring {
        frame.split(separator: " ", maxSplits: 1).first ?? ""
    }

    /// Albumist's executable or, in a debug build, its debug dylib; not the entry point at the
    /// bottom of every main-thread stack (`main`, `AlbumistApp.$main()`), and not the watch itself.
    static func isAppFrame(_ frame: String) -> Bool {
        let parts = frame.split(separator: " ", maxSplits: 1)
        guard let image = parts.first, image == "Albumist" || image == "Albumist.debug.dylib" else { return false }
        let symbol = parts.count > 1 ? withoutOffset(String(parts[1])) : ""
        let entry = symbol == "main" || symbol.contains("$main") || symbol.contains("entry_point")
            || symbol.contains("MainThreadWatch")
        return !entry
    }

    /// XCTest and the accessibility runtime it reads the screen with.
    static func isTestFrame(_ frame: String) -> Bool {
        let image = image(frame)
        return image.hasPrefix("XCT") || image.hasPrefix("libXCT") || image.contains("Accessibility")
            || image.hasPrefix("libAX") || image.hasPrefix("AXRuntime") || image.hasPrefix("AXCore")
    }

    /// The frames a `UI_MAIN_HANG` line shows (one line, so it stays readable in the log): Albumist's
    /// own frames (at most 6, innermost first) with the frame just below the first of them (what
    /// our code was waiting in), else the innermost 4 frames. Offsets are dropped, so the same
    /// place gives the same text in every run (`hang_report` groups by it).
    public static func shortStack(_ frames: [String]) -> String {
        let clean = frames.map(withoutOffset)
        guard let first = frames.firstIndex(where: isAppFrame) else {
            return clean.prefix(4).joined(separator: " | ")
        }
        let own = frames.indices.filter { isAppFrame(frames[$0]) }.prefix(6).map { clean[$0] }
        let below = first > 0 ? [clean[first - 1]] : []
        return (below + own).joined(separator: " | ")
    }

    /// "Albumist.debug.dylib AppModel.tick(run:) + 120" → "Albumist.debug.dylib AppModel.tick(run:)".
    static func withoutOffset(_ frame: String) -> String {
        guard let range = frame.range(of: " + ", options: .backwards),
              frame[range.upperBound...].allSatisfy(\.isNumber) else { return frame }
        return String(frame[..<range.lowerBound])
    }
}
