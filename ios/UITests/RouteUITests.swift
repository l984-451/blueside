import XCTest

/// The route on the map and in the drawer, on the bundled Austin test files with no network.
final class RouteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) {
        wait(for: [expectation(for: NSPredicate(format: format), evaluatedWith: element)], timeout: timeout)
    }

    /// Swipes the route list up until the element is on screen; the waypoints sit under the plan inputs.
    @MainActor private func scroll(to element: XCUIElement, _ app: XCUIApplication, tries: Int = 8) {
        for _ in 0..<tries where !(element.exists && element.isHittable) {
            app.collectionViews["route-list"].swipeUp(velocity: .slow)
        }
    }

    /// Scrolls the planning page until the element is on screen, swiping on whichever of its parts is.
    @MainActor private func scrollPage(to element: XCUIElement, _ app: XCUIApplication, up: Bool = true) {
        let parts = ["route-list", "route-inputs", "route-log", "route-details"].map { app.descendants(matching: .any)[$0].firstMatch }
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            guard let part = parts.first(where: { $0.exists && $0.isHittable }) else { return }
            if up { part.swipeUp(velocity: .slow) } else { part.swipeDown(velocity: .slow) }
        }
    }

    @MainActor func testAddToRouteFromTheAirportPageAndASearchRow() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "nav", "-navQuery", "AUS"])
        let row = app.buttons["nav-result-AUS"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let add = app.buttons["add-to-route-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertEqual(add.label, "Add to Route")
        try Screen.save("route-airport-page")
        // With no route, the first one added is flown from the aircraft.
        add.tap()
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["map-direct-ident"].label, "KAUS")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.buttons.firstMatch.tap()
        field.tap()
        field.typeText("EDC")
        let edc = app.buttons["nav-result-EDC"]
        XCTAssertTrue(edc.waitForExistence(timeout: 10))
        edc.swipeRight()
        app.buttons["Add to Route"].tap()
        let second = app.staticTexts["leg-ident-1"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertEqual(second.label, "KEDC")
        XCTAssertEqual(app.staticTexts["map-direct-ident"].label, "KAUS")
        waitUntil(app.staticTexts["map-nav"], "label CONTAINS 'direct on'")
        try Screen.save("route-added")
    }

    @MainActor func testTheDrawerListsTheLegsAndATapEditsTheRouteInThePanel() throws {
        let app = Screen.launch(NavUITests.austin + ["-navRoute", "KAUS CWK SAT"])
        let active = app.staticTexts["map-direct-ident"]
        XCTAssertTrue(active.waitForExistence(timeout: 20))
        XCTAssertEqual(active.label, "CWK")
        XCTAssertEqual(app.staticTexts["leg-ident-1"].label, "SAT")
        XCTAssertTrue(app.staticTexts["leg-course-1"].label.hasSuffix("°M"), app.staticTexts["leg-course-1"].label)
        XCTAssertTrue(app.staticTexts["map-direct-distance"].label.hasSuffix(" NM"))
        XCTAssertEqual(app.descendants(matching: .any)["direct-row"].value as? String, "Active leg")
        // The line starts at Austin, the route's first point.
        waitUntil(app.staticTexts["map-nav"], "label ENDSWITH 'direct on 30.195,-97.670'")
        try Screen.save("route-drawer")
        // The drawer only shows the legs; a tap opens the editor in the panel, and the drawer stays.
        app.descendants(matching: .any)["direct-row"].tap()
        XCTAssertTrue(app.textFields["route-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(active.exists)
        sleep(1)
        try Screen.save("route-drawer-editor")
        // Removing the active leg's waypoint flies on to the next.
        scroll(to: app.descendants(matching: .any)["route-point-1"], app)
        app.descendants(matching: .any)["route-point-1"].swipeLeft()
        app.buttons["Remove"].tap()
        waitUntil(active, "label == 'SAT'")
        XCTAssertFalse(app.staticTexts["leg-ident-1"].exists)
        // Direct To from the row makes a one-leg route from the aircraft.
        app.descendants(matching: .any)["route-point-1"].swipeLeft()
        app.buttons["Direct To"].tap()
        waitUntil(app.buttons["direct-drawer-tab"], "label == 'Hide Direct To'")
        XCTAssertEqual(active.label, "SAT")
        app.descendants(matching: .any)["route-point-0"].swipeLeft()
        app.buttons["Remove"].tap()
        waitUntil(app.staticTexts["map-nav"], "label ENDSWITH 'direct off'")
        XCTAssertFalse(active.exists)
    }

    // The Route button in the control column opens the editor in the panel; with no route the strip has no tab.
    @MainActor func testTheRouteButtonOpensTheEditorInThePanel() throws {
        let app = Screen.launch(NavUITests.austin)
        let button = app.buttons["route-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        XCTAssertEqual(button.label, "Route")
        XCTAssertFalse(app.buttons["direct-drawer-tab"].exists)
        button.tap()
        XCTAssertTrue(app.textFields["route-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["data-strip"].exists)
        if Screen.device == "ipad" {
            XCTAssertLessThan(app.collectionViews["route-list"].frame.midX, app.descendants(matching: .any)["data-strip"].frame.midX)
        }
    }

    @MainActor func testTheRoutePanelTakesTextSuggestsAndShowsProblemsAndTotals() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "route"])
        let field = app.textFields["route-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("KAUS KXYZ")
        let problem = app.staticTexts.matching(identifier: "route-problem-0").firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        XCTAssertTrue(problem.label.contains("KXYZ is not an airport, navaid or fix"), problem.label)
        // Wiping the bad word and picking a suggestion makes the route.
        for _ in 0..<4 { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        field.typeText("CW")
        let suggestion = app.buttons["route-suggestion-CWK"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        suggestion.tap()
        field.typeText("SAT")
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["map-direct-ident"].label, "CWK")
        XCTAssertEqual(app.staticTexts["leg-ident-1"].label, "SAT")
        field.typeText("\n")
        // The answer leads the panel, above the route text.
        let distance = app.descendants(matching: .any)["route-total-distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        XCTAssertTrue(distance.label.contains("NM"), distance.label)
        XCTAssertLessThan(distance.frame.midY, field.frame.midY)
        sleep(1)
        try Screen.save("route-panel")
        // Without an aircraft the results say why there are no times, where those lines would be.
        let hint = app.descendants(matching: .any)["route-speed-hint"]
        XCTAssertTrue(hint.exists)
        XCTAssertLessThan(hint.frame.midY, field.frame.midY)
        // Swipe to remove a waypoint from the panel.
        let point = app.descendants(matching: .any)["route-point-1"]
        scroll(to: point, app)
        point.swipeLeft()
        app.buttons["Remove"].tap()
        waitUntil(app.staticTexts["map-direct-ident"], "label == 'SAT'")
        // Flights, Save Flight and Clear Route sit in one menu in the bar; an empty field clears the route too.
        XCTAssertTrue(app.buttons["route-menu"].exists)
        for _ in 0..<6 where !(field.exists && field.isHittable) { app.collectionViews["route-list"].swipeDown(velocity: .fast) }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        XCTAssertTrue(app.staticTexts["map-direct-ident"].waitForNonExistence(timeout: 5))
    }

    @MainActor func testExpandKeepsTheRouteAndMapTapsDoNotClose() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT"])
        let expand = app.buttons["route-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        // The page lays the nav log out as a table under the inputs, its columns named.
        let log = app.descendants(matching: .any)["route-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        let course = app.descendants(matching: .any)["Course"].firstMatch
        XCTAssertTrue(course.exists)
        let list = app.collectionViews["route-list"], inputs = app.collectionViews["route-inputs"]
        XCTAssertLessThan(list.frame.midY, log.frame.midY)
        // One page, each part as tall as its content, so no group is cut off at an edge.
        XCTAssertGreaterThanOrEqual(list.frame.maxY, app.buttons["route-share-navlog"].frame.maxY)
        let alternate = app.textFields["plan-alternate"]
        XCTAssertGreaterThanOrEqual(inputs.frame.maxY, alternate.frame.maxY)
        // The log is as tall as its rows: the totals row ends it, whole, with no empty band under it.
        let total = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Total'")).firstMatch
        XCTAssertTrue(total.exists)
        XCTAssertGreaterThanOrEqual(log.frame.maxY, total.frame.maxY)
        XCTAssertLessThan(log.frame.maxY - total.frame.maxY, 80)
        sleep(1)
        try Screen.save("route-page")
        // The page keeps the field being typed in clear of the keyboard.
        alternate.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThan(alternate.frame.maxY, keyboard.frame.minY)
        alternate.typeText("\n")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        // On its side, at the top of the page, the results and every plan input sit beside each other.
        let distance = app.descendants(matching: .any)["route-total-distance"].firstMatch
        scrollPage(to: distance, app, up: false)
        for id in ["route-total-distance", "plan-departure", "plan-alternate"] {
            let element = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(element.exists && element.isHittable, id)
        }
        try Screen.save("route-page-landscape")
        // Where it does not all fit, the page scrolls on to the foot of the log.
        scrollPage(to: total, app)
        XCTAssertTrue(total.isHittable)
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        // Open map at the trailing edge, beside the page.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(log.waitForExistence(timeout: 2))
        // A long press on a point in the log gives the row actions.
        let point = app.descendants(matching: .any)["route-point-1"]
        scrollPage(to: point, app)
        point.press(forDuration: 1)
        let show = app.buttons["Show on Map"]
        XCTAssertTrue(show.waitForExistence(timeout: 3))
        show.tap()
        app.buttons["route-expand"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: log)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    // Turned between landscape and upright ten times, the planning page settles after each turn: nothing keeps moving.
    @MainActor func testThePlanningPageSettlesThroughTenTurns() throws {
        guard Screen.device == "ipad" else { throw XCTSkip("the planning page opens on iPad") }
        executionTimeAllowance = 120
        let app = Screen.launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT"])
        let expand = app.buttons["route-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 20))
        expand.tap()
        let log = app.descendants(matching: .any)["route-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        for turn in 1...10 {
            let started = Date()
            // Setting the orientation waits for the app to settle, for up to a minute when it never does.
            XCUIDevice.shared.orientation = turn.isMultiple(of: 2) ? .portrait : .landscapeLeft
            XCTAssertLessThan(Date().timeIntervalSince(started), 10, "turn \(turn) did not settle")
            XCTAssertTrue(log.exists, "turn \(turn)")
        }
    }

    @MainActor func testTheRoutePanelAtNight() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "route", "-night", "1", "-navRoute", "KAUS CWK SAT"])
        XCTAssertTrue(app.descendants(matching: .any)["route-point-2"].waitForExistence(timeout: 20))
        sleep(1)
        try Screen.save("route-panel-night")
    }

    @MainActor func testTheBriefOpensWithItsGraphics() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT"])
        XCTAssertTrue(app.collectionViews["route-list"].waitForExistence(timeout: 20))
        let brief = app.buttons["route-brief"]
        scroll(to: brief, app)
        brief.tap()
        XCTAssertTrue(app.descendants(matching: .any)["brief-hazards"].waitForExistence(timeout: 20))
        let map = app.descendants(matching: .any)["brief-map"]
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        // The share button waits for the map pictures, so it shows they were drawn.
        XCTAssertTrue(app.buttons["brief-share"].waitForExistence(timeout: 30))
        _ = try Screen.save("brief-graphics")
        let profile = app.descendants(matching: .any)["brief-profile"]
        for _ in 0..<4 where !profile.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(profile.exists)
        app.buttons["brief-done"].tap()
        // Opening it again shows the kept brief at once, share button and all.
        brief.tap()
        XCTAssertTrue(app.buttons["brief-share"].waitForExistence(timeout: 3))
    }

    @MainActor func testSavingARouteAndLoadingItFromTheList() throws {
        let app = Screen.launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT"])
        let menu = app.buttons["route-menu"]
        XCTAssertTrue(app.descendants(matching: .any)["route-total-distance"].waitForExistence(timeout: 20))
        menu.tap()
        XCTAssertTrue(app.buttons["Save Flight"].waitForExistence(timeout: 5))
        try Screen.save("route-menu")
        app.buttons["Save Flight"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(alert.textFields.firstMatch.value as? String, "KAUS to SAT")
        alert.buttons["Save"].tap()
        menu.tap()
        app.buttons["Flights"].tap()
        let row = app.buttons["saved-route-KAUS to SAT"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // The Flights page closes the panel like every other page.
        XCTAssertTrue(app.buttons["panel-close"].exists)
        sleep(1)
        try Screen.save("saved-routes")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["route-total-distance"].waitForExistence(timeout: 5))
    }

    /// Types a number into a form field, scrolling to it first and clearing what is there.
    @MainActor private func enter(_ value: String, _ id: String, _ app: XCUIApplication) {
        let field = app.textFields[id]
        for _ in 0..<8 where !(field.exists && field.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(field.waitForExistence(timeout: 5), id)
        // The first tap on the detail page can go to the split view, so tap until the field has focus.
        let focused = { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        for _ in 0..<3 where !focused() { field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap() }
        XCTAssertTrue(focused(), id)
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value + "\n")
    }

    @MainActor func testAircraftAddSitsLeftOfClose() throws {
        let app = Screen.launch(NavUITests.austin)
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let close = app.buttons["panel-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let closeFrame = close.frame
        app.descendants(matching: .any)["settings-Aircraft"].tap()
        let add = app.buttons["aircraft-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        sleep(1)
        try Screen.save("settings-aircraft")
        XCTAssertLessThan(add.frame.midX, app.buttons["panel-close"].frame.midX)
        XCTAssertEqual(app.buttons["panel-close"].frame.midX, closeFrame.midX, accuracy: 2, "the close button moved")
    }

    /// Opens Settings, Aircraft, and adds a blank one, or the template whose type is `choice` found by `search`.
    @MainActor private func addAircraft(_ choice: String, search: String? = nil, tail: String) -> XCUIApplication {
        let app = Screen.launch(NavUITests.austin)
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let page = app.descendants(matching: .any)["settings-Aircraft"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        page.tap()
        let add = app.buttons["aircraft-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        if choice == "Blank" {
            app.buttons[choice].firstMatch.tap()
        } else {
            app.buttons["Template"].firstMatch.tap()
            let query = app.searchFields.firstMatch
            XCTAssertTrue(query.waitForExistence(timeout: 10))
            query.tap()
            query.typeText(search ?? choice)
            let row = app.buttons["template-\(choice)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            if search != nil { try? Screen.save("aircraft-template-search") }
            row.tap()
        }
        let field = app.textFields["aircraft-tail"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(tail + "\n")
        return app
    }

    @MainActor func testATemplateAircraftGetsWeightAndBalance() throws {
        // About a minute of typing into a dozen fields.
        executionTimeAllowance = 120
        let app = addAircraft("C172S", tail: "N12345")
        for (id, value) in [("aircraft-emptyWeightLb", "1663"), ("aircraft-emptyArmIn", "39.3"),
                            ("aircraft-station-arm-0", "37")] {
            enter(value, id, app)
        }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        try Screen.save("aircraft-editor")
        let wb = app.buttons["aircraft-weight-balance"]
        for _ in 0..<12 where !(wb.exists && wb.isHittable) { app.swipeUp(velocity: .fast) }
        wb.tap()
        enter("340", "wb-station-0", app)
        enter("150", "wb-station-1", app)
        enter("20", "wb-fuel-burned", app)
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        let status = app.descendants(matching: .any)["wb-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        try Screen.save("aircraft-weight-balance")
        XCTAssertEqual(status.label, "Within limits")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["aircraft-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aircraft-row-N12345"].waitForExistence(timeout: 5))
    }

    @MainActor func testCirrusTemplateGetsWeightAndBalance() throws {
        try templateWeightAndBalance("SR20", search: "cirrus sr20", empty: "2150", arm: "139.5")
    }

    @MainActor func testMooneyTemplateGetsWeightAndBalance() throws {
        try templateWeightAndBalance("M20J", search: "mooney 201", empty: "1800", arm: "45.5")
    }

    /// A template loaded from a made-up airplane's record comes out within limits.
    @MainActor private func templateWeightAndBalance(_ type: String, search: String, empty: String, arm: String) throws {
        executionTimeAllowance = 120
        let shot = "aircraft-wb-\(type.lowercased())"
        let app = addAircraft(type, search: search, tail: "N\(type)")
        if type == "M20J" { enter("37", "aircraft-station-arm-0", app) }
        enter(empty, "aircraft-emptyWeightLb", app)
        enter(arm, "aircraft-emptyArmIn", app)
        let wb = app.buttons["aircraft-weight-balance"]
        for _ in 0..<12 where !(wb.exists && wb.isHittable) { app.swipeUp(velocity: .fast) }
        wb.tap()
        enter("340", "wb-station-0", app)
        enter("20", "wb-fuel-burned", app)
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        let status = app.descendants(matching: .any)["wb-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), type)
        // Read before the swipe, which can scroll the verdict's row out of the list.
        XCTAssertEqual(status.label, "Within limits", type)
        app.swipeUp()
        try Screen.save(shot)
    }

    /// Attaches a PDF from Files to a saved aircraft and opens it. Needs "Sample POH.pdf" in On My iPad.
    @MainActor func testAttachedPOHOpens() throws {
        executionTimeAllowance = 120
        let app = addAircraft("Blank", tail: "N12345")
        app.buttons["aircraft-save"].tap()
        let row = app.descendants(matching: .any)["aircraft-row-N12345"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let attach = app.buttons["aircraft-attach-poh"]
        for _ in 0..<8 where !(attach.exists && attach.isHittable) { app.swipeUp(velocity: .fast) }
        attach.tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sample POH'")).firstMatch
        let onDevice = app.descendants(matching: .any)["On My iPad"].firstMatch
        if !file.waitForExistence(timeout: 5), onDevice.waitForExistence(timeout: 5) { onDevice.tap() }
        // A fresh simulator has no sample PDF in Files; seed one there to run this test.
        guard file.waitForExistence(timeout: 10) else { throw XCTSkip("no Sample POH.pdf in On My iPad") }
        file.tap()
        let open = app.buttons["aircraft-poh"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plate-view"].waitForExistence(timeout: 10))
        sleep(1)
        try Screen.save("aircraft-poh")
        app.buttons["plate-find"].tap()
        sleep(1)
        try Screen.save("aircraft-poh-find")
    }

    @MainActor func testAircraftSpeedAndBurnGiveTheRouteTimeAndFuel() throws {
        executionTimeAllowance = 120
        let app = addAircraft("Blank", tail: "N12345")
        enter("120", "aircraft-cruiseTASKt", app)
        enter("9.5", "aircraft-burnGPH", app)
        app.buttons["aircraft-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aircraft-row-N12345"].waitForExistence(timeout: 5))
        app.buttons["panel-close"].firstMatch.tap()
        app.buttons["route-button"].tap()
        let field = app.textFields["route-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("KAUS SAT")
        let time = app.descendants(matching: .any)["route-total-time en route"]
        // About 52.8 NM at 120 knots, burning 9.5 an hour.
        scroll(to: time, app)
        _ = Screen.wait(5) { time.label.contains("0:26") }
        XCTAssertTrue(time.label.contains("0:26"), time.label)
        let fuel = app.descendants(matching: .any)["route-total-trip"]
        scroll(to: fuel, app, tries: 4)
        XCTAssertTrue(fuel.label.contains("4.2 gal"), fuel.label)
        // With an aircraft the log fills; where ten columns would be cut short it keeps the core's short list.
        guard Screen.device == "ipad" else { return }
        field.typeText("\n")
        app.buttons["route-expand"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["route-log"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["GS"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["Hdg"].firstMatch.exists)
        sleep(1)
        try Screen.save("route-page-aircraft")
        // The foot of the page: the whole log, then fuel, altitudes and sun.
        let total = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Total'")).firstMatch
        scrollPage(to: total, app)
        XCTAssertTrue(total.isHittable)
        let foot = app.staticTexts[RouteUITests.notCovered]
        scrollPage(to: foot, app)
        sleep(1)
        try Screen.save("route-page-aircraft-foot")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        scrollPage(to: app.descendants(matching: .any)["route-total-distance"].firstMatch, app, up: false)
        XCTAssertTrue(app.descendants(matching: .any)["GS"].firstMatch.exists)
        try Screen.save("route-page-aircraft-landscape")
    }

    /// The last line of the planning page, under the sun times.
    private static let notCovered = "Not covered: takeoff and landing distance, density altitude, runway length."

    // A phone on its side opens the card; expanded, it keeps the list, since a narrow table shows its first column only.
    @MainActor func testOnAPhoneOnItsSideTheExpandedPanelKeepsTheList() throws {
        guard Screen.device == "iphone" else { throw XCTSkip("phones only") }
        let app = Screen.launch(NavUITests.austin + ["-show", "route", "-navRoute", "KAUS CWK SAT"])
        XCTAssertTrue(app.descendants(matching: .any)["route-total-distance"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft
        let expand = app.buttons["route-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["route-log"].exists)
        try Screen.save("route-page-landscape")
        // Hittability is not reported on a phone on its side, so the list is swiped until the row exists.
        let point = app.descendants(matching: .any)["route-point-2"]
        for _ in 0..<8 where !point.exists { app.collectionViews["route-list"].swipeUp(velocity: .slow) }
        XCTAssertTrue(point.exists)
    }
}
