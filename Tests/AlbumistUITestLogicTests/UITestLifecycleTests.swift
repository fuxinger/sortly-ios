import Foundation
import Testing
@testable import AlbumistUITestLogic

/// The app's lifecycle lines in the watch file (`UITestLifecycle`): written by the app, printed by
/// the UI test next to its Home press, so a lost first press shows whether it reached the app.
@Suite("UI test lifecycle lines")
struct UITestLifecycleTests {
    // 2026-11-21 03:43:07.4 UTC
    let seconds = 1_795_232_587.4

    @Test func aWrittenLineIsReadBack() throws {
        for event in UITestLifecycle.events.sorted() {
            let line = UITestLifecycle.line(event, at: seconds)
            #expect(line.hasSuffix("\n"))
            let fact = try #require(UITestLifecycle.fact(Substring(line.dropLast())))
            #expect(fact == "UI_FACT app lifecycle \(event) at 03:43:07.4 UTC")
        }
    }

    @Test func otherLinesOfTheFileAreNotLifecycleLines() {
        // A stall, the process line, a stack, the marked work, an unknown event, a broken time.
        for line in ["1795232587.400 2200", "@ 27835 1795232544.5 1795232551.4", "# after 2.0 s of the stall: a | b",
                     "% in the stall of 2.2 s from 03:43:07.4 UTC: atlas map paths 1x", "^ 1795232587.4 suspended",
                     "^ soon background", "^ 1795232587.4", ""] {
            #expect(UITestLifecycle.fact(Substring(line)) == nil, "\(line)")
        }
    }

    /// UI run 44880878362, device test03: Home press at 08:53:15.1, the app resigned active at
    /// 15.5 and was in the background at 16.2, while XCTest still read state 4 eight seconds later
    /// and pressed Home a second time. The app's own line answers the question first.
    @Test func theAppsBackgroundLineAfterThePressCounts() throws {
        let press = 1_795_251_195.1 // 08:53:15.1
        let file = UITestLifecycle.line("foreground", at: press - 28) + UITestLifecycle.line("active", at: press - 22)
            + "1795251190.000 2600\n" + UITestLifecycle.line("resign-active", at: press + 0.4)
            + UITestLifecycle.line("background", at: press + 1.1)
        let since = try #require(UITestLifecycle.inBackground(file, since: press))
        #expect(UITestLifecycle.clock(since) == "08:53:16.2")
    }

    @Test func noBackgroundLineAfterThePressMeansNotYet() {
        let press = 1_795_251_195.1
        // Only a resign-active (a gesture iOS cancelled), or a background from before the press.
        #expect(UITestLifecycle.inBackground(UITestLifecycle.line("resign-active", at: press + 0.4), since: press) == nil)
        #expect(UITestLifecycle.inBackground(UITestLifecycle.line("background", at: press - 30)
            + UITestLifecycle.line("foreground", at: press - 20), since: press) == nil)
        // Back in the foreground after the background: not in the background now.
        #expect(UITestLifecycle.inBackground(UITestLifecycle.line("background", at: press + 1)
            + UITestLifecycle.line("foreground", at: press + 3), since: press) == nil)
        #expect(UITestLifecycle.inBackground("", since: press) == nil)
    }

    @Test func theClockIsTheOneOfTheTestsClockLines() {
        #expect(UITestLifecycle.clock(seconds) == "03:43:07.4")
        #expect(UITestLifecycle.clock(86_400 * 3 + 5) == "00:00:05.0")
    }
}
