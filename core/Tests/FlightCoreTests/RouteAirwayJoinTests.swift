import Foundation
import Testing
@testable import FlightCore

/// Invented rows. V901 and V902 share thirty points in one stretch. V903 and V904 cross at thirty
/// points, and each has a point of its own between one crossing and the next.
private let chainSQL: String = {
    var fixes: [String] = []
    var points: [String] = []
    func fix(_ ident: String, _ lat: Double, _ lon: Double, on airways: String...) {
        fixes.append("(\(9200 + fixes.count), '\(ident)', 'TX', \(lat), \(lon), 'RP', 'ENROUTE LOW')")
        for airway in airways {
            points.append("('\(airway)', 'C', \(points.count), '\(ident)', 'RP', \(lat), \(lon), 0, NULL)")
        }
    }
    func name(_ prefix: String, _ n: Int) -> String {
        prefix + String(UnicodeScalar(UInt8(65 + n / 26))) + String(UnicodeScalar(UInt8(65 + n % 26)))
    }
    fix("QBEG", 35, -100, on: "V901")
    fix("RBEG", 37, -100, on: "V903")
    for n in 0..<30 {
        let lon = -99.9 + 0.1 * Double(n)
        fix(name("QA", n), 35, lon, on: "V901", "V902")
        fix(name("RA", n), 37, lon, on: "V903", "V904")
        if n < 29 {
            fix(name("RN", n), 37.2, lon + 0.05, on: "V903")
            fix(name("RS", n), 36.8, lon + 0.05, on: "V904")
        }
    }
    fix("QEND", 35, -96.9, on: "V901")
    fix("REND", 37, -96.9, on: "V903")
    return """

        INSERT INTO fixes(id, ident, state, lat, lon, use, charts) VALUES \(fixes.joined(separator: ","));
        INSERT INTO airway_points(airway, location, seq, point, point_type, lat, lon, gap, mea) VALUES
          \(points.joined(separator: ","));
        """
}()

/// Invented rows: V998 follows V565 from OSUME to OSCER, V997 crosses V565 at SCOLL and at OSCER,
/// and V905 meets V906 at QMZ, a beacon and a range two tenths of a mile apart.
private let joinNav = try! NavDatabase(path: makeNavDatabase(extraSQL: routeNavSQL + chainSQL + """

    INSERT INTO navaids(id, ident, type, name, city, state, lat, lon, elev, freq, chan, magvar, status) VALUES
      (9101, 'QMZ', 'NDB', 'INVENTED BEACON', 'NOWHERE', 'TX', 31.0, -96.0, NULL, '254', NULL, NULL, 'OPERATIONAL IFR'),
      (9102, 'QMZ', 'VOR/DME', 'INVENTED RANGE', 'NOWHERE', 'TX', 31.0027, -95.9985, 30.0, '110.6', '43X', '4E', 'OPERATIONAL IFR');
    INSERT INTO fixes(id, ident, state, lat, lon, use, charts) VALUES
      (9103, 'QWA', 'TX', 31.0, -97.0, 'RP', 'ENROUTE LOW'),
      (9104, 'QEA', 'TX', 31.0, -95.0, 'RP', 'ENROUTE LOW');
    INSERT INTO airway_points(airway, location, seq, point, point_type, lat, lon, gap, mea) VALUES
      ('V905', 'C', 10, 'QWA', 'RP', 31.0, -97.0, 0, NULL),
      ('V905', 'C', 20, 'QMZ', 'VOR/DME', 31.0027, -95.9985, 0, NULL),
      ('V906', 'C', 10, 'QMZ', 'VOR/DME', 31.0027, -95.9985, 0, NULL),
      ('V906', 'C', 20, 'QEA', 'RP', 31.0, -95.0, 0, NULL),
      ('V998', 'C', 10, 'OSUME', 'RP', 30.54841388, -96.70280555, 0, NULL),
      ('V998', 'C', 20, 'CLL', 'VORTAC', 30.60500172, -96.42068075, 0, NULL),
      ('V998', 'C', 30, 'OSCER', 'RP', 30.79231666, -95.85780833, 0, NULL),
      ('V998', 'C', 40, 'BITER', 'WP', 30.11251388, -97.07993055, 0, NULL),
      ('V997', 'C', 10, 'SCOLL', 'RP', 30.44515555, -97.20874166, 0, NULL),
      ('V997', 'C', 20, 'BITER', 'WP', 30.11251388, -97.07993055, 0, NULL),
      ('V997', 'C', 30, 'OSCER', 'RP', 30.79231666, -95.85780833, 0, NULL),
      ('V997', 'C', 40, 'ZZT', 'NDB', 30.0, -97.0, 0, NULL);
    """))

