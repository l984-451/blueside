public struct RouteWaypoint: Equatable, Sendable, Codable {
    public var kind: WaypointKind
    /// For an airport, the ICAO code when it has one, otherwise the FAA identifier.
    public var ident: String
    public var name: String
    public var coordinate: Coordinate
    /// The airway flown to reach this waypoint from the one before, if any.
    public var airway: String?
    /// Field elevation, airports only; where climb starts and descent ends.
    public var elevationFt: Double?

    public init(kind: WaypointKind, ident: String, name: String, coordinate: Coordinate, airway: String? = nil,
                elevationFt: Double? = nil) {
        self.kind = kind
        self.ident = ident
        self.name = name
        self.coordinate = coordinate
        self.airway = airway
        self.elevationFt = elevationFt
    }

    public init(airport: Airport) {
        self.init(kind: .airport, ident: airport.icao ?? airport.ident, name: airport.name, coordinate: airport.coordinate,
                  elevationFt: airport.elevationFt)
    }

    public init(navaid: Navaid) {
        self.init(kind: .navaid, ident: navaid.ident, name: navaid.name, coordinate: navaid.coordinate)
    }

    public init(fix: Fix) {
        self.init(kind: .fix, ident: fix.ident, name: fix.ident, coordinate: fix.coordinate)
    }

    /// From a search suggestion. An airport takes its ICAO code when it has one, as init(airport:) does.
    public init(match: WaypointMatch) {
        self.init(kind: match.kind, ident: match.kind == .airport ? (match.icao ?? match.ident) : match.ident,
                  name: match.name, coordinate: match.coordinate, elevationFt: match.elevationFt)
    }

    /// A point with no database record, named in the degrees and minutes form. Kept to six decimals.
    public static func user(at coordinate: Coordinate) -> RouteWaypoint {
        let point = RouteText.rounded(coordinate)
        let name = RouteText.name(for: point)
        return RouteWaypoint(kind: .user, ident: name, name: name, coordinate: point)
    }

    /// How this waypoint is written in route text.
    var textToken: String {
        guard kind == .user else { return ident }
        // A point named by fix, radial and distance is written the way it was typed.
        if RouteText.fixRadialDistance(ident) != nil { return ident }
        return RouteText.coordinate(ident) == coordinate ? ident : RouteText.decimal(coordinate)
    }

    /// The same place, whatever airway led to it.
    func isSamePlace(as other: RouteWaypoint) -> Bool {
        kind == other.kind && ident == other.ident && coordinate == other.coordinate
    }
}

/// Two or more waypoints in the order flown.
public struct Route: Equatable, Sendable, Codable {
    public private(set) var waypoints: [RouteWaypoint]
    /// The nav cycle the route was built with, such as 2026-10-01.
    public private(set) var navCycle: String

    private enum CodingKeys: String, CodingKey {
        case waypoints, navCycle
    }

    /// Nil for fewer than two waypoints, or a waypoint whose position is not on the earth.
    public init?(waypoints: [RouteWaypoint], navCycle: String) {
        let real = waypoints.allSatisfy { point in
            let c = point.coordinate
            return c.latitude.isFinite && c.longitude.isFinite && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
        }
        guard waypoints.count >= 2, real else { return nil }
        var points = waypoints
        points[0].airway = nil
        self.waypoints = points
        self.navCycle = navCycle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let points = try container.decode([RouteWaypoint].self, forKey: .waypoints)
        let cycle = try container.decode(String.self, forKey: .navCycle)
        guard let route = Route(waypoints: points, navCycle: cycle) else {
            throw DecodingError.dataCorruptedError(forKey: .waypoints, in: container,
                                                   debugDescription: "a route needs two or more real waypoints")
        }
        self = route
    }

    /// A waypoint keeps its airway mark only when the waypoint before it is the one it had before the edit.
    private func rebuilt(_ points: [RouteWaypoint]) -> Route? {
        var out = points
        for j in out.indices where out[j].airway != nil {
            var kept = false
            if j > 0 {
                for k in waypoints.indices.dropFirst() where waypoints[k].airway == points[j].airway {
                    if waypoints[k].isSamePlace(as: points[j]), waypoints[k - 1].isSamePlace(as: points[j - 1]) {
                        kept = true
                        break
                    }
                }
            }
            if !kept { out[j].airway = nil }
        }
        return Route(waypoints: out, navCycle: navCycle)
    }

    /// Nil when the index is out of range. The index may equal the count, which appends.
    public func inserting(_ waypoint: RouteWaypoint, at index: Int) -> Route? {
        guard index >= 0, index <= waypoints.count else { return nil }
        var added = waypoint
        added.airway = nil
        var points = waypoints
        points.insert(added, at: index)
        return rebuilt(points)
    }

    /// Nil when the index is out of range or the route would drop below two waypoints.
    public func removing(at index: Int) -> Route? {
        guard waypoints.indices.contains(index) else { return nil }
        var points = waypoints
        points.remove(at: index)
        return rebuilt(points)
    }

    /// Takes the waypoint out and puts it back so that it ends up at the second index.
    public func moving(from: Int, to: Int) -> Route? {
        guard waypoints.indices.contains(from), waypoints.indices.contains(to) else { return nil }
        var points = waypoints
        let moved = points.remove(at: from)
        points.insert(moved, at: to)
        return rebuilt(points)
    }

    /// The same legs flown the other way. Airway stretches stay on the same pairs of points.
    public func reversed() -> Route {
        var points = Array(waypoints.reversed())
        let count = points.count
        for j in points.indices {
            points[j].airway = j == 0 ? nil : waypoints[count - j].airway
        }
        var route = self
        route.waypoints = points
        return route
    }

    /// Identifiers joined by spaces, with each airway stretch written as entry, airway, exit.
    public var routeText: String {
        var tokens: [String] = []
        var i = 0
        while i < waypoints.count {
            if i > 0, let airway = waypoints[i].airway {
                var j = i
                // A stretch stops where the route turns back onto a point the stretch already holds.
                while j + 1 < waypoints.count, waypoints[j + 1].airway == airway,
                      !waypoints[(i - 1)...j].contains(where: { $0.isSamePlace(as: waypoints[j + 1]) }) { j += 1 }
                tokens.append(airway)
                tokens.append(waypoints[j].textToken)
                i = j + 1
            } else {
                tokens.append(waypoints[i].textToken)
                i += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    /// From a point at the present position straight to the target. Nil when the position is not real.
    public static func direct(from position: Coordinate, to target: RouteWaypoint, navCycle: String) -> Route? {
        var end = target
        end.airway = nil
        return Route(waypoints: [.user(at: position), end], navCycle: navCycle)
    }
}
