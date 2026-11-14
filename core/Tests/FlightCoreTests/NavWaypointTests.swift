import Foundation
import Testing
@testable import FlightCore

/// Rows for the lookup and route tests. Real positions from FAA cycle 2026-10-01, except ZZT and V999, which are invented.
let routeNavSQL = """
    INSERT INTO airports(id, site_no, ident, icao, name, city, state, type, use, lat, lon, elev, magvar, tpa, twr, fuel, artcc, status) VALUES
      (101, 'T1', 'CLL', 'KCLL', 'EASTERWOOD FLD', 'COLLEGE STATION', 'TX', 'A', 'PU', 30.58804188, -96.36254444, 320.0, '4E', NULL, 'ATCT', NULL, 'ZHU', 'O'),
      (102, 'T2', 'LFK', 'KLFK', 'ANGELINA COUNTY', 'LUFKIN', 'TX', 'A', 'PU', 31.23402777, -94.75, 296.0, '3E', NULL, 'NON-ATCT', NULL, 'ZHU', 'O'),
      (103, 'T3', 'SAT', 'KSAT', 'SAN ANTONIO INTL', 'SAN ANTONIO', 'TX', 'A', 'PU', 29.53395833, -98.46905694, 809.0, '4E', NULL, 'ATCT', NULL, 'ZHU', 'O'),
      (104, 'T4', 'ZZT', NULL, 'INVENTED FAR FIELD', 'NOWHERE', 'AK', 'A', 'PU', 64.0, -150.0, 500.0, NULL, NULL, 'NON-ATCT', NULL, 'ZAN', 'O');
    INSERT INTO navaids(id, ident, type, name, city, state, lat, lon, elev, freq, chan, magvar, status) VALUES
      (101, 'CLL', 'VORTAC', 'COLLEGE STATION', 'COLLEGE STATION', 'TX', 30.60500172, -96.42068075, 264.0, '113.3', '80X', '8E', 'OPERATIONAL RESTRICTED'),
      (102, 'LFK', 'VORTAC', 'LUFKIN', 'LUFKIN', 'TX', 31.16244188, -94.71683261, 207.0, '112.1', '58X', '5E', 'OPERATIONAL RESTRICTED'),
      (103, 'JCT', 'VORTAC', 'JUNCTION', 'JUNCTION', 'TX', 30.59802113, -99.817481, 2282.0, '116', '107X', '8E', 'OPERATIONAL RESTRICTED'),
      (104, 'SAT', 'VOT', 'SAN ANTONIO', 'SAN ANTONIO', 'TX', 29.53361944, -98.46998888, 810.0, '110.4', NULL, NULL, 'OPERATIONAL IFR'),
      (105, 'BR', 'NDB', 'DEPOO', 'BROWNSVILLE', 'TX', 25.98366283, -97.50909794, NULL, '393', NULL, NULL, 'OPERATIONAL IFR'),
      (106, 'BR', 'NDB', 'LAREW', 'BRAINERD', 'MN', 46.4566203, -94.02243002, NULL, '251', NULL, NULL, 'OPERATIONAL IFR'),
      (107, 'BR', 'NDB', 'BURNS', 'BURLINGTON', 'IA', 40.65435738, -91.12322608, NULL, '390', NULL, NULL, 'OPERATIONAL IFR'),
      (108, 'XCR', 'NDB', 'RIPLEY', 'LITTLE FALLS', 'MN', 46.07922555, -94.34347555, NULL, '397', NULL, NULL, 'SHUTDOWN'),
      (109, 'ZZT', 'NDB', 'INVENTED NEAR BEACON', 'NOWHERE', 'TX', 30.0, -97.0, NULL, '300', NULL, NULL, 'OPERATIONAL IFR');
    INSERT INTO fixes(id, ident, state, lat, lon, use, charts) VALUES
      (101, 'SCOLL', 'TX', 30.44515555, -97.20874166, 'RP', 'ENROUTE LOW'),
      (102, 'OSUME', 'TX', 30.54841388, -96.70280555, 'RP', 'ENROUTE LOW'),
      (103, 'OSCER', 'TX', 30.79231666, -95.85780833, 'RP', 'ENROUTE LOW'),
      (104, 'CORVY', 'TX', 30.50037777, -98.74630833, 'RP', 'ENROUTE LOW'),
      (105, 'FLIES', 'TX', 30.48138611, -98.54894444, 'RP', 'ENROUTE LOW'),
      (106, 'AMUSE', 'TX', 30.45644722, -98.29418888, 'RP', 'ENROUTE LOW'),
      (107, 'PINSO', 'AK', 53.534475, 173.54752222, 'RP', 'ENROUTE HIGH'),
      (108, 'POOFF', 'AK', 55.32343897, 178.72708686, 'RP', 'ENROUTE HIGH'),
      (109, 'PINTT', 'AK', 56.8232668, -175.88053911, 'RP', 'ENROUTE HIGH');
    INSERT INTO airway_points(airway, location, seq, point, point_type, lat, lon, gap, mea) VALUES
      ('V565', 'C', 10, 'CWK', 'VORTAC', 30.37855, -97.52984722, 0, 2400),
      ('V565', 'C', 20, 'SCOLL', 'RP', 30.44515555, -97.20874166, 0, 2400),
      ('V565', 'C', 30, 'OSUME', 'RP', 30.54841388, -96.70280555, 0, 2400),
      ('V565', 'C', 40, 'CLL', 'VORTAC', 30.60500172, -96.42068075, 0, 4000),
      ('V565', 'C', 50, 'OSCER', 'RP', 30.79231666, -95.85780833, 0, 4000),
      ('V565', 'C', 60, 'LFK', 'VORTAC', 31.16244188, -94.71683261, 0, 4000),
      ('V306', 'C', 10, 'JCT', 'VORTAC', 30.59802113, -99.817481, 0, 7000),
      ('V306', 'C', 20, 'CORVY', 'RP', 30.50037777, -98.74630833, 0, 7000),
      ('V306', 'C', 30, 'FLIES', 'RP', 30.48138611, -98.54894444, 0, 7000),
      ('V306', 'C', 40, 'AMUSE', 'RP', 30.45644722, -98.29418888, 0, 3300),
      ('V306', 'C', 50, 'CWK', 'VORTAC', 30.37855, -97.52984722, 0, 2400),
      ('A590', 'A', 40, 'PINSO', 'RP', 53.534475, 173.54752222, 0, NULL),
      ('A590', 'A', 50, 'POOFF', 'RP', 55.32343897, 178.72708686, 0, NULL),
      ('A590', 'A', 60, 'PINTT', 'RP', 56.8232668, -175.88053911, 0, NULL),
      ('V999', 'C', 10, 'CWK', 'VORTAC', 30.37855, -97.52984722, 0, NULL),
      ('V999', 'C', 20, 'SCOLL', 'RP', 30.44515555, -97.20874166, 1, NULL),
      ('V999', 'C', 30, 'OSUME', 'RP', 30.54841388, -96.70280555, 0, NULL),
      ('V999', 'C', 40, 'U.S. MEXICAN BORDER-2', NULL, NULL, NULL, 0, NULL),
      ('V999', 'C', 50, 'CLL', 'VORTAC', 30.60500172, -96.42068075, 0, NULL),
      ('V999', 'C', 60, 'OSCER', 'RP', 30.79231666, -95.85780833, 0, NULL),
      ('V999', 'H', 10, 'LFK', 'VORTAC', 31.16244188, -94.71683261, 0, NULL),
      ('V999', 'H', 20, 'JCT', 'VORTAC', 30.59802113, -99.817481, 0, NULL);
    """

