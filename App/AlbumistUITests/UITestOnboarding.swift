import XCTest

/// What the later UI tests need from test 1 (AlbumistFlowUITests.test1_FullFlow): a finished
/// onboarding, the demo library and its first analysis.
///
/// UI run 43816787321: the test runner ended inside test 1 right after the trial step (no
/// "passed" or "failed" line, "Executed 5 tests" for the six flow tests). xcodebuild started a
/// new runner at test 2 with an app still at its welcome screen, and every later test failed
/// on that one cut-off (13 failures). Each later test now brings the app to that state by
/// itself when test 1 did not reach its end, so a cut-off costs test 1 and nothing else.
/// In CI (ui.yml) test 1 runs in its own group; the other flow tests run on another simulator
/// and always onboard by themselves there.
@MainActor
enum UITestOnboarding {
    /// Start and end markers of a first test in the runner's temporary folder. A static flag
    /// starts fresh in a restarted runner (run 43816787321: test 2 did not notice the
    /// cut-off); a file stays.
    struct Markers: Sendable {
        let started: URL
        let finished: URL

        init(_ name: String) {
            let folder = FileManager.default.temporaryDirectory
            started = folder.appending(path: "albumist-ui-\(name)-started")
            finished = folder.appending(path: "albumist-ui-\(name)-finished")
        }

        func starts() {
            try? FileManager.default.removeItem(at: finished)
            try? Data().write(to: started)
        }

        func ends() {
            try? Data().write(to: finished)
        }

        var reachedItsEnd: Bool {
            FileManager.default.fileExists(atPath: finished.path)
        }
    }

    /// AlbumistFlowUITests.test1_FullFlow.
    static let fullFlow = Markers("full-flow")
    /// AccessibilityUITests.test1_OnboardingAtLargestTextInDarkMode (run 43823834271: a UI
    /// query timed out while the demo library was being created, which ended test 1, and
    /// tests 2 to 4 found no suggestions).
    static let accessibilityOnboarding = Markers("a11y-onboarding")

    static func fullFlowStarts() { fullFlow.starts() }
    static func fullFlowFinished() { fullFlow.ends() }
    static var fullFlowReachedItsEnd: Bool { fullFlow.reachedItsEnd }

