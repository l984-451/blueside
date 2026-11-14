import XCTest

/// Runs on the bundled Austin chart and the bundled test navigation files, with no network.
final class NavUITests: XCTestCase {
    static let austin = ["-offline", "1", "-basePack", "nav", "-center", "30.1945,-97.6699", "-zoom", "9"]

    override func setUp() { continueAfterFailure = false }

    @MainActor private func loaded(_ app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
    }

    @MainActor private func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) {
        wait(for: [expectation(for: NSPredicate(format: format), evaluatedWith: element)], timeout: timeout)
    }

    // Dark appearance with night mode off puts the map's labels over a day chart.
    // The launch option stands in for the device setting, which a simulator can ignore.
    @MainActor func testDarkAppearanceWithNightModeOffKeepsMapLabelsReadable() throws {
        let dark = ["-appearance", "dark"]
        var app = try darkDirectTo("dark-day-direct")

        app = Screen.launch(dark + ["-offline", "1", "-center", Screen.dfw, "-zoom", "10"])
        let label = app.staticTexts["no-chart-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        sleep(1)
        let shot = try Screen.save("dark-day-no-chart")
        Screen.readable(label, shot)
    }

    // Landscape puts the readout over the city tint, the palest ground near Austin.
    @MainActor func testDarkAppearanceKeepsTheDirectToReadoutReadableInLandscape() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        try darkDirectTo("dark-day-direct-landscape", orientation: .landscapeLeft)
    }

    /// Starts direct-to Austin in dark appearance with night mode off and checks the map's labels.
    @discardableResult @MainActor
    private func darkDirectTo(_ name: String, orientation: UIDeviceOrientation = .portrait) throws -> XCUIApplication {
        let app = Screen.launch(Self.austin + ["-appearance", "dark", "-show", "nav", "-navQuery", "AUS"])
        XCUIDevice.shared.orientation = orientation
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["appearance-probe"].value as? String, "dark")
        row.tap()
        let direct = app.buttons["direct-to-button"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        direct.tap()
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForExistence(timeout: 10))
        try Screen.save("direct-list")
        app.buttons["direct-drawer-tab"].tap()
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForNonExistence(timeout: 5))
        try Screen.save("direct-drawer-closed")
        app.buttons["direct-drawer-tab"].tap()
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["night-button"].value as? String, "Off")
        sleep(2)
        let shot = try Screen.save(name)
        Screen.readable(app.staticTexts["map-direct-ident"], shot)
        Screen.readable(app.staticTexts["map-direct-distance"], shot)
        // The glyph sits in the middle of its round button.
        Screen.readable(app.buttons["search-button"], shot, inset: 0.2)
        Screen.readable(app.buttons["night-button"], shot, inset: 0.2)
        return app
    }

    @MainActor func testOverlayIsDrawnOnTheMapScreenAndFollowsItsSwitches() throws {
        let app = Screen.launch(Self.austin + ["-navNow", "2026-10-13T12:00:00Z"])
        loaded(app)
        let probe = app.staticTexts["map-nav"]
        waitUntil(probe, "label CONTAINS 'nav-airports'")
        XCTAssertTrue(probe.label.contains("nav-airspace"), probe.label)
        XCTAssertFalse(probe.label.contains("nav-fixes"), probe.label)
        XCTAssertFalse(app.staticTexts["nav-banner"].exists)
        sleep(3)
        try Screen.save("nav-overlay-austin")
        app.buttons["layers-button"].tap()
        let airports = app.switches["overlay-nav-airports"]
        XCTAssertTrue(airports.waitForExistence(timeout: 10))
        airports.switches.firstMatch.tap()
        // On a phone the picker is a sheet and hides the probe, so it is closed before the probe is read.
        app.buttons["panel-close"].tap()
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        waitUntil(probe, "NOT (label CONTAINS 'nav-airports')")
        XCTAssertTrue(probe.label.contains("nav-airspace"), probe.label)
    }

    @MainActor func testExpiredDataIsMarkedOnTheMap() throws {
        let app = Screen.launch(Self.austin + ["-navNow", "2026-11-05T12:00:00Z"])
        loaded(app)
        let banner = app.staticTexts["nav-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertEqual(banner.label, "Nav data expired 29 Oct 2026")
        sleep(2)
        try Screen.save("nav-expired")
    }

    @MainActor func testWithNothingInstalledTheMapSaysSo() throws {
        let app = Screen.launch(["-offline", "1", "-basePack", "test", "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        let banner = app.staticTexts["nav-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertEqual(banner.label, "Navigation data not downloaded")
        // Only the map writes these words, so this passes once it has reported that it draws no overlay.
        waitUntil(app.staticTexts["map-nav"], "label == 'overlay none direct off'")
        sleep(2)
        try Screen.save("nav-not-downloaded")
    }

    // The nav test packs carry no street map, so the chart store is given one and emptied afterwards.
    @MainActor func testStreetBaseDrawsTheOverlay() throws {
        addTeardownBlock { @MainActor in Screen.launch(["-seedPacks", "empty", "-offline", "1"]).terminate() }
        let app = Screen.launch(["-basePack", "nav", "-seedPacks", "current", "-manifestBase", Screen.deadServer,
                                 "-base", "street", "-center", Screen.dfw, "-zoom", "10",
                                 "-navNow", "2026-10-13T12:00:00Z"])
        loaded(app)
        // The street map is drawn and it holds the overlay.
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'")
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
        XCTAssertFalse(app.staticTexts["nav-banner"].exists)
        sleep(2)
        try Screen.save("nav-street-overlay")
    }

    @MainActor func testStreetChosenWithNoStreetMapKeepsTheOverlay() throws {
        let app = Screen.launch(Self.austin + ["-show", "layers", "-navNow", "2026-10-13T12:00:00Z"])
        XCTAssertTrue(app.buttons["base-street"].waitForExistence(timeout: 20))
        app.buttons["base-street"].tap()
        app.buttons["panel-close"].tap()
        let label = app.staticTexts["no-chart-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertEqual(label.label, "No street map downloaded")
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'")
        XCTAssertFalse(app.staticTexts["nav-banner"].exists)
        try Screen.save("nav-street-not-downloaded")
    }

    @MainActor private func openSearch(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["search-button"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    // The first spelling is typed. The other two arrive with the launch, as text already in the field.
    @MainActor func testSearchButtonReachesTheAirportPageByThreeSpellings() throws {
        for text in ["AUS", "KAUS", "Bergstrom"] {
            let typed = text == "AUS"
            let app = Screen.launch(Self.austin + ["-navNow", "2026-10-13T12:00:00Z"] + (typed ? [] : ["-navQuery", text]))
            loaded(app)
            let field = openSearch(app)
            if typed { Screen.type(text, into: field, app) }
            XCTAssertEqual(field.value as? String, text)
            let row = app.buttons["nav-result-AUS"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), text)
            if text == "AUS" { try Screen.save("nav-search") }
            row.tap()
            let bar = app.navigationBars["KAUS"]
            XCTAssertTrue(bar.waitForExistence(timeout: 10), text)
            XCTAssertTrue(bar.staticTexts["Austin-Bergstrom Intl"].exists, text)
            XCTAssertEqual(app.staticTexts["airport-place"].label, "Austin, TX · 542 ft")
            XCTAssertFalse(app.staticTexts["airport-data-warning"].exists)
            guard text == "AUS" else { continue }
            try Screen.save("nav-airport-page")
            app.collectionViews.firstMatch.swipeUp()
            XCTAssertTrue(app.buttons["frequency-0"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["frequency-0"].label.hasPrefix("ATIS"), app.buttons["frequency-0"].label)
            sleep(1)
            try Screen.save("nav-airport-frequencies")
            app.collectionViews.firstMatch.swipeUp()
            XCTAssertEqual(app.staticTexts["airport-data-dates"].label,
                           "FAA data effective 01 Oct 2026 to 29 Oct 2026")
            app.buttons["airport-remarks"].tap()
            XCTAssertTrue(app.navigationBars["Remarks"].waitForExistence(timeout: 5))
        }
    }

    // A field the FAA gives no ICAO code goes by its FAA code alone, with no K added.
    @MainActor func testAFieldWithNoICAOCodeIsTitledByItsFAACode() throws {
        let app = Screen.launch(Self.austin + ["-show", "nav", "-navQuery", "T82", "-navNow", "2026-10-13T12:00:00Z"])
        let row = app.buttons["nav-result-T82"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertFalse(row.label.contains("KT82"), row.label)
        row.tap()
        XCTAssertTrue(app.navigationBars["T82"].waitForExistence(timeout: 10))
        sleep(1)
        try Screen.save("nav-airport-t82")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["nav-result-T82"].waitForExistence(timeout: 5))
    }

    // The nav store outlives a launch, so it is emptied before its state is read.
    // Launched the way a pilot's copy starts, with a server that does not answer.
    @MainActor func testWithNothingInstalledThePanelOffersTheDownload() throws {
        let app = Screen.launch(["-seedNav", "empty", "-manifestBase", Screen.deadServer,
                                 "-center", Screen.dfw, "-zoom", "10"])
        XCTAssertTrue(app.buttons["search-button"].waitForExistence(timeout: 30))
        let field = openSearch(app)
        XCTAssertEqual(app.staticTexts["nav-problem"].label, "Navigation data is not downloaded")
        sleep(1)
        let day = XCUIScreen.main.screenshot()
        Screen.readable(app.staticTexts["nav-problem"], day)
        // The word sits in the middle of its filled button. White on the system accent measures about 3.5.
        Screen.readable(app.buttons["nav-download"], day, inset: 0.15, minimum: 3)
        let notice = app.staticTexts["nav-download-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "No connection. Connect to the internet to download navigation data.")
        app.buttons["nav-download"].tap()
        sleep(2)
        XCTAssertEqual(notice.label, "No connection. Connect to the internet to download navigation data.")
        XCTAssertEqual(app.staticTexts["nav-download-state"].label, "Not downloaded")
        // The test database holds AUS. It must not answer on a launch that did not ask for it.
        Screen.type("AUS", into: field, app)
        XCTAssertEqual(field.value as? String, "AUS")
        sleep(2)
        XCTAssertFalse(app.buttons["nav-result-AUS"].exists)
        XCTAssertFalse(app.staticTexts["nearest-header"].exists)
        try Screen.save("nav-panel-not-downloaded")
        // The same red words and the same button on the night glass.
        app.buttons["panel-close"].tap()
        app.buttons["night-button"].tap()
        _ = openSearch(app)
        sleep(1)
        let night = try Screen.save("nav-panel-not-downloaded-night")
        Screen.readable(app.staticTexts["nav-problem"], night)
        Screen.readable(app.buttons["nav-download"], night, inset: 0.15, minimum: 3)
    }

    @MainActor func testExpiredDataAndAClosedPrivateAirportAreMarkedInTheListAndOnThePage() throws {
        let app = Screen.launch(Self.austin + ["-show", "nav", "-navQuery", "TS01",
                                               "-navNow", "2026-11-05T12:00:00Z"])
        let row = app.buttons["nav-result-TS01"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["nav-data-warning"].label, "Not current: expired 29 Oct 2026")
        XCTAssertTrue(row.label.contains("Closed"), row.label)
        XCTAssertTrue(row.label.contains("PRIVATE"), row.label)
        sleep(1)
        Screen.readable(app.staticTexts["nav-data-warning"], XCUIScreen.main.screenshot())
        row.tap()
        let closed = app.staticTexts["airport-closed"]
        XCTAssertTrue(closed.waitForExistence(timeout: 10))
        XCTAssertEqual(closed.label, "Closed")
        XCTAssertEqual(app.staticTexts["airport-data-warning"].label, "Not current: expired 29 Oct 2026")
        sleep(1)
        Screen.readable(closed, try Screen.save("nav-airport-closed"))
    }

    // The simulator may or may not have a fix here, so the words are checked and the numbers are not.
    @MainActor func testDirectToReadoutNeverShowsNumbersWithoutALine() throws {
        let app = Screen.launch(Self.austin + ["-show", "nav", "-navQuery", "AUS"])
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let direct = app.buttons["direct-to-button"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        direct.tap()
        let bearing = app.staticTexts["map-direct-bearing"]
        XCTAssertTrue(bearing.waitForExistence(timeout: 10))
        XCTAssertTrue(bearing.label == "---" || bearing.label.hasSuffix("°M"), bearing.label)
        let distance = app.staticTexts["map-direct-distance"]
        XCTAssertTrue(distance.label == "---" || distance.label.hasSuffix(" NM"), distance.label)
        XCTAssertEqual(app.staticTexts["map-direct-ident"].label, "KAUS")
        // Dashes and a line never appear together.
        let probe = app.staticTexts["map-nav"].label
        XCTAssertEqual(probe.contains("direct on"), bearing.label != "---", probe)
        Screen.removeFirstWaypoint(app)
        waitUntil(app.staticTexts["map-nav"], "label ENDSWITH 'direct off'")
        XCTAssertFalse(app.staticTexts["map-direct-bearing"].exists)
    }

    // A phone on a landscape mount still shows every map button below the strip and the readout.
    @MainActor func testEveryMapButtonStaysOnScreenInLandscapeWithDirectTo() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = Screen.launch(Self.austin + ["-show", "nav", "-navQuery", "AUS"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let direct = app.buttons["direct-to-button"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        direct.tap()
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForExistence(timeout: 10))
        let map = app.otherElements["mapLoaded"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7)))
        waitUntil(app.buttons["tracking-button"], "value == 'Not following'")
        sleep(1)
        try Screen.save("\(Screen.device)-landscape-buttons")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "not landscape")
        let readout = app.descendants(matching: .any)["direct-row"]
        XCTAssertTrue(window.contains(readout.frame), "the Direct To row at \(readout.frame) is outside \(window)")
        for id in ["search-button", "layers-button", "settings-button", "tracking-button", "night-button"] {
            let frame = app.buttons[id].frame
            XCTAssertTrue(window.contains(frame), "\(id) at \(frame) is outside \(window)")
            XCTAssertTrue(app.buttons[id].isHittable, id)
        }
    }

    @MainActor func testTappingAnAirportSymbolOpensItsPage() throws {
        var arguments = Self.austin
        arguments[arguments.count - 1] = "11"
        let app = Screen.launch(arguments)
        loaded(app)
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'")
        sleep(2)
        app.otherElements["mapLoaded"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["KAUS"].waitForExistence(timeout: 10))
    }

    // The tapped airport, under where the card opens, moves to the middle of the map the card leaves open, ringed.
    @MainActor func testTappedAirportMovesClearOfThePanelAndIsRinged() throws {
        var arguments = Self.austin
        arguments[arguments.count - 1] = "11"
        let app = Screen.launch(arguments)
        loaded(app)
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'")
        sleep(2)
        let map = app.otherElements["mapLoaded"]
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["KAUS"].waitForExistence(timeout: 10))
        waitUntil(app.staticTexts["map-place"], "label == 'ring on centered'")
        try Screen.save("airport-centered")
        app.buttons["panel-close"].firstMatch.tap()
        waitUntil(app.staticTexts["map-place"], "label == 'ring off'")
    }

    // Layers over an open airport page switches the panel to the layer picker, and a second tap closes it.
    @MainActor func testLayersButtonOverAnAirportPageShowsTheLayers() throws {
        var arguments = Self.austin
        arguments[arguments.count - 1] = "11"
        let app = Screen.launch(arguments)
        loaded(app)
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'")
        sleep(2)
        app.otherElements["mapLoaded"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["KAUS"].waitForExistence(timeout: 10))
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["layer-picker"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["KAUS"].exists)
        app.buttons["layers-button"].tap()
        waitUntil(app.descendants(matching: .any)["layer-picker"], "exists == false")
    }

    // Night mode turns every panel dark, so no light panel sits over a dark chart.
    @MainActor func testNightModeTurnsEveryPanelDark() throws {
        let app = Screen.launch(Self.austin + ["-manifestBase", Screen.deadServer, "-navNow", "2026-10-13T12:00:00Z"])
        loaded(app)
        func look(_ button: String, _ wanted: String, _ shot: String) throws {
            if button == "settings-button" { Screen.openDownloads(app) } else { app.buttons[button].tap() }
            let title = app.staticTexts["appearance-probe"]
            XCTAssertTrue(title.waitForExistence(timeout: 10), button)
            XCTAssertEqual(title.value as? String, wanted, button)
            Screen.assertTargets(app)
            sleep(1)
            try Screen.save(shot)
            app.buttons["panel-close"].tap()
        }
        try look("settings-button", "light", "panel-downloads-day")
        try look("search-button", "light", "panel-nav-day")
        app.buttons["night-button"].tap()
        try look("settings-button", "dark", "panel-downloads-night")
        try look("search-button", "dark", "panel-nav-night")
        try look("layers-button", "dark", "panel-layers-night")
        // The airport page is drawn in the same panel, so it is dark too.
        Screen.type("AUS", into: openSearch(app), app)
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["KAUS"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["appearance-probe"].value as? String, "dark")
        try Screen.save("panel-airport-night")
    }
}
