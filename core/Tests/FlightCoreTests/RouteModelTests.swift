import Foundation
import Testing
@testable import FlightCore

private let logDate = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!

private func point(_ ident: String, _ latitude: Double, _ longitude: Double, airway: String? = nil) -> RouteWaypoint {
    RouteWaypoint(kind: .fix, ident: ident, name: ident,
                  coordinate: Coordinate(latitude: latitude, longitude: longitude), airway: airway)
}

private func airwayRoute() throws -> Route {
    try #require(Route(waypoints: [
        point("A", 0, 0), point("B", 0, 1, airway: "V1"), point("C", 0, 2, airway: "V1"),
        point("D", 0, 3, airway: "V1"), point("E", 0, 4),
    ], navCycle: "2026-10-01"))
}

private func eastbound() throws -> Route {
    try #require(Route(waypoints: [point("A", 0, 0), point("B", 0, 1), point("C", 0, 2)], navCycle: "2026-10-01"))
}

@Test func routeNeedsTwoRealWaypoints() throws {
    #expect(Route(waypoints: [point("A", 0, 0)], navCycle: "2026-10-01") == nil)
    #expect(Route(waypoints: [], navCycle: "2026-10-01") == nil)
    #expect(Route(waypoints: [point("A", 0, 0), point("B", .nan, 0)], navCycle: "2026-10-01") == nil)
    #expect(Route(waypoints: [point("A", 0, 0), point("B", 91, 0)], navCycle: "2026-10-01") == nil)
    let route = try #require(Route(waypoints: [point("A", 0, 0, airway: "V1"), point("B", 0, 1)], navCycle: "2026-10-01"))
    #expect(route.waypoints.count == 2)
    #expect(route.waypoints[0].airway == nil)
    #expect(route.navCycle == "2026-10-01")
}

@Test func routeSurvivesEncodingAndRefusesAShortOne() throws {
    let route = try #require(Route(waypoints: [
        point("A", 0, 0), point("B", 0, 1, airway: "V1"), .user(at: Coordinate(latitude: 1, longitude: 1)),
    ], navCycle: "2026-10-01"))
    let data = try JSONEncoder().encode(route)
    let back = try JSONDecoder().decode(Route.self, from: data)
    #expect(back == route)
    let short = Data(#"{"waypoints":[{"kind":"fix","ident":"A","name":"A","coordinate":{"latitude":0,"longitude":0}}],"navCycle":"2026-10-01"}"#.utf8)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Route.self, from: short) }
}

@Test func insertingInsideAnAirwayClearsTheMarkOnTheLegItSplits() throws {
    let route = try airwayRoute()
    let edited = try #require(route.inserting(point("X", 1, 1.5, airway: "V9"), at: 2))
    #expect(edited.waypoints.map(\.ident) == ["A", "B", "X", "C", "D", "E"])
    #expect(edited.waypoints.map(\.airway) == [nil, "V1", nil, nil, "V1", nil])
    #expect(route.inserting(point("X", 1, 1), at: 6) == nil)
    #expect(route.inserting(point("X", 1, 1), at: 5)?.waypoints.last?.ident == "X")
}

@Test func removingABendClearsTheMarkSoNoLegClaimsTheAirway() throws {
    let route = try airwayRoute()
    let edited = try #require(route.removing(at: 2))
    #expect(edited.waypoints.map(\.ident) == ["A", "B", "D", "E"])
    #expect(edited.waypoints.map(\.airway) == [nil, "V1", nil, nil])
    #expect(route.removing(at: 0)?.waypoints.map(\.airway) == [nil, "V1", "V1", nil])
    #expect(route.removing(at: 9) == nil)
    let two = try #require(Route(waypoints: [point("A", 0, 0), point("B", 0, 1)], navCycle: "2026-10-01"))
    #expect(two.removing(at: 0) == nil)
}

@Test func movingAWaypointClearsOnlyTheLegsItTouches() throws {
    let route = try airwayRoute()
    let edited = try #require(route.moving(from: 4, to: 0))
    #expect(edited.waypoints.map(\.ident) == ["E", "A", "B", "C", "D"])
    #expect(edited.waypoints.map(\.airway) == [nil, nil, "V1", "V1", "V1"])
    let inside = try #require(route.moving(from: 1, to: 2))
    #expect(inside.waypoints.map(\.ident) == ["A", "C", "B", "D", "E"])
    #expect(inside.waypoints.map(\.airway) == [nil, nil, nil, nil, nil])
    #expect(route.moving(from: 0, to: 5) == nil)
}

