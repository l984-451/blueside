import XCTest

final class LayerPickerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testPlatesOnTheMapAreListedFirstAndCanBeTakenOff() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "layers", "-plateOnMap", "00556IL18R.PDF"])
        let row = app.buttons["on-map-00556IL18R.PDF"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["On Map"].exists)
        XCTAssertTrue(app.buttons["on-map-remove-all"].exists)
        XCTAssertLessThan(row.frame.minY, app.switches["overlay-nav-airports"].frame.minY, "On Map is not the first section")
        try Screen.save("layers-on-map")
        row.tap()
        XCTAssertTrue(row.exists, "a tap flies to the plate and leaves it placed")
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(Screen.wait(5) { !row.exists && !app.staticTexts["On Map"].exists })
    }

    @MainActor func testStationReadoutsPickOneAtATime() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-show", "layers", "-basePack", "test", "-offline", "1", "-reset", "1"]
        app.launch()
        let picker = app.descendants(matching: .any)["layer-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        let wind = app.buttons["station-wind"], temperature = app.buttons["station-temperature"]
        for _ in 0..<4 where !wind.isHittable { picker.swipeUp() }
        wind.tap()
        XCTAssertTrue(wind.isSelected)
        temperature.tap()
        XCTAssertTrue(temperature.isSelected)
        XCTAssertFalse(wind.isSelected)
        try Screen.save("layers-weather")
        temperature.tap()
        XCTAssertFalse(temperature.isSelected)
    }

    @MainActor func testTappingEachBaseLayerSelectsIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-show", "layers", "-basePack", "test", "-center", "32.8968,-97.0380", "-zoom", "10",
                               "-offline", "1", "-reset", "1"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.buttons["base-vfr"].waitForExistence(timeout: 8), "the layer picker is not on screen")
        XCTAssertTrue(app.buttons["base-vfr"].isSelected)
        for name in ["ifr-low", "street", "aerial", "vfr"] {
            let row = app.buttons["base-\(name)"]
            row.tap()
            let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: row)
            wait(for: [selected], timeout: 5)
            for other in ["vfr", "ifr-low", "street", "aerial"] where other != name {
                XCTAssertFalse(app.buttons["base-\(other)"].isSelected, "\(other) stayed selected with \(name)")
            }
            sleep(2)
            if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
                try XCUIScreen.main.screenshot().pngRepresentation
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("layers-\(name).png"))
            }
        }
    }
}
