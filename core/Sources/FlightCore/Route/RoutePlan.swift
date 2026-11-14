/// The active route and the leg being flown. Direct To is a one-leg route from the aircraft.
public struct RoutePlan: Equatable, Sendable, Codable {
    /// When fromAircraft, the first point stands for the aircraft and moves with it.
    public private(set) var route: Route
    public private(set) var fromAircraft: Bool
    public private(set) var activeLeg = 0
    /// From the aircraft: a live fix has closed on the first waypoint, so passing it abeam can sequence.
    /// Every new plan starts without it; plans saved before it was kept decode as nil.
    private var closing: Bool?

    /// A route between its own points, flown from the first leg.
    public init(route: Route) {
        self.route = route
        fromAircraft = false
    }

    private init(route: Route, fromAircraft: Bool, activeLeg: Int) {
        self.route = route
        self.fromAircraft = fromAircraft
        self.activeLeg = min(max(activeLeg, 0), route.waypoints.count - 2)
    }

    public static func direct(to target: RouteWaypoint, navCycle: String) -> RoutePlan {
        // The aircraft's point is filled in from each fix, so its stored place does not matter.
        RoutePlan(route: Route.direct(from: Coordinate(latitude: 0, longitude: 0), to: target, navCycle: navCycle)!,
                  fromAircraft: true, activeLeg: 0)
    }

    /// Adds a waypoint at the end, or starts a route from the aircraft when there is none.
    public static func appending(_ waypoint: RouteWaypoint, to plan: RoutePlan?, navCycle: String) -> RoutePlan {
        guard let plan, let longer = plan.route.inserting(waypoint, at: plan.route.waypoints.count) else {
            return direct(to: waypoint, navCycle: navCycle)
        }
        return RoutePlan(route: longer, fromAircraft: plan.fromAircraft, activeLeg: plan.activeLeg)
    }

    /// Typed waypoints as the route. One alone, or a route of several already from the aircraft, flies from it;
    /// a Direct To typed over becomes the typed route.
    // ponytail: keeps the active leg's index, not its waypoint; match by waypoint if retyping in flight jumps legs.
    public static func typed(_ points: [RouteWaypoint], replacing plan: RoutePlan?, navCycle: String) -> RoutePlan? {
        let fromAircraft = (plan?.fromAircraft == true && plan?.isDirect == false) || points.count == 1
        let start = fromAircraft ? [RouteWaypoint.user(at: Coordinate(latitude: 0, longitude: 0))] : []
        guard let route = Route(waypoints: start + points, navCycle: navCycle) else { return nil }
        return RoutePlan(route: route, fromAircraft: fromAircraft, activeLeg: plan?.activeLeg ?? 0)
    }

    /// The route as typed. From the aircraft, the aircraft's point is left out.
    public var text: String {
        guard fromAircraft else { return route.routeText }
        return Route(waypoints: targets, navCycle: route.navCycle)?.routeText ?? targets.first?.ident ?? ""
    }

    /// Totals for the route as flown now, one wind per leg. Magnetic values are for the departure date, else now.
    /// Nil when nothing is drawn.
    public func navLog(position: Position?, approximate: Bool = false, now: Date, trueAirspeedKt: Double,
                fuelBurnPerHour: Double, winds: [LegWind?] = [], departure: Date? = nil) -> NavLog? {
        route(from: position, approximate: approximate, now: now)?
            .navLog(trueAirspeedKt: trueAirspeedKt, fuelBurnPerHour: fuelBurnPerHour, winds: winds, date: departure ?? now)
    }

    public var isDirect: Bool { fromAircraft && legCount == 1 }
    public var legCount: Int { route.waypoints.count - 1 }
    /// The waypoints the legs fly to, one per leg: every point but the first.
    public var targets: [RouteWaypoint] { Array(route.waypoints.dropFirst()) }

    /// Nil when no leg is left.
    public func removing(target: Int) -> RoutePlan? {
        guard let shorter = route.removing(at: target + 1) else { return nil }
        // An earlier point going takes the active leg back one, so it still flies to the same place.
        return RoutePlan(route: shorter, fromAircraft: fromAircraft, activeLeg: target < activeLeg ? activeLeg - 1 : activeLeg)
    }