@Test func reversingKeepsAirwayStretchesOnTheSameLegs() throws {
    let reversed = try airwayRoute().reversed()
    #expect(reversed.waypoints.map(\.ident) == ["E", "D", "C", "B", "A"])
    #expect(reversed.waypoints.map(\.airway) == [nil, nil, "V1", "V1", "V1"])
    #expect(reversed.navCycle == "2026-10-01")
}

@Test func routeTextCollapsesAirwayStretches() throws {
    let route = try airwayRoute()
    #expect(route.routeText == "A V1 D E")
    let split = try #require(route.removing(at: 2))
    #expect(split.routeText == "A V1 B D E")
}

@Test func coordinateTokensAreReadInAllThreeForms() {
    #expect(RouteText.coordinate("3015N09745W") == Coordinate(latitude: 30.25, longitude: -97.75))
    #expect(RouteText.coordinate("301530N0974500W") == Coordinate(latitude: 30.258333, longitude: -97.75))
    #expect(RouteText.coordinate("30.25/-97.75") == Coordinate(latitude: 30.25, longitude: -97.75))
    #expect(RouteText.coordinate("3015s09745e") == Coordinate(latitude: -30.25, longitude: 97.75))
    for bad in ["3075N09745W", "9100N09745W", "3015N18100W", "3015N9745W", "95.0/-97", "30.25/",
                "30.25/-97.75/1", "nan/0", "0x1p3/0", "KAUS", "3015N09745"] {
        #expect(RouteText.coordinate(bad) == nil, "\(bad)")
    }
    #expect(RouteText.looksLikeCoordinate("3075N09745W"))
    #expect(RouteText.looksLikeCoordinate("95.0/-97"))
    #expect(!RouteText.looksLikeCoordinate("N0120A050"))
    #expect(!RouteText.looksLikeCoordinate("12N"))
}

@Test func userWaypointsAreNamedInDegreesAndMinutesAndWrittenSoTheyReadBack() {
    let onMinute = RouteWaypoint.user(at: Coordinate(latitude: 30.25, longitude: -97.75))
    #expect(onMinute.kind == .user)
    #expect(onMinute.ident == "3015N09745W")
    #expect(onMinute.textToken == "3015N09745W")
    let offMinute = RouteWaypoint.user(at: Coordinate(latitude: 30.25123456, longitude: -97.7534))
    #expect(offMinute.ident == "3015N09745W")
    #expect(offMinute.coordinate == Coordinate(latitude: 30.251235, longitude: -97.7534))
    #expect(offMinute.textToken == "30.251235/-97.753400")
    #expect(RouteText.coordinate(offMinute.textToken) == offMinute.coordinate)
    #expect(RouteWaypoint.user(at: Coordinate(latitude: -0.5, longitude: 179.999)).ident == "0030S18000E")
}

@Test func directToIsATwoPointRouteFromTheAircraft() throws {
    let target = point("CWK", 30.37855, -97.52984722, airway: "V565")
    let route = try #require(Route.direct(from: Coordinate(latitude: 30.2, longitude: -97.7), to: target, navCycle: "2026-10-01"))
    #expect(route.waypoints.map(\.kind) == [.user, .fix])
    #expect(route.waypoints[1].airway == nil)
    #expect(Route.direct(from: Coordinate(latitude: .nan, longitude: 0), to: target, navCycle: "2026-10-01") == nil)
}

@Test func linePointsFollowTheGreatCircle() throws {
    let route = try #require(Route(waypoints: [point("A", 40, -100), point("B", 40, -80)], navCycle: "2026-10-01"))
    let line = route.linePoints()
    #expect(line.first == Coordinate(latitude: 40, longitude: -100))
    #expect(line.last == Coordinate(latitude: 40, longitude: -80))
    // A great circle between two points on one parallel bulges toward the pole: 40.43 at the middle here.
    let middle = line[line.count / 2]
    #expect(middle.latitude > 40.3 && middle.latitude < 40.6)
    for (a, b) in zip(line, line.dropFirst()) {
        #expect(Geo.distanceNM(from: a, to: b) <= 20.01)
    }
    #expect(route.linePoints(maxSegmentNM: 5000).count == 2)
    #expect(route.linePoints(maxSegmentNM: 0).count == line.count)
    #expect(route.linePoints(maxSegmentNM: .nan).count == line.count)
}

