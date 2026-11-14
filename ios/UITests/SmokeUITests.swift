import XCTest

final class SmokeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testLaunchesWithNoArguments() {
        let app = XCUIApplication()
        // Offline keeps the network and packs from earlier runs out of the result.
        app.launchArguments = ["-offline", "1", "-reset", "1"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // A crash on launch shows up as the app leaving the foreground.
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 3))
    }

    @MainActor func testBundledChartDraws() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-basePack", "test", "-center", "32.8968,-97.0380", "-zoom", "10", "-offline", "1", "-reset", "1"]
        app.launch()
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))

        // A flat gray screen is under 100 KB as a PNG and a drawn chart is several MB.
        var shot = XCUIScreen.main.screenshot()
        let deadline = Date().addingTimeInterval(10)
        while shot.pngRepresentation.count < 1_000_000, Date() < deadline {
            sleep(1)
            shot = XCUIScreen.main.screenshot()
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "smoke-map"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("smoke-map.png"))
        }
        XCTAssertGreaterThan(shot.pngRepresentation.count, 1_000_000, "the chart did not draw")
    }
}
