import XCTest

/// Speed measurements with XCTest's metrics (owner's decision 16.11.2026: start, scrolling and
/// analysis; generous limits or report only). Report only: no test here has a baseline, so a
/// slow value never makes a run red; `ui_tests.py` (`perf_report`) collects the values
/// ("measured [...] average: ..." from XCTest, `UI_PERF` lines from this file) into the job
/// summary, so every full UI run leaves a row to compare with the last.
///
/// Runs in the group "flow-full" after test1 and test1b (classes run in alphabetical order),
/// on the demo library they made; run alone it onboards and seeds first (`UITestOnboarding`).
/// The analysis measurement (test3, about five minutes on a CI simulator) is left out of quick
/// runs (ALBUMIST_UI_QUICK, as DeviceConditionUITests.test11).
///
/// The values come from a CI simulator on a shared Mac: they show trends between runs, not
/// what a phone does (the iPhone measurements stay with the owner).
@MainActor
final class PerformanceUITests: XCTestCase {
    private var app = XCUIApplication()

    private static let arguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked",
                                    "-AlbumistUITestFastStart"]

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = Self.arguments + extra
        UITestAppEnd.launch(app)
    }

    /// An onboarded demo library with nothing running, as the other groups' tests start from.
    private func prepare(_ test: String) {
        launch()
        UITestOnboarding.completeIfNeeded(app, in: test)
        let idle = waitIdle(timeout: 900)
        print(idle ? "UI_STEP_OK \(test) ready" : "UI_STEP_MISSING \(test) ready")
        XCTAssertTrue(idle, "\(test): the analysis did not come to rest before the measurement")
    }

    /// Nothing runs, three checks in a row two seconds apart (as `waitStable` in the flow tests).
    private func waitIdle(timeout: TimeInterval) -> Bool {
        UITestOnboarding.waitStable(timeout: timeout) { UITestOnboarding.analysisIdle(app) }
    }

    /// A tab bar button; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            _ = UITestWait.holds(timeout: 1) { button.exists && button.isHittable }
            tries += 1
        }
        return button
    }

    // MARK: 1 Start

    /// Cold start until the app answers taps (`XCTApplicationLaunchMetric`, waitUntilResponsive),
    /// five launches of the onboarded app with the demo library. Every launch goes through
    /// `UITestAppEnd.launch` (it ends the app of the launch before; the metric measures the
    /// launch itself from the system's start signposts, not the end before it).
    func test1_LaunchTime() {
        prepare("perf start")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            launch()
        }
        print("UI_STEP_OK perf start measured")
    }

    // MARK: 2 Scrolling

    /// Scrolling the library's photo grid fast (`XCTOSSignpostMetric` deceleration: hitches and
    /// frame time while the grid glides out), five times, each from the top.
    func test2_LibraryScroll() {
        prepare("perf scroll")
        let library = tabButton("Mediathek")
        guard library.waitForExistence(timeout: 15) else {
            print("UI_STEP_MISSING perf scroll library tab")
            XCTFail("No library tab")
            return
        }
        library.tap()
        let grid = app.collectionViews.firstMatch.waitForExistence(timeout: 10) ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        guard grid.waitForExistence(timeout: 10) else {
            print("UI_STEP_MISSING perf scroll grid")
            XCTFail("No scrolling photo grid in the library")
            return
        }
        print("UI_STEP_OK perf scroll grid (\(grid.elementType == .collectionView ? "collection view" : "scroll view"))")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            grid.swipeUp(velocity: .fast)
            stopMeasuring()
            grid.swipeDown(velocity: .fast)
            grid.swipeDown(velocity: .fast)
        }
        print("UI_STEP_OK perf scroll measured")
    }

    // MARK: 3 Analysis

    /// The whole analysis of the demo library from the start: a launch sets the database aside
    /// (`-AlbumistUITestRebuildDatabase`, as the stress test does) and analyses every photo.
    /// Measured once with the app's own clock in mind: XCTest's `measure` would run the five
    /// minutes at least twice (its first round is a warm-up), so the time is taken here and
    /// printed as `UI_PERF analysis <s> s` for the summary.
    func test3_AnalysisTime() throws {
        if ProcessInfo.processInfo.environment["ALBUMIST_UI_QUICK"] == "1" {
            throw XCTSkip("Quick UI run (ALBUMIST_UI_QUICK): the analysis is measured only in a full UI run")
        }
        prepare("perf analysis")
        // The clock starts right before the launch, after `UITestAppEnd.launch` has ended the app
        // of `prepare` (that end can take up to a minute on a busy Mac and is no analysis).
        var began = Date()
        app = XCUIApplication()
        app.launchArguments = Self.arguments + ["-AlbumistUITestRebuildDatabase"]
        UITestAppEnd.launch(app) { began = Date() }
        // The analysis starts at launch with this switch; until its card shows "Pause" the idle
        // check would see the overview of a moment before it began.
        let pause = app.buttons["Pause"]
        let started = UITestWait.holds(timeout: 30) { pause.exists }
        if !started { print("UI_FACT perf analysis: no Pause within 30 s (a very quick analysis or a late card)") }
        let done = waitIdle(timeout: 1200)
        // `waitIdle` needs three idle checks two seconds apart: the analysis ended about 4 s
        // before it says so.
        let seconds = max(0, Date().timeIntervalSince(began) - 4)
        print(done ? "UI_STEP_OK perf analysis done" : "UI_STEP_MISSING perf analysis done")
        XCTAssertTrue(done, "The analysis of the demo library did not finish within 20 min")
        // Only a measured analysis is a value: without "Pause" the idle check may have seen the
        // overview before the analysis began, and the time would look like a fast analysis.
        if done && started {
            print("UI_PERF analysis \(String(format: "%.1f", seconds)) s")
        }
    }
}