private func parse(_ text: String) throws -> RouteParse {
    try RouteParser.parse(text, database: joinNav, date: routeDate)
}

private func meetTwice(_ position: Int, _ token: String) -> [RouteProblem] {
    [RouteProblem(position: position, token: token, kind: .airwaysMeetMoreThanOnce)]
}

@Test func twoAirwaysInARowJoinAtThePointTheyShare() throws {
    let parsed = try parse("JCT V306 V565 LFK")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.ident) == ["JCT", "CORVY", "FLIES", "AMUSE", "CWK", "SCOLL", "OSUME", "CLL",
                                              "OSCER", "LFK"])
    #expect(parsed.waypoints.map(\.airway) == [nil, "V306", "V306", "V306", "V306", "V565", "V565", "V565", "V565",
                                               "V565"])
    // The junction was not typed, so it is not offered as a token with other meanings.
    #expect(!parsed.alternatives.contains { $0.position == 2 })
    // The same waypoints as the text with the junction typed, and DCT between the airways changes nothing.
    #expect(try parse("JCT V306 CWK V565 LFK").waypoints == parsed.waypoints)
    #expect(try parse("jct v306 dct v565 lfk").waypoints == parsed.waypoints)
}

@Test func airwaysThatShareAStretchJoinWithoutTurningBack() throws {
    // V565 and V998 share OSUME, CLL and OSCER. Every junction gives the same places, so the nearest names the legs.
    let west = try parse("CWK V565 V998 BITER")
    #expect(west.problems.isEmpty)
    #expect(west.waypoints.map(\.ident) == ["CWK", "SCOLL", "OSUME", "CLL", "OSCER", "BITER"])
    #expect(west.waypoints.map(\.airway) == [nil, "V565", "V565", "V998", "V998", "V998"])
    let east = try parse("LFK V565 V998 BITER")
    #expect(east.problems.isEmpty)
    #expect(east.waypoints.map(\.ident) == ["LFK", "OSCER", "BITER"])
    #expect(east.waypoints.map(\.airway) == [nil, "V565", "V998"])
    // A route that starts on the shared stretch goes on from there. It never flies out to OSUME and back.
    let onBoth = try parse("CLL V565 V998 BITER")
    #expect(onBoth.problems.isEmpty)
    #expect(onBoth.waypoints.map(\.ident) == ["CLL", "OSCER", "BITER"])
    #expect(onBoth.waypoints.map(\.airway) == [nil, "V565", "V998"])
    #expect(try parse("CLL V565 OSCER V998 BITER").waypoints == onBoth.waypoints)
    let first = try parse("OSUME V565 V998 BITER")
    #expect(first.problems.isEmpty)
    #expect(first.waypoints.map(\.ident) == ["OSUME", "CLL", "OSCER", "BITER"])
    #expect(first.waypoints.map(\.airway) == [nil, "V565", "V998", "V998"])
    // Three airways in a row.
    let three = try parse("JCT V306 V565 V998 BITER")
    #expect(three.problems.isEmpty)
    #expect(three.waypoints.map(\.ident) == ["JCT", "CORVY", "FLIES", "AMUSE", "CWK", "SCOLL", "OSUME", "CLL",
                                             "OSCER", "BITER"])
}

