import XCTest

/// Waits for a state instead of a fixed sleep (review P5-05). A fixed sleep that stands in for
/// a state the app has to reach turns red on a starved Mac: device test06 waited a fixed 4 s
/// for the background and failed (UI run 44480215847). Each wait here has a deadline at least as
/// long as the sleep it replaced. When the deadline runs out it prints `UI_STEP_MISSING` and
/// fails the test, never a silent pass. The time it took is printed as `UI_TIMING wait`, so a
/// starved Mac shows in the log. The rule `SleepRuleTests` (test_ui_tests.py) keeps the number
/// of fixed sleeps going down.
@MainActor
enum UITestWait {
    /// `element` exists within `timeout` seconds.
    @discardableResult
    static func appears(_ element: XCUIElement, _ what: String, timeout: TimeInterval,
                        file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let start = Date()
        let shown = element.waitForExistence(timeout: timeout)
        report(shown, what, since: start, timeout: timeout, file: file, line: line)
        return shown
    }

    /// `element` is gone within `timeout` seconds.
    @discardableResult
    static func disappears(_ element: XCUIElement, _ what: String, timeout: TimeInterval,
                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let start = Date()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        let done = XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
        report(done, what, since: start, timeout: timeout, file: file, line: line)
        return done
    }

    /// `condition` holds within `timeout` seconds (checked every half second).
    @discardableResult
    static func until(_ what: String, timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
        let start = Date()
        let met = holds(timeout: timeout, condition)
        report(met, what, since: start, timeout: timeout, file: file, line: line)
        return met
    }

    /// `condition` holds within `timeout` seconds, checked every `interval` seconds; goes on as
    /// soon as it does. Unlike `until` it neither prints nor fails: for a try the caller repeats
    /// or checks itself right after (a tab bar that expands after a swipe), and for something
    /// that may or may not come (a system alert). Every condition wait of this file polls here.
    static func holds(timeout: TimeInterval, interval: TimeInterval = 0.5, _ condition: () -> Bool) -> Bool {
        let start = Date()
        var met = condition()
        while !met, Date().timeIntervalSince(start) < timeout {
            // pacing: the poll's interval
            usleep(UInt32(interval * 1_000_000))
            met = condition()
        }
        return met
    }

    /// `element` lies above the bottom of the navigation bar `bar` and not inside it: content
    /// that counts as hittable for XCUITest, but a tap there lands on the bar. As
    /// `bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY`,
    /// read from one snapshot of each instead of five queries (every property of an
    /// `XCUIElement` asks the app again; the taps of the flow and device tests ask this before
    /// each of their taps). The element's frame is read as before when its snapshot fails, so an
    /// element that is gone still fails the test there.
    static func underNavigationBar(_ element: XCUIElement, _ bar: XCUIElement) -> Bool {
        guard let barFrame = (try? bar.snapshot())?.frame else { return false }
        let frame = (try? element.snapshot())?.frame ?? element.frame
        return !barFrame.contains(frame) && frame.midY < barFrame.maxY
    }

    /// What `screenAtRest` found.
    enum ScreenRest {
        /// Two snapshots in a row put every element in the same place; the last of them.
        case still(any XCUIElementSnapshot)
        /// The last two snapshots still differed when the time ran out (the test has failed).
        case moving
        /// No two snapshots in a row could be read (failed or too slow): not checked, not failed.
        case unread
    }

