import Foundation
import Testing
@testable import FlightCore

@Suite struct ClimbDescentTests {
    private let cruise = (tas: 120.0, burn: 8.0)
    // Climb 500 ft/min at 100 kt burning 10 gal/h; descent 500 ft/min at 120 kt burning 6 gal/h.
    private let vertical = FlightPlan.Vertical(
        climb: .init(rateFPM: 500, tasKt: 100, burnGPH: 10), descent: .init(rateFPM: 500, tasKt: 120, burnGPH: 6))

    /// A point this many nautical miles due north of 30N 97W along the meridian.
    private func north(_ nm: Double, _ ident: String) -> RouteWaypoint {
        let lat = 30 + nm / (Geo.earthRadiusNM * .pi / 180)
        return RouteWaypoint(kind: .fix, ident: ident, name: ident, coordinate: Coordinate(latitude: lat, longitude: -97))
    }

    private func make(_ nm: [Double], altitude: Int = 5500, vertical: FlightPlan.Vertical?) throws -> FlightPlan {
        let points = nm.enumerated().map { north($0.element, "P\($0.offset)") }
        let route = try #require(Route(waypoints: points, navCycle: "2026-10-01"))
        return FlightPlan.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: altitude, departure: Date(timeIntervalSince1970: 0)),
                               trueAirspeedKt: cruise.tas, burnGPH: cruise.burn, winds: nil, tafs: [], vertical: vertical)
    }

    @Test func aHundredMileRouteGetsTopOfClimbAndTopOfDescent() throws {
        // Climb 5500 ft / 500 ft/min = 11 min, 100 kt x 11/60 h = 18.33 nm, 10 gal/h x 11/60 h = 1.833 gal.
        // Descent 11 min, 120 kt x 11/60 h = 22 nm, 1.1 gal. Cruise 100 - 40.33 = 59.67 nm at 120 kt = 29.83 min, 3.978 gal.
        let plan = try make([0, 50, 100], vertical: vertical)
        let legs = plan.log.legs
        #expect(legs.map { $0.leg.to.ident } == ["-TOC-", "P1", "-TOD-", "P2"])
        #expect(abs(legs[0].leg.cumulativeDistanceNM - 18.333) < 0.02)
        #expect(abs(legs[2].leg.cumulativeDistanceNM - 78) < 0.02)
        #expect(plan.segments == [.climb, .cruise, .cruise, .descent])
        #expect(abs(plan.log.totalDistanceNM - 100) < 0.02)
        let time = try #require(plan.log.totalTime), fuel = try #require(plan.log.totalFuel)
        #expect(abs(time - (11 + 29.833 + 11) * 60) < 2)
        #expect(abs(fuel - (1.8333 + 3.9778 + 1.1)) < 0.01)
        let (up, down) = (try #require(legs[0].time), try #require(legs[3].time))
        #expect(abs(up - 660) < 0.5 && abs(down - 660) < 0.5)
        #expect(plan.notes == [FlightPlan.calmNote])
        #expect(plan.endAltitudesFt == [5500, 5500, 5500, 0])
    }

    @Test func climbAndDescentStartAndEndAtFieldElevation() throws {
        // From a 3000 ft field to a 1000 ft field at 5500: climb 2500 ft = 5 min, 8.33 nm; descent 4500 ft = 9 min, 18 nm.
        var points = [north(0, "HIGH"), north(50, "P1"), north(100, "LOW")]
        points[0].elevationFt = 3000
        points[2].elevationFt = 1000
        let route = try #require(Route(waypoints: points, navCycle: "2026-10-01"))
        let plan = FlightPlan.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: Date(timeIntervalSince1970: 0)),
                                   trueAirspeedKt: cruise.tas, burnGPH: cruise.burn, winds: nil, tafs: [], vertical: vertical)
        let legs = plan.log.legs
        #expect(legs.map { $0.leg.to.ident } == ["-TOC-", "P1", "-TOD-", "LOW"])
        #expect(abs(legs[0].leg.cumulativeDistanceNM - 8.333) < 0.02)
        #expect(abs(legs[2].leg.cumulativeDistanceNM - 82) < 0.02)
        #expect(abs((legs[0].time ?? 0) - 300) < 0.5 && abs((legs[3].time ?? 0) - 540) < 0.5)
        #expect(plan.endAltitudesFt.last == 1000)
    }

    @Test func anAirportWaypointCarriesItsElevation() {
        let airport = Airport(id: 1, ident: "DEN", icao: "KDEN", name: "DENVER INTL", city: "DENVER", state: "CO", type: "A",
                              use: "PU", coordinate: Coordinate(latitude: 39.86, longitude: -104.67), elevationFt: 5434,
                              magneticVariation: nil, patternAltitude: nil, tower: "Y", fuel: nil, artcc: nil, status: "O")
        #expect(RouteWaypoint(airport: airport).elevationFt == 5434)
        let match = WaypointMatch(kind: .airport, ident: "DEN", icao: "KDEN", name: "DENVER INTL",
                                  coordinate: airport.coordinate, elevationFt: 5434)
        #expect(RouteWaypoint(match: match).elevationFt == 5434)
    }

    @Test func aShortRouteCapsAtTheAltitudeItCanReach() throws {
        // Climb needs 100/60/500 = 0.003333 nm per ft, descent 120/60/500 = 0.004: 30 nm / 0.007333 = 4091 ft.
        let plan = try make([0, 30], vertical: vertical)
        #expect(plan.log.legs.map { $0.leg.to.ident } == ["-TOC/TOD-", "P1"])
        #expect(abs(plan.log.legs[0].leg.cumulativeDistanceNM - 13.636) < 0.02)
        #expect(abs(Double(plan.endAltitudesFt[0]) - 4091) <= 1)
        #expect(plan.notes.count == 2 && plan.notes[1] == FlightPlan.calmNote && plan.notes[0].contains("5500"))
        // 4091 ft at 500 ft/min = 8.18 min up and down: 1.364 + 0.818 gal.
        let fuel = try #require(plan.log.totalFuel)
        #expect(abs(fuel - (4090.9 / 500 / 60 * 10 + 4090.9 / 500 / 60 * 6)) < 0.01)
    }

    @Test func noNumbersFliesCruiseAndSaysWhy() throws {
        let plain = try make([0, 50, 100], vertical: nil)
        #expect(plain.log.legs.map { $0.leg.to.ident } == ["P1", "P2"])
        #expect(plain.segments == [.cruise, .cruise])
        let (time, fuel) = (try #require(plain.log.totalTime), try #require(plain.log.totalFuel))
        #expect(abs(time - 100.0 / 120 * 3600) < 1 && abs(fuel - 100.0 / 120 * 8) < 0.01)
        #expect(plain.notes == [FlightPlan.verticalMissingNote])
    }

    @Test func inFlightTheDescentStillCountsAndClimbLegsCarryNoWarning() throws {
        let route = try #require(Route(waypoints: [north(0, "P0"), north(50, "P1"), north(100, "P2")], navCycle: "2026-10-01"))
        let plan = FlightPlan.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: Date(timeIntervalSince1970: 0)),
                                   trueAirspeedKt: cruise.tas, burnGPH: cruise.burn, winds: nil, tafs: [],
                                   vertical: vertical, inFlight: true)
        #expect(plan.log.legs.map { $0.leg.to.ident } == ["P1", "-TOD-", "P2"])
        #expect(plan.legWinds.allSatisfy { $0.note != FlightPlan.calmNote })
        #expect(plan.notes == [FlightPlan.calmNote])
        let profiled = try make([0, 50, 100], vertical: vertical)
        #expect(profiled.notes == [FlightPlan.calmNote])
    }

    @Test func typedNumbersNeverAskForNumbers() throws {
        // Cruise below the field: no profile, and no note asking for numbers the aircraft already has.
        var points = [north(0, "HIGH"), north(100, "P1")]
        points[0].elevationFt = 6000
        let route = try #require(Route(waypoints: points, navCycle: "2026-10-01"))
        let plan = FlightPlan.make(route: route, inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: Date(timeIntervalSince1970: 0)),
                                   trueAirspeedKt: cruise.tas, burnGPH: cruise.burn, winds: nil, tafs: [], vertical: vertical)
        #expect(!plan.notes.contains(FlightPlan.verticalMissingNote))
    }

    @Test func theAircraftOffersNumbersOnlyWhenAllSixAreTyped() {
        var craft = AircraftProfile(tail: "N1")
        #expect(craft.vertical == nil)
        craft.climbRateFPM = 500; craft.climbTASKt = 100; craft.climbBurnGPH = 10
        craft.descentRateFPM = 500; craft.descentTASKt = 120
        #expect(craft.vertical == nil)
        craft.descentBurnGPH = 6
        #expect(craft.vertical == vertical)
        #expect(AircraftTemplates.all.allSatisfy { $0.profile.vertical == nil })
        let old = Data(#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","tail":"N2","taxiFuelGal":0,"fuelLbPerGal":6,"stations":[],"envelope":[]}"#.utf8)
        #expect((try? JSONDecoder().decode(AircraftProfile.self, from: old))?.climbRateFPM == nil)
        #expect(AircraftPages.sections.contains { $0.title == "Climb and Descent" && $0.fields.count == 6 })
    }

    @Test func theLogPageInsertsThemWithConsistentRemainders() throws {
        let points = [north(0, "P0"), north(50, "P1"), north(100, "P2")]
        let route = RoutePlan(route: try #require(Route(waypoints: points, navCycle: "c")))
        let now = Date(timeIntervalSince1970: 0)
        let page = try #require(RoutePages.planPage(route, position: nil, now: now,
                                                    inputs: FlightPlanInputs(cruiseAltitudeFt: 5500, departure: now),
                                                    trueAirspeedKt: 120, burnGPH: 8, fuelOnBoardGal: 30, winds: nil, tafs: [],
                                                    vertical: vertical))
        let editor = RoutePages.editor(route, position: nil, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 8)
        let col = { (name: String) in RoutePages.logColumns.firstIndex(of: name)! }
        let rows = editor.points.flatMap { p in RoutePages.logInserts(p, page: page) + [RoutePages.logCells(p, page: page)] }
        #expect(rows.map { $0[0] } == ["P0", "-TOC-", "P1", "-TOD-", "P2"])
        #expect(rows.allSatisfy { $0.count == RoutePages.logColumns.count })
        #expect(rows.map { $0[col("Alt")] } == [NavText.dashes, "5500", "5500", "5500", "0"])
        #expect(rows[1][col("Rem NM")] == NavText.fixed(100 - 18.333, 1) && rows.last?[col("Rem NM")] == "0.0")
        #expect(rows[1][col("Rem time")] == NavText.duration(page.plan.log.totalTime! - 660))
        #expect(rows[1][col("Rem fuel")] == NavText.fixed(30 - 1.8333, 1))
        #expect(rows.last?[col("Rem fuel")] == NavText.fixed(30 - page.plan.log.totalFuel!, 1))
        #expect(page.legs[0]?.time == NavText.duration(page.plan.log.legs[0].time! + page.plan.log.legs[1].time!))
    }
}
