/// The route screens as text and decisions: the drawer, the editor, the drawn line and edits made on the map.
/// Both apps only lay these out.
public enum RoutePages {
    public static let directTitle = "Direct To"
    public static let routeTitle = "Route"
    public static let planTitle = "Plan a Route"
    public static let edit = "Edit"
    public static let done = "Done"
    public static let clear = "Clear Route"
    public static let speedHint = "Enter cruise speed and fuel burn in Settings, Aircraft, for time and fuel."
    public static let undo = "Undo"
    /// The note beside Undo where the platform's undo pattern needs one.
    public static let edited = "Route changed"
    public static let fieldPrompt = "KAUS V306 KDFW"
    public static let useInstead = "Use instead?"
    public static let keepPoint = "Keep Point"
    public static let speedTitle = "Cruise true airspeed"
    public static let burnTitle = "Fuel burn"
    public static let aircraftNote = "The route uses these for leg times and fuel."
    /// Stored settings keys, the same on both platforms.
    public static let speedKey = "aircraftTrueAirspeedKt"
    public static let burnKey = "aircraftFuelBurnPerHour"
    /// Seconds the Use instead? card and the Undo button stay.
    public static let offerSeconds = 8.0
    public static let undoSeconds = 10.0

    public static func title(_ plan: RoutePlan) -> String { plan.isDirect ? directTitle : routeTitle }

    // MARK: Drawn line

    /// The route as drawn now, its active leg's index in it, and the first point with a dot and label.
    public struct Drawn: Equatable, Sendable {
        public var route: Route
        public var active: Int?
        /// 1 when the first point is the aircraft's own, which gets no dot, no label and is never grabbed.
        public var firstDot: Int
        public var dots: [RouteWaypoint] { Array(route.waypoints.dropFirst(firstDot)) }
    }

    /// A leg from the aircraft is drawn only from a live, exact fix, so no line starts at a guess.
    public static func drawn(_ plan: RoutePlan?, position: Position?, approximate: Bool = false, now: Date) -> Drawn? {
        guard let plan, let route = plan.route(from: position, approximate: approximate, now: now) else { return nil }
        // Without a fix the aircraft's leg is gone, so the indices shift down by one.
        let shift = route.waypoints.count == plan.route.waypoints.count ? 0 : 1
        let active = plan.activeLeg - shift
        return Drawn(route: route, active: active >= 0 ? active : nil,
                     firstDot: plan.fromAircraft && shift == 0 ? 1 : 0)
    }

    /// Points along the great circle, counting longitudes across the 180th meridian.
    public static func path(from start: Coordinate, to end: Coordinate) -> [Coordinate] {
        let ends = [start, end].map { RouteWaypoint(kind: .user, ident: "", name: "", coordinate: $0) }
        return Route(waypoints: ends, navCycle: "")?.linePoints() ?? [start, end]
    }

    // MARK: Map edits

    /// What a let-go rubber band does: edit the route, or ask which of several places.
    public enum Bend: Equatable, Sendable {
        /// The edited route, and the target of a dropped plain point that places near it could take.
        case edit(RoutePlan, offer: Int?)
        case choose([WaypointMatch])
    }

    public static func bend(_ plan: RoutePlan, _ grab: RouteGrab, drawnCount: Int, snap: MapPick.Snap,
                            at: Coordinate) -> Bend? {
        switch snap {
        case .open:
            let point = RouteWaypoint.user(at: at)
            guard let edited = plan.bending(grab, drawnCount: drawnCount, to: point) else { return nil }
            return .edit(edited, offer: edited.targets.firstIndex(of: point))
        case .one(let place):
            return plan.bending(grab, drawnCount: drawnCount, to: RouteWaypoint(match: place)).map { .edit($0, offer: nil) }
        case .choose(let places): return .choose(places)
        }
    }

    // MARK: Editor

    /// What typing in the route field gives: suggestions for the word being typed, problems, notes and the route.
    public struct Typed: Equatable, Sendable {
        public var suggestions: [WaypointMatch]
        public var problems: [String]
        public var notes: [String]
        /// The route to show when replaces is true; nil clears it.
        public var plan: RoutePlan?
        /// False keeps the route as it was, as when the text has a problem.
        public var replaces: Bool
    }

    /// Saved route text read again against the data in hand. Nil when it no longer parses cleanly.
    public static func restored(_ text: String?, database: NavDatabase, now: Date) -> RoutePlan? {
        guard let text, let parse = try? RouteParser.parse(text, database: database, date: now),
              parse.problems.isEmpty else { return nil }
        return RoutePlan.typed(parse.waypoints, replacing: nil, navCycle: parse.navCycle)
    }

    /// Parses as typed; a route with no problems replaces the active one at once, and an empty field clears it.
    public static func typed(_ text: String, plan: RoutePlan?, database: NavDatabase, now: Date) -> Typed {
        let tokens = text.split(separator: " ")
        let last = text.hasSuffix(" ") ? "" : tokens.last.map(String.init) ?? ""
        let matches = (try? database.waypointSearch(prefix: last, limit: 6)) ?? []
        let suggestions = matches.count == 1 && ident(matches[0]) == last ? [] : matches
        guard !tokens.isEmpty else { return Typed(suggestions: suggestions, problems: [], notes: [], plan: nil, replaces: true) }
        guard let parse = try? RouteParser.parse(text, database: database, date: now) else {
            return Typed(suggestions: suggestions, problems: [], notes: [], plan: plan, replaces: false)
        }
        let notes = parse.alternatives.compactMap { alternative -> String? in
            guard parse.waypoints.indices.contains(alternative.waypointIndex) else { return nil }
            return "\(parse.waypoints[alternative.waypointIndex].ident) names \(alternative.choices.count) places; the one nearest the route is used"
        }
        let made = parse.problems.isEmpty ? RoutePlan.typed(parse.waypoints, replacing: plan, navCycle: parse.navCycle) : nil
        return Typed(suggestions: suggestions, problems: parse.problems.map { NavText.routeProblem($0.kind, $0.token) },
                     notes: notes, plan: made ?? plan, replaces: made != nil)
    }

