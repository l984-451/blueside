import FlightCore
import Foundation
import Observation

/// What the navigation screens show: the open database, the search and its results, and the open airport.
@MainActor @Observable final class NavModel {
    private(set) var database: NavDatabase?
    /// Shown above the results when the data is missing or a read failed.
    private(set) var problem: String?
    private(set) var query = ""
    private(set) var results: [Airport] = []
    private(set) var detail: AirportDetail?
    /// A fixed time for the data currency line, set by tests. Nil means the real clock.
    var fixedNow: Date?

    /// The files in use, and the map style that draws the tile file. Nil when there is none.
    private(set) var files: NavFiles?
    private(set) var styleFile: URL?
    /// The active route; Direct To is a one-leg route from the aircraft. Nil when none is active.
    var route: RoutePlan?
    /// The brief open over the route panel, held here so turning the phone (sheet to card) keeps it.
    var brief: BriefJob?
    /// The last finished brief, shown again at once while nothing it was built from has changed.
    @ObservationIgnored var briefDone: BriefJob.Done?
    /// The packs the map can draw, for the brief's map.
    @ObservationIgnored var mapPacks: @MainActor () -> [PackFile] = { [] }
    @ObservationIgnored private var firstQuery: String?
    @ObservationIgnored private var firstRoute: String?
    /// The saved route until the data opens and it is parsed again.
    @ObservationIgnored private(set) var savedRoute: String?

    static let notDownloaded = NavPages.notDownloaded

    /// Reads the test launch options: a fixed clock and a search to run when the data opens.
    /// The saved route is parsed again once the data opens.
    func configure(options: LaunchOptions, savedRoute: String? = nil) {
        self.savedRoute = savedRoute
        fixedNow = options.string("navNow").flatMap { ISO8601DateFormatter().date(from: $0) }
        firstQuery = options.string("navQuery")
        firstRoute = options.string("navRoute")
    }

    /// True while files are being opened and no database is in use yet, as at launch. Views can wait on it
    /// rather than say the data is missing.
    private(set) var isOpeningFirst = false

    @ObservationIgnored private var opening: (files: NavFiles, task: Task<Void, Never>)? {
        didSet {
            let first = opening != nil && database == nil
            if first != isOpeningFirst { isOpeningFirst = first }
        }
    }

    /// Opens the given files off the main thread, or closes everything when there are none. The same files twice
    /// do nothing. What is open stays in use until the new database is; the task ends once it is.
    @discardableResult func use(_ new: NavFiles?) -> Task<Void, Never> {
        if let opening, opening.files == new { return opening.task }
        opening?.task.cancel()
        opening = nil
        guard new != files || (database == nil && problem == nil) else { return Task {} }
        guard let new else {
            switchTo(nil, opened: nil, style: nil)
            return Task {}
        }
        // With nothing open yet the tile style is set at once, so the map loads a single style at launch.
        let style = database == nil ? new.tiles.flatMap { NavOverlay.styleURL(tiles: $0) } : nil
        if database == nil { styleFile = style }
        let task = Task {
            let opened = await Task.detached(priority: .userInitiated) {
                Result { try NavDatabase(path: new.database.path) }
            }.value
            guard !Task.isCancelled else { return }
            opening = nil
            switchTo(new, opened: opened, style: style)
        }
        opening = (new, task)
        return task
    }

    // Puts opened files in use, then reads the search, the open page and the route again from them.
    private func switchTo(_ new: NavFiles?, opened: Result<NavDatabase, any Error>?, style: URL?) {
        files = new
        let page = detail?.airport.ident
        take(opened)
        styleFile = database == nil ? nil : style ?? new?.tiles.flatMap { NavOverlay.styleURL(tiles: $0) }
        guard database != nil else { return }
        // The typed search and the open page are read again from the new file.
        if let text = firstQuery {
            firstQuery = nil
            search(text)
        } else if !query.isEmpty {
            search(query)
        }
        if let page { show(ident: page) }
        // A test route, given as route text.
        if let text = firstRoute, let database {
            firstRoute = nil
            if let parse = try? RouteParser.parse(text, database: database, date: Date()), let made = try? Route(parse) {
                route = RoutePlan(route: made)
            }
        } else if route == nil, let database {
            route = RoutePages.restored(savedRoute, database: database, now: fixedNow ?? Date())
        }
        savedRoute = nil
    }

    /// Opens the page for an identifier read from the map. An unknown one leaves no page open.
    func show(ident: String) {
        guard let database, let found = try? database.airport(identifier: ident) else {
            detail = nil
            return
        }
        show(found)
    }

    // Replaces the database with an opened one, or none and the reason.
    private func take(_ opened: Result<NavDatabase, any Error>?) {
        database = nil
        quickLines = [:]
        results = []
        detail = nil
        // Rows from another database carry its row numbers, so they must not outlive it.
        nearest = NearestList()
        lastDetail = nil
        lastAirport = nil
        switch opened {
        case nil: problem = Self.notDownloaded
        case .success(let opened):
            database = opened
            problem = nil
        case .failure: problem = NavPages.unreadable
        }
    }