    /// The overview says the analysis is done and nothing runs (as `analysisIdle` in the tests).
    static func analysisIdle(_ app: XCUIApplication) -> Bool {
        func anything(_ text: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        // The Pause button first: one query while the analysis runs (see AlbumistFlowUITests).
        return !app.buttons["Pause"].exists
            && (anything("Fotos analysiert") || anything("Analyse aktuell") || anything("Analyse fertig"))
    }

    /// Onboarding, demo library and first analysis, when the app still shows its welcome
    /// screen, or only the demo library and its analysis when the app is past the onboarding
    /// but still offers it (as `onboardAndSeed` in AccessibilityUITests). Returns true when it
    /// had to do either.
    ///
    /// UI run 43893790053 (group "flow-other"): the runner ended in test 2 right after it tapped
    /// "Beispiel-Mediathek anlegen"; tests 3 to 7 found the app past its welcome screen and ran
    /// on the simulator's own handful of photos (no suggestions, no albums: 10 failures).
    @discardableResult
    static func completeIfNeeded(_ app: XCUIApplication, in test: String) -> Bool {
        func button(_ text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        // The first screen: the welcome screen, the overview's tab bar or "Kein Zugriff". The app
        // picks it once when it has loaded (`AppModel.phase`), so a tab bar is never followed by
        // the welcome screen. Waiting 10 s for the welcome screen alone ran out in every test
        // that found the app onboarded: in CI test 1 runs in its own group, so flow tests 3-7
        // and the locked test came here each time (UI run 44630953220).
        let welcome = button("Los geht")
        _ = UITestWait.holds(timeout: 10) {
            welcome.exists || app.tabBars.firstMatch.exists || app.buttons["access.continue"].exists
        }
        guard welcome.exists else {
            let demo = button("Beispiel-Mediathek anlegen")
            // The demo card is drawn in the same body as the overview's title (OverviewView, a
            // plain VStack; DemoLibrary.isDone is read at start), so once "Übersicht" is there,
            // the card is there too or does not come. Up to the old 5 s when it is not.
            let overview = app.navigationBars["Übersicht"]
            _ = UITestWait.holds(timeout: 5) { demo.exists || overview.exists }
            guard demo.exists else {
                finishInterruptedAnalysis(app, in: test)
                return false
            }
            print("UI_FACT \(test): past the onboarding without the demo library, creating it first")
            demo.tap()
            XCTAssertTrue(demoLibraryCreated(app), "\(test): demo library not created")
            let idle = waitStable(timeout: 1200) { analysisIdle(app) }
            print(idle ? "UI_STEP_OK \(test) demo library" : "UI_STEP_MISSING \(test) demo library")
            XCTAssertTrue(idle, "\(test): the analysis of the demo library did not finish")
            expectCompleteAnalysis(app, in: test)
            return true
        }
        print("UI_FACT \(test): the app is at its welcome screen, onboarding first")
        button("Los geht").tap()
        if button("Weiter").waitForExistence(timeout: 10) { button("Weiter").tap() }
        if app.buttons["access.continue"].waitForExistence(timeout: 5) {
            app.buttons["access.continue"].tap()
            allowPhotosIfAsked(app)
        }
        if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
        guard button("Analyse starten").waitForExistence(timeout: 20) else {
            print("UI_STEP_MISSING \(test) onboarding")
            XCTFail("\(test): onboarding did not reach the trial step")
            return true
        }
        button("Analyse starten").tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] where springboard.buttons[label].waitForExistence(timeout: 4) {
            springboard.buttons[label].tap()
            break
        }
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            demo.tap()
            XCTAssertTrue(demoLibraryCreated(app), "\(test): demo library not created")
        }
        let idle = waitStable(timeout: 1200) { analysisIdle(app) }
        print(idle ? "UI_STEP_OK \(test) onboarding and demo library" : "UI_STEP_MISSING \(test) onboarding and demo library")
        XCTAssertTrue(idle, "\(test): the analysis of the demo library did not finish")
        expectCompleteAnalysis(app, in: test)
        return true
    }

    /// What the analysis card says when not every photo counts as analysed: "58 von 246 Fotos
    /// analysiert", and possibly "12 Fotos konnten noch nicht gelesen werden" below it.
    struct PartialAnalysis {
        let label: String
        let analyzed: Int
        let photos: Int
        let unreadable: Int
        /// The image loads the app counted (the label's value in UI runs).
        let loads: String
        /// The count was on screen but its snapshot failed three times: never taken as complete.
        var readFailed = false

        /// Photos the analysis never came to; unreadable ones it tried and keeps for later.
        var cutOff: Bool { readFailed || analyzed + unreadable < photos }

        var unreadableText: String {
            "\(unreadable) of \(photos) photos could not be read ('\(label)', \(loads))"
        }
    }