@Test func airwaysThatMeetTwiceNeedTheJunctionTyped() throws {
    // V565 and V997 cross at SCOLL and at OSCER, and the two ways between pass different places.
    for text in ["CWK V565 V997 ZZT", "OSUME V565 V997 ZZT"] {
        let parsed = try parse(text)
        #expect(parsed.problems == meetTwice(2, "V997"), "\(text)")
        #expect(throws: RouteError.hasProblems(parsed.problems), "\(text)") { _ = try Route(parsed) }
    }
    let back = try parse("ZZT V997 V565 OSUME")
    #expect(back.problems == meetTwice(2, "V565"))
    #expect(throws: RouteError.self) { _ = try Route(back) }
    // With the junction typed, each way is a route.
    let near = try parse("OSUME V565 SCOLL V997 ZZT")
    let far = try parse("OSUME V565 OSCER V997 ZZT")
    #expect(near.problems.isEmpty && far.problems.isEmpty)
    #expect(near.waypoints.map(\.ident) == ["OSUME", "SCOLL", "BITER", "OSCER", "ZZT"])
    #expect(far.waypoints.map(\.ident) == ["OSUME", "CLL", "OSCER", "ZZT"])
    // In a chain the problem is on the airway whose junction is in doubt.
    let chain = try parse("JCT V306 V565 V997 ZZT")
    #expect(chain.problems == meetTwice(3, "V997"))
    #expect(throws: RouteError.self) { _ = try Route(chain) }
    // Only one crossing goes on to LFK without passing OSCER twice.
    let one = try parse("ZZT V997 V565 LFK")
    #expect(one.problems.isEmpty)
    #expect(one.waypoints.map(\.ident) == ["ZZT", "OSCER", "LFK"])
    #expect(one.waypoints.map(\.airway) == [nil, "V997", "V565"])
}

@Test func aSharedPointAcrossABreakIsNotTheJunction() throws {
    // V999 reaches JCT only from LFK, so the nearer points it shares with V565 cannot be where the route changes.
    let parsed = try parse("CWK V565 V999 JCT")
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.map(\.ident) == ["CWK", "SCOLL", "OSUME", "CLL", "OSCER", "LFK", "JCT"])
    #expect(parsed.waypoints.map(\.airway) == [nil, "V565", "V565", "V565", "V565", "V565", "V999"])
    #expect(try parse("CWK V565 LFK V999 JCT").waypoints == parsed.waypoints)
    // The other way the break is on the first airway. CWK is the nearest shared point, and V999 cannot reach it.
    let back = try parse("JCT V999 V565 CWK")
    #expect(back.problems.isEmpty)
    #expect(back.waypoints.map(\.ident) == ["JCT", "LFK", "OSCER", "CLL", "OSUME", "SCOLL", "CWK"])
    #expect(try parse("JCT V999 LFK V565 CWK").waypoints == back.waypoints)
}

@Test func airwaysThatShareNoPointAreAProblemAndNeverARoute() throws {
    let parsed = try parse("CWK V565 A590 PINTT")
    #expect(parsed.problems == [RouteProblem(position: 2, token: "A590", kind: .airwaysDoNotMeet)])
    #expect(parsed.waypoints.map(\.ident) == ["CWK", "PINTT"])
    #expect(parsed.waypoints.allSatisfy { $0.airway == nil })
    #expect(throws: RouteError.hasProblems(parsed.problems)) { _ = try Route(parsed) }
    // The only shared point is the one the route starts on, so none of the first airway would be flown.
    let none = try parse("CWK V565 V306 JCT")
    #expect(none.problems == [RouteProblem(position: 1, token: "V565", kind: .airwayBroken)])
    #expect(throws: RouteError.self) { _ = try Route(none) }
    // From OSCER every other shared point lies behind, and V998 comes back through OSCER.
    let behind = try parse("OSCER V565 V998 BITER")
    #expect(behind.problems == [RouteProblem(position: 1, token: "V565", kind: .airwayBroken)])
    #expect(throws: RouteError.self) { _ = try Route(behind) }
    // A chain of airways still needs a point at each end.
    #expect(try parse("V565 V306 JCT").problems.map(\.kind) == [.airwayWithoutPoint, .airwayWithoutPoint])
    #expect(try parse("CWK V565 V306").problems == [RouteProblem(position: 2, token: "V306", kind: .airwayWithoutPoint)])
}

