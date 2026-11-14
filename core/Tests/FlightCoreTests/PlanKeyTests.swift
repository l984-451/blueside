import Foundation
import Testing
@testable import FlightCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let austin = RouteWaypoint(kind: .airport, ident: "KAUS", name: "AUSTIN-BERGSTROM INTL",
                                   coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699))
private let waco = RouteWaypoint(kind: .navaid, ident: "ACT", name: "WACO",
                                 coordinate: Coordinate(latitude: 31.6624, longitude: -97.2690))
private let dallas = RouteWaypoint(kind: .airport, ident: "KDFW", name: "DALLAS-FORT WORTH INTL",
                                   coordinate: Coordinate(latitude: 32.8968, longitude: -97.0380))
// A spot on the Austin ramp.
private let ramp = Coordinate(latitude: 30.2002, longitude: -97.6702)

private func fix(_ at: Coordinate, knots: Double = 0, at time: Date = now) -> Position {
    Position(latitude: at.latitude, longitude: at.longitude, courseDegrees: 10,
             speedMetersPerSecond: knots / 1.943844, altitudeMeters: nil, timestamp: time)!
}

private func page(_ plan: RoutePlan, _ position: Position?, _ time: Date, rules: FlightPlanInputs.Rules = .vfr,
                  hasApproach: Bool? = nil) -> RoutePages.PlanPage? {
    RoutePages.planPage(plan, position: position, now: time,
                        inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now + 3600, rules: rules),
                        trueAirspeedKt: 120, burnGPH: 9, taxiFuelGal: 1, fuelOnBoardGal: 40, winds: nil, tafs: [],
                        destinationHasApproach: hasApproach)
}

@Suite struct PlanKeyTests {
    @Test func aRouteBetweenItsOwnPointsKeepsItsKeyWhileTheAircraftSitsOrTaxis() throws {
        let plan = RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
        let parked = fix(ramp)
        let later = fix(Coordinate(latitude: ramp.latitude + 0.003, longitude: ramp.longitude), knots: 15, at: now + 2)
        let key = RoutePages.planKey(plan, position: parked, now: now)
        #expect(key == RoutePages.planKey(plan, position: later, now: now + 2))
        #expect(page(plan, parked, now) == page(plan, later, now + 2))
        // Losing the fix changes what the page shows: the active leg loses its live time.
        #expect(key != RoutePages.planKey(plan, position: parked, now: now + 10))
        #expect(key != RoutePages.planKey(plan, position: nil, now: now))
        #expect(key != RoutePages.planKey(plan, position: parked, approximate: true, now: now))
        // So does any edit, the active leg included.
        var flown = plan
        flown.advance(position: fix(waco.coordinate), now: now)
        #expect(flown.activeLeg == 1 && key != RoutePages.planKey(flown, position: parked, now: now))
    }

    @Test func aRouteFromTheAircraftKeepsItsStartUntilTheAircraftHasMoved() {
        let plan = RoutePlan.direct(to: dallas, navCycle: "c")
        let key = RoutePages.planKey(plan, position: fix(ramp), now: now)
        #expect(key.start == ramp)
        // GPS jitter of a few meters, either way, keeps the start: 0.04 NM is about 0.00067° of latitude.
        for step in [0.00009, -0.00009, 0.00067] {
            let near = Coordinate(latitude: ramp.latitude + step, longitude: ramp.longitude)
            #expect(key == RoutePages.planKey(plan, position: fix(near, at: now + 1), now: now + 1, after: key))
        }
        // 0.06 NM on, the route starts at the aircraft again.
        let away = Coordinate(latitude: ramp.latitude + 0.001, longitude: ramp.longitude)
        let moved = RoutePages.planKey(plan, position: fix(away, at: now + 1), now: now + 1, after: key)
        #expect(moved != key && moved.start == away)
        #expect(RoutePages.planKey(plan, position: nil, now: now, after: key).start == nil)
    }