/// One read-only database on the sample rows plus the rows above, shared by the route tests.
let routeNav = try! NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL))

@Test func navaidLookupReturnsEveryMatch() throws {
    let found = try routeNav.navaids(ident: " br ")
    #expect(found.map(\.state) == ["TX", "MN", "IA"])
    #expect(found.allSatisfy { $0.ident == "BR" && $0.type == "NDB" })
    #expect(try routeNav.navaids(ident: "NOPE").isEmpty)
}

@Test func navaidKeepsItsStatusAndStillResolves() throws {
    let ripley = try #require(try routeNav.navaids(ident: "XCR").first)
    #expect(ripley.status == "SHUTDOWN")
    #expect(ripley.isShutDown)
    #expect(ripley.isRoutePoint)
    let centex = try #require(try routeNav.navaids(ident: "CWK").first)
    #expect(!centex.isShutDown)
    #expect(centex.coordinate == Coordinate(latitude: 30.37855, longitude: -97.52984722))
    #expect(centex.frequency == "112.8")
}

@Test func testSignalsAreReturnedButAreNotRoutePoints() throws {
    let found = try routeNav.navaids(ident: "SAT")
    #expect(found.map(\.type) == ["VORTAC", "VOT"])
    #expect(found.map(\.isRoutePoint) == [true, false])
}

