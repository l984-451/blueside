import Foundation
import Testing
@testable import FlightCore

private let fixTime = ISO8601DateFormatter().date(from: "2026-10-13T18:00:00Z")!

private func waypoint(_ ident: String, _ latitude: Double, _ longitude: Double) -> RouteWaypoint {
    RouteWaypoint(kind: .fix, ident: ident, name: ident, coordinate: Coordinate(latitude: latitude, longitude: longitude))
}

private func fix(_ latitude: Double, _ longitude: Double, knots: Double? = 120, age: TimeInterval = 1,
                 track: Double = 90) -> Position {
    Position(latitude: latitude, longitude: longitude, courseDegrees: track,
             speedMetersPerSecond: knots.map { $0 / 1.943844 } ?? -1, altitudeMeters: 1500,
             timestamp: fixTime.addingTimeInterval(-age))!
}

/// East along the equator for one degree, then north for one degree.
private let corner = Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("C", 1, 1)],
                           navCycle: "2026-10-01")!

@Test func progressGivesDistancesBearingsAndTimes() throws {
    let position = fix(0.1, 0.5)
    let progress = try #require(corner.progress(legIndex: 0, position: position, now: fixTime))
    let b = Coordinate(latitude: 0, longitude: 1)
    let c = Coordinate(latitude: 1, longitude: 1)
    let toNext = Geo.distanceNM(from: position.coordinate, to: b)
    #expect(progress.legIndex == 0)
    #expect(abs(progress.distanceToNextNM - toNext) < 1e-9)
    #expect(abs(progress.distanceToDestinationNM - (toNext + Geo.distanceNM(from: b, to: c))) < 1e-9)
    #expect(abs(progress.bearingToNextTrue - Geo.initialBearing(from: position.coordinate, to: b)) < 1e-9)
    #expect(progress.bearingToNextTrue > 95 && progress.bearingToNextTrue < 110)
    let variation = MagneticModel.declination(at: position.coordinate, altitudeFt: position.altitudeFtMSL ?? 0, date: fixTime)
    #expect(abs(progress.bearingToNextMagnetic - RouteMath.normalized(progress.bearingToNextTrue - variation)) < 1e-9)
    let speed = try #require(position.groundspeedKt)
    #expect(abs((progress.timeToNext ?? 0) - toNext / speed * 3600) < 1e-6)
    #expect(abs((progress.timeToDestination ?? 0) - progress.distanceToDestinationNM / speed * 3600) < 1e-6)
}

@Test func crossTrackIsPositiveRightOfCourse() throws {
    // One tenth of a degree is 6.004 nm.
    let left = try #require(corner.progress(legIndex: 0, position: fix(0.1, 0.5), now: fixTime))
    let right = try #require(corner.progress(legIndex: 0, position: fix(-0.1, 0.5), now: fixTime))
    #expect(abs((left.crossTrackNM ?? 0) + 6.004) < 0.01)
    #expect(abs((right.crossTrackNM ?? 0) - 6.004) < 0.01)
    // Northbound on the second leg, east is right of course.
    let east = try #require(corner.progress(legIndex: 1, position: fix(0.5, 1.1), now: fixTime))
    #expect(abs((east.crossTrackNM ?? 0) - 6.004) < 0.01)
}

@Test func staleOrMissingPositionGivesNothing() {
    #expect(corner.progress(legIndex: 0, position: nil, now: fixTime) == nil)
    #expect(corner.progress(legIndex: 0, position: fix(0.1, 0.5, age: 6), now: fixTime) == nil)
    #expect(corner.progress(legIndex: 0, position: fix(0.1, 0.5, age: -6), now: fixTime) == nil)
    #expect(corner.progress(legIndex: 2, position: fix(0.1, 0.5), now: fixTime) == nil)
    #expect(corner.progress(legIndex: -1, position: fix(0.1, 0.5), now: fixTime) == nil)
    #expect(corner.progress(legIndex: .max, position: fix(0.1, 0.5), now: fixTime) == nil)
    // A starting leg is not chosen from an old fix either.
    #expect(corner.initialLeg(for: nil, now: fixTime) == nil)
    #expect(corner.initialLeg(for: fix(0.1, 0.5, age: 6), now: fixTime) == nil)
    #expect(corner.initialLeg(for: fix(0.1, 0.5, age: -6), now: fixTime) == nil)
}

