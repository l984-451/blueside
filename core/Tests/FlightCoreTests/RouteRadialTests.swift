import Foundation
import Testing
@testable import FlightCore

/// The route rows plus invented stations: one with west variation, one whose variation cannot be read,
/// and a Texas airport that shares its identifier with a navaid far offshore.
private let radialNav = try! NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL + """

    INSERT INTO navaids(id, ident, type, name, city, state, lat, lon, elev, freq, chan, magvar, status) VALUES
      (301, 'WWV', 'VOR/DME', 'INVENTED WEST', 'NOWHERE', 'ME', 44.0, -70.0, 300.0, '114.5', '92X', '12W', 'OPERATIONAL IFR'),
      (302, 'QQV', 'VOR/DME', 'INVENTED UNREADABLE', 'NOWHERE', 'TX', 31.0, -98.0, 900.0, '115.5', '102X', 'EAST', 'OPERATIONAL IFR'),
      (303, 'PPV', 'VOR/DME', 'INVENTED OFFSHORE', 'NOWHERE', NULL, 18.5, -68.4, 40.0, '116.5', '112X', '13W', 'OPERATIONAL IFR'),
      (304, 'BBN', 'NDB', 'INVENTED OLD BEACON', 'NOWHERE', 'AL', 33.0, -88.0, NULL, '350', NULL, '7E', 'OPERATIONAL IFR'),
      (305, 'DDV', 'VOR/DME', 'INVENTED PAIR', 'NOWHERE', 'TX', 30.4, -97.0, 500.0, '117.5', '122X', '6E', 'OPERATIONAL IFR'),
      (306, 'DDV', 'NDB', 'INVENTED PAIR', 'NOWHERE', 'TX', 30.40333, -97.0, NULL, '360', NULL, '6E', 'OPERATIONAL IFR'),
      (307, 'FFV', 'VOR/DME', 'INVENTED FAR NORTH', 'NOWHERE', 'ME', 44.5, -70.0, 300.0, '113.5', '82X', '15W', 'OPERATIONAL IFR'),
      (308, 'FFV', 'NDB', 'INVENTED FAR SOUTH', 'NOWHERE', 'TX', 31.5, -97.5, NULL, '370', NULL, '4E', 'OPERATIONAL IFR');
    INSERT INTO airports(id, site_no, ident, icao, name, city, state, type, use, lat, lon, elev, magvar, tpa, twr, fuel, artcc, status) VALUES
      (301, 'T9', 'PPV', NULL, 'INVENTED NEAR FIELD', 'NOWHERE', 'TX', 'A', 'PU', 31.0, -96.0, 400.0, NULL, NULL, 'NON-ATCT', NULL, 'ZHU', 'O');
    """))

private func parse(_ text: String) throws -> RouteParse {
    try RouteParser.parse(text, database: radialNav, date: routeDate)
}

private let cll = Coordinate(latitude: 30.60500172, longitude: -96.42068075)
private let biter = Coordinate(latitude: 30.11251388, longitude: -97.07993055)

/// The angle between two directions, from 0 to 180.
private func bearingGap(_ a: Double, _ b: Double) -> Double {
    abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
}

@Test func destinationUndoesDistanceAndBearing() throws {
    let start = Coordinate(latitude: 0, longitude: 0)
    let east = try #require(Geo.destination(from: start, bearingTrue: 90, distanceNM: 60))
    #expect(abs(east.latitude) < 1e-9 && abs(east.longitude - 60 / Geo.earthRadiusNM * 180 / .pi) < 1e-9)
    for (bearing, distance) in [(0.0, 5.0), (98.0, 20.0), (183.5, 150.0), (271.0, 999.0), (359.0, 1.0)] {
        let point = try #require(Geo.destination(from: cll, bearingTrue: bearing, distanceNM: distance))
        #expect(abs(Geo.distanceNM(from: cll, to: point) - distance) < 1e-6, "\(bearing)")
        #expect(bearingGap(Geo.initialBearing(from: cll, to: point), bearing) < 1e-6, "\(bearing)")
    }
    // Across the 180 degree meridian the longitude stays between -180 and 180.
    let across = try #require(Geo.destination(from: Coordinate(latitude: 0, longitude: 179.5), bearingTrue: 90,
                                              distanceNM: 60))
    #expect(across.longitude < -179 && across.longitude > -180)
    #expect(Geo.destination(from: cll, bearingTrue: .nan, distanceNM: 10) == nil)
    #expect(Geo.destination(from: cll, bearingTrue: 90, distanceNM: .infinity) == nil)
}

