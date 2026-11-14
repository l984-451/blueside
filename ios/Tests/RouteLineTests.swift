import FlightCore
import Foundation
import Testing
@testable import Blueside

private let fixTime = Date(timeIntervalSince1970: 1_800_000_000)
private let austin = Coordinate(latitude: 30.1945, longitude: -97.6699)
private let dallas = Coordinate(latitude: 32.8968, longitude: -97.0380)

private func fix(_ at: Coordinate) -> Position {
    Position(latitude: at.latitude, longitude: at.longitude, courseDegrees: -1, speedMetersPerSecond: -1,
             altitudeMeters: nil, timestamp: fixTime)!
}

@Suite struct RouteLineTests {
    private func target(_ at: Coordinate) -> RouteWaypoint { RouteWaypoint(kind: .airport, ident: "X", name: "", coordinate: at) }

    @Test func aDirectToStartsAtTheAircraftAndEndsAtTheAirport() throws {
        let plan = RoutePlan.direct(to: target(austin), navCycle: "")
        let drawn = try #require(RouteLine.drawn(plan, position: fix(dallas), now: fixTime.addingTimeInterval(1)))
        #expect(drawn.route.waypoints.map(\.coordinate) == [dallas, austin])
        #expect(drawn.active == 0)
        #expect(drawn.route.linePoints().count >= 9)
    }

    @Test func theLineMovesWithTheAircraft() throws {
        let plan = RoutePlan.direct(to: target(austin), navCycle: "")
        let moved = Coordinate(latitude: 32.0, longitude: -97.2)
        let second = try #require(RouteLine.drawn(plan, position: fix(moved), now: fixTime))
        #expect(second.route.waypoints[0].coordinate == moved)
    }

    @Test func noDirectLineWithNoFixAStaleFixOrNoRoute() {
        let plan = RoutePlan.direct(to: target(austin), navCycle: "")
        #expect(RouteLine.drawn(plan, position: nil, now: fixTime) == nil)
        #expect(RouteLine.drawn(plan, position: fix(dallas), now: fixTime.addingTimeInterval(6)) == nil)
        #expect(RouteLine.drawn(plan, position: fix(dallas), approximate: true, now: fixTime) == nil)
        #expect(RouteLine.drawn(nil, position: fix(dallas), now: fixTime) == nil)
        #expect(RouteLine.drawn(plan, position: fix(dallas), now: fixTime.addingTimeInterval(5)) != nil)
    }

    @Test func withNoFixARouteFromTheAircraftKeepsItsFixedLegsButNoActiveOne() throws {
        let plan = RoutePlan.appending(target(dallas), to: .direct(to: target(austin), navCycle: ""), navCycle: "")
        let drawn = try #require(RouteLine.drawn(plan, position: nil, now: fixTime))
        #expect(drawn.route.waypoints.map(\.coordinate) == [austin, dallas])
        #expect(drawn.active == nil)
    }

    @Test func aLongLineFollowsTheGreatCircle() {
        let newYork = Coordinate(latitude: 40.64, longitude: -73.78)
        let seattle = Coordinate(latitude: 47.45, longitude: -122.31)
        let path = RouteLine.path(from: newYork, to: seattle)
        // The middle of the great circle is well north of the middle of a straight chart line (about 44.0 N).
        #expect(path[path.count / 2].latitude > 46 && path[path.count / 2].latitude < 47.45)
        #expect((path.map(\.latitude).max() ?? 0) > 47.45)
        // Each step is the same length, so the line is not bunched.
        let steps = zip(path, path.dropFirst()).map { Geo.distanceNM(from: $0, to: $1) }
        #expect((steps.max() ?? 0) - (steps.min() ?? 0) < 0.5)
    }

    @Test func aLineAcrossThe180thMeridianDoesNotJump() {
        let anchorage = Coordinate(latitude: 61.17, longitude: -149.99)
        let tokyo = Coordinate(latitude: 35.55, longitude: 139.78)
        let path = RouteLine.path(from: anchorage, to: tokyo)
        let steps = zip(path, path.dropFirst()).map { abs($1.longitude - $0.longitude) }
        #expect((steps.max() ?? 999) < 5)
        // The far end keeps counting westward past 180 instead of wrapping to the east.
        #expect(abs(path[path.count - 1].longitude - (139.78 - 360)) < 1e-9)
    }

    @Test func theSamePlaceTwiceGivesTwoPoints() {
        #expect(RouteLine.path(from: austin, to: austin).count == 2)
    }
}