@Test func fixLookupReturnsTheFix() throws {
    let found = try routeNav.fixes(ident: "scoll")
    #expect(found.count == 1)
    #expect(found.first?.coordinate == Coordinate(latitude: 30.44515555, longitude: -97.20874166))
    #expect(found.first?.use == "RP")
    #expect(try routeNav.fixes(ident: "CWK").isEmpty)
}

@Test func airwayComesBackAsOneRunInOrder() throws {
    let runs = try routeNav.airway(named: "v565")
    #expect(runs.count == 1)
    #expect(runs.first?.location == "C")
    #expect(runs.first?.points.map(\.ident) == ["CWK", "SCOLL", "OSUME", "CLL", "OSCER", "LFK"])
    #expect(runs.first?.points.first?.meaFt == 2400)
    #expect(try routeNav.airway(named: "V1").isEmpty)
}

@Test func airwayRunsEndAtGapsUnplacedRowsAndLocationChanges() throws {
    let runs = try routeNav.airway(named: "V999")
    #expect(runs.map { $0.points.map(\.ident) } == [["CWK", "SCOLL"], ["OSUME"], ["CLL", "OSCER"], ["LFK", "JCT"]])
    #expect(runs.map(\.location) == ["C", "C", "C", "H"])
}

@Test func waypointSearchPutsExactIdentifiersFirst() throws {
    let found = try routeNav.waypointSearch(prefix: "s")
    #expect(found.map(\.ident) == ["SAT", "SAT", "SCOLL"])
    #expect(found.map(\.kind) == [.airport, .navaid, .fix])
    let exact = try routeNav.waypointSearch(prefix: "CWK")
    #expect(exact.map(\.kind) == [.navaid])
    let both = try routeNav.waypointSearch(prefix: "CL")
    #expect(both.map(\.kind) == [.airport, .navaid])
    #expect(both.first?.icao == "KCLL")
}

@Test func waypointSearchFindsAirportsByIcaoCodeAndLeavesOutTestSignals() throws {
    let byIcao = try routeNav.waypointSearch(prefix: "KAU")
    #expect(byIcao.map(\.ident) == ["AUS"])
    let sat = try routeNav.waypointSearch(prefix: "SAT")
    #expect(sat.count == 2)
    #expect(sat.contains { $0.kind == .navaid && $0.name == "SAN ANTONIO" })
}

@Test func waypointSearchHonoursTheLimitAndRejectsOddText() throws {
    #expect(try routeNav.waypointSearch(prefix: "S", limit: 2).count == 2)
    #expect(try routeNav.waypointSearch(prefix: "S", limit: 0).isEmpty)
    #expect(try routeNav.waypointSearch(prefix: "").isEmpty)
    #expect(try routeNav.waypointSearch(prefix: "%").isEmpty)
    #expect(try routeNav.waypointSearch(prefix: "S_").isEmpty)
}

@Test func waypointsNearAPointComeClosestFirstWithinTheRadius() throws {
    let vortac = Coordinate(latitude: 30.60500172, longitude: -96.42068075)
    let found = try routeNav.waypoints(near: vortac, withinNM: 20)
    #expect(found.map { "\($0.kind.rawValue) \($0.ident)" } == ["navaid CLL", "airport CLL", "fix OSUME"])
    #expect(try routeNav.waypoints(near: vortac, withinNM: 0.1).map(\.ident) == ["CLL"])
    // The test signal beside San Antonio is left out.
    let sat = Coordinate(latitude: 29.53395833, longitude: -98.46905694)
    #expect(try routeNav.waypoints(near: sat, withinNM: 1).map(\.kind) == [.airport])
}
