import Foundation
import Testing
@testable import FlightCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func point(_ ident: String, _ latitude: Double, _ longitude: Double) -> RouteWaypoint {
    RouteWaypoint(kind: .fix, ident: ident, name: ident, coordinate: Coordinate(latitude: latitude, longitude: longitude))
}

private func fix(_ longitude: Double, knots: Double = 120, at time: Date = t0) -> Position? {
    Position(latitude: 0, longitude: longitude, courseDegrees: 90, speedMetersPerSecond: knots / 1.943844,
             altitudeMeters: nil, timestamp: time)
}

private func eastbound() throws -> RoutePlan {
    RoutePlan(route: try #require(Route(waypoints: [point("A", 0, 0), point("B", 0, 1), point("C", 0, 2)],
                                        navCycle: "2026-10-01")))
}

private func step(showing: LiveLeg.Shown? = nil, sent: Date? = nil, plan: RoutePlan?, position: Position?,
                  approximate: Bool = false, until: Date? = t0 + 300, inFront: Bool = true,
                  now: Date = t0) -> LiveLeg.Step? {
    LiveLeg.step(showing: showing, sent: sent, plan: plan, position: position, approximate: approximate,
                 until: until, inFront: inFront, now: now)
}

@Suite struct LiveLegTests {
    @Test func showsWhatTheDrawersActiveRowShows() throws {
        var plan = try eastbound()
        let direct = RoutePlan.direct(to: point("C", 0, 2), navCycle: "2026-10-01")
        for route in [plan, direct] {
            let rows = route.rows(position: fix(0.4), now: t0, trueAirspeedKt: nil)
            let row = try #require(rows.first { $0.isActive })
            let shown = try #require(LiveLeg.shown(route, position: fix(0.4), now: t0))
            #expect(shown.ident == row.waypoint.ident)
            #expect(shown.distance == row.distance)
            let arrival = try #require(shown.arrival)
            #expect(NavText.duration(arrival.timeIntervalSince(t0)) == row.time)
        }
        // Past B the next leg's waypoint shows.
        plan.advance(position: fix(1.05), now: t0)
        #expect(LiveLeg.shown(plan, position: fix(1.05), now: t0)?.ident == "C")
    }

    @Test func needsALiveExactFixAndFlyingSpeedForATime() throws {
        let plan = try eastbound()
        #expect(LiveLeg.shown(plan, position: nil, now: t0) == nil)
        #expect(LiveLeg.shown(plan, position: fix(0.4, at: t0 - 30), now: t0) == nil)
        #expect(LiveLeg.shown(plan, position: fix(0.4), approximate: true, now: t0) == nil)
        let slow = try #require(LiveLeg.shown(plan, position: fix(0.4, knots: 20), now: t0))
        #expect(slow.distance == "36.0 NM")
        #expect(slow.arrival == nil)
    }

    @Test func startsInTheFrontAtFlyingSpeedWithARoute() throws {
        let plan = try eastbound()
        let shown = try #require(LiveLeg.shown(plan, position: fix(0.4), now: t0))
        #expect(step(plan: plan, position: fix(0.4)) == .start(shown))
        #expect(step(plan: plan, position: fix(0.4), inFront: false) == nil)
        #expect(step(plan: plan, position: fix(0.4, knots: 25)) == nil)
        #expect(step(plan: plan, position: fix(0.4), approximate: true) == nil)
        #expect(step(plan: nil, position: fix(0.4)) == nil)
        // A start the system refused is asked again only after the update interval.
        #expect(step(sent: t0 - 5, plan: plan, position: fix(0.4)) == nil)
        #expect(step(sent: t0 - 15, plan: plan, position: fix(0.4)) == .start(shown))
    }

    @Test func updatesOnANewLegAtOnceAndOtherwiseEveryFifteenSecondsOnANewDistance() throws {
        var plan = try eastbound()
        let showing = try #require(LiveLeg.shown(plan, position: fix(0.4), now: t0))
        let moved = try #require(LiveLeg.shown(plan, position: fix(0.5, at: t0 + 5), now: t0 + 5))
        #expect(step(showing: showing, sent: t0, plan: plan, position: fix(0.5, at: t0 + 5), now: t0 + 5) == nil)
        #expect(step(showing: showing, sent: t0 - 10, plan: plan, position: fix(0.5, at: t0 + 5), now: t0 + 5)
                == .update(moved))
        // The same distance text is not sent again, and a lost fix keeps the last values.
        #expect(step(showing: showing, sent: t0 - 30, plan: plan, position: fix(0.4)) == nil)
        #expect(step(showing: showing, sent: t0 - 30, plan: plan, position: fix(0.4, at: t0 - 30)) == nil)
        plan.advance(position: fix(1.05), now: t0)
        let next = try #require(LiveLeg.shown(plan, position: fix(1.05), now: t0))
        #expect(step(showing: showing, sent: t0 - 1, plan: plan, position: fix(1.05)) == .update(next))
        // Out of the front it still updates.
        #expect(step(showing: showing, sent: t0 - 1, plan: plan, position: fix(1.05), inFront: false) == .update(next))
    }

    @Test func endsWithNoRouteOnTheGroundAtTheRoutesEndOrWhenTheAppWouldStop() throws {
        var plan = try eastbound()
        let showing = try #require(LiveLeg.shown(plan, position: fix(0.4), now: t0))
        #expect(step(showing: showing, sent: t0 - 30, plan: nil, position: fix(0.4)) == .end)
        #expect(step(showing: showing, sent: t0 - 30, plan: plan, position: nil, until: t0, inFront: false) == .end)
        #expect(step(showing: showing, sent: t0 - 30, plan: plan, position: nil, until: nil) == .end)
        // Slow near a waypoint that is not the last does not end it.
        #expect(step(showing: showing, sent: t0, plan: plan, position: fix(0.99, knots: 10)) == nil)
        plan.advance(position: fix(1.05), now: t0)
        let last = try #require(LiveLeg.shown(plan, position: fix(1.5), now: t0))
        #expect(step(showing: last, sent: t0, plan: plan, position: fix(1.99, knots: 10)) == .end)
        // Still flying over the last waypoint, it stays.
        #expect(step(showing: last, sent: t0, plan: plan, position: fix(1.99)) == nil)
        // With nothing running there is nothing to end.
        #expect(step(plan: nil, position: nil) == nil)
    }
}
