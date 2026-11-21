import XCTest
import UIKit

/// Accessibility run on its own small iPhone (CI job "Accessibility", iPhone SE size, Reduce
/// Motion on; see `.github/workflows/ui.yml`). Unlike the UI flow, which only prints what the
/// audit finds, these tests FAIL on real findings:
///
/// Failing audit types (`performAccessibilityAudit`):
/// - `.contrast` "Contrast failed" (clearly below WCAG AA)
/// - `.textClipped` at the accessibility text sizes, for text on one line ("Gan…thek")
/// - `.hitRegion` (target too small to tap)
/// - `.sufficientElementDescription` (missing or useless VoiceOver label)
///
/// Failing checks of our own (from one snapshot of the accessibility tree per screen):
/// - a button or link without a label, and a button, link or switch labelled "-" or with an
///   SF Symbol name ("chevron.right"), which VoiceOver would read out. Images and the inner
///   knob of a toggle are left to the audit: the tree also lists elements VoiceOver never
///   visits (`accessibilityHidden` thumbnails, the switch inside a labelled toggle), the
///   audit only real accessibility elements.
/// - a visible format placeholder ("%lld", "%@") and, in the English run, German words
///   left in the interface (untranslated strings)
/// - text that runs off the side of the screen
/// - a country row of the atlas at the largest text size taller than its words need (a name
///   or year broken mid-word, review P3-11, `checkAtlasRows`), and the folder label in the
///   settings cut on one line at any size (P3-17, `checkFullyShown`)
///
/// Also failing: an audit that does not complete in two attempts ("Audit failed to complete in
/// time", each attempt printed as `A11Y_AUDIT_ERROR`): the screen would otherwise pass unchecked.
///
/// Reported, not failing (`A11Y_WARN`), each with its reason:
/// - "Contrast nearly passed": the system `secondaryLabel` colour Apple uses for secondary
///   text is 3.3–3.4:1 on light backgrounds (5.9–6.4:1 in dark mode); the app keeps the
///   system colour, see the report in the commit
/// - findings on disabled controls (WCAG 1.4.3 exempts inactive components)
/// - findings on or under the system's Liquid Glass bars (navigation bar, tab bar, toolbar,
///   bottom search field): XCTest cannot measure text on glass (Apple's own "Fertig" button
///   fails there), and content scrolling under a bar is cut by design; so is content passing
///   under the preview's own opaque bar with "Alben jetzt anlegen" ("plan.bar", review P3-05).
///   The elements inside that bar (its promise, button and notes) are not exempt: they are
///   audited like any content and fail the test (`ownBarElements`)
/// - contrast findings without an element on screens with such a bar: XCTest found text it
///   cannot attribute (text inside a combined row), which in the UI flow was always a row
///   passing under the tab bar
/// - text cut at the top or bottom edge of the screen (scrolled, not clipped)
/// - `.textClipped` at standard text sizes and on text that already wraps: the audit also
///   reports text that only clips once it grows, and wrapped text whose every line is shown
///   (checked in the screenshots); the run at the largest size is the real test
/// - findings on emoji only (country flags are pictures, not text) and inside a labelled
///   picture (the scaled-down share image preview, read out as one image)
/// - "Contrast failed" that does not repeat in a second contrast audit two seconds later
///   (measured while the screen moved; see `confirmContrast`)
/// - positions: XCTest can scroll while it audits, so an element counts as under a bar when
///   it was there in the snapshot taken just before the audit or is there afterwards. Bars
///   reach 12 pt into the content (the scroll edge effect), the keyboard 48 pt (its word
///   suggestions, three unlabelled system buttons)
/// - `.dynamicType`, `.elementDetection` and `.trait` are not audited here: the tests run at
///   the largest text size anyway, which is the stronger check, and the Dynamic Type audit
///   flags the intentional caps (progress ring, share image)
///
/// Every screen also prints a screenshot (`PREVIEW_JPEG ui-a11y-…`), like the UI flow.
@MainActor
final class AccessibilityUITests: XCTestCase {
    private var app = XCUIApplication()
    private var auditFailures: [String] = []
    private var screenFailures: [String] = []
    /// The current launch runs at an accessibility text size.
    private var accessibilitySize = false
    /// Frames by label from the snapshot just before the audit (see the class comment).
    private var framesBeforeAudit: [String: [CGRect]] = [:]
    /// Labelled pictures that contain text (share image preview).
    private var pictureFrames: [CGRect] = []
    /// The elements inside the preview's own bar ("plan.bar": promise, "Alben jetzt anlegen",
    /// notes) by label and frame, noted with the chrome frames: audited like any content, a
    /// finding on them fails as before; only what passes under the bar counts as under a bar.
    private var ownBarElements: [(label: String, frame: CGRect)] = []
    /// "Contrast failed" findings waiting for the second contrast audit.
    private var pendingContrast: [(label: String, line: String, detail: String)] = []

    private static let largestText = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let failingAuditTypes: XCUIAccessibilityAuditType = [.contrast, .textClipped, .hitRegion, .sufficientElementDescription]

    /// Labels the walk taps, per language (from Localizable.xcstrings).
    private struct Words {
        var overviewTab: String
        var libraryTab: String
        var albumsTab: String
        var settings: String
        var done: String
        /// A pattern: the count is singular or plural ("1 Vorschlag prüfen" once only one
        /// suggestion is left open, UI run 43796844064).
        var reviewSuggestions: String
        var suggestionTitle: String
        /// The list "… Vorschläge prüfen" opens (all areas, so the plain title).
        var suggestionsTitle: String
        var rowMarker: String
        var starterPattern: String
        var planTitle: String
        var applyNow: String
        var undo: String
        var atlas: String
        var shareAtlas: String
        /// The share card's preview image (ShareCardSheet).
        var sharePreview: String
        var searchQuery: String
        var country: String
        /// Titles of screens the walk opens and goes back from: it waits for their bar.
        var receiptTitle: String
        var historyTitle: String
        /// The label of the folder field in the settings (review P3-17: cut at the default size).
        var folderLabel: String
        /// What the screens show while they load (their spinners' labels): the walk waits until
        /// they are gone instead of a fixed time.
        var planLoading: String
        var photoLoading: String
        /// The sorting show's one VoiceOver element (SortingShow).
        var sortingShow: String
        /// The receipt's share button, there once the receipt is loaded (PlanReceiptView).
        var shareReceipt: String

        static let german = Words(overviewTab: "Übersicht", libraryTab: "Mediathek", albumsTab: "Alben",
                                  settings: "Einstellungen", done: "Fertig", reviewSuggestions: ".*[0-9.]+ Vorschl(ag|äge) prüfen.*",
                                  suggestionTitle: "Vorschlag", suggestionsTitle: "Vorschläge", rowMarker: "Fotos",
                                  starterPattern: "[0-9]+ Alben (kostenlos )?anlegen", planTitle: "Vorschau",
                                  applyNow: "Alben jetzt anlegen", undo: "Rückgängig machen", atlas: "Reise-Atlas",
                                  shareAtlas: "Reise-Atlas teilen", sharePreview: "Vorschau des Teilen-Bilds", searchQuery: "Rom", country: "Italien",
                                  receiptTitle: "Änderungen", historyTitle: "Verlauf und Rückgängig",
                                  folderLabel: "Ordner für neue Alben", planLoading: "Plan wird erstellt",
                                  photoLoading: "Foto wird geladen", sortingShow: "Fotos werden einsortiert",
                                  shareReceipt: "Liste teilen")
        static let english = Words(overviewTab: "Overview", libraryTab: "Library", albumsTab: "Albums",
                                   settings: "Settings", done: "Done", reviewSuggestions: ".*Review [0-9,]+ [Ss]uggestions?.*",
                                   suggestionTitle: "Suggestion", suggestionsTitle: "Suggestions", rowMarker: "photo",
                                   starterPattern: "Create [0-9]+ Albums?( for Free)?", planTitle: "Preview",
                                   applyNow: "Create Albums Now", undo: "Undo", atlas: "Travel Atlas",
                                   shareAtlas: "Share Travel Atlas", sharePreview: "Preview of the share image", searchQuery: "Rome", country: "Italy",
                                   receiptTitle: "Changes", historyTitle: "History and Undo",
                                   folderLabel: "Folder for New Albums", planLoading: "Creating plan",
                                   photoLoading: "Loading photo", sortingShow: "Sorting photos",
                                   shareReceipt: "Share List")
    }