    /// The partial count on the overview, or nil when every photo is analysed. German only.
    static func partialAnalysis(_ app: XCUIApplication, wait: TimeInterval = 3) -> PartialAnalysis? {
        let partial = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ von [0-9.]+ Fotos analysiert")).firstMatch
        // Read from one snapshot each: the count changes while the analysis runs, and reading
        // `label` of an element that has just changed is a hard test failure ("No matches
        // found", flow test 5 in UI run 44038288087, right after "checking again").
        // A failed snapshot is tried again and never read as "every photo analysed" (it was:
        // `try?` gave nil, which means complete).
        // "Alle 246 Fotos analysiert" is the same headline when every photo counts: then no
        // partial count comes, and the old wait of `wait` seconds is not waited out.
        let whole = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Alle ", "Fotos analysiert")).firstMatch
        guard UITestWait.holds(timeout: wait, { partial.exists || whole.exists }), partial.exists else { return nil }
        var taken: (any XCUIElementSnapshot)?
        var gone = false
        var tries = 0
        // Three tries, half a second apart. The tries end it (as before the wait helper): three
        // slow snapshots still get their three tries. The 30 s cap only keeps the wait finite and
        // visible to the time-limit rule (second review of P5-05); three tries never reach it.
        _ = UITestWait.holds(timeout: 30) {
            tries += 1
            if let snapshot = try? partial.snapshot() { taken = snapshot; return true }
            // The count went away between the tries: the analysis has finished.
            gone = !partial.exists
            return gone || tries >= 3
        }
        if gone { return nil }
        guard let shot = taken else {
            print("UI_FACT partial analysis: the count is on screen but could not be read three times")
            return PartialAnalysis(label: "(not readable)", analyzed: 0, photos: 0, unreadable: 0, loads: "", readFailed: true)
        }
        let label = shot.label
        func number(_ text: Substring) -> Int { Int(text.filter(\.isNumber)) ?? 0 }
        let parts = label.split(separator: " ")
        let analyzed = parts.first.map(number) ?? 0
        let photos = parts.count > 2 ? number(parts[2]) : 0
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "konnten noch nicht gelesen")).firstMatch
        let noteLabel = note.exists ? (try? note.snapshot())?.label : nil
        let unreadable = noteLabel.map { $0.split(separator: " ").first.map(number) ?? 0 } ?? 0
        return PartialAnalysis(label: label, analyzed: analyzed, photos: photos, unreadable: unreadable, loads: (shot.value as? String) ?? "")
    }

    /// After a test watched the analysis finish in this app process, every photo must count as
    /// analysed: a partial count is an analysis that stopped early and said "fertig" (never
    /// allowed), not something to repair with "Neu prüfen".
    static func expectCompleteAnalysis(_ app: XCUIApplication, in test: String) {
        guard let partial = partialAnalysis(app) else { return }
        if partial.readFailed {
            print("UI_STEP_MISSING \(test) complete analysis: count not readable")
            XCTFail("\(test): the analysis card shows a partial count that could not be read")
        } else if partial.cutOff {
            print("UI_STEP_MISSING \(test) complete analysis: '\(partial.label)'")
            XCTFail("\(test): the analysis ended early at '\(partial.label)' (\(partial.unreadable) unreadable, \(partial.loads)) although this test watched it finish")
        } else {
            print("UI_STEP_MISSING \(test) readable demo photos: \(partial.unreadableText)")
            XCTFail("\(test): \(partial.unreadableText)")
        }
    }

    /// Only for a relaunch into a library seeded earlier (no welcome screen, no demo button):
    /// an analysis cut off by a restarted test runner (the app was ended in the middle of it)
    /// does not go on by itself in UI runs, which start no analysis at launch. The card says
    /// "58 von 246 Fotos analysiert" with "Neu prüfen", and `analysisIdle` takes that as done
    /// (run 43918684247: the runner was restarted in accessibility test 1, and tests 2 to 4
    /// found "No suggestions yet"). "Neu prüfen" analyses the rest, as a user would. Photos that
    /// could not be read are no cut-off: checking again would not change them, so they fail at
    /// once with their count instead of after a 20-minute wait.
    static func finishInterruptedAnalysis(_ app: XCUIApplication, in test: String) {
        guard let partial = partialAnalysis(app) else { return }
        if partial.readFailed {
            print("UI_STEP_MISSING \(test) partial count readable")
            XCTFail("\(test): the analysis card shows a partial count that could not be read")
            return
        }
        guard partial.cutOff else {
            print("UI_STEP_MISSING \(test) readable demo photos: \(partial.unreadableText)")
            XCTFail("\(test): \(partial.unreadableText)")
            return
        }
        print("UI_FACT \(test): the analysis was cut off at '\(partial.label)' (\(partial.unreadable) unreadable), checking again")
        let again = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Neu prüfen")).firstMatch
        guard again.waitForExistence(timeout: 5) else {
            print("UI_STEP_MISSING \(test) check again after a cut-off analysis")
            XCTFail("\(test): an analysis was cut off and the overview offers no \"Neu prüfen\"")
            return
        }
        // Below other cards the button can sit under the tab bar, where a tap lands on the bar.
        let tabs = app.tabBars.firstMatch
        var swipes = 0
        while swipes < 4, tabs.exists, again.frame.maxY > tabs.frame.minY {
            app.swipeUp()
            swipes += 1
        }
        again.tap()
        // Idle with a count that no longer leaves photos out (unreadable ones are judged below).
        let done = waitStable(timeout: 1200) { analysisIdle(app) && partialAnalysis(app, wait: 0)?.cutOff != true }
        print(done ? "UI_STEP_OK \(test) cut-off analysis finished" : "UI_STEP_MISSING \(test) cut-off analysis finished")
        XCTAssertTrue(done, "\(test): the cut-off analysis did not finish after \"Neu prüfen\"")
        if done { expectCompleteAnalysis(app, in: test) }
    }

    private static func allowPhotosIfAsked(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        // Taps the alert's button when it is there; the trial step means it was not needed.
        _ = UITestWait.holds(timeout: 25) {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    return true
                }
            }
            return app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Analyse starten")).firstMatch.exists
        }
    }

    /// Waits until the demo card no longer creates photos and no longer offers to.
    ///
    /// Run 43823834271: a query over every element ("label CONTAINS" on `.any`) every 2 s timed
    /// out while the app wrote the photos at the largest text size ("Failed to get matching
    /// snapshots: Timed out while evaluating UI query"), and a failed query ends the test. The
    /// wait asks only for the card's text and button, every 5 s.
    static func demoLibraryCreated(_ app: XCUIApplication, timeout: TimeInterval = 600) -> Bool {
        let seeding = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Beispielfotos werden angelegt")).firstMatch
        let offer = app.buttons["Beispiel-Mediathek anlegen"]
        let started = Date()
        let created = waitStable(timeout: timeout, interval: 5) { !seeding.exists && !offer.exists }
        if !created { print("UI_STEP_MISSING demo library created (timeout \(Int(timeout)) s)") }
        print("UI_TIMING demo library \(Int(Date().timeIntervalSince(started))) s")
        return created
    }

    /// `condition` held on three checks in a row, `interval` seconds apart (also PerformanceUITests).
    static func waitStable(timeout: TimeInterval, interval: UInt32 = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            let asked = Date()
            streak = condition() ? streak + 1 : 0
            reportSlowCheck(since: asked)
            if streak >= 3 { return true }
            // pacing: the poll's interval
            sleep(interval)
        }
        return false
    }

    /// One check (a few queries) normally answers in well under a second. A slow one is printed
    /// with the time, so a run whose queries time out shows whether the answers slowed down
    /// first or stopped at once (compare `UI_MAIN_STALL` / `UI_PROCESS_STALL` from the app).
    static func reportSlowCheck(since asked: Date) {
        let took = Date().timeIntervalSince(asked)
        if took >= 5 { print("UI_FACT slow query: a check took \(Int(took)) s, from \(clockText(asked)) UTC") }
    }

    /// `UI_FACT clock 18:31:05.2 <event>`: the time of a test step in UTC, on the clock the app's
    /// `UI_MAIN_STALL` lines use (`MainThreadWatch.clock`), so a stall can be put next to the
    /// step, the tap or the accessibility audit that ran then.
    static func clock(_ event: String) {
        // UI_FACT: the job log keeps only some prefixes of the test output (ui_tests.py
        // REPORT), and prints them after the test, so the time has to be in the line.
        print("UI_FACT clock \(clockText(Date())) \(event)")
    }

    static func clockText(_ date: Date) -> String {
        let day = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let hours = Int(day / 3600), minutes = Int(day.truncatingRemainder(dividingBy: 3600) / 60)
        let rest = day.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%04.1f", hours, minutes, rest)
    }
}