    /// Puts a waypoint before the given target, so it ends that leg; targets.count appends. Nil when out of range.
    public func inserting(_ waypoint: RouteWaypoint, at target: Int) -> RoutePlan? {
        guard let longer = route.inserting(waypoint, at: target + 1) else { return nil }
        return RoutePlan(route: longer, fromAircraft: fromAircraft, activeLeg: target < activeLeg ? activeLeg + 1 : activeLeg)
    }

    /// Puts a waypoint in the target's place; -1 is the start of a route not flown from the aircraft.
    public func replacing(target: Int, with waypoint: RouteWaypoint) -> RoutePlan? {
        guard !(fromAircraft && target < 0),
              let swapped = route.inserting(waypoint, at: target + 1)?.removing(at: target + 2) else { return nil }
        return RoutePlan(route: swapped, fromAircraft: fromAircraft, activeLeg: activeLeg)
    }

    /// The route with a grabbed leg or dot of the drawn line, of drawnCount points, pulled to a waypoint.
    public func bending(_ grab: RouteGrab, drawnCount: Int, to point: RouteWaypoint) -> RoutePlan? {
        let shift = route.waypoints.count - drawnCount
        switch grab {
        case .leg(let leg): return inserting(point, at: leg + shift)
        case .point(let index): return replacing(target: index + shift - 1, with: point)
        }
    }

    /// The target a new point goes in at when it sits beside a leg rather than past the route's end. Nil appends.
    // ponytail: the leg from the aircraft never takes an insert; a point beside it appends.
    public func insertTarget(for point: Coordinate, position: Position?, approximate: Bool = false, now: Date) -> Int? {
        guard let leg = nearestLeg(to: point, position: position, approximate: approximate, now: now),
              !(fromAircraft && leg == 0) else { return nil }
        if leg < legCount - 1 { return leg }
        // On the last leg, only a point abeam it is nearer the leg than the end.
        let start = route.waypoints[leg].coordinate, end = route.waypoints[leg + 1].coordinate
        func apart(_ a: Double, _ b: Double) -> Double { abs(remainder(a - b, 360)) }
        let abeam = apart(Geo.initialBearing(from: start, to: point), Geo.initialBearing(from: start, to: end)) < 90
            && apart(Geo.initialBearing(from: end, to: point), Geo.initialBearing(from: end, to: start)) < 90
        return abeam ? leg : nil
    }

    /// The leg drawn nearest a map point, by its target's index. Nil when nothing is drawn.
    public func nearestLeg(to point: Coordinate, position: Position?, approximate: Bool = false, now: Date) -> Int? {
        guard let drawn = route(from: position, approximate: approximate, now: now),
              let probe = Position(latitude: point.latitude, longitude: point.longitude, courseDegrees: -1,
                                   speedMetersPerSecond: -1, altitudeMeters: nil, timestamp: now),
              let leg = drawn.initialLeg(for: probe, now: now) else { return nil }
        // Without a fix a route from the aircraft draws one leg fewer.
        return leg + route.waypoints.count - drawn.waypoints.count
    }

    /// Moves a target as a list's move gives it: one row, to an offset counted before the move.
    /// The aircraft's point never moves.
    public func moving(from source: Int?, to destination: Int) -> RoutePlan {
        guard let from = source,
              let moved = route.moving(from: from + 1, to: (destination > from ? destination - 1 : destination) + 1)
        else { return self }
        return RoutePlan(route: moved, fromAircraft: fromAircraft, activeLeg: activeLeg)
    }

    /// From the aircraft straight to a target, then on along the rest of the route. -1 is the first point of a route
    /// not flown from the aircraft; any target the editor does not give changes nothing.
    public func direct(toTarget target: Int) -> RoutePlan {
        guard target >= (fromAircraft ? 0 : -1), target < targets.count else { return self }
        var rest = Array(route.waypoints.dropFirst(target + 1))
        rest[0].airway = nil
        let start = RouteWaypoint.user(at: Coordinate(latitude: 0, longitude: 0))
        return RoutePlan(route: Route(waypoints: [start] + rest, navCycle: route.navCycle)!, fromAircraft: true,
                         activeLeg: 0)
    }

