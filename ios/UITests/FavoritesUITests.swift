import XCTest

/// Favorites and Show on Map on the airport page, on the bundled Austin files.
final class FavoritesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func openAustin() -> XCUIApplication {
        let app = Screen.launch(NavUITests.austin + ["-show", "nav", "-navQuery", "AUS", "-navNow", "2026-10-13T12:00:00Z"])
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.buttons["favorite-button"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testAFavoriteShowsAboveTheNearestList() throws {
        let app = openAustin()
        let star = app.buttons["favorite-button"]
        // Favorites outlive a launch, so an earlier run's star is cleared first.
        if star.label == "Remove from favorites" { star.tap() }
        star.tap()
        XCTAssertEqual(star.label, "Remove from favorites")
        try Screen.save("fav-airport-page")
        app.buttons["panel-close"].tap()
        app.buttons["search-button"].tap()
        // The panel reopens on the airport last shown, so it goes back to the search.
        let bar = app.navigationBars["KAUS"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.buttons.element(boundBy: 0).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.buttons.firstMatch.tap()
        let favorite = app.buttons["favorite-AUS"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Favorites"].exists)
        try Screen.save("fav-search")
        favorite.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertFalse(favorite.waitForExistence(timeout: 2))
    }

    @MainActor func testShowOnMapCentersTheAirportAndStopsFollowing() throws {
        let app = openAustin()
        app.buttons["show-on-map-button"].tap()
        let camera = app.staticTexts["map-camera"]
        wait(for: [expectation(for: NSPredicate(format: "label ENDSWITH 'zoom 10'"), evaluatedWith: camera)],
             timeout: 15)
        XCTAssertEqual(app.buttons["tracking-button"].value as? String, "Not following")
    }
}
