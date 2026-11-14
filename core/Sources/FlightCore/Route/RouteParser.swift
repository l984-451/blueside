public enum RouteProblemKind: String, Equatable, Sendable {
    case unknownIdentifier
    /// The point before or after an airway is not on that airway.
    case pointNotOnAirway
    /// Both points are on the airway, with a break between them.
    case airwayBroken
    case malformedCoordinate
    /// An airway name with no point before it or after it.
    case airwayWithoutPoint
    /// An airway straight after an airway, with no point on both.
    case airwaysDoNotMeet
    /// An airway straight after an airway, where the point to change at has to be typed.
    case airwaysMeetMoreThanOnce
    /// A fix, radial and distance whose numbers are out of range or whose station has no variation that can be used.
    case badRadialDistance
}

public struct RouteProblem: Equatable, Sendable {
    /// Index among the space-separated tokens, from 0, counting DCT.
    public var position: Int
    public var token: String
    public var kind: RouteProblemKind
}

/// The other matches for an identifier that was found more than once.
public struct RouteAlternative: Equatable, Sendable {
    /// Index into the parse's waypoints of the match that was chosen.
    public var waypointIndex: Int
    public var position: Int
    public var choices: [RouteWaypoint]
}

/// What a route text resolved to. Waypoints are for display; only a parse with no problems makes a Route.
public struct RouteParse: Equatable, Sendable {
    public var waypoints: [RouteWaypoint]
    public var problems: [RouteProblem]
    public var alternatives: [RouteAlternative]
    public var navCycle: String
}

public enum RouteError: Error, Equatable {
    case hasProblems([RouteProblem])
    case tooFewWaypoints
}

public enum RouteChangeKind: Equatable, Sendable {
    case missing
    case moved(distanceNM: Double)
    /// The airway no longer joins this waypoint to the one before it as neighbours on one run.
    case airwayChanged
}

public struct RouteChange: Equatable, Sendable {
    public var index: Int
    public var waypoint: RouteWaypoint
    public var kind: RouteChangeKind
}

public enum RouteParser {
    /// A match farther than this from the route never wins over a nearer one.
    public static let ambiguityLimitNM = 500.0
    /// An airport and a navaid with one identifier this close together are one place by name.
    static let colocatedNM = 30.0

    private enum Role {
        case point([RouteWaypoint])
        case airway([AirwayRun])
        case bad
    }

    /// Every airport, navaid and fix the token could mean. Test signals and fan markers are left out.
    /// With a date, a token that names nothing is tried as a fix, radial and distance.
    static func candidates(_ token: String, _ database: NavDatabase, date: Date? = nil) throws -> [RouteWaypoint] {
        if let position = RouteText.coordinate(token) { return [.user(at: position)] }
        var out: [RouteWaypoint] = []
        if let airport = try database.airport(identifier: token) { out.append(RouteWaypoint(airport: airport)) }
        out += try database.navaids(ident: token).filter { $0.isRoutePoint }.map { RouteWaypoint(navaid: $0) }
        out += try database.fixes(ident: token).map { RouteWaypoint(fix: $0) }
        if out.isEmpty, let date { out = try radialPoints(token, database, date: date) }
        return out
    }