    /// The route as flown now: from the aircraft's live fix when it starts there.
    /// Without a live, exact fix such a route keeps only its fixed points, or nothing.
    public func route(from position: Position?, approximate: Bool = false, now: Date) -> Route? {
        guard fromAircraft else { return route }
        guard let position, !approximate, !position.isStale(at: now) else {
            return Route(waypoints: targets, navCycle: route.navCycle)
        }
        var points = route.waypoints
        points[0] = RouteWaypoint(kind: .user, ident: "", name: "", coordinate: position.coordinate)
        return Route(waypoints: points, navCycle: route.navCycle)
    }

    /// Within this distance, a waypoint the aircraft closed on and now has behind its track counts as passed.
    static let passedWithinNM = 10.0

    /// Steps to the next leg once the aircraft has passed the end of this one.
    public mutating func advance(position: Position?, approximate: Bool = false, now: Date) {
        guard let position, !approximate, !position.isStale(at: now) else { return }
        if fromAircraft {
            // The leg from the aircraft always starts where it is, so only its end counts. It is passed within 2 nm,
            // or within 10 nm once it is more than 90° off the track after a fix that was closing on it.
            guard activeLeg == 0, legCount > 1 else { return }
            let end = route.waypoints[1].coordinate
            let distance = Geo.distanceNM(from: position.coordinate, to: end)
            let bearing = Geo.initialBearing(from: position.coordinate, to: end)
            let moving = (position.groundspeedKt ?? 0) >= Route.minimumGroundspeedForTimesKt
            let off = moving ? position.trackTrue.map { abs(RouteMath.normalized(bearing - $0 + 180) - 180) } : nil
            // ponytail: after closing, a turn away inside 10 nm (a hold, a vector) also sequences; needs the turn's intent to tell.
            let passed = closing == true && distance <= Self.passedWithinNM && (off ?? 0) > 90
            if distance <= Route.turnAnticipationNM || passed, let rest = route.removing(at: 0) {
                self = RoutePlan(route: rest, fromAircraft: false, activeLeg: 0)
            } else if let off, off < 90 {
                closing = true
            }
            return
        }
        activeLeg = route.advanced(legIndex: activeLeg, position: position, now: now)
    }

    /// The same route on the same leg. A fix that only notes the aircraft closing on a waypoint sequences nothing.
    public func sameLeg(as other: RoutePlan?) -> Bool { route == other?.route && activeLeg == other?.activeLeg }

    /// One drawer row: where a leg goes, its magnetic course, distance and time.
    public struct LegRow: Identifiable, Equatable, Sendable, Encodable {
        public var id: Int
        public var waypoint: RouteWaypoint
        public var course: String
        public var distance: String
        public var time: String?
        public var isActive: Bool
    }

    /// The active leg counts from a live fix; the others, and the active one without a fix, show planned values.
    public func rows(position: Position?, approximate: Bool = false, now: Date, trueAirspeedKt: Double?) -> [LegRow] {
        let live = position.flatMap { !approximate && !$0.isStale(at: now) ? $0 : nil }
        let legs = route.legs(date: now)
        return legs.enumerated().map { index, leg in
            var miles: Double? = leg.distanceNM
            var course: String = NavText.bearing(leg.trueCourse, from: leg.from.coordinate, date: now)
            var speed = trueAirspeedKt
            if index == activeLeg, let live {
                miles = Geo.distanceNM(from: live.coordinate, to: leg.to.coordinate)
                course = NavText.directTo(from: live, to: leg.to.coordinate, now: now).bearing
                if let ground = live.groundspeedKt, ground >= Route.minimumGroundspeedForTimesKt { speed = ground }
            } else if fromAircraft, index == 0 {
                miles = nil
                course = NavText.dashes
            }
            let time = miles.flatMap { distance in speed.flatMap { $0 > 0 ? NavText.duration(distance / $0 * 3600) : nil } }
            return LegRow(id: index, waypoint: leg.to, course: course,
                          distance: miles.map(NavText.distance) ?? NavText.dashes, time: time,
                          isActive: index == activeLeg)
        }
    }
}
