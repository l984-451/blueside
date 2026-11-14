import XCTest

/// Taps and holds on the bundled Austin chart with the bundled test navigation files, with no network.
/// XCUITest has no two-finger press and hold, so the ruler is covered by unit tests only.
final class MapGestureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(center: String, zoom: String) -> XCUIApplication {
        let app = Screen.launch(["-offline", "1", "-basePack", "nav", "-center", center, "-zoom", zoom,
                                 "-navNow", "2026-10-13T12:00:00Z"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        let probe = app.staticTexts["map-nav"]
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'nav-navaids'"), evaluatedWith: probe)],
             timeout: 15)
        sleep(2)
        return app
    }

    private func map(_ app: XCUIApplication, _ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
        app.otherElements["mapLoaded"].coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
    }

    // Centex VORTAC alone under the finger opens its card; open map then closes it.
    @MainActor func testTappingANavaidOpensItsCardAndOpenMapClosesIt() throws {
        let app = launch(center: "30.37855,-97.52984722", zoom: "11")
        map(app, 0.5, 0.5).tap()
        XCTAssertTrue(app.navigationBars["CWK"].waitForExistence(timeout: 10))
        let frequency = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '112.8'"))
        XCTAssertTrue(frequency.firstMatch.exists)
        XCTAssertTrue(app.buttons["direct-to-button"].exists)
        XCTAssertTrue(app.buttons["add-to-route-button"].exists)
        sleep(1)
        try Screen.save("gesture-navaid-card")
        map(app, 0.6, 0.85).tap()
        XCTAssertTrue(app.navigationBars["CWK"].waitForNonExistence(timeout: 5))
    }

    // Centex and Austin Executive sit a finger apart at zoom 10, so the card lists both, closest first.
    @MainActor func testTappingTwoPlacesListsThemAndARowOpensItsCard() throws {
        let app = launch(center: "30.3880,-97.5481", zoom: "10")
        map(app, 0.5, 0.5).tap()
        XCTAssertTrue(app.navigationBars["Here"].waitForExistence(timeout: 10))
        let navaid = app.buttons["place-navaid-CWK"]
        let airport = app.buttons["place-airport-EDC"]
        XCTAssertTrue(navaid.waitForExistence(timeout: 5) && airport.exists)
        sleep(1)
        try Screen.save("gesture-here-list")
        navaid.tap()
        XCTAssertTrue(app.navigationBars["CWK"].waitForExistence(timeout: 10))
    }

    // A held finger drops a pin and lists what is nearby; a nearby airport opens its page.
    @MainActor func testHoldingOpenMapDropsAPinWithNearbyPlaces() throws {
        let app = launch(center: "30.1945,-97.6699", zoom: "11")
        map(app, 0.5, 0.6).press(forDuration: 1)
        let bar = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH '30°'")).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let aus = app.buttons["nearby-airport-AUS"]
        XCTAssertTrue(aus.waitForExistence(timeout: 5))
        sleep(1)
        try Screen.save("gesture-pin-card")
        aus.tap()
        XCTAssertTrue(app.navigationBars["KAUS"].waitForExistence(timeout: 10))
    }
}