    /// Runs a search with the text exactly as typed. Nothing is added to it or taken from it.
    func search(_ text: String) {
        query = text
        guard let database else {
            results = []
            return
        }
        do {
            results = try database.search(text)
            problem = nil
        } catch {
            results = []
            problem = NavPages.searchFailed
        }
    }

    /// Opens the page for one airport.
    func show(_ airport: Airport) {
        guard let database else { return }
        do {
            detail = try database.detail(airportID: airport.id)
            problem = detail == nil ? "Airport not found" : nil
        } catch {
            detail = nil
            problem = "Airport page could not be read"
        }
    }

    func closePage() { detail = nil }

    private var navCycle: String { database?.metadata.cycle ?? "" }

    func directTo(_ waypoint: RouteWaypoint) { route = .direct(to: waypoint, navCycle: navCycle) }

    /// Appends to the active route, or starts one from the aircraft. A target puts it in at that leg instead.
    func addToRoute(_ waypoint: RouteWaypoint, at target: Int? = nil) {
        if let target, let longer = route?.inserting(waypoint, at: target) { route = longer; return }
        route = .appending(waypoint, to: route, navCycle: navCycle)
    }

    /// Adds where the add button says: into the leg it sits beside, else at the end.
    func add(_ waypoint: RouteWaypoint, position: Position?, approximate: Bool) {
        route = .adding(waypoint, to: route, position: position, approximate: approximate, now: Date(), navCycle: navCycle)
    }

    /// True for an airport on the route that is not operational.
    func isClosed(_ waypoint: RouteWaypoint) -> Bool { database?.isClosed(waypoint) ?? false }

    /// Where a point would join the route, and the add button's title for it.
    func addSpot(_ point: Coordinate, position: Position?, approximate: Bool = false,
                 now: Date) -> (target: Int?, title: String) {
        NavPages.addSpot(point, route: route, position: position, approximate: approximate, now: now)
    }

    /// The route before the last map edit, kept while Undo shows.
    private(set) var undoRoute: RoutePlan?

    /// A map edit that Undo can take back.
    func edit(_ plan: RoutePlan?) {
        guard let plan, plan != route else { return }
        undoRoute = route
        route = plan
    }

    func undoEdit() {
        if let undoRoute { route = undoRoute }
        undoRoute = nil
    }

    func dropUndo() { undoRoute = nil }

    @ObservationIgnored private var quickLines: [Int64: String] = [:]

    /// The airport's at-a-glance line for list rows, read once per airport.
    func quickLine(_ airport: Airport) -> String? {
        if let line = quickLines[airport.id] { return line.isEmpty ? nil : line }
        let line = database?.quickLine(airport) ?? ""
        quickLines[airport.id] = line
        return line.isEmpty ? nil : line
    }

    // The last airport looked up for a place card, so a redraw on each fix reads the file once.
    @ObservationIgnored private var lastDetail: (ident: String, database: NavDatabase, airport: Airport, detail: AirportDetail)?

    /// An airport and its page by identifier, from the open database.
    func airportDetail(_ ident: String) -> (Airport, AirportDetail)? {
        guard let database else { return nil }
        if let last = lastDetail, last.ident == ident, last.database === database { return (last.airport, last.detail) }
        guard let airport = try? database.airport(identifier: ident),
              let detail = try? database.detail(airportID: airport.id) else { return nil }
        lastDetail = (ident, database, airport, detail)
        return (airport, detail)
    }

    // The last airport asked for by identifier, so the route panel's IFR advice reads the file once per destination.
    @ObservationIgnored private var lastAirport: (ident: String, airport: Airport?)?

    /// An airport by identifier from the open database.
    func airport(_ ident: String) -> Airport? {
        if let last = lastAirport, last.ident == ident { return last.airport }
        guard let database else { return nil }
        let airport = try? database.airport(identifier: ident)
        lastAirport = (ident, airport)
        return airport
    }

    let favorites = Favorites()
    let aircraft = AircraftStore()
    let savedRoutes = SavedRouteStore()

    /// The favorites found in the open database, in the order added.
    // ponytail: one lookup per favorite on every redraw; cache if the list grows long.
    func favoriteAirports() -> [Airport] {
        guard let database else { return [] }
        return favorites.idents.compactMap { try? database.airport(identifier: $0) }
    }

    struct NearestRow: Equatable, Sendable, Identifiable {
        var airport: Airport
        var distance: String
        var bearing: String
        /// Degrees to turn from the aircraft's track to the airport; from north when the track is unknown.
        var turn: Double?
        var id: Int64 { airport.id }
    }

    private var nearest = NearestList()

    /// Works the list out again from a live, exact fix. With no fix, a stale or approximate one, or a failed read, the last list stays.
    func updateNearest(from position: Position?, approximate: Bool = false, now: Date) {
        nearest.update(database, from: position, approximate: approximate, now: now)
    }

    /// The list as shown, under a header that says where and when it was worked out.
    func nearestList(position: Position?, approximate: Bool = false,
                     now: Date) -> (header: String, rows: [NearestRow]) {
        let shown = nearest.shown(position: position, approximate: approximate, now: now)
        return (shown.header, shown.rows.map {
            NearestRow(airport: $0.airport, distance: $0.row.distance ?? NavText.dashes,
                       bearing: $0.row.bearing ?? NavText.dashes, turn: $0.row.turn)
        })
    }
}
