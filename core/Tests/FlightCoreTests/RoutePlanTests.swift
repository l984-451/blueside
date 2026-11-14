import Foundation
import Testing
@testable import FlightCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let austin = RouteWaypoint(kind: .airport, ident: "KAUS", name: "AUSTIN-BERGSTROM INTL",
                                   coordinate: Coordinate(latitude: 30.1945, longitude: -97.6699))
private let waco = RouteWaypoint(kind: .navaid, ident: "ACT", name: "WACO",
                                 coordinate: Coordinate(latitude: 31.6624, longitude: -97.2690))
private let dallas = RouteWaypoint(kind: .airport, ident: "KDFW", name: "DALLAS-FORT WORTH INTL",
                                   coordinate: Coordinate(latitude: 32.8968, longitude: -97.0380))

private func fix(_ at: Coordinate, knots: Double? = nil, track: Double? = nil) -> Position {
    Position(latitude: at.latitude, longitude: at.longitude, courseDegrees: track ?? -1,
             speedMetersPerSecond: knots.map { $0 / 1.943844 } ?? -1, altitudeMeters: nil, timestamp: now)!
}

private func planned() throws -> RoutePlan {
    RoutePlan(route: try #require(Route(waypoints: [austin, waco, dallas], navCycle: "c")))
}

@Suite struct RoutePlanTests {
    @Test func directToIsOneLegFromTheAircraft() throws {
        let plan = RoutePlan.direct(to: dallas, navCycle: "c")
        #expect(plan.isDirect && plan.fromAircraft)
        #expect(plan.legCount == 1 && plan.activeLeg == 0)
        #expect(plan.targets == [dallas])
        // The leg starts wherever the aircraft is now.
        let live = try #require(plan.route(from: fix(austin.coordinate), now: now))
        #expect(live.waypoints.map(\.coordinate) == [austin.coordinate, dallas.coordinate])
        // No fix leaves nothing to draw.
        #expect(plan.route(from: nil, now: now) == nil)
    }

    @Test func appendingToNoRouteStartsOneFromTheAircraft() {
        let plan = RoutePlan.appending(austin, to: nil, navCycle: "c")
        #expect(plan == RoutePlan.direct(to: austin, navCycle: "c"))
        let longer = RoutePlan.appending(dallas, to: plan, navCycle: "c")
        #expect(longer.targets == [austin, dallas])
        #expect(longer.legCount == 2 && !longer.isDirect && longer.activeLeg == 0)
    }

    @Test func aPlannedRouteFliesBetweenItsOwnPoints() throws {
        let plan = try planned()
        #expect(!plan.fromAircraft && plan.legCount == 2)
        #expect(plan.targets == [waco, dallas])
        // With no fix the fixed points still draw.
        #expect(plan.route(from: nil, now: now)?.waypoints == [austin, waco, dallas])
    }

    @Test func removingATargetKeepsTheActiveLegOnTheSameWaypoint() throws {
        var plan = RoutePlan.appending(waco, to: .direct(to: austin, navCycle: "c"), navCycle: "c")
        plan = RoutePlan.appending(dallas, to: plan, navCycle: "c")
        plan.advance(position: fix(Coordinate(latitude: 30.21, longitude: -97.66)), now: now)
        // Past Austin the aircraft leg is dropped and the route flies Austin, Waco, Dallas.
        #expect(!plan.fromAircraft && plan.activeLeg == 0 && plan.targets == [waco, dallas])
        let shorter = try #require(plan.removing(target: 0))
        #expect(shorter.targets == [dallas] && shorter.activeLeg == 0)
        // Removing the last waypoint of a direct-to leaves no route.
        #expect(RoutePlan.direct(to: dallas, navCycle: "c").removing(target: 0) == nil)
        #expect(try planned().removing(target: 1)?.targets == [waco])
    }

    @Test func removingAnEarlierTargetMovesTheActiveLegBack() throws {
        var plan = try planned()
        plan.advance(position: fix(Coordinate(latitude: 31.75, longitude: -97.25)), now: now)
        #expect(plan.activeLeg == 1)
        let shorter = try #require(plan.removing(target: 0))
        #expect(shorter.targets == [dallas] && shorter.activeLeg == 0)
    }

    @Test func reorderingMovesTargetsAndNeverTheAircraft() throws {
        let plan = RoutePlan.appending(dallas, to: .direct(to: waco, navCycle: "c"), navCycle: "c")
        let moved = plan.moving(from: 1, to: 0)
        #expect(moved.targets == [dallas, waco])
        #expect(moved.fromAircraft && moved.activeLeg == 0)
        #expect(try planned().moving(from: 0, to: 2).targets == [dallas, waco])
    }

    @Test func directToAWaypointOnTheRouteFliesFromTheAircraftToIt() throws {
        let plan = try planned().direct(toTarget: 1)
        #expect(plan.fromAircraft && plan.isDirect && plan.targets == [dallas])
        let partway = try planned().direct(toTarget: 0)
        #expect(partway.targets == [waco, dallas] && partway.activeLeg == 0)
        #expect(partway.targets.allSatisfy { $0.airway == nil })
        // -1, the first point of a route not flown from the aircraft, flies to it and on.
        let whole = try planned()
        let toStart = whole.direct(toTarget: -1)
        #expect(toStart.fromAircraft && toStart.targets == [austin, waco, dallas] && toStart.activeLeg == 0)
        // A target the editor never gives changes nothing.
        for target in [-3, -2, 2, 9] { #expect(whole.direct(toTarget: target) == whole) }
        #expect(toStart.direct(toTarget: -1) == toStart)
    }

    // Direct To W1, then W2. Abeam W1 sequences only after a fix that was closing on it.
    @Test func aRouteFromTheAircraftSequencesWhenItsFirstWaypointIsPassedAbeamAfterClosingOnIt() {
        let w1 = RouteWaypoint(kind: .fix, ident: "W1", name: "W1", coordinate: Coordinate(latitude: 31.0, longitude: -97.0))
        let w2 = RouteWaypoint(kind: .fix, ident: "W2", name: "W2", coordinate: Coordinate(latitude: 31.0, longitude: -96.0))
        func flown(_ fixes: [(latitude: Double, longitude: Double, track: Double)], knots: Double = 120) -> RoutePlan {
            var plan = RoutePlan.appending(w2, to: .direct(to: w1, navCycle: "c"), navCycle: "c")
            for f in fixes {
                plan.advance(position: fix(Coordinate(latitude: f.latitude, longitude: f.longitude), knots: knots, track: f.track), now: now)
            }
            return plan
        }
        // Tapped while W1 is 5 nm behind, flying west: the Direct To holds.
        #expect(flown([(31.0, -97.1, 270), (31.0, -97.11, 270)]).fromAircraft)
        // Turned toward W1, then flown past it 3 nm abeam: it sequences.
        let past = flown([(31.0, -97.1, 270), (31.05, -97.05, 90), (31.05, -96.97, 90)])
        #expect(!past.fromAircraft && past.targets == [w2] && past.activeLeg == 0)
        // Passing abeam without having closed, or closing too slowly to count, keeps the leg.
        #expect(flown([(31.05, -96.97, 90)]).fromAircraft)
        #expect(flown([(31.05, -97.05, 90), (31.05, -96.97, 90)], knots: 20).fromAircraft)
        // More than 10 nm away keeps the leg.
        #expect(flown([(31.05, -97.05, 90), (31.05, -96.8, 90)]).fromAircraft)
    }

    @Test func aPlanSavedWithoutTheClosingFlagDecodesAndOneWithItRoundTrips() throws {
        let plan = RoutePlan.appending(waco, to: .direct(to: austin, navCycle: "c"), navCycle: "c")
        let old = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(RoutePlan.self, from: old)
        #expect(!String(decoding: old, as: UTF8.self).contains("closing") && decoded == plan)
        var closing = plan
        closing.advance(position: fix(Coordinate(latitude: 30.0, longitude: -97.6699), knots: 120, track: 0), now: now)
        let saved = try JSONEncoder().encode(closing)
        let back = try JSONDecoder().decode(RoutePlan.self, from: saved)
        #expect(closing != plan && String(decoding: saved, as: UTF8.self).contains(#""closing":true"#) && back == closing)
        // Noting it changes no leg; sequencing does.
        #expect(closing.sameLeg(as: plan) && !closing.sameLeg(as: nil))
        var passed = closing
        passed.advance(position: fix(austin.coordinate, knots: 120, track: 0), now: now)
        #expect(!passed.sameLeg(as: closing))
    }

    @Test func theActiveLegStepsOnAndNeverBack() throws {
        var plan = try planned()
        plan.advance(position: fix(dallas.coordinate), now: now)
        #expect(plan.activeLeg == 1)
        plan.advance(position: fix(austin.coordinate), now: now)
        #expect(plan.activeLeg == 1)
        // A stale fix changes nothing.
        var stale = try planned()
        stale.advance(position: fix(dallas.coordinate), now: now.addingTimeInterval(60))
        #expect(stale.activeLeg == 0)
    }

    @Test func legRowsShowPlannedValuesAndLiveOnesForTheActiveLeg() throws {
        let plan = try planned()
        let rows = plan.rows(position: nil, now: now, trueAirspeedKt: 120)
        #expect(rows.map(\.waypoint.ident) == ["ACT", "KDFW"])
        #expect(rows.map(\.isActive) == [true, false])
        #expect(rows[0].distance.hasSuffix(" NM") && rows[0].course.hasSuffix("°M"))
        // About 90 NM at 120 knots is 0:45.
        #expect(rows[0].time.map { $0.hasPrefix("0:4") } == true)
        #expect(plan.rows(position: nil, now: now, trueAirspeedKt: nil)[1].time == nil)
        // A direct-to with no fix shows dashes.
        let direct = RoutePlan.direct(to: dallas, navCycle: "c").rows(position: nil, now: now, trueAirspeedKt: 120)
        #expect(direct[0].distance == NavText.dashes && direct[0].time == nil)
        // Live, the active leg counts from the aircraft at its groundspeed.
        let live = plan.rows(position: fix(austin.coordinate, knots: 100, track: 10), now: now, trueAirspeedKt: 120)
        #expect(live[0].distance == NavText.distance(Geo.distanceNM(from: austin.coordinate, to: waco.coordinate)))
        #expect(live[0].time != rows[0].time)
    }

    @Test func insertingBeforeATargetKeepsTheActiveLegFlyingToTheSamePlace() throws {
        var plan = try planned()
        plan.advance(position: fix(Coordinate(latitude: 31.75, longitude: -97.25)), now: now)
        let early = try #require(plan.inserting(austin, at: 0))
        #expect(early.targets == [austin, waco, dallas] && early.activeLeg == 2)
        let onActive = try #require(plan.inserting(waco, at: 1))
        #expect(onActive.activeLeg == 1 && onActive.targets[1] == waco)
        #expect(try planned().inserting(austin, at: 2)?.targets.last == austin)
        #expect(try planned().inserting(austin, at: 3) == nil)
    }

    @Test func theNearestLegToAMapPoint() throws {
        let plan = try planned()
        #expect(plan.nearestLeg(to: Coordinate(latitude: 31.0, longitude: -97.5), position: nil, now: now) == 0)
        #expect(plan.nearestLeg(to: Coordinate(latitude: 32.3, longitude: -97.1), position: nil, now: now) == 1)
        // From the aircraft with no fix, only the fixed leg is drawn and it keeps its index.
        let fromHere = RoutePlan.appending(dallas, to: .direct(to: waco, navCycle: "c"), navCycle: "c")
        #expect(fromHere.nearestLeg(to: austin.coordinate, position: nil, now: now) == 1)
        #expect(fromHere.nearestLeg(to: austin.coordinate, position: fix(austin.coordinate), now: now) == 0)
    }

    @Test func typedTextBecomesTheRouteAndReadsBack() throws {
        // One waypoint typed flies from the aircraft; two or more fly between themselves.
        let one = try #require(RoutePlan.typed([dallas], replacing: nil, navCycle: "c"))
        #expect(one == RoutePlan.direct(to: dallas, navCycle: "c") && one.text == "KDFW")
        let fixed = try #require(RoutePlan.typed([austin, waco, dallas], replacing: one, navCycle: "c"))
        #expect(!fixed.fromAircraft && fixed.text == "KAUS ACT KDFW")
        #expect(RoutePlan.typed([], replacing: one, navCycle: "c") == nil)
        // A route from the aircraft stays one, and its text leaves the aircraft out.
        let started = RoutePlan.appending(dallas, to: .direct(to: waco, navCycle: "c"), navCycle: "c")
        #expect(started.text == "ACT KDFW")
        let retyped = try #require(RoutePlan.typed([austin, dallas], replacing: started, navCycle: "c"))
        #expect(retyped.fromAircraft && retyped.targets == [austin, dallas])
    }

    @Test func routeProblemsReadAsPlainWords() {
        #expect(NavText.routeProblem(.unknownIdentifier, "KXYZ") == "KXYZ is not an airport, navaid or fix")
        for kind in [RouteProblemKind.pointNotOnAirway, .airwayBroken, .malformedCoordinate, .airwayWithoutPoint,
                     .airwaysDoNotMeet, .airwaysMeetMoreThanOnce, .badRadialDistance] {
            #expect(NavText.routeProblem(kind, "V306").contains("V306"))
        }
    }

    @Test func aircraftTotalsNeedASpeed() throws {
        let plan = try planned()
        let log = try #require(plan.navLog(position: nil, now: now, trueAirspeedKt: 120, fuelBurnPerHour: 10))
        #expect(log.totalTime != nil && log.totalFuel != nil)
        #expect(plan.navLog(position: nil, now: now, trueAirspeedKt: 0, fuelBurnPerHour: 10)?.totalTime == nil)
    }

    @Test func durationsReadAsHoursAndMinutes() {
        #expect(NavText.duration(45 * 60) == "0:45")
        #expect(NavText.duration(3900) == "1:05")
        #expect(NavText.duration(.infinity) == NavText.dashes)
    }
}