@Test func aRadialFromANavaidUsesTheNavaidsPublishedVariation() throws {
    let parsed = try parse("KAUS CLL090020 KLFK")
    #expect(parsed.problems.isEmpty)
    let point = parsed.waypoints[1]
    #expect(point.kind == .user && point.ident == "CLL090020" && point.name == "CLL090020" && point.airway == nil)
    #expect(abs(Geo.distanceNM(from: cll, to: point.coordinate) - 20) < 0.01)
    // College Station is aligned to 8 degrees east. The present-day model is more than a degree from that.
    #expect(bearingGap(Geo.initialBearing(from: cll, to: point.coordinate), 98) < 0.01)
    let model = MagneticModel.declination(at: cll, altitudeFt: 0, date: routeDate)
    #expect(abs(8 - model) >= 1)
    #expect(bearingGap(Geo.initialBearing(from: cll, to: point.coordinate), 90 + model) >= 1)
    // West variation is taken off: radial 360 from a station at 12 west points to 348 true.
    let station = Coordinate(latitude: 44.0, longitude: -70.0)
    let west = try parse("KAUS WWV360015 KLFK").waypoints[1]
    #expect(bearingGap(Geo.initialBearing(from: station, to: west.coordinate), 348) < 0.01)
    let zero = try parse("KAUS WWV000015 KLFK").waypoints[1]
    #expect(Geo.distanceNM(from: zero.coordinate, to: west.coordinate) < 0.001)
}

@Test func aRadialFromAnyOtherFixUsesTheModelAtTheFix() throws {
    let parsed = try parse("KAUS BITER180010 KCLL")
    #expect(parsed.problems.isEmpty)
    let point = parsed.waypoints[1]
    let model = MagneticModel.declination(at: biter, altitudeFt: 0, date: routeDate)
    #expect(point.kind == .user && point.ident == "BITER180010")
    #expect(abs(Geo.distanceNM(from: biter, to: point.coordinate) - 10) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: biter, to: point.coordinate), 180 + model) < 0.01)
    // A beacon with no published variation is read by compass, so it takes the model too.
    let beacon = Coordinate(latitude: 30.0, longitude: -97.0)
    let fromBeacon = try parse("KAUS ZZT045010 KCLL").waypoints[1]
    let there = MagneticModel.declination(at: beacon, altitudeFt: 0, date: routeDate)
    #expect(abs(Geo.distanceNM(from: beacon, to: fromBeacon.coordinate) - 10) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: beacon, to: fromBeacon.coordinate), 45 + there) < 0.01)
    // An airport can be the station.
    let field = try #require(try radialNav.airport(identifier: "KAUS")).coordinate
    let fromField = try parse("KCLL KAUS270005 KLFK").waypoints[1]
    #expect(abs(Geo.distanceNM(from: field, to: fromField.coordinate) - 5) < 0.01)
    // The model moves with the date, and the point moves with it.
    let later = try RouteParser.parse("KAUS BITER180010 KCLL", database: radialNav,
                                      date: routeDate.addingTimeInterval(3 * 365 * 86400))
    #expect(later.waypoints[1].coordinate != point.coordinate)
}

@Test func aRadialFromABeaconUsesTheModelEvenWhenAVariationIsPublished() throws {
    // A beacon sends no direction of its own, so its published figure, here years old, is not used.
    let beacon = Coordinate(latitude: 33.0, longitude: -88.0)
    let model = MagneticModel.declination(at: beacon, altitudeFt: 0, date: routeDate)
    #expect(abs(7 - model) >= 5)
    let parsed = try parse("KAUS BBN090050 KLFK")
    #expect(parsed.problems.isEmpty)
    let point = parsed.waypoints[1]
    #expect(abs(Geo.distanceNM(from: beacon, to: point.coordinate) - 50) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: beacon, to: point.coordinate), 90 + model) < 0.01)
    // It needs the model, so a date the model does not cover is a problem, never a route.
    let date = try #require(ISO8601DateFormatter().date(from: "2031-01-01T00:00:00Z"))
    let late = try RouteParser.parse("KAUS BBN090050 KLFK", database: radialNav, date: date)
    #expect(late.problems == [RouteProblem(position: 1, token: "BBN090050", kind: .badRadialDistance)])
    #expect(throws: RouteError.hasProblems(late.problems)) { _ = try Route(late) }
}

