import Foundation
import Testing
@testable import FlightCore

/// The date the route tests are read at. The core never reads the clock.
let routeDate = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!

private func parse(_ text: String) throws -> RouteParse {
    try RouteParser.parse(text, database: routeNav, date: routeDate)
}

private func problem(_ position: Int, _ token: String, _ kind: RouteProblemKind) -> RouteProblem {
    RouteProblem(position: position, token: token, kind: kind)
}

@Test func routeTextIsSplitOnSpacesIgnoringCaseAndDirectMarkers() throws {
    let parsed = try parse("  kaus dct cwk   DCT kcll ")
    #expect(parsed.waypoints.map(\.ident) == ["KAUS", "CWK", "KCLL"])
    #expect(parsed.waypoints.map(\.kind) == [.airport, .navaid, .airport])
    #expect(parsed.problems.isEmpty)
    #expect(parsed.navCycle == "2026-10-01")
    let route = try Route(parsed)
    #expect(route.waypoints.count == 3)
    #expect(route.navCycle == "2026-10-01")
}

@Test func airwayGainsEveryPointBetweenEntryAndExit() throws {
    let parsed = try parse("KAUS CWK V565 LFK KLFK")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.ident) == ["KAUS", "CWK", "SCOLL", "OSUME", "CLL", "OSCER", "LFK", "KLFK"])
    #expect(parsed.waypoints.map(\.airway) == [nil, nil, "V565", "V565", "V565", "V565", "V565", nil])
    #expect(parsed.waypoints.map(\.kind) == [.airport, .navaid, .fix, .fix, .navaid, .fix, .navaid, .airport])
}

@Test func airwayIsFlownInEitherDirection() throws {
    let parsed = try parse("LFK V565 CWK")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.ident) == ["LFK", "OSCER", "CLL", "OSUME", "SCOLL", "CWK"])
    #expect(parsed.waypoints.first?.kind == .navaid)
    #expect(parsed.waypoints.map(\.airway) == [nil, "V565", "V565", "V565", "V565", "V565"])
}

@Test func twoAirwaysJoinAtAPointOnBoth() throws {
    let parsed = try parse("JCT V306 CWK V565 CLL")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.ident) == ["JCT", "CORVY", "FLIES", "AMUSE", "CWK", "SCOLL", "OSUME", "CLL"])
    #expect(parsed.waypoints.map(\.airway) == [nil, "V306", "V306", "V306", "V306", "V565", "V565", "V565"])
    #expect(parsed.waypoints.last?.kind == .navaid)
}

@Test func airwayAcrossTheDateLineExpands() throws {
    let parsed = try parse("PINSO A590 PINTT")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.ident) == ["PINSO", "POOFF", "PINTT"])
    let line = try Route(parsed).linePoints()
    for (a, b) in zip(line, line.dropFirst()) {
        #expect(abs(b.longitude - a.longitude) < 2)
    }
}

@Test func entryOrExitOffTheAirwayIsAProblem() throws {
    let entry = try parse("KAUS BITER V565 LFK")
    #expect(entry.problems == [problem(1, "BITER", .pointNotOnAirway)])
    #expect(entry.waypoints.map(\.ident) == ["KAUS", "BITER", "LFK"])
    #expect(entry.waypoints.allSatisfy { $0.airway == nil })
    #expect(throws: RouteError.hasProblems(entry.problems)) { _ = try Route(entry) }
    let exit = try parse("CWK V565 BITER")
    #expect(exit.problems == [problem(2, "BITER", .pointNotOnAirway)])
    let position = try parse("3015N09745W V565 LFK")
    #expect(position.problems == [problem(0, "3015N09745W", .pointNotOnAirway)])
}

@Test func airwayIsNotExpandedAcrossABreak() throws {
    // CWK, SCOLL | OSUME | (unplaced row) | CLL, OSCER | other location: LFK, JCT
    for text in ["CWK V999 CLL", "SCOLL V999 OSUME", "OSUME V999 CLL", "OSCER V999 LFK"] {
        let parsed = try parse(text)
        #expect(parsed.problems == [problem(1, "V999", .airwayBroken)], "\(text)")
        #expect(parsed.waypoints.count == 2, "\(text)")
        #expect(parsed.waypoints.allSatisfy { $0.airway == nil }, "\(text)")
        #expect(throws: RouteError.self) { _ = try Route(parsed) }
    }
    let whole = try parse("CWK V999 SCOLL")
    #expect(whole.problems.isEmpty)
    #expect(whole.waypoints.map(\.airway) == [nil, "V999"])
    #expect(try parse("CWK V565 CWK").problems == [problem(1, "V565", .airwayBroken)])
}