@Test func legSequencesWhenTheTurnIsBegunBeforeTheWaypoint() throws {
    // A right angle bend cut inside the corner: never abeam the waypoint on the old leg.
    #expect(corner.advanced(legIndex: 0, position: fix(0.02, 0.9), now: fixTime) == 0)
    #expect(corner.advanced(legIndex: 0, position: fix(0.2, 0.995, track: 0), now: fixTime) == 1)
    // East for one degree, then a 120 degree left turn onto a track of 330.
    let sharp = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("C", 0.866, 0.5)],
                                   navCycle: "2026-10-01"))
    #expect(sharp.advanced(legIndex: 0, position: fix(0, 0.9), now: fixTime) == 0)
    #expect(sharp.advanced(legIndex: 0, position: fix(0.02, 0.9), now: fixTime) == 0)
    // Established on the centreline of the second leg, well short of abeam on the first.
    #expect(sharp.advanced(legIndex: 0, position: fix(0.0866, 0.95, track: 330), now: fixTime) == 1)
    #expect(sharp.advanced(legIndex: 0, position: fix(0.433, 0.75, track: 330), now: fixTime) == 1)
}

@Test func sharpTurnDoesNotSequenceFarShortOfTheWaypoint() throws {
    // East 40 nm, then back to a point 5 nm north of the start: a 173 degree left turn.
    let hairpin = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 0.6667), waypoint("C", 0.0833, 0)],
                                     navCycle: "2026-10-01"))
    // Still eastbound, left of course: 20 nm short, then just after departure.
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.025, 0.3333), now: fixTime) == 0)
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.05, 0.0167), now: fixTime) == 0)
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.0167, 0.5), now: fixTime) == 0)
    // No track known: the same positions still hold the leg.
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.025, 0.3333, track: -1), now: fixTime) == 0)
    // Tracking across the leg just after departure, or standing still: the leg holds.
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.05, 0.03, track: 350), now: fixTime) == 0)
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.05, 0.03, track: 200), now: fixTime) == 0)
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.05, 0.03, knots: 0, track: 300), now: fixTime) == 0)
    // Turned onto the way back, or past the waypoint: sequenced.
    #expect(hairpin.advanced(legIndex: 0, position: fix(0.02, 0.63, track: 277), now: fixTime) == 1)
    #expect(hairpin.advanced(legIndex: 0, position: fix(0, 0.68), now: fixTime) == 1)
    // A 150 degree turn, 10 nm short and 3 nm left, still eastbound.
    let sharp = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("C", 0.5, 0.134)],
                                   navCycle: "2026-10-01"))
    #expect(sharp.advanced(legIndex: 0, position: fix(0.05, 0.8333), now: fixTime) == 0)
}

@Test func outAndBackDoesNotSequenceBeforeTheTurnPoint() throws {
    let back = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("A2", 0, 0)],
                                  navCycle: "2026-10-01"))
    #expect(back.advanced(legIndex: 0, position: fix(0.01, 0.5), now: fixTime) == 0)
    #expect(back.advanced(legIndex: 0, position: fix(-0.01, 0.5), now: fixTime) == 0)
    #expect(back.advanced(legIndex: 0, position: fix(0, 0.99), now: fixTime) == 0)
    #expect(back.advanced(legIndex: 0, position: fix(0, 1.01), now: fixTime) == 1)
}