    // MARK: Tests

    /// First start at the largest accessibility text size in dark mode: every onboarding step,
    /// then the demo library and its analysis, which the later tests use.
    func test1_OnboardingAtLargestTextInDarkMode() {
        continueAfterFailure = true
        UITestOnboarding.accessibilityOnboarding.starts()
        // Test 1 runs first on a freshly erased simulator (ui.yml; a repeat after a simulator
        // failure erases it again), so it always meets the welcome screen and checks every step.
        // An issue that ends the method early must not let it pass without its later checks.
        let end = UITestOnboarding.accessibilityOnboarding.finished
        addTeardownBlock {
            if !FileManager.default.fileExists(atPath: end.path) {
                print("UI_STEP_MISSING accessibility onboarding reached its end")
                XCTFail("test1_OnboardingAtLargestTextInDarkMode stopped before its end")
            }
        }
        launch(textSize: Self.largestText, dark: true)
        if !onboardAndSeed(checking: true) {
            print("UI_STEP_MISSING onboarding")
            XCTFail("test1 must start on a fresh simulator: no welcome screen, so the onboarding was not checked")
        }
        check("overview after first analysis")
        UITestOnboarding.accessibilityOnboarding.ends()
        finish("onboarding")
    }

    /// Test 1 did not reach its end (or did not run): onboarding, demo library and analysis
    /// first, without audits, so one cut-off test 1 does not fail every later test (run
    /// 43823834271: a timed-out query ended test 1 while the demo library was being created,
    /// and tests 2 to 4 found no suggestions).
    private func completeOnboardingIfCutOff(_ test: String) {
        guard !UITestOnboarding.accessibilityOnboarding.reachedItsEnd else { return }
        print("UI_FACT \(test): test 1 did not reach its end, onboarding and demo library first")
        launch()
        onboardAndSeed(checking: false)
    }

    /// Onboarding, demo library and its analysis, when the app is at its first start. Test 1
    /// does this with an audit of every step; a later test that finds the app new does it
    /// without (run 43796844064: the simulator service dropped the first pass before any test
    /// ran, and the contrast pass met the welcome screen instead of the overview).
    /// False when the app was past the onboarding already.
    @discardableResult
    private func onboardAndSeed(checking: Bool) -> Bool {
        let welcome = button("Los geht").waitForExistence(timeout: checking ? 30 : 10)
        if welcome {
            if !checking { print("UI_FACT app at its first start: onboarding and demo library first") }
            if checking { check("onboarding welcome") }
            tap(button("Los geht"), "welcome")
            if checking { check("onboarding areas") }
            tap(button("Weiter"), "areas")
            if checking { check("onboarding access") }
            if button("Zugriff erlauben").waitForExistence(timeout: 5) {
                button("Zugriff erlauben").tap()
                allowPhotosIfAsked()
            }
            if button("Weiter").waitForExistence(timeout: 3) { button("Weiter").tap() }
            let trial = button("Analyse starten").waitForExistence(timeout: 20)
            XCTAssertTrue(trial, "Onboarding did not reach the trial step")
            if checking { check("onboarding trial") }
            tap(button("Analyse starten"), "start analysis")
            allowNotificationsIfAsked()
        }
        let demo = button("Beispiel-Mediathek anlegen")
        let seeds = demo.waitForExistence(timeout: welcome ? 30 : 5)
        if seeds {
            if seedDemoLibrary(demo) {
                XCTAssertTrue(UITestOnboarding.demoLibraryCreated(app), "Demo library not created")
            }
        } else if checking {
            print("UI_STEP_MISSING demo button")
            XCTFail("No \"Beispiel-Mediathek anlegen\" after the onboarding on a fresh simulator")
        }
        XCTAssertTrue(waitStable("analysis finished", timeout: 1200) { analysisIdle }, "Analysis did not finish")
        let test = checking ? "accessibility test 1" : "accessibility"
        if welcome || seeds {
            // This test watched the analysis run to its end: a partial count now is an early stop.
            UITestOnboarding.expectCompleteAnalysis(app, in: test)
        } else {
            // A relaunch into a library seeded earlier, whose analysis a restarted runner may have cut off.
            UITestOnboarding.finishInterruptedAnalysis(app, in: test)
        }
        return welcome
    }

