import Foundation
import Testing
@testable import FlightCore

private let testDatabase = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/MapAssets/nav-test.sqlite").path

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let austin = RouteWaypoint(kind: .airport, ident: "KAUS", name: "AUSTIN-BERGSTROM INTL",
                                   coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699))
private let waco = RouteWaypoint(kind: .navaid, ident: "ACT", name: "WACO",
                                 coordinate: Coordinate(latitude: 31.6624, longitude: -97.2690))
private let dallas = RouteWaypoint(kind: .airport, ident: "KDFW", name: "DALLAS-FORT WORTH INTL",
                                   coordinate: Coordinate(latitude: 32.8968, longitude: -97.0380))

private func fix(_ at: Coordinate, knots: Double? = nil) -> Position {
    Position(latitude: at.latitude, longitude: at.longitude, courseDegrees: -1,
             speedMetersPerSecond: knots.map { $0 / 1.943844 } ?? -1, altitudeMeters: nil, timestamp: now)!
}

private func planned() throws -> RoutePlan {
    RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
}

private func place(_ kind: WaypointKind, _ ident: String) -> WaypointMatch {
    WaypointMatch(kind: kind, ident: ident, name: ident, coordinate: Coordinate(latitude: 31, longitude: -97.5))
}

@Suite struct RoutePagesTests {
    @Test func aDirectToIsDrawnOnlyFromALiveExactFix() throws {
        let plan = RoutePlan.direct(to: dallas, navCycle: "c")
        let drawn = try #require(RoutePages.drawn(plan, position: fix(austin.coordinate), now: now))
        #expect(drawn.route.waypoints.count == 2 && drawn.active == 0 && drawn.firstDot == 1)
        #expect(drawn.dots == [dallas])
        #expect(RoutePages.drawn(plan, position: nil, now: now) == nil)
        #expect(RoutePages.drawn(plan, position: fix(austin.coordinate), approximate: true, now: now) == nil)
        #expect(RoutePages.title(plan) == "Direct To")
    }

    @Test func aRouteFromTheAircraftWithoutAFixDropsItsFirstLeg() throws {
        let plan = RoutePlan.appending(dallas, to: .direct(to: waco, navCycle: "c"), navCycle: "c")
        let drawn = try #require(RoutePages.drawn(plan, position: nil, now: now))
        #expect(drawn.route.waypoints == [waco, dallas] && drawn.active == nil && drawn.firstDot == 0)
        #expect(RoutePages.title(plan) == "Route")
    }

    @Test func anchorsAndSnapLabels() {
        #expect(MapPick.anchors(.leg(1), count: 3) == [1, 2])
        #expect(MapPick.anchors(.point(0), count: 3) == [1])
        #expect(MapPick.anchors(.point(2), count: 3) == [1])
        #expect(MapPick.Snap.open.label == nil)
        #expect(MapPick.Snap.one(place(.navaid, "CWK")).label == "CWK")
        #expect(MapPick.Snap.choose([place(.navaid, "CWK"), place(.airport, "CWK")]).label == "CWK · CWK")
    }

