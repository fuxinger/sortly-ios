import Foundation

/// When iOS moved the app between active, inactive and background, as the app saw it. Plain
/// Foundation, so SwiftPM also builds it on Linux (target `AlbumistUITestLogic`, tests in
/// `UITestLifecycleTests`).
///
/// Why: in every full UI run since 18.11. the first Home press of a launch left the app in the
/// foreground (state 4 after 8 s) and the second worked within 1.4 s (docs/IMPROVEMENTS.md,
/// "Home-Druck kommt nicht an"); a system alert in front was ruled out on 21.11. Whether the
/// first press reached the app at all (it resigned active and came back: a gesture that iOS
/// cancelled) or never arrived (nothing until the second press) tells the app from the
/// simulator. The app (`MainThreadWatch`, with `-AlbumistUITestWatchMainLog`) writes each change
/// as "^ <seconds since 1970> <event>" into the runner's file; `UITestStalls.report` prints it
/// next to the test's `UI_FACT clock … Home press` line.
enum UITestLifecycle {
    /// The events the app writes: UIApplication's willResignActive, didEnterBackground,
    /// willEnterForeground and didBecomeActive.
    static let events: Set<String> = ["resign-active", "background", "foreground", "active"]

    /// The line the app writes for `event` at `seconds` since 1970.
    static func line(_ event: String, at seconds: Double) -> String {
        "^ " + String(format: "%.1f", seconds) + " " + event + "\n"
    }

    /// `UI_FACT app lifecycle background at 03:43:07.4 UTC` for such a line, nil for any other.
    static func fact(_ line: Substring) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "^", let seconds = Double(parts[1]), events.contains(String(parts[2])) else {
            return nil
        }
        return "UI_FACT app lifecycle \(parts[2]) at \(clock(seconds)) UTC"
    }

    /// When the app last entered the background at or after `since` (seconds since 1970), from the
    /// watch file's `text`; nil when it has not, or came back to the foreground since. In UI run
    /// 44880878362 (device test03) the first Home press reached the app (background 1.1 s after
    /// it) while XCTest still read the app in the foreground 8 s later: the app's own line is the
    /// earlier and surer answer (`UITestWait.toBackground`).
    static func inBackground(_ text: String, since: Double) -> Double? {
        var entered: Double?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "^", let seconds = Double(parts[1]), seconds >= since - 0.05 else { continue }
            switch parts[2] {
            case "background": entered = seconds
            case "foreground", "active": entered = nil
            default: break
            }
        }
        return entered
    }

    /// "HH:MM:SS.s" (UTC) of seconds since 1970, the clock of `UITestOnboarding.clock`.
    static func clock(_ seconds: Double) -> String {
        let day = seconds.truncatingRemainder(dividingBy: 86_400)
        return String(format: "%02d:%02d:%04.1f", Int(day / 3600), Int(day.truncatingRemainder(dividingBy: 3600) / 60),
                      day.truncatingRemainder(dividingBy: 60))
    }
}
