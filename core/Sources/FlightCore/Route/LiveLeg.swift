/// The active leg as the Lock Screen shows it in flight, and when that display starts, changes and ends.
public enum LiveLeg {
    /// The next waypoint, the distance to it in the strip's format, and when the aircraft reaches it at its present
    /// groundspeed (nil below the speed that gives times).
    public struct Shown: Equatable, Sendable {
        public var ident: String
        public var distance: String
        public var arrival: Date?
    }

    /// The least time between two updates on one leg.
    public static let updateEvery: TimeInterval = 15

    /// The active leg from a live, exact fix, counted as the route drawer's active row counts it. Nil without one.
    public static func shown(_ plan: RoutePlan, position: Position?, approximate: Bool = false, now: Date) -> Shown? {
        guard let position, !approximate, !position.isStale(at: now) else { return nil }
        let target = plan.route.waypoints[plan.activeLeg + 1]
        let miles = Geo.distanceNM(from: position.coordinate, to: target.coordinate)
        let speed = position.groundspeedKt.flatMap { $0 >= Route.minimumGroundspeedForTimesKt ? $0 : nil }
        let arrival = speed.flatMap { miles.isFinite ? now.addingTimeInterval(miles / $0 * 3600) : nil }
        return Shown(ident: target.ident, distance: NavText.distance(miles), arrival: arrival)
    }

    public enum Step: Equatable, Sendable {
        case start(Shown), update(Shown), end
    }

    /// What to do next. `showing` is what a running display shows, nil when none runs; `sent` is the last start or
    /// update asked for. It starts only in the front, at flying speed on a live fix, and ends with no route, on the
    /// ground at the route's end, or once the app would stop running out of the front (`until`). Nil changes nothing.
    public static func step(showing: Shown?, sent: Date?, plan: RoutePlan?, position: Position?, approximate: Bool,
                            until: Date?, inFront: Bool, now: Date) -> Step? {
        let live = plan.flatMap { shown($0, position: position, approximate: approximate, now: now) }
        let flying = live != nil && (position?.groundspeedKt ?? 0) >= BackgroundPolicy.flyingKt
        let due = sent.map { now >= $0 + updateEvery } ?? true
        guard let plan, let until, until > now, !arrived(plan, position: position, approximate: approximate, now: now)
        else { return showing == nil ? nil : .end }
        guard let showing else {
            // A refused start is not asked again with every fix.
            return inFront && flying && due ? live.map(Step.start) : nil
        }
        // Without a live fix the last values stay until the app would stop.
        guard let live else { return nil }
        return live.ident != showing.ident || (due && live.distance != showing.distance) ? .update(live) : nil
    }

    /// Slowed below flying speed on a live fix, on the last leg, within the sequencing distance of its end.
    static func arrived(_ plan: RoutePlan, position: Position?, approximate: Bool, now: Date) -> Bool {
        guard plan.activeLeg == plan.legCount - 1, let position, !approximate, !position.isStale(at: now),
              (position.groundspeedKt ?? 0) < BackgroundPolicy.flyingKt, let end = plan.route.waypoints.last else { return false }
        return Geo.distanceNM(from: position.coordinate, to: end.coordinate) <= Route.turnAnticipationNM
    }
}