@Test func aRadialFromABeaconBesideAVorOfTheSameNameIsMeasuredFromTheVor() throws {
    // A VOR/DME aligned to 6 east with a beacon of the same name 0.2 nm north of it.
    let station = Coordinate(latitude: 30.4, longitude: -97.0)
    let model = MagneticModel.declination(at: station, altitudeFt: 0, date: routeDate)
    #expect(abs(6 - model) >= 2)
    let east = try parse("KAUS DDV090020 KCLL")
    let west = try parse("KCLL DDV090020 KAUS")
    #expect(east.problems.isEmpty && west.problems.isEmpty)
    // One point whichever way the route is flown, and no second reading offered.
    #expect(east.waypoints[1] == west.waypoints[1])
    #expect(east.alternatives.isEmpty && west.alternatives.isEmpty)
    let point = east.waypoints[1]
    #expect(abs(Geo.distanceNM(from: station, to: point.coordinate) - 20) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: station, to: point.coordinate), 96) < 0.01)
    // The VOR's variation is published, so the model's years do not matter.
    let date = try #require(ISO8601DateFormatter().date(from: "2031-01-01T00:00:00Z"))
    let late = try RouteParser.parse("KAUS DDV090020 KCLL", database: radialNav, date: date)
    #expect(late.problems.isEmpty && late.waypoints[1] == point)

    // A beacon far from the VOR that shares its name is still its own station, read with the model.
    let beacon = Coordinate(latitude: 31.5, longitude: -97.5)
    let there = MagneticModel.declination(at: beacon, altitudeFt: 0, date: routeDate)
    let far = try parse("KAUS FFV180010 KCLL")
    #expect(far.problems.isEmpty && far.alternatives.map(\.choices.count) == [1])
    #expect(abs(Geo.distanceNM(from: beacon, to: far.waypoints[1].coordinate) - 10) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: beacon, to: far.waypoints[1].coordinate), 180 + there) < 0.01)
}

@Test func aRadialFromASharedIdentifierUsesTheStationNearTheRoute() throws {
    let field = Coordinate(latitude: 31.0, longitude: -96.0)
    let offshore = Coordinate(latitude: 18.5, longitude: -68.4)
    let bare = try parse("KAUS PPV KLFK")
    #expect(bare.waypoints[1].kind == .airport && bare.waypoints[1].coordinate == field)

    // The radial is measured from the same station the bare identifier means, with the model there.
    let parsed = try parse("KAUS PPV090020 KLFK")
    #expect(parsed.problems.isEmpty)
    let point = parsed.waypoints[1]
    let model = MagneticModel.declination(at: field, altitudeFt: 0, date: routeDate)
    #expect(point.kind == .user && point.ident == "PPV090020")
    #expect(abs(Geo.distanceNM(from: field, to: point.coordinate) - 20) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: field, to: point.coordinate), 90 + model) < 0.01)
    // The far navaid is offered, at its published 13 degrees west.
    try #require(parsed.alternatives.count == 1)
    #expect(parsed.alternatives[0].waypointIndex == 1 && parsed.alternatives[0].position == 1)
    let other = try #require(parsed.alternatives[0].choices.first)
    #expect(parsed.alternatives[0].choices.count == 1 && other.ident == "PPV090020")
    #expect(abs(Geo.distanceNM(from: offshore, to: other.coordinate) - 20) < 0.01)
    #expect(bearingGap(Geo.initialBearing(from: offshore, to: other.coordinate), 77) < 0.01)
    let route = try Route(parsed)
    #expect(try route.textReadsBack(against: radialNav, date: routeDate))
    for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) {
        #expect(Geo.distanceNM(from: a.coordinate, to: b.coordinate) < 200)
    }

    // Whichever station is nearer wins: the Alaska airfield from the Aleutians, the Texas beacon from Austin.
    let alaska = Coordinate(latitude: 64.0, longitude: -150.0)
    let north = try parse("PINSO ZZT045010 POOFF")
    #expect(abs(Geo.distanceNM(from: alaska, to: north.waypoints[1].coordinate) - 10) < 0.01)
    #expect(north.alternatives.map(\.choices.count) == [1])
    #expect(try parse("KAUS ZZT045010 KCLL").alternatives.map(\.choices.count) == [1])

    // An airport beside its own navaid is the same station, so nothing else is offered.
    #expect(try parse("KAUS CLL090020 KLFK").alternatives.isEmpty)
}