@Test func linePointsDoNotJumpAcrossTheDateLine() throws {
    let route = try #require(Route(waypoints: [point("W", 52, 179), point("E", 52, -179), point("F", 53, -178)],
                                   navCycle: "2026-10-01"))
    let line = route.linePoints(maxSegmentNM: 10)
    for (a, b) in zip(line, line.dropFirst()) {
        #expect(abs(b.longitude - a.longitude) < 1)
    }
    #expect(abs(line[line.count - 1].longitude - 182) < 1e-9)
    #expect(line.contains { $0.longitude > 180 })
    let westbound = try #require(Route(waypoints: [point("E", 52, -179), point("W", 52, 179)], navCycle: "2026-10-01"))
    let back = westbound.linePoints(maxSegmentNM: 10)
    #expect(abs(back[back.count - 1].longitude + 181) < 1e-9)
}

@Test func legsCarryDistanceTrueAndMagneticCourseAndRunningTotal() throws {
    let a = Coordinate(latitude: 30.19452722, longitude: -97.66987611)
    let b = Coordinate(latitude: 31.19452722, longitude: -97.66987611)
    let route = try #require(Route(waypoints: [
        point("A", a.latitude, a.longitude), point("B", b.latitude, b.longitude),
        point("C", b.latitude, b.longitude + 1),
    ], navCycle: "2026-10-01"))
    let legs = route.legs(date: logDate)
    #expect(legs.count == 2)
    #expect(legs[0].from.ident == "A" && legs[0].to.ident == "B")
    #expect(abs(legs[0].distanceNM - 60.04) < 0.05)
    #expect(legs[0].trueCourse < 0.001 || legs[0].trueCourse > 359.999)
    #expect(abs(legs[1].cumulativeDistanceNM - (legs[0].distanceNM + legs[1].distanceNM)) < 1e-9)
    #expect(abs(route.totalDistanceNM - legs[1].cumulativeDistanceNM) < 1e-9)
    // East variation makes the magnetic course smaller than the true one. The FAA lists 4E at this airport.
    let variation = MagneticModel.declination(at: a, altitudeFt: 0, date: logDate)
    #expect(abs(legs[0].magneticCourse - (360 - variation)) < 1e-6)
    #expect(legs[0].magneticCourse > 354 && legs[0].magneticCourse < 359)
    #expect(legs[1].trueCourse > 89 && legs[1].trueCourse < 90.5)
    let second = MagneticModel.declination(at: b, altitudeFt: 0, date: logDate)
    #expect(abs(legs[1].magneticCourse - (legs[1].trueCourse - second)) < 1e-6)
}

@Test func navLogWithNoWindIsMarkedCalm() throws {
    let log = try eastbound().navLog(trueAirspeedKt: 120, fuelBurnPerHour: 10, date: logDate)
    #expect(log.legs.count == 2)
    #expect(log.legs.allSatisfy { $0.windIsAssumedCalm })
    let first = log.legs[0]
    #expect(abs((first.groundspeedKt ?? 0) - 120) < 1e-9)
    #expect(abs((first.trueHeading ?? -1) - 90) < 1e-6)
    #expect(abs((first.time ?? 0) - first.leg.distanceNM / 120 * 3600) < 1e-6)
    #expect(abs((first.fuel ?? 0) - first.leg.distanceNM / 120 * 10) < 1e-9)
    #expect(abs((log.totalTime ?? 0) - log.totalDistanceNM / 120 * 3600) < 1e-6)
    #expect(abs((log.totalFuel ?? 0) - log.totalDistanceNM / 120 * 10) < 1e-9)
    let variation = MagneticModel.declination(at: Coordinate(latitude: 0, longitude: 0), altitudeFt: 0, date: logDate)
    #expect(abs((first.magneticHeading ?? -1) - RouteMath.normalized(90 - variation)) < 1e-6)
}

@Test func navLogCrabsIntoACrosswindAndSlowsInAHeadwind() throws {
    let winds: [LegWind?] = [LegWind(directionTrue: 360, speedKt: 20), LegWind(directionTrue: 90, speedKt: 20)]
    let log = try eastbound().navLog(trueAirspeedKt: 100, fuelBurnPerHour: 8, winds: winds, date: logDate)
    let cross = log.legs[0]
    let head = log.legs[1]
    #expect(!cross.windIsAssumedCalm)
    // Wind from the north on an eastbound leg: the nose points left of course, toward the wind.
    #expect(abs((cross.trueHeading ?? 0) - (90 - asin(0.2) * 180 / .pi)) < 1e-6)
    #expect(abs((cross.groundspeedKt ?? 0) - 100 * cos(asin(0.2))) < 1e-6)
    #expect(abs((head.trueHeading ?? 0) - 90) < 1e-6)
    #expect(abs((head.groundspeedKt ?? 0) - 80) < 1e-6)
    #expect(abs((head.time ?? 0) - head.leg.distanceNM / 80 * 3600) < 1e-6)
}

