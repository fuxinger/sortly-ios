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

    /// The first suggestion row of a list ("57 Aufnahmen" is in every row, never in a button).
    private func suggestionRow() -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", "Aufnahmen")).element(boundBy: 0)
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
            // Cities can be chosen right at the start (off by default).
            let cities = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Städte")).firstMatch
            print(cities.waitForExistence(timeout: 3) ? "UI_STEP_OK cities switch in onboarding" : "UI_STEP_MISSING cities switch in onboarding")
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

        // Fuchs, 14.11.: looking at the starter set and going back must not select anything.
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ Alben (kostenlos )?anlegen")).firstMatch
        if starter.waitForExistence(timeout: 5) {
            tap(starter, "open starter set")
            let preview = app.navigationBars["Umsetzen"].waitForExistence(timeout: 20)
            print(preview ? "UI_STEP_OK starter preview opened" : "UI_STEP_MISSING starter preview opened")
            sleep(2); shot("06c-starter-plan")
            back(); sleep(2)
            let leftover = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ausgewählte")).firstMatch.exists
            print(leftover ? "UI_STEP_MISSING nothing selected after starter preview" : "UI_STEP_OK nothing selected after starter preview")
            XCTAssertFalse(leftover, "Going back from the starter preview left suggestions selected")
            shot("06d-back-from-starter")
        } else {
            print("UI_STEP_MISSING starter set card")
        }

        // Suggestions
        if tap(button("Vorschläge prüfen"), "open suggestions", timeout: 20) {
            sleep(1)
            shot("07-suggestions"); audit("suggestions")
            // Rows live in a List (collection view), not a scroll view. The first cell can be
            // the "N empfohlene auswählen" button, so pick the first real suggestion row.
            let first = suggestionRow()
            if tap(first, "open first suggestion", timeout: 10) {
                sleep(1)
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK suggestion detail opened" : "UI_STEP_MISSING suggestion detail opened")
                XCTAssertTrue(opened, "Tapping a suggestion did not open its detail")
                shot("08-suggestion-detail"); audit("suggestion detail")
                // "Album anlegen" opens a preview; back without creating selects nothing.
                let create = app.buttons["Album anlegen"]
                if create.exists {
                    create.tap()
                    if app.navigationBars["Umsetzen"].waitForExistence(timeout: 20) { sleep(1); back(); sleep(1) }
                }
                back(); sleep(1)
                let selected = suggestionRow().label.contains("Ausgewählt")
                print(selected ? "UI_STEP_MISSING nothing selected after single preview" : "UI_STEP_OK nothing selected after single preview")
                XCTAssertFalse(selected, "Going back from a single preview left the suggestion selected")
                let list = app.navigationBars["Vorschläge"].waitForExistence(timeout: 5)
                print(list ? "UI_STEP_OK back to suggestions" : "UI_STEP_MISSING back to suggestions")
                XCTAssertTrue(list, "Back from a suggestion did not return to the list")
                shot("08b-back-to-list")
            }
            if tap(button("empfohlene auswählen"), "accept recommended") {
                sleep(1)
                shot("09-accepted")
            }
            back(); sleep(1)
        }

        // Area list: open a suggestion and come back (reported: rows not tappable, warning triangle on back)
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        if tap(travel, "open travel area", timeout: 10) {
            sleep(1)
            if tap(suggestionRow(), "open trip suggestion", timeout: 10) {
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
        if tap(button("ausgewählte Alben anlegen"), "open plan", timeout: 20) {
            sleep(3)
            shot("10-plan"); audit("plan")
            // The plan names every album it will make, not only the counts.
            let list = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diese Alben werden")).firstMatch
            print(list.waitForExistence(timeout: 5) ? "UI_STEP_OK plan lists albums" : "UI_STEP_MISSING plan lists albums")
            if list.exists {
                app.swipeUp(); sleep(1)
                shot("10a-plan-albums")
                app.swipeDown(); sleep(1)
            }
            if tap(button("Jetzt umsetzen"), "apply plan", timeout: 30) {
                let applied = Date()
                // Mid-show frames of "photos fly into albums".
                usleep(1_100_000); shot("10b-show")
                usleep(900_000); shot("10c-show")
                XCTAssertTrue(button("Rückgängig machen").waitForExistence(timeout: 900), "Plan did not finish")
                print("UI_TIMING apply \(Int(Date().timeIntervalSince(applied))) s")
                sleep(1)
                shot("11-result"); audit("result")
                // The change receipt: what really changed, from the execution journal.
                let receipt = app.buttons["result.receipt"]
                if !receipt.isHittable { app.swipeUp(); sleep(1) }
                if tap(receipt, "open change receipt", timeout: 10) {
                    sleep(2)
                    let checked = anything("0 Originale gelöscht").waitForExistence(timeout: 5)
                    print(checked ? "UI_STEP_OK receipt shows originals untouched" : "UI_STEP_MISSING receipt shows originals untouched")
                    shot("11a-receipt"); audit("receipt")
                    app.swipeUp(); sleep(1)
                    shot("11b-receipt-albums")
                    back(); sleep(1)
                }
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
                // Close the keyboard: it covers the tab bar, and a tap on "Übersicht" would hit it.
                field.typeText("\n")
                sleep(1)
            }
        }

        // Settings and undo
        if tap(tabButton("Übersicht"), "overview tab") {
            if tap(app.buttons["Einstellungen"], "settings") {
                sleep(1)
                shot("21-settings"); audit("settings")
                // The history sits far down in a lazy list: its rows exist only once scrolled to.
                let row = app.buttons["history.row"].firstMatch
                let list = app.collectionViews.firstMatch
                var swipes = 0
                while !(row.exists && row.isHittable) && swipes < 10 {
                    (list.exists ? list : app).swipeUp()
                    swipes += 1
                }
                // A history row opens the plan's change receipt; undo lives there.
                let opened = tap(row, "history row opens receipt", timeout: 10)
                if opened { sleep(2); shot("21a-history-receipt") }
                let undo = app.buttons["receipt.undo"]
                if opened && !undo.exists {
                    var more = 0
                    while !undo.exists && more < 6 { app.swipeUp(); more += 1 }
                }
                if opened, tap(undo, "undo in receipt", timeout: 10) {
                    // Another "Rückgängig machen" (the result card further back) can exist in
                    // the hierarchy; tap the one in the dialog that is really on screen.
                    let dialog = app.staticTexts["Diese Änderungen rückgängig machen?"].waitForExistence(timeout: 5)
                    print(dialog ? "UI_STEP_OK undo dialog" : "UI_STEP_MISSING undo dialog")
                    shot("21b-undo-dialog")
                    let confirms = app.buttons.matching(identifier: "Rückgängig machen").allElementsBoundByIndex
                    print("UI_FACT undo confirm buttons \(confirms.count), hittable \(confirms.filter(\.isHittable).count)")
                    if let confirm = confirms.first(where: \.isHittable) {
                        confirm.tap()
                        print("UI_STEP_OK confirm undo")
                    } else {
                        print("UI_STEP_MISSING confirm undo")
                    }
                    // iOS asks before an app deletes albums. All albums go in one request, so
                    // this must be one question, not one per album.
                    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    var questions = 0
                    let end = Date().addingTimeInterval(40)
                    while Date() < end {
                        let alert = springboard.alerts.firstMatch
                        if alert.waitForExistence(timeout: 3) {
                            if questions == 0 { shot("22-delete-question") }
                            let delete = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Löschen"])).firstMatch
                            if delete.exists { delete.tap(); questions += 1; sleep(2) } else { break }
                        } else if app.staticTexts["Rückgängig gemacht"].exists {
                            break
                        }
                    }
                    print("UI_FACT undo questions \(questions)")
                    XCTAssertLessThanOrEqual(questions, 1, "Undo asked more than once before deleting albums")
                    let undone = app.staticTexts["Rückgängig gemacht"].waitForExistence(timeout: 30)
                    print(undone ? "UI_STEP_OK undo finished" : "UI_STEP_MISSING undo finished")
                    if !undone {
                        for alert in app.alerts.allElementsBoundByIndex { print("UI_FACT app alert \(alert.label)") }
                        shot("22-undo-not-finished")
                    }
                    XCTAssertTrue(undone, "Undo did not finish")
                    // The receipt now ends with what the undo removed.
                    app.swipeUp(); app.swipeUp(); sleep(1)
                    shot("22-after-undo")
                }
                if opened { back(); sleep(1) }
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
                             "Übernehmen", "Nicht jetzt", "ergänzen", "so lassen", "Fortsetzen", "Beispiel", "Ignorieren", "Auswählen",
                             "aufheben"]

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

    // MARK: Safety backup

    /// Fourth run: the decisions of the earlier runs are copied when the app goes to the
    /// background, the database is then set aside (as with "Neu aufbauen") and the next start
    /// must bring the decisions and the history back and say so.
    func test4_DecisionsComeBackAfterRebuild() {
        continueAfterFailure = true
        launch(["-SortlyUITestBackup"])
        sleep(5)
        // Going to the background writes the copy.
        XCUIDevice.shared.press(.home)
        sleep(4)
        launch(["-SortlyUITestBackup", "-SortlyUITestRebuildDatabase"])
        let card = app.staticTexts["Entscheidungen zurückgeholt"]
        let restored = card.waitForExistence(timeout: 30)
        print(restored ? "UI_STEP_OK restored card" : "UI_STEP_MISSING restored card")
        XCTAssertTrue(restored, "The decisions did not come back after the database was rebuilt")
        // The analysis starts again right away, as after a real rebuild.
        sleep(4)
        shot("40-restored-card"); audit("restored card")
        let withHistory = anything("Alben und den Verlauf aus der Sicherung").exists
        print("UI_FACT restore included history \(withHistory)")
        XCTAssertTrue(withHistory, "Album records and history were not restored into the same library")

        // The history is back and the settings say when the copy was made.
        if tap(app.buttons["Einstellungen"], "settings after restore") {
            sleep(1)
            let list = app.collectionViews.firstMatch
            let saved = anything("Zuletzt gesichert")
            var swipes = 0
            while !saved.exists && swipes < 10 {
                (list.exists ? list : app).swipeUp()
                swipes += 1
            }
            print(saved.exists ? "UI_STEP_OK backup date in settings" : "UI_STEP_MISSING backup date in settings")
            let empty = app.staticTexts["Noch keine Änderungen"].exists
            print("UI_FACT history empty after restore \(empty)")
            XCTAssertFalse(empty, "The history is empty after the restore")
            shot("41-settings-backup")
            tap(button("Fertig"), "close settings after restore")
        }
        if tap(app.buttons["overview.restoredFromBackup.ok"], "dismiss restored card") {
            sleep(1)
            let gone = !card.exists
            print(gone ? "UI_STEP_OK restored card dismissed" : "UI_STEP_MISSING restored card dismissed")
            XCTAssertTrue(gone, "The restored card did not go away")
        }
    }

    /// Fifth run: the app is closed while a plan runs. The next start offers to continue,
    /// undo or leave it; "So lassen" keeps what was done, the change receipt says so and
    /// "Fehlendes erneut versuchen" makes a plan with only the missing steps.
    func test5_InterruptedPlanCanBeLeftAndRetried() {
        continueAfterFailure = true
        launch()
        _ = waitStable("analysis idle before interruption", timeout: 120) { analysisIdle }
        // Select something to apply: the selection of earlier runs, else the recommended ones.
        var apply = button("ausgewählte Alben anlegen")
        if !apply.waitForExistence(timeout: 5), tap(button("Vorschläge prüfen"), "open suggestions for interruption", timeout: 20) {
            sleep(1)
            if button("empfohlene auswählen").waitForExistence(timeout: 5) { button("empfohlene auswählen").tap(); sleep(1) }
            back(); sleep(1)
            apply = button("ausgewählte Alben anlegen")
        }
        guard tap(apply, "open plan for interruption", timeout: 20) else { return }
        sleep(3)
        guard tap(button("Jetzt umsetzen"), "start plan for interruption", timeout: 30) else { return }
        // The run takes about 16 s; closing the app after 3 s leaves it half done.
        sleep(3)
        app.terminate()
        sleep(2)
        launch()
        let card = anything("Umsetzen wurde unterbrochen")
        guard card.waitForExistence(timeout: 30) else {
            // The plan finished before the app was closed: nothing to repair in this run.
            print("UI_FACT no interruption card (plan finished before the app was closed)")
            return
        }
        print("UI_STEP_OK interruption card")
        sleep(1)
        shot("50-interrupted"); audit("interrupted card")
        let keep = app.buttons["interrupted.keep"]
        if !keep.isHittable { app.swipeUp(); sleep(1) }
        guard tap(keep, "leave interrupted plan as it is") else { return }
        let gone = waitGone(card, timeout: 30)
        print(gone ? "UI_STEP_OK interruption card gone after keep" : "UI_STEP_MISSING interruption card gone after keep")
        XCTAssertTrue(gone, "The interruption card stayed after \"So lassen\"")

        // The kept plan is the newest history row; its receipt says what is missing.
        guard tap(app.buttons["Einstellungen"], "settings after keep") else { return }
        sleep(1)
        let row = app.buttons["history.row"].firstMatch
        let list = app.collectionViews.firstMatch
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 10 {
            (list.exists ? list : app).swipeUp()
            swipes += 1
        }
        guard tap(row, "kept plan in history", timeout: 10) else { return }
        sleep(2)
        let partial = anything("Teilweise umgesetzt").waitForExistence(timeout: 5)
        print(partial ? "UI_STEP_OK kept plan is partial" : "UI_STEP_MISSING kept plan is partial")
        XCTAssertTrue(partial, "The kept plan does not say it is partial")
        shot("51-kept-receipt"); audit("kept receipt")
        let retry = app.buttons["receipt.retry"]
        var more = 0
        while !(retry.exists && retry.isHittable) && more < 6 { app.swipeUp(); more += 1 }
        sleep(1)
        shot("52-receipt-repair")
        guard tap(retry, "retry missing steps", timeout: 10) else { return }
        let plan = app.navigationBars["Umsetzen"].waitForExistence(timeout: 20)
        print(plan ? "UI_STEP_OK retry plan opened" : "UI_STEP_MISSING retry plan opened")
        XCTAssertTrue(plan, "\"Fehlendes erneut versuchen\" did not open a plan")
        sleep(2)
        shot("53-retry-plan"); audit("retry plan")
        if tap(button("Jetzt umsetzen"), "apply retry plan", timeout: 30) {
            let done = button("Rückgängig machen").waitForExistence(timeout: 300)
            print(done ? "UI_STEP_OK retry plan finished" : "UI_STEP_MISSING retry plan finished")
            XCTAssertTrue(done, "The retry plan did not finish")
            sleep(1)
            shot("54-retry-result")
        }
    }
}