@Test func aRadialThatNeedsTheModelIsAProblemOnADateTheModelDoesNotCover() throws {
    let published = try parse("KAUS CLL090020 KLFK").waypoints[1]
    for text in ["2031-01-01T00:00:00Z", "2045-01-01T00:00:00Z", "2024-12-31T00:00:00Z"] {
        let date = try #require(ISO8601DateFormatter().date(from: text))
        #expect(!MagneticModel.covers(date))
        // A fix, a beacon with no published variation, an airport, and a name shared with a far airport.
        for token in ["BITER180010", "ZZT045010", "KAUS270005", "PPV090020"] {
            let parsed = try RouteParser.parse("KCLL \(token) KLFK", database: radialNav, date: date)
            #expect(parsed.problems == [RouteProblem(position: 1, token: token, kind: .badRadialDistance)],
                    "\(token) \(text)")
            #expect(parsed.waypoints.map(\.ident) == ["KCLL", "KLFK"], "\(token) \(text)")
            #expect(throws: RouteError.hasProblems(parsed.problems)) { _ = try Route(parsed) }
        }
        // A navaid's published variation does not come from the model, so its radials still stand.
        let parsed = try RouteParser.parse("KAUS CLL090020 KLFK", database: radialNav, date: date)
        #expect(parsed.problems.isEmpty && parsed.waypoints[1] == published, "\(text)")
    }
}

@Test func radialTokensAndVariationTextAreReadStrictly() {
    #expect(RouteText.variationDegrees("6E") == 6 && RouteText.variationDegrees("12W") == -12)
    #expect(RouteText.variationDegrees("0E") == 0)
    for text in ["", "E", "6", "6N", "EAST", "-6E", "6.5.1E", "200E", "0x10E", "1e1E", "+6E", "6.5E", "6e"] {
        #expect(RouteText.variationDegrees(text) == nil, "\(text)")
    }
    #expect(RouteText.fixRadialDistance("CLL090020")?.ident == "CLL")
    #expect(RouteText.fixRadialDistance("biter180010")?.radial == 180)
    #expect(RouteText.fixRadialDistance("KAUS270005")?.distanceNM == 5)
    for text in ["BR090020", "ABCDEF090020", "CLL09002", "CLL09O020", "090020090", "3015N09745W", "CL-090020"] {
        #expect(RouteText.fixRadialDistance(text) == nil, "\(text)")
    }
}

@Test func aRadialTokenThatCannotBePlacedIsAProblemAndNeverARoute() throws {
    let cases: [(String, RouteProblemKind)] = [
        ("CLL361020", .badRadialDistance), ("CLL090000", .badRadialDistance), ("QQV090020", .badRadialDistance),
        ("NOPEX090020", .unknownIdentifier), ("BR090020", .unknownIdentifier), ("ABCDEF090020", .unknownIdentifier),
    ]
    for (token, kind) in cases {
        let parsed = try parse("KAUS \(token) KCLL")
        #expect(parsed.problems == [RouteProblem(position: 1, token: token, kind: kind)], "\(token)")
        #expect(parsed.waypoints.map(\.ident) == ["KAUS", "KCLL"], "\(token)")
        #expect(throws: RouteError.hasProblems(parsed.problems)) { _ = try Route(parsed) }
    }
    // A point made from a radial is not on any airway.
    let beside = try parse("CLL090020 V565 LFK")
    #expect(beside.problems == [RouteProblem(position: 0, token: "CLL090020", kind: .pointNotOnAirway)])
    #expect(throws: RouteError.self) { _ = try Route(beside) }
}

@Test func radialWaypointsAreWrittenBackAsTheSameToken() throws {
    let route = try Route(parse("kaus cll090020 biter180010 klfk"))
    #expect(route.routeText == "KAUS CLL090020 BITER180010 KLFK")
    #expect(try Route(parse(route.routeText)) == route)
    #expect(try route.textReadsBack(against: radialNav, date: routeDate))
    // At either end of a route, and through a saved copy.
    let ends = try Route(parse("CLL090020 KAUS WWV360015"))
    #expect(ends.routeText == "CLL090020 KAUS WWV360015")
    #expect(try ends.textReadsBack(against: radialNav, date: routeDate))
    let saved = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
    #expect(saved == route && saved.routeText == route.routeText)
    // If the station's variation changes, the text no longer means the saved point, and the check says so.
    let realigned = try NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL + """

        UPDATE navaids SET magvar = '2E' WHERE ident = 'CLL';
        """))
    #expect(try !route.textReadsBack(against: realigned, date: routeDate))
}