    /// The screen of `app` has stopped moving: two snapshots of its whole tree, half a second
    /// apart, put every element in the same place (to the point). Replaces the fixed second
    /// "to let a scroll come to rest" before a screenshot, a tree check or an audit: it goes on
    /// once a decelerating list has stopped, and a screen that is still moving after `timeout`
    /// fails with `UI_STEP_MISSING`. Only movement fails: a snapshot that cannot be read (a
    /// busy simulator) is said as `UI_FACT … no snapshot` and the caller carries on, as after
    /// the old sleep.
    ///
    /// Not seen: transitions that move no frame. UIKit sets the final frames of a push or a
    /// sheet at once and animates only what is drawn, and a fade changes no frame at all; the
    /// waits for the screen's own elements cover the first, the second contrast audit
    /// (`confirmContrast` in AccessibilityUITests) the fades.
    @discardableResult
    static func screenAtRest(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 8,
                             file: StaticString = #filePath, line: UInt = #line) -> ScreenRest {
        let start = Date()
        var last: [CGRect]?
        var lastRoot: (any XCUIElementSnapshot)?
        // The last two readings were both read and differed: real movement.
        var moved = false
        let still = holds(timeout: timeout) {
            var now: [CGRect]?
            lastRoot = try? app.snapshot()
            if let root = lastRoot { now = frames(of: root) }
            moved = now != nil && last != nil && now != last
            let same = now != nil && now == last
            last = now
            return same
        }
        print("UI_TIMING wait \(what) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        if still, let root = lastRoot {
            print("UI_STEP_OK \(what)")
            return .still(root)
        }
        if moved {
            print("UI_STEP_MISSING \(what) (still moving after \(Int(timeout)) s)")
            XCTFail("Not at rest within \(Int(timeout)) s: \(what)", file: file, line: line)
            return .moving
        }
        print("UI_FACT \(what): not checked at rest, no snapshot")
        return .unread
    }

