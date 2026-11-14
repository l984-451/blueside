import Network
import XCTest

/// What only a real iPhone shows: running in the background with a receiver, the route's Live Activity, Markup under a
/// finger, a download finished while the app was gone. Pictures go into the result bundle. Every test skips on a simulator.
/// An app launched by XCTest is never suspended, so suspension is judged only with the app launched by devicectl.
/// The tests reset the app's data, so they run only in the separate test app, never in a pilot's Blueside.
final class DeviceUITests: XCTestCase {
    static let kaus = (30.1945, -97.6699)
    static let cwk = (30.37855, -97.52985)
    @MainActor var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("runs on a device only")
        #else
        // This bundle's id is APP_BUNDLE_ID plus ".uitests", the same build setting that names the app under test.
        let id = Bundle(for: Self.self).bundleIdentifier ?? ""
        try XCTSkipUnless(id.contains(".devtest."), "resets the app's data: build with an APP_BUNDLE_ID ending in .devtest (this is \(id))")
        continueAfterFailure = true
        #endif
    }

    /// On an iPad the first key command after a launch was lost, so a plain key goes first.
    @MainActor private func connectKeyboard(_ app: XCUIApplication) {
        app.typeKey("x", modifierFlags: [])
        sleep(1)
    }

    // MARK: Steps

    /// Launches, then answers the first-launch questions this test app gets: location while in use, Local Network as given.
    @MainActor private func launch(_ arguments: [String], reset: Bool = true, localNetwork: String = "Allow") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-probes", "1"] + (reset ? ["-reset", "1"] : [])
        app.launch()
        answerAlerts(localNetwork: localNetwork)
        return app
    }

    @MainActor private func answerAlerts(localNetwork: String) {
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 6) else { return }
            print("device: alert '\(alert.label)'")
            shot("alert")
            // Asked by label: on an iPad, listing the alert's buttons by index fails.
            if let allow = ["Allow While Using App", "Allow While Using the App", localNetwork]
                .map({ alert.buttons[$0] }).first(where: \.exists) {
                allow.tap()
            } else {
                return
            }
            sleep(1)
        }
    }

    /// Saves the whole screen, home screen and Dynamic Island included, into the result bundle.
    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func state(_ app: XCUIApplication) -> String {
        switch app.state {
        case .runningForeground: "foreground"
        case .runningBackground: "background"
        case .runningBackgroundSuspended: "suspended"
        case .notRunning: "not running"
        default: "unknown"
        }
    }

    /// Waits on the home screen, pressing Home now and then so the phone does not lock, and logs the app's state.
    @MainActor private func away(_ seconds: Int, _ app: XCUIApplication, note: String, ask: Bool = true) {
        var left = seconds
        while left > 0 {
            let step = min(left, 15)
            sleep(UInt32(step))
            left -= step
            XCUIDevice.shared.press(.home)
            print("device: \(note) +\(seconds - left)s app \(ask ? state(app) : "not asked")")
        }
    }

    @MainActor private func label(_ app: XCUIApplication, _ id: String) -> String {
        app.descendants(matching: .any)[id].firstMatch.label
    }

    /// Long-presses the Dynamic Island to show the expanded view.
    @MainActor private func expandIsland() {
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: springboard.frame.width / 2, dy: 28)).press(forDuration: 1.2)
        sleep(1)
    }

    // MARK: 1. Launch

    @MainActor func testLaunchDrawsAndSitsIdle() throws {
        let app = launch(NavUITests.austin)
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        sleep(3)
        shot("1-launch-map")
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app)], options: options) { sleep(60) }
        shot("1-after-idle")
    }

    /// Tells running from suspended by the receiver probe alone, with the app launched by the test or, with
    /// TEST_RUNNER_OUTSIDE=1, by `devicectl device process launch` when the log says "launch now".
    /// First a receiver holds the app at Home for 90 s; then, silent, it should be let go a minute later. Datagrams
    /// sent 120 s later reach a running app at once, a suspended one only when it comes back 40 s after that.
    @MainActor func testRunningOrSuspendedByTheProbe() throws {
        let port: UInt16 = 4560
        let outside = ProcessInfo.processInfo.environment["OUTSIDE"] == "1"
        let app: XCUIApplication
        if outside {
            print("device: launch now")
            sleep(30)
            app = XCUIApplication()
        } else {
            app = launch(NavUITests.austin + ["-gdl90Port", "\(port)"])
        }
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        var feed = GDL90Feed(port: port, from: Self.kaus, track: 0, knots: nil)
        feed.start()
        sleep(10)
        XCUIDevice.shared.press(.home)
        away(90, app, note: "held", ask: !outside)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        print("device: held \(label(app, "map-receiver"))")
        XCUIDevice.shared.press(.home)
        feed.stop()
        away(120, app, note: "silent", ask: !outside)
        feed = GDL90Feed(port: port, from: Self.kaus, track: 0, knots: nil)
        feed.start()
        defer { feed.stop() }
        away(40, app, note: "fed again", ask: !outside)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        print("device: released \(label(app, "map-receiver"))")
    }

    // MARK: 2 and 3. Background running and the Live Activity

    /// A route, a receiver with ownship at 120 kt toward CWK and one target. In the front the activity starts; at Home
    /// the island and the location indicator show; after 100 s away the app must have heard every second; with the feed
    /// stopped, both end five minutes after the last fast fix.
    @MainActor func testBackgroundRunningAndTheLiveActivity() throws {
        let port: UInt16 = 4555
        let feed = GDL90Feed(port: port, from: GDL90Feed.offset(Self.kaus, bearing: GDL90Feed.bearing(Self.kaus, Self.cwk), nm: 1),
                             track: GDL90Feed.bearing(Self.kaus, Self.cwk), knots: 120)
        let app = launch(NavUITests.austin + ["-navRoute", "KAUS CWK SAT", "-gdl90Port", "\(port)"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        feed.start()
        defer { feed.stop() }
        let traffic = app.staticTexts["map-traffic"]
        XCTAssertTrue(Screen.wait(15) { traffic.label.hasPrefix("traffic 1") }, traffic.label)
        sleep(8)
        print("device: front \(label(app, "map-receiver")) direct \(label(app, "map-direct-ident")) \(label(app, "map-direct-distance"))")
        shot("2-front-route-and-receiver")

        XCUIDevice.shared.press(.home)
        sleep(3)
        print("device: home app \(state(app))")
        shot("3-island-compact-a")
        expandIsland()
        shot("3-island-expanded-a")
        XCUIDevice.shared.press(.home)
        away(30, app, note: "feeding")
        shot("3-island-compact-b")
        expandIsland()
        shot("3-island-expanded-b")
        XCUIDevice.shared.press(.home)
        away(60, app, note: "feeding")
        shot("2-home-feeding-100s")

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        let received = label(app, "map-receiver")
        print("device: back \(received) badge \(app.descendants(matching: .any)["receiver-badge"].firstMatch.label)")
        shot("2-back-in-front")
        let gap = Int(received.split(separator: " ").last ?? "") ?? -1
        XCTAssertTrue((0...3).contains(gap), "the app stopped hearing the receiver for \(gap) s: \(received)")

        XCUIDevice.shared.press(.home)
        sleep(2)
        feed.stop()
        print("device: feed stopped")
        for (mark, wait) in [(30, 30), (75, 45), (180, 105), (270, 90), (320, 50), (380, 60)] {
            away(wait, app, note: "stopped")
            shot("2-stopped-\(mark)s")
        }
        app.activate()
        sleep(2)
        print("device: end \(label(app, "map-receiver"))")
        shot("2-end-in-front")
    }

    /// The activity with the app launched by `devicectl device process launch` (after "launch now"), so the system
    /// suspends it as it would any app: pictures in flight, then after the feed stops, around the five-minute end.
    @MainActor func testTheLiveActivityOutsideTheTest() throws {
        let feed = GDL90Feed(port: 4561, from: GDL90Feed.offset(Self.kaus, bearing: GDL90Feed.bearing(Self.kaus, Self.cwk), nm: 1),
                             track: GDL90Feed.bearing(Self.kaus, Self.cwk), knots: 120)
        feed.start()
        defer { feed.stop() }
        print("device: launch now")
        sleep(30)
        let app = XCUIApplication()
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        sleep(5)
        print("device: front \(label(app, "map-receiver")) direct \(label(app, "map-direct-ident")) \(label(app, "map-direct-distance"))")
        shot("3o-front")
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("3o-compact-a")
        expandIsland()
        shot("3o-expanded-a")
        XCUIDevice.shared.press(.home)
        away(30, app, note: "feeding", ask: false)
        shot("3o-compact-b")
        expandIsland()
        shot("3o-expanded-b")
        XCUIDevice.shared.press(.home)
        feed.stop()
        print("device: feed stopped")
        for (mark, wait) in [(60, 60), (240, 180), (285, 45), (315, 30), (345, 30), (400, 55)] {
            away(wait, app, note: "stopped", ask: false)
            shot("3o-stopped-\(mark)s")
        }
    }

    /// The aircraft symbol under the redraw rule: followed at 120 kt the camera keeps up, and turning in place it turns.
    @MainActor func testOwnshipFollowsAndTurns() throws {
        let moving = GDL90Feed(port: 4562, from: Self.kaus, track: 33, knots: 120)
        let app = launch(NavUITests.austin + ["-gdl90Port", "4562", "-follow", "1", "-zoom", "12"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        moving.start()
        sleep(6)
        let camera = app.descendants(matching: .any)["map-camera"].firstMatch
        let first = camera.label
        shot("o-follow-a")
        sleep(10)
        print("device: following, camera '\(first)' then '\(camera.label)', tracking '\(app.buttons["tracking-button"].value as? String ?? "")'")
        shot("o-follow-b")
        moving.stop()
        let turning = GDL90Feed(port: 4562, from: Self.kaus, track: 0, knots: 0, turn: 18)
        turning.start()
        defer { turning.stop() }
        sleep(4)
        shot("o-turn-a")
        sleep(5)
        shot("o-turn-b")
    }

    /// Only a receiver, no fast fix: the app keeps running a minute after the receiver was last heard, then stops.
    @MainActor func testReceiverAloneHoldsAMinute() throws {
        let port: UInt16 = 4556
        let feed = GDL90Feed(port: port, from: Self.kaus, track: 0, knots: nil)
        let app = launch(NavUITests.austin + ["-gdl90Port", "\(port)"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        feed.start()
        defer { feed.stop() }
        let traffic = app.staticTexts["map-traffic"]
        XCTAssertTrue(Screen.wait(15) { traffic.label.hasPrefix("traffic 1") }, traffic.label)
        XCUIDevice.shared.press(.home)
        away(30, app, note: "feeding")
        shot("2r-home-feeding-30s")
        feed.stop()
        for (mark, wait) in [(30, 30), (50, 20), (75, 25), (100, 25)] {
            away(wait, app, note: "stopped")
            shot("2r-stopped-\(mark)s")
        }
        app.activate()
        sleep(2)
        print("device: end \(label(app, "map-receiver"))")
    }

    /// Clearing the route ends the activity at once.
    @MainActor func testClearingTheRouteEndsTheActivity() throws {
        let port: UInt16 = 4557
        let feed = GDL90Feed(port: port, from: GDL90Feed.offset(Self.kaus, bearing: GDL90Feed.bearing(Self.kaus, Self.cwk), nm: 1),
                             track: GDL90Feed.bearing(Self.kaus, Self.cwk), knots: 120)
        let app = launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT", "-gdl90Port", "\(port)"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        feed.start()
        defer { feed.stop() }
        let traffic = app.staticTexts["map-traffic"]
        XCTAssertTrue(Screen.wait(15) { traffic.label.hasPrefix("traffic 1") }, traffic.label)
        sleep(8)
        print("device: front \(label(app, "map-activity"))")
        shot("3c-front")
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("3c-island-before-clear")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        print("device: back \(label(app, "map-activity")), clearing at \(Date())")
        let menu = app.buttons["route-menu"]
        if !menu.waitForExistence(timeout: 3) { app.buttons["route-button"].tap() }
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Clear Route"].tap()
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForNonExistence(timeout: 5))
        sleep(1)
        print("device: route cleared at \(Date()): \(label(app, "map-activity"))")
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("3c-island-after-clear")
        sleep(20)
    }

    // MARK: 4. Markup

    /// Opens Austin's ILS 18R from the bundled plates pack, from a fresh start or with what the last run left.
    @MainActor private func openPlate(reset: Bool) -> XCUIApplication {
        let app = launch(NavUITests.austin + ["-show", "nav", "-navQuery", "AUS", "-navNow", "2026-10-13T12:00:00Z"], reset: reset)
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        app.buttons["airport-procedures"].tap()
        app.buttons["plate-00556IL18R.PDF"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plate-view"].waitForExistence(timeout: 10))
        sleep(1)
        return app
    }

    @MainActor func testMarkup() throws {
        var app = openPlate(reset: true)
        let page = app.descendants(matching: .any)["plate-view"]
        let palette = app.otherElements["Drawing-Palette"]
        print("device: before markup palette exists \(palette.exists)")
        shot("4-plate")
        let markup = app.buttons["plate-markup"]
        markup.tap()
        sleep(2)
        print("device: markup selected \(markup.isSelected) zoom \(page.value as? String ?? "nil") page \(page.frame) palette \(palette.exists ? "\(palette.frame)" : "none")")
        shot("4-markup-on")
        // One finger across the page: a stroke if it draws, a moved page if it pans.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35)))
        sleep(1)
        print("device: after one-finger drag zoom \(page.value as? String ?? "nil")")
        shot("4-one-finger-drag")
        // A drag that starts beside the page scrolls it toward its foot without drawing.
        let side = page.frame.height > page.frame.width * 1.4
            ? (CGVector(dx: 0.5, dy: 0.03), CGVector(dx: 0.5, dy: -0.14)) : (CGVector(dx: 0.01, dy: 0.6), CGVector(dx: 0.01, dy: 0.05))
        page.coordinate(withNormalizedOffset: side.0).press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: side.1))
        sleep(1)
        shot("4-whole-page-foot-markup-on")
        page.pinch(withScale: 3, velocity: 1)
        sleep(2)
        print("device: after pinch zoom \(page.value as? String ?? "nil")")
        shot("4-pinched")
        page.swipeUp()
        sleep(1)
        print("device: after one-finger swipe up zoom \(page.value as? String ?? "nil")")
        shot("4-swipe-up-with-markup")
        markup.tap()
        sleep(1)
        for _ in 0..<6 { page.swipeUp(velocity: .fast) }
        sleep(1)
        shot("4-foot-markup-off")
        markup.tap()
        sleep(2)
        shot("4-foot-markup-on")
        page.pinch(withScale: 0.2, velocity: -1)
        sleep(2)
        markup.tap()
        // The mark, if a finger made one, is still there after the app is killed and launched again.
        app.terminate()
        app = openPlate(reset: false)
        shot("4-after-relaunch")
    }

    // MARK: Keyboard

    /// Whether the first key command after launch is lost: soon after the map loads, much later, or after a plain key.
    @MainActor func testFirstKeyAfterLaunch() throws {
        for (name, wait, warmUp) in [("2 s", UInt32(2), false), ("10 s", 10, false), ("2 s and a plain key", 2, true)] {
            let app = launch(NavUITests.austin)
            XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
            sleep(wait)
            if warmUp {
                app.typeKey("x", modifierFlags: [])
                sleep(1)
            }
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            print("device: first Command-L after \(name): layers '\(app.buttons["layers-button"].value as? String ?? "")'")
            app.terminate()
        }
    }

    /// Command-F, L, R, Shift-Command-N, Command-0 and Command-period on the map; none act under a plate, the brief or
    /// Settings. XCUITest's Escape key never reached the app in a simulator, so Command-period, which fires a shortcut
    /// bound to Escape alone, stands in.
    @MainActor func testKeyboardCommands() throws {
        var app = launch(NavUITests.austin + ["-navRoute", "KAUS CWK SAT"])
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        sleep(2)
        connectKeyboard(app)
        func value(_ id: String) -> String {
            let button = app.buttons[id].firstMatch
            return button.exists ? button.value as? String ?? "" : "hidden"
        }
        func state() -> String {
            "search '\(value("search-button"))' layers '\(value("layers-button"))' route '\(value("route-button"))' "
                + "night '\(value("night-button"))' tracking '\(value("tracking-button"))'"
        }
        func key(_ name: String, _ key: String, _ flags: XCUIElement.KeyModifierFlags = .command) {
            app.typeKey(key, modifierFlags: flags)
            sleep(1)
            print("device: map after \(name): \(state())")
        }
        print("device: map at start: \(state())")
        for (name, letter) in [("Command-F", "f"), ("Command-L", "l"), ("Command-R", "r")] {
            key(name, letter)
            shot("k-\(name)")
            key("Command-period", ".")
            // The search field takes the first cancel and ends its editing.
            if app.buttons["search-button"].value as? String == "Open" { key("Command-period again", ".") }
            shot("k-\(name)-closed")
        }
        key("Shift-Command-N", "n", [.command, .shift])
        shot("k-night")
        key("Shift-Command-N again", "n", [.command, .shift])
        key("Command-0", "0")

        // Settings closes the panel as it opens; the key then belongs to Settings.
        key("Command-L", "l")
        app.buttons["settings-button"].tap()
        sleep(1)
        let settingsUp = { app.descendants(matching: .any)["settings-Devices"].exists }
        print("device: settings up \(settingsUp()): \(state())")
        key("Command-period under Settings", ".")
        print("device: settings up \(settingsUp())")
        shot("k-settings-after-cancel")

        // Under a full-screen plate, over the open airport page.
        app.terminate()
        app = openPlate(reset: true)
        connectKeyboard(app)
        print("device: plate open: \(state())")
        for (name, letter, flags) in [("Command-F", "f", XCUIElement.KeyModifierFlags.command), ("Command-L", "l", .command),
                                      ("Command-R", "r", .command), ("Shift-Command-N", "n", [.command, .shift]),
                                      ("Command-0", "0", .command), ("Command-period", ".", .command)] {
            app.typeKey(letter, modifierFlags: flags)
            sleep(1)
            print("device: plate after \(name): plate \(app.buttons["plate-close"].exists ? "open" : "closed") \(state())")
        }
        shot("k-plate-after-keys")
        if app.buttons["plate-close"].exists { app.buttons["plate-close"].tap() }
        sleep(1)
        print("device: plate closed: \(state())")

        // Under the brief.
        app.terminate()
        app = launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT"])
        let brief = app.buttons["route-brief"]
        for _ in 0..<6 where !(brief.exists && brief.isHittable) { app.collectionViews["route-list"].firstMatch.swipeUp() }
        brief.tap()
        XCTAssertTrue(app.buttons["brief-done"].waitForExistence(timeout: 30))
        connectKeyboard(app)
        print("device: brief open: \(state())")
        for (name, letter, flags) in [("Command-F", "f", XCUIElement.KeyModifierFlags.command), ("Command-L", "l", .command),
                                      ("Command-R", "r", .command), ("Shift-Command-N", "n", [.command, .shift]),
                                      ("Command-0", "0", .command), ("Command-period", ".", .command)] {
            app.typeKey(letter, modifierFlags: flags)
            sleep(1)
            print("device: brief after \(name): brief \(app.buttons["brief-done"].exists ? "open" : "closed") \(state())")
        }
        shot("k-brief-after-keys")
    }

    // MARK: 5. A download finished while the app was gone

    /// Starts a state's charts, kills the app at once, waits, and launches again. TEST_RUNNER_REGION picks the state.
    @MainActor func testADownloadFinishesWithTheAppGone() throws {
        let region = ProcessInfo.processInfo.environment["REGION"] ?? "RI"
        let arguments = ["-show", "downloads", "-downloads", "charts", "-center", "41.7,-71.5", "-zoom", "9"]
        let app = launch(["-seedPacks", "empty"] + arguments)
        let list = app.descendants(matching: .any)["downloads-charts-page"]
        let download = app.buttons["download-\(region)"]
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'state-'")).firstMatch.waitForExistence(timeout: 30))
        for _ in 0..<12 where !download.exists { list.swipeUp() }
        download.tap()
        print("device: after tap state-\(region) \(app.staticTexts["state-\(region)"].label)")
        app.terminate()
        print("device: terminated")
        sleep(90)
        let again = launch(arguments, reset: false)
        let row = again.staticTexts["state-\(region)"]
        let rows = again.descendants(matching: .any)["downloads-charts-page"]
        _ = again.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'state-'")).firstMatch.waitForExistence(timeout: 30)
        for _ in 0..<12 where !row.exists { rows.swipeUp() }
        print("device: relaunched state-\(region) \(row.label)")
        shot("5-relaunched")
        sleep(10)
        print("device: relaunched +10s state-\(region) \(row.label)")
        shot("5-relaunched-10s")
        again.terminate()
    }

    // MARK: 6. Local Network denied

    @MainActor func testLocalNetworkDenied() throws {
        let app = launch(NavUITests.austin + ["-gdl90Port", "4558"], localNetwork: "Don’t Allow")
        XCTAssertTrue(app.otherElements["mapLoaded"].waitForExistence(timeout: 30))
        app.buttons["settings-button"].tap()
        let devices = app.descendants(matching: .any)["settings-Devices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 5))
        devices.tap()
        sleep(2)
        print("device: status \(label(app, "receiver-status"))")
        shot("6-devices")
    }
}

/// Sends GDL 90 to the app on this phone once a second, as a receiver on the Wi-Fi would: heartbeat with GPS, ownship
/// flying a straight track (none when `knots` is nil), or turning in place by `turn` degrees a second, and one target
/// 2 NM off its right side.
final class GDL90Feed: @unchecked Sendable {
    private let connection: NWConnection
    private let from: (Double, Double)
    private let heading: Double
    private let knots: Double?
    private let turn: Double
    private var timer: DispatchSourceTimer?
    private var began = Date()

    init(port: UInt16, from: (Double, Double), track: Double, knots: Double?, turn: Double = 0) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        (self.from, self.heading, self.knots, self.turn) = (from, track, knots, turn)
    }

    func start() {
        began = Date()
        connection.start(queue: .global())
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [self] in connection.send(content: datagram(), completion: .idempotent) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connection.cancel()
    }

    private func datagram() -> Data {
        let now = Date()
        let track = (heading + turn * now.timeIntervalSince(began)).truncatingRemainder(dividingBy: 360)
        let own = Self.offset(from, bearing: track, nm: (knots ?? 0) * now.timeIntervalSince(began) / 3600)
        let target = Self.offset(own, bearing: track + 90, nm: 2)
        var messages = [Self.heartbeat(now)]
        if let knots {
            messages.append(Self.report(0x0A, address: 0xC0FFEE, own, feet: 3500, track: track, knots: Int(knots), callsign: "N1BS"))
        }
        messages.append(Self.report(0x14, address: 0xA1B2C3, target, feet: 4000, track: track, knots: 110, callsign: "N123AB"))
        return Data(messages.flatMap(Self.frame))
    }

    static func bearing(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let east = (b.1 - a.1) * cos(a.0 * .pi / 180)
        return (atan2(east, b.0 - a.0) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func offset(_ origin: (Double, Double), bearing: Double, nm: Double) -> (Double, Double) {
        let radians = bearing * .pi / 180
        return (origin.0 + nm / 60 * cos(radians), origin.1 + nm / 60 * sin(radians) / cos(origin.0 * .pi / 180))
    }

    static func heartbeat(_ now: Date) -> [UInt8] {
        let seconds = Int(now.timeIntervalSince1970) % 86_400
        return [0x00, 0x81, UInt8(0x01 | ((seconds >> 16) << 7)), UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF), 0, 0]
    }

    static func report(_ id: UInt8, address: Int, _ at: (Double, Double), feet: Int, track: Double, knots: Int,
                       callsign: String) -> [UInt8] {
        func semicircles(_ degrees: Double) -> [UInt8] {
            let value = Int((degrees * Double(1 << 23) / 180).rounded()) & 0xFFFFFF
            return [UInt8(value >> 16), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        let altitude = (feet + 1000) / 25
        let heading = UInt8(Int(track * 256 / 360) & 0xFF)
        let name = Array((callsign + String(repeating: " ", count: 8)).utf8.prefix(8))
        return [id, 0x00, UInt8(address >> 16), UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
            + semicircles(at.0) + semicircles(at.1)
            + [UInt8(altitude >> 4), UInt8(((altitude & 0xF) << 4) | 0x09), 0x89, UInt8(knots >> 4), UInt8((knots & 0xF) << 4), 0,
               heading, 1] + name + [0]
    }

    static func frame(_ message: [UInt8]) -> [UInt8] {
        var crc: UInt16 = 0
        for byte in message {
            var c = UInt16(crc >> 8) << 8
            for _ in 0..<8 { c = (c << 1) ^ (c & 0x8000 != 0 ? 0x1021 : 0) }
            crc = c ^ (crc << 8) ^ UInt16(byte)
        }
        var out: [UInt8] = [0x7E]
        for byte in message + [UInt8(crc & 0xFF), UInt8(crc >> 8)] {
            out += byte == 0x7D || byte == 0x7E ? [0x7D, byte ^ 0x20] : [byte]
        }
        return out + [0x7E]
    }
}
