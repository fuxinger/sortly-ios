import XCTest
import UIKit

/// End-to-end run on the simulator: onboarding, demo library, analysis, accepting
/// suggestions, creating albums, atlas, library, search, settings and undo.
/// Every step prints `UI_STEP_OK` / `UI_STEP_MISSING`, screenshots are printed as
/// `PREVIEW_JPEG ui-…` chunks and accessibility audit findings as `A11Y_ISSUE` lines,
/// so the CI log is the whole report (artifact downloads are not available to us).
@MainActor
final class SortlyFlowUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-SortlyUITestUnlocked"] + extra
        app.launch()
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The search tab (`Tab(role: .search)`) carries the system's own label.
    private func searchTabButton() -> XCUIElement {
        for label in ["Suchen", "Suche", "Search"] where app.tabBars.buttons[label].exists {
            return tabButton(label)
        }
        return app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
    }

    /// A tab bar button; the iOS 26 tab bar shrinks while scrolling, so it is expanded first.
    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            // Minimized bar: scroll back up first, then tap the bar itself to expand it.
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            sleep(1)
            tries += 1
        }
        return button
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-")) // what was on screen instead
            XCTFail("Missing: \(step)")
            return false
        }
        // Scroll the element into view. Content above the screen or under the navigation bar
        // still counts as "hittable" for XCUITest, but a tap there lands on the bar, so it is
        // scrolled back down; content below the screen is scrolled up.
        let bar = app.navigationBars.firstMatch
        var swipes = 0
        while swipes < 8 {
            let underBar = bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
            if underBar { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.buttons.firstMatch.exists { bar.buttons.element(boundBy: 0).tap() }
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let small = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = small.jpegData(compressionQuality: 0.55) else { return }
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG ui-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    private func audit(_ screen: String) {
        do {
            try app.performAccessibilityAudit { issue in
                let element = issue.element
                let frame = element.map { f in "\(Int(f.frame.minX)),\(Int(f.frame.minY)) \(Int(f.frame.width))x\(Int(f.frame.height))" } ?? "-"
                print("A11Y_ISSUE \(screen) | type \(issue.auditType.rawValue) | \(issue.compactDescription) | label '\(element?.label ?? "-")' | \(element?.elementType.rawValue ?? 0) | id '\(element?.identifier ?? "-")' | \(frame)")
                return true // collect everything, the report decides
            }
            print("A11Y_AUDIT_DONE \(screen)")
        } catch {
            print("A11Y_AUDIT_ERROR \(screen) \(error)")
        }
    }

    /// The system photo alert, if the simulator still asks (the CI grant does not always hold).
    /// It can take several seconds to appear while it renders its photo preview.
    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    print("UI_STEP_OK system photo alert")
                    return
                }
            }
            if button("Analyse starten").exists { return } // access was already granted
            usleep(500_000)
        }
        print("UI_STEP_MISSING system photo alert")
    }

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 4) { allow.tap(); print("UI_STEP_OK notification alert"); return }
        }
    }

    /// Polls until `condition` held on `stableChecks` checks in a row (2 s apart).
    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            streak = condition() ? streak + 1 : 0
            if streak >= stableChecks { return true }
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    /// The overview shows "Analyse aktuell" and no running analysis (no "Pause").
    private var analysisIdle: Bool {
        anything("Analyse aktuell").exists && !app.buttons["Pause"].exists
    }

    // MARK: Tests

    func test1_FullFlow() {
        continueAfterFailure = true
        launch()

        // Onboarding
        if button("Los geht").waitForExistence(timeout: 20) {
            shot("01-welcome"); audit("welcome")
            tap(button("Los geht"), "welcome")
            shot("02-areas")
            tap(button("Weiter"), "areas")
            shot("03-access")
            if button("Zugriff erlauben").waitForExistence(timeout: 5) {
                button("Zugriff erlauben").tap()
                allowPhotosIfAsked()
            }
            // With access granted the app moves on by itself; "Weiter" only appears when
            // access had been granted before.
            if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
            let trial = button("Analyse starten").waitForExistence(timeout: 20)
            print(trial ? "UI_STEP_OK access granted" : "UI_STEP_MISSING access granted")
            XCTAssertTrue(trial, "Onboarding did not reach the trial step")
            shot("04-trial"); audit("trial")
            tap(button("Analyse starten"), "start analysis")
            allowNotificationsIfAsked()
        }

        // Demo library
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            shot("05-overview-empty")
            tap(demo, "seed demo library")
            let started = Date()
            // The demo card disappears from the overview once every photo is in the library.
            let seeded = waitStable("demo library created", timeout: 600) {
                !anything("Beispielfotos werden angelegt").exists && !button("Beispiel-Mediathek anlegen").exists
            }
            XCTAssertTrue(seeded, "Demo library not created")
            print("UI_TIMING seed \(Int(Date().timeIntervalSince(started))) s")
        } else {
            print("UI_STEP_MISSING demo button (already seeded?)")
        }
        let analysed = Date()
        // Seeding starts a fresh analysis; wait until it ran and the overview stays idle.
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")
        print("UI_TIMING analysis \(Int(Date().timeIntervalSince(analysed))) s")
        // The demo library holds 12 trips; "1 Reisen" was a real detection bug.
        let teaser = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dein Reise-Atlas")).firstMatch
        if teaser.waitForExistence(timeout: 10) {
            print("UI_FACT atlas \(teaser.label)")
            let trips = teaser.label.firstMatch(of: #/(\d+) Reise/#).flatMap { Int($0.1) } ?? 0
            XCTAssertGreaterThanOrEqual(trips, 8, "Too few trips detected in the demo library: \(teaser.label)")
        }
        shot("06-overview"); audit("overview")
        app.swipeUp(); sleep(1)
        shot("06b-overview-areas")
        app.swipeDown(); app.swipeDown()

        // Suggestions
        if tap(button("Vorschläge prüfen"), "open suggestions", timeout: 20) {
            sleep(1)
            shot("07-suggestions"); audit("suggestions")
            // Rows live in a List (collection view), not a scroll view.
            let first = app.collectionViews.cells.element(boundBy: 0)
            if tap(first, "open first suggestion", timeout: 10) {
                sleep(1)
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK suggestion detail opened" : "UI_STEP_MISSING suggestion detail opened")
                XCTAssertTrue(opened, "Tapping a suggestion did not open its detail")
                shot("08-suggestion-detail"); audit("suggestion detail")
                back(); sleep(1)
                let list = app.navigationBars["Vorschläge"].waitForExistence(timeout: 5)
                print(list ? "UI_STEP_OK back to suggestions" : "UI_STEP_MISSING back to suggestions")
                XCTAssertTrue(list, "Back from a suggestion did not return to the list")
                shot("08b-back-to-list")
            }
            if tap(button("empfohlene übernehmen"), "accept recommended") {
                sleep(1)
                shot("09-accepted")
            }
            back(); sleep(1)
        }

        // Area list: open a suggestion and come back (reported: rows not tappable, warning triangle on back)
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        if tap(travel, "open travel area", timeout: 10) {
            sleep(1)
            if tap(app.collectionViews.cells.element(boundBy: 0), "open trip suggestion", timeout: 10) {
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK trip detail opened" : "UI_STEP_MISSING trip detail opened")
                XCTAssertTrue(opened, "Tapping a trip suggestion did not open its detail")
                shot("08c-trip-detail")
                back(); sleep(1)
                shot("08d-back-to-trips")
            }
            back(); sleep(1)
        }

        // Apply
        if tap(button("umsetzen"), "open plan", timeout: 20) {
            sleep(3)
            shot("10-plan"); audit("plan")
            if tap(button("Jetzt umsetzen"), "apply plan", timeout: 30) {
                let applied = Date()
                // Mid-show frames of "photos fly into albums".
                usleep(1_100_000); shot("10b-show")
                usleep(900_000); shot("10c-show")
                XCTAssertTrue(button("Rückgängig machen").waitForExistence(timeout: 900), "Plan did not finish")
                print("UI_TIMING apply \(Int(Date().timeIntervalSince(applied))) s")
                sleep(1)
                shot("11-result"); audit("result")
            }
            back(); sleep(2)
        }

        // Travel atlas
        if tap(button("Reise-Atlas"), "open atlas", timeout: 30) {
            sleep(8)
            shot("12-atlas"); audit("atlas")
            app.swipeUp(); sleep(1)
            shot("12b-atlas-list")
            // A country opens its photos (list row; the map does the same for sighted users).
            let italy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Italien")).firstMatch
            if tap(italy, "open country", timeout: 10) {
                let opened = app.navigationBars["Italien"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK country photos opened" : "UI_STEP_MISSING country photos opened")
                XCTAssertTrue(opened, "Tapping a country did not open its photos")
                let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).count
                print("UI_FACT country photos \(photos)")
                XCTAssertGreaterThan(photos, 5, "The country screen shows no photos")
                sleep(1)
                shot("12c-country"); audit("country")
                back(); sleep(1)
            }
            if tap(app.buttons["Reise-Atlas teilen"], "share atlas") {
                sleep(3)
                shot("13-share-card"); audit("share card")
                tap(button("Fertig"), "close share")
                sleep(2) // the sheet slides away before the navigation bar answers again
            }
            back(); sleep(1)
        }

        // Library
        if tap(tabButton("Mediathek"), "library tab") {
            sleep(2)
            shot("14-library"); audit("library")
            let photo = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
            // After the plan ran, "Nicht sortiert" can be empty: show the sorted photos instead.
            if !photo.waitForExistence(timeout: 3), tap(button("Sortiert"), "sorted photos") {
                sleep(2)
                shot("14b-library-sorted")
            }
            if tap(photo, "open photo") {
                sleep(2)
                shot("15-photo-detail"); audit("photo detail")
                tap(button("Fertig"), "close photo")
            }
            if tap(button("Auswählen"), "select mode") {
                let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
                if photos.count >= 2 { photos.element(boundBy: 0).tap(); photos.element(boundBy: 1).tap() }
                sleep(1)
                shot("16-selection")
                if tap(button("Zu Album hinzufügen"), "add to album") {
                    sleep(2)
                    shot("17-add-to-album"); audit("add to album")
                    tap(button("Abbrechen"), "cancel add")
                }
                tap(button("Fertig"), "end selection")
            }
        }

        // Albums
        if tap(tabButton("Alben"), "albums tab") {
            sleep(2)
            shot("18-albums"); audit("albums")
        }

        // Search (the system names the search tab itself)
        if tap(searchTabButton(), "search tab") {
            sleep(1)
            shot("19-search-empty")
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("Rom")
                sleep(3)
                shot("20-search-rom"); audit("search")
            }
        }

        // Settings and undo
        if tap(tabButton("Übersicht"), "overview tab") {
            if tap(app.buttons["Einstellungen"], "settings") {
                sleep(1)
                shot("21-settings"); audit("settings")
                let undo = app.buttons["Rückgängig"].firstMatch
                if tap(undo, "undo in history", timeout: 10) {
                    tap(app.buttons["Rückgängig machen"].firstMatch, "confirm undo")
                    sleep(15)
                    shot("22-after-undo")
                }
                tap(button("Fertig"), "close settings")
            }
        }
    }

    /// Same app state, but with the largest accessibility text size in dark mode.
    func test2_LargeTextDarkMode() {
        continueAfterFailure = true
        XCUIDevice.shared.appearance = .dark
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-SortlyUITestDark"])
        sleep(5)
        shot("30-overview-xxxl-dark"); audit("overview xxxl dark")
        if tap(button("Reise-Atlas"), "open atlas xxxl", timeout: 20) {
            sleep(6)
            shot("31-atlas-xxxl-dark")
            back()
        }
        if tap(tabButton("Mediathek"), "library xxxl") {
            sleep(2)
            shot("32-library-xxxl-dark"); audit("library xxxl dark")
        }
        XCUIDevice.shared.appearance = .light
    }

    // MARK: Tap-through sweep

    /// Labels the sweep never taps: anything that changes the library or the analysis.
    private let sweepSkip = ["Pause", "Neu prüfen", "Jetzt umsetzen", "Rückgängig", "In Fotos ansehen", "Löschen", "Entfernen", "Anlegen",
                             "Übernehmen", "Nicht jetzt", "ergänzen", "so lassen", "Fortsetzen", "Beispiel", "Ignorieren", "Auswählen"]

    private func isSafe(_ label: String) -> Bool {
        !label.isEmpty && !sweepSkip.contains { label.localizedCaseInsensitiveContains($0) }
    }

    private var screenTitle: String {
        let bar = app.navigationBars.firstMatch
        return bar.exists ? bar.identifier : "-"
    }

    /// Closes a sheet or popover if one is open; returns true if it did.
    @discardableResult
    private func closeSheet() -> Bool {
        for label in ["Fertig", "Abbrechen", "Schließen"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); sleep(1); return true }
        }
        return false
    }

    /// Taps every row (and on top-level screens every button in the content) and checks
    /// that each tap leads somewhere and back works: no dead rows, no crash, no lost screen.
    private func sweep(_ screen: String, depth: Int, strict: Bool = false) {
        let start = screenTitle
        let useCells = app.collectionViews.cells.count > 0
        if depth > 0 && !useCells { return } // detail screens hold actions, not navigation
        let query = useCells ? app.collectionViews.cells : app.scrollViews.firstMatch.buttons
        var labels: [String] = []
        for i in 0..<min(query.count, 8) {
            let label = query.element(boundBy: i).label
            if isSafe(label) && !labels.contains(label) { labels.append(label) }
        }
        for label in labels.prefix(6) {
            let element = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
            guard element.exists else { continue }
            if !element.isHittable { app.swipeUp(); sleep(1) }
            guard element.isHittable else { continue }
            element.tap(); sleep(2)
            guard app.state == .runningForeground else {
                print("UI_SWEEP_CRASH \(screen) › \(label)")
                XCTFail("App crashed after tapping \(label) on \(screen)")
                launch(); sleep(5)
                return
            }
            let now = screenTitle
            if now != start {
                print("UI_SWEEP_OK \(screen) › \(label) → \(now)")
                if depth == 0 && useCells { sweep("\(screen) › \(label)", depth: 1) }
                back(); sleep(1)
                if screenTitle != start {
                    print("UI_SWEEP_BACK_FAILED \(screen) › \(label) (still \(screenTitle))")
                    XCTFail("Back did not return to \(screen) after \(label)")
                    back(); sleep(1)
                }
            } else if closeSheet() {
                print("UI_SWEEP_OK \(screen) › \(label) → sheet")
            } else {
                print("UI_SWEEP_NOOP \(screen) › \(label)")
                if strict { XCTFail("Row '\(label)' on \(screen) did nothing") }
            }
        }
    }

    /// Third run: every tab, every row, one level deep.
    func test3_TapThroughSweep() {
        continueAfterFailure = true
        launch()
        sleep(5)
        sweep("Übersicht", depth: 0)
        for tab in ["Mediathek", "Alben", "Suchen"] {
            let button = tab == "Suchen" ? searchTabButton() : tabButton(tab)
            guard button.waitForExistence(timeout: 5) else { print("UI_STEP_MISSING sweep tab \(tab)"); continue }
            button.tap(); sleep(2)
            sweep(tab, depth: 0)
        }
        // Suggestions list, the screen that had dead rows.
        tabButton("Übersicht").tap(); sleep(1)
        let suggestions = button("Vorschläge prüfen")
        if suggestions.waitForExistence(timeout: 5) {
            suggestions.tap(); sleep(2)
            sweep("Vorschläge", depth: 0, strict: true)
            back()
        }
        print("UI_SWEEP_DONE")
    }
}