@Test func slowOrUnknownGroundspeedGivesDistancesWithoutTimes() throws {
    let speeds: [Double?] = [29, 0, nil]
    for knots in speeds {
        let progress = try #require(corner.progress(legIndex: 0, position: fix(0.1, 0.5, knots: knots), now: fixTime))
        #expect(progress.timeToNext == nil && progress.timeToDestination == nil)
        #expect(progress.distanceToNextNM > 30 && progress.distanceToDestinationNM > 90)
        #expect(progress.bearingToNextTrue.isFinite && progress.bearingToNextMagnetic.isFinite)
    }
    let moving = try #require(corner.progress(legIndex: 0, position: fix(0.1, 0.5, knots: 31), now: fixTime))
    #expect(moving.timeToNext != nil && moving.timeToDestination != nil)
}

@Test func firstLegIsTheClosestOneTheAircraftIsAbeam() {
    #expect(corner.initialLeg(for: fix(0.05, 0.5), now: fixTime) == 0)
    #expect(corner.initialLeg(for: fix(0.5, 1.05), now: fixTime) == 1)
    #expect(corner.initialLeg(for: fix(0.3, 0.9), now: fixTime) == 1)
    // Abeam no leg: the leg that ends at the nearest waypoint.
    #expect(corner.initialLeg(for: fix(-0.5, -0.5), now: fixTime) == 0)
    #expect(corner.initialLeg(for: fix(1.5, 1.2), now: fixTime) == 1)
}

@Test func startingAtTheFirstWaypointPicksTheFirstLeg() throws {
    // A zigzag whose fourth leg passes abeam the start.
    let zigzag = try #require(Route(waypoints: [waypoint("A", 30, -97), waypoint("B", 30, -96), waypoint("C", 30.2, -96.9),
                                                waypoint("D", 30.4, -96), waypoint("E", 30.6, -96.9)],
                                    navCycle: "2026-10-01"))
    var leg = try #require(zigzag.initialLeg(for: fix(30, -97, knots: 0), now: fixTime))
    #expect(leg == 0)
    // Flown down the line, each leg comes up in turn.
    for index in 1...3 {
        let from = zigzag.waypoints[index].coordinate
        let to = zigzag.waypoints[index + 1].coordinate
        let here = RouteMath.intermediate(from: from, to: to, fraction: 0.1)
        let position = fix(here.latitude, here.longitude, track: Geo.initialBearing(from: here, to: to))
        leg = zigzag.advanced(legIndex: leg, position: position, now: fixTime)
        #expect(leg == index)
    }
    // A round robin: the leg home ends at the start and passes closer to the ramp than the first leg.
    let triangle = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("C", 1, 0.5),
                                                  waypoint("A2", 0, 0)],
                                      navCycle: "2026-10-01"))
    #expect(triangle.initialLeg(for: fix(0, 0, knots: 0), now: fixTime) == 0)
    for (latitude, longitude) in [(0.003, 0.003), (0.003, -0.003), (-0.003, 0.003), (-0.003, -0.003)] {
        #expect(triangle.initialLeg(for: fix(latitude, longitude, knots: 0), now: fixTime) == 0)
    }
    // Just behind the start, abeam only the second leg 27 nm away.
    let dogleg = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("C", -1, -1)],
                                    navCycle: "2026-10-01"))
    #expect(dogleg.initialLeg(for: fix(0, -0.005, knots: 0), now: fixTime) == 0)
}

@Test func outAndBackStartsOnTheLegTheTrackFollows() throws {
    let back = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("B", 0, 1), waypoint("A2", 0, 0)],
                                  navCycle: "2026-10-01"))
    #expect(back.initialLeg(for: fix(0.02, 0.6, track: 270), now: fixTime) == 1)
    #expect(back.initialLeg(for: fix(0.02, 0.98, track: 270), now: fixTime) == 1)
    #expect(back.initialLeg(for: fix(0.02, 0.6, track: 90), now: fixTime) == 0)
    // No track, or too slow for the track to mean anything: the earlier leg.
    #expect(back.initialLeg(for: fix(0.02, 0.6, track: -1), now: fixTime) == 0)
    #expect(back.initialLeg(for: fix(0.02, 0.6, knots: 5, track: 270), now: fixTime) == 0)
    // Homebound on the second leg: it holds, north of track is right of course, and the start lies ahead.
    let homebound = fix(0.02, 0.4, track: 270)
    #expect(back.advanced(legIndex: 1, position: homebound, now: fixTime) == 1)
    let progress = try #require(back.progress(legIndex: 1, position: homebound, now: fixTime))
    #expect((progress.crossTrackNM ?? 0) > 0)
    #expect(progress.bearingToNextTrue > 260 && progress.bearingToNextTrue < 280)
}

