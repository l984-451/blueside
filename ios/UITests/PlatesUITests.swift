import XCTest

/// Opens Austin's diagram and a procedure from the bundled plates test pack.
final class PlatesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    @MainActor private func airport(night: Bool) -> XCUIApplication {
        let app = Screen.launch(NavUITests.austin + ["-show", "nav", "-navQuery", "AUS", "-navNow", "2026-10-13T12:00:00Z"]
                                + (night ? ["-night", "1"] : []))
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.navigationBars["KAUS"].waitForExistence(timeout: 10))
        return app
    }

    /// Drags the airport page up until the row shows, as a phone needs; slowly, so the row stays clear of the header.
    @MainActor private func reveal(_ row: XCUIElement, _ app: XCUIApplication) {
        let page = app.collectionViews.firstMatch
        for _ in 0..<3 where !row.exists || row.frame.maxY > page.frame.maxY {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    @MainActor func testTheAirportPageOpensTheDiagramAndTheProcedures() throws {
        let app = airport(night: false)
        let diagram = app.buttons["airport-diagram"]
        XCTAssertTrue(diagram.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["show-on-map-button"].label, "Show on Map")
        try Screen.save("plates-airport")
        // A chart opens full screen with one tap.
        diagram.tap()
        XCTAssertTrue(app.buttons["plate-close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["AIRPORT DIAGRAM"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["plate-view"].waitForExistence(timeout: 5))
        sleep(1)
        try Screen.save("plates-diagram-day")
        // The picker shows only with Markup on.
        let palette = app.otherElements["Drawing-Palette"]
        XCTAssertFalse(palette.exists)
        // Markup shows the system tool picker, and two fingers still zoom the page while it is on.
        let markup = app.buttons["plate-markup"]
        XCTAssertEqual(markup.label, "Markup")
        XCTAssertFalse(markup.isSelected)
        let diagramPage = app.descendants(matching: .any)["plate-view"]
        // The page's foot scrolls above the picker, opened if the phone shows it minimized, so it covers the most it can.
        // The drag starts beside the page, above it when the page fills the width, so it scrolls and draws nothing.
        func markupToFoot(_ name: String) throws {
            markup.tap()
            XCTAssertTrue(markup.isSelected)
            sleep(2)
            if palette.exists, palette.frame.width < 120 {
                palette.tap()
                sleep(1)
            }
            try Screen.save(name)
            let tall = diagramPage.frame.height > diagramPage.frame.width * 1.4
            let (from, to) = tall ? (CGVector(dx: 0.5, dy: 0.03), CGVector(dx: 0.5, dy: -0.14))
                : (CGVector(dx: 0.01, dy: 0.6), CGVector(dx: 0.01, dy: 0.05))
            diagramPage.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: diagramPage.coordinate(withNormalizedOffset: to))
            sleep(1)
            try Screen.save(name + "-foot")
        }
        try markupToFoot("plates-markup")
        diagramPage.pinch(withScale: 4, velocity: 1)
        sleep(2)
        let marked = diagramPage.value as? String
        XCTAssertGreaterThan(Double(marked?.dropLast() ?? "") ?? 0, 1.5, "two fingers did not zoom with Markup on: \(marked ?? "nil")")
        // A large phone's panel turns from sheet to card on its side; the chart stays open, zoomed and marking.
        if Screen.device == "iphone" {
            try Screen.save("plates-turn-before")
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            XCTAssertTrue(app.buttons["plate-close"].exists, "the turn closed the chart")
            XCTAssertTrue(markup.isSelected)
            XCTAssertEqual(diagramPage.value as? String, marked)
            try Screen.save("plates-turn-after")
            XCUIDevice.shared.orientation = .portrait
            sleep(2)
            XCTAssertEqual(diagramPage.value as? String, marked)
        }
        markup.tap()
        XCTAssertFalse(markup.isSelected)
        app.buttons["plate-close"].tap()
        // On its side, opened there.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        reveal(diagram, app)
        diagram.tap()
        XCTAssertTrue(markup.waitForExistence(timeout: 5))
        try markupToFoot("plates-markup-landscape")
        markup.tap()
        // Turned upright while open; on a large phone the card under it becomes a sheet once it closes.
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(app.buttons["plate-close"].exists, "the turn closed the chart")
        app.buttons["plate-close"].tap()
        sleep(1)
        reveal(app.buttons["airport-procedures"], app)
        XCTAssertTrue(app.buttons["airport-procedures"].waitForExistence(timeout: 5))
        app.buttons["airport-procedures"].tap()
        XCTAssertTrue(app.staticTexts["Approaches"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Departures"].exists)
        XCTAssertTrue(app.staticTexts["Arrivals"].exists)
        XCTAssertTrue(app.buttons["panel-close"].exists, "the procedures list has no close button")
        try Screen.save("plates-procedures")
    }

    @MainActor func testAtNightTheTargetsAreFullSizeAndAProcedureHoldsItsZoom() throws {
        let app = airport(night: true)
        XCTAssertTrue(app.buttons["direct-to-button"].waitForExistence(timeout: 5))
        reveal(app.buttons["airport-procedures"], app)
        XCTAssertTrue(app.buttons["airport-procedures"].waitForExistence(timeout: 5))
        Screen.assertTargets(app)
        try Screen.save("plates-airport-night")
        app.buttons["airport-procedures"].tap()
        app.buttons["plate-00556IL18R.PDF"].tap()
        XCTAssertTrue(app.buttons["plate-close"].waitForExistence(timeout: 5))
        let page = app.descendants(matching: .any)["plate-view"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        sleep(1)
        try Screen.save("plates-full-screen-night")
        page.doubleTap()
        sleep(1)
        try Screen.save("plates-full-screen-zoomed")
        page.doubleTap()
        sleep(1)
        // A pinch and a pan hold their zoom; nothing refits the page behind the reader.
        page.pinch(withScale: 6, velocity: 1)
        sleep(2)
        let zoom = page.value as? String
        XCTAssertGreaterThan(Double(zoom?.dropLast() ?? "") ?? 0, 1.5, "pinch zoom sprang back to \(zoom ?? "nil")")
        page.swipeLeft()
        sleep(2)
        XCTAssertEqual(page.value as? String, zoom, "the zoom changed after a pan")
        try Screen.save("plates-full-screen-pinched")
        page.pinch(withScale: 0.2, velocity: -1)
        app.buttons["plate-close"].tap()
        XCTAssertTrue(app.buttons["plate-00556IL18R.PDF"].waitForExistence(timeout: 5))
    }
}