@Test func airwayNeedsAPointOnEachSide() throws {
    #expect(try parse("V565 CWK KLFK").problems == [problem(0, "V565", .airwayWithoutPoint)])
    #expect(try parse("KAUS CWK V565").problems == [problem(2, "V565", .airwayWithoutPoint)])
    // CWK is the only point V565 and V306 share, and the route starts on it.
    #expect(try parse("CWK V565 V306 JCT").problems == [problem(1, "V565", .airwayBroken)])
    #expect(try parse("CWK DCT V565").problems == [problem(2, "V565", .airwayWithoutPoint)])
}

@Test func unknownTokensAreReportedAndNeverGuessed() throws {
    let parsed = try parse("KAUS NOPE1 N0120A050 KCLL")
    #expect(parsed.problems == [problem(1, "NOPE1", .unknownIdentifier), problem(2, "N0120A050", .unknownIdentifier)])
    #expect(parsed.waypoints.map(\.ident) == ["KAUS", "KCLL"])
    #expect(throws: RouteError.hasProblems(parsed.problems)) { _ = try Route(parsed) }
}

@Test func malformedPositionsAreReportedAsSuch() throws {
    #expect(try parse("KAUS 3075N09745W KCLL").problems == [problem(1, "3075N09745W", .malformedCoordinate)])
    #expect(try parse("KAUS 95.0/-97 KCLL").problems == [problem(1, "95.0/-97", .malformedCoordinate)])
}

@Test func positionsBecomeUserWaypoints() throws {
    let parsed = try parse("KAUS 3015N09745W 301530n0974500w 30.4/-97.2 KCLL")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.kind) == [.airport, .user, .user, .user, .airport])
    #expect(parsed.waypoints[1].coordinate == Coordinate(latitude: 30.25, longitude: -97.75))
    #expect(parsed.waypoints[1].ident == "3015N09745W")
    #expect(parsed.waypoints[2].coordinate == Coordinate(latitude: 30.258333, longitude: -97.75))
    #expect(parsed.waypoints[3].coordinate == Coordinate(latitude: 30.4, longitude: -97.2))
}

@Test func repeatedIdentifierResolvesToTheNearestAndListsTheOthers() throws {
    let parsed = try parse("KAUS BR BITER KCLL")
    #expect(parsed.problems.isEmpty)
    let chosen = parsed.waypoints[1]
    #expect(chosen.name == "DEPOO")
    #expect(Geo.distanceNM(from: parsed.waypoints[0].coordinate, to: chosen.coordinate) < RouteParser.ambiguityLimitNM)
    #expect(parsed.alternatives.count == 1)
    #expect(parsed.alternatives.first?.waypointIndex == 1)
    #expect(parsed.alternatives.first?.position == 1)
    #expect(parsed.alternatives.first?.choices.map(\.name) == ["LAREW", "BURNS"])
    // With nothing before it, the first token is judged against the next one.
    #expect(try parse("BR KAUS").waypoints.first?.name == "DEPOO")
}

@Test func airportWinsAtTheEndsAndTheNavaidInTheMiddle() throws {
    let ends = try parse("CLL CWK LFK")
    #expect(ends.waypoints.map(\.ident) == ["KCLL", "CWK", "KLFK"])
    #expect(ends.waypoints.map(\.kind) == [.airport, .navaid, .airport])
    #expect(ends.alternatives.map { $0.choices.map(\.kind) } == [[.navaid], [.navaid]])
    // The airport is the nearer of the two from the east and the farther from the west.
    for text in ["KAUS CLL KLFK", "KLFK CLL KAUS"] {
        let middle = try parse(text)
        #expect(middle.waypoints[1].kind == .navaid, "\(text)")
        #expect(middle.waypoints[1].coordinate == Coordinate(latitude: 30.60500172, longitude: -96.42068075), "\(text)")
        #expect(middle.alternatives.first?.choices.map(\.ident) == ["KCLL"], "\(text)")
    }
    #expect(try parse("KAUS KCLL KLFK").waypoints[1].kind == .airport)
}

@Test func testSignalsAreNeverChosenOrOffered() throws {
    for text in ["KAUS SAT KCLL", "2900N09830W SAT KAUS"] {
        let parsed = try parse(text)
        #expect(parsed.problems.isEmpty, "\(text)")
        #expect(parsed.waypoints[1].coordinate == Coordinate(latitude: 29.64403, longitude: -98.4613158), "\(text)")
        #expect(parsed.alternatives.first?.choices.map(\.kind) == [.airport], "\(text)")
    }
}

@Test func farAirportLosesToANearMatchAtTheEndOfARoute() throws {
    let parsed = try parse("KAUS CWK ZZT")
    let last = try #require(parsed.waypoints.last)
    #expect(last.kind == .navaid)
    #expect(Geo.distanceNM(from: parsed.waypoints[1].coordinate, to: last.coordinate) < RouteParser.ambiguityLimitNM)
    #expect(parsed.alternatives.last?.choices.map(\.kind) == [.airport])
    // An airport inside the limit still wins at the end, even when the navaid is nearer.
    #expect(try parse("KAUS CWK CLL").waypoints.last?.kind == .airport)
}

