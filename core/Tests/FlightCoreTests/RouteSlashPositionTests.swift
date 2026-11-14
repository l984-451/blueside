import Foundation
import Testing
@testable import FlightCore

private func parse(_ text: String) throws -> RouteParse {
    try RouteParser.parse(text, database: routeNav, date: routeDate)
}

@Test func aSlashBetweenLetteredHalvesIsAPosition() throws {
    let parsed = try parse("KAUS 3015N/09745W 301530n/0974500w 3015S/09745E KCLL")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.kind) == [.airport, .user, .user, .user, .airport])
    #expect(parsed.waypoints[1].coordinate == Coordinate(latitude: 30.25, longitude: -97.75))
    #expect(parsed.waypoints[1].ident == "3015N09745W")
    #expect(parsed.waypoints[2].coordinate == Coordinate(latitude: 30.258333, longitude: -97.75))
    #expect(parsed.waypoints[3].coordinate == Coordinate(latitude: -30.25, longitude: 97.75))
    // The same points as the forms without the slash, and the decimal form still reads.
    #expect(RouteText.coordinate("3015N/09745W") == RouteText.coordinate("3015N09745W"))
    #expect(RouteText.coordinate("301530N/0974500W") == RouteText.coordinate("301530N0974500W"))
    #expect(RouteText.coordinate("30.25/-97.75") == Coordinate(latitude: 30.25, longitude: -97.75))
}

@Test func aBadSlashedPositionIsMalformedAndNeverARoute() throws {
    let bad = ["3015N/09745", "3015/09745W", "3075N/09745W", "3015N/09775W", "3015N/0974500W", "301530N/09745W",
               "3015N//09745W", "3015N/09745W/", "/3015N09745W", "9100N/09745W", "3015N/18100W", "3015N/"]
    for token in bad {
        #expect(RouteText.coordinate(token) == nil, "\(token)")
        let parsed = try parse("KAUS \(token) KCLL")
        #expect(parsed.problems == [RouteProblem(position: 1, token: token, kind: .malformedCoordinate)], "\(token)")
        #expect(throws: RouteError.hasProblems(parsed.problems)) { _ = try Route(parsed) }
    }
}

@Test func slashedPositionsReadBack() throws {
    let route = try Route(parse("KAUS 3015N/09745W 301530N/0974500W KCLL"))
    // Written in the forms route text already uses: whole minutes run together, anything finer as decimals.
    #expect(route.routeText == "KAUS 3015N09745W 30.258333/-97.750000 KCLL")
    #expect(try Route(parse(route.routeText)) == route)
    #expect(try route.textReadsBack(against: routeNav, date: routeDate))
    #expect(try Route(parse("KAUS 3015N09745W 301530N0974500W KCLL")) == route)
}
