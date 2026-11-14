import XCTest

/// Needs the pack server and the track replay running beside the tests. Tests run in name order.
final class AcceptanceUITests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["ACCEPT_SERVER"] ?? ""
    private let hasDriver = ProcessInfo.processInfo.environment["LOCATION_DRIVER"] == "1"

    @MainActor override func setUp() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        try XCTSkipIf(server.isEmpty || !hasDriver, "the pack server and the track replay are not running")
        // A track left running by the test before would move the map and the aircraft in this one.
        try Screen.request("gps-clear")
    }

    @MainActor private func loaded(_ app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
    }

    @MainActor private func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval) {
        wait(for: [expectation(for: NSPredicate(format: format), evaluatedWith: element)], timeout: timeout)
    }

    /// Reads the number after a word in the map's camera text, which looks like "heading 90 zoom 11".
    @MainActor private func camera(_ app: XCUIApplication, _ word: String) throws -> Int {
        let parts = app.staticTexts["map-camera"].label.split(separator: " ")
        let index = try XCTUnwrap(parts.firstIndex(of: Substring(word)), "the map reported no \(word)")
        return try XCTUnwrap(Int(parts[index + 1]))
    }

    @MainActor func test1DownloadListGoesFromNotDownloadedToReadyAcrossARelaunch() throws {
        let arguments = ["-show", "downloads", "-downloads", "charts", "-manifestBase", server, "-center", Screen.dfw, "-zoom", "9"]
        let app = Screen.launch(arguments)
        let state = app.staticTexts["state-TX"]
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        XCTAssertEqual(state.label, "Not downloaded")
        try Screen.save("downloads-not-downloaded")
        app.buttons["download-TX"].tap()
        waitUntil(state, "label BEGINSWITH 'Downloading'", timeout: 20)
        try Screen.save("downloads-downloading")
        // The transfer belongs to the system, so closing the app must not stop it.
        app.terminate()
        sleep(4)
        app.launch()
        waitUntil(app.staticTexts["state-TX"], "label == 'Ready'", timeout: 80)
        sleep(2)
        try Screen.save("downloads-ready")
    }

    @MainActor func test2NoNetworkKeepsChartsAndTheLastKnownList() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(["-manifestBase", Screen.deadServer, "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        try Screen.chartShot("failure-no-network-map", floor: floor)
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
        Screen.openDownloads(app)
        let note = app.staticTexts["downloads-offline"]
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        XCTAssertEqual(note.label, "No connection. Showing the last known list.")
        Screen.openCategory(app, "charts")
        XCTAssertTrue(app.staticTexts["state-TX"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["state-TX"].label, "Ready")
        try Screen.save("failure-no-network-list")
    }

    @MainActor func test3AllFourBaseLayersWithAMovingTrack() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(["-basePack", "test", "-manifestBase", Screen.deadServer, "-follow", "1",
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        try Screen.request("gps-start")
        waitUntil(app.staticTexts["strip-groundspeed"], "label ENDSWITH 'knots'", timeout: 30)
        try Screen.chartShot("layer-vfr", floor: floor)
        for name in ["ifr-low", "street", "aerial"] {
            app.buttons["layers-button"].tap()
            XCTAssertTrue(app.buttons["base-\(name)"].waitForExistence(timeout: 5))
            app.buttons["base-\(name)"].tap()
            app.buttons["panel-close"].tap()
            // Lets the panel finish closing, so the picture is of the map alone.
            sleep(2)
            if name == "street" {
                sleep(3)
                try Screen.save("layer-street")
            } else {
                try Screen.chartShot("layer-\(name)", floor: floor)
            }
            XCTAssertFalse(app.staticTexts["no-chart-label"].exists, "\(name) drew nothing")
            XCTAssertFalse(app.staticTexts["aerial-offline-label"].exists)
        }
        XCTAssertTrue(app.staticTexts["aerial-credit"].exists)
    }

    @MainActor func test3TexasChartViews() throws {
        let floor = Screen.drawnFloor()
        // The widest view goes last, so a pack with a hole in it still gets both close views checked.
        let views = [("texas-dfw-terminal", Screen.dfw, "12"), ("texas-houston-terminal", "29.9844,-95.3414", "12"),
                     ("texas-statewide", "31.0,-99.0", "6")]
        for (name, center, zoom) in views {
            let app = Screen.launch(["-manifestBase", Screen.deadServer, "-center", center, "-zoom", zoom])
            loaded(app)
            let shot = try Screen.chartShot(name, floor: floor)
            XCTAssertFalse(Screen.centerIsBlank(shot), "\(name): no chart at the center of the view")
            XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
            XCTAssertFalse(app.staticTexts["no-coverage-label"].exists)
            XCTAssertFalse(app.staticTexts["chart-banner"].exists)
        }
    }

    @MainActor func test3TexasIFRLowViewsAndTheEdgeOfTheCharts() throws {
        let floor = Screen.drawnFloor()
        // The close view draws the area chart, the wide one the en route chart.
        for (name, zoom) in [("texas-ifr-area-dfw", "11.6"), ("texas-ifr-low", "8")] {
            let app = Screen.launch(["-base", "ifr-low", "-manifestBase", Screen.deadServer,
                                     "-center", Screen.dfw, "-zoom", zoom])
            loaded(app)
            let shot = try Screen.chartShot(name, floor: floor)
            XCTAssertFalse(Screen.centerIsBlank(shot), "\(name): no chart at the center of the view")
            XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
            XCTAssertFalse(app.staticTexts["no-coverage-label"].exists)
            XCTAssertFalse(app.staticTexts["chart-banner"].exists)
        }
        // Central Mexico is on no chart, so the gray there must carry words, on both chart families.
        // The second point is under a wide tile of the Texas pack that is empty that far south.
        for (base, center) in [("vfr", "20.0,-100.0"), ("ifr-low", "23.0,-100.0")] {
            let app = Screen.launch(["-base", base, "-manifestBase", Screen.deadServer,
                                     "-center", center, "-zoom", "8"])
            loaded(app)
            let label = app.staticTexts["no-coverage-label"]
            XCTAssertTrue(label.waitForExistence(timeout: 10), "\(base): gray map with no words")
            XCTAssertEqual(label.label, "No chart coverage here")
            sleep(1)
            try Screen.save("texas-no-coverage-\(base)")
        }
    }

    @MainActor func test4TrackUpAndNightOverTexas() throws {
        let floor = Screen.drawnFloor()
        let app = Screen.launch(["-manifestBase", Screen.deadServer, "-follow", "1",
                                 "-center", Screen.dfw, "-zoom", "11"])
        loaded(app)
        try Screen.request("gps-start")
        waitUntil(app.staticTexts["strip-track"], "label ENDSWITH '°M'", timeout: 30)
        sleep(2)
        try Screen.chartShot("track-north-up", floor: floor)
        XCTAssertTrue([0, 360].contains(try camera(app, "heading")), "north-up map is turned")
        let toggle = app.buttons["tracking-button"]
        toggle.tap()
        waitUntil(toggle, "value == 'Following, track up'", timeout: 5)
        sleep(3)
        // The replay runs east, so a track-up map reports a heading near 90.
        XCTAssertTrue((80...100).contains(try camera(app, "heading")), "the map did not turn to the track")
        let day = try Screen.chartShot("track-track-up", floor: floor)
        app.buttons["night-button"].tap()
        sleep(3)
        let night = try Screen.chartShot("track-night", floor: floor)
        XCTAssertLessThan(Screen.brightness(night), Screen.brightness(day) - 0.2, "night mode did not darken the chart")
        // Zooming out while following must hold: eight two-finger taps take zoom 11 to about 4.
        // XCUITest's synthesized pinch does not reach MapLibre's pinch recognizer, so taps stand in.
        let map = app.otherElements["mapLoaded"]
        for _ in 0..<8 { map.twoFingerTap() }
        sleep(3)
        XCTAssertLessThan(try camera(app, "zoom"), 7, "following put the zoom back")
        XCTAssertEqual(toggle.value as? String, "Following, track up", "a pinch stopped the map following")
        // Panned away, the map still keeps the track at the top.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8)))
        waitUntil(toggle, "value == 'Not following'", timeout: 5)
        sleep(3)
        XCTAssertTrue((80...100).contains(try camera(app, "heading")), "track-up was lost after a pan")
    }

    // Bundled test files and simulated fixes: the line starts at the aircraft, follows it, and goes on cancel.
    @MainActor func test5DirectToLineStartsAtTheAircraftFollowsItAndCancels() throws {
        let app = Screen.launch(["-offline", "1", "-basePack", "nav", "-show", "nav", "-navQuery", "AUS",
                                 "-center", Screen.dfw, "-zoom", "8"])
        try Screen.request("gps-fixed")
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.buttons["direct-to-button"].waitForExistence(timeout: 10))
        app.buttons["direct-to-button"].tap()
        let probe = app.staticTexts["map-nav"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        waitUntil(probe, "label ENDSWITH 'direct on 32.897,-97.038'", timeout: 30)
        // DFW to Austin is 191.4 degrees true; east variation of a few degrees is taken off.
        let bearing = app.staticTexts["map-direct-bearing"]
        waitUntil(bearing, "label ENDSWITH '°M'", timeout: 10)
        let degrees = try XCTUnwrap(Int(bearing.label.prefix(3)), bearing.label)
        print("direct-to from DFW to AUS reads \(bearing.label) \(app.staticTexts["map-direct-distance"].label)")
        XCTAssertTrue((185...191).contains(degrees), bearing.label)
        XCTAssertTrue(app.staticTexts["map-direct-distance"].label.hasSuffix(" NM"))
        XCTAssertTrue(app.staticTexts["strip-track"].label == "Track unknown" || app.staticTexts["strip-track"].label.hasSuffix("°M"))
        // The aircraft flies east at 100 m/s, and the start of the line leaves DFW with it.
        try Screen.request("gps-start")
        waitUntil(probe, "label CONTAINS 'direct on' AND NOT (label ENDSWITH '32.897,-97.038')", timeout: 40)
        waitUntil(app.staticTexts["strip-track"], "label ENDSWITH '°M'", timeout: 20)
        print("eastbound track reads \(app.staticTexts["strip-track"].label)")
        Screen.removeFirstWaypoint(app)
        waitUntil(probe, "label ENDSWITH 'direct off'", timeout: 10)
        XCTAssertFalse(app.staticTexts["map-direct-ident"].exists)
    }

    @MainActor func test5GpsLostGraysTheSymbolAndDashesTheStrip() throws {
        let app = Screen.launch(["-basePack", "test", "-offline", "1", "-follow", "1",
                                 "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        try Screen.request("gps-start")
        let speed = app.staticTexts["strip-groundspeed"]
        waitUntil(speed, "label ENDSWITH 'knots'", timeout: 30)
        sleep(2)
        let live = Screen.centerColors(try Screen.save("failure-gps-live"))
        try Screen.request("gps-clear")
        waitUntil(speed, "label == 'Groundspeed unknown'", timeout: 20)
        XCTAssertEqual(app.staticTexts["strip-track"].label, "Track unknown")
        XCTAssertEqual(app.staticTexts["strip-altitude"].label, "Altitude unknown")
        sleep(2)
        let lost = Screen.centerColors(try Screen.save("failure-gps-lost"))
        print("center pixels live \(live) lost \(lost)")
        XCTAssertGreaterThan(live.blue, 300, "no blue aircraft symbol at the center with a live fix")
        XCTAssertLessThan(lost.blue, live.blue / 4, "the aircraft symbol stayed blue after the fixes stopped")
        XCTAssertGreaterThan(lost.gray, live.gray + 300, "no gray aircraft symbol at the center")
    }

    private static let austin = "30.1945,-97.6699"

    // The navigation files download on their own, are verified, and draw over the Texas chart.
    @MainActor func test5NavADataDownloadsAndDrawsOverAustin() throws {
        let app = Screen.launch(["-show", "downloads", "-downloads", "nav", "-manifestBase", server,
                                 "-center", Self.austin, "-zoom", "9"])
        let state = app.staticTexts["nav-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        waitUntil(state, "label == 'Ready'", timeout: 80)
        app.buttons["panel-close"].tap()
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'", timeout: 20)
        XCTAssertFalse(app.staticTexts["nav-banner"].exists)
        sleep(4)
        try Screen.save("nav-overlay-austin")
    }

    @MainActor func test5NavBSearchPageNearestAndDirectTo() throws {
        let app = Screen.launch(["-manifestBase", Screen.deadServer, "-center", Self.austin, "-zoom", "9"])
        loaded(app)
        try Screen.request("gps-fixed")
        app.buttons["search-button"].tap()
        let header = app.staticTexts["nearest-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        // The list is worked out when the first fix arrives, so the header is the wait for the fix.
        waitUntil(header, "label BEGINSWITH 'Nearest airports from 32°53.81′N 097°02.28′W at '", timeout: 30)
        XCTAssertTrue(app.buttons["nearest-DFW"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["nearest-DFW"].label.contains("°M"))
        sleep(1)
        try Screen.save("nav-nearest")
        let field = app.searchFields.firstMatch
        Screen.type("KAUS", into: field, app)
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        try Screen.save("nav-search")
        row.tap()
        XCTAssertTrue(app.navigationBars["KAUS"].exists)
        XCTAssertFalse(app.staticTexts["airport-data-warning"].exists)
        sleep(1)
        try Screen.save("nav-airport-page")
        // The data dates close a long page; Direct To sits at its top.
        reveal(app.staticTexts["airport-data-dates"], in: app)
        XCTAssertEqual(app.staticTexts["airport-data-dates"].label, "FAA data effective 01 Oct 2026 to 29 Oct 2026")
        XCTAssertEqual(app.staticTexts["airport-sua-date"].label, "Special use airspace as of 28 Sep 2026")
        reveal(app.buttons["direct-to-button"], in: app, back: true)
        app.buttons["direct-to-button"].tap()
        let bearing = app.staticTexts["map-direct-bearing"]
        XCTAssertTrue(bearing.waitForExistence(timeout: 10))
        // DFW to Austin is about 166 NM on 191.4 degrees true, which reads 189 magnetic.
        waitUntil(bearing, "label ENDSWITH '°M'", timeout: 10)
        let degrees = try XCTUnwrap(Int(bearing.label.prefix(3)))
        XCTAssertTrue((188...190).contains(degrees), bearing.label)
        XCTAssertTrue(app.staticTexts["map-direct-distance"].label.hasSuffix(" NM"))
        let probe = app.staticTexts["map-nav"]
        // The line starts at the aircraft, which is parked at DFW.
        waitUntil(probe, "label ENDSWITH 'direct on 32.897,-97.038'", timeout: 10)
        sleep(2)
        try Screen.save("nav-direct-to")

        // Canceling takes a drawn line off the map.
        Screen.removeFirstWaypoint(app)
        waitUntil(probe, "label ENDSWITH 'direct off'", timeout: 10)
        XCTAssertFalse(app.staticTexts["map-direct-ident"].exists)

        // Direct-to again from the page, which is still open behind the button.
        app.buttons["search-button"].tap()
        XCTAssertTrue(app.buttons["direct-to-button"].waitForExistence(timeout: 10))
        app.buttons["direct-to-button"].tap()
        waitUntil(probe, "label CONTAINS 'direct on'", timeout: 10)

        // The aircraft flies east at 100 m/s, and the start of the line leaves DFW with it.
        try Screen.request("gps-start")
        waitUntil(probe, "label CONTAINS 'direct on' AND NOT (label ENDSWITH '32.897,-97.038')", timeout: 40)
        waitUntil(bearing, "label ENDSWITH '°M'", timeout: 10)
        let moving = try XCTUnwrap(Int(bearing.label.prefix(3)))
        XCTAssertTrue((188...193).contains(moving), bearing.label)

        // With the fixes gone the numbers and the line go too, with no tap.
        try Screen.request("gps-clear")
        waitUntil(bearing, "label == '---'", timeout: 20)
        XCTAssertEqual(app.staticTexts["map-direct-distance"].label, "---")
        waitUntil(probe, "label ENDSWITH 'direct off'", timeout: 10)
        XCTAssertEqual(app.staticTexts["map-direct-ident"].label, "KAUS")
    }

    /// A list builds its rows as they come into view, so the page is dragged up until the row exists.
    /// With back set it drags down, to bring the page's top into view again.
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, back: Bool = false) {
        let x = app.navigationBars.firstMatch.frame.midX
        let corner = app.coordinate(withNormalizedOffset: .zero)
        let (from, to) = back ? (0.45, 0.85) : (0.85, 0.45)
        for _ in 0..<14 where !(element.exists && element.isHittable) {
            corner.withOffset(CGVector(dx: x, dy: app.frame.height * from))
                // The hold at the end leaves no fling, so a tap that follows lands on a still list.
                .press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: x, dy: app.frame.height * to)),
                       withVelocity: .default, thenHoldForDuration: 0.1)
        }
    }

    // The words on the airport page, read from the national file: a closed runway, a dead frequency, a working one.
    @MainActor func test5NavBClosedRunwaysAndDeadFrequenciesAreLabeled() throws {
        let notes = NSPredicate(format: "identifier BEGINSWITH 'frequency-note-'")
        func page(_ ident: String) -> XCUIApplication {
            let app = Screen.launch(["-manifestBase", Screen.deadServer, "-show", "nav", "-navQuery", ident,
                                     "-center", Self.austin, "-zoom", "9"])
            let row = app.buttons["nav-result-\(ident)"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), ident)
            row.tap()
            XCTAssertTrue(app.staticTexts["airport-place"].waitForExistence(timeout: 10), ident)
            return app
        }
        // Page, Arizona: runway 07/25 is closed indefinitely.
        var app = page("PGA")
        let closed = app.staticTexts["runway-note-07/25"]
        reveal(closed, in: app)
        XCTAssertEqual(closed.label, "Closed")
        try Screen.save("nav-closed-runway")
        // 2F4: the UNICOM remark reads UNICOM OTS INDEFLY.
        app = page("2F4")
        let dead = app.staticTexts.matching(notes).firstMatch
        reveal(dead, in: app)
        XCTAssertEqual(dead.label, "Out of service")
        XCTAssertEqual(app.staticTexts.matching(notes).count, 1)
        // 3G5: the CTAF remark says a light is out. The remark is brought into view first, so no label is a true absence.
        app = page("3G5")
        let remark = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'PAPI RWY 05 & 23 OTS'")).firstMatch
        reveal(remark, in: app)
        XCTAssertTrue(remark.exists)
        XCTAssertEqual(app.staticTexts.matching(notes).count, 0)
        // ME16 carries the same remark twice under one runway end, so a page that draws has told the rows apart.
        app = page("ME16")
        let repeated = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'OTS INDEFLY.'")).firstMatch
        // Airport-wide remarks are on their own page under the list.
        let remarks = app.buttons["airport-remarks"]
        reveal(remarks, in: app)
        remarks.tap()
        XCTAssertTrue(repeated.waitForExistence(timeout: 5))
    }

    // No clock is set here. The installed files' cycle ended on 1 October, so the real clock is past their expiry.
    @MainActor func test5NavCAnInstalledPackPastItsExpiryIsMarkedOnTheMap() throws {
        let app = Screen.launch(["-seedNav", "empty", "-manifestBase", server, "-navList", "nav/old-manifest.json",
                                 "-center", Self.austin, "-zoom", "9"])
        loaded(app)
        let banner = app.staticTexts["nav-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        // Until the two small files are in, the label says not downloaded.
        waitUntil(banner, "label == 'Nav data expired 01 Oct 2026'", timeout: 60)
        // The overlay stays on under the label.
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airspace'", timeout: 20)
        sleep(3)
        try Screen.save("nav-expired")

        // A newer database the app cannot read is refused, and the older one stays in use.
        app.terminate()
        let again = Screen.launch(["-show", "downloads", "-downloads", "nav", "-manifestBase", server,
                                   "-navList", "nav/refused-manifest.json", "-center", Self.austin, "-zoom", "9"])
        let state = again.staticTexts["nav-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        waitUntil(state, "label == 'Failed: File could not be read by this version'", timeout: 60)
        again.buttons["panel-close"].tap()
        XCTAssertTrue(again.staticTexts["nav-banner"].waitForExistence(timeout: 5))
        XCTAssertEqual(again.staticTexts["nav-banner"].label, "Nav data expired 01 Oct 2026")
    }

    // A database that fails its checksum twice is deleted, reported, and never opened.
    @MainActor func test5NavDAChecksumFailureIsNeverOpened() throws {
        var app = Screen.launch(["-seedNav", "empty", "-show", "downloads", "-downloads", "nav", "-manifestBase", server,
                                 "-navList", "nav/bad-manifest.json", "-center", Self.austin, "-zoom", "9"])
        let state = app.staticTexts["nav-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        waitUntil(state, "label == 'Failed: Checksum failed twice'", timeout: 60)
        XCTAssertTrue(app.buttons["nav-row-retry"].exists)
        app.buttons["panel-close"].tap()
        // On a phone the sheet hid the label until now.
        XCTAssertTrue(app.staticTexts["nav-banner"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nav-banner"].label, "Navigation data not downloaded")
        waitUntil(app.staticTexts["map-nav"], "label == 'overlay none direct off'", timeout: 10)
        app.buttons["search-button"].tap()
        XCTAssertTrue(app.staticTexts["nav-problem"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["nav-problem"].label, "Navigation data is not downloaded")
        sleep(1)
        try Screen.save("nav-not-downloaded")
        // The good list is put back for whatever runs next.
        app.terminate()
        app = Screen.launch(["-seedNav", "empty", "-show", "downloads", "-downloads", "nav", "-manifestBase", server])
        waitUntil(app.staticTexts["nav-state"], "label == 'Ready'", timeout: 80)
    }

    // Pictures on real data with no test rows in the list.
    @MainActor func test5NavEPicturesOfEveryPanelByDayAndNight() throws {
        let app = Screen.launch(["-manifestBase", server, "-chartList", "clean-manifest.json",
                                 "-center", Self.austin, "-zoom", "9"])
        loaded(app)
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'nav-airports'", timeout: 30)
        sleep(3)
        try Screen.save("pic-map")
        func panel(_ button: String, _ shot: String, _ wanted: String) throws {
            if button == "settings-button" { Screen.openDownloads(app) } else { app.buttons[button].tap() }
            let title = app.staticTexts["appearance-probe"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            XCTAssertEqual(title.value as? String, wanted)
            Screen.assertTargets(app)
            if button == "settings-button" {
                waitUntil(app.staticTexts["downloads-summary-nav"], "label MATCHES '.* (KB|MB|GB)'", timeout: 30)
                Screen.openCategory(app, "charts")
                waitUntil(app.staticTexts["state-TX"], "label == 'Ready'", timeout: 30)
                XCTAssertFalse(app.staticTexts["state-XX"].exists)
                XCTAssertFalse(app.staticTexts["state-ZZ"].exists)
            }
            sleep(1)
            try Screen.save(shot)
            app.buttons["panel-close"].tap()
        }
        try panel("settings-button", "pic-downloads-day", "light")
        try panel("layers-button", "pic-layer-picker", "light")
        app.buttons["night-button"].tap()
        try panel("settings-button", "pic-downloads-night", "dark")
        app.buttons["search-button"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        Screen.type("KAUS", into: field, app)
        XCTAssertTrue(app.buttons["nav-result-AUS"].waitForExistence(timeout: 10))
        app.buttons["nav-result-AUS"].tap()
        XCTAssertTrue(app.staticTexts["airport-place"].waitForExistence(timeout: 10))
        sleep(1)
        try Screen.save("pic-airport-page-night")
    }

    // The first fix zooms in and then moves to the aircraft; a parked aircraft sends nothing after that.
    @MainActor func test5ParkedAircraftOverAChartShowsNoCoverageLabel() throws {
        let app = Screen.launch(["-basePack", "test", "-offline", "1", "-follow", "1"])
        loaded(app)
        try Screen.request("gps-fixed")
        waitUntil(app.staticTexts["map-camera"], "label ENDSWITH 'zoom 10'", timeout: 30)
        sleep(3)
        try Screen.save("parked-on-chart")
        XCTAssertFalse(app.staticTexts["no-coverage-label"].exists, "the label sits on a chart that is drawn")
    }

    @MainActor func test6ExpiredPacksShowInTheListAndOnTheBanner() throws {
        let app = Screen.launch(["-seedPacks", "expired", "-show", "downloads", "-downloads", "charts", "-manifestBase", server,
                                 "-center", Screen.dfw, "-zoom", "10"])
        let state = app.staticTexts["state-TX"]
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        XCTAssertEqual(state.label, "Expired")
        // A sheet hides what is under it from the test, so the banner is read on the wide layout only.
        if Screen.device == "ipad" {
            XCTAssertTrue(app.staticTexts["chart-banner"].label.hasPrefix("Charts expired "))
        }
        sleep(2)
        let shot = try Screen.save("downloads-expired")
        Screen.readable(state, shot)
        Screen.readable(app.buttons["update-TX"], shot, inset: 0.15, minimum: 3) // a glyph: 3:1 for non-text
        // The same words on the night glass. On a phone the sheet covers the night button.
        if Screen.device == "ipad" {
            app.buttons["night-button"].tap()
            sleep(2)
            let night = try Screen.save("downloads-expired-night")
            Screen.readable(state, night)
            Screen.readable(app.buttons["update-TX"], night, inset: 0.15, minimum: 3)
        }
    }

    // A transfer the system still holds for a region nobody wants any more must be stopped, not shown as running.
    @MainActor func test6TransferLeftForAnUnwantedRegionIsStopped() throws {
        let list = ["-show", "downloads", "-downloads", "charts", "-manifestBase"]
        // The first launch only stores the list, so the second can show it with no server.
        var app = Screen.launch(["-seedPacks", "empty"] + list + [server])
        XCTAssertTrue(app.staticTexts["state-TX"].waitForExistence(timeout: 20))
        sleep(2)
        app.terminate()
        // Nothing answers at this address, so a transfer started here waits and never ends.
        app = Screen.launch(list + [Screen.deadServer])
        XCTAssertTrue(app.staticTexts["state-XX"].waitForExistence(timeout: 20))
        if app.buttons["download-XX"].exists { app.buttons["download-XX"].tap() }
        sleep(3)
        print("leftover transfer reads \(app.staticTexts["state-XX"].label)")
        app.terminate()
        app = Screen.launch(["-seedPacks", "empty"] + list + [server])
        XCTAssertTrue(app.buttons["download-XX"].waitForExistence(timeout: 20), "a leftover transfer hides Download")
        XCTAssertEqual(app.staticTexts["state-XX"].label, "Not downloaded")
    }

    @MainActor func test7FailedDownloadAndFullStorageSaySo() throws {
        let app = Screen.launch(["-seedPacks", "empty", "-show", "downloads", "-downloads", "charts", "-manifestBase", server])
        XCTAssertTrue(app.buttons["download-XX"].waitForExistence(timeout: 20))
        app.buttons["download-XX"].tap()
        waitUntil(app.staticTexts["state-XX"], "label BEGINSWITH 'Failed'", timeout: 30)
        Screen.readable(app.staticTexts["state-XX"], try Screen.save("downloads-failed"))
        app.buttons["download-ZZ"].tap()
        let message = app.staticTexts["downloads-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.hasPrefix("Not enough storage"), message.label)
        sleep(1)
        Screen.readable(message, try Screen.save("downloads-storage-full"))
        // The two regions chosen here must not start transfers in whatever runs next.
        app.terminate()
        Screen.launch(["-seedPacks", "empty", "-offline", "1"]).terminate()
    }

    // With only the wide-area chart on the device, a close view is a smear and must say what is missing.
    @MainActor func test7WideAreaChartAloneSaysNoDetailedChartUpClose() throws {
        let floor = Screen.drawnFloor()
        var app = Screen.launch(["-seedPacks", "empty", "-manifestBase", server, "-center", Screen.dfw, "-zoom", "10"])
        loaded(app)
        // The wide-area chart downloads by itself, with no region chosen.
        let label = app.staticTexts["no-detail-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 40), "stretched chart with no words")
        XCTAssertEqual(label.label, "No detailed chart downloaded here")
        XCTAssertFalse(app.staticTexts["no-coverage-label"].exists)
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
        sleep(1)
        try Screen.save("failure-no-detail")
        app.terminate()
        // From far enough out the same chart is sharp, so nothing is said.
        app = Screen.launch(["-manifestBase", Screen.deadServer, "-center", "31.0,-99.0", "-zoom", "6"])
        loaded(app)
        try Screen.chartShot("wide-area-alone", floor: floor)
        XCTAssertFalse(app.staticTexts["no-detail-label"].exists)
        XCTAssertFalse(app.staticTexts["no-coverage-label"].exists)
    }
}
