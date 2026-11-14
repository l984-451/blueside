/// A flight kept by name: the route text, the plan inputs and the W&B load that go with it. Read again against the nav cycle in use on load.
public struct SavedRoute: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var text: String
    /// The route as it resolved when saved, to tell what moved since. Nil for a single point flown from the aircraft.
    public var route: Route?
    public var cruiseAltitudeFt: Int
    public var rules: FlightPlanInputs.Rules
    public var alternate: String?
    /// Nil in files from before flights were saved whole.
    public var departure: Date?
    public var aircraftID: UUID?
    public var load: FlightLoad?

    public init(id: UUID = UUID(), name: String, plan: RoutePlan, inputs: FlightPlanInputs, load: FlightLoad? = nil) {
        self.id = id
        self.name = name
        text = plan.text
        route = plan.fromAircraft ? Route(waypoints: plan.targets, navCycle: plan.route.navCycle) : plan.route
        cruiseAltitudeFt = inputs.cruiseAltitudeFt
        rules = inputs.rules
        alternate = inputs.alternate?.ident
        departure = inputs.departure
        aircraftID = inputs.aircraftID
        self.load = load
    }
}

/// The device's offset from UTC now, and across its next clock change. The core has no time zone data.
public struct LocalOffset: Codable, Equatable, Sendable {
    public var seconds: Int
    public var nextChange: Date?
    public var secondsAfter: Int?

    public init(seconds: Int, nextChange: Date? = nil, secondsAfter: Int? = nil) {
        (self.seconds, self.nextChange, self.secondsAfter) = (seconds, nextChange, secondsAfter)
    }

    /// The offset in force at a date.
    // ponytail: one change only; a date past the change after next, or before the last one, reads an hour off.
    // Carry more changes if that matters.
    public func seconds(at date: Date) -> Int {
        guard let nextChange, let secondsAfter, date >= nextChange else { return seconds }
        return secondsAfter
    }
}

/// The saved and recent routes, kept in one local file.
public struct SavedRoutes: Codable, Equatable, Sendable {
    public static let format = "blueside-routes"
    public static let version = 1
    public static let recentLimit = 10
    public static let fileName = "routes.json"

    public enum Unreadable: Error, Equatable { case notRoutes, newerVersion(Int) }

    public private(set) var saved: [SavedRoute] = []
    public private(set) var recent: [SavedRoute] = []

    public init() {}

    private struct Head: Decodable { var format: String?; var version: Int? }
    private struct File: Codable {
        var format = SavedRoutes.format
        var version = SavedRoutes.version
        var saved: [SavedRoute]
        var recent: [SavedRoute]
    }

    /// No file, or an empty one, is no routes. Throws for a file it cannot read, so it is never written over.
    public static func decode(_ data: Data?) throws -> SavedRoutes {
        guard let data, !data.isEmpty else { return SavedRoutes() }
        let head = try JSONDecoder().decode(Head.self, from: data)
        guard head.format == format else { throw Unreadable.notRoutes }
        guard head.version == version else { throw Unreadable.newerVersion(head.version ?? 0) }
        let file = try JSONDecoder().decode(File.self, from: data)
        var out = SavedRoutes()
        out.saved = file.saved
        out.recent = file.recent
        return out
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(File(saved: saved, recent: recent))
    }

    /// First and last point, as KAUS to KDAL; one point alone is its own name.
    public static func defaultName(_ plan: RoutePlan) -> String {
        let words = plan.text.split(separator: " ").filter { $0 != "DCT" }.map(String.init)
        guard let first = words.first, let last = words.last else { return "" }
        return words.count == 1 ? first : "\(first) to \(last)"
    }

    /// Newest first. A blank name takes the default; a route saved under a name already kept replaces it.
    public func saving(_ plan: RoutePlan, inputs: FlightPlanInputs, name: String, load: FlightLoad? = nil) -> SavedRoutes {
        let typed = name.trimmed
        let entry = SavedRoute(name: typed.isEmpty ? Self.defaultName(plan) : typed, plan: plan, inputs: inputs, load: load)
        var out = self
        out.saved.removeAll { $0.name.lowercased() == entry.name.lowercased() }
        out.saved.insert(entry, at: 0)
        return out
    }

    /// A blank name changes nothing.
    public func renaming(_ id: UUID, to name: String) -> SavedRoutes {
        let typed = name.trimmed
        var out = self
        guard !typed.isEmpty, let i = out.saved.firstIndex(where: { $0.id == id }) else { return self }
        out.saved[i].name = typed
        return out
    }

    public func removing(_ id: UUID) -> SavedRoutes {
        var out = self
        out.saved.removeAll { $0.id == id }
        out.recent.removeAll { $0.id == id }
        return out
    }

