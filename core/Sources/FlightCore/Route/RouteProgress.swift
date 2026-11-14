/// Where the aircraft is against the active leg. Built only from a position that is not stale.
public struct RouteProgress: Equatable, Sendable {
    public var legIndex: Int
    /// Right of course is positive. Absent on a leg of no length.
    public var crossTrackNM: Double?
    public var distanceToNextNM: Double
    public var bearingToNextTrue: Double
    public var bearingToNextMagnetic: Double
    public var distanceToDestinationNM: Double
    /// Seconds. Absent when groundspeed is unknown or under 30 knots.
    public var timeToNext: TimeInterval?
    /// Seconds. Absent when groundspeed is unknown or under 30 knots.
    public var timeToDestination: TimeInterval?
}

extension Route {
    /// Below this groundspeed a time to go means nothing, so none is given.
    public static let minimumGroundspeedForTimesKt = 30.0

    /// Within this distance of a waypoint a turn may sequence the leg whatever the track.
    public static let turnAnticipationNM = 2.0

    /// Legs within this distance of the closest one count as equally close.
    public static let legTieNM = 1.0

    /// Nil for a missing or stale position, or a leg index outside the route.
    public func progress(legIndex: Int, position: Position?, now: Date) -> RouteProgress? {
        guard let position, !position.isStale(at: now), legIndex >= 0, legIndex < waypoints.count - 1 else { return nil }
        let here = position.coordinate
        let start = waypoints[legIndex].coordinate
        let end = waypoints[legIndex + 1].coordinate
        let toNext = Geo.distanceNM(from: here, to: end)
        var remaining = toNext
        for i in (legIndex + 1)..<(waypoints.count - 1) {
            remaining += Geo.distanceNM(from: waypoints[i].coordinate, to: waypoints[i + 1].coordinate)
        }
        let bearing = Geo.initialBearing(from: here, to: end)
        guard toNext.isFinite, remaining.isFinite, bearing.isFinite else { return nil }
        var result = RouteProgress(
            legIndex: legIndex,
            crossTrackNM: RouteMath.offsets(from: start, to: end, point: here)?.crossNM,
            distanceToNextNM: toNext,
            bearingToNextTrue: bearing,
            bearingToNextMagnetic: RouteMath.magnetic(bearing, at: here, altitudeFt: position.altitudeFtMSL ?? 0, date: now),
            distanceToDestinationNM: remaining,
            timeToNext: nil,
            timeToDestination: nil)
        if let speed = position.groundspeedKt, speed.isFinite, speed >= Self.minimumGroundspeedForTimesKt {
            result.timeToNext = toNext / speed * 3600
            result.timeToDestination = remaining / speed * 3600
        }
        return result
    }

    /// The leg to start on: the closest leg, the earliest on a near tie, with track breaking the tie when moving.
    /// Nil for a missing or stale position.
    public func initialLeg(for position: Position?, now: Date) -> Int? {
        guard let position, !position.isStale(at: now) else { return nil }
        let here = position.coordinate
        // Distance to each leg: cross-track when abeam it, otherwise to its nearer end.
        let distances = (0..<(waypoints.count - 1)).map { index -> Double in
            let start = waypoints[index].coordinate
            let end = waypoints[index + 1].coordinate
            if let offsets = RouteMath.offsets(from: start, to: end, point: here),
               offsets.alongNM >= 0, offsets.alongNM <= Geo.distanceNM(from: start, to: end) {
                return abs(offsets.crossNM)
            }
            return min(Geo.distanceNM(from: here, to: start), Geo.distanceNM(from: here, to: end))
        }
        guard let best = distances.filter(\.isFinite).min() else { return nil }
        // Legs about as close as the best one are tied, and the earliest of them wins.
        var tied = distances.indices.filter { distances[$0] <= best + Self.legTieNM }
        if let track = position.trackTrue, let speed = position.groundspeedKt, speed >= Self.minimumGroundspeedForTimesKt {
            let withTrack = tied.filter {
                let course = Geo.initialBearing(from: waypoints[$0].coordinate, to: waypoints[$0 + 1].coordinate)
                return abs(RouteMath.normalized(track - course + 180) - 180) <= 90
            }
            if !withTrack.isEmpty { tied = withTrack }
        }
        return tied.first
    }

    /// The next leg once the aircraft is in the turn past the line that halves it, or abeam the end of this one.
    /// Never backward, never past the last leg.
    public func advanced(legIndex: Int, position: Position?, now: Date) -> Int {
        let last = waypoints.count - 2
        let current = min(max(legIndex, 0), last)
        guard current < last, let position, !position.isStale(at: now) else { return current }
        let here = position.coordinate
        guard here.latitude.isFinite, here.longitude.isFinite else { return current }
        let start = waypoints[current].coordinate
        let end = waypoints[current + 1].coordinate
        // A turn begun before the waypoint never passes abeam it, so the test line halves the turn.
        let corner = RouteVector(end)
        if let inbound = RouteVector(start).cross(corner).cross(corner).unit,
           let outbound = corner.cross(RouteVector(waypoints[current + 2].coordinate)).cross(corner).unit {
            let across = RouteVector(inbound.x + outbound.x, inbound.y + outbound.y, inbound.z + outbound.z)
            // A reversal of course has no such line. Far from the waypoint the line is no guide,
            // so it counts only near the waypoint or once the track favours the next leg.
            if across.length > 1e-6, RouteVector(here).dot(across) >= 0 {
                let next = waypoints[current + 2].coordinate
                let off = { (a: Double, b: Double) in abs(RouteMath.normalized(a - b + 180) - 180) }
                let inboundCourse = Geo.initialBearing(from: end, to: start) + 180
                let outboundCourse = Geo.initialBearing(from: end, to: next)
                // Flying, and tracking close to the next leg's course.
                let moving = (position.groundspeedKt ?? 0) >= Self.minimumGroundspeedForTimesKt
                let turned = moving && (position.trackTrue.map {
                    off($0, outboundCourse) < 45 && off($0, outboundCourse) < off($0, inboundCourse)
                } ?? false)
                if turned || Geo.distanceNM(from: here, to: end) <= Self.turnAnticipationNM { return current + 1 }
            }
        }
        let length = Geo.distanceNM(from: start, to: end)
        guard let offsets = RouteMath.offsets(from: start, to: end, point: here) else {
            // A leg of no length is already behind the aircraft.
            return length < 0.001 ? current + 1 : current
        }
        return offsets.alongNM >= length ? current + 1 : current
    }
}