    /// User waypoints for a token such as CLL090020, one per station with that identifier.
    /// Empty when the token is not that form, a number is out of range, or a station has no usable variation.
    static func radialPoints(_ token: String, _ database: NavDatabase, date: Date) throws -> [RouteWaypoint] {
        guard let parts = RouteText.fixRadialDistance(token), parts.radial <= 360, parts.distanceNM > 0 else {
            return []
        }
        // Outside the years the model was made for it gives no variation, so the token is a problem.
        func model(_ place: Coordinate) -> Double? {
            MagneticModel.covers(date) ? MagneticModel.declination(at: place, altitudeFt: 0, date: date) : nil
        }
        // A navaid's radials follow the variation it was aligned to, which can be years old.
        // A beacon, or one with none published, is read by compass and takes the model, as a fix or an airport does.
        var stations: [(place: Coordinate, variation: Double?)] = []
        let named = try database.navaids(ident: parts.ident).filter { $0.isRoutePoint }
        let beacons = named.filter { $0.type.contains("NDB") }
        for navaid in named where !navaid.type.contains("NDB") {
            if let published = navaid.magneticVariation, !published.isEmpty {
                stations.append((navaid.coordinate, RouteText.variationDegrees(published)))
            } else {
                stations.append((navaid.coordinate, model(navaid.coordinate)))
            }
        }
        // A beacon beside a station of the same name that sends radials is that station. One elsewhere is its own.
        let senders = stations.map { $0.place }
        for beacon in beacons
        where !senders.contains(where: { Geo.distanceNM(from: $0, to: beacon.coordinate) <= colocatedNM }) {
            stations.append((beacon.coordinate, model(beacon.coordinate)))
        }
        // A fix or an airport beside a navaid of the same name is that navaid. One elsewhere is its own station.
        let navaids = named.map(\.coordinate)
        var others = try database.fixes(ident: parts.ident).map(\.coordinate)
        if let airport = try database.airport(identifier: parts.ident) { others.append(airport.coordinate) }
        for place in others
        where !navaids.contains(where: { Geo.distanceNM(from: $0, to: place) <= colocatedNM }) {
            stations.append((place, model(place)))
        }
        let name = token.uppercased()
        var out: [RouteWaypoint] = []
        for station in stations {
            // A variation that cannot be read is never replaced by a guess.
            guard let variation = station.variation,
                  let point = Geo.destination(from: station.place, bearingTrue: Double(parts.radial) + variation,
                                              distanceNM: Double(parts.distanceNM)) else { return [] }
            out.append(RouteWaypoint(kind: .user, ident: name, name: name, coordinate: RouteText.rounded(point)))
        }
        return out
    }

    /// Where a navaid or fix sits on a run: same identifier, within a mile of the airway's point.
    static func index(of waypoint: RouteWaypoint, in run: AirwayRun) -> Int? {
        guard waypoint.kind == .navaid || waypoint.kind == .fix else { return nil }
        return run.points.firstIndex {
            $0.ident == waypoint.ident && Geo.distanceNM(from: $0.coordinate, to: waypoint.coordinate) < 1
        }
    }

    private static func isOn(_ waypoint: RouteWaypoint, _ runs: [AirwayRun]) -> Bool {
        runs.contains { index(of: waypoint, in: $0) != nil }
    }

    /// The database record for a point of a run, or a plain fix at the airway's own position.
    private static func waypoint(for point: AirwayPoint, in run: AirwayRun,
                                 _ database: NavDatabase) throws -> RouteWaypoint {
        let record = try candidates(point.ident, database).first { index(of: $0, in: run) != nil }
        return record ?? RouteWaypoint(kind: .fix, ident: point.ident, name: point.ident, coordinate: point.coordinate)
    }

    /// The points two airways share: one identifier within a mile, as for an entry or an exit.
    /// Each comes with every record a typed point there would keep.
    private static func junctions(_ first: [AirwayRun], _ second: [AirwayRun],
                                  _ database: NavDatabase) throws -> [RouteWaypoint] {
        var out: [RouteWaypoint] = []
        for run in first {
            for point in run.points {
                let shared = second.contains { other in
                    other.points.contains {
                        $0.ident == point.ident && Geo.distanceNM(from: $0.coordinate, to: point.coordinate) < 1
                    }
                }
                guard shared else { continue }
                var found = try candidates(point.ident, database).filter { isOn($0, first) && isOn($0, second) }
                if found.isEmpty { found = [try waypoint(for: point, in: run, database)] }
                out += found.filter { !out.contains($0) }
            }
        }
        return out
    }

    /// The run that holds two points and its points strictly between them, in the direction flown.
    /// Nil when no run holds both, or they are the same point.
    private static func span(_ entry: RouteWaypoint, _ exit: RouteWaypoint,
                             _ runs: [AirwayRun]) -> (run: AirwayRun, inner: [AirwayPoint])? {
        for run in runs {
            guard let from = index(of: entry, in: run), let to = index(of: exit, in: run), from != to else { continue }
            return (run, from < to ? Array(run.points[(from + 1)..<to]) : Array(run.points[(to + 1)..<from].reversed()))
        }
        return nil
    }

    /// The span's points as waypoints on the named airway.
    private static func between(_ entry: RouteWaypoint, _ exit: RouteWaypoint, _ runs: [AirwayRun],
                                _ name: String, _ database: NavDatabase) throws -> [RouteWaypoint]? {
        guard let (run, inner) = span(entry, exit, runs) else { return nil }
        return try inner.map { point in
            var next = try waypoint(for: point, in: run, database)
            next.airway = name
            return next
        }
    }