    /// The identifier a suggestion types.
    public static func ident(_ match: WaypointMatch) -> String { RouteWaypoint(match: match).ident }

    public static func suggestionDetail(_ match: WaypointMatch) -> String { "\(match.name) · \(match.kind.rawValue)" }

    /// A suggestion replaces the word being typed.
    public static func take(_ match: WaypointMatch, into text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        if !text.hasSuffix(" "), !words.isEmpty { words.removeLast() }
        return (words + [ident(match)]).joined(separator: " ") + " "
    }

    /// One editor row: a waypoint, the target its remove and move use, and the leg to it.
    public struct Point: Equatable, Sendable {
        public var title: String
        public var name: String?
        /// -1 is the first point of a route not flown from the aircraft.
        public var target: Int
        public var leg: RoutePlan.LegRow?
        public var waypoint: RouteWaypoint
    }

    public struct Editor: Equatable, Sendable {
        public var header: String
        public var points: [Point]
        public var totals: [NavPages.Line]
    }

    /// The aircraft's own point is not listed; a route between its own points lists its first.
    public static func editor(_ plan: RoutePlan, position: Position?, approximate: Bool = false, now: Date,
                              trueAirspeedKt: Double, fuelBurnPerHour: Double) -> Editor {
        let first = plan.fromAircraft ? 1 : 0
        let legs = plan.rows(position: position, approximate: approximate, now: now,
                             trueAirspeedKt: trueAirspeedKt > 0 ? trueAirspeedKt : nil)
        let points = plan.route.waypoints.dropFirst(first).enumerated().map { index, point in
            let target = index + first - 1
            return Point(title: point.airway.map { "\(point.ident) via \($0)" } ?? point.ident,
                         name: point.name == point.ident ? nil : point.name, target: target,
                         leg: legs.indices.contains(target) ? legs[target] : nil, waypoint: point)
        }
        let log = plan.navLog(position: position, approximate: approximate, now: now, trueAirspeedKt: trueAirspeedKt,
                              fuelBurnPerHour: fuelBurnPerHour)
        let totals = [
            NavPages.Line(title: "Distance", value: log.map { NavText.distance($0.totalDistanceNM) } ?? NavText.dashes),
            NavPages.Line(title: "Time", value: log?.totalTime.map(NavText.duration) ?? NavText.dashes),
            NavPages.Line(title: "Fuel", value: log?.totalFuel.map(NavText.fuel) ?? NavText.dashes),
        ]
        return Editor(header: plan.fromAircraft ? "From the aircraft" : "Waypoints", points: points, totals: totals)
    }

    /// The route in one line, for when its drawer is tucked away: the next waypoint and where it ends.
    public struct Summary: Equatable, Sendable, Encodable {
        public var ident: String
        public var detail: String
        public var end: String?
    }

    public static func summary(_ rows: [RoutePlan.LegRow]) -> Summary? {
        guard let next = rows.first(where: \.isActive) ?? rows.first else { return nil }
        let end = rows.last.flatMap { $0.id == next.id ? nil : "· \($0.waypoint.ident)" }
        return Summary(ident: next.waypoint.ident, detail: [next.distance, next.time].compactMap { $0 }.joined(separator: " "),
                       end: end)
    }
}

extension RoutePlan {
    /// Adds where the add button says: into the leg the point sits beside, else at the end.
    public static func adding(_ waypoint: RouteWaypoint, to plan: RoutePlan?, position: Position?, approximate: Bool = false,
                              now: Date, navCycle: String) -> RoutePlan {
        let target = NavPages.addSpot(waypoint.coordinate, route: plan, position: position, approximate: approximate,
                                      now: now).target
        if let target, let longer = plan?.inserting(waypoint, at: target) { return longer }
        return .appending(waypoint, to: plan, navCycle: navCycle)
    }
}

extension MapPick {
    /// The ends a grabbed part's rubber band stays fixed to, by point index in a drawn route of count points.
    public static func anchors(_ grab: RouteGrab, count: Int) -> [Int] {
        switch grab {
        case .leg(let index): [index, index + 1]
        case .point(let index): [index - 1, index + 1].filter { (0..<count).contains($0) }
        }
    }
}

extension MapPick.Snap {
    /// What the band says over the finger: the place it would snap to, or the tied places.
    public var label: String? {
        switch self {
        case .open: nil
        case .one(let place): place.ident
        case .choose(let places): places.map(\.ident).joined(separator: " · ")
        }
    }
}

extension NavDatabase {
    /// Places that could take a dropped point's place: within about 90 screen points, at most 5 NM, closest 3.
    public func useInstead(near point: Coordinate, metersPerPoint: Double) -> [WaypointMatch] {
        Array(((try? waypoints(near: point, withinNM: min(metersPerPoint * 90 / 1852, 5))) ?? []).prefix(3))
    }

    /// True for an airport on the route that is not operational.
    public func isClosed(_ waypoint: RouteWaypoint) -> Bool {
        guard waypoint.kind == .airport, let airport = try? airport(identifier: waypoint.ident) else { return false }
        return !airport.isOperational
    }
}