    /// The main screens in English at the default text size, light mode: nothing German left,
    /// nothing clipped, contrast and labels as in German. Runs before anything is applied, so
    /// no album names from a German run are on screen.
    func test2_EnglishMainScreens() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test2")
        launch(english: true)
        walk("en", .english, english: true)
        finish("english")
    }

    /// Largest accessibility text size, dark mode, Reduce Motion (set for this simulator by
    /// the workflow): every main screen, then the starter set is applied, so the sorting show,
    /// the result and the change receipt are checked too.
    func test3_LargestTextDarkModeReduceMotion() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test3")
        launch(textSize: Self.largestText, dark: true)
        walk("xxxl", .german, applyStarter: true)
        finish("largest text")
    }

    /// The small iPhone turned sideways. Version 1 is portrait only (Fuchs 15.11.2026,
    /// `UISupportedInterfaceOrientations` in App/project.yml): the app must stay upright and
    /// whole while the device lies on its side. (UI run on PR #12, 20.11.: the wait for a
    /// landscape layout timed out, because the app rightly never turns.)
    func test4_Landscape() {
        continueAfterFailure = true
        completeOnboardingIfCutOff("test4")
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        UITestWait.until("device turned to landscape", timeout: 10) {
            XCUIDevice.shared.orientation == .landscapeLeft
        }
        _ = UITestWait.never("app turned although it is portrait only", for: 3) {
            let window = app.windows.firstMatch
            return window.exists && window.frame.width > window.frame.height
        }
        walk("landscape", .german, short: true)
        finish("landscape")
    }

    /// Increase Contrast and Reduce Transparency (switched on by the workflow before this test
    /// runs on its own), light and dark: the high-contrast colour variants must hold everywhere.
    func test5_IncreasedContrastAndReducedTransparency() {
        continueAfterFailure = true
        launch()
        onboardAndSeed(checking: false)
        walk("contrast light", .german, short: true)
        launch(dark: true)
        walk("contrast dark", .german, short: true)
        finish("increased contrast")
    }

    // MARK: Walk

    /// Overview, suggestions, one suggestion, the starter plan, atlas and share image, library,
    /// albums, search and settings; `short` leaves out the lower halves and the side screens.
    private func walk(_ tag: String, _ w: Words, english: Bool = false, applyStarter: Bool = false, short: Bool = false) {
        let overview = tabButton(w.overviewTab)
        if overview.waitForExistence(timeout: 20) { overview.tap() }
        UITestWait.appears(app.navigationBars[w.overviewTab], "\(tag) overview shown", timeout: 20)
        // Right after an analysis the "Analyse fertig" card carries "Vorschläge prüfen" without a
        // number ("analysis.review") and the counted button waits until it is gone: in the
        // contrast run of UI run 44880878362 the light walk found only the card's button.
        let reviewSuggestions = app.buttons.matching(NSPredicate(format: "label MATCHES %@ OR identifier == %@",
                                                                 w.reviewSuggestions, "analysis.review")).firstMatch
        // Its content, not only its bar: the suggestions button the walk taps next. Not asserted
        // here, the tap below says when it is missing.
        _ = reviewSuggestions.waitForExistence(timeout: 20)
        // check() waits for the screen to come to rest after every swipe before it.
        check("\(tag) overview", english: english)
        if !short {
            app.swipeUp(); app.swipeUp()
            check("\(tag) overview lower", english: english)
            app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
            UITestWait.screenAtRest(app, "\(tag) overview back at the top")
        }

        // Suggestions and one suggestion
        // A tap that landed elsewhere (on a bar) fails here by its name, not steps later.
        if tap(reviewSuggestions, "\(tag) open suggestions", timeout: 20),
           opened(app.navigationBars[w.suggestionsTitle], "\(tag) suggestions") {
            check("\(tag) suggestions", english: english)
            // A List only creates the rows on screen; at the largest text size the first row
            // starts below the fold. After each swipe the row has up to the old second to show.
            let row = suggestionRow(w.rowMarker)
            var swipes = 0
            while !row.exists && swipes < 6 { app.swipeUp(); swipes += 1; _ = row.waitForExistence(timeout: 1) }
            if tap(row, "\(tag) open suggestion", timeout: 10) {
                let detailShown = app.navigationBars[w.suggestionTitle].waitForExistence(timeout: 5)
                print(detailShown ? "UI_STEP_OK \(tag) suggestion opened" : "UI_STEP_MISSING \(tag) suggestion opened")
                XCTAssertTrue(detailShown, "Not opened: \(tag) suggestion (the tap landed elsewhere)")
                check("\(tag) suggestion detail", english: english)
                if !short {
                    app.swipeUp()
                    check("\(tag) suggestion detail lower", english: english)
                }
                back("\(tag) suggestion detail", confirmed: detailShown)
                // Gone, not "the list is there": a detail that never opened is already gone.
                UITestWait.disappears(app.navigationBars[w.suggestionTitle], "\(tag) suggestion detail closed", timeout: 10)
            }
            back("\(tag) suggestions", confirmed: false)
            backOnOverview(w, "\(tag) suggestions")
        }

        // The starter set opens the plan; going back selects nothing. Once it has been applied
        // (test 3) the card is gone.
        let starter = app.buttons.matching(NSPredicate(format: "label MATCHES %@", w.starterPattern)).firstMatch
        if !starter.waitForExistence(timeout: 8) {
            print("UI_STEP_SKIPPED \(tag) starter plan (no starter set on the overview)")
        } else if tap(starter, "\(tag) open starter plan", timeout: 10) {
            let planShown = app.navigationBars[w.planTitle].waitForExistence(timeout: 20)
            // A tap on the clear part of a row (largest text) that missed would otherwise pass
            // silently: the plan has to be open.
            print(planShown ? "UI_STEP_OK \(tag) starter plan opened" : "UI_STEP_MISSING \(tag) starter plan opened")
            XCTAssertTrue(planShown, "Not opened: \(tag) starter plan (the tap landed elsewhere)")
            if planShown {
                // The plan itself, not its spinner: the screen opens with "Plan wird erstellt".
                UITestWait.disappears(anything(exactly: w.planLoading), "\(tag) starter plan made", timeout: 30)
                check("\(tag) plan", english: english)
                expectApplyInReach("\(tag) plan", required: applyStarter)
                if !short {
                    app.swipeUp(); app.swipeUp()
                    check("\(tag) plan lower", english: english)
                }
                if applyStarter, tap(button(w.applyNow), "\(tag) apply plan", timeout: 30) {
                    // The sorting show; with Reduce Motion one album at a time, cross-faded. The
                    // first picture once the show is on screen (not asserted: a short plan may
                    // be past it already), the second a set time later to catch a later album.
                    _ = anything(exactly: w.sortingShow).waitForExistence(timeout: 5)
                    shot("a11y-\(slug(tag))-sorting-show-1")
                    // pacing: the second picture of the show, 1.5 s after the first; the time
                    // between them is the point (another album on screen), there is no state.
                    usleep(1_500_000); shot("a11y-\(slug(tag))-sorting-show-2")
                    if button(w.undo).waitForExistence(timeout: 600) {
                        // The result replaces the show, which fades out over it first.
                        UITestWait.disappears(anything(exactly: w.sortingShow), "\(tag) sorting show ended", timeout: 10)
                        check("\(tag) result", english: english)
                        let receipt = app.buttons["result.receipt"]
                        if tap(receipt, "\(tag) open receipt", timeout: 10),
                           opened(app.navigationBars[w.receiptTitle], "\(tag) receipt") {
                            // The receipt loads after the screen opens (an empty list until then):
                            // its rows, or the share button that comes with the loaded receipt.
                            UITestWait.until("\(tag) receipt loaded", timeout: 20) {
                                app.collectionViews.cells.firstMatch.exists || app.buttons[w.shareReceipt].exists
                            }
                            check("\(tag) receipt", english: english)
                            back("\(tag) receipt", confirmed: true)
                            UITestWait.disappears(app.navigationBars[w.receiptTitle], "\(tag) receipt closed", timeout: 10)
                        }
                    } else {
                        XCTFail("The starter plan did not finish")
                    }
                }
            }
            back("\(tag) starter plan", confirmed: planShown)
            backOnOverview(w, "\(tag) starter plan")
        }

        // Travel atlas and the share image
        if tap(button(w.atlas), "\(tag) open atlas", timeout: 20), opened(app.navigationBars[w.atlas], "\(tag) atlas") {
            // pacing: the map draws before the audit; opened() checked the atlas screen
            sleep(3)
            check("\(tag) atlas", english: english)
            if !short {
                app.swipeUp(); app.swipeUp()
                check("\(tag) atlas lower", english: english)
                if accessibilitySize { checkAtlasRows(tag) }
                // A country: its photo colours sit behind the title and caption.
                let country = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", w.country)).firstMatch
                // Its screen is called by the country's name.
                if tap(country, "\(tag) open country", timeout: 10), opened(app.navigationBars[w.country], "\(tag) country") {
                    // Kept: the colour wash behind the title and caption (PhotoGlow) comes from a
                    // photo that loads after the screen and fades in over 0.8 s. It is hidden from
                    // VoiceOver and only fades, so neither an element nor a frame says it is
                    // there, and the contrast audit is meant to measure the text on it.
                    sleep(2)
                    check("\(tag) country", english: english)
                    back("\(tag) country", confirmed: true)
                    UITestWait.disappears(app.navigationBars[w.country], "\(tag) country closed", timeout: 10)
                }
                app.swipeDown(); app.swipeDown(); app.swipeDown()
                UITestWait.screenAtRest(app, "\(tag) atlas back at the top")
                if tap(app.buttons[w.shareAtlas], "\(tag) share atlas", timeout: 5) {
                    let shownAt = Date()
                    // The card itself before the audit (its preview), and at least the old 3 s:
                    // the outlines and the cover load after the sheet is shown (second review of C2).
                    UITestWait.appears(button(w.done), "\(tag) share card with its done button", timeout: 20)
                    UITestWait.appears(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", w.sharePreview)).firstMatch,
                                       "\(tag) share card preview", timeout: 20)
                    UITestWait.atLeast(3, since: shownAt)
                    check("\(tag) share sheet", english: english)
                    tap(button(w.done), "\(tag) close share")
                    UITestWait.disappears(anything(exactly: w.sharePreview), "\(tag) share card closed", timeout: 10)
                }
            }
            back("\(tag) atlas", confirmed: true)
            backOnOverview(w, "\(tag) atlas")
        }

        // Tabs
        if tap(tabButton(w.libraryTab), "\(tag) library tab") {
            UITestWait.appears(app.navigationBars[w.libraryTab], "\(tag) library shown", timeout: 10)
            // The first pass over the photos shows "Fotos werden zusammengestellt …" instead of them.
            UITestWait.disappears(app.descendants(matching: .any).matching(identifier: "library.preparing").firstMatch,
                                  "\(tag) library photos listed", timeout: 30)
            check("\(tag) library", english: english)
            // Design review W11/W12: the photo viewer (system toolbar) and its info sheet.
            let photo = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*20[0-9][0-9].*")).firstMatch
            if !short, photo.waitForExistence(timeout: 5), tap(photo, "\(tag) open photo", timeout: 5) {
                UITestWait.appears(app.buttons["viewer.close"], "\(tag) photo viewer shown", timeout: 10)
                // The photo itself, not its spinner ("Foto wird geladen" until Photos delivers it).
                // Only a spinner on screen counts: the pages beside it load their own.
                let spinners = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", w.photoLoading))
                UITestWait.until("\(tag) photo loaded", timeout: 20) {
                    let screen = app.frame
                    for spinner in spinners.allElementsBoundByIndex {
                        // A snapshot, not `frame`: a spinner that went away meanwhile is no failure.
                        if let seen = try? spinner.snapshot(), screen.contains(CGPoint(x: seen.frame.midX, y: seen.frame.midY)) {
                            return false
                        }
                    }
                    return true
                }
                check("\(tag) photo viewer", english: english)
                if tap(app.buttons["viewer.info"], "\(tag) photo info", timeout: 5) {
                    UITestWait.appears(app.buttons["detail.close"], "\(tag) photo info shown", timeout: 10)
                    check("\(tag) photo info", english: english)
                    tap(app.buttons["detail.close"], "\(tag) close photo info")
                    UITestWait.disappears(app.buttons["detail.close"], "\(tag) photo info closed", timeout: 10)
                }
                tap(app.buttons["viewer.close"], "\(tag) close photo", timeout: 5)
                UITestWait.disappears(app.buttons["viewer.close"], "\(tag) photo viewer closed", timeout: 10)
            }
        }
        if tap(tabButton(w.albumsTab), "\(tag) albums tab") {
            UITestWait.appears(app.navigationBars[w.albumsTab], "\(tag) albums shown", timeout: 10)
            check("\(tag) albums", english: english)
        }
        // Settings
        if tap(tabButton(w.overviewTab), "\(tag) back to overview"), tap(app.buttons[w.settings], "\(tag) settings") {
            UITestWait.appears(app.navigationBars[w.settings], "\(tag) settings shown", timeout: 10)
            check("\(tag) settings", english: english)
            if !short {
                // Design review W16: history and undo on their own screen. Opened first, from
                // the top of the list: after scrolling down and back the first row was not in
                // the tree again (UI run 43773339053, "history" missing).
                if tap(app.buttons["settings.history"], "\(tag) history", timeout: 5),
                   opened(app.navigationBars[w.historyTitle], "\(tag) history") {
                    check("\(tag) history", english: english)
                    back("\(tag) history", confirmed: true)
                    UITestWait.disappears(app.navigationBars[w.historyTitle], "\(tag) history closed", timeout: 10)
                }
                let list = app.collectionViews.firstMatch
                (list.exists ? list : app).swipeUp(); (list.exists ? list : app).swipeUp()
                check("\(tag) settings lower", english: english)
                checkFullyShown(w.folderLabel, identifier: "settings.rootFolder.label", "\(tag) settings", in: list.exists ? list : app)
            }
            tap(button(w.done), "\(tag) close settings")
            UITestWait.disappears(app.navigationBars[w.settings], "\(tag) settings closed", timeout: 10)
        }

        // Search last: the search tab focuses its field, and the keyboard covers the tab bar.
        if !short, tap(searchTabButton(), "\(tag) search tab") {
            UITestWait.appears(app.searchFields.firstMatch, "\(tag) search field shown", timeout: 10)
            // The keyboard the focused field brings up, so the check sees it as it stays; not
            // asserted (without it the check runs as before, on the whole screen).
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            check("\(tag) search", english: english)
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText(w.searchQuery)
                // The search's answer before the audit: its chips, results or empty state
                // (SearchView sets them together). What they say is checked in SearchUITests.
                let answer = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier IN %@", ["search.token", "search.ignored", "search.result", "search.empty"])).firstMatch
                UITestWait.appears(answer, "\(tag) search answered '\(w.searchQuery)'", timeout: 10)
                // The keyboard covers the lower half; the results and chips above it count.
                check("\(tag) search results", english: english)
                // The walk ends here; nothing waits for what the return does.
                field.typeText("\n")
            }
        }
    }

    /// Back on the overview after leaving a screen opened from it: its bar is there again. A
    /// screen that closed by itself (see `back`) finds it at once.
    private func backOnOverview(_ w: Words, _ step: String) {
        UITestWait.appears(app.navigationBars[w.overviewTab], "back on the overview from \(step)", timeout: 10)
    }

    // MARK: Checks

    /// Screenshot, audit and tree checks for what is on screen now.
    private func check(_ screen: String, english: Bool = false) {
        // Let a scroll come to rest, so screenshot, tree and audit see the same positions. Push,
        // sheet and fade transitions move no frame and are not seen here: the callers wait for
        // the screen's own elements, and `confirmContrast` measures a contrast failure again.
        // The snapshot that showed the screen still is the one the tree checks read.
        var still: (any XCUIElementSnapshot)?
        switch UITestWait.screenAtRest(app, "\(screen) at rest") {
        case .still(let root): still = root
        case .moving: break // failed in the wait
        case .unread: print("A11Y_WARN \(screen) | not checked at rest: no snapshot")
        }
        answerLateNotificationAlert(before: screen)
        shot("a11y-" + slug(screen))
        let chrome = chromeFrames()
        UITestOnboarding.clock("check start \(screen)")
        inspectTree(screen, root: still, chrome: chrome, english: english)
        audit(screen, chrome: chrome)
        UITestOnboarding.clock("check end \(screen)")
        let failures = auditFailures + screenFailures
        if failures.isEmpty {
            print("A11Y_SCREEN_OK \(screen)")
        } else {
            print("A11Y_SCREEN_FAILED \(screen) \(failures.count)")
            XCTFail("\(screen): \(failures.count) accessibility finding(s): " + failures.prefix(8).joined(separator: " · "))
        }
        auditFailures = []
        screenFailures = []
    }

    /// Frames of the system's Liquid Glass chrome: navigation bars, tab bar, toolbars and
    /// search fields (in iOS 26 a sheet's search field floats at the bottom like a toolbar),
    /// and the preview's own bar at the bottom ("plan.bar"), whose own elements are noted in
    /// `ownBarElements` and stay audited.
    private func chromeFrames() -> [CGRect] {
        var frames: [CGRect] = []
        // The keyboard covers content like a bar does.
        for query in [app.navigationBars, app.tabBars, app.toolbars] {
            for element in query.allElementsBoundByIndex where element.exists {
                // The scroll edge effect softens content for a few points beyond the bar.
                frames.append(element.frame.insetBy(dx: 0, dy: -12))
            }
        }
        // The status bar: content scrolling under it (onboarding) shares its pixels with the clock.
        let top = app.frame
        frames.append(CGRect(x: top.minX, y: top.minY, width: top.width, height: top.height > 800 ? 54 : 20))
        for keyboard in app.keyboards.allElementsBoundByIndex where keyboard.exists {
            // The word suggestions sit in a 44 pt strip above the keyboard's frame.
            let frame = keyboard.frame
            frames.append(CGRect(x: frame.minX, y: frame.minY - 48, width: frame.width, height: frame.height + 48))
        }
        for field in app.searchFields.allElementsBoundByIndex where field.exists {
            frames.append(field.frame.insetBy(dx: -8, dy: -8))
        }
        // The preview's own bar with "Alben jetzt anlegen" (`PlanReviewView.applyBar`, review
        // P3-05): opaque, so a row passing under it is cut by design, as under the tab bar. The
        // elements inside it are noted (`ownBarElements`) and audited like any content: the
        // screen's main action fails the test as before. Without them (no snapshot of the bar)
        // the bar is not counted at all, so its button never passes as something under it.
        ownBarElements = []
        for bar in app.descendants(matching: .any).matching(identifier: "plan.bar").allElementsBoundByIndex where bar.exists {
            guard let snapshot = try? bar.snapshot() else { continue }
            frames.append(snapshot.frame)
            // The bar itself and everything inside it.
            var inside: [any XCUIElementSnapshot] = [snapshot]
            while let element = inside.popLast() {
                ownBarElements.append((element.label.trimmingCharacters(in: .whitespacesAndNewlines), element.frame))
                inside += element.children
            }
        }
        // Only real bars count: at the top or bottom edge and not taller than the keyboard
        // (45 % of the screen). Anything else would exempt the middle of the screen.
        let screen = app.frame
        let bars = frames.filter { frame in
            !frame.isEmpty && frame.height < screen.height * 0.45
                && (frame.minY <= screen.minY + screen.height * 0.3 || frame.maxY >= screen.maxY - screen.height * 0.3)
        }
        let described = frames.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: "; ")
        print("A11Y_CHROME \(frames.count) frames, \(bars.count) used: \(described)")
        return bars
    }

    /// One of the elements inside the preview's own bar (`ownBarElements`): the same label and
    /// frame. The bar does not scroll, so its elements stand where they were noted.
    private func isOwnBarElement(label: String, frame: CGRect) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownBarElements.contains { own in
            own.label == label && abs(own.frame.minX - frame.minX) < 1 && abs(own.frame.minY - frame.minY) < 1
                && abs(own.frame.width - frame.width) < 1 && abs(own.frame.height - frame.height) < 1
        }
    }

    private func audit(_ screen: String, chrome: [CGRect]) {
        let bounds = app.frame
        // A screen with a bar over scrolling content (see the class comment).
        let barOverContent = app.tabBars.firstMatch.exists || app.toolbars.firstMatch.exists || app.searchFields.firstMatch.exists
        // An element that changes while the audit reads the screen makes XCTest record
        // "Failed to get matching snapshot"; that says nothing about the app.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("Failed to get matching snapshot") }
        for attempt in 1...2 {
            var finished = false
            XCTExpectFailure("The screen changed during the accessibility audit", options: options) {
                do {
                    try app.performAccessibilityAudit(for: Self.failingAuditTypes) { issue in
                        self.record(issue, screen: screen, chrome: chrome, bounds: bounds, barOverContent: barOverContent)
                        return true // handled here: failures are collected and reported per screen
                    }
                    finished = true
                } catch {
                    print("A11Y_AUDIT_ERROR \(screen) attempt \(attempt) \(error.localizedDescription)")
                }
            }
            if finished {
                confirmContrast(screen)
                return
            }
            auditFailures = []
            pendingContrast = []
            // Kept: the pause before the second attempt of an audit that did not complete (a
            // busy simulator). Nothing on screen says the simulator has caught up.
            sleep(2)
        }
        // "Audit failed to complete in time" twice: the screen went unaudited, and a screen nobody
        // checked must not pass (Prüfer B G5-06). The tree checks still ran; check() fails the test.
        print("A11Y_FAIL \(screen) | audit | did not complete in 2 attempts, screen not audited")
        auditFailures.append("audit did not complete in 2 attempts, screen not audited")
    }

    /// "Contrast failed" must repeat in a second contrast audit two seconds later to count.
    /// In UI run 2 and 3 the first audit reported black titles and buttons on white (over
    /// 15:1) on screens that had just scrolled: it measured them mid-movement. Text that
    /// really lacks contrast fails both times.
    private func confirmContrast(_ screen: String) {
        guard !pendingContrast.isEmpty else { return }
        let pending = pendingContrast
        pendingContrast = []
        // Kept: the two seconds are the check. A fade (opacity) that the first audit measured
        // moves no frame, so there is no state to wait for; text that lacks contrast fails both.
        sleep(2)
        var again = Set<String>()
        do {
            try app.performAccessibilityAudit(for: .contrast) { issue in
                if !issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
                    again.insert(issue.element?.label ?? "-")
                }
                return true
            }
        } catch {
            // Without a second measurement the first one stands.
            print("A11Y_AUDIT_ERROR \(screen) contrast confirmation \(error.localizedDescription)")
            again = Set(pending.map { $0.label })
        }
        for finding in pending {
            if again.contains(finding.label) {
                print("A11Y_FAIL \(finding.line)")
                print("A11Y_DETAIL \(screen) | \(finding.detail)")
                auditFailures.append("contrast '\(finding.label.prefix(40))'")
            } else {
                print("A11Y_WARN \(finding.line) | did not repeat in a second contrast audit (measured mid-movement)")
            }
        }
    }

    private func record(_ issue: XCUIAccessibilityAuditIssue, screen: String, chrome: [CGRect], bounds: CGRect, barOverContent: Bool) {
        let type = issue.auditType
        let summary = issue.compactDescription
        var reason: String?
        var where_ = "-"
        var label = "-"
        if let element = issue.element {
            let frame = element.frame
            label = element.label
            where_ = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) type \(element.elementType.rawValue) id '\(element.identifier)'"
            // The same element before the audit: same label, column and size (a scroll only moves it up or down).
            let before = (framesBeforeAudit[label] ?? []).filter {
                abs($0.minX - frame.minX) < 1 && abs($0.width - frame.width) < 1 && abs($0.height - frame.height) < 1
            }
            let frames = [frame] + before
            if type == .contrast && summary.localizedCaseInsensitiveContains("nearly") {
                reason = "contrast nearly passed (system secondary text)"
            } else if type == .contrast && !element.isEnabled {
                reason = "disabled control (WCAG exempt)"
            } else if !isOwnBarElement(label: label, frame: frame) && frames.contains(where: { frame in chrome.contains { $0.intersects(frame) } }) {
                reason = "on or under a system Liquid Glass bar, or under the preview's own bar"
            } else if Self.isEmojiOnly(label) {
                reason = "emoji only (a flag is a picture, not text)"
            } else if pictureFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) }) {
                reason = "inside a labelled picture (share image preview)"
            } else if type == .textClipped && !accessibilitySize {
                reason = "text clipped at a standard size (the audit enlarges text; the largest-size run decides)"
            } else if type == .textClipped && frame.height > Self.wrappedHeight {
                reason = "text clipped on wrapped text (every line shown in the screenshot)"
            } else if frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1
                        && (frame.minY < bounds.minY || frame.maxY > bounds.maxY) {
                reason = "cut by the top or bottom edge of the screen (scrolled)"
            }
        } else if type == .textClipped {
            reason = "text clipped, no element (text inside a combined row)"
        } else if type == .contrast {
            if summary.localizedCaseInsensitiveContains("nearly") {
                reason = "contrast nearly passed (system secondary text), no element"
            } else if barOverContent {
                reason = "no element, screen has content passing under a system bar"
            }
        }
        let line = "\(screen) | audit \(Self.name(of: type)) | \(summary) | label '\(label)' | \(where_)"
        if let reason {
            print("A11Y_WARN \(line) | \(reason)")
        } else if type == .contrast {
            pendingContrast.append((label, line, String(issue.detailedDescription.prefix(400))))
        } else {
            print("A11Y_FAIL \(line)")
            print("A11Y_DETAIL \(screen) | \(String(issue.detailedDescription.prefix(400)))")
            auditFailures.append("\(Self.name(of: type)) '\(label.prefix(40))'")
        }
    }

    /// Taller than two lines of body text at the largest accessibility size: text that wraps.
    private static let wrappedHeight: CGFloat = 100

    /// Flags and other emoji, without letters or digits.
    private static func isEmojiOnly(_ label: String) -> Bool {
        let scalars = label.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        return !scalars.isEmpty && scalars.allSatisfy { $0.properties.isEmojiPresentation || (0x1F1E6...0x1F1FF).contains($0.value) || $0.properties.isEmojiModifier || $0.value == 0xFE0F || $0.value == 0x200D }
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .textClipped: "textClipped"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "elementDescription"
        case .dynamicType: "dynamicType"
        case .elementDetection: "elementDetection"
        case .trait: "trait"
        default: "type \(type.rawValue)"
        }
    }

    /// Top folders the German first run created in the library: data in the English run.
    private static let germanFolderNames: Set<String> = ["Länder", "Reisen", "Orte", "Länder und Orte", "Themen", "Dokumente"]

    /// Words that only a German interface shows (the English run must show none of them).
    private static let germanWords: Set<String> = [
        "und", "oder", "nicht", "der", "die", "das", "Der", "Die", "Das", "dein", "deine", "deinen", "deiner", "deinem",
        "Dein", "Deine", "mit", "für", "Alle", "alle",
        "werden", "wird", "ist", "sind", "jetzt", "noch", "Fotos", "Alben", "Aufnahmen", "Vorschläge", "Vorschlag",
        "Einstellungen", "Übersicht", "Mediathek", "Reisen", "Länder", "Orte", "Städte", "anlegen", "prüfen",
        "Zurück", "Fertig", "Weiter", "Abbrechen", "Schließen", "Analyse", "sortiert", "Sortiert", "Jahre", "Tage",
    ]

    /// One snapshot of the accessibility tree: labels, placeholders, untranslated words, text
    /// running off the side, and (reported only) small targets and overlapping text. `given`:
    /// the snapshot `check` already took once the screen was still; else a new one.
    private func inspectTree(_ screen: String, root given: (any XCUIElementSnapshot)?, chrome: [CGRect], english: Bool) {
        let root: any XCUIElementSnapshot
        if let given {
            root = given
        } else {
            do {
                root = try app.snapshot()
            } catch {
                print("A11Y_WARN \(screen) | tree | no snapshot: \(error.localizedDescription)")
                return
            }
        }
        let bounds = root.frame
        var texts: [(label: String, frame: CGRect)] = []
        var seen = 0
        framesBeforeAudit = [:]
        pictureFrames = []

        func fail(_ kind: String, _ label: String, _ frame: CGRect) {
            print("A11Y_FAIL \(screen) | \(kind) | label '\(label)' | \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            screenFailures.append("\(kind) '\(label.prefix(40))'")
        }

        func visit(_ node: any XCUIElementSnapshot) {
            seen += 1
            let frame = node.frame
            let visible = !frame.isEmpty && frame.intersects(bounds)
            let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
            // The preview bar's own elements are content, not something under a bar.
            let inChrome = !isOwnBarElement(label: label, frame: frame) && chrome.contains { $0.intersects(frame) }
            let type = node.elementType
            if !label.isEmpty { framesBeforeAudit[label, default: []].append(frame) }
            if type == .image && !label.isEmpty && frame.width >= 80 && frame.height >= 80 {
                pictureFrames.append(frame)
            }
            if visible {
                if label.contains("%lld") || label.contains("%@") || label.contains("%ld") {
                    fail("format placeholder", label, frame)
                }
                if english {
                    // Folder paths ("Albumist › Reisen › 2024") are names of folders that exist in
                    // the library, made in the German first run: data, not interface text.
                    // So are the top folders standing alone as a value ("Folder, Länder").
                    let interface = label.components(separatedBy: ", ")
                        .filter { !$0.contains("›") && !Self.germanFolderNames.contains($0) }.joined(separator: " ")
                    let words = interface.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
                    if let word = words.first(where: { Self.germanWords.contains($0) }) {
                        fail("German word '\(word)' in English UI", label, frame)
                    }
                }
            }
            if visible && !inChrome {
                switch type {
                case .button, .link, .switch, .toggle:
                    if (label.isEmpty && (type == .button || type == .link)) || label == "-" || Self.looksLikeSymbolName(label) {
                        fail("no VoiceOver label (\(type.rawValue))", label, frame)
                    }
                    if (type == .button || type == .link) && node.isEnabled && (frame.height < 43.5 || frame.width < 43.5) {
                        print("A11Y_WARN \(screen) | small target \(Int(frame.width))x\(Int(frame.height)) | label '\(label)'")
                    }
                case .staticText:
                    texts.append((label, frame))
                    // Wider than the screen or starting off its side: the layout does not fit.
                    if frame.minX < bounds.minX - 1 || frame.maxX > bounds.maxX + 1 {
                        fail("text runs off the side of the screen", label, frame)
                    }
                default:
                    break
                }
            }
            for child in node.children { visit(child) }
        }
        visit(root)

        // Overlapping texts (reported): two labels drawn over each other.
        for i in texts.indices {
            for j in texts.indices where j > i {
                let overlap = texts[i].frame.intersection(texts[j].frame)
                guard !overlap.isNull, overlap.width > 4, overlap.height > 4 else { continue }
                let smaller = min(texts[i].frame.width * texts[i].frame.height, texts[j].frame.width * texts[j].frame.height)
                if overlap.width * overlap.height > 0.3 * smaller {
                    print("A11Y_WARN \(screen) | overlapping text | '\(texts[i].label.prefix(40))' and '\(texts[j].label.prefix(40))'")
                }
            }
        }
        print("A11Y_TREE \(screen) \(seen) elements, \(texts.count) texts")
    }

    // MARK: Layout checks the audit does not make

    /// Largest text: a country row of the atlas holds its name in whole words and the year in
    /// one line (review P3-11 / G3-01: "Ver-ei-nig-te Sta-a-ten" over six lines, the year as
    /// "20" over "11", and the audit passed: wrapped text is not "clipped"). The row is one
    /// VoiceOver element, so its height is measured: at most the line of flag and arrow, one
    /// line per word of the name and one more (a single word wider than the screen of the
    /// small iPhone may still break once), the year's line and the padding. A name broken into
    /// syllables needs more lines than that: the six lines of "Vereinigte Staaten" are about
    /// 400 pt on the small iPhone, two words are allowed about 355 pt.
    private func checkAtlasRows(_ tag: String) {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let bodyLine = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
        let flagLine = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: traits).lineHeight
        let screen = app.frame
        let rows = app.buttons.matching(identifier: "atlas.country")
        // Only rows wholly on screen: a row cut by the edge has no meaningful height.
        func wholeRows() -> [XCUIElement] {
            rows.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty && screen.contains($0.frame) }
        }
        // At the largest size on the small iPhone the tiles above the list fill more than two
        // swipes (UI run 44561127820: no row wholly on screen): scroll on slowly until one is,
        // and back the same way after, so the walk finds the share button again.
        var shown = wholeRows()
        var swipes = 0
        while shown.isEmpty && swipes < 8 { app.swipeUp(velocity: .slow); swipes += 1; shown = wholeRows() }
        print("UI_FACT \(tag) atlas rows: \(rows.count) in the tree, \(shown.count) wholly on screen after \(swipes) more swipe(s)")
        defer { for _ in 0..<swipes { app.swipeDown(velocity: .slow) } }
        var measured = 0
        for row in shown {
            let frame = row.frame
            measured += 1
            // "Vereinigte Staaten, 2011": the name is the part before the year.
            let name = row.label.components(separatedBy: ", ").first ?? row.label
            let words = max(1, name.split(whereSeparator: { $0 == " " || $0 == "-" }).count)
            let allowed = flagLine + CGFloat(words + 2) * bodyLine + 2 * 10 + 2 * 4 + 8
            if frame.height > allowed {
                print("A11Y_FAIL \(tag) atlas lower | country row broken mid-word | label '\(row.label)' | height \(Int(frame.height)) > \(Int(allowed)) for \(words) word(s)")
                XCTFail("\(tag) atlas: the row '\(row.label)' is \(Int(frame.height)) pt tall, more than \(Int(allowed)) pt for \(words) word(s) and the year: the name or the year breaks mid-word")
            }
        }
        if measured > 0 {
            print("UI_STEP_OK \(tag) atlas rows measured \(measured)")
        } else {
            print("UI_STEP_MISSING \(tag) atlas rows measured (no country row wholly on screen)")
            XCTFail("\(tag) atlas: no country row wholly on screen to measure")
        }
    }

    /// A label shown in full, not ending in "…" (review P3-17 / G3-08: "Ordner für neue Al…"
    /// in the settings at the default text size; the audit leaves clipped text at standard
    /// sizes to the largest-size run, see `record`). On one line the label is as wide as the
    /// text needs; wrapped, it is at least two lines tall. Scrolls the list until the label is
    /// on screen.
    private func checkFullyShown(_ text: String, identifier: String, _ screen: String, in list: XCUIElement) {
        var element = app.staticTexts[text]
        if !element.exists { element = app.staticTexts[identifier] }
        func visible() -> Bool {
            element.exists && !element.frame.isEmpty && app.frame.contains(element.frame)
        }
        // No fixed sleep after a swipe (SleepRuleTests): XCTest waits for the app to be idle,
        // and only the width and height of the label are measured, not its position.
        var swipes = 0
        while !visible() && swipes < 4 { list.swipeDown(); swipes += 1; if !element.exists { element = app.staticTexts[identifier] } }
        swipes = 0
        while !visible() && swipes < 6 { list.swipeUp(); swipes += 1; if !element.exists { element = app.staticTexts[identifier] } }
        guard visible() else {
            print("UI_STEP_MISSING \(screen) label '\(text)' on screen")
            XCTFail("\(screen): the label '\(text)' was not found on screen")
            return
        }
        let category: UIContentSizeCategory = accessibilitySize ? .accessibilityExtraExtraExtraLarge : .large
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let needed = (text as NSString).size(withAttributes: [.font: font]).width
        let frame = element.frame
        let oneLineInFull = frame.width + 2 >= needed
        let wrapped = frame.height >= 1.8 * font.lineHeight
        if oneLineInFull || wrapped {
            print("UI_STEP_OK \(screen) label '\(text)' shown in full (\(Int(frame.width))x\(Int(frame.height)), needs \(Int(needed)) on one line)")
        } else {
            print("A11Y_FAIL \(screen) | label cut | label '\(text)' | \(Int(frame.width))x\(Int(frame.height)), needs \(Int(needed)) pt on one line")
            XCTFail("\(screen): the label '\(text)' is cut: \(Int(frame.width)) pt wide on one line, it needs \(Int(needed)) pt")
        }
    }

    /// "chevron.right", "square.and.arrow.up": a symbol name read out instead of a label.
    private static func looksLikeSymbolName(_ label: String) -> Bool {
        guard label.contains("."), !label.contains(" "), label == label.lowercased() else { return false }
        let parts = label.split(separator: ".")
        let plain = parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { character in character.isLetter || character.isNumber } }
        return parts.count >= 2 && plain && label.contains(where: { character in character.isLetter })
    }

    private func finish(_ test: String) {
        print("A11Y_TEST_DONE \(test)")
    }

    // MARK: Helpers (copied from AlbumistFlowUITests, which another change owns)

    private func launch(english: Bool = false, textSize: String? = nil, dark: Bool = false) {
        // The app's stalls and stacks of each launch (UITestStalls; the contrast run's long
        // stalls before "close settings" had no stack, UI run 44012530107).
        // The app of the last launch is ended in UITestAppEnd.launch (its process id stays known
        // when the report removes the stall file, `UITestLaunchRecord`).
        UITestStalls.report()
        if !stallsReportedAtEnd {
            stallsReportedAtEnd = true
            addTeardownBlock { UITestStalls.report() }
        }
        app = XCUIApplication()
        var arguments = ["-AlbumistUITestUnlocked"] + UITestStalls.arguments(besides: [])
        arguments += english ? ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] : ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        accessibilitySize = textSize?.contains("Accessibility") ?? false
        if dark { arguments.append("-AlbumistUITestDark") }
        app.launchArguments = arguments
        UITestAppEnd.launch(app)
    }

    private var stallsReportedAtEnd = false

    private func slug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private func suggestionRow(_ marker: String) -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", marker)).element(boundBy: 0)
    }

    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anything(exactly text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func searchTabButton() -> XCUIElement {
        for label in ["Suchen", "Suche", "Search"] where app.tabBars.buttons[label].exists {
            return tabButton(label)
        }
        return app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1)
    }

    private func tabButton(_ name: String) -> XCUIElement {
        let button = app.tabBars.buttons[name]
        var tries = 0
        while !(button.exists && button.isHittable) && tries < 3 {
            if tries < 2 { app.swipeDown() } else if app.tabBars.firstMatch.exists { app.tabBars.firstMatch.tap() }
            // The bar expands after the swipe: on as soon as the button can be tapped, else the
            // next try after the old second.
            _ = UITestWait.holds(timeout: 1) { button.exists && button.isHittable }
            tries += 1
        }
        return button
    }

    /// Taps "Beispiel-Mediathek anlegen" and checks that the seeding started: its progress text
    /// shows, or the button is gone, within 20 s. Accessibility run 44144000817: at the largest
    /// text the demo card's button was still 2 pt above the tab bar after 10 swipes
    /// (element y 582, bar from 584), the tap landed on the bar, nothing was seeded, the test
    /// waited 600 s and tests 2 to 4 then ran on the simulator's 6 photos ("Missing: open
    /// suggestions"). A tap that started nothing is said with the button's state and repeated
    /// on the part of the button clear of the bars, at most 3 times; then the test fails at once.
    private func seedDemoLibrary(_ demo: XCUIElement) -> Bool {
        let seeding = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Beispielfotos werden angelegt")).firstMatch
        for attempt in 1...3 {
            if attempt == 1 {
                tap(demo, "seed demo library")
            } else if !tapClearOfBars(demo, "seed demo library, attempt \(attempt)") {
                break
            }
            if UITestWait.holds(timeout: 20, { seeding.exists || !demo.exists }) { return true }
            let tabs = app.tabBars.firstMatch
            print("UI_FACT seed demo library attempt \(attempt): nothing started; button enabled \(demo.isEnabled), hittable \(demo.isHittable), frame \(demo.frame), tab bar \(tabs.exists ? "\(tabs.frame)" : "none")")
        }
        print("UI_STEP_MISSING seed demo library started")
        shot("a11y-x-missing-seed-demo-library")
        XCTFail("Tapping \"Beispiel-Mediathek anlegen\" started no seeding")
        return false
    }

    /// A point near the top of `element` at least 18 pt above the tab bar (the bar takes taps a
    /// little above its frame, see `tap`), when the element starts that far above it; else nil.
    private func topClearOfTabs(_ element: XCUIElement) -> CGFloat? {
        let tabs = app.tabBars.firstMatch
        guard tabs.exists else { return nil }
        let frame = element.frame
        let y = frame.minY + min(8, frame.height / 4)
        return y <= tabs.frame.minY - 18 ? y : nil
    }

    /// The part of `element` clear of both bars (top and bottom; empty or negative when none).
    private func clearBand(_ element: XCUIElement) -> (top: CGFloat, bottom: CGFloat) {
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        let frame = element.frame
        let top = max(frame.minY, bar.exists ? bar.frame.maxY + 8 : window.minY + 60)
        let bottom = min(frame.maxY, tabs.exists ? tabs.frame.minY - 24 : window.maxY - 24)
        return (top, bottom)
    }

    /// Scrolls `element` by short drags (up above the tab bar, or down below the navigation bar
    /// for an element under it) until at least 30 pt of it are clear of both bars, then taps the
    /// middle of that part. False when it never got clear.
    private func tapClearOfBars(_ element: XCUIElement, _ step: String) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        func band() -> (top: CGFloat, bottom: CGFloat) { clearBand(element) }
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        // Content under the navigation bar is dragged down, everything else up. (`tap` calls
        // this only when the band is already 30 pt, so it drags only when called directly.)
        let down = bar.exists && element.frame.midY < bar.frame.maxY
        var drags = 0
        while band().bottom - band().top < 30 && drags < 6 {
            let from = down ? (bar.exists ? bar.frame.maxY : window.minY + 60) + 40 : (tabs.exists ? tabs.frame.minY : window.maxY) - 40
            origin.withOffset(CGVector(dx: window.midX, dy: from))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: window.midX, dy: down ? from + 220 : from - 220)))
            drags += 1
            // The drag may fling the list on: measured once the element stops moving (the same
            // frame twice in a row). Not asserted: an element a lazy list dropped for a moment
            // is measured again by the loop, as after the old second.
            var lastFrame: CGRect?
            _ = UITestWait.holds(timeout: 5) {
                let now: CGRect? = element.exists ? element.frame : nil
                let same = now != nil && now == lastFrame
                lastFrame = now
                return same
            }
        }
        let clear = band()
        print("UI_FACT tap \(step): element \(element.frame), clear band \(Int(clear.top))-\(Int(clear.bottom)), \(drags) drags")
        guard clear.bottom - clear.top >= 30 else { return false }
        UITestOnboarding.clock("tap \(step)")
        origin.withOffset(CGVector(dx: element.frame.midX, dy: (clear.top + clear.bottom) / 2)).tap()
        return true
    }

    /// "Alben jetzt anlegen" is in reach as the plan opens, without scrolling and clear of the tab
    /// bar, at this walk's text size and orientation (review P3-05 = G3-05: it stood at the end
    /// of the plan, below the fold). Content under the tab bar counts as hittable for XCUITest,
    /// so the frame is read too. `required`: the walk applies the plan next, so the button has to
    /// be there; otherwise a plan that something stops (no button) is only reported.
    private func expectApplyInReach(_ step: String, required: Bool) {
        let apply = app.buttons["plan.apply"]
        guard required || apply.waitForExistence(timeout: 5) else {
            print("UI_FACT \(step): no \"plan.apply\" (something stops the plan), its reach not checked")
            return
        }
        let tabs = app.tabBars.firstMatch
        let reached = UITestWait.until("\(step): button in reach without scrolling", timeout: 10) {
            apply.exists && apply.isHittable && app.frame.contains(apply.frame)
                && (!tabs.exists || apply.frame.maxY <= tabs.frame.minY + 1)
        }
        if !reached {
            print("UI_FACT \(step): button \(apply.exists ? "\(apply.frame)" : "missing"), tab bar \(tabs.exists ? "\(tabs.frame)" : "missing")")
        }
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            print("UI_STEP_MISSING \(step)")
            shot("a11y-x-missing-" + slug(step))
            XCTFail("Missing: \(step)")
            return false
        }
        // Content under the tab bar also counts as hittable, but a tap there lands on the bar
        // (contrast run 43918684247: the atlas teaser sat under the tab bar on a fresh simulator,
        // the tap opened nothing, and `back()` then tapped the overview's settings button). The
        // bar takes taps a little above its frame too: run 43945035122 tapped the teaser 6 pt
        // above it (centre y 578, bar from 584) and the atlas did not open, so the centre has
        // to be clear of the bar by the scroll edge it softens (see `chromeFrames`) and more.
        let bar = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        func underBar() -> Bool {
            bar.exists && !bar.frame.contains(element.frame) && element.frame.midY < bar.frame.maxY
        }
        func underTabs() -> Bool {
            tabs.exists && !tabs.frame.contains(element.frame) && element.frame.midY > tabs.frame.minY - 24
        }
        var swipes = 0
        var unmoved = 0
        var stuck = false
        // The direction of the last swipe: up (+1) for an element under the tab bar or below the
        // screen, down (-1) for one under the navigation bar.
        var lastDirection = 0
        var overshot = false
        while swipes < 10 {
            let before = element.frame
            let direction: Int
            if underBar() { direction = -1 } else if underTabs() || !element.isHittable { direction = 1 } else { break }
            // The last swipe took the element past the band between the bars to the other bar: a
            // swipe scrolls further than that band is tall, so further swipes only sent it back
            // and forth (UI runs 44630953220 and job 136352444079: ten swipes, then one short drag
            // of `tapClearOfBars` brought it clear, 30-50 s per such tap in the accessibility and
            // contrast walks). The short drags below take over at once.
            if lastDirection != 0, direction != lastDirection { overshot = true; break }
            if direction < 0 { app.swipeDown() } else { app.swipeUp() }
            lastDirection = direction
            swipes += 1
            // The list is at its end: two swipes in a row did not move the element (accessibility
            // run 44202318875: ten swipes, the row stayed at y 500-765 under the tab bar from 584).
            unmoved = element.frame == before ? unmoved + 1 : 0
            if unmoved >= 2 { stuck = true; break }
        }
        if tabs.exists, swipes > 0 || element.frame.maxY > tabs.frame.minY {
            print("UI_FACT tap \(step): element \(element.frame), tab bar \(tabs.frame), \(swipes) swipes\(stuck ? ", it no longer moves" : "")\(overshot ? ", the last one took it past the band between the bars" : "")")
        }
        // An element under a bar with at least 30 pt clear of both bars is tapped there, not on
        // its centre, which the bar takes: in accessibility run 44202318875 (test3) the tap meant
        // for a suggestion row (y 500-765, tab bar from 584) opened the Mediathek tab, and every
        // later step ran on the wrong screen ("Missing: xxxl open atlas"). With less clear,
        // `element.tap()` as before: XCTest scrolls it into view itself (green runs 44130058787,
        // 44164854295: atlas teaser and seed button at y 592-690 after ten swipes). A tap that
        // lands elsewhere fails where the walk checks the screen it opened (`opened`).
        if underBar() || underTabs() {
            let band = clearBand(element)
            if band.bottom - band.top >= 30, tapClearOfBars(element, step) {
                print("UI_STEP_OK \(step)")
                return true
            }
            print("UI_FACT tap \(step): under a bar with less than 30 pt clear (\(Int(band.top))-\(Int(band.bottom)))")
            // Contrast run 44582675590 (light, small iPhone): after ten swipes the button "open
            // suggestions" still sat at y 557-607 under the tab bar from 584, `element.tap()` hit
            // its centre (582) and the bar took it ("Not opened: contrast light suggestions").
            // Short drags first; if it still has no 30 pt clear, its top part above the bar.
            if tapClearOfBars(element, step) {
                print("UI_STEP_OK \(step)")
                return true
            }
            if underTabs(), let top = topClearOfTabs(element) {
                print("UI_FLAKY_RETRY \(UITestWait.testID(self)) \(step): tapped at y \(Int(top)), the top of the element above the tab bar")
                UITestOnboarding.clock("tap \(step)")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: element.frame.midX, dy: top)).tap()
                print("UI_STEP_OK \(step)")
                return true
            }
            print("UI_FACT tap \(step): XCTest scrolls it")
        }
        UITestOnboarding.clock("tap \(step)")
        element.tap()
        print("UI_STEP_OK \(step)")
        return true
    }

    /// A screen that was tapped open is there. Only such a screen is left with `back()`: on the
    /// overview the first button of the navigation bar is the settings button, and `back()`
    /// there opened the settings in the middle of the walk (contrast run 43918684247).
    private func opened(_ screen: XCUIElement, _ step: String) -> Bool {
        guard screen.waitForExistence(timeout: 10) else {
            print("UI_STEP_MISSING \(step) opened")
            shot("a11y-x-missing-" + slug("\(step) opened"))
            XCTFail("Not opened: \(step)")
            return false
        }
        return true
    }

    /// Taps the back button. Never on the overview, whose first bar button is the settings
    /// button: after the suggestions list had closed by itself, `back()` opened the settings,
    /// and every later step of the contrast walk ran on the settings sheet until "settings"
    /// tapped its "Fertig" (contrast run 44038288087: "close settings" missing, the screenshots
    /// show the sheet). Told by the bar's title, not the button's label: the back button of a
    /// screen opened from the settings is called "Einstellungen" too (UI run 44055738268).
    /// `confirmed`: the walk saw the screen open (its bar or `opened`); finding the overview
    /// instead means the screen closed by itself, which is a finding. Unconfirmed screens (only
    /// the tap is known) are left alone there.
    private func back(_ step: String, confirmed: Bool) {
        let bar = app.navigationBars.firstMatch
        let first = bar.buttons.element(boundBy: 0)
        guard first.exists else { return }
        if ["Übersicht", "Overview"].contains(bar.identifier) {
            print("UI_FACT back: no back button, the overview is showing (\(step))")
            shot("a11y-x-back-on-overview-" + slug(step))
            if confirmed { XCTFail("Closed by itself before going back: \(step)") }
            return
        }
        first.tap()
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

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Zugriff auf alle Fotos erlauben", "Allow Full Access", "Allow Access to All Photos", "Alle Fotos erlauben", "Vollzugriff erlauben"]
        var answered = false
        // Taps the alert's button when it is there; the trial step means it was not needed.
        let done = UITestWait.holds(timeout: 25) {
            for source in [springboard, app] {
                for label in labels where source.buttons[label].exists {
                    source.buttons[label].tap()
                    answered = true
                    return true
                }
            }
            return button("Analyse starten").exists
        }
        if answered {
            print("UI_STEP_OK system photo alert")
        } else if !done {
            print("UI_STEP_MISSING system photo alert")
        }
    }

    /// The notification question comes a while after "Analyse starten" (never within the 8 s
    /// this waited before: no run printed "notification alert"), and until it is answered it
    /// takes every touch: in UI runs 44032718289 and 44038288087 it still covered the overview
    /// when "Beispiel-Mediathek anlegen" was tapped, and no demo library was made. Looked for in
    /// the springboard and in the app for up to 20 s; when it never came, that is said.
    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let answered = UITestWait.holds(timeout: 20) {
            for source in [springboard, app] {
                for label in ["Erlauben", "Allow"] where source.buttons[label].exists {
                    source.buttons[label].tap()
                    return true
                }
            }
            return false
        }
        print(answered ? "UI_STEP_OK notification alert" : "UI_FACT no notification alert within 20 s")
    }

    /// The notification question can come later than the 20 s `allowNotificationsIfAsked` waits:
    /// on a busy Mac (load 669, UI run 44880878362) it came only after the demo library was made
    /// and covered "overview after first analysis". The audit then could not reach the app
    /// ("Invalid target app" twice) and the screen went unaudited. So every check first looks
    /// once whether the system alert is in front and answers it as the onboarding does.
    private func answerLateNotificationAlert(before screen: String) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return }
        let aboutNotifications = ["Notification", "Mitteilung"].contains { alert.label.localizedCaseInsensitiveContains($0) }
        for label in ["Erlauben", "Allow"] where aboutNotifications && alert.buttons[label].exists {
            alert.buttons[label].tap()
            UITestWait.disappears(alert, "late notification alert before \(screen) answered", timeout: 10)
            print("UI_FACT notification alert came late, answered before \(screen)")
            return
        }
        print("UI_FACT system alert in front before \(screen): \(alert.label)")
    }

    @discardableResult
    private func waitStable(_ what: String, timeout: TimeInterval, stableChecks: Int = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var streak = 0
        while Date() < deadline {
            let asked = Date()
            streak = condition() ? streak + 1 : 0
            UITestOnboarding.reportSlowCheck(since: asked)
            if streak >= stableChecks { return true }
            // pacing: the poll's interval, kept: "three checks in a row" means the state held for
            // about four seconds (the analysis idle, not only between two batches).
            sleep(2)
        }
        print("UI_STEP_MISSING \(what) (timeout \(Int(timeout)) s)")
        return false
    }

    /// The Pause button first: while the analysis runs it is there, and one query answers.
    /// Every other query reads the whole screen, and during the analysis such a read held the
    /// app's main thread for 16 to 48 s (UI run 43979263666: each long stall began within half
    /// a second of a check of this wait).
    private var analysisIdle: Bool {
        !app.buttons["Pause"].exists && (anything("Fotos analysiert").exists || anything("Analyse aktuell").exists || anything("Analyse fertig").exists)
    }
}
