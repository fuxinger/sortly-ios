import Foundation

/// The app's main-thread stalls, printed by the test that launched it: the job log keeps at
/// most 40 of the app's own lines, and the stalls of a later test were cut off there (test02,
/// UI run 44002652481, a snapshot timeout with no stall line to compare). The app writes each
/// stall over half a second into `path` (-AlbumistUITestWatchMainLog, anew at every launch), and
/// during a long stall the main thread's stack (`MainThreadWatch.reportStack`).
/// Nonisolated: also called from teardown blocks.
enum UITestStalls {
    static var path: String { NSTemporaryDirectory() + "uitest-main-stalls.txt" }

    /// Launch arguments that make the app write the file (none when `extra` names one already).
    static func arguments(besides extra: [String]) -> [String] {
        extra.contains("-AlbumistUITestWatchMainLog") ? [] : ["-AlbumistUITestWatchMainLog", path]
    }

    /// The stalls of 2 s or more since the last launch, as `UI_FACT main stall 3.2 s from
    /// 18:31:05.2 UTC` (the clock of `UI_MAIN_STALL` and of `UI_FACT slow query`), and each stack
    /// as `UI_FACT main stack after 5.0 s of the stall from …: frame | frame | …`, and the marked
    /// work the main thread did in it as `UI_FACT main work in the stall of …: name 12x 0.3 s, …`
    /// (`MainThreadWatch.count` and `section`), and each change between active, inactive and
    /// background as `UI_FACT app lifecycle background at 18:31:05.2 UTC` (`UITestLifecycle`). `file`: another file the app wrote the same way
    /// (the stress test's measured launch, `-AlbumistUITestWatchMainLog <file>`), else `path`.
    static func report(_ file: String? = nil) {
        let file = file ?? path
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        // The app may still run (a teardown report): its process id stays known for its end.
        UITestLaunchRecord.shared.read(text, of: file)
        try? FileManager.default.removeItem(atPath: file)
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# ") {
                print("UI_FACT main stack \(line.dropFirst(2))")
                continue
            }
            if line.hasPrefix("% ") {
                print("UI_FACT main work \(line.dropFirst(2))")
                continue
            }
            if let fact = UITestLifecycle.fact(line) {
                print(fact)
                continue
            }
            let parts = line.split(separator: " ")
            // "@ <pid> <process start> <app code reached>": `ui_tests.py` compares the start
            // with the test's "UI_FACT clock … launch" when XCTest lost the app at a launch.
            if parts.count == 4, parts[0] == "@", let started = Double(parts[2]), let reached = Double(parts[3]) {
                print("UI_FACT app process \(parts[1]) started \(clock(started)) UTC, its code ran from \(clock(reached)) UTC")
                continue
            }
            guard parts.count == 2, let end = Double(parts[0]), let ms = Int(parts[1]), ms >= 2000 else { continue }
            let from = end - Double(ms) / 1000
            print("UI_FACT main stall \(String(format: "%.1f", Double(ms) / 1000)) s from \(clock(from)) UTC")
        }
    }

    /// "HH:MM:SS.s" (UTC) of seconds since 1970, the clock of `UITestOnboarding.clock`.
    private static func clock(_ seconds: Double) -> String { UITestLifecycle.clock(seconds) }
}