@Test func routeTextReadsBackToTheSameRoute() throws {
    let texts = ["KAUS CWK V565 LFK KLFK", "LFK V565 CWK", "JCT V306 CWK V565 CLL", "KAUS CLL KLFK",
                 "KAUS BR BITER KCLL", "KAUS 3015N09745W 30.251235/-97.7534 KCLL", "KAUS CWK ZZT",
                 "PINSO A590 PINTT", "KAUS CWK V565 CLL V565 LFK",
                 // Out and back along one airway: each stretch has to be written.
                 "CWK V565 LFK V565 CWK", "KAUS CWK V565 LFK V565 CLL KCLL", "CWK V565 LFK V565 CLL",
                 "CWK V565 CLL V565 CWK", "KAUS CWK V565 LFK V565 OSUME KCLL"]
    for text in texts {
        let route = try Route(parse(text))
        let again = try Route(parse(route.routeText))
        #expect(again == route, "\(text) became \(route.routeText)")
        #expect(try route.textReadsBack(against: routeNav, date: routeDate), "\(text)")
    }
    #expect(try Route(parse("kaus dct cwk v565 lfk klfk")).routeText == "KAUS CWK V565 LFK KLFK")
    #expect(try Route(parse("KAUS CWK V565 CLL V565 LFK")).routeText == "KAUS CWK V565 LFK")
    #expect(try Route(parse("CWK V565 LFK V565 CWK")).routeText == "CWK V565 LFK V565 CWK")
    #expect(try Route(parse("CWK V565 LFK V565 CWK")).waypoints.count == 11)
    // An edit can leave a navaid at the start with no airway beside it; the text then starts at the airport.
    let cut = try #require(try Route(parse("LFK V565 CWK")).removing(at: 1))
    #expect(cut.routeText == "LFK CLL V565 CWK")
    #expect(try !cut.textReadsBack(against: routeNav, date: routeDate))
}

@Test func revalidationReportsWaypointsThatMovedOrWentAway() throws {
    let route = try Route(parse("KAUS CWK V565 LFK KLFK 3015N09745W"))
    #expect(try route.revalidated(against: routeNav, date: routeDate).isEmpty)
    // A waypoint made from a search suggestion is the one the parser makes.
    let picked = RouteWaypoint(match: try #require(try routeNav.waypointSearch(prefix: "KAUS").first))
    #expect(picked == route.waypoints[0])
    let changed = try NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL + """

        UPDATE fixes SET lat = lat + 0.01 WHERE ident = 'SCOLL';
        UPDATE fixes SET lat = lat + 0.001 WHERE ident = 'OSUME';
        DELETE FROM navaids WHERE ident = 'LFK';
        """))
    let report = try route.revalidated(against: changed, date: routeDate)
    try #require(report.count == 2)
    #expect(report.map(\.index) == [2, 6])
    #expect(report.map(\.waypoint.ident) == ["SCOLL", "LFK"])
    // 0.01 degrees of latitude is 0.6 nm; the 0.001 degree move of OSUME is under the 0.1 nm limit.
    if case .moved(let distance) = report[0].kind {
        #expect(abs(distance - 0.6) < 0.01)
    } else {
        Issue.record("expected SCOLL to be reported as moved")
    }
    #expect(report[1].kind == .missing)
}

@Test func revalidationReportsAnAirwayThatGainedAPointOrABreak() throws {
    let route = try Route(parse("KAUS CWK V565 LFK KLFK"))
    // A new bend between OSUME and CLL, and a break after OSCER.
    let changed = try NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL + """

        INSERT INTO fixes(id, ident, state, lat, lon, use, charts) VALUES (201, 'NEWBD', 'TX', 31.2, -96.5, 'RP', 'ENROUTE LOW');
        INSERT INTO airway_points(airway, location, seq, point, point_type, lat, lon, gap, mea) VALUES ('V565', 'C', 35, 'NEWBD', 'RP', 31.2, -96.5, 0, 5000);
        UPDATE airway_points SET gap = 1 WHERE airway = 'V565' AND point = 'OSCER';
        """))
    let report = try route.revalidated(against: changed, date: routeDate)
    #expect(report.map(\.index) == [4, 6])
    #expect(report.map(\.waypoint.ident) == ["CLL", "LFK"])
    #expect(report.allSatisfy { $0.kind == .airwayChanged })
}

@Test func tooShortTextNeverMakesARoute() throws {
    #expect(throws: RouteError.tooFewWaypoints) { _ = try Route(parse("")) }
    #expect(throws: RouteError.tooFewWaypoints) { _ = try Route(parse("KAUS")) }
    #expect(throws: RouteError.tooFewWaypoints) { _ = try Route(parse("DCT dct")) }
}
