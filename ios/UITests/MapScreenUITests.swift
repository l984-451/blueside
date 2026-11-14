import XCTest

final class MapScreenUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let chart = ["-basePack", "test", "-center", "32.8968,-97.0380", "-zoom", "10", "-offline", "1"]

    @MainActor private func loaded(_ app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
    }

    @MainActor func testLayersButtonOpensThePickerAndTheChoiceChangesTheMap() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(chart)
        loaded(app)
        XCTAssertFalse(app.buttons["base-vfr"].exists)
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.buttons["base-ifr-low"].waitForExistence(timeout: 5))
        app.buttons["base-ifr-low"].tap()
        app.buttons["panel-close"].tap()
        XCTAssertTrue(app.buttons["base-vfr"].waitForNonExistence(timeout: 5))
        try Screen.chartShot("screen-ifr-low", floor: floor)
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
        XCTAssertFalse(app.staticTexts["no-coverage-label"].exists)
    }

    // Past the edge of every installed chart the map is flat gray, so it must say why.
    @MainActor func testViewPastTheEdgeOfTheChartsSaysNoCoverage() throws {
        let app = Screen.launch(["-basePack", "test", "-offline", "1", "-center", "40.0,-75.0", "-zoom", "10"])
        loaded(app)
        let label = app.staticTexts["no-coverage-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(label.label, "No chart coverage here")
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
        try Screen.save("failure-no-coverage")
        // The other chart family has the same edge, and a base that is not a chart pack has none.
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.buttons["base-ifr-low"].waitForExistence(timeout: 5))
        app.buttons["base-ifr-low"].tap()
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        app.buttons["base-street"].tap()
        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
    }

    @MainActor func testSettingsButtonOpensTheDownloadsList() throws {
        let app = Screen.launch(chart + ["-manifestBase", Screen.deadServer])
        loaded(app)
        XCTAssertFalse(app.staticTexts["downloads-offline"].exists)
        app.buttons["settings-button"].tap()
        if !app.staticTexts["downloads-offline"].waitForExistence(timeout: 3) { app.buttons["settings-downloads"].tap() }
        XCTAssertTrue(app.staticTexts["downloads-offline"].waitForExistence(timeout: 10))
        try Screen.save("screen-downloads")
        app.buttons["panel-close"].tap()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 5))
    }

    @MainActor func testTrackingButtonCyclesItsThreeStates() throws {
        let app = Screen.launch(chart)
        loaded(app)
        let button = app.buttons["tracking-button"]
        XCTAssertEqual(button.value as? String, "Not following")
        for wanted in ["Following, north up", "Following, track up", "Not following"] {
            button.tap()
            wait(for: [expectation(for: NSPredicate(format: "value == %@", wanted), evaluatedWith: button)], timeout: 5)
        }
    }

    @MainActor func testNightButtonDarkensTheChart() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(chart)
        loaded(app)
        let day = try Screen.chartShot("screen-day", floor: floor)
        app.buttons["night-button"].tap()
        sleep(3)
        let night = try Screen.chartShot("screen-night", floor: floor)
        XCTAssertLessThan(Screen.brightness(night), Screen.brightness(day) - 0.2, "night mode did not darken the chart")
        XCTAssertEqual(app.buttons["night-button"].value as? String, "On")
    }

    @MainActor func testAPanStopsFollowing() throws {
        let app = Screen.launch(chart + ["-follow", "1"])
        loaded(app)
        let button = app.buttons["tracking-button"]
        XCTAssertEqual(button.value as? String, "Following, north up")
        let map = app.otherElements["mapLoaded"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8)))
        wait(for: [expectation(for: NSPredicate(format: "value == 'Not following'"), evaluatedWith: button)], timeout: 5)
        try Screen.save("screen-panned")
    }

    @MainActor func testExpiredChartsShowTheBannerAndStayUsable() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(["-seedPacks", "expired", "-manifestBase", Screen.deadServer,
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        let banner = app.staticTexts["chart-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.hasPrefix("Charts expired "), banner.label)
        // The label reads the same when the text is covered, so the frame is checked too.
        XCTAssertFalse(banner.frame.intersects(app.buttons["layers-button"].frame))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(banner.frame))
        try Screen.chartShot("failure-expired", floor: floor)
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
    }

    @MainActor func testChartsNotYetInEffectAreDrawnAndDated() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(["-seedPacks", "upcoming", "-manifestBase", Screen.deadServer,
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        let banner = app.staticTexts["chart-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.hasPrefix("Charts not yet in effect until "), banner.label)
        XCTAssertFalse(banner.label.contains("expired"), banner.label)
        XCTAssertFalse(banner.frame.intersects(app.buttons["layers-button"].frame))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(banner.frame))
        try Screen.chartShot("failure-not-yet-in-effect", floor: floor)
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
    }

    @MainActor func testCurrentChartsShowNoBanner() throws {
        let app = Screen.launch(["-seedPacks", "current", "-manifestBase", Screen.deadServer,
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        sleep(2)
        XCTAssertFalse(app.staticTexts["chart-banner"].exists)
    }

    @MainActor func testAerialWithNoConnectionSaysSo() throws {
        let app = Screen.launch(["-base", "aerial", "-offline", "1"])
        let label = app.staticTexts["aerial-offline-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        XCTAssertEqual(label.label, "Aerial imagery needs an internet connection")
        try Screen.save("failure-aerial-offline")
    }

    // A joined network with no internet: the path is up and no tile answers.
    @MainActor func testAerialWithADeadLinkSaysSo() throws {
        let app = Screen.launch(["-base", "aerial", "-aerialProbe", Screen.deadServer + "/x",
                                 "-manifestBase", Screen.deadServer])
        XCTAssertTrue(app.staticTexts["aerial-offline-label"].waitForExistence(timeout: 20))
    }

    // An app left open for hours must still learn of the next cycle. The wait is shortened to two seconds.
    @MainActor func testChartListIsFetchedAgainWhileTheAppStaysOpen() throws {
        let host = try EmptyChartHost()
        defer { host.stop() }
        let app = Screen.launch(["-seedPacks", "empty", "-manifestBase", host.address, "-listRefresh", "2",
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        XCTAssertTrue(Screen.wait(15) { host.listRequests >= 4 }, "the list was asked for \(host.listRequests) times")
    }

    @MainActor func testChartListIsFetchedAgainOnReturnToTheForeground() throws {
        let host = try EmptyChartHost()
        defer { host.stop() }
        let app = Screen.launch(["-seedPacks", "empty", "-manifestBase", host.address,
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        XCTAssertTrue(Screen.wait(10) { host.listRequests >= 1 }, "the list was never asked for")
        sleep(3)
        let before = host.listRequests
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(Screen.wait(10) { host.listRequests > before }, "coming back did not ask for the list")
    }
}