    @Test func aBandLetGoOnOpenMapOffersPlacesForTheNewPoint() throws {
        let plan = try planned()
        let at = Coordinate(latitude: 31, longitude: -97.6)
        guard case .edit(let bent, let offer)? = RoutePages.bend(plan, .leg(0), drawnCount: 3, snap: .open, at: at) else {
            Issue.record("no edit")
            return
        }
        #expect(bent.route.waypoints.count == 4 && offer == 0)
        #expect(bent.targets[0] == RouteWaypoint.user(at: at))
        let cwk = place(.navaid, "CWK")
        #expect(RoutePages.bend(plan, .point(1), drawnCount: 3, snap: .one(cwk), at: at)
                == .edit(try #require(plan.replacing(target: 0, with: RouteWaypoint(match: cwk))), offer: nil))
        #expect(RoutePages.bend(plan, .leg(0), drawnCount: 3, snap: .choose([cwk]), at: at) == .choose([cwk]))
    }

    @Test func typingARouteSuggestsParsesAndReplaces() throws {
        let db = try NavDatabase(path: testDatabase)
        let typing = RoutePages.typed("KAUS CW", plan: nil, database: db, now: now)
        #expect(typing.suggestions.map(RoutePages.ident) == ["CWK"])
        #expect(!typing.replaces || typing.problems.isEmpty)
        #expect(RoutePages.take(typing.suggestions[0], into: "KAUS CW") == "KAUS CWK ")
        let typed = RoutePages.typed("KAUS CWK ", plan: .direct(to: austin, navCycle: "c"), database: db, now: now)
        #expect(typed.replaces && typed.problems.isEmpty && typed.suggestions.isEmpty)
        #expect(typed.plan?.route.waypoints.map(\.ident) == ["KAUS", "CWK"] && typed.plan?.fromAircraft == false)
        let bad = RoutePages.typed("KAUS QQQQQ", plan: typed.plan, database: db, now: now)
        #expect(!bad.replaces && bad.plan == typed.plan && bad.problems.count == 1)
        let empty = RoutePages.typed(" ", plan: typed.plan, database: db, now: now)
        #expect(empty.replaces && empty.plan == nil)
    }

    @Test func theEditorListsPointsAndTotals() throws {
        let plan = try planned()
        let editor = RoutePages.editor(plan, position: nil, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 10)
        #expect(editor.header == "Waypoints")
        #expect(editor.points.map(\.title) == ["KAUS", "ACT", "KDFW"])
        #expect(editor.points.map(\.target) == [-1, 0, 1])
        #expect(editor.points[0].leg == nil && editor.points[1].leg?.waypoint == waco)
        #expect(editor.totals.map(\.title) == ["Distance", "Time", "Fuel"])
        #expect(editor.totals.allSatisfy { $0.value != NavText.dashes })
        let direct = RoutePages.editor(.direct(to: dallas, navCycle: "c"), position: nil, now: now, trueAirspeedKt: 0,
                                       fuelBurnPerHour: 0)
        #expect(direct.header == "From the aircraft" && direct.points.map(\.target) == [0])
        #expect(direct.totals.allSatisfy { $0.value == NavText.dashes })
    }

    @Test func theSummaryNamesTheNextWaypointAndTheEnd() throws {
        let rows = try planned().rows(position: nil, now: now, trueAirspeedKt: 120)
        let summary = try #require(RoutePages.summary(rows))
        #expect(summary.ident == "ACT" && summary.end == "· KDFW")
        #expect(RoutePages.summary([]) == nil)
    }

    @Test func addingInsertsBesideALegOrAppends() throws {
        let plan = try planned()
        let beside = RouteWaypoint(kind: .fix, ident: "MID", name: "MID", coordinate: Coordinate(latitude: 30.9, longitude: -97.3))
        let added = RoutePlan.adding(beside, to: plan, position: nil, now: now, navCycle: "c")
        #expect(added.route.waypoints.map(\.ident) == ["KAUS", "MID", "ACT", "KDFW"])
        #expect(RoutePlan.adding(austin, to: nil, position: nil, now: now, navCycle: "c") == .direct(to: austin, navCycle: "c"))
    }

    @Test func aPlanRoundTripsAsJSON() throws {
        var plan = RoutePlan.appending(dallas, to: .direct(to: waco, navCycle: "c"), navCycle: "c")
        plan = plan.moving(from: 1, to: 0)
        let back = try JSONDecoder().decode(RoutePlan.self, from: JSONEncoder().encode(plan))
        #expect(back == plan)
    }

    @Test func useInsteadAndClosedReadTheDatabase() throws {
        let db = try NavDatabase(path: testDatabase)
        let near = db.useInstead(near: austin.coordinate, metersPerPoint: 100)
        #expect(!near.isEmpty && near.count <= 3)
        #expect(!db.isClosed(austin) && !db.isClosed(waco))
    }

    @Test func thePlanPageKeysLegsByEditorRowAndRollsAPastDeparture() throws {
        let page = try #require(RoutePages.planPage(try planned(), position: nil, now: now,
                                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now),
                                                    trueAirspeedKt: 120, burnGPH: 10, winds: nil, tafs: []))
        #expect(page.legs.keys.sorted() == [0, 1])
        #expect(page.legs[0]?.time != nil && page.legs[0]?.note == "No winds aloft: calm assumed")
        // A Direct To with no fix has no leg to plan.
        #expect(RoutePages.planPage(.direct(to: dallas, navCycle: "c"), position: nil, now: now,
                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now),
                                    trueAirspeedKt: 120, burnGPH: 10, winds: nil, tafs: []) == nil)

        let stored = RoutePages.storing(FlightPlanInputs(cruiseAltitudeFt: 7500, departure: now - 3600, rules: .ifr))
        let back = RoutePages.planInputs(stored: stored, now: now)
        #expect(back.cruiseAltitudeFt == 7500 && back.rules == .ifr && back.departure >= now)
        let fresh = RoutePages.planInputs(stored: nil, now: now + 1)
        #expect(fresh.cruiseAltitudeFt == RoutePages.defaultAltitudeFt && fresh.departure == now + 900)
    }

    @Test func logCellsLineUpWithTheColumns() throws {
        let plan = try planned()
        let editor = RoutePages.editor(plan, position: nil, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 9)
        let page = try #require(RoutePages.planPage(plan, position: nil, now: now,
                                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now + 3600),
                                                    trueAirspeedKt: 120, burnGPH: 9, taxiFuelGal: 1, fuelOnBoardGal: 40,
                                                    winds: nil, tafs: []))
        let col = { (name: String) in RoutePages.logColumns.firstIndex(of: name) ?? -1 }
        let rows = editor.points.map { RoutePages.logCells($0, page: page) }
        #expect(rows.allSatisfy { $0.count == RoutePages.logColumns.count })
        let leg = try #require(editor.points[1].leg)
        #expect(rows[1][0] == "ACT" && leg.course.hasPrefix(rows[1][col("Course")]) && leg.distance.hasPrefix(rows[1][col("NM")]))
        #expect(rows[1][col("GS")] == "120" && rows[1][col("Alt")] == "5500" && rows[1][col("Hdg")].hasSuffix("°M"))
        // Remaining counts down from the whole trip to nothing; fuel starts at on board less taxi.
        let total = page.plan.log.totalDistanceNM
        #expect(rows[0][col("Rem NM")] == NavText.fixed(total, 1) && rows.last?[col("Rem NM")] == "0.0")
        #expect(rows[0][col("Rem fuel")] == "39.0")
        let burned = try #require(page.plan.log.totalFuel)
        #expect(rows.last?[col("Rem fuel")] == NavText.fixed(39 - burned, 1))
        let totals = RoutePages.logTotals(page)
        #expect(totals.count == RoutePages.logColumns.count && totals[col("NM")] == NavText.fixed(total, 1))
    }

    @Test func theActiveLegKeepsItsLiveTimeAndCoursesAreMagnetic() throws {
        let plan = RoutePlan.direct(to: dallas, navCycle: "c")
        let here = fix(austin.coordinate, knots: 120)
        let editor = RoutePages.editor(plan, position: here, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 9)
        let page = try #require(RoutePages.planPage(plan, position: here, now: now,
                                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now),
                                                    trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: []))
        let point = try #require(editor.points.first { $0.leg != nil })
        let cells = RoutePages.logCells(point, page: page)
        let time = try #require(RoutePages.logColumns.firstIndex(of: "Time"))
        #expect(cells[time] != NavText.dashes && cells[time] == point.leg?.time)
        #expect(cells[1].hasSuffix("°M") && cells[2].hasSuffix("°M"))
    }

    @Test func isaDeviationIsSignedWholeDegrees() {
        #expect(RoutePages.isaDeviation(temperatureC: 10, altitudeFt: 5500) == "+6")
        #expect(RoutePages.isaDeviation(temperatureC: -12, altitudeFt: 12000) == "-3")
        #expect(RoutePages.isaDeviation(temperatureC: nil, altitudeFt: 5500) == NavText.dashes)
    }
}
