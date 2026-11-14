/// A point on the screen, in the platform's own units.
public struct ScreenPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// What a finger picks on the map.
public enum MapPick {
    /// The places under the finger, closest to it first, each place once.
    public static func here(_ hits: [(WaypointMatch, Double)]) -> [WaypointMatch] {
        var seen = Set<String>()
        return hits.sorted { $0.1 < $1.1 }.map(\.0).filter { seen.insert("\($0.kind.rawValue) \($0.ident)").inserted }
    }

    /// What a released rubber band snaps to: open map, the one nearest place, or places about equally near.
    public enum Snap: Equatable, Sendable {
        case open
        case one(WaypointMatch)
        case choose([WaypointMatch])
    }

    /// Places within 4 points of the nearest count as equally near.
    public static func snap(_ hits: [(WaypointMatch, Double)]) -> Snap {
        let places = here(hits)
        guard let nearest = hits.map(\.1).min() else { return .open }
        let near = Set(hits.filter { $0.1 <= nearest + 4 }.map { "\($0.0.kind.rawValue) \($0.0.ident)" })
        let tied = places.filter { near.contains("\($0.kind.rawValue) \($0.ident)") }
        return tied.count > 1 ? .choose(tied) : .one(places[0])
    }

    /// What a held finger grabs on the drawn route, in screen points: a waypoint dot first, then a leg, within 22.
    /// Dots start at firstDot, so the aircraft's point is never grabbed.
    // ponytail: legs are tested as straight screen lines; fine at chart zooms, bend-aware if long legs miss.
    public static func grab(_ points: [ScreenPoint], firstDot: Int, at finger: ScreenPoint) -> RouteGrab? {
        func gap(_ a: ScreenPoint, _ b: ScreenPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let dot = points.indices.dropFirst(firstDot).min { gap(points[$0], finger) < gap(points[$1], finger) }
        if let dot, gap(points[dot], finger) <= 22 { return .point(dot) }
        let legs = points.indices.dropLast().map { index -> Double in
            let a = points[index], b = points[index + 1]
            let span = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
            let t = span == 0 ? 0 : max(0, min(1, ((finger.x - a.x) * (b.x - a.x) + (finger.y - a.y) * (b.y - a.y)) / span))
            return gap(finger, ScreenPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
        }
        guard let leg = legs.indices.min(by: { legs[$0] < legs[$1] }), legs[leg] <= 22 else { return nil }
        return .leg(leg)
    }
}

/// A grabbed part of the drawn route: a leg by its index, or a waypoint dot by its point's index.
public enum RouteGrab: Equatable, Sendable {
    case leg(Int)
    case point(Int)
}