    /// One airway and the points it may be left at.
    private typealias Leg = (runs: [AirwayRun], ends: [RouteWaypoint])

    /// More different ways than this through a chain of airways are not sorted out: the junction must be typed.
    static let wayLimit = 500

    /// The first leg's ends that lead through every leg in order, passing no place twice, and whether
    /// they all fly the same places. With too many ways to tell: the ends found so far, and not the same.
    private static func through(from entry: RouteWaypoint, _ legs: [Leg],
                                past: [RouteWaypoint]) -> (usable: [RouteWaypoint], same: Bool) {
        // Places are numbered by the rule that puts a point on an airway: one identifier, within a mile.
        var numbered: [String: [(at: Coordinate, number: Int)]] = [:]
        var count = 0
        func number(_ ident: String, _ at: Coordinate) -> Int {
            if let known = numbered[ident]?.first(where: { Geo.distanceNM(from: $0.at, to: at) < 1 }) {
                return known.number
            }
            numbered[ident, default: []].append((at, count))
            count += 1
            return count - 1
        }
        func onAirway(_ waypoint: RouteWaypoint) -> Int? {
            waypoint.kind == .navaid || waypoint.kind == .fix ? number(waypoint.ident, waypoint.coordinate) : nil
        }
        let passed = Set(past.map { number($0.ident, $0.coordinate) })
        guard let start = onAirway(entry) else { return ([], true) }

        // Each different list of places flown so far, with the first-leg ends that lead to it.
        // Ways that fly the same places are kept once, so the work does not multiply at each join.
        var ways: [[Int]: Set<Int>] = [[start]: []]
        var tooMany = false
        chain: for (n, leg) in legs.enumerated() {
            let runs = leg.runs.map { run in run.points.map { number($0.ident, $0.coordinate) } }
            let ends = Set(leg.ends.compactMap(onAirway))
            var longer: [[Int]: Set<Int>] = [:]
            for (way, firstEnds) in ways {
                guard let from = way.last else { continue }
                let behind = passed.union(way)
                for end in ends where !behind.contains(end) {
                    // The first run that holds both, as for a typed entry and exit.
                    var flown: [Int]?
                    for run in runs {
                        guard let a = run.firstIndex(of: from), let b = run.firstIndex(of: end) else { continue }
                        flown = a < b ? Array(run[(a + 1)...b]) : Array(run[b..<a].reversed())
                        break
                    }
                    guard let flown, !flown.contains(where: behind.contains) else { continue }
                    longer[way + flown, default: []].formUnion(n == 0 ? [end] : firstEnds)
                    if longer.count > wayLimit {
                        tooMany = true
                        break chain
                    }
                }
            }
            ways = longer
        }
        let usable = ways.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        return (legs.first?.ends.filter { onAirway($0).map(usable.contains) ?? false } ?? [],
                !tooMany && ways.values.allSatisfy { $0 == usable })
    }

    /// Picks one of several matches. The reference is the previous waypoint, or the next token's matches.
    private static func choose(_ matches: [RouteWaypoint], isEnd: Bool, reference: [Coordinate]) -> Int {
        guard matches.count > 1 else { return 0 }
        let distances = matches.map { match in
            reference.map { Geo.distanceNM(from: $0, to: match.coordinate) }.min() ?? 0
        }
        var nearest = 0
        for i in distances.indices where distances[i] < distances[nearest] { nearest = i }
        if isEnd, let airport = matches.firstIndex(where: { $0.kind == .airport }) {
            // A route starts and ends at an airport, unless that airport is far away and something nearer matches.
            return distances[airport] > ambiguityLimitNM && distances[nearest] < distances[airport] ? nearest : airport
        }
        if matches[nearest].kind == .airport {
            // In the middle of a route a name shared by an airport and its navaid means the navaid.
            let partner = matches.indices.first { i in
                matches[i].kind != .airport && distances[i] <= ambiguityLimitNM
                    && Geo.distanceNM(from: matches[i].coordinate, to: matches[nearest].coordinate) <= colocatedNM
            }
            if let partner { return partner }
        }
        return nearest
    }