    // A Direct To flown straight in, one fix a second for ten minutes: the page is worked out again when the distance
    // it prints moves a tenth, the course out of the fix a degree, or the minute turns. Not on every fix.
    @Test func airborneFromTheAircraftTheKeyFollowsWhatThePagePrints() throws {
        let plan = RoutePlan.direct(to: dallas, navCycle: "c")
        let from = Coordinate(latitude: 31.9, longitude: -97.4)
        let miles = Geo.distanceNM(from: from, to: dallas.coordinate)
        for knots in [120.0, 180.0] {
            var key: RoutePages.PlanKey?, changes = 0
            for second in 0..<600 {
                let time = now + Double(second)
                let at = RouteMath.intermediate(from: from, to: dallas.coordinate, fraction: knots * Double(second) / 3600 / miles)
                let next = RoutePages.planKey(plan, position: fix(at, knots: knots, at: time), now: time, after: key)
                if next != key { changes += 1 }
                key = next
            }
            // Tenths of a mile flown in ten minutes: one change each 3 s at 120 kt, each 2 s at 180 kt.
            let tenths = Int(knots / 6 * 10)
            #expect(changes >= tenths && changes <= tenths + 15, "\(knots) kt: \(changes) changes")
        }
        let key = RoutePages.planKey(plan, position: fix(from, knots: 120), now: now)
        #expect(key.start == from && key.printed?.first == NavText.distance(miles))
    }

    // Airborne 50.05 NM out, GPS noise of 3 m either way flips the printed tenth on every fix; the key holds.
    @Test func airborneJitterAcrossAPrintedTenthKeepsTheKey() {
        let plan = RoutePlan.direct(to: dallas, navCycle: "c")
        let out = Coordinate(latitude: 31.9, longitude: -97.4)
        let miles = Geo.distanceNM(from: dallas.coordinate, to: out)
        func at(_ nm: Double) -> Coordinate { RouteMath.intermediate(from: dallas.coordinate, to: out, fraction: nm / miles) }
        var key = RoutePages.planKey(plan, position: fix(at(50.05 + 0.0016), knots: 120), now: now)
        var printed: Set<String> = [], changes = 0
        for second in 1...20 {
            let nm = 50.05 + (second.isMultiple(of: 2) ? 0.0016 : -0.0016)
            printed.insert(NavText.distance(Geo.distanceNM(from: at(nm), to: dallas.coordinate)))
            let next = RoutePages.planKey(plan, position: fix(at(nm), knots: 120, at: now + Double(second)),
                                          now: now + Double(second), after: key)
            if next != key { changes += 1 }
            key = next
        }
        #expect(printed == ["50.0 NM", "50.1 NM"] && changes == 0)
    }

    @Test func airborneThePlanDepartsNowSoTheKeyTurnsOverEachMinute() throws {
        let plan = RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
        let key = RoutePages.planKey(plan, position: fix(ramp, knots: 120), now: now)
        #expect(key.airborne && key.minute != nil)
        #expect(key == RoutePages.planKey(plan, position: fix(ramp, knots: 120, at: now + 30), now: now + 30))
        #expect(key != RoutePages.planKey(plan, position: fix(ramp, knots: 120, at: now + 61), now: now + 61))
        #expect(RoutePages.planKey(plan, position: fix(ramp, knots: 20), now: now).minute == nil)
    }

