import Foundation
import Testing
@testable import FlightCore

private func place(_ kind: WaypointKind, _ ident: String) -> WaypointMatch {
    WaypointMatch(kind: kind, ident: ident, name: ident, coordinate: Coordinate(latitude: 30, longitude: -97))
}

@Suite struct MapPickTests {
    @Test func hereListsWhatIsUnderTheFingerClosestFirstAndEachPlaceOnce() {
        let hits: [(WaypointMatch, Double)] = [
            (place(.airport, "EDC"), 15), (place(.navaid, "CWK"), 4), (place(.fix, "BITER"), 21),
            // A symbol drawn in two tiles comes back twice; an airport and a navaid can share an identifier.
            (place(.navaid, "CWK"), 9), (place(.airport, "CWK"), 12),
        ]
        #expect(MapPick.here(hits).map { "\($0.kind.rawValue) \($0.ident)" }
                == ["navaid CWK", "airport CWK", "airport EDC", "fix BITER"])
        #expect(MapPick.here([]).isEmpty)
    }

    @Test func aReleasedBandSnapsToTheNearestOrAsksAmongTies() {
        #expect(MapPick.snap([]) == .open)
        #expect(MapPick.snap([(place(.fix, "A"), 3), (place(.fix, "B"), 10)]) == .one(place(.fix, "A")))
        #expect(MapPick.snap([(place(.fix, "A"), 3), (place(.fix, "B"), 7)]) == .choose([place(.fix, "A"), place(.fix, "B")]))
    }

    @Test func aHeldFingerGrabsADotFirstThenALeg() {
        let points = [ScreenPoint(x: 0, y: 0), ScreenPoint(x: 100, y: 0), ScreenPoint(x: 200, y: 0)]
        #expect(MapPick.grab(points, firstDot: 1, at: ScreenPoint(x: 95, y: 10)) == .point(1))
        #expect(MapPick.grab(points, firstDot: 1, at: ScreenPoint(x: 5, y: 5)) == .leg(0))
        #expect(MapPick.grab(points, firstDot: 0, at: ScreenPoint(x: 5, y: 5)) == .point(0))
        #expect(MapPick.grab(points, firstDot: 1, at: ScreenPoint(x: 150, y: 21)) == .leg(1))
        #expect(MapPick.grab(points, firstDot: 1, at: ScreenPoint(x: 150, y: 30)) == nil)
    }

    @Test func rulerReadsDistanceMagneticBearingAndTimeAtGroundspeed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = Coordinate(latitude: 30, longitude: -97)
        let b = Coordinate(latitude: 31, longitude: -97)
        let bearing = NavText.bearing(Geo.initialBearing(from: a, to: b), from: a, date: now)
        // 120 knots over about 60 NM.
        let moving = Position(latitude: 30, longitude: -97, courseDegrees: 0, speedMetersPerSecond: 61.7333,
                              altitudeMeters: nil, timestamp: now)!
        #expect(NavText.ruler(from: a, to: b, position: moving, now: now) == "60.0 NM · \(bearing) · 0:30")
        // No time with no fix, a stale fix, or a groundspeed of 30 knots or less.
        #expect(NavText.ruler(from: a, to: b, position: nil, now: now) == "60.0 NM · \(bearing)")
        #expect(NavText.ruler(from: a, to: b, position: moving, now: now.addingTimeInterval(10)) == "60.0 NM · \(bearing)")
        let taxiing = Position(latitude: 30, longitude: -97, courseDegrees: 0, speedMetersPerSecond: 15,
                               altitudeMeters: nil, timestamp: now)!
        #expect(NavText.ruler(from: a, to: b, position: taxiing, now: now) == "60.0 NM · \(bearing)")
    }
}