    /// Resolves route text against the database. Problems are reported and never guessed around.
    /// The date sets the magnetic variation for a radial from a fix or an airport.
    public static func parse(_ text: String, database: NavDatabase, date: Date) throws -> RouteParse {
        let all = text.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var tokens: [(position: Int, text: String, implied: Bool)] = []
        for (position, token) in all.enumerated() where token != "DCT" {
            tokens.append((position, token, false))
        }
        var problems: [RouteProblem] = []

        // First pass: what each token is.
        var roles: [Role] = []
        for (i, token) in tokens.enumerated() {
            let found = try candidates(token.text, database, date: date)
            let runs = try database.airway(named: token.text)
            var afterPoint = false
            var afterAirway = false
            if let last = roles.last {
                if case .point = last { afterPoint = true }
                if case .airway = last { afterAirway = true }
            }
            // Straight after an airway, a name that is also a point is that airway's exit.
            if !runs.isEmpty, i + 1 < tokens.count, afterPoint || (afterAirway && found.isEmpty) {
                roles.append(.airway(runs))
            } else if !found.isEmpty {
                roles.append(.point(found))
            } else {
                let kind: RouteProblemKind
                if !runs.isEmpty {
                    kind = .airwayWithoutPoint
                } else if RouteText.looksLikeCoordinate(token.text) {
                    kind = .malformedCoordinate
                } else if let parts = RouteText.fixRadialDistance(token.text),
                          try !candidates(parts.ident, database).isEmpty {
                    // The station exists, so the trouble is in the numbers or the station's variation.
                    kind = .badRadialDistance
                } else {
                    kind = .unknownIdentifier
                }
                problems.append(RouteProblem(position: token.position, token: token.text, kind: kind))
                roles.append(.bad)
            }
        }

        // An airway straight after an airway: a point both share stands between them, as if it had been typed.
        var at = 1
        while at < tokens.count {
            if case .airway(let first) = roles[at - 1], case .airway(let second) = roles[at] {
                let shared = try junctions(first, second, database)
                if shared.isEmpty {
                    problems.append(RouteProblem(position: tokens[at].position, token: tokens[at].text,
                                                 kind: .airwaysDoNotMeet))
                    roles[at] = .bad
                } else {
                    tokens.insert((tokens[at].position, shared[0].ident, true), at: at)
                    roles.insert(.point(shared), at: at)
                    at += 1
                }
            }
            at += 1
        }

        // Second pass: choose one match per point and fill in the airways.
        var waypoints: [RouteWaypoint] = []
        var alternatives: [RouteAlternative] = []
        /// Where the latest typed point sits in the waypoints.
        var typedAt = 0
        /// The first untyped junction that no way through could be found for.
        var unjoined: RouteProblem?
        for (i, token) in tokens.enumerated() {
            guard case .point(let found) = roles[i] else { continue }
            var before: [AirwayRun]?
            var after: [AirwayRun]?
            if i > 0, case .airway(let runs) = roles[i - 1] { before = runs }
            if i + 1 < tokens.count, case .airway(let runs) = roles[i + 1] { after = runs }

            var pool = found
            var onAirways = true
            for runs in [before, after].compactMap({ $0 }) {
                let kept = pool.filter { isOn($0, runs) }
                if kept.isEmpty { onAirways = false } else { pool = kept }
            }
            let nextToAirway = before != nil || after != nil
            if !onAirways {
                problems.append(RouteProblem(position: token.position, token: token.text, kind: .pointNotOnAirway))
                pool = found
            }
            if token.implied, let entry = waypoints.last, let first = before {
                // The airways on from here, up to the next typed point.
                var rest: [Leg] = []
                var k = i
                var reachesTyped = false
                while !reachesTyped, k + 2 < tokens.count,
                      case .airway(let runs) = roles[k + 1], case .point(let ends) = roles[k + 2] {
                    rest.append((runs, ends))
                    reachesTyped = !tokens[k + 2].implied
                    k += 2
                }
                // A token past the chain that could not be read has its own problem already.
                if reachesTyped {
                    let second = RouteProblem(position: tokens[i + 1].position, token: tokens[i + 1].text,
                                              kind: .airwaysMeetMoreThanOnce)
                    let found = through(from: entry, [(first, pool)] + rest, past: Array(waypoints[typedAt...]))
                    if found.usable.isEmpty {
                        // Kept for the end: the nearest shared point below usually names a plainer problem.
                        unjoined = unjoined ?? second
                    } else {
                        // The junction is only picked when every usable one flies the same places.
                        if !found.same { problems.append(second) }
                        pool = found.usable
                    }
                }
            }

            var reference: [Coordinate] = []
            if let last = waypoints.last {
                reference = [last.coordinate]
            } else {
                for role in roles[(i + 1)...] {
                    if case .point(let next) = role {
                        reference = next.map(\.coordinate)
                        break
                    }
                }
            }
            let isEnd = (i == 0 || i == tokens.count - 1) && !(nextToAirway && onAirways)
            var chosen = pool[choose(pool, isEnd: isEnd, reference: reference)]

            // The token before an airway is always a point, so the last waypoint is the entry.
            if let runs = before, let entry = waypoints.last {
                let name = tokens[i - 1].text
                if let stretch = try between(entry, chosen, runs, name, database) {
                    waypoints += stretch
                    chosen.airway = name
                } else if isOn(entry, runs), isOn(chosen, runs) {
                    problems.append(RouteProblem(position: tokens[i - 1].position, token: name, kind: .airwayBroken))
                }
            }

            // A junction that was not typed has no token for a screen to offer other meanings for.
            let lost = found.filter { !$0.isSamePlace(as: chosen) }
            if !lost.isEmpty, !token.implied {
                alternatives.append(RouteAlternative(waypointIndex: waypoints.count, position: token.position, choices: lost))
            }
            if !token.implied { typedAt = waypoints.count }
            waypoints.append(chosen)
        }

        // Airways that join only by passing a place twice are not flown without the junction typed.
        if problems.isEmpty, let unjoined { problems.append(unjoined) }
        problems.sort { $0.position < $1.position }
        return RouteParse(waypoints: waypoints, problems: problems, alternatives: alternatives,
                          navCycle: database.metadata.cycle)
    }
}