    @Test func theSummaryLeadsAndLeavesOutLinesWithNoNumber() throws {
        let plan = RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
        let full = try #require(page(plan, nil, now))
        #expect(full.summary.map(\.title) == ["Distance", "Departure", "Time en route", "ETA", "Fuel required", "Margin"])
        #expect(full.fuelLines.map(\.title) == ["Taxi", "Trip", "Reserve", "On board"])
        let noSpeed = try #require(RoutePages.planPage(plan, position: nil, now: now,
                                                       inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now),
                                                       trueAirspeedKt: 0, burnGPH: 0, winds: nil, tafs: []))
        #expect(noSpeed.summary.map(\.title) == ["Distance", "Departure"])
        #expect(noSpeed.fuelLines.isEmpty)
    }

    // IFR to a field with no approach and no alternate picked: fuel is unknown, and says so beside the advice.
    @Test func aRequiredAlternateNotPickedLeavesFuelRequiredUnknownOnThePage() throws {
        let plan = RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
        let p = try #require(page(plan, nil, now, rules: .ifr, hasApproach: false))
        #expect(p.plan.alternate?.required == true && p.plan.fuel == nil && p.plan.fuelUnknown)
        let fuel = try #require(p.summary.first { $0.title == "Fuel required" })
        #expect(fuel.value == NavText.dashes && fuel.detail == nil)
        #expect(p.summary.map(\.title) == ["Distance", "Departure", "Time en route", "ETA", "Fuel required"])
        #expect(p.fuelLines.isEmpty)
        // Without a burn the line still leaves the page, and the plan's line says what is missing.
        let noBurn = try #require(RoutePages.planPage(plan, position: nil, now: now,
                                                      inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now, rules: .ifr),
                                                      trueAirspeedKt: 120, burnGPH: 0, winds: nil, tafs: [],
                                                      destinationHasApproach: false))
        #expect(!noBurn.plan.fuelUnknown && !noBurn.summary.contains { $0.title == "Fuel required" })
        #expect(noBurn.plan.lines.first { $0.title == "Fuel required" }?.detail != nil)
    }

    @Test func columnsWithNoValueInAnyRowAreLeftOut() {
        let d = NavText.dashes
        let rows = [["KAUS", d, d, d, d, d, d, d, d, d, "52.8", d, d],
                    ["SAT", "225°M", d, "52.8", "5500", d, d, d, d, d, "0.0", d, d],
                    ["Total", "", "", "52.8", "", "", "", "", d, d, "", "", ""]]
        #expect(RoutePages.logShown(rows).map { RoutePages.logColumns[$0] } == ["Waypoint", "Course", "NM", "Alt", "Rem NM"])
        #expect(RoutePages.logColumns[RoutePages.logTime] == "Time")
        #expect(RoutePages.logColumns[RoutePages.logTime + 1] == "Fuel")
    }

    // Widths as the iPad's upright and landscape planning pages measure them with winds loaded.
    @Test func aNarrowPageDropsTheLeastNeededColumnsUntilTheRestFit() {
        let widths: [Double] = [87, 70, 65, 47, 53, 152, 42, 43, 50, 48, 78, 88, 86]
        let shown = Array(0...11)
        func names(_ room: Double, _ widths: [Double] = widths) -> [String]? {
            RoutePages.logFitted(shown, widths: widths, room: room)?.map { RoutePages.logColumns[$0] }
        }
        #expect(names(401) == ["Waypoint", "Course", "NM", "GS", "Time", "Fuel"])
        #expect(names(642) == ["Waypoint", "Course", "Hdg", "NM", "Alt", "Wind", "GS", "Time", "Fuel"])
        #expect(RoutePages.logFitted(shown, widths: widths, room: 2000) == shown)
        // A column that does not fit takes every one after it.
        #expect(names(300) == ["Waypoint", "Course", "NM", "Time"])
        // The waypoint, its distance and its time go before the course.
        #expect(names(250) == ["Waypoint", "NM", "Time"])
        #expect(RoutePages.logFitted([0, 1, 3, 8], widths: [87, 70, 0, 47, 0, 0, 0, 0, 50], room: 200) == [0, 3, 8])
        // Without room for those three there is no table, as at the largest text sizes on the upright page.
        #expect(names(10) == nil)
        #expect(names(401, widths.map { $0 * 2.3 }) == nil)
        // A column no row fills is not needed: with no time, the waypoint and distance make a table.
        #expect(RoutePages.logFitted([0, 1, 3], widths: widths, room: 210) == [0, 1, 3])
        #expect(Set(RoutePages.logPriority) == Set(RoutePages.logColumns.indices) && RoutePages.logPriority.first == 0)
    }

    @Test func theDestinationsPlatesTellWhetherItHasAnApproach() throws {
        func plate(_ code: String) -> Plate {
            Plate(airport: "SAT", icao: "KSAT", name: code, code: code, file: code, pages: 1)
        }
        // An approach chart says yes wherever it comes from.
        #expect(RoutePages.hasApproach([plate("APD"), plate("IAP")], regionInstalled: true) == true)
        // In a state whose pack is here, no chart, or no approach chart, means none is published.
        #expect(RoutePages.hasApproach([], regionInstalled: true) == false)
        #expect(RoutePages.hasApproach([plate("APD"), plate("DP")], regionInstalled: true) == false)
        // Elsewhere nothing can be told.
        #expect(RoutePages.hasApproach([], regionInstalled: false) == nil)
        let plan = RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
        let advice = try #require(page(plan, nil, now, rules: .ifr, hasApproach: false)?.plan.alternate)
        #expect(advice.required == true && advice.text.contains("no instrument approach at KDFW"))
    }
}
