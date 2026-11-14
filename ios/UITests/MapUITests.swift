import XCTest

final class MapUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private static var blankSize = 0

    // PNG size a drawn chart must exceed: four times the same screen with no chart, measured once per run.
    // A sectional is about 35 times the blank screen and an enroute chart, mostly white paper, about 8 times.
    @MainActor private func drawnFloor() -> Int {
        if Self.blankSize == 0 {
            let app = XCUIApplication()
            app.launchArguments = ["-offline", "1", "-reset", "1"]
            app.launch()
            XCTAssertTrue(app.staticTexts["no-chart-label"].waitForExistence(timeout: 20))
            Self.blankSize = XCUIScreen.main.screenshot().pngRepresentation.count
        }
        return 4 * Self.blankSize
    }

    // Waits for tiles, saves the screen, and fails if it is no busier than a blank map.
    @MainActor private func chartShot(_ name: String, arguments: [String]) throws -> XCUIScreenshot {
        let floor = drawnFloor()
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-reset", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        var shot = XCUIScreen.main.screenshot()
        let deadline = Date().addingTimeInterval(10)
        while shot.pngRepresentation.count <= floor, Date() < deadline {
            sleep(1)
            shot = XCUIScreen.main.screenshot()
        }
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        XCTAssertGreaterThan(shot.pngRepresentation.count, floor, "\(name): the chart did not draw")
        return shot
    }

    // Mean brightness from 0 to 1, from the picture drawn into a small gray bitmap.
    private func brightness(_ shot: XCUIScreenshot) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(shot.image.cgImage!, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(side * side * 255)
    }

    @MainActor func testNightModeDarkensTheChart() throws {
        let view = ["-basePack", "test", "-center", "32.8968,-97.0380", "-zoom", "10", "-offline", "1", "-reset", "1"]
        let day = try chartShot("map-day", arguments: view)
        let night = try chartShot("map-night", arguments: view + ["-night", "1"])
        XCTAssertLessThan(brightness(night), brightness(day) - 0.2, "night mode did not darken the chart")
    }

    // Outside chart coverage the map is all background, so night mode must darken that too.
    @MainActor func testNightModeDarkensTheEmptyMap() throws {
        var levels: [Double] = []
        for night in ["0", "1"] {
            let app = XCUIApplication()
            app.launchArguments = ["-offline", "1", "-night", night, "-reset", "1"]
            app.launch()
            XCTAssertTrue(app.staticTexts["no-chart-label"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
            sleep(1)
            levels.append(brightness(XCUIScreen.main.screenshot()))
        }
        XCTAssertLessThan(levels[1], levels[0] - 0.2, "night mode left the map background bright")
    }

    @MainActor func testIFRLowDrawsFromItsOwnPacks() throws {
        _ = try chartShot("map-ifr-low", arguments: ["-basePack", "test", "-base", "ifr-low",
                                                     "-center", "32.8968,-97.0380", "-zoom", "10", "-offline", "1", "-reset", "1"])
    }

    @MainActor func testNoPackShowsTheLabel() throws {
        let app = XCUIApplication()
        // Offline keeps downloaded packs and the network out, so the result does not depend on earlier runs.
        app.launchArguments = ["-base", "ifr-low", "-offline", "1", "-reset", "1"]
        app.launch()
        let label = app.staticTexts["no-chart-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        XCTAssertEqual(label.label, "No IFR Low chart downloaded")
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("map-no-chart.png"))
        }
    }

    @MainActor func testLabelIsAbsentWhenAChartIsDrawn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-basePack", "test", "-center", "32.8968,-97.0380", "-zoom", "10", "-offline", "1", "-reset", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
    }
}