extension Route {
    /// Fails for a parse with any problem, so text that was not fully understood is never flown.
    public init(_ parse: RouteParse) throws {
        guard parse.problems.isEmpty else { throw RouteError.hasProblems(parse.problems) }
        guard let route = Route(waypoints: parse.waypoints, navCycle: parse.navCycle) else {
            throw RouteError.tooFewWaypoints
        }
        self = route
    }

    /// False when routeText would parse to other waypoints, as after an edit that left a navaid at an end.
    /// A radial from a fix moves slowly with the date: within 0.1 nm it is still the same point.
    public func textReadsBack(against database: NavDatabase, date: Date) throws -> Bool {
        let parsed = try RouteParser.parse(routeText, database: database, date: date)
        guard let again = (try? Route(parsed))?.waypoints, again.count == waypoints.count else { return false }
        for (a, b) in zip(again, waypoints) where a != b {
            guard a.kind == .user, b.kind == .user, a.ident == b.ident, a.airway == b.airway,
                  RouteText.fixRadialDistance(a.ident) != nil,
                  Geo.distanceNM(from: a.coordinate, to: b.coordinate) < 0.1 else { return false }
        }
        return true
    }

    /// Looks every airport, navaid, fix and airway leg up again, and works each radial point out again at the date.
    /// Empty when nothing has gone, nothing has moved more than 0.1 nm, and each airway leg still joins neighbours.
    public func revalidated(against database: NavDatabase, date: Date) throws -> [RouteChange] {
        var changes: [RouteChange] = []
        for (index, waypoint) in waypoints.enumerated()
        where waypoint.kind != .user || RouteText.fixRadialDistance(waypoint.ident) != nil {
            let same = try RouteParser.candidates(waypoint.ident, database, date: date)
                .filter { $0.kind == waypoint.kind && $0.ident == waypoint.ident }
            let nearest = same.map { Geo.distanceNM(from: $0.coordinate, to: waypoint.coordinate) }.min()
            if let nearest {
                if nearest > 0.1 {
                    changes.append(RouteChange(index: index, waypoint: waypoint, kind: .moved(distanceNM: nearest)))
                }
            } else {
                changes.append(RouteChange(index: index, waypoint: waypoint, kind: .missing))
            }
            // A leg marked with an airway must still be two neighbouring points of one run.
            if index > 0, let airway = waypoint.airway {
                let before = waypoints[index - 1]
                let joined = try database.airway(named: airway).contains { run in
                    guard let a = RouteParser.index(of: before, in: run),
                          let b = RouteParser.index(of: waypoint, in: run) else { return false }
                    return abs(a - b) == 1
                }
                if !joined { changes.append(RouteChange(index: index, waypoint: waypoint, kind: .airwayChanged)) }
            }
        }
        return changes
    }
}
