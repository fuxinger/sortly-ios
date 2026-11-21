import XCTest
import UIKit

/// End-to-end run on the simulator: onboarding, demo library, analysis, accepting
/// suggestions, creating albums, atlas, library, search, settings and undo.
/// Every step prints `UI_STEP_OK` / `UI_STEP_MISSING`, screenshots are printed as
/// `PREVIEW_JPEG ui-…` chunks and accessibility audit findings as `A11Y_ISSUE` lines,
/// so the CI log is the whole report (artifact downloads are not available to us).
/// CI runs groups of these tests on separate simulators, so each test sets itself up:
/// test1_FullFlow goes through the real onboarding and seeding, the others start with
/// `prepare()` (fast start, demo library) and make the state they need themselves.
@MainActor
final class AlbumistFlowUITests: XCTestCase {
    private var app = XCUIApplication()

    // MARK: Helpers

    private func launch(_ extra: [String] = []) {
        // UITestAppEnd.launch ends the app of the last launch first.
        app = XCUIApplication()
        // The stall file also gives the Mac the app's process id to end it by (`UITestAppEnd`).
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-AlbumistUITestUnlocked"]
            + UITestStalls.arguments(besides: extra) + extra
        UITestAppEnd.launch(app)
    }

    /// The first suggestion row of a list ("57 Fotos" is in every row, never in a button).
    private func suggestionRow() -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos?")).element(boundBy: 0)
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// "16 Vorschläge prüfen", or "1 Vorschlag prüfen" once a single suggestion is left open
    /// (UI run 43796844064: the locked run after a complete flow found only the singular).
    private func reviewSuggestionsButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9.]+ Vorschl(ag|äge) prüfen.*")).firstMatch
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
            // The tab bar has expanded (at most the second the fixed pause gave it); the loop checks.
            _ = UITestWait.holds(timeout: 1) { button.exists && button.isHittable }
            tries += 1
        }
        return button
    }

    /// The tab bar can be tapped (it is hidden while photos are selected, as in Photos).
    private func tabBarHittable() -> Bool {
        let bar = app.tabBars.firstMatch
        return bar.exists && bar.isHittable
    }

    /// The actions of a suggestion besides its two buttons ("Album anlegen", "Nicht jetzt"): in
    /// the "…" menu at the top right since review P3-06.
    private static let menuActions = ["Anpassen", "Auswählen und später anlegen", "Reise teilen oder zusammenlegen",
                                      "Keine Reise, hier bin ich öfter"]

    /// The "…" button at the top right of a suggestion, by its identifier or, where the toolbar
    /// does not pass that on, by its name.
    private func moreActionsButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "proposal.more", "Weitere Aktionen")).firstMatch
    }

    /// An item of the open "…" menu, by its identifier or by the start of its name: an item with
    /// a second line ("Keine Reise, hier bin ich öfter" and why it waits) may be named with both.
    private func menuItem(_ identifier: String, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", identifier, title)).firstMatch
    }

    /// Waits until `element` is there (and can be tapped, if `tappable`) and stays where it is from
    /// one check to the next (half a second apart): an opening menu or dialog has come to rest
    /// before its picture, without a fixed sleep.
    @discardableResult
    private func settled(_ element: XCUIElement, _ what: String, tappable: Bool = true, timeout: TimeInterval = 5) -> Bool {
        var last: CGRect?
        return UITestWait.until(what, timeout: timeout) {
            guard element.exists, !tappable || element.isHittable else { last = nil; return false }
            let frame = element.frame
            defer { last = frame }
            return frame == last
        }
    }

    /// Closes the dialog that shows `title` without an answer: its "Abbrechen", or where iOS shows
    /// none (a dialog as a popover), the region around the popover or a tap at the top of the
    /// screen, which only closes it.
    @discardableResult
    private func closeDialog(_ title: XCUIElement, _ what: String) -> Bool {
        let cancel = app.buttons["Abbrechen"]
        let around = app.otherElements["PopoverDismissRegion"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else if around.exists {
            around.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        }
        return UITestWait.disappears(title, what, timeout: 5)
    }

    /// Taps an item of the open menu where it is: `tap(_:_:)` swipes to bring an element into
    /// view, and a swipe would close the menu. A missing item closes the menu again.
    @discardableResult
    private func tapMenuItem(_ item: XCUIElement, _ step: String) -> Bool {
        guard item.waitForExistence(timeout: 5) else {
            print("UI_STEP_MISSING \(step)")
            shot("x-missing-" + step.replacingOccurrences(of: " ", with: "-"))
            XCTFail("Missing: \(step)")
            // A tap at the left edge closes the menu; if it reached the page, it hits no button.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
            return false
        }
        UITestOnboarding.clock("tap \(step)")
        item.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    /// Review P3-06 (screenshot ui-08c-trip-detail): a suggestion showed up to six actions in a
    /// column, the last half behind the tab bar. Its page now has "Nicht jetzt" beside the
    /// primary button and none of the other actions, and the "…" menu at the top right is there
    /// to tap.
    private func checkTwoActionsAndMenu(_ what: String) {
        let more = moreActionsButton()
        // Hittable once the pushed page has come to rest, not in the first look after the push.
        let menu = UITestWait.until("\(what) has the \"…\" menu to tap", timeout: 5) { more.exists && more.isHittable }
        let onPage = Self.menuActions.filter { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", $0)).firstMatch.exists }
        let notNow = app.buttons.matching(NSPredicate(format: "label == %@", "Nicht jetzt")).firstMatch.exists
        let shown = onPage.isEmpty && menu && notNow
        print(shown ? "UI_STEP_OK \(what) shows two actions and the menu"
                    : "UI_STEP_MISSING \(what) shows two actions and the menu (on the page \(onPage), menu \(menu), Nicht jetzt \(notNow))")
        // A "…" not there in time has failed in the wait already.
        XCTAssertTrue(onPage.isEmpty, "The \(what) shows \(onPage) on the page instead of in the \"…\" menu")
        XCTAssertTrue(notNow, "The \(what) shows no \"Nicht jetzt\"")
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
            if UITestWait.underNavigationBar(element, bar) { app.swipeDown() } else if !element.isHittable { app.swipeUp() } else { break }
            swipes += 1
        }
        UITestOnboarding.clock("tap \(step)")
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// The preview's next step is in reach as it opens, without scrolling and clear of the tab
    /// bar: "Alben jetzt anlegen" in the bar at the bottom, or the unlock card at the top of the
    /// plan in its place (review P3-05 = G3-05: both stood at the end of the plan, below the
    /// fold). Content under the tab bar counts as hittable for XCUITest, so the frame is read too.
    @discardableResult
    private func expectPlanStartInReach(_ step: String) -> Bool {
        let tabs = app.tabBars.firstMatch
        func inReach(_ element: XCUIElement) -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            return app.frame.contains(frame) && (!tabs.exists || frame.maxY <= tabs.frame.minY + 1)
        }
        let apply = app.buttons["plan.apply"]
        let unlock = app.staticTexts["Albumist freischalten"]
        let reached = UITestWait.until("\(step): start in reach without scrolling", timeout: 30) {
            inReach(apply) || inReach(unlock)
        }
        if !reached {
            print("UI_FACT \(step): button \(apply.exists ? "\(apply.frame)" : "missing"), tab bar \(tabs.exists ? "\(tabs.frame)" : "missing")")
        }
        return reached
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
        UITestOnboarding.clock("audit start \(screen)")
        defer { UITestOnboarding.clock("audit end \(screen)") }
        // The screen first comes to rest (a ring or count still moving after an analysis):
        // an audit of a screen in motion ends the whole test (see `UITestOnboarding`).
        // One snapshot per check (labels and frames); element addresses differ every time.
        var last = ""
        for _ in 0..<6 {
            let tree = app.debugDescription.replacing(#/0x[0-9a-f]+/#, with: "")
            if tree == last { break }
            last = tree
            // pacing: kept, "the same tree a second apart" is the condition, and the six reads
            // (not a time) bound it: on a slow Mac one read of the tree takes seconds.
            sleep(1)
        }
        // An element that changes while the audit reads the screen (a progress bar finishing)
        // makes XCTest record "Failed to get matching snapshot". That says nothing about the app,
        // so only that internal error is expected; every other failure still counts.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("Failed to get matching snapshot") }
        XCTExpectFailure("The screen changed during the accessibility audit", options: options) {
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
    }

    /// The system photo alert, if the simulator still asks (the CI grant does not always hold).
    /// It can take several seconds to appear while it renders its photo preview.
    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        var answered = false
        let done = UITestWait.holds(timeout: 25) {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    print("UI_STEP_OK system photo alert")
                    answered = true
                    return true
                }
            }
            return button("Analyse starten").exists // access was already granted
        }
        if done || answered { return }
        print("UI_STEP_MISSING system photo alert")
    }

    /// A10: the notification question is declined; the app must work just the same (it only
    /// uses notifications to say that a long analysis finished while it was away).
    private func declineNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The question may not come (asked before): no failure either way.
        let declined = UITestWait.holds(timeout: 8) {
            for label in ["Nicht erlauben", "Don’t Allow", "Don't Allow"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
                print("UI_STEP_OK notification alert declined")
                return true
            }
            return false
        }
        if declined { return }
        print("UI_FACT no notification alert")
    }

    /// Polls until `condition` held on `stableChecks` checks in a row (2 s apart).
    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            let asked = Date()
            streak = condition() ? streak + 1 : 0
            UITestOnboarding.reportSlowCheck(since: asked)
            if streak >= stableChecks { return true }
            // pacing: the poll's interval, kept: "`stableChecks` in a row" means the state held
            // over that many 2 s steps (the analysis idle for about four seconds, not only between
            // two batches).
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    /// The overview says the analysis is done ("Alle 412 Fotos analysiert", or "Analyse fertig"
    /// right after a long run) and nothing runs (no "Pause").
    /// The Pause button first: while the analysis runs it is there, and one query answers.
    /// Every other query reads the whole screen, and during the analysis such a read held the
    /// app's main thread for 16 to 48 s (UI run 43979263666: each long stall began within half
    /// a second of a check of this wait).
    private var analysisIdle: Bool {
        !app.buttons["Pause"].exists
            && (anything("Fotos analysiert").exists || anything("Analyse aktuell").exists || anything("Analyse fertig").exists)
    }

    /// The card's progress element (one element, B1): value "120 von 412 Fotos, fertig gegen
    /// 23:40, Schritt 4 von 6, …", as (step, done, total). Read from one snapshot: the element
    /// can go away between an `exists` and reading it, and that read failed test6 (run
    /// 43743310212).
    private func analysisCount() -> (step: Int, done: Int, total: Int)? {
        guard let snapshot = try? app.descendants(matching: .any)["analysis.progress"].firstMatch.snapshot() else { return nil }
        let text = ((snapshot.value as? String) ?? "") + " " + snapshot.label
        let digits = text.replacingOccurrences(of: ".", with: "")
        guard let s = digits.firstMatch(of: #/Schritt (\d+) von \d+/#), let step = Int(s.1),
              let m = digits.firstMatch(of: #/(\d+) von (\d+) /#), let done = Int(m.1), let total = Int(m.2) else { return nil }
        return (step, done, total)
    }

    /// The card's "Details" during the analysis, for one screenshot (review P3-08: the step, the
    /// photos just looked at, whether it runs in the background and the note on town names went
    /// there from the card), then closed again. Skipped with a note when the row is not on
    /// screen: nothing here checks the analysis.
    private func lookAtAnalysisDetails() {
        let details = app.buttons["analysis.details"]
        guard details.exists, details.isHittable else {
            print("UI_FACT analysis details not on screen")
            return
        }
        details.tap()
        let sheet = app.navigationBars["So läuft die Analyse"]
        if !sheet.waitForExistence(timeout: 10) {
            // A sheet that opens late would cover the card for the rest of the test (it reads
            // analysis.progress): it gets 10 s more and is closed like one that opened in time.
            print("UI_FACT analysis details did not open within 10 s")
            guard sheet.waitForExistence(timeout: 10) else { return }
            print("UI_FACT analysis details opened late")
        }
        shot("60a-analysis-details")
        let done = sheet.buttons["Fertig"]
        if done.exists { done.tap() } else { app.swipeDown() }
        if !waitGone(sheet, timeout: 10) {
            app.swipeDown()
            XCTAssertTrue(waitGone(sheet, timeout: 10), "The analysis details did not close")
        }
    }

    // MARK: Setup for tests that run alone

    /// Every test except test1 may be the first on a fresh simulator: the onboarding counts as
    /// done (`-AlbumistUITestFastStart`), the demo library is created and analysed. On a
    /// simulator where that already happened this only waits until nothing runs.
    private func prepare() {
        let started = Date()
        launch(["-AlbumistUITestFastStart"])
        let noAccess = app.buttons["access.continue"]
        // The first screen: the overview, "Kein Zugriff" or the welcome screen, within the 5 s
        // the wait for "Kein Zugriff" alone had. The app picks it once when it has loaded
        // (`AppModel.phase`), so the overview never turns into one of the others and the wait
        // ends when it shows: the 5 s for "Kein Zugriff" alone ran out in every test that found
        // the overview (all but the group's first).
        _ = UITestWait.holds(timeout: 5) {
            app.tabBars.firstMatch.exists || noAccess.exists || button("Los geht").exists
        }
        if noAccess.exists {
            // Photo access is not granted (the CI grant did not hold, or a test took it away):
            // with the introduction done the app shows "Kein Zugriff auf deine Fotos" (W4).
            noAccess.tap()
            allowPhotosIfAsked()
            // Opened once more, so the fast start runs as with access (demo library, if missing).
            launch(["-AlbumistUITestFastStart"])
        } else if button("Los geht").exists {
            // A first start without the fast start's introduction: the real onboarding.
            tap(button("Los geht"), "welcome (prepare)")
            // The areas step is pushed: its "Weiter" (the welcome screen has none) can be tapped.
            // Not asserted: the tap below says it.
            let areasNext = app.buttons["Weiter"]
            _ = UITestWait.holds(timeout: 10) { areasNext.exists && areasNext.isHittable }
            tap(app.buttons["Weiter"], "areas (prepare)")
            if noAccess.waitForExistence(timeout: 5) { noAccess.tap(); allowPhotosIfAsked() }
            if app.buttons["Weiter"].waitForExistence(timeout: 3) { app.buttons["Weiter"].tap() }
            tap(button("Analyse starten"), "start analysis (prepare)", timeout: 20)
            declineNotificationsIfAsked()
        }
        // "Beispiel-Mediathek anlegen" is tapped (once) when it shows in the first 3 s of the
        // wait below (its checks at about 0 and 2 s), the 3 s its own wait had, instead of that
        // wait, which a seeded library waited out in every test. Looked for only in those 3 s:
        // while the analysis runs every query slows the app down (see `analysisIdle`); the
        // condition still says when it is there.
        let demo = button("Beispiel-Mediathek anlegen")
        let demoUntil = Date().addingTimeInterval(3)
        var demoTapped = false
        let ready = waitStable("demo library analysed", timeout: 900) {
            if !demoTapped, Date() < demoUntil, demo.exists, !anything("Beispielfotos werden angelegt").exists {
                demoTapped = true
                demo.tap()
                return false
            }
            return anything("Fotos analysiert").exists && !app.buttons["Pause"].exists && !anything("Beispielfotos werden angelegt").exists
                && !demo.exists
        }
        print(ready ? "UI_STEP_OK prepared" : "UI_STEP_MISSING prepared")
        XCTAssertTrue(ready, "The demo library was not created and analysed")
        print("UI_TIMING prepare \(Int(Date().timeIntervalSince(started))) s")
    }

    /// Two photos from the library into a new album: opens its plan ("Umsetzen").
    private func openManualPlan(_ title: String) -> Bool {
        guard tap(tabButton("Mediathek"), "library for \(title)") else { return false }
        let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
        // The first pass over the library comes before the photos (`library.preparing`): up to
        // the two seconds the fixed pause gave it, then the five below, as before.
        _ = UITestWait.holds(timeout: 2) { photos.firstMatch.exists }
        if !photos.firstMatch.waitForExistence(timeout: 5) {
            tap(app.buttons["Alle"], "all photos for \(title)", timeout: 5)
            // Every photo of the library (not asserted: the count below is).
            _ = UITestWait.holds(timeout: 5) { photos.count >= 2 }
        }
        guard tap(app.buttons["Auswählen"], "select photos for \(title)"), photos.count >= 2 else { return false }
        photos.element(boundBy: 0).tap()
        photos.element(boundBy: 1).tap()
        guard tap(button("Zu Album hinzufügen"), "add to album for \(title)") else { return false }
        var field = app.textFields["Name des neuen Albums"]
        if !field.waitForExistence(timeout: 5) { field = app.textFields.firstMatch }
        guard tap(field, "name for \(title)") else { return false }
        field.typeText(title)
        guard tap(app.buttons["Anlegen"], "create \(title)") else { return false }
        return app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
    }

    /// Opens the plan of the recommended suggestions (or of what is selected already); a new
    /// album of two photos when nothing is recommended.
    private func openRecommendedPlan(_ what: String) -> Bool {
        var apply = button("ausgewählte Alben anlegen")
        // "16 Vorschläge prüfen", or "1 Vorschlag prüfen" when one is left.
        let open = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Vorschl(ag|äge) prüfen")).firstMatch
        if !apply.waitForExistence(timeout: 5), open.waitForExistence(timeout: 10), tap(open, "open suggestions for \(what)") {
            let list = app.navigationBars["Vorschläge"]
            let recommended = button("empfohlene auswählen")
            // The list is pushed; its "empfohlene auswählen" (when something is recommended) is
            // looked for below, and tapped once it can be.
            _ = UITestWait.holds(timeout: 10) { list.exists }
            if recommended.waitForExistence(timeout: 5) {
                _ = UITestWait.holds(timeout: 5) { recommended.isHittable }
                recommended.tap()
                // The list offers "N ausgewählte Alben anlegen" once something is selected;
                // whether it is, the wait for it after going back says.
                _ = button("ausgewählte Alben anlegen").waitForExistence(timeout: 5)
            }
            back()
            // pacing: kept, the list has its own "ausgewählte Alben anlegen" at the bottom and
            // the one below must be the overview's; the bar swaps when the pop starts, so its
            // end is not seen (review), and the second lets the list leave.
            sleep(1)
            apply = button("ausgewählte Alben anlegen")
        }
        if apply.waitForExistence(timeout: 5) {
            guard tap(apply, "open plan for \(what)", timeout: 20) else { return false }
            // The plan's screen, not a fixed 3 s (the callers tap "Jetzt umsetzen" on it next).
            return UITestWait.appears(app.navigationBars["Vorschau"], "plan screen for \(what)", timeout: 30)
        }
        print("UI_FACT nothing recommended for \(what): a new album of two photos instead")
        return openManualPlan("Testalbum \(what)")
    }

    /// The plan screen shows its content, not only its bar: the start button, the unlock card,
    /// the list of albums it makes, or "Nichts zu tun" when there is no plan ("Plan wird
    /// erstellt" comes before them).
    private func planContentShown() -> Bool {
        app.buttons["plan.apply"].exists || app.staticTexts["Albumist freischalten"].exists
            || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diese Alben werden")).firstMatch.exists
            || app.staticTexts["Nichts zu tun"].exists
    }

    /// Applies a plan, so the history holds one; the app is started again afterwards.
    @discardableResult
    private func applyRecommended(_ what: String, relaunchWith extra: [String] = []) -> Bool {
        guard openRecommendedPlan(what), tap(app.buttons["plan.apply"], "apply plan for \(what)", timeout: 30) else { return false }
        let done = button("Rückgängig machen").waitForExistence(timeout: 900)
        print(done ? "UI_STEP_OK plan for \(what) finished" : "UI_STEP_MISSING plan for \(what) finished")
        XCTAssertTrue(done, "The plan for \(what) did not finish")
        // pacing: kept, the app stores the finished plan (history, free albums) after the result
        // shows; no element says it is written, and the launch below ends the app.
        sleep(2)
        launch(extra)
        return done
    }

    // MARK: Tests

    /// The demo library is fully readable: the analysis card says "Alle N Fotos analysiert"
    /// and no photo counts as unreadable. UI runs reported "0 von 246 Fotos analysiert" and
    /// "246 Fotos konnten noch nicht gelesen werden" for weeks without failing.
    private func assertEveryPhotoAnalysed(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Alle ", "Fotos analysiert")).firstMatch
        _ = card.waitForExistence(timeout: 10)
        // Any other analysis line (e.g. "0 von 246 Fotos analysiert") is printed for the log.
        let other = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fotos analysiert")).firstMatch
        print("UI_FACT analysis card \(when): \(card.exists ? card.label : "not found (\(other.exists ? other.label : "-"))") | \(card.exists ? (card.value as? String ?? "-") : "-")")
        let unreadable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "konnten noch nicht gelesen")).firstMatch
        if unreadable.exists { print("UI_FACT unreadable \(when): \(unreadable.label)") }
        let all = card.exists && card.label.hasPrefix("Alle ")
        print(all && !unreadable.exists ? "UI_STEP_OK every photo analysed \(when)" : "UI_STEP_MISSING every photo analysed \(when)")
        XCTAssertTrue(card.exists, "No analysis card \(when)", file: file, line: line)
        XCTAssertTrue(all, "Not every demo photo analysed \(when): \(card.label)", file: file, line: line)
        XCTAssertFalse(unreadable.exists, "Demo photos unreadable \(when): \(unreadable.label)", file: file, line: line)
    }

    /// Set by test 1 at its start and its end; the runner keeps them for the later tests.
    /// An audit that meets a screen in motion makes XCTest record "Failed to get matching
    /// snapshot" (expected in `audit`), and that issue ends the test method: test 1 then
    /// "passed" after the overview audit having done nothing more (runs 43773339053 and
    /// 43804947107: no "A11Y_AUDIT_DONE overview", no plan applied, so test 4's backup had
    /// no history to bring back). Test 2 reports such a cut-off test 1 as a failure. The
    /// markers are files (`UITestOnboarding`): run 43816787321 lost the test runner inside
    /// test 1, and the restarted runner began with fresh static flags.

    /// The first start as a user sees it: onboarding (notifications declined), demo library,
    /// analysis, overview, starter set, suggestions, the trip list, applying and the receipt.
    func test1_FullFlow() {
        continueAfterFailure = true
        UITestOnboarding.fullFlowStarts()
        // Test 1 runs first on a freshly erased simulator (its own group in ui.yml, and a repeat
        // after a simulator failure erases it again). An issue that ends the method early (an
        // audit meeting a screen in motion) would otherwise let it pass without its later checks;
        // this replaces the check test 2 made while both ran in one job.
        let end = UITestOnboarding.fullFlow.finished
        addTeardownBlock {
            if !FileManager.default.fileExists(atPath: end.path) {
                print("UI_STEP_MISSING full flow reached its end")
                XCTFail("test1_FullFlow stopped before its end (an accessibility audit cut it off, or the test runner restarted)")
            }
        }
        launch()

        // Onboarding: a fresh simulator always starts at the welcome screen.
        let welcome = button("Los geht").waitForExistence(timeout: 20)
        if !welcome {
            print("UI_STEP_MISSING welcome screen")
            XCTFail("test1_FullFlow must start on a fresh simulator: no welcome screen, so the onboarding checks did not run")
        }
        if welcome {
            shot("01-welcome"); audit("welcome")
            tap(button("Los geht"), "welcome")
            shot("02-areas")
            // Cities can be chosen right at the start (off by default).
            let cities = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Städte")).firstMatch
            print(cities.waitForExistence(timeout: 3) ? "UI_STEP_OK cities switch in onboarding" : "UI_STEP_MISSING cities switch in onboarding")
            tap(button("Weiter"), "areas")
            shot("03-access")
            // Design review W13: every step after the welcome screen has the system way back.
            if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5) {
                back()
                let areasAgain = app.staticTexts["Was soll Albumist sortieren?"].waitForExistence(timeout: 5)
                print(areasAgain ? "UI_STEP_OK onboarding back to areas" : "UI_STEP_MISSING onboarding back to areas")
                XCTAssertTrue(areasAgain, "Back from the access step did not return to the areas")
                tap(button("Weiter"), "areas again")
            } else {
                print("UI_STEP_MISSING onboarding back button")
                XCTFail("The access step has no back button")
            }
            if app.buttons["access.continue"].waitForExistence(timeout: 5) {
                app.buttons["access.continue"].tap()
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
            declineNotificationsIfAsked()
        }

        // Demo library
        let demo = button("Beispiel-Mediathek anlegen")
        if demo.waitForExistence(timeout: 30) {
            // A fresh simulator holds only its own handful of sample photos, like many App Review
            // devices (plugin review K6): once the first analysis is done, the overview explains
            // why there is nothing to suggest and offers Albumist's sample photos (not tapped:
            // the demo library below is the bigger one).
            let hint = app.descendants(matching: .any)["overview.libraryHint"]
            let explained = hint.waitForExistence(timeout: 120)
            print(explained ? "UI_STEP_OK empty-library hint" : "UI_STEP_MISSING empty-library hint")
            XCTAssertTrue(explained, "A nearly empty library shows no explanation")
            let offer = app.buttons["samples.add"].exists
            print(offer ? "UI_STEP_OK sample photos offered" : "UI_STEP_MISSING sample photos offered")
            XCTAssertTrue(offer, "A nearly empty library does not offer the sample photos")
            shot("05-overview-empty")
            tap(demo, "seed demo library")
            let started = Date()
            // The demo card disappears from the overview once every photo is in the library.
            let seeded = UITestOnboarding.demoLibraryCreated(app)
            XCTAssertTrue(seeded, "Demo library not created")
            print("UI_TIMING seed \(Int(Date().timeIntervalSince(started))) s")
        } else {
            print("UI_STEP_MISSING demo button")
            XCTFail("No \"Beispiel-Mediathek anlegen\" on a fresh simulator: the empty-library checks and the seeding did not run")
        }
        let analysed = Date()
        // Seeding starts a fresh analysis; wait until it ran and the overview stays idle.
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")
        print("UI_TIMING analysis \(Int(Date().timeIntervalSince(analysed))) s")
        assertEveryPhotoAnalysed("after seeding")
        // With every photo readable the suggestions reach the overview a little after the
        // analysis card says done (run 43774578089: the overview changed during its audit,
        // which ended test1 there). The audit waits for them.
        let offers = Date()
        let ready = waitStable("suggestions on the overview", timeout: 180) {
            app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ (Vorschläge|Vorschlag) prüfen|[0-9]+ Alben (kostenlos )?anlegen")).firstMatch.exists
        }
        print("UI_FACT suggestions on the overview \(ready) after \(Int(Date().timeIntervalSince(offers))) s")
        // The demo library holds 12 trips; "1 Reisen" was a real detection bug.
        let teaser = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dein Reise-Atlas")).firstMatch
        if teaser.waitForExistence(timeout: 10) {
            print("UI_FACT atlas \(teaser.label)")
            let trips = teaser.label.firstMatch(of: #/(\d+) Reise/#).flatMap { Int($0.1) } ?? 0
            XCTAssertGreaterThanOrEqual(trips, 8, "Too few trips detected in the demo library: \(teaser.label)")
        }
        shot("06-overview"); audit("overview")
        app.swipeUp()
        // pacing: kept, the scroll comes to rest before the screenshot (only the picture needs
        // it; a wait for a still screen would also fail on content that changes, review).
        sleep(1)
        shot("06b-overview-areas")
        app.swipeDown(); app.swipeDown()

        // Fuchs, 14.11.: looking at the starter set and going back must not select anything.
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ Alben (kostenlos )?anlegen")).firstMatch
        if starter.waitForExistence(timeout: 5) {
            tap(starter, "open starter set")
            let preview = app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
            print(preview ? "UI_STEP_OK starter preview opened" : "UI_STEP_MISSING starter preview opened")
            // The plan's content, not only its bar: the start button, the unlock card or the album
            // list ("Plan wird erstellt" before it). Not asserted: only the screenshot needs it.
            _ = UITestWait.holds(timeout: 20) { planContentShown() }
            if preview { expectPlanStartInReach("starter preview") }
            shot("06c-starter-plan")
            back()
            // pacing: kept, the check below says nothing got selected, and it looks after the
            // old two seconds (a wait for the overview would look sooner).
            sleep(2)
            let leftover = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ausgewählte")).firstMatch.exists
            print(leftover ? "UI_STEP_MISSING nothing selected after starter preview" : "UI_STEP_OK nothing selected after starter preview")
            XCTAssertFalse(leftover, "Going back from the starter preview left suggestions selected")
            shot("06d-back-from-starter")
        } else {
            print("UI_STEP_MISSING starter set card")
        }

        // Suggestions
        if tap(reviewSuggestionsButton(), "open suggestions", timeout: 20) {
            let openedAt = Date()
            let suggestionsBar = app.navigationBars["Vorschläge"]
            // The list with its rows (the audit then waits for a still tree itself). Not
            // asserted: the row is tapped below. The push moves no frame at its end: at least
            // the old second for the screenshot (review).
            _ = UITestWait.holds(timeout: 10) { suggestionsBar.exists && suggestionRow().exists }
            UITestWait.atLeast(1, since: openedAt)
            shot("07-suggestions"); audit("suggestions")
            // Rows live in a List (collection view), not a scroll view. The first cell can be
            // the "N empfohlene auswählen" button, so pick the first real suggestion row.
            let first = suggestionRow()
            if tap(first, "open first suggestion", timeout: 10) {
                // Up to the second of the old pause, then the five below, as before.
                _ = UITestWait.holds(timeout: 1) { app.navigationBars["Vorschlag"].exists }
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK suggestion detail opened" : "UI_STEP_MISSING suggestion detail opened")
                XCTAssertTrue(opened, "Tapping a suggestion did not open its detail")
                shot("08-suggestion-detail"); audit("suggestion detail")
                // Design review D3: every photo of a suggestion is a named button (its date),
                // so VoiceOver and Voice Control can pick photos to take out.
                let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alle ")).firstMatch
                if tap(all, "open all photos of the suggestion", timeout: 5) {
                    let photo = app.buttons["proposalPhotos.photo"].firstMatch
                    let named = photo.waitForExistence(timeout: 5) && photo.label.range(of: "20[0-9][0-9]", options: .regularExpression) != nil
                    print(named ? "UI_STEP_OK suggestion photos are named buttons (\(photo.label))" : "UI_STEP_MISSING suggestion photos are named buttons")
                    XCTAssertTrue(named, "The photos of a suggestion are not buttons named by their date")
                    if tap(button("Auswählen"), "select photos of the suggestion", timeout: 5) {
                        photo.tap()
                        XCTAssertTrue(photo.isSelected, "A selected photo does not report the selected trait")
                        shot("08a-suggestion-photos"); audit("suggestion photos")
                        tap(button("Fertig"), "end photo selection")
                    }
                    back()
                    // Back on the detail: the photos of that screen are gone (not asserted).
                    _ = UITestWait.holds(timeout: 5) { !photo.exists }
                }
                // "Album anlegen" opens a preview; back without creating selects nothing.
                let create = app.buttons["Album anlegen"]
                if create.exists {
                    create.tap()
                    let singlePreview = app.navigationBars["Vorschau"]
                    if singlePreview.waitForExistence(timeout: 20) {
                        // The preview's content, as a user sees it before going back (not asserted).
                        _ = UITestWait.holds(timeout: 10) { planContentShown() }
                        back()
                        // Back on the detail: its "Album anlegen" can be tapped again (not
                        // asserted: the way back goes on).
                        _ = UITestWait.holds(timeout: 5) { create.exists && create.isHittable }
                    }
                }
                back()
                // pacing: kept, the check below says nothing got selected, and it looks after the
                // old second (a wait for the list would look sooner).
                sleep(1)
                let selected = suggestionRow().label.contains("Ausgewählt")
                print(selected ? "UI_STEP_MISSING nothing selected after single preview" : "UI_STEP_OK nothing selected after single preview")
                XCTAssertFalse(selected, "Going back from a single preview left the suggestion selected")
                let list = app.navigationBars["Vorschläge"].waitForExistence(timeout: 5)
                print(list ? "UI_STEP_OK back to suggestions" : "UI_STEP_MISSING back to suggestions")
                XCTAssertTrue(list, "Back from a suggestion did not return to the list")
                shot("08b-back-to-list")
            }
            if tap(button("empfohlene auswählen"), "accept recommended") {
                // The list offers "N ausgewählte Alben anlegen" once something is selected (not
                // asserted: the plan below needs it and says so).
                _ = button("ausgewählte Alben anlegen").waitForExistence(timeout: 5)
                shot("09-accepted")
            }
            back()
        }

        // Area list: open a suggestion and come back (reported: rows not tappable, warning triangle on back)
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        // Back on the overview: its travel area can be tapped (not asserted: the tap below is).
        _ = UITestWait.holds(timeout: 10) { travel.exists && travel.isHittable }
        if tap(travel, "open travel area", timeout: 10) {
            // The area's list is pushed (the overview has no list rows); its first row can be
            // tapped. Not asserted: the tap below says it.
            _ = UITestWait.holds(timeout: 10) { suggestionRow().exists && suggestionRow().isHittable }
            if tap(suggestionRow(), "open trip suggestion", timeout: 10) {
                let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
                print(opened ? "UI_STEP_OK trip detail opened" : "UI_STEP_MISSING trip detail opened")
                XCTAssertTrue(opened, "Tapping a trip suggestion did not open its detail")
                shot("08c-trip-detail")
                checkTwoActionsAndMenu("trip")
                back()
                // pacing: kept, the pop ends before the screenshot (the bar swaps when it starts)
                sleep(1)
                shot("08d-back-to-trips")
            }
            back()
            // pacing: kept, the trip list has its own "ausgewählte Alben anlegen", and the tap
            // below must find the overview's; the second lets the list leave the screen.
            sleep(1)
        }

        // Apply
        if tap(button("ausgewählte Alben anlegen"), "open plan", timeout: 20) {
            let shownAt = Date()
            // The plan names every album it will make, not only the counts.
            let list = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diese Alben werden")).firstMatch
            // The plan's content before the audit, not only its bar (second review of C2): the
            // start button, the unlock card or the album list; and at least the old 3 s.
            UITestWait.until("plan screen shown", timeout: 30) {
                app.buttons["plan.apply"].exists || app.staticTexts["Albumist freischalten"].exists || list.exists
            }
            UITestWait.atLeast(3, since: shownAt)
            expectPlanStartInReach("plan")
            shot("10-plan"); audit("plan")
            print(list.waitForExistence(timeout: 5) ? "UI_STEP_OK plan lists albums" : "UI_STEP_MISSING plan lists albums")
            if list.exists {
                app.swipeUp()
                // pacing: kept, the scroll comes to rest before the screenshot, and after the
                // swipe back before the tap on "Jetzt umsetzen" measures its place.
                sleep(1)
                shot("10a-plan-albums")
                app.swipeDown()
                // pacing: kept (as above)
                sleep(1)
            }
            if tap(app.buttons["plan.apply"], "apply plan", timeout: 30) {
                let applied = Date()
                // Mid-show frames of "photos fly into albums".
                // pacing: kept, the screenshots are meant to fall 1.1 s and 2 s into the show
                usleep(1_100_000); shot("10b-show")
                // pacing: kept (as above)
                usleep(900_000); shot("10c-show")
                XCTAssertTrue(button("Rückgängig machen").waitForExistence(timeout: 900), "Plan did not finish")
                print("UI_TIMING apply \(Int(Date().timeIntervalSince(applied))) s")
                // pacing: kept, the result card fades and scales in after the show (PlanReviewView);
                // a fade moves no frame and no element says it is done.
                sleep(1)
                shot("11-result"); audit("result")
                // The change receipt: what really changed, from the execution journal.
                let receipt = app.buttons["result.receipt"]
                if !receipt.isHittable {
                    app.swipeUp()
                    // pacing: kept, the scroll comes to rest before the tap measures the button's place
                    sleep(1)
                }
                if tap(receipt, "open change receipt", timeout: 10) {
                    // The receipt loads after the screen opens (an empty list until then); its share
                    // button comes with the loaded receipt. Not asserted: the check below is.
                    _ = UITestWait.holds(timeout: 20) { app.buttons["Liste teilen"].exists }
                    let checked = anything("Kein Original gelöscht").waitForExistence(timeout: 5)
                    print(checked ? "UI_STEP_OK receipt shows originals untouched" : "UI_STEP_MISSING receipt shows originals untouched")
                    shot("11a-receipt"); audit("receipt")
                    app.swipeUp()
                    // pacing: kept, the scroll comes to rest before the screenshot
                    sleep(1)
                    shot("11b-receipt-albums")
                    back()
                    // Back on the result: its receipt button can be tapped (not asserted: the way
                    // back below does not need it).
                    _ = UITestWait.holds(timeout: 5) { receipt.exists && receipt.isHittable }
                }
            }
            back()
            // Back on the overview (not asserted: test 1 ends here).
            _ = UITestWait.holds(timeout: 10) { app.navigationBars["Übersicht"].exists }
        }

        print("UI_FACT notifications declined, the app went on: \(app.state == .runningForeground)")
        // The end of test 1 itself: since the split into 1b-1d (which run in "other flows", on
        // another simulator) the marker was written at the end of 1d, so test 1's teardown
        // check failed every run of the full-flow group (UI run 43964816778).
        UITestOnboarding.fullFlowFinished()
        print("UI_STEP_OK full flow reached its end")
    }

    /// Atlas, library, albums and search on the analysed demo library.
    /// No audits of atlas, country, share card, library, photo, albums and search here: their
    /// audit here only printed findings, and `AccessibilityUITests` audits the same screens and
    /// fails on findings (docs/TEST_PLAN.md, "UI-Tests: Dauer und Verlagerung").
    func test1b_AtlasLibrarySearch() {
        continueAfterFailure = true
        prepare()
        // Travel atlas
        if tap(button("Reise-Atlas"), "open atlas", timeout: 30) {
            UITestWait.appears(app.navigationBars["Reise-Atlas"], "atlas screen", timeout: 30)
            // pacing: the map draws its tiles for the screenshot (the screen is there)
            sleep(3)
            shot("12-atlas")
            app.swipeUp()
            // pacing: kept, the scroll comes to rest before the screenshot
            sleep(1)
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
                // pacing: kept, the photo colour behind the country's title loads and fades in
                // before the screenshot; no element and no frame shows it.
                sleep(1)
                shot("12c-country")
                back()
            }
            let shareAtlas = app.buttons["Reise-Atlas teilen"]
            // Back on the atlas: its share button in the bar can be tapped (not asserted: the
            // tap below says it).
            _ = UITestWait.holds(timeout: 10) { shareAtlas.exists && shareAtlas.isHittable }
            if tap(shareAtlas, "share atlas") {
                let shownAt = Date()
                // The card itself (its preview and the share button), and at least the old 3 s:
                // the outlines and the cover load after the sheet is shown (second review of C2).
                UITestWait.appears(button("Fertig"), "share card with its done button", timeout: 20)
                UITestWait.appears(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Vorschau des Teilen-Bilds")).firstMatch,
                                   "share card preview", timeout: 20)
                UITestWait.atLeast(3, since: shownAt)
                shot("13-share-card")
                tap(button("Fertig"), "close share")
                // pacing: kept, the sheet slides away before the navigation bar answers again
                sleep(2)
            }
            back()
            // Back on the overview: the library tab can be tapped (not asserted: the tab below
            // is looked for either way).
            let libraryTab = app.tabBars.buttons["Mediathek"]
            _ = UITestWait.holds(timeout: 10) { libraryTab.exists && libraryTab.isHittable }
        }

        // Library
        if tap(tabButton("Mediathek"), "library tab") {
            let photo = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
            // pacing: kept, the thumbnails draw into their places before the screenshot; the
            // first button is there before them (review).
            sleep(2)
            shot("14-library")
            // After the plan ran, "Nicht sortiert" can be empty: show the sorted photos instead.
            if !photo.waitForExistence(timeout: 3), tap(button("Sortiert"), "sorted photos") {
                let sortedAt = Date()
                // The sorted photos (not asserted: the tap on one below is), and their thumbnails
                // drawn for the screenshot: at least the old two seconds.
                _ = UITestWait.holds(timeout: 5) { photo.exists }
                UITestWait.atLeast(2, since: sortedAt)
                shot("14b-library-sorted")
            }
            // Design review W11/W12: a tap opens the photo large, its details behind "i",
            // and a pull down closes it, as in Photos.
            if tap(photo, "open photo") {
                let openedAt = Date()
                let info = app.buttons["viewer.info"]
                // The viewer with its "i" free to tap, and the photo itself rather than its
                // spinner ("Foto wird geladen"; only one on screen counts, the pages beside it
                // load their own). Not asserted: the tap below is, and only the screenshot needs
                // the photo.
                let spinners = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Foto wird geladen"))
                _ = UITestWait.holds(timeout: 10) {
                    guard info.exists && info.isHittable else { return false }
                    let screen = app.frame
                    for spinner in spinners.allElementsBoundByIndex {
                        // A snapshot, not `frame`: a spinner that went away meanwhile is no failure.
                        if let seen = try? spinner.snapshot(), screen.contains(CGPoint(x: seen.frame.midX, y: seen.frame.midY)) {
                            return false
                        }
                    }
                    return true
                }
                // The photo zooms out of its thumbnail (no frame shows the end): at least the old 2 s.
                UITestWait.atLeast(2, since: openedAt)
                shot("15-photo-viewer")
                if tap(info, "photo info") {
                    let infoAt = Date()
                    let detailClose = app.buttons["detail.close"]
                    // The info sheet with its close button free to tap (not asserted: the tap is),
                    // and at least the old second for the sheet to slide up for the screenshot.
                    _ = UITestWait.holds(timeout: 10) { detailClose.exists && detailClose.isHittable }
                    UITestWait.atLeast(1, since: infoAt)
                    shot("15a-photo-detail")
                    tap(detailClose, "close photo info")
                    // The sheet has gone, so the pull below reaches the viewer (not asserted: the
                    // viewer's close is).
                    _ = UITestWait.holds(timeout: 10) { !detailClose.exists }
                }
                let close = app.buttons["viewer.close"]
                app.swipeDown(velocity: .slow)
                let closed = waitGone(close, timeout: 5)
                print(closed ? "UI_STEP_OK pull down closes the photo" : "UI_STEP_MISSING pull down closes the photo")
                XCTAssertTrue(closed, "Pulling the photo down did not close it")
                if !closed { closeViewerIfOpen() }
            }
            if tap(button("Auswählen"), "select mode") {
                let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
                if photos.count >= 2 { photos.element(boundBy: 0).tap(); photos.element(boundBy: 1).tap() }
                // Review P3-01 = G3-04: while selecting, the tab bar is gone and the actions are in
                // the system bottom bar, free to tap (a bar of its own floated above the tab bar).
                let add = button("Zu Album hinzufügen")
                // Before the screenshot without failing, at most the old second (the same is
                // asserted right after it with its own 5 s).
                _ = UITestWait.holds(timeout: 1) { add.exists && add.isHittable && !tabBarHittable() }
                shot("16-selection")
                UITestWait.until("library actions free to tap while selecting", timeout: 5) {
                    add.exists && add.isHittable && !tabBarHittable()
                }
                if tap(button("Zu Album hinzufügen"), "add to album") {
                    let addAt = Date()
                    let closeAdd = button("Schließen")
                    // The sheet with its close button free to tap (the audit then waits for a
                    // still tree itself). Not asserted: the tap below is.
                    _ = UITestWait.holds(timeout: 10) { closeAdd.exists && closeAdd.isHittable }
                    // The sheet slides up (no frame shows the end): at least the old 2 s.
                    UITestWait.atLeast(2, since: addAt)
                    shot("17-add-to-album"); audit("add to album")
                    tap(button("Schließen"), "close add")
                }
                tap(button("Fertig"), "end selection")
            }
            ignoreAndUndo()
        }

        // Albums. Until 20.11. this used the albums DeviceConditionUITests 05, 07 and 08 left on
        // the simulator of the same group; since they run in "device-flows" (UI run 44777850189:
        // "Missing: open an album" on an empty tab), the test makes its own, as test3 does.
        ensureAlbum(for: "the album check")
        if tap(tabButton("Alben"), "albums tab") {
            // Design review W12: an album shows all its photos, and each opens large.
            // An album with photos: an empty one has none to open.
            let album = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(.*[^0-9.])?[1-9][0-9.]* Fotos?")).firstMatch
            // pacing: kept, the album covers draw before the screenshot; the first row is there
            // before them (review).
            sleep(2)
            shot("18-albums")
            if tap(album, "open an album", timeout: 5) {
                let photo = app.buttons["album.photo"].firstMatch
                if tap(photo, "open a photo of the album", timeout: 10) {
                    let viewer = app.buttons["viewer.close"].waitForExistence(timeout: 5)
                    print(viewer ? "UI_STEP_OK album photo opens large" : "UI_STEP_MISSING album photo opens large")
                    XCTAssertTrue(viewer, "A photo of an album does not open")
                    shot("18a-album-photo")
                    closeViewerIfOpen()
                }
                back()
                // Back on the albums: the album's photos are gone (not asserted).
                _ = UITestWait.holds(timeout: 5) { !app.buttons["album.photo"].firstMatch.exists }
            }
        }

        // Search (the system names the search tab itself)
        if tap(searchTabButton(), "search tab") {
            let field = app.searchFields.firstMatch
            // The field with the keyboard that comes with it, up to the second of the old pause
            // (then the five below, as before).
            _ = UITestWait.holds(timeout: 1) { field.exists && app.keyboards.firstMatch.exists }
            shot("19-search-empty")
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("Rom")
                // pacing: the results before the screenshot; nothing is asserted on them here
                // (SearchUITests checks the results)
                sleep(3)
                shot("20-search-rom")
                // Close the keyboard: it covers the tab bar, and a tap on "Übersicht" would hit it.
                field.typeText("\n")
                // The keyboard has gone (not asserted: the test ends here).
                _ = UITestWait.holds(timeout: 5) { !app.keyboards.firstMatch.exists }
            }
        }
    }

    /// Undo of a plan from the history in the settings: one question from iOS, everything gone.
    func test1c_UndoFromHistory() {
        continueAfterFailure = true
        prepare()
        applyRecommended("undo")
        // Settings and undo
        if tap(tabButton("Übersicht"), "overview tab") {
            if tap(app.buttons["Einstellungen"], "settings") {
                let settingsAt = Date()
                let historyButton = app.buttons["settings.history"]
                // The settings sheet with its first row free to tap (not asserted: the tap is),
                // and at least the old second for the sheet to slide up for the screenshot.
                _ = UITestWait.holds(timeout: 10) { historyButton.exists && historyButton.isHittable }
                UITestWait.atLeast(1, since: settingsAt)
                shot("21-settings")
                // Design review W16: history and undo are the first row, on their own screen.
                let history = tap(historyButton, "open history and undo", timeout: 5)
                let row = app.buttons["history.row"].firstMatch
                if history {
                    let historyAt = Date()
                    // The history with its newest row free to tap (not asserted: the tap is), and
                    // at least the old second for the push to end for the screenshot.
                    _ = UITestWait.holds(timeout: 10) { row.exists && row.isHittable }
                    UITestWait.atLeast(1, since: historyAt)
                    shot("21h-history")
                }
                // A history row opens the plan's change receipt; undo lives there.
                let opened = history && tap(row, "history row opens receipt", timeout: 10)
                let undo = app.buttons["receipt.undo"]
                if opened {
                    let receiptAt = Date()
                    // The receipt loads after the screen opens (an empty list until then): its
                    // share button comes with it. Not asserted: the undo below is. At least the
                    // old two seconds for the push to end for the screenshot.
                    _ = UITestWait.holds(timeout: 20) { app.buttons["Liste teilen"].exists || undo.exists }
                    UITestWait.atLeast(2, since: receiptAt)
                    shot("21a-history-receipt")
                }
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
                            if delete.exists {
                                delete.tap()
                                questions += 1
                                // pacing: kept, the count of questions looks for a second one
                                // after the old two seconds (the check is that there is none).
                                sleep(2)
                            } else { break }
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
                    app.swipeUp(); app.swipeUp()
                    // pacing: kept, the scroll comes to rest before the screenshot, and the reloaded
                    // receipt's rows are read right after it (one of them must not be there).
                    sleep(1)
                    shot("22-after-undo")
                    // "Rückgängig gemacht" is also the section title of a partial undo; on the
                    // first real iPhone nothing was taken back and the test would not have
                    // noticed (15.11.). Everything must be gone.
                    let partial = anything("Nicht alles ließ sich zurücknehmen").exists || anything("teilweise rückgängig").exists
                    let removedRow = anything("Entfernte Alben und Ordner").exists
                    print(!partial && removedRow ? "UI_STEP_OK undo took back everything" : "UI_STEP_MISSING undo took back everything (partial \(partial), removed row \(removedRow))")
                    XCTAssertFalse(partial, "Undo was only partial")
                    XCTAssertTrue(removedRow, "Undo removed no albums or folders")
                }
                if opened {
                    back()
                    // Back on the history: its row can be tapped (not asserted: the way back goes on).
                    _ = UITestWait.holds(timeout: 5) { row.exists && row.isHittable }
                }
                let done = button("Fertig")
                if history {
                    back()
                    // Back on the settings, with "Fertig" free to tap (not asserted: the tap is).
                    _ = UITestWait.holds(timeout: 10) {
                        !app.navigationBars["Verlauf und Rückgängig"].exists && done.exists && done.isHittable
                    }
                }
                tap(done, "close settings")
            }
        }
    }

    /// Reise-Werkstatt: split a trip and merge it again, then take the changes back in the
    /// settings.
    func test1d_TripWorkshop() {
        continueAfterFailure = true
        prepare()
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        let trips = app.navigationBars["Reisen"]
        if tap(travel, "open travel area for workshop", timeout: 10) {
            // The trips list with its rows (the overview has none), before the workshop scrolls
            // it. Not asserted: the workshop's taps are.
            _ = UITestWait.holds(timeout: 10) { trips.exists && suggestionRow().exists }
            tripWorkshop()
            back()
            // Back on the overview: its settings button can be tapped (not asserted: the tap is).
            let settingsButton = app.buttons["Einstellungen"]
            _ = UITestWait.holds(timeout: 10) { settingsButton.exists && settingsButton.isHittable }
        }
        // The trip changes from the workshop can be taken back in the settings.
        if tap(app.buttons["Einstellungen"], "settings for trip reset") {
            let list = app.collectionViews.firstMatch
            // The settings list is there before it is scrolled (the overview has no list).
            _ = UITestWait.holds(timeout: 10) { app.navigationBars["Einstellungen"].exists && list.exists }
            let reset = app.buttons["settings.resetTrips"]
            var swipes = 0
            while !(reset.exists && reset.isHittable) && swipes < 8 {
                (list.exists ? list : app).swipeUp()
                swipes += 1
            }
            // Disabled while the analysis started by the last merge still runs (as in the workshop).
            let enabledAt = Date()
            let enabled = waitStable("trip reset enabled", timeout: 180, stableChecks: 1) { reset.exists && reset.isEnabled }
            print("UI_FACT trip reset enabled \(enabled) after \(String(format: "%.1f", Date().timeIntervalSince(enabledAt))) s")
            if tap(reset, "reset trip changes", timeout: 5) {
                shot("66-settings-trips")
                let confirm = app.buttons["Automatisch erkennen"]
                if tap(confirm, "confirm trip reset", timeout: 5) {
                    let gone = waitGone(reset, timeout: 20)
                    print(gone ? "UI_STEP_OK trip changes reset" : "UI_STEP_MISSING trip changes reset")
                    XCTAssertTrue(gone, "Resetting the trip changes did not clear them")
                }
            }
            tap(button("Fertig"), "close settings after trip reset")
            _ = waitStable("analysis after trip reset", timeout: 180) { analysisIdle }
        }
        // Second review of P3-06: "Keine Reise, hier bin ich öfter" from the "…" menu asks
        // before it changes anything; asked with nothing running, closed without an answer.
        noTripQuestion()
    }

    /// Design review D4 (15.11.): "Ignorieren" can be taken back, right after the action
    /// ("Widerrufen") and later in "Ignoriert" ("Nicht mehr ignorieren"). Runs in the library.
    private func ignoreAndUndo() {
        let photos = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*"))
        func ignoreTwo(_ step: String) -> Bool {
            guard tap(button("Auswählen"), "select mode for \(step)") else { return false }
            guard photos.count >= 2 else { print("UI_STEP_MISSING two photos for \(step)"); return false }
            photos.element(boundBy: 0).tap(); photos.element(boundBy: 1).tap()
            return tap(app.buttons["selection.ignore"], "ignore two photos (\(step))")
        }
        // 1. Ignore, then "Widerrufen" in the note right after. The note is tapped first and
        // audited in 2.: it goes away by itself (20 s in UI runs, as with VoiceOver), and an
        // audit that took 16 s left too little of that for the tap (UI run 44012530107).
        let note = anything("2 Fotos ignoriert")
        if ignoreTwo("undo") {
            // The note comes once the app has counted again (`ignore` waits for
            // `refreshDerived`): UI run 44178558165 had none within 5 s, and it was there for
            // "Widerrufen" later. Up to 20 s, and the time it took is said; anything over a
            // second is a finding about the app, listed for after the build (owner rule 17.11.).
            let asked = Date()
            let shown = note.waitForExistence(timeout: 20)
            print("UI_TIMING ignore note \(Int(Date().timeIntervalSince(asked) * 1000)) ms, shown \(shown)")
            print(shown ? "UI_STEP_OK ignore note" : "UI_STEP_MISSING ignore note")
            XCTAssertTrue(shown, "No \"2 Fotos ignoriert\" note after ignoring")
            // "Widerrufen" right away; the picture of the note is taken in 2. On a slow Mac the
            // picture before the tap took so long that the note had gone by itself (UI run
            // 44592357899: "Missing: undo ignore", the same test green an hour earlier).
            if tap(app.buttons["ignore.undo"], "undo ignore") {
                XCTAssertTrue(waitGone(note, timeout: 5), "The ignore note stayed after Widerrufen")
                tap(app.buttons["Ignoriert"], "ignored area after undo")
                // "Keine Fotos" shows only in an empty area other than "Nicht sortiert": up to the
                // two seconds of the old pause, then the five below, as before.
                let noPhotos = anything("Keine Fotos")
                _ = UITestWait.holds(timeout: 2) { noPhotos.exists }
                let empty = noPhotos.waitForExistence(timeout: 5)
                print(empty ? "UI_STEP_OK undo restored the photos" : "UI_STEP_MISSING undo restored the photos")
                XCTAssertTrue(empty, "Widerrufen left photos in Ignoriert")
                tap(app.buttons["Alle"], "all photos")
                // Every photo again ("Ignoriert" was empty), two of them selected next (not
                // asserted: `ignoreTwo` checks the count).
                _ = UITestWait.holds(timeout: 5) { photos.count >= 2 }
            }
        }
        // 2. Ignore again: the note is audited and must then go away by itself. Then one
        // photo is brought back from "Ignoriert".
        if ignoreTwo("unignore") {
            let asked = Date()
            let shown = note.waitForExistence(timeout: 20)
            print("UI_TIMING ignore note again \(Int(Date().timeIntervalSince(asked) * 1000)) ms, shown \(shown)")
            print(shown ? "UI_STEP_OK ignore note again" : "UI_STEP_MISSING ignore note again")
            XCTAssertTrue(shown, "No \"2 Fotos ignoriert\" note after ignoring again")
            if shown {
                shot("16a-ignore-note")
                audit("ignore note")
                let expired = waitGone(note, timeout: 30)
                print(expired ? "UI_STEP_OK ignore note went away by itself" : "UI_STEP_MISSING ignore note went away by itself")
                XCTAssertTrue(expired, "The ignore note did not go away by itself")
            }
            // pacing: kept, the library counts again after the note has ended
            sleep(2)
            tap(app.buttons["Ignoriert"], "ignored area")
            // pacing: kept, the area's photos: the grid and its count show in every area, so no
            // element says it is "Ignoriert" that shows; the count below is asserted after the
            // old time.
            sleep(2)
            shot("16b-ignored")
            if tap(button("Auswählen"), "select in ignored") {
                let ignored = photos.count
                print("UI_FACT ignored photos \(ignored)")
                XCTAssertEqual(ignored, 2, "Ignoriert should hold the two photos")
                if ignored > 0 { photos.element(boundBy: 0).tap() }
                // No red, destructive look for a step that can be taken back.
                if tap(app.buttons["selection.unignore"], "unignore one photo") {
                    // The list follows once the app has counted again (`refreshDerived`), which
                    // took more than the 2 s waited here before on a busy simulator (UI run
                    // 44164854295: still 2 after 2 s). Up to 15 s, and the time it took is said.
                    let asked = Date()
                    var left = photos.count
                    // Looked at every second, as before.
                    _ = UITestWait.holds(timeout: 15, interval: 1) {
                        left = photos.count
                        return left == max(0, ignored - 1)
                    }
                    print("UI_TIMING unignore one photo \(Int(Date().timeIntervalSince(asked) * 1000)) ms, \(left) left")
                    XCTAssertEqual(left, max(0, ignored - 1), "Nicht mehr ignorieren did not bring the photo back")
                }
            }
            // The other one through the photo's own detail.
            if photos.count > 0, tap(photos.element(boundBy: 0), "open ignored photo") {
                let info = app.buttons["viewer.info"]
                // The viewer with its "i" free to tap (not asserted: openPhotoInfo waits too).
                _ = UITestWait.holds(timeout: 10) { info.exists && info.isHittable }
                openPhotoInfo()
                // The info sheet opens at half height and its List builds rows only on
                // screen: the action at the end is not in the tree until the sheet is pulled
                // up (UI run 43779950348).
                let unignore = app.buttons["detail.unignore"]
                var pulls = 0
                let sheet = app.collectionViews["detail.list"]
                while !(unignore.exists && unignore.isHittable) && pulls < 4 {
                    (sheet.exists ? sheet : app).swipeUp()
                    pulls += 1
                    // pacing: kept, the scroll comes to rest before the tap measures the element's place
                    sleep(1)
                }
                if tap(unignore, "unignore in detail") {
                    // "Nicht mehr ignorieren" closes the info sheet; the viewer is closed after it
                    // (not asserted: "Keine Fotos" below is).
                    _ = UITestWait.holds(timeout: 10) { !app.buttons["detail.close"].exists }
                    closeViewerIfOpen()
                    let empty = anything("Keine Fotos").waitForExistence(timeout: 5)
                    print(empty ? "UI_STEP_OK ignored area empty again" : "UI_STEP_MISSING ignored area empty again")
                    XCTAssertTrue(empty, "Nicht mehr ignorieren in the detail did not bring the photo back")
                }
            }
            tap(app.buttons["Alle"], "all photos after unignore")
        }
    }

    /// A photo opens large; its details sit behind the "i" button (design review W12).
    private func openPhotoInfo() {
        let info = app.buttons["viewer.info"]
        if info.waitForExistence(timeout: 5) {
            info.tap()
            // The info sheet is up (its close button; not asserted: the callers' taps are).
            _ = UITestWait.holds(timeout: 10) { app.buttons["detail.close"].exists }
        }
    }

    private func closeViewerIfOpen() {
        let close = app.buttons["viewer.close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
            // The viewer has closed (not asserted: the callers go on either way).
            _ = UITestWait.holds(timeout: 5) { !close.exists }
        }
    }

    /// Reise-Werkstatt (I07), from the trip list. The demo library's Iceland trip is
    /// Reykjavík (1.–4. August) and Vík (5.–7. August) in one: split it at 5 August, then
    /// merge the two parts again, so the rest of the run sees the trips as before.
    /// Found by month and year, the one part of a title that does not depend on where the
    /// place names come from: with Apple's towns the trip is "Island, August 2023", with the
    /// offline map alone "Reykjavík, August 2023" (UI run 43779950348 looked for "Island" and
    /// scrolled past it); after the split the parts may carry two different places.
    private func tripWorkshop() {
        let iceland = "August 2023"
        func tripRows(_ text: String) -> XCUIElementQuery {
            app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", text))
        }
        func tripRow(_ text: String) -> XCUIElement { tripRows(text).element(boundBy: 0) }
        func openWorkshop(_ row: XCUIElement, _ step: String) -> Bool {
            var swipes = 0
            while !(row.exists && row.isHittable) && swipes < 4 {
                app.swipeUp()
                swipes += 1
                // pacing: kept, the scroll comes to rest before the tap measures the element's place
                sleep(1)
            }
            guard tap(row, "open trip for " + step, timeout: 10) else { return false }
            // Review P3-06: the workshop is in the "…" menu at the top right of the trip.
            guard tap(moreActionsButton(), "more actions of the trip for " + step, timeout: 5) else { return false }
            let reshape = menuItem("proposal.reshapeTrip", "Reise teilen oder zusammenlegen")
            if step == "split" {
                // The open menu holds the trip's other actions too: "Anpassen" is in every
                // suggestion's. Both can be tapped before the picture is taken.
                UITestWait.until("trip menu lists its actions", timeout: 5) {
                    reshape.exists && reshape.isHittable && menuItem("proposal.adjust", "Anpassen").isHittable
                }
                // pacing: the menu's opening animation, before the picture
                sleep(1)
                shot("59-trip-menu")
            } else if settled(reshape, "trip menu during the analysis", timeout: 15) {
                // Second review of P3-06: the same menu while the analysis the split started
                // still runs. "Keine Reise, hier bin ich öfter" waits then and says why as its
                // second line, which no picture showed before; what it showed is logged. Up to
                // 15 s: queries can be slow while the analysis runs (see `analysisIdle`).
                // One snapshot for all of it (each query is slow while the analysis runs).
                let noTrip = try? menuItem("proposal.oftenHere", "Keine Reise, hier bin ich öfter").snapshot()
                let state = noTrip.map { "\($0.isEnabled ? "can be tapped" : "waits"): \($0.label) | \($0.value as? String ?? "")" }
                print("UI_FACT trip menu during the analysis: Keine Reise \(state ?? "not offered")")
                shot("63b-trip-menu-analysis")
            }
            return tapMenuItem(reshape, "open trip workshop for " + step)
        }
        func finish(_ step: String, shotName: String) {
            let done = app.buttons["workshop.done"]
            let finished = done.waitForExistence(timeout: 180)
            print(finished ? "UI_STEP_OK trip \(step)" : "UI_STEP_MISSING trip \(step)")
            XCTAssertTrue(finished, "The trip \(step) did not finish")
            // pacing: kept, the finished workshop's result fades in before the screenshot; a
            // fade moves no frame and no element says it is done.
            sleep(1)
            shot(shotName)
            if finished {
                let tapped = Date()
                done.tap()
                UITestWait.disappears(done, "trip workshop closed after \(step)", timeout: 20)
                // The old 3 s at least: the trips list takes the split or merge after the close.
                UITestWait.atLeast(3, since: tapped)
            }
        }

        guard openWorkshop(tripRow(iceland), "split") else { return }
        let workshopAt = Date()
        // The workshop with its days (its content; the audit then waits for a still tree
        // itself). Not asserted: the day is tapped below. At least the old two seconds for the
        // push to end for the screenshot.
        _ = UITestWait.holds(timeout: 10) { app.buttons.matching(identifier: "workshop.day").firstMatch.exists }
        UITestWait.atLeast(2, since: workshopAt)
        shot("60-trip-workshop"); audit("trip workshop")
        let day = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "workshop.day", "5. August")).firstMatch
        var swipes = 0
        while !(day.exists && day.isHittable) && swipes < 4 {
            app.swipeUp()
            swipes += 1
            // pacing: kept, the scroll comes to rest before the tap measures the element's place
            sleep(1)
        }
        guard tap(day, "choose split day", timeout: 5) else { back(); return }
        // The preview and the button sit above the home indicator, whatever is scrolled.
        let split = app.buttons["workshop.split"]
        // Up to the second of the old pause, then the five below, as before.
        _ = UITestWait.holds(timeout: 1) { split.exists && split.isHittable }
        let inReach = split.waitForExistence(timeout: 5) && split.isHittable
        print(inReach ? "UI_STEP_OK split button in reach" : "UI_STEP_MISSING split button in reach")
        shot("61-split-preview"); audit("split preview")
        guard tap(split, "split trip") else { return }
        finish("split", shotName: "62-split-done")
        let list = app.navigationBars["Reisen"].waitForExistence(timeout: 5)
        print(list ? "UI_STEP_OK back to trips after split" : "UI_STEP_MISSING back to trips after split")
        let parts = waitStable("two trips in August 2023", timeout: 20, stableChecks: 1) { tripRows(iceland).count == 2 }
        print(parts ? "UI_STEP_OK second part is its own trip" : "UI_STEP_MISSING second part is its own trip")
        print("UI_FACT trips after split: \(tripRows(iceland).allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(parts, "After the split there are not two trips in August 2023")
        shot("63-trips-after-split")

        // The first part (listed below the newer one) lists the split and offers to merge with
        // the part after it; the other part offers the one before.
        guard openWorkshop(tripRows(iceland).element(boundBy: tripRows(iceland).count > 1 ? 1 : 0), "merge") else { return }
        let undoChange = app.buttons["workshop.undoChange"]
        // Up to the two seconds of the old pause (only a log line depends on it).
        _ = UITestWait.holds(timeout: 2) { undoChange.exists }
        let listed = undoChange.exists
        print(listed ? "UI_STEP_OK workshop lists the split" : "UI_STEP_MISSING workshop lists the split")
        shot("64-workshop-after-split")
        let after = app.buttons["workshop.merge.after"], before = app.buttons["workshop.merge.before"]
        swipes = 0
        // Rows of a List exist only once they are on screen.
        while !((after.exists && after.isHittable) || (before.exists && before.isHittable)) && swipes < 4 {
            app.swipeUp()
            swipes += 1
            // pacing: kept, the scroll comes to rest before the tap measures the element's place
            sleep(1)
        }
        let mergeRow = after.exists ? after : before
        // The split starts an analysis, and while it runs the workshop's buttons are disabled
        // (UI run 44375768011: the tap landed on the disabled row, nothing happened). The row is
        // tapped once the analysis has ended; how long that took is logged.
        let enabledAt = Date()
        let enabled = waitStable("merge row enabled", timeout: 180, stableChecks: 1) { mergeRow.exists && mergeRow.isEnabled }
        print("UI_FACT merge row enabled \(enabled) after \(String(format: "%.1f", Date().timeIntervalSince(enabledAt))) s")
        guard tap(mergeRow, "merge with the other part", timeout: 5) else { return }
        // The question may take a moment on a busy Mac; it is awaited, not looked for once.
        var confirm: XCUIElement?
        let asked = Date()
        var tappedAgain = false
        // UI run 44592357899 (slow Mac, the same test green an hour earlier): no question within
        // 10 s. After 10 s the row is tapped once more if it is still there and enabled (a tap
        // the busy simulator lost), with a counted retry line; the question then gets 30 s in all.
        // Looked for every quarter second, as before.
        _ = UITestWait.holds(timeout: 30, interval: 0.25) {
            confirm = app.buttons.matching(identifier: "Zusammenlegen").allElementsBoundByIndex.first(where: \.isHittable)
            if confirm == nil, !tappedAgain, Date().timeIntervalSince(asked) >= 10,
               mergeRow.exists, mergeRow.isEnabled, mergeRow.isHittable {
                tappedAgain = true
                print("UI_FLAKY_RETRY \(UITestWait.testID(self)) no merge question 10 s after the tap, row tapped again")
                mergeRow.tap()
            }
            return confirm != nil
        }
        print("UI_FACT merge question shown \(confirm != nil) after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s")
        shot("64b-merge-question")
        guard let confirm else {
            print("UI_STEP_MISSING confirm merge")
            XCTFail("Missing: confirm merge")
            return
        }
        confirm.tap()
        finish("merge", shotName: "65-merge-done")
        let whole = waitStable("one trip in August 2023 again", timeout: 20, stableChecks: 1) { tripRows(iceland).count == 1 }
        print(whole ? "UI_STEP_OK trip whole again" : "UI_STEP_MISSING trip whole again")
        XCTAssertTrue(whole, "After the merge the trip is not one again")
    }

    /// "Keine Reise?" from the "…" menu of the Iceland trip, with nothing running (second review
    /// of P3-06: no picture showed the question since the action moved behind "…"). It is closed
    /// without an answer: "Keine Reise" would turn the stays there into an album of the place and
    /// plan the trips anew.
    private func noTripQuestion() {
        let travel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reisen")).firstMatch
        guard tap(travel, "open travel area for Keine Reise", timeout: 10) else { return }
        defer { back() }
        guard UITestWait.appears(app.navigationBars["Reisen"], "trips for Keine Reise", timeout: 10) else { return }
        // Rows of a List exist only once they are on screen: one swipe per look.
        let row = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", "August 2023")).element(boundBy: 0)
        UITestWait.until("Iceland trip in the list for Keine Reise", timeout: 20) {
            if row.exists && row.isHittable { return true }
            app.swipeUp()
            return false
        }
        guard tap(row, "open trip for Keine Reise", timeout: 5) else { return }
        defer { back() }
        guard tap(moreActionsButton(), "more actions of the trip for Keine Reise", timeout: 5) else { return }
        let noTrip = menuItem("proposal.oftenHere", "Keine Reise, hier bin ich öfter")
        let offered = settled(noTrip, "Keine Reise in the trip menu")
        let enabled = offered && noTrip.isEnabled
        if offered {
            print(enabled ? "UI_STEP_OK Keine Reise can be tapped with nothing running"
                          : "UI_STEP_MISSING Keine Reise can be tapped with nothing running (\(noTrip.label))")
            XCTAssertTrue(enabled, "\"Keine Reise, hier bin ich öfter\" waits with nothing running: \(noTrip.label)")
        }
        guard enabled else {
            // A tap at the left edge closes the menu; if it reached the page, it hits no button.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
            return
        }
        guard tapMenuItem(noTrip, "ask Keine Reise") else { return }
        let title = app.staticTexts["Keine Reise?"]
        guard UITestWait.appears(title, "Keine Reise? asks", timeout: 5) else { return }
        // Its answer "Keine Reise, hier bin ich öfter" is never tapped here.
        settled(title, "Keine Reise? at rest", tappable: false)
        shot("66b-no-trip-question")
        if closeDialog(title, "Keine Reise? closed without an answer") {
            let kept = app.navigationBars["Vorschlag"].exists
            print(kept ? "UI_STEP_OK the trip stays after Keine Reise? was closed" : "UI_STEP_MISSING the trip stays after Keine Reise? was closed")
            XCTAssertTrue(kept, "Closing \"Keine Reise?\" without an answer left the trip")
        }
    }

    /// Test 1 did not reach its end (or did not run): the app may still be at its welcome
    /// screen. One plain start finishes the onboarding and the demo library first, so a
    /// cut-off test 1 does not fail every later test (run 43816787321: 13 failures).
    private func completeOnboardingIfCutOff(_ test: String) {
        guard !UITestOnboarding.fullFlowReachedItsEnd else { return }
        launch()
        if UITestOnboarding.completeIfNeeded(app, in: test) { shot("x-onboarded-again-\(test)") }
    }

    /// Creates albums once if "Verlauf und Rückgängig" is empty: the starter set, else the
    /// suggestions already selected.
    private func ensureHistory() {
        guard tap(app.buttons["Einstellungen"], "settings before backup"),
              tap(app.buttons["settings.history"], "history before backup", timeout: 5) else { return }
        let noChanges = app.staticTexts["Noch keine Änderungen"]
        // The history shows its rows or says it has none (both come from the app's memory).
        _ = UITestWait.holds(timeout: 10) { noChanges.exists || app.buttons["history.row"].firstMatch.exists }
        let empty = noChanges.exists
        print("UI_FACT history empty before backup \(empty)")
        back()
        let closeSettings = button("Fertig")
        // Back on the settings, with "Fertig" free to tap (not asserted: the tap is).
        _ = UITestWait.holds(timeout: 10) {
            !app.navigationBars["Verlauf und Rückgängig"].exists && closeSettings.exists && closeSettings.isHittable
        }
        tap(closeSettings, "close settings before backup")
        // The settings sheet has gone (not asserted: the overview's buttons are looked for below).
        _ = UITestWait.holds(timeout: 10) { !app.navigationBars["Einstellungen"].exists }
        guard empty else { return }
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ Alben (kostenlos )?anlegen")).firstMatch
        let selected = button("ausgewählte Alben anlegen")
        let open = starter.waitForExistence(timeout: 10) ? starter : selected
        guard tap(open, "open a plan for the backup", timeout: 10),
              app.navigationBars["Vorschau"].waitForExistence(timeout: 20),
              tap(app.buttons["plan.apply"], "apply a plan for the backup", timeout: 30) else { return }
        let done = button("Rückgängig machen").waitForExistence(timeout: 900)
        print(done ? "UI_STEP_OK plan for the backup applied" : "UI_STEP_MISSING plan for the backup applied")
        XCTAssertTrue(done, "The plan for the backup did not finish")
        back()
        // pacing: kept, the analysis after the plan starts on its own time; the idle wait
        // below must not see the overview before it started.
        sleep(2)
        _ = waitStable("analysis before backup", timeout: 180) { analysisIdle }
    }

    // MARK: Tap-through sweep

    /// Labels the sweep never taps: anything that changes the library or the analysis.
    private let sweepSkip = ["Pause", "Neu prüfen", "jetzt anlegen", "jetzt einsortieren", "jetzt ausführen", "zurücknehmen", "Rest anlegen",
                             "Erledigtes behalten", "ignorieren", "Widerrufen", "Rückgängig", "Fotos-App öffnen", "Alle Jahre", "Ganze Mediathek dazunehmen", "arbeitet mit", "Nur 20", "Löschen", "Entfernen", "Anlegen",
                             "Übernehmen", "Nicht jetzt", "ergänzen", "so lassen", "Fortsetzen", "Beispiel", "Ignorieren", "Auswählen",
                             "aufheben", "gleichen Fotos"]

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
            if b.exists && b.isHittable {
                b.tap()
                // The sheet has gone with its button (not asserted: the sweep goes on).
                _ = UITestWait.holds(timeout: 5) { !b.exists }
                return true
            }
        }
        return false
    }

    /// What a row says: its own label, or for a list cell (whose own label is usually empty,
    /// UI run 43842312131: no row of "Vorschläge" or "Alben" was ever tapped) its first text.
    private func rowLabel(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        let text = element.staticTexts.firstMatch
        return text.exists ? text.label : ""
    }

    /// A list cell without its own label is a row (a link to a screen) only when it shows more
    /// than one text or an image: a suggestion or album row has its title, "12 Fotos" and a
    /// thumbnail. A section header ("Länder und Orte") or footer is a cell with one text and
    /// nothing to open (UI run 43906501407: they were tapped as rows and reported as dead).
    /// Every cell skipped this way is printed as UI_SWEEP_SKIP, and ui_tests.py lists those in
    /// the job summary and the run's "UI summary", so a real row skipped here is seen.
    private func looksLikeRow(_ element: XCUIElement) -> Bool {
        element.staticTexts.count >= 2 || element.images.count > 0
    }

    /// A row is tapped only when its label is not on the skip list, and a cell found by its
    /// text only when nothing in it is: a tap on the middle of such a cell can land on a
    /// button inside it. (Rows with their own label are tapped as before.)
    private func rowIsSafe(_ element: XCUIElement, label: String) -> Bool {
        guard isSafe(label) else { return false }
        guard element.label.isEmpty else { return true }
        let inside = element.buttons.allElementsBoundByIndex.prefix(8).map(\.label)
            + element.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label)
        return !inside.contains { !$0.isEmpty && !isSafe($0) }
    }

    /// Taps every row (and on top-level screens every button in the content) and checks
    /// that each tap leads somewhere and back works: no dead rows, no crash, no lost screen.
    /// Returns how many taps led somewhere (this screen and the screens below it). Rows it
    /// leaves out are printed (UI_SWEEP_SKIP), so a sweep that taps nothing says why.
    /// A row that does nothing fails the test in every list the sweep walks (G5-10 of the
    /// review of 18.11.2026; before, only in "Vorschläge", elsewhere it was only a log line):
    /// in 38 UI runs of 16.–19.11. no row on any of them did nothing.
    @discardableResult
    private func sweep(_ screen: String, depth: Int) -> Int {
        var reached = 0
        let start = screenTitle
        let useCells = app.collectionViews.cells.count > 0
        if depth > 0 && !useCells { return 0 } // detail screens hold actions, not navigation
        let query = useCells ? app.collectionViews.cells : app.scrollViews.firstMatch.buttons
        // Rows by what they say; a cell whose own label is empty is found again by its text.
        var rows: [(label: String, own: Bool)] = []
        for i in 0..<min(query.count, 8) {
            let element = query.element(boundBy: i)
            let label = rowLabel(element)
            if label.isEmpty {
                print("UI_SWEEP_SKIP \(screen) row \(i) (no label, no text)")
            } else if element.label.isEmpty && !looksLikeRow(element) {
                print("UI_SWEEP_SKIP \(screen) › \(label) (section header or footer text)")
            } else if !rowIsSafe(element, label: label) {
                print("UI_SWEEP_SKIP \(screen) › \(label) (changes the library)")
            } else if !rows.contains(where: { $0.label == label }) {
                rows.append((label, !element.label.isEmpty))
            }
        }
        for (label, own) in rows.prefix(6) {
            let match = NSPredicate(format: "label == %@", label)
            let element = own ? query.matching(match).firstMatch : query.containing(match).firstMatch
            guard element.exists else { print("UI_SWEEP_SKIP \(screen) › \(label) (gone)"); continue }
            if !element.isHittable {
                app.swipeUp()
                // At most the old second; XCTest's own tap below waits for the scroll to end.
                _ = UITestWait.holds(timeout: 1) { element.isHittable }
            }
            guard element.isHittable else { print("UI_SWEEP_SKIP \(screen) › \(label) (not hittable)"); continue }
            element.tap()
            // pacing: kept, the time a tap has to lead somewhere: the screen it opens is read
            // right after (its title, its rows), and a screen that does not change is a finding.
            sleep(2)
            guard app.state == .runningForeground else {
                print("UI_SWEEP_CRASH \(screen) › \(label)")
                XCTFail("App crashed after tapping \(label) on \(screen)")
                launch()
                UITestWait.appears(app.tabBars.firstMatch, "app back after the crash on \(screen)", timeout: 60)
                return reached
            }
            let now = screenTitle
            if now != start {
                print("UI_SWEEP_OK \(screen) › \(label) → \(now)")
                reached += 1
                if depth == 0 && useCells { reached += sweep("\(screen) › \(label)", depth: 1) }
                back()
                // pacing: kept, the pop ends before the next row is looked for (the title swaps
                // when the pop starts, while the rows still move in).
                sleep(1)
                if screenTitle != start {
                    print("UI_SWEEP_BACK_FAILED \(screen) › \(label) (still \(screenTitle))")
                    XCTFail("Back did not return to \(screen) after \(label)")
                    back()
                    // pacing: kept (as above)
                    sleep(1)
                }
            } else if closeSheet() {
                print("UI_SWEEP_OK \(screen) › \(label) → sheet")
                reached += 1
            } else {
                print("UI_SWEEP_NOOP \(screen) › \(label)")
                XCTFail("Row '\(label)' on \(screen) did nothing")
            }
        }
        return reached
    }

    /// The search tab has no rows to open: a starting point must find photos, and a found
    /// photo must open large. Starting points from the library carry their photo count
    /// ("12 Fotos") and are taken first; before the analysis the fixed examples show, of which
    /// "Italien" matches the demo library.
    private func sweepSearch() -> Int {
        let chips = app.descendants(matching: .any).matching(identifier: "search.example")
        guard chips.firstMatch.waitForExistence(timeout: 10) else {
            print("UI_SWEEP_NOOP Suchen › no example")
            return 0
        }
        let counted = chips.matching(NSPredicate(format: "value MATCHES %@", "[1-9][0-9]* Fotos?")).firstMatch
        let italy = chips.matching(NSPredicate(format: "label == %@", "Italien")).firstMatch
        let chip = counted.exists ? counted : italy.exists ? italy : chips.firstMatch
        let label = chip.label
        chip.tap()
        let result = app.descendants(matching: .any).matching(identifier: "search.result").firstMatch
        guard result.waitForExistence(timeout: 20) else {
            print("UI_SWEEP_NOOP Suchen › \(label) (no results)")
            return 0
        }
        print("UI_SWEEP_OK Suchen › \(label) → results")
        var reached = 1
        // The keyboard can cover the grid; the first photo is above it.
        if !result.isHittable, app.keyboards.firstMatch.exists {
            app.swipeDown()
            // The keyboard has gone or the photo is free (at most the old second).
            _ = UITestWait.holds(timeout: 1) { result.isHittable || !app.keyboards.firstMatch.exists }
        }
        if result.isHittable {
            result.tap()
            let viewer = app.buttons["viewer.close"].waitForExistence(timeout: 5)
            print(viewer ? "UI_SWEEP_OK Suchen › \(label) › photo → viewer" : "UI_SWEEP_NOOP Suchen › \(label) › photo")
            XCTAssertTrue(viewer, "A photo found by the search example '\(label)' did not open")
            if viewer { reached += 1 }
            closeViewerIfOpen()
        } else {
            print("UI_SWEEP_SKIP Suchen › \(label) › photo (not hittable)")
        }
        // Leave the search: "Abbrechen", or on iOS 26 the field's "Schließen" (UI run
        // 43964816778: the search stayed open with its keyboard, and the tap on the
        // "Übersicht" tab after the sweep left the app on "Suchen").
        for label in ["Abbrechen", "Schließen"] where app.buttons[label].exists && app.buttons[label].isHittable {
            let leave = app.buttons[label]
            leave.tap()
            // The search is left: its button has gone (not asserted: the caller checks the overview).
            _ = UITestWait.holds(timeout: 5) { !leave.exists }
            break
        }
        return reached
    }

    /// The sweep's own album when the albums tab has none: two photos into "Testalbum Rundgang"
    /// (no sweep-skip word in it), kept for the sweep. Until 20.11. the sweep used the albums
    /// that DeviceConditionUITests 05, 07 and 08 left on the same simulator; those now run in
    /// their own group (device-flows), so the sweep makes its own.
    private func ensureAlbumForSweep() { ensureAlbum(for: "the sweep") }

    /// An album with photos on the Alben tab: makes "Testalbum Rundgang" through a manual plan
    /// when the tab has none with photos. The tests of a group share one simulator, and what an
    /// earlier test left there depends on the grouping, so a test that needs an album makes
    /// its own instead of relying on another test.
    private func ensureAlbum(for purpose: String) {
        guard tap(tabButton("Alben"), "albums tab before \(purpose)") else { return }
        let empty = app.staticTexts["Noch keine Alben"]
        let anyAlbum = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "(.*, )?[0-9]+ Fotos?")).firstMatch
        // An album with photos (an empty Albumist album has happened, UI run 43949880264).
        let album = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "(.*[^0-9.])?[1-9][0-9.]* Fotos?")).firstMatch
        // The tab shows its rows or says it has none.
        let shown = UITestWait.holds(timeout: 10) { empty.exists || anyAlbum.exists }
        if !shown {
            print("UI_STEP_MISSING albums tab before \(purpose)")
            XCTFail("The albums tab showed neither an album row nor \"Noch keine Alben\" before \(purpose)")
        }
        let made = empty.exists || !album.exists
        print("UI_FACT albums tab without an album with photos before \(purpose) \(made)")
        if made, openManualPlan("Testalbum Rundgang"),
           tap(app.buttons["plan.apply"], "apply the album for \(purpose)", timeout: 30) {
            let done = button("Rückgängig machen").waitForExistence(timeout: 900)
            let doneAt = Date()
            print(done ? "UI_STEP_OK album for \(purpose)" : "UI_STEP_MISSING album for \(purpose)")
            XCTAssertTrue(done, "The album for \(purpose) was not created")
            // The plan ran from the "Zu Album hinzufügen" sheet: start the app again, as
            // applyRecommended does, so no sheet is left over the tab bar; with its pacing (the
            // app stores the finished plan after the result shows, no element says when), so the
            // restart does not cut the plan off.
            UITestWait.atLeast(2, since: doneAt)
            launch()
            UITestWait.appears(app.tabBars.firstMatch, "tab bar after the album for \(purpose)", timeout: 60)
            // Evidence that it was stored: no "wurde unterbrochen" card for it after the restart.
            let cut = anything("wurde unterbrochen").waitForExistence(timeout: 5)
            print("UI_FACT album plan for \(purpose) interrupted by the restart \(cut)")
            XCTAssertFalse(cut, "The album plan for \(purpose) shows as interrupted after the restart")
        }
        tap(tabButton("Übersicht"), "overview before \(purpose)")
        _ = app.navigationBars["Übersicht"].waitForExistence(timeout: 10)
        guard made else { return }
        // After a plan the analysis starts again on its own time: up to 2 s for its "Pause",
        // then the overview idle over three checks (as in ensureHistory, without a fixed pause).
        _ = UITestWait.holds(timeout: 2) { app.buttons["Pause"].exists }
        _ = waitStable("analysis before \(purpose)", timeout: 180) { analysisIdle }
    }

    /// Third run: every tab, every row, one level deep.
    func test3_TapThroughSweep() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test3")
        let prepared = Date()
        prepare()
        UITestWait.appears(app.tabBars.firstMatch, "tab bar before the sweep", timeout: 60)
        ensureAlbumForSweep()
        // The old 5 s at least (second review of C2): the overview settles before the sweep.
        UITestWait.atLeast(5, since: prepared)
        // A sweep that reaches nothing proves nothing: every tab and the suggestions list must
        // lead somewhere, the albums tab too (the test made an album above when it had none).
        func check(_ tab: String, _ reached: Int) {
            print("UI_SWEEP_TAB \(tab) \(reached)")
            if reached == 0 { XCTFail("The sweep reached no screen from \(tab)") }
        }
        check("Übersicht", sweep("Übersicht", depth: 0))
        for tab in ["Mediathek", "Alben", "Suchen"] {
            let button = tab == "Suchen" ? searchTabButton() : tabButton(tab)
            guard button.waitForExistence(timeout: 5) else {
                print("UI_STEP_MISSING sweep tab \(tab)")
                XCTFail("No tab \(tab) for the sweep")
                continue
            }
            button.tap()
            // pacing: kept, the sweep reads the tab's rows and title right after; no one element
            // says a tab's content is complete, and a title read mid-switch fails "back".
            sleep(2)
            if tab == "Suchen" {
                check(tab, sweepSearch())
            } else if tab == "Alben" && app.staticTexts["Noch keine Alben"].exists {
                print("UI_SWEEP_TAB Alben 0 (empty)")
                XCTFail("\"Noch keine Alben\": the sweep has no album to open (ensureAlbumForSweep)")
            } else {
                check(tab, sweep(tab, depth: 0))
            }
        }
        // Suggestions list, the screen that had dead rows.
        // Back on the overview before looking for its button: a tab tap while the search is
        // still active can leave the app on "Suchen" (UI run 43964816778).
        let overview = app.navigationBars["Übersicht"]
        var tries = 0
        repeat {
            tabButton("Übersicht").tap()
            // Up to the second of the old pause, then the three of the loop's check, as before.
            _ = UITestWait.holds(timeout: 1) { overview.exists }
            tries += 1
        } while !overview.waitForExistence(timeout: 3) && tries < 3
        let suggestions = reviewSuggestionsButton()
        if suggestions.waitForExistence(timeout: 5) {
            suggestions.tap()
            // pacing: kept, the sweep reads the list's title as its start right after; read
            // during the push it would take the overview's and fail "back".
            sleep(2)
            check("Vorschläge", sweep("Vorschläge", depth: 0))
            back()
        } else {
            print("UI_STEP_MISSING sweep suggestions")
            // What the overview showed instead (UI runs 43930271358, 43930277920, 43949880264
            // left no picture of it): screen title, buttons and the analysis card.
            let buttons = app.buttons.allElementsBoundByIndex.prefix(30).map(\.label).filter { !$0.isEmpty }
            print("UI_FACT sweep overview: \(screenTitle) | \(buttons.joined(separator: " | "))")
            shot("x-sweep-no-suggestions")
            XCTFail("No \"Vorschläge prüfen\" on the overview for the sweep")
        }
        print("UI_SWEEP_DONE")
    }

    // MARK: Safety backup

    /// Fourth run: the decisions and the plan made here are copied when the app goes to the
    /// background, the database is then set aside (as with "Neu aufbauen") and the next start
    /// must bring the decisions and the history back and say so.
    func test4_DecisionsComeBackAfterRebuild() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test4")
        prepare()
        // Decisions and a plan in the history, made in a run that keeps the backup copy.
        launch(["-AlbumistUITestBackup"])
        applyRecommended("backup", relaunchWith: ["-AlbumistUITestBackup"])
        UITestWait.appears(app.tabBars.firstMatch, "app back after the backup plan", timeout: 60)
        // The copy must hold a history to bring back: when the earlier tests left none (test 1
        // cut off before its plan), this test creates one first instead of testing a backup
        // that has nothing to restore.
        ensureHistory()
        // Going to the background writes the copy: wait until iOS has the app there (a fixed
        // 4 s brought device test06 back before it ever was, UI run 44480215847).
        UITestWait.toBackground(app, "to write the backup copy", atLeast: 4, in: self)
        launch(["-AlbumistUITestBackup", "-AlbumistUITestRebuildDatabase"])
        let card = app.staticTexts["Entscheidungen zurückgeholt"]
        let restored = card.waitForExistence(timeout: 30)
        print(restored ? "UI_STEP_OK restored card" : "UI_STEP_MISSING restored card")
        XCTAssertTrue(restored, "The decisions did not come back after the database was rebuilt")
        // The analysis starts again right away, as after a real rebuild. The card says that
        // album records and history came back into the same library (waited for, not a fixed 4 s).
        let withHistory = UITestWait.appears(anything("Alben und den Verlauf aus der Sicherung"),
                                             "restore names album records and history", timeout: 30)
        print("UI_FACT restore included history \(withHistory)")
        shot("40-restored-card"); audit("restored card")

        // The history is back and the settings say when the copy was made.
        if tap(app.buttons["Einstellungen"], "settings after restore"),
           tap(app.buttons["settings.history"], "history after restore", timeout: 5) {
            // Up to the second of the old pause for a history row: the check below says the
            // history is not empty, so "Noch keine Änderungen" does not end this wait early.
            _ = UITestWait.holds(timeout: 1) { app.buttons["history.row"].firstMatch.exists }
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
            back()
            let done = button("Fertig")
            // Back on the settings, with "Fertig" free to tap (not asserted: the tap is).
            _ = UITestWait.holds(timeout: 10) {
                !app.navigationBars["Verlauf und Rückgängig"].exists && done.exists && done.isHittable
            }
            tap(done, "close settings after restore")
        }
        if tap(app.buttons["overview.restoredFromBackup.ok"], "dismiss restored card") {
            // The card goes (asserted right after, within the old second).
            _ = UITestWait.holds(timeout: 1) { !card.exists }
            let gone = !card.exists
            print(gone ? "UI_STEP_OK restored card dismissed" : "UI_STEP_MISSING restored card dismissed")
            XCTAssertTrue(gone, "The restored card did not go away")
        }
    }

    /// Fifth run: the app is closed while a plan runs. The next start offers to continue,
    /// undo or leave it; "Nur Erledigtes behalten" keeps what was done, the change list says so and
    /// "Fehlendes erneut versuchen" makes a plan with only the missing steps.
    /// (Fortsetzen and Rückgängig: DeviceConditionUITests.test07.)
    func test5_InterruptedPlanCanBeLeftAndRetried() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test5")
        prepare()
        // The first change in Photos goes through at once, every later one waits 30 s, so the
        // app is always closed half way.
        launch(["-AlbumistUITestSlowPlan"])
        _ = waitStable("analysis idle before interruption", timeout: 120) { analysisIdle }
        // Something to apply: the selection of earlier runs, else the recommended ones, else a
        // new album of two photos. Tests 1c and 4 apply the recommended suggestions on this
        // simulator first, so often only one that is not recommended is left (UI run
        // 43930271358: "1 Vorschlag prüfen", nothing to select, "Missing: open plan for
        // interruption"). Any plan of two or more changes is cut off by the slow plan.
        guard openRecommendedPlan("interruption") else {
            print("UI_STEP_MISSING plan for interruption")
            XCTFail("No plan to interrupt could be opened")
            return
        }
        guard tap(app.buttons["plan.apply"], "start plan for interruption", timeout: 30) else { return }
        // The app is closed only once the plan has left its preview (the sorting show or the
        // running card instead of the button): a fixed 5 s after the tap closed it before the
        // plan had started on a slow simulator, and no card came (UI run 44012530107).
        let tapped = Date()
        let left = waitGone(app.buttons["plan.apply"], timeout: 30)
        print("UI_FACT plan left its preview: \(left) after \(Int(Date().timeIntervalSince(tapped))) s")
        // pacing: the plan runs 5 s before the app is closed (the test's design); its start is checked above
        sleep(5)
        // Read by identifier: the running card's title ("Alben werden angelegt") is covered by
        // the sorting show, and a query over every element during the show took long on a slow
        // simulator (device test 07, UI run 44202318875).
        print("UI_FACT plan running when the app was closed: \(left && !app.buttons["result.receipt"].exists)")
        shot("49-plan-before-close")
        UITestAppEnd.end(app, "during the plan")
        // pacing: kept, a gap after the process has ended (awaited in UITestAppEnd.end) before
        // the next launch; no element shows what iOS still does with the ended app.
        sleep(2)
        launch()
        let card = anything("Anlegen wurde unterbrochen")
        guard card.waitForExistence(timeout: 30) else {
            // Not silent any more: with the slow plan this means the interruption was lost.
            print("UI_STEP_MISSING interruption card")
            shot("x-no-interruption-card")
            XCTFail("No interruption card although the app was closed in the middle of a plan")
            return
        }
        print("UI_STEP_OK interruption card")
        let keep = app.buttons["interrupted.keep"]
        // The card with its buttons (the audit then waits for a still tree itself). Not
        // asserted: the tap on "keep" below is.
        _ = UITestWait.holds(timeout: 5) { keep.exists }
        shot("50-interrupted"); audit("interrupted card")
        if !keep.isHittable {
            app.swipeUp()
            // pacing: kept, the scroll comes to rest before the tap measures the element's place
            sleep(1)
        }
        guard tap(keep, "leave interrupted plan as it is") else { return }
        let gone = waitGone(card, timeout: 30)
        print(gone ? "UI_STEP_OK interruption card gone after keep" : "UI_STEP_MISSING interruption card gone after keep")
        XCTAssertTrue(gone, "The interruption card stayed after \"Nur Erledigtes behalten\"")
        // pacing: kept, the app stores the kept plan in the history after the card has gone; the
        // newest history row is opened next, and no element says it is written.
        sleep(2)
        shot("50b-after-keep")

        // The kept plan is the newest history row; its receipt says what is missing.
        guard tap(app.buttons["Einstellungen"], "settings after keep") else { return }
        let historyButton = app.buttons["settings.history"]
        // The settings sheet with its first row free to tap (not asserted: the tap is).
        _ = UITestWait.holds(timeout: 10) { historyButton.exists && historyButton.isHittable }
        guard tap(historyButton, "history after keep", timeout: 5) else { return }
        let row = app.buttons["history.row"].firstMatch
        // The history with its newest row free to tap (not asserted: the tap is).
        _ = UITestWait.holds(timeout: 10) { row.exists && row.isHittable }
        guard tap(row, "kept plan in history", timeout: 10) else { return }
        // The receipt loads after the screen opens (an empty list until then): its share button
        // comes with it. Not asserted: the check below is.
        _ = UITestWait.holds(timeout: 20) { app.buttons["Liste teilen"].exists }
        let partial = anything("Teilweise umgesetzt").waitForExistence(timeout: 5)
        print(partial ? "UI_STEP_OK kept plan is partial" : "UI_STEP_MISSING kept plan is partial")
        XCTAssertTrue(partial, "The kept plan does not say it is partial")
        shot("51-kept-receipt"); audit("kept receipt")
        let retry = app.buttons["receipt.retry"]
        var more = 0
        while !(retry.exists && retry.isHittable) && more < 6 { app.swipeUp(); more += 1 }
        // pacing: kept, the scroll comes to rest before the tap measures the element's place
        // (and the screenshot)
        sleep(1)
        shot("52-receipt-repair")
        guard tap(retry, "retry missing steps", timeout: 10) else { return }
        let plan = app.navigationBars["Vorschau"].waitForExistence(timeout: 20)
        print(plan ? "UI_STEP_OK retry plan opened" : "UI_STEP_MISSING retry plan opened")
        XCTAssertTrue(plan, "\"Fehlendes erneut versuchen\" did not open a plan")
        // The plan's content, not only its bar (the audit then waits for a still tree itself).
        // Not asserted: the tap on "Jetzt umsetzen" below is.
        _ = UITestWait.holds(timeout: 30) { planContentShown() }
        shot("53-retry-plan"); audit("retry plan")
        if tap(app.buttons["plan.apply"], "apply retry plan", timeout: 30) {
            let done = button("Rückgängig machen").waitForExistence(timeout: 300)
            print(done ? "UI_STEP_OK retry plan finished" : "UI_STEP_MISSING retry plan finished")
            XCTAssertTrue(done, "The retry plan did not finish")
            // pacing: kept, the result card fades and scales in before the screenshot (as in test 1)
            sleep(1)
            shot("54-retry-result")
        }
    }
    // MARK: Analysis keeps going

    /// Sixth run (first device test 15.11.: "bricht die Suche ab", "die Zahlen werden kleiner",
    /// "läuft es weiter, wenn man den Tab wechselt?"): a full analysis, made slow on purpose,
    /// survives leaving the app, coming back and switching tabs. Its count never goes down,
    /// it never starts at step 1 again, and it ends with every photo analysed. Then the trial
    /// year: choosing one shows it on the overview, "Alle Jahre" takes it back.
    func test6_AnalysisKeepsGoingThroughBackgroundAndTabs() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test6")
        prepare()
        launch(["-AlbumistUITestSlowAnalysis"])
        _ = waitStable("analysis idle before rebuild", timeout: 300) { analysisIdle }
        // A full run from scratch: "Analyse neu aufbauen" in the settings.
        guard tap(app.buttons["Einstellungen"], "settings for rebuild") else { return }
        let list = app.collectionViews.firstMatch
        let rebuild = app.buttons["Analyse neu aufbauen"]
        var swipes = 0
        while !(rebuild.exists && rebuild.isHittable) && swipes < 12 { (list.exists ? list : app).swipeUp(); swipes += 1 }
        tap(rebuild, "rebuild analysis")
        let confirmRebuild = app.buttons["Neu aufbauen"]
        tap(confirmRebuild, "confirm rebuild")
        // The dialog has closed, so "Fertig" of the settings is not behind it. Not asserted: the
        // analysis checks after this say whether the rebuild started.
        _ = UITestWait.holds(timeout: 5) { !confirmRebuild.exists }
        if app.buttons["Fertig"].exists { app.buttons["Fertig"].tap() }

        var seen: [(step: Int, done: Int, total: Int)] = []
        func record(_ moment: String) {
            guard let count = analysisCount() else {
                print("UI_FACT analysis \(moment): no count (running \(app.buttons["Pause"].exists))")
                return
            }
            print("UI_FACT analysis \(moment): step \(count.step) \(count.done)/\(count.total)")
            if let last = seen.last {
                let back = count.step < last.step || (count.step == last.step && count.total == last.total && count.done < last.done)
                print(back ? "UI_STEP_MISSING count never goes back (\(moment))" : "UI_STEP_OK count never goes back (\(moment))")
                XCTAssertFalse(back, "The analysis went back at \(moment): \(last) -> \(count)")
            }
            seen.append(count)
        }

        // Wait for the image analysis (step 4), where most of the time goes.
        let inContent = waitStable("analysis reached the images", timeout: 300, stableChecks: 1) { (analysisCount()?.step ?? 0) >= 4 }
        XCTAssertTrue(inContent, "The analysis did not reach the image step")
        record("before leaving")
        shot("60-analysis-running"); audit("analysis running")
        lookAtAnalysisDetails()

        // In the foreground the count moves (run 43743310212 printed only "0/246" while the
        // app was away, which says nothing about the foreground).
        let start = analysisCount()
        let moved = waitStable("progress moves in the foreground", timeout: 60, stableChecks: 1) {
            guard let start else { return true }
            guard let now = analysisCount() else { return analysisIdle }
            return now.step > start.step || (now.step == start.step && now.done > start.done)
        }
        print(moved ? "UI_STEP_OK progress moves in the foreground" : "UI_STEP_MISSING progress moves in the foreground")
        XCTAssertTrue(moved, "The analysis progress did not move in the foreground for 60 s")
        record("in the foreground")

        // Leave the app (on the simulator iOS holds it right away) and come back: in the
        // background for at least the old 8 s, counted once iOS has it there.
        UITestWait.toBackground(app, "during the analysis", atLeast: 8, in: self)
        UITestWait.toForeground(app, "after the background during the analysis", in: self)
        // Running or done, polled (no 10 s extra when it is already done), and for at least the
        // old 3 s no "Fortsetzen": a pause that comes a moment after the return is seen too
        // (second review of C2).
        UITestWait.until("analysis still there after background", timeout: 10) { app.buttons["Pause"].exists || analysisIdle }
        UITestWait.never("analysis not paused by the background", for: 3) { app.buttons["analysis.resume"].exists }
        record("after background")
        shot("61-after-background")

        // Switch tabs while it runs, then back to the overview.
        for name in ["Mediathek", "Alben"] {
            // pacing: a while on each tab during the analysis (the test's design); the tap is checked
            if tap(tabButton(name), "tab \(name) during analysis") { sleep(3) }
        }
        tap(tabButton("Übersicht"), "back to overview during analysis")
        // pacing: kept, the overview's card is read once after the old time: each look for it
        // reads the whole tree, which held the app's main thread during the analysis (UI run
        // 43979263666), so it is not polled here.
        sleep(2)
        record("after tabs")
        shot("62-after-tabs")

        // It goes on and ends with every photo analysed.
        var checks = 0
        while !analysisIdle && checks < 300 {
            // pacing: the poll's interval
            sleep(3)
            if checks % 5 == 0 { record("while running") }
            checks += 1
        }
        let done = waitStable("analysis finished after background and tabs", timeout: 60) { analysisIdle }
        XCTAssertTrue(done, "The analysis did not finish after background and tabs")
        assertEveryPhotoAnalysed("after background and tabs")
        shot("63-analysis-done"); audit("analysis done")

        // "Neu prüfen" finds nothing new and says so.
        if tap(app.buttons["Neu prüfen"], "check again") {
            let said = waitStable("check result shown", timeout: 120) { analysisIdle && anything("keine neuen Fotos").exists }
            print(said ? "UI_STEP_OK check says no new photos" : "UI_STEP_MISSING check says no new photos")
            shot("64-check-again")
        }

        // Trial year: chosen in the settings, shown on the overview, taken back there.
        let year = Calendar.current.component(.year, from: Date())
        if tap(app.buttons["Einstellungen"], "settings for trial year") {
            // On a busy Mac (UI run 44886315629, flow-other 44 min, Home presses needed twice) the
            // picker was not there 15 s after the tap: the settings open is now waited for and
            // said by name, and the picker has 30 s.
            UITestWait.appears(app.navigationBars["Einstellungen"], "settings open for the trial year", timeout: 20)
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Albumist arbeitet mit")).firstMatch
            if tap(picker, "trial year picker", timeout: 30) {
                let onlyYear = app.buttons["Nur \(year)"]
                tap(onlyYear, "choose \(year)")
                // The menu has closed (not asserted: the overview's note below is).
                _ = UITestWait.holds(timeout: 5) { !onlyYear.exists }
            }
            shot("65-settings-trial-year")
            if app.buttons["Fertig"].exists { app.buttons["Fertig"].tap() }
            UITestWait.disappears(app.navigationBars["Einstellungen"], "settings closed after the trial year", timeout: 20)
            let note = app.descendants(matching: .any)["analysis.trial"]
            let shown = note.waitForExistence(timeout: 20)
            print(shown ? "UI_STEP_OK trial year on overview" : "UI_STEP_MISSING trial year on overview")
            XCTAssertTrue(shown, "The chosen year is not shown on the overview")
            _ = waitStable("analysis idle with trial year", timeout: 300) { analysisIdle }
            shot("66-overview-trial-year")
            if tap(button("Alle Jahre"), "take in all years") {
                let gone = waitGone(note, timeout: 20)
                print(gone ? "UI_STEP_OK trial year taken back" : "UI_STEP_MISSING trial year taken back")
                _ = waitStable("analysis idle after all years", timeout: 300) { analysisIdle }
                shot("67-overview-all-years")
            }
        }
    }

    // MARK: Personal places

    /// Seventh run (owner's device test 18.11., dark mode): in "Häufiger Ort in Zwiesel" nothing
    /// showed where the name goes, and the button only said "Erst einen Namen eingeben",
    /// disabled. A place only the user can name has a field of its own with a label and
    /// examples; "Namen eingeben" opens the keyboard there, Return only closes it, and with a
    /// name the button becomes "Album anlegen". "Anpassen" shows the typed name under "Titel",
    /// and a name changed there is in the field after "Abbrechen" (the owner's "Dahoam" was
    /// missing there). The test goes back before creating anything: nothing is stored.
    func test7_PersonalPlaceAsksForName() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test7")
        prepare()
        guard tap(reviewSuggestionsButton(), "open suggestions for a personal place", timeout: 30) else { return }
        // The list with its rows before it is scrolled (the overview has none). Not asserted:
        // the row is looked for below.
        _ = UITestWait.holds(timeout: 10) { app.navigationBars["Vorschläge"].exists && suggestionRow().exists }
        // The demo library's second frequent place (`DemoLibrary.grandma`) has no name. Its
        // section comes after the countries and trips, and the list only makes the rows on
        // screen, so the list is scrolled until the row is there.
        let row = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", "Häufiger Ort")).firstMatch
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 12 {
            app.swipeUp()
            // pacing: kept, the scroll comes to rest before the tap measures the element's place
            sleep(1)
            swipes += 1
        }
        guard tap(row, "open personal place suggestion", timeout: 5) else { return }
        let opened = app.navigationBars["Vorschlag"].waitForExistence(timeout: 5)
        print(opened ? "UI_STEP_OK personal place detail opened" : "UI_STEP_MISSING personal place detail opened")
        XCTAssertTrue(opened, "Tapping the personal place did not open its detail")

        // The field is there to see and to tap, with its own label and examples for VoiceOver.
        let field = app.textFields["proposal.nameField"]
        // Up to the second of the old pause, then the five below, as before.
        _ = UITestWait.holds(timeout: 1) { field.exists && field.isHittable }
        if field.waitForExistence(timeout: 5) && !field.isHittable {
            app.swipeUp()
            // At most the old second, until the field can be tapped (asserted right after).
            _ = UITestWait.holds(timeout: 1) { field.isHittable }
        }
        let visible = field.exists && field.isHittable
        print(visible ? "UI_STEP_OK name field visible" : "UI_STEP_MISSING name field visible")
        XCTAssertTrue(visible, "The suggestion of a personal place shows no name field to tap")
        shot("70-personal-place-name-field")
        guard visible else { return }
        let prompt = field.placeholderValue ?? ""
        print("UI_FACT name field label '\(field.label)' prompt '\(prompt)' value '\(field.value as? String ?? "-")'")
        let described = field.label == "Name für das Album" && prompt.contains("Bei Oma")
        print(described ? "UI_STEP_OK name field has label and examples" : "UI_STEP_MISSING name field has label and examples")
        XCTAssertTrue(described, "The name field does not say what it is for: label '\(field.label)', prompt '\(prompt)'")

        // "Namen eingeben" is a working button: it puts the keyboard in the field.
        guard tap(app.buttons["Namen eingeben"], "tap Namen eingeben", timeout: 5) else { return }
        let focused = waitStable("keyboard in the name field", timeout: 10, stableChecks: 1) {
            (field.value(forKey: "hasKeyboardFocus") as? Bool) == true || app.keyboards.count > 0
        }
        print(focused ? "UI_STEP_OK keyboard in the name field" : "UI_STEP_MISSING keyboard in the name field")
        XCTAssertTrue(focused, "\"Namen eingeben\" did not put the keyboard in the name field")
        guard focused else { return }
        field.typeText("Bei Oma")
        let create = app.buttons["Album anlegen"]
        let ready = create.waitForExistence(timeout: 5) && create.isEnabled
        print(ready ? "UI_STEP_OK named place offers Album anlegen" : "UI_STEP_MISSING named place offers Album anlegen")
        XCTAssertTrue(ready, "With a name the suggestion does not offer an enabled \"Album anlegen\"")
        XCTAssertFalse(app.buttons["Namen eingeben"].exists, "\"Namen eingeben\" stayed although a name was typed")
        shot("71-personal-place-named")

        // Return only closes the keyboard: no preview opens, nothing is created.
        field.typeText("\n")
        // pacing: kept, the check below says Return opened nothing, and it looks after the old
        // two seconds.
        sleep(2)
        let stayed = app.navigationBars["Vorschlag"].exists && !app.navigationBars["Vorschau"].exists
        print(stayed ? "UI_STEP_OK return creates nothing" : "UI_STEP_MISSING return creates nothing")
        XCTAssertTrue(stayed, "Return in the name field left the suggestion")

        // "Anpassen" has the same name under "Titel", and a name changed there is in the field
        // afterwards, also when "Abbrechen" closes it (owner's device test 18.11.: "Dahoam"
        // typed in the suggestion, "Titel" in "Anpassen" was empty). "Anpassen" is in the "…"
        // menu at the top right (review P3-06).
        let typed = field.value as? String ?? ""
        if tap(moreActionsButton(), "more actions of the personal place", timeout: 5),
           tapMenuItem(menuItem("proposal.adjust", "Anpassen"), "open Anpassen with the typed name") {
            let title = app.textFields["adjust.titleField"]
            let there = title.waitForExistence(timeout: 5) ? (title.value as? String ?? "") : "-"
            print("UI_FACT name in the suggestion '\(typed)', in Anpassen '\(there)'")
            let carried = typed.lowercased() == "bei oma" && there == typed
            print(carried ? "UI_STEP_OK Anpassen shows the typed name" : "UI_STEP_MISSING Anpassen shows the typed name")
            XCTAssertTrue(carried, "\"Anpassen\" does not show the name typed in the suggestion: '\(there)' instead of '\(typed)'")
            if title.exists {
                title.tap()
                title.typeText(" und Opa")
            }
            let changed = title.exists ? (title.value as? String ?? "") : ""
            print("UI_FACT name changed in Anpassen to '\(changed)'")
            XCTAssertEqual(changed.lowercased(), "bei oma und opa", "The name could not be changed in \"Anpassen\"")
            shot("72-adjust-with-name")
            tap(app.buttons["Abbrechen"], "close Anpassen without choosing")
            XCTAssertTrue(waitGone(title, timeout: 5), "\"Abbrechen\" did not close \"Anpassen\"")
            // The name from "Anpassen" in the field (asserted right after, within the old second).
            _ = UITestWait.holds(timeout: 1) { !changed.isEmpty && (field.value as? String ?? "") == changed }
            let afterwards = field.value as? String ?? ""
            print("UI_FACT name in the suggestion after Anpassen '\(afterwards)'")
            let synced = !changed.isEmpty && afterwards == changed
            print(synced ? "UI_STEP_OK name from Anpassen in the field" : "UI_STEP_MISSING name from Anpassen in the field")
            XCTAssertTrue(synced, "The name changed in \"Anpassen\" is not in the suggestion's field: '\(afterwards)' instead of '\(changed)'")
            XCTAssertFalse(app.navigationBars["Vorschau"].exists, "Closing \"Anpassen\" opened a preview")
            shot("73-name-back-from-adjust")
        }

        // Back without creating: the row still waits for its name and is not selected.
        back()
        // pacing: kept, the check below says the row is not selected, and it looks after the old
        // second (a wait for the list would look sooner).
        sleep(1)
        let list = app.navigationBars["Vorschläge"].waitForExistence(timeout: 5)
        print(list ? "UI_STEP_OK back to suggestions without creating" : "UI_STEP_MISSING back to suggestions without creating")
        XCTAssertTrue(list, "Back from the personal place did not return to the list")
        func rowSays(_ text: String) -> Bool {
            row.label.contains(text)
                || row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        let untouched = row.waitForExistence(timeout: 5) && rowSays("Name fehlt") && !rowSays("Ausgewählt")
        print(untouched ? "UI_STEP_OK personal place untouched" : "UI_STEP_MISSING personal place untouched")
        XCTAssertTrue(untouched, "Going back from the named place stored the name or selected the suggestion")
    }

    // MARK: Taking a photo out of a suggestion

    /// Review P3-01 = G3-04 (18.11.): "N aus Vorschlag entfernen" sat in the bottom bar behind
    /// the tab bar (screenshot ui-08a-suggestion-photos), and test1 only selected a photo and
    /// never tapped the button. Here a photo is selected, the button is tapped and confirmed,
    /// and the suggestion has one photo less: in the title of its photos and in "Alle N Fotos
    /// ansehen". While selecting, the tab bar is hidden (as in Photos); afterwards it is back.
    func testRemovePhotoFromSuggestion() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("testRemovePhotoFromSuggestion")
        prepare()
        guard tap(reviewSuggestionsButton(), "open suggestions to remove a photo", timeout: 30),
              tap(suggestionRow(), "open a suggestion to remove a photo", timeout: 10),
              UITestWait.appears(app.navigationBars["Vorschlag"], "suggestion detail", timeout: 5) else { return }
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alle ")).firstMatch
        guard tap(all, "open all photos of the suggestion", timeout: 5) else { return }
        let photo = app.buttons["proposalPhotos.photo"].firstMatch
        guard UITestWait.appears(photo, "photos of the suggestion", timeout: 5) else { return }

        // "31 Fotos": the title of the suggestion's photos is their number.
        func count() -> Int? {
            let bar = app.navigationBars.firstMatch
            let titled = bar.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ Fotos?")).firstMatch
            let title = bar.identifier.contains("Foto") ? bar.identifier : (titled.exists ? titled.label : "")
            return title.firstMatch(of: #/([0-9.]+) Fotos?/#).flatMap { Int($0.1.replacingOccurrences(of: ".", with: "")) }
        }
        var seen: Int?
        UITestWait.until("number of the suggestion's photos", timeout: 5) {
            seen = count()
            return seen != nil
        }
        guard let before = seen else { return }
        print("UI_FACT suggestion photos before \(before)")
        guard before >= 2 else {
            XCTFail("The first suggestion has \(before) photo(s): nothing to take out and keep")
            return
        }

        guard tap(button("Auswählen"), "select a photo to take out", timeout: 5) else { return }
        photo.tap()
        let remove = app.buttons["proposalPhotos.remove"]
        // The button names one photo and is not behind the tab bar: the tab bar is hidden.
        let free = UITestWait.until("remove button free to tap", timeout: 5) {
            remove.exists && remove.isEnabled && remove.label.hasPrefix("1 ") && remove.isHittable && !tabBarHittable()
        }
        shot("08e-remove-from-suggestion")
        guard free else { return }
        remove.tap()
        let confirm = app.buttons["Entfernen"]
        guard tap(confirm, "confirm taking the photo out", timeout: 5) else { return }

        var after: Int?
        let fewer = UITestWait.until("suggestion has one photo less", timeout: 15) {
            after = count()
            return after == before - 1
        }
        print("UI_FACT suggestion photos after \(after.map { String($0) } ?? "-")")
        XCTAssertEqual(after, before - 1, "Taking one photo out of the suggestion did not lower its count by one")
        guard fewer else { return }
        // Selecting ended: the tab bar is back, the bottom bar gone.
        UITestWait.until("tab bar back after taking the photo out", timeout: 5) { tabBarHittable() && !remove.exists }
        shot("08f-photo-taken-out")

        back()
        // "Alle 2 Fotos ansehen", or "1 Foto ansehen" when one photo is left (the singular has no "Alle").
        let detailSays = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                                          "Alle \(before - 1) Foto", "\(before - 1) Foto ")).firstMatch
        UITestWait.appears(detailSays, "suggestion says \(before - 1) photos", timeout: 5)
    }
}
