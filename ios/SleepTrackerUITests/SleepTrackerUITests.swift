import XCTest

/// End to end, in the simulator, against the nights `UITestFixtures` seeds.
///
/// Last night: 1 and 2 snoring, 3 speech ("turn the light off"), 4 a cough, 5 a `music` the
/// app calls unclear, 6 breathing. An older night holds two more.
final class SleepTrackerUITests: XCTestCase {
    private enum Fixtures: String {
        case fresh, keep
    }

    private let lastNight = "night-2026-09-14-23-00"
    private let olderNight = "night-2026-09-13-23-10"
    private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        launch(.fresh)
    }

    // MARK: - Nights

    func testTheNightListShowsTheSeededNights() {
        app.tabBars.buttons["Nights"].tap()
        XCTAssertTrue(app.buttons[lastNight].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[olderNight].exists)
    }

    // MARK: - Correcting a sound

    func testASoundCanBeCorrectedToSeveralKindsInTheOrderHeard() {
        openLastNight()
        let cough = kindPicker(4)
        XCTAssertEqual(cough.label, "Coughing", "the classifier's guess, before any correction")

        cough.tap()
        // Both ticks in one visit: the menu has to stay open between them.
        menuItem("Farting").tap()
        menuItem("Breathing").tap()
        dismissMenu()
        XCTAssertEqual(kindPicker(4).label, "Farting, breathing")

        kindPicker(4).tap()
        menuItem("Back to the guess").tap()
        dismissMenu()
        XCTAssertEqual(kindPicker(4).label, "Coughing")
    }

    func testACorrectionSurvivesARelaunch() {
        openLastNight()
        XCTAssertEqual(kindPicker(5).label, "Unclear")
        kindPicker(5).tap()
        menuItem("Awake").tap()
        dismissMenu()

        app.terminate()
        launch(.keep)
        openLastNight()
        XCTAssertEqual(kindPicker(5).label, "Awake")
    }

    // MARK: - Filtering

    func testTheFilterShowsOnlyOrHidesAKind() {
        openLastNight()
        let header = app.staticTexts["every-sound-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(header.label.contains("(6)"), header.label)

        app.buttons["kind-filter"].tap()
        menuItem("Snoring (2)").tap()
        dismissMenu()
        XCTAssertTrue(header.label.uppercased().contains("2 OF 6"), header.label)
        XCTAssertTrue(listed(1) && listed(2))
        XCTAssertFalse(listed(4))

        app.buttons["kind-filter"].tap()
        menuItem("Hide").tap()
        dismissMenu()
        XCTAssertTrue(header.label.uppercased().contains("4 OF 6"), header.label)
        XCTAssertFalse(listed(1))
        XCTAssertTrue(listed(4))

        app.buttons["kind-filter"].tap()
        menuItem("Show everything").tap()
        dismissMenu()
        XCTAssertTrue(header.label.contains("(6)"), header.label)
    }

    // MARK: - Favourites

    func testAStarredSoundAppearsInFavouritesAndCanBeFilteredOut() {
        openLastNight()
        let star = app.buttons.matching(identifier: "star-3").firstMatch
        star.tap()
        XCTAssertEqual(star.label, "Remove star")

        app.tabBars.buttons["Favourites"].tap()
        let spoken = app.staticTexts["“turn the light off”"]
        XCTAssertTrue(spoken.waitForExistence(timeout: 5))

        app.buttons["kind-filter"].tap()
        menuItem("Hide").tap()
        menuItem("Talking (1)").tap()
        dismissMenu()
        XCTAssertTrue(app.staticTexts["Nothing marked matches"].waitForExistence(timeout: 5))
        XCTAssertFalse(spoken.exists)
    }

    // MARK: - Recording

    func testTheStartDelayExplainsWhatItSkips() {
        app.tabBars.buttons["Record"].tap()
        app.buttons["settings-button"].tap()
        app.buttons["delay-picker"].tap()
        menuItem("After 30 min").tap()
        let explained = NSPredicate(format: "label BEGINSWITH 'The first 30 minutes'")
        XCTAssertTrue(
            app.staticTexts.containing(explained).firstMatch.waitForExistence(timeout: 5)
        )
        app.buttons["Done"].tap()
    }

    func testStoppingDuringTheWaitKeepsNoNight() {
        app.tabBars.buttons["Record"].tap()
        // In fixture mode capture is silence, not the microphone: see `CaptureEngine`.
        app.buttons["Start recording"].tap()

        // The fixture defaults leave the delay at 15 minutes.
        XCTAssertTrue(app.staticTexts["listening-from"].waitForExistence(timeout: 10))
        app.buttons["Stop recording"].tap()

        // Stopping lands on the night list; nothing was kept, so nothing was added.
        XCTAssertTrue(app.buttons[lastNight].waitForExistence(timeout: 5))
        let nights = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'night-'"))
        XCTAssertEqual(nights.count, 2)
    }

    // MARK: - Helpers

    private func launch(_ fixtures: Fixtures) {
        app = XCUIApplication()
        app.launchEnvironment["SLEEPTRACKER_UITEST"] = fixtures.rawValue
        app.launch()
    }

    private func openLastNight() {
        app.tabBars.buttons["Nights"].tap()
        let night = app.buttons[lastNight]
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        night.tap()
    }

    /// The kind picker for an event in the "Every sound" list. The same event can also sit in
    /// the reel or the marked list, which have no picker, so the identifier is unique.
    private func kindPicker(_ index: Int) -> XCUIElement {
        let picker = app.buttons["kind-picker-\(index)"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no picker for event \(index)")
        return picker
    }

    private func listed(_ index: Int) -> Bool {
        app.buttons["kind-picker-\(index)"].exists
    }

    /// An item in whichever menu is open. Looked up inside the menu, because a row's own
    /// picker can carry the same label ("Breathing").
    private func menuItem(_ label: String) -> XCUIElement {
        let item = app.collectionViews.buttons[label]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no menu item \(label)")
        return item
    }

    /// Menus here stay open between ticks, so they have to be closed by tapping elsewhere —
    /// and the next tap has to wait until the menu has actually gone.
    private func dismissMenu() {
        app.navigationBars.firstMatch.tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForNonExistence(timeout: 5))
    }
}
