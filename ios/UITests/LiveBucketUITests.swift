import XCTest

/// One real download from the address built into the app. It needs the internet, so it runs only when asked for.
final class LiveBucketUITests: XCTestCase {
    @MainActor func testSmallStateDownloadsInstallsAndDraws() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_BUCKET"] == "1", "set LIVE_BUCKET=1 to run")
        continueAfterFailure = false
        executionTimeAllowance = 120
        let floor = Screen.drawnFloor()
        // No address is passed, so the list and the packs come from the built-in one.
        let app = Screen.launch(["-seedPacks", "empty", "-show", "downloads", "-downloads", "charts", "-center", "41.7,-71.5", "-zoom", "9"])
        let rows = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'state-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "no chart list arrived")
        // Rows are built as they scroll into view, and Rhode Island is far down the list.
        let list = app.descendants(matching: .any)["downloads-charts-page"]
        let download = app.buttons["download-RI"]
        for _ in 0..<12 where !download.exists { list.swipeUp() }
        XCTAssertTrue(download.exists, "Rhode Island is not in the list")
        download.tap()
        let state = app.staticTexts["state-RI"]
        wait(for: [expectation(for: NSPredicate(format: "label == 'Ready'"), evaluatedWith: state)], timeout: 85)
        try Screen.chartShot("live-bucket-download", floor: floor)
        XCTAssertFalse(app.staticTexts["no-chart-label"].exists)
        XCTAssertFalse(app.staticTexts["no-coverage-label"].exists)
        XCTAssertFalse(app.staticTexts["no-detail-label"].exists)
        // The region chosen here must not start transfers in whatever runs next.
        app.terminate()
        Screen.launch(["-seedPacks", "empty", "-offline", "1"]).terminate()
    }

    @MainActor func testNavigationDataDownloadsFromTheBuiltInAddress() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_BUCKET"] == "1", "set LIVE_BUCKET=1 to run")
        continueAfterFailure = false
        executionTimeAllowance = 120
        // No address is passed, so the list and both files come from the built-in one.
        let app = Screen.launch(["-seedNav", "empty", "-show", "downloads", "-downloads", "nav", "-center", "30.1945,-97.6699", "-zoom", "9"])
        let state = app.staticTexts["nav-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        wait(for: [expectation(for: NSPredicate(format: "label == 'Ready'"), evaluatedWith: state)], timeout: 100)
        try Screen.save("live-nav-download")
    }
}