@Test func legAdvancesOnlyForwardAndOnlyOncePastAbeam() {
    #expect(corner.advanced(legIndex: 0, position: fix(0, 0.5), now: fixTime) == 0)
    #expect(corner.advanced(legIndex: 0, position: fix(0.05, 1.01), now: fixTime) == 1)
    #expect(corner.advanced(legIndex: 1, position: fix(1.2, 1), now: fixTime) == 1)
    #expect(corner.advanced(legIndex: 1, position: fix(0, 0.2), now: fixTime) == 1)
    #expect(corner.advanced(legIndex: 0, position: fix(0.05, 1.01, age: 6), now: fixTime) == 0)
    #expect(corner.advanced(legIndex: 0, position: nil, now: fixTime) == 0)
    #expect(corner.advanced(legIndex: 7, position: fix(0, 0.5), now: fixTime) == 1)
    #expect(corner.advanced(legIndex: -3, position: fix(0, 0.5), now: fixTime) == 0)
}

@Test func progressWorksAcrossTheDateLine() throws {
    let route = try #require(Route(waypoints: [waypoint("W", 52, 179), waypoint("E", 52, -179), waypoint("F", 53, -178)],
                                   navCycle: "2026-10-01"))
    let position = fix(52.1, 179.9)
    let progress = try #require(route.progress(legIndex: 0, position: position, now: fixTime))
    // Eastbound across the line with the aircraft six miles north of track: left of course, 41 nm to run.
    let cross = try #require(progress.crossTrackNM)
    #expect(cross < -4 && cross > -7)
    #expect(progress.distanceToNextNM > 35 && progress.distanceToNextNM < 45)
    #expect(progress.bearingToNextTrue > 80 && progress.bearingToNextTrue < 110)
    #expect(route.initialLeg(for: position, now: fixTime) == 0)
    #expect(route.advanced(legIndex: 0, position: fix(52.0, -178.9), now: fixTime) == 1)
    #expect(route.advanced(legIndex: 0, position: fix(52.0, 179.9), now: fixTime) == 0)
}

@Test func progressNeverReturnsNaN() throws {
    let stacked = try #require(Route(waypoints: [waypoint("A", 0, 0), waypoint("A2", 0, 0), waypoint("B", 0, 1)],
                                     navCycle: "2026-10-01"))
    let onTop = try #require(stacked.progress(legIndex: 0, position: fix(0, 0), now: fixTime))
    #expect(onTop.crossTrackNM == nil)
    #expect(onTop.distanceToNextNM == 0)
    #expect(onTop.bearingToNextTrue.isFinite && onTop.bearingToNextMagnetic.isFinite)
    #expect(onTop.timeToNext == 0)
    #expect(stacked.advanced(legIndex: 0, position: fix(0, 0), now: fixTime) == 1)
    var odd = fix(0.1, 0.5)
    odd.groundspeedKt = .nan
    let noSpeed = try #require(corner.progress(legIndex: 0, position: odd, now: fixTime))
    #expect(noSpeed.timeToNext == nil && noSpeed.timeToDestination == nil)
    odd.coordinate = Coordinate(latitude: .nan, longitude: 0)
    #expect(corner.progress(legIndex: 0, position: odd, now: fixTime) == nil)
    #expect(corner.initialLeg(for: odd, now: fixTime) == nil)
    #expect(corner.advanced(legIndex: 0, position: odd, now: fixTime) == 0)
}
