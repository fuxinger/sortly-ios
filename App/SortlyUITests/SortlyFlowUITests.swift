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

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            XCTFail("Missing: \(step)")
            return false
        }
        var swipes = 0
        while !element.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }
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
                print("A11Y_ISSUE \(screen) | type \(issue.auditType.rawValue) | \(issue.compactDescription) | label '\(element?.label ?? "-")' | \(element?.elementType.rawValue ?? 0)")
                return true // collect everything, the report decides
            }
            print("A11Y_AUDIT_DONE \(screen)")
        } catch {
            print("A11Y_AUDIT_ERROR \(screen) \(error)")
        }
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 2) { allow.tap(); print("UI_STEP_OK system photo alert"); return }
        }
    }

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 4) { allow.tap(); print("UI_STEP_OK notification alert"); return }
        }
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
            tap(button("Weiter"), "access granted", timeout: 20)
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
            XCTAssertTrue(waitGone(demo, timeout: 600), "Demo library not created")
            print("UI_TIMING seed \(Int(Date().timeIntervalSince(started))) s")
        } else {
            print("UI_STEP_MISSING demo button (already seeded?)")
        }
        sleep(3)
        let analysed = Date()
        XCTAssertTrue(anything("Analyse aktuell").waitForExistence(timeout: 1200), "Analysis did not finish")
        print("UI_TIMING analysis \(Int(Date().timeIntervalSince(analysed))) s")
        sleep(2)
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
            if tap(app.buttons["Weitere Aktionen"], "more actions") {
                tap(button("Alle sicheren übernehmen"), "accept all safe")
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
            if tap(app.buttons["Reise-Atlas teilen"], "share atlas") {
                sleep(3)
                shot("13-share-card"); audit("share card")
                tap(button("Fertig"), "close share")
            }
            back(); sleep(1)
        }

        // Library
        if tap(app.tabBars.buttons["Mediathek"], "library tab") {
            sleep(2)
            shot("14-library"); audit("library")
            let photo = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
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
        if tap(app.tabBars.buttons["Alben"], "albums tab") {
            sleep(2)
            shot("18-albums"); audit("albums")
        }

        // Search
        let searchTab = app.tabBars.buttons["Suche"].exists ? app.tabBars.buttons["Suche"] : app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
        if tap(searchTab, "search tab") {
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
        if tap(app.tabBars.buttons["Übersicht"], "overview tab") {
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
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        sleep(5)
        shot("30-overview-xxxl-dark"); audit("overview xxxl dark")
        if tap(button("Reise-Atlas"), "open atlas xxxl", timeout: 20) {
            sleep(6)
            shot("31-atlas-xxxl-dark")
            back()
        }
        if tap(app.tabBars.buttons["Mediathek"], "library xxxl") {
            sleep(2)
            shot("32-library-xxxl-dark"); audit("library xxxl dark")
        }
        XCUIDevice.shared.appearance = .light
    }
}