    /// Every element's frame in one snapshot, rounded to the point, in a fixed order. A loop,
    /// not a nested function: the snapshot's attributes belong to the main actor.
    static func frames(of root: any XCUIElementSnapshot) -> [CGRect] {
        var frames: [CGRect] = []
        var stack: [any XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            let frame = node.frame
            frames.append(CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                                 width: frame.width.rounded(), height: frame.height.rounded()))
            stack.append(contentsOf: node.children)
        }
        return frames
    }

    /// Presses Home and waits until iOS has the app in the background (or ended it), then keeps
    /// it there for `atLeast` seconds (at least 1 s), counted from the moment iOS reported it. A
    /// fixed sleep after Home brought the app back before it was ever in the background on a
    /// slow Mac (device test06, UI run 44480215847; d8f863f).
    ///
    /// The Home press itself can be lost on the CI simulator: in UI run 44497741096 (19.11.) the
    /// app stayed in the foreground (state 4) for 30 s after it in test03 and test06, while
    /// simctl calls to the same simulator timed out. So a press without effect after 8 s is
    /// tried once more (15 s), and then the Settings app is brought to the front (30 s), which
    /// sends this app to the background without SpringBoard's Home gesture. The first press had
    /// 20 s until 20.11.: on the CI simulator it never had an effect in 13 of 13 presses, and the
    /// second one always did within 1.4 s. Each extra try is a
    /// counted flaky retry (`UI_FLAKY_RETRY <Class.test>`, from `test`), never silent; the test
    /// fails only when no way reached the background. Every Home press of the UI tests goes
    /// through here. The time in the background never counts from the first press: after a late
    /// way (20-35 s after it) the app would otherwise stay there only 1 s, and test03's expiry
    /// might never happen (second review of 5d730ac, 6d6baf1).
    @discardableResult
    static func toBackground(_ app: XCUIApplication, _ why: String, atLeast: TimeInterval, in test: XCTestCase,
                             timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let pressed = Date()
        UITestOnboarding.clock("wait start app in the background \(why)")
        // The moment iOS reported the app in the background (or ended), nil while it has not.
        // The app's own lifecycle line counts too (`UITestLifecycle.inBackground`): in UI run
        // 44880878362 it was in the background 1.1 s after the first press while XCTest read
        // state 4 for 8 s more, and only that stale state made the second press.
        func inBackground(within seconds: TimeInterval) -> Date? {
            let until = Date().addingTimeInterval(seconds)
            repeat {
                let state = app.state
                if state == .runningBackground || state == .runningBackgroundSuspended || state == .notRunning { return Date() }
                if let since = appReportedBackground(since: pressed, state: state) { return since }
                usleep(250_000)
            } while Date() < until
            return nil
        }
        // Plain values, no closures: XCUIDevice and XCUIApplication belong to the main actor.
        // The first press gets 8 s (it had 20 s): in all 13 Home presses of the UI job logs
        // collected for the tempo plan (18.-20.11., among them UI runs 44617747359 and
        // 44630953220) the app was still in the foreground 20 s after the first press and in
        // the background 1.0-1.4 s after the second. A first press that works shows within a second or two;
        // the second press and the Settings app keep their times.
        let ways: [(name: String, wait: TimeInterval)] = [
            ("Home press", min(timeout, 8)), ("second Home press", 15), ("Settings app in front", 30),
        ]
        var reached = false
        var inBackgroundSince = pressed
        for (index, way) in ways.enumerated() {
            if index > 0 {
                print("UI_FLAKY_RETRY \(testID(test)) app still in the foreground (state \(app.state.rawValue)) \(Int(Date().timeIntervalSince(pressed))) s after the Home press \(why), tried: \(way.name)")
            }
            clearSystemAlert(index == 0 ? "before the Home press \(why)" : "before the \(way.name) \(why)")
            // The moment of each way, next to the app's own `UI_FACT app lifecycle` lines
            // (`UITestLifecycle`): did the first press reach the app at all?
            UITestOnboarding.clock("\(way.name) \(why)")
            if index < 2 {
                XCUIDevice.shared.press(.home)
            } else {
                XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
            }
            if let since = inBackground(within: way.wait) {
                reached = true
                inBackgroundSince = since
                print("UI_FACT app in the background \(why) by \(way.name)")
                break
            }
        }
        let took = Date().timeIntervalSince(pressed)
        print("UI_FACT app in the background \(why): state \(app.state.rawValue) after \(String(format: "%.1f", took)) s")
        print("UI_TIMING wait app in the background \(why) \(String(format: "%.1f", took)) s")
        if reached {
            print("UI_STEP_OK app in the background \(why)")
        } else {
            print("UI_STEP_MISSING app in the background \(why) (Home twice and Settings, \(Int(took)) s)")
            XCTFail("The app did not reach the background \(why) (Home twice and Settings, \(Int(took)) s)", file: file, line: line)
        }
        let wait = reached ? max(atLeast - Date().timeIntervalSince(inBackgroundSince), 1) : 0
        // pacing: the minimum time in the background, counted from when iOS reported it
        if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
        return reached
    }

    /// When the app wrote that it entered the background after `pressed` (its watch file,
    /// `UITestStalls.path`), nil while it has not; `state` is what XCTest reads meanwhile.
    private static func appReportedBackground(since pressed: Date, state: XCUIApplication.State) -> Date? {
        guard let text = try? String(contentsOfFile: UITestStalls.path, encoding: .utf8),
              let since = UITestLifecycle.inBackground(text, since: pressed.timeIntervalSince1970) else { return nil }
        print("UI_FACT app reported the background at \(UITestLifecycle.clock(since)) UTC, XCTest state \(state.rawValue)")
        return Date(timeIntervalSince1970: since)
    }

    /// A system alert in front of the app takes a Home press for itself: SpringBoard closes the
    /// alert and the app stays in the foreground. In the full UI runs of 20.11. (44790864148,
    /// 44814382842, 44828248004) every first Home press of the suite (5 of 5 per run) left the
    /// app in the foreground and every second one worked within 1.4 s; each press came seconds
    /// after a run the user started (rebuild, disk full, backup, analysis), which is when the app
    /// asks for notifications (`ContinuedAnalysis.requestNotificationPermission`), and no test of
    /// those groups had answered that question before. A Home press closes it unanswered, so
    /// iOS asks again at the next run. The notification question is answered here as everywhere
    /// in the UI tests ("Nicht erlauben", A10); any other system alert is only named, never
    /// answered, because the tests that expect one (deleting albums, photo access) answer it
    /// themselves.
    static func clearSystemAlert(_ when: String) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return }
        let title = alert.label
        print("UI_FACT system alert in front \(when): \(title)")
        let aboutNotifications = ["Notification", "Mitteilung"].contains { title.localizedCaseInsensitiveContains($0) }
        guard aboutNotifications else { return }
        for label in ["Nicht erlauben", "Don’t Allow", "Don't Allow"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            print("UI_STEP_OK notification question answered (don't allow) \(when)")
            return
        }
    }

    /// Brings `app` back to the front and waits until iOS has it there. On a starved CI Mac
    /// XCTest's `activate()` can fail on its own: device test03 in UI run 44582675590 (load 674)
    /// stopped with "Failed to activate application ... (current state: Running Background)"
    /// with nothing wrong in the app. Such a failed activation is taken as expected (non-strict,
    /// only that message) and tried again, at most three times; every extra try is a counted
    /// flaky retry (`UI_FLAKY_RETRY <Class.test>`), never silent. The test fails only when the
    /// app never came to the front. Every return of the UI tests to the app goes through here
    /// (rule `test_every_return_to_the_app_goes_through_the_wait_that_tries_again`).
    @discardableResult
    static func toForeground(_ app: XCUIApplication, _ why: String, in test: XCTestCase,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        final class Seen: @unchecked Sendable { var failedActivation = false }
        let start = Date()
        for attempt in 1...3 {
            let seen = Seen()
            let options = XCTExpectedFailure.Options()
            options.isStrict = false
            options.issueMatcher = { issue in
                let match = issue.compactDescription.contains("Failed to activate application")
                if match { seen.failedActivation = true }
                return match
            }
            XCTExpectFailure("XCTest could not activate the app on a busy simulator", options: options) {
                app.activate()
            }
            let front = app.wait(for: .runningForeground, timeout: 15)
            if front {
                if attempt > 1 || seen.failedActivation {
                    print("UI_TIMING wait app in the foreground \(why) \(Int(Date().timeIntervalSince(start) * 1000)) ms, attempt \(attempt)")
                }
                if seen.failedActivation {
                    print("UI_FLAKY_RETRY \(testID(test)) XCTest could not activate the app \(why) (attempt \(attempt)), it came to the front")
                }
                return true
            }
            if attempt < 3 {
                print("UI_FLAKY_RETRY \(testID(test)) app not in the foreground \(why) (state \(app.state.rawValue), attempt \(attempt)\(seen.failedActivation ? ", activation failed" : "")), tried again")
            }
        }
        print("UI_STEP_MISSING app in the foreground \(why) (3 activations, \(Int(Date().timeIntervalSince(start))) s)")
        XCTFail("The app did not come to the front \(why) (3 activations, state \(app.state.rawValue))", file: file, line: line)
        return false
    }

    /// "DeviceConditionUITests.test03_…" for UI_FLAKY_RETRY (XCTest's name is "-[Module.Class test]").
    static func testID(_ test: XCTestCase) -> String {
        let parts = test.name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).split(separator: " ")
        let type = parts.first.flatMap { $0.split(separator: ".").last }.map(String.init) ?? String(describing: Swift.type(of: test))
        return "\(type).\(parts.last.map(String.init) ?? "unknown")"
    }

    /// `condition` never holds for `seconds` (checked every half second): the check that
    /// something does not happen watches as long as the fixed sleep before it did (second review
    /// of C2: a check right after a state was reached saw nothing yet).
    @discardableResult
    static func never(_ what: String, for seconds: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
        let start = Date()
        let seen = holds(timeout: seconds, condition)
        let took = String(format: "%.1f", Date().timeIntervalSince(start))
        if seen {
            print("UI_STEP_MISSING \(what) (it happened after \(took) s)")
            XCTFail("Within \(Int(seconds)) s: \(what) did not hold", file: file, line: line)
        } else {
            print("UI_STEP_OK \(what) (watched \(took) s)")
        }
        return !seen
    }

    /// Waits until `seconds` have passed since `start`: the old fixed time stays the minimum
    /// after the state a wait reached (second review of C2: the screen was there, its content
    /// or the next check needed the rest of the old time).
    static func atLeast(_ seconds: TimeInterval, since start: Date) {
        let rest = seconds - Date().timeIntervalSince(start)
        // pacing: the rest of the old fixed time, after the state was reached
        if rest > 0 { usleep(UInt32(rest * 1_000_000)) }
    }

    private static func report(_ met: Bool, _ what: String, since start: Date, timeout: TimeInterval,
                               file: StaticString, line: UInt) {
        print("UI_TIMING wait \(what) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        if met {
            print("UI_STEP_OK \(what)")
        } else {
            print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
            XCTFail("Not within \(Int(timeout)) s: \(what)", file: file, line: line)
        }
    }
}