    /// Puts a flown or loaded route at the top of Recent, once by its text, keeping the last ten.
    public func noting(_ plan: RoutePlan, inputs: FlightPlanInputs) -> SavedRoutes {
        let entry = SavedRoute(name: Self.defaultName(plan), plan: plan, inputs: inputs)
        guard !entry.text.isEmpty else { return self }
        var out = self
        out.recent.removeAll { $0.text == entry.text }
        out.recent.insert(entry, at: 0)
        out.recent = Array(out.recent.prefix(Self.recentLimit))
        return out
    }

    public func route(_ id: UUID) -> SavedRoute? { (saved + recent).first { $0.id == id } }

    // MARK: Page

    /// One list row: the name, the route text, and departure, altitude, rules and alternate.
    public struct Row: Equatable, Sendable, Encodable, Identifiable {
        public var id: UUID
        public var name: String
        public var text: String
        public var detail: String
    }

    /// The departure in the local time in force on its date.
    public static func row(_ route: SavedRoute, localOffset: LocalOffset) -> Row {
        let when = route.departure.map { d -> String in
            let t = UTCTime(d + TimeInterval(localOffset.seconds(at: d)))
            return "\(NavText.pad(t.day, 2)) \(t.monthName) \(NavText.pad(t.hour, 2))\(NavText.pad(t.minute, 2)) local"
        }
        let parts = (when.map { [$0] } ?? []) + ["\(NavText.grouped(route.cruiseAltitudeFt)) ft", RoutePages.rulesName(route.rules)]
            + (route.alternate.map { ["Alternate \($0)"] } ?? [])
        return Row(id: route.id, name: route.name, text: route.text, detail: parts.joined(separator: " · "))
    }

    /// Flights still to come first, soonest first; the rest as saved.
    public func savedRows(now: Date, localOffset: LocalOffset) -> [Row] {
        let upcoming = saved.filter { ($0.departure ?? now) > now }.sorted { $0.departure! < $1.departure! }
        let rest = saved.filter { ($0.departure ?? now) <= now }
        return (upcoming + rest).map { Self.row($0, localOffset: localOffset) }
    }

    public func recentRows(localOffset: LocalOffset) -> [Row] { recent.map { Self.row($0, localOffset: localOffset) } }

    /// What loading a route gives. With problems the plan is nil and the active route stays; the text goes in the field.
    public struct Loaded: Equatable, Sendable {
        public var text: String
        public var plan: RoutePlan?
        public var inputs: FlightPlanInputs
        public var problems: [String]
        public var notes: [String]
        /// The saved W&B load, only when its aircraft is still here.
        public var load: FlightLoad?

        /// As the route field shows it: problems and notes, no suggestions.
        public var typed: RoutePages.Typed {
            RoutePages.Typed(suggestions: [], problems: problems, notes: notes, plan: plan, replaces: plan != nil)
        }
    }

    /// Parses the text against the database in use, says what moved since it was saved, and finds the alternate again.
    /// A departure still to come and an aircraft still here come back; otherwise the current ones stay.
    public static func load(_ saved: SavedRoute, inputs: FlightPlanInputs, database: NavDatabase, now: Date,
                            aircraft: [AircraftProfile] = []) -> Loaded {
        let typed = RoutePages.typed(saved.text, plan: nil, database: database, now: now)
        var notes = typed.notes
        // Points that are gone the parser already reports.
        let changes = (try? saved.route?.revalidated(against: database, date: now)) ?? []
        for change in changes {
            let ident = change.waypoint.ident
            switch change.kind {
            case .missing: break
            case .moved(let nm): notes.append("\(ident) moved \(NavText.distance(nm)) since the route was saved")
            case .airwayChanged: notes.append("\(change.waypoint.airway ?? "The airway") no longer runs to \(ident)")
            }
        }
        var next = inputs
        next.cruiseAltitudeFt = saved.cruiseAltitudeFt
        next.rules = saved.rules
        next.alternate = saved.alternate.flatMap { RoutePages.alternate($0, database: database) }
        if let departure = saved.departure, departure > now { next.departure = departure }
        let craft = saved.aircraftID.flatMap { id in aircraft.first { $0.id == id } }
        if let craft { next.aircraftID = craft.id }
        if let alternate = saved.alternate, next.alternate == nil {
            notes.append("Alternate \(alternate) is not in this nav cycle")
        }
        return Loaded(text: saved.text, plan: typed.replaces ? typed.plan : nil, inputs: next,
                      problems: typed.problems, notes: notes, load: craft == nil ? nil : saved.load)
    }
}

extension RoutePages {
    public static let savedTitle = "Flights"
    public static let saveRoute = "Save Flight"
    public static let savedSection = "Saved"
    public static let recentSection = "Recent"
    public static let routeName = "Name"
    public static let rename = "Rename"
    public static let delete = "Delete"
    public static let save = "Save"
    public static let cancel = "Cancel"
    public static let noSaved = "No saved flights. Save Flight in the route editor keeps the flight here."
    public static let savedUnreadable = "Saved flights could not be read. They are left as they are."
}