@Test func aChainThatOnlyJoinsByPassingAPlaceTwiceIsNeverARoute() throws {
    // Every way round ends back on SCOLL, so no junction is picked for the pilot.
    let parsed = try parse("SCOLL V565 V998 V997 SCOLL")
    #expect(parsed.problems == meetTwice(2, "V998"))
    #expect(throws: RouteError.self) { _ = try Route(parsed) }
    #expect(try parse("SCOLL V565 OSUME V998 BITER V997 SCOLL").problems.isEmpty)
}

@Test func aJunctionWithTwoRecordsIsChosenAsIfItHadBeenTyped() throws {
    for (text, typed) in [("QWA V905 V906 QEA", "QWA V905 QMZ V906 QEA"),
                          ("QEA V906 V905 QWA", "QEA V906 QMZ V905 QWA")] {
        let parsed = try parse(text)
        #expect(parsed.problems.isEmpty, "\(text)")
        #expect(try parse(typed).waypoints == parsed.waypoints, "\(text)")
        let route = try Route(parsed)
        #expect(route.routeText == typed, "\(text)")
        #expect(try route.textReadsBack(against: joinNav, date: routeDate), "\(text)")
    }
    // The record nearest the previous waypoint, from either side.
    #expect(try parse("QWA V905 V906 QEA").waypoints.map(\.name) == ["QWA", "INVENTED BEACON", "QEA"])
    #expect(try parse("QEA V906 V905 QWA").waypoints.map(\.name) == ["QEA", "INVENTED RANGE", "QWA"])
}

@Test func aLongSharedStretchChainedFiveTimesIsReadQuickly() throws {
    _ = try parse("QBEG QEND")
    let start = Date()
    let parsed = try parse("QBEG V901 V902 V901 V902 V901 QEND")
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(parsed.problems.isEmpty)
    #expect(parsed.waypoints.count == 32)
    #expect(parsed.waypoints.prefix(6).map(\.airway) == [nil, "V901", "V902", "V901", "V902", "V901"])
    let route = try Route(parsed)
    #expect(route.routeText == "QBEG V901 QAAA V902 QAAB V901 QAAC V902 QAAD V901 QEND")
    #expect(try route.textReadsBack(against: joinNav, date: routeDate))
}

@Test func airwaysThatCrossInManyPlacesChainedAreRefusedQuickly() throws {
    _ = try parse("RBEG REND")
    // Five airways have tens of thousands of ways through, and nine have millions.
    for text in ["RBEG V903 V904 V903 V904 V903 REND", "RBEG V903 V904 V903 V904 V903 V904 V903 V904 V903 REND"] {
        let start = Date()
        let parsed = try parse(text)
        #expect(Date().timeIntervalSince(start) < 1, "\(text)")
        let airways = text.split(separator: " ").dropFirst(2).dropLast().map(String.init)
        #expect(parsed.problems == airways.enumerated().flatMap { meetTwice($0.offset + 2, $0.element) }, "\(text)")
        #expect(throws: RouteError.hasProblems(parsed.problems), "\(text)") { _ = try Route(parsed) }
    }
    // With every junction typed the same airways are a route.
    #expect(try parse("RBEG V903 RAAA V904 RAAD V903 RAAG V904 RAAJ V903 REND").problems.isEmpty)
}

@Test func joinedAirwaysWriteTheJunctionAndReadBack() throws {
    let written = ["JCT V306 V565 LFK": "JCT V306 CWK V565 LFK",
                   "CWK V565 V998 BITER": "CWK V565 OSUME V998 BITER",
                   "LFK V565 V998 BITER": "LFK V565 OSCER V998 BITER",
                   "CLL V565 V998 BITER": "CLL V565 OSCER V998 BITER",
                   "CWK V565 V999 JCT": "CWK V565 LFK V999 JCT",
                   "ZZT V997 V565 LFK": "ZZT V997 OSCER V565 LFK",
                   "JCT V306 V565 V998 BITER": "JCT V306 CWK V565 OSUME V998 BITER"]
    for (text, expected) in written {
        let route = try Route(parse(text))
        #expect(route.routeText == expected, "\(text)")
        #expect(try Route(parse(route.routeText)) == route, "\(text)")
        #expect(try route.textReadsBack(against: joinNav, date: routeDate), "\(text)")
    }
}