@Test func navLogLeavesOutALegTheWindMakesUnflyable() throws {
    let route = try eastbound()
    let cross = route.navLog(trueAirspeedKt: 50, fuelBurnPerHour: 8,
                             winds: [LegWind(directionTrue: 360, speedKt: 60), nil], date: logDate)
    #expect(cross.legs[0].trueHeading == nil && cross.legs[0].magneticHeading == nil)
    #expect(cross.legs[0].groundspeedKt == nil && cross.legs[0].time == nil && cross.legs[0].fuel == nil)
    #expect(cross.legs[1].groundspeedKt != nil)
    #expect(cross.legs[1].windIsAssumedCalm)
    #expect(cross.totalTime == nil && cross.totalFuel == nil)
    #expect(cross.totalDistanceNM > 119)
    let head = route.navLog(trueAirspeedKt: 100, fuelBurnPerHour: 8,
                            winds: [LegWind(directionTrue: 90, speedKt: 100)], date: logDate)
    #expect(head.legs[0].groundspeedKt == nil)
    #expect(head.totalTime == nil)
}

@Test func navLogCountsUnderAKnotOverTheGroundAsUnflyable() throws {
    let route = try eastbound()
    let crawl = route.navLog(trueAirspeedKt: 100, fuelBurnPerHour: 8, winds: [LegWind(directionTrue: 90, speedKt: 99.5)], date: logDate)
    #expect(crawl.legs[0].groundspeedKt == nil && crawl.legs[0].time == nil && crawl.totalTime == nil)
    let slow = route.navLog(trueAirspeedKt: 100, fuelBurnPerHour: 8, winds: [LegWind(directionTrue: 90, speedKt: 98.5)], date: logDate)
    #expect(abs((slow.legs[0].groundspeedKt ?? 0) - 1.5) < 1e-9)
}

@Test func navLogGivesNoFuelForABurnOfZero() throws {
    let log = try eastbound().navLog(trueAirspeedKt: 100, fuelBurnPerHour: 0, date: logDate)
    #expect(log.totalTime != nil && log.totalFuel == nil && log.legs.allSatisfy { $0.fuel == nil })
}

@Test func navLogNeverReturnsNaN() throws {
    let route = try eastbound()
    for speed in [0.0, -10.0, Double.nan, Double.infinity] {
        let log = route.navLog(trueAirspeedKt: speed, fuelBurnPerHour: 8, date: logDate)
        #expect(log.legs.allSatisfy { $0.groundspeedKt == nil && $0.time == nil && $0.fuel == nil && $0.trueHeading == nil })
        #expect(log.totalTime == nil && log.totalFuel == nil)
        #expect(log.totalDistanceNM.isFinite)
    }
    let noBurn = route.navLog(trueAirspeedKt: 100, fuelBurnPerHour: .nan, date: logDate)
    #expect(noBurn.totalTime != nil && noBurn.totalFuel == nil)
    let oddWind = route.navLog(trueAirspeedKt: 100, fuelBurnPerHour: 8,
                               winds: [LegWind(directionTrue: .nan, speedKt: 10)], date: logDate)
    #expect(oddWind.legs[0].groundspeedKt == nil && oddWind.totalTime == nil)
    // Absurd but finite inputs must not overflow into an infinite value.
    let huge = Double.greatestFiniteMagnitude
    let tailwind = route.navLog(trueAirspeedKt: huge, fuelBurnPerHour: huge,
                                winds: [LegWind(directionTrue: 270, speedKt: huge)], date: logDate)
    let crawl = route.navLog(trueAirspeedKt: .leastNonzeroMagnitude, fuelBurnPerHour: huge, date: logDate)
    for log in [tailwind, crawl] {
        #expect((log.totalTime ?? 0).isFinite && (log.totalFuel ?? 0).isFinite)
        for row in log.legs {
            let values = [row.trueHeading, row.magneticHeading, row.groundspeedKt, row.time, row.fuel]
            #expect(values.allSatisfy { ($0 ?? 0).isFinite })
        }
    }
}
