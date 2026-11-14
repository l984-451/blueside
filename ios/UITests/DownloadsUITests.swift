import XCTest

final class DownloadsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // Needs the range server serving a manifest whose TX packs are under /slow/.
    @MainActor func testDownloadSurvivesTheAppBeingClosed() throws {
        let server = ProcessInfo.processInfo.environment["RANGE_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "no range server address was given")
        let app = XCUIApplication()
        // The first launch starts from an empty store, so packs left by other tests cannot hide the button.
        app.launchArguments = ["-show", "downloads", "-downloads", "charts", "-manifestBase", server, "-seedPacks", "empty", "-reset", "1"]
        app.launch()
        app.launchArguments = ["-show", "downloads", "-downloads", "charts", "-manifestBase", server]
        XCTAssertTrue(app.buttons["download-TX"].waitForExistence(timeout: 10), "the download list is not on screen")
        app.buttons["download-TX"].tap()
        let state = app.staticTexts["state-TX"]
        let downloading = expectation(for: NSPredicate(format: "label BEGINSWITH 'Downloading'"), evaluatedWith: state)
        wait(for: [downloading], timeout: 20)
        app.terminate()
        sleep(5)
        app.launch()
        let ready = expectation(for: NSPredicate(format: "label == 'Ready'"), evaluatedWith: state)
        wait(for: [ready], timeout: 90)
        if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("downloads-ready.png"))
        }
    }
}