@Test func aRadialPointStillReadsBackAfterTheModelHasMovedItAFewMetres() throws {
    let month = routeDate.addingTimeInterval(30 * 86400)
    for text in ["KAUS BITER180010 KLFK", "KAUS BITER180150 KLFK"] {
        let route = try Route(parse(text))
        let later = try RouteParser.parse(text, database: radialNav, date: month).waypoints[1]
        let moved = Geo.distanceNM(from: later.coordinate, to: route.waypoints[1].coordinate)
        #expect(moved > 0 && moved < 0.05, "\(text)")
        #expect(try route.textReadsBack(against: radialNav, date: month), "\(text)")
    }
    // The other station of a shared name is hundreds of miles away and is never the same point.
    let shared = try parse("KAUS PPV090020 KLFK")
    var points = shared.waypoints
    points[1] = try #require(shared.alternatives.first?.choices.first)
    let other = try #require(Route(waypoints: points, navCycle: shared.navCycle))
    #expect(other.routeText == "KAUS PPV090020 KLFK")
    #expect(try !other.textReadsBack(against: radialNav, date: routeDate))
}

/// What a saved route reports against the route rows after the given change to them.
private func report(_ route: Route, after sql: String, date: Date = routeDate) throws -> [RouteChange] {
    let changed = try NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL + "\n" + sql))
    return try route.revalidated(against: changed, date: date)
}

private func movedNM(_ change: RouteChange?) -> Double? {
    if case .moved(let distance) = change?.kind { return distance }
    return nil
}

@Test func revalidationWorksARadialPointOutAgainFromItsStation() throws {
    let route = try Route(parse("KAUS CLL090020 BITER180010 3015N09745W KLFK"))
    #expect(try route.revalidated(against: radialNav, date: routeDate).isEmpty)
    // A month of drift in the model moves the point from a fix by metres, well under the limit.
    #expect(try route.revalidated(against: radialNav, date: routeDate.addingTimeInterval(30 * 86400)).isEmpty)

    // The station realigned from 8 east to 2 east: the same text is now a point two miles away.
    let realigned = try report(route, after: "UPDATE navaids SET magvar = '2E' WHERE ident = 'CLL';")
    #expect(realigned.map(\.index) == [1] && realigned.first?.waypoint.ident == "CLL090020")
    #expect(abs((movedNM(realigned.first) ?? 0) - 2.09) < 0.01)

    // The navaid shut down: the airport of the same name is now the station, read with the model.
    let shutDown = try report(route, after: "DELETE FROM navaids WHERE ident = 'CLL';")
    #expect(shutDown.map(\.index) == [1])
    #expect(abs((movedNM(shutDown.first) ?? 0) - 3.33) < 0.01)

    // The navaid moved.
    let shifted = try report(route, after: "UPDATE navaids SET lat = lat + 0.01 WHERE ident = 'CLL';")
    #expect(shifted.map(\.index) == [1])
    #expect(abs((movedNM(shifted.first) ?? 0) - 0.6) < 0.01)

    // No station of that name is left.
    let renamed = try report(route, after: """
        UPDATE navaids SET ident = 'CLX' WHERE ident = 'CLL';
        UPDATE airports SET ident = 'CLX', icao = 'KCLX' WHERE ident = 'CLL';
        """)
    #expect(renamed.map(\.index) == [1] && renamed.first?.kind == .missing)
    let noFix = try report(route, after: "DELETE FROM fixes WHERE ident = 'BITER';")
    #expect(noFix.map(\.index) == [2] && noFix.first?.kind == .missing)
    #expect(noFix.first?.waypoint.ident == "BITER180010")

    // A date the model does not cover cannot place the point from a fix, so that point is reported.
    let late = try #require(ISO8601DateFormatter().date(from: "2031-01-01T00:00:00Z"))
    let unplaced = try route.revalidated(against: radialNav, date: late)
    #expect(unplaced.map(\.index) == [2] && unplaced.first?.kind == .missing)
}

@Test func aRadialNameOverAnotherPositionIsReportedAndDoesNotReadBack() throws {
    // The name is written as it stands, so the checks against the database are what catch a changed position.
    var points = try parse("KAUS CLL090020 KLFK").waypoints
    points[1].coordinate = Coordinate(latitude: 31.5, longitude: -96.0)
    let route = try #require(Route(waypoints: points, navCycle: "2026-10-01"))
    #expect(route.routeText == "KAUS CLL090020 KLFK")
    let found = try route.revalidated(against: radialNav, date: routeDate)
    #expect(found.map(\.index) == [1] && (movedNM(found.first) ?? 0) > 50)
    #expect(try !route.textReadsBack(against: radialNav, date: routeDate))
}
