import FlightCore

/// Saved flights and recent routes. Kotlin reads and writes routes.json's text; the core does the rest.
extension Bridge {
    /// One edit at most: save the plan under `save`, rename `rename` to `name`, remove `remove`, or note the plan in
    /// Recent. `stored` is the plan inputs' text, `load` the W&B load saved with the flight, `localOffset` the
    /// device's offset from UTC with its next change.
    struct SavedArgs: Decodable {
        var file: String?
        var plan: RoutePlan?
        var stored: String?
        var now: Date
        var save: String?
        var rename: UUID?
        var name: String?
        var remove: UUID?
        var recent: Bool?
        var load: FlightLoad?
        /// The aircraft flown, saved with the flight even when the inputs name none.
        var aircraft: UUID?
        var localOffset: LocalOffset?
    }

    struct SavedView: Encodable {
        var saved: [SavedRoutes.Row] = []
        var recent: [SavedRoutes.Row] = []
        /// The name Save Route offers for the plan.
        var defaultName: String?
        /// Text to write back to routes.json, set when it changed.
        var file: String?
        /// Set when routes.json could not be read; Kotlin then never writes it.
        var problem: String?
    }

    /// `aircraft` is aircraft.json's text, so a flight's aircraft and load come back only while it is still there.
    struct LoadRouteArgs: Decodable { var file: String?; var id: UUID; var stored: String?; var now: Date; var aircraft: String? }

    /// With problems, plan is nil and the field shows text. Inputs are to keep, file to write back.
    struct LoadedRoute: Encodable {
        var text: String
        var plan: RoutePlan?
        var problems: [String]
        var notes: [String]
        var inputs: PlanInputs
        var load: FlightLoad?
        var file: String?
    }

    static func savedFile(_ routes: SavedRoutes) throws -> String { String(decoding: try routes.encoded(), as: UTF8.self) }

    static func savedRoutes(_ a: SavedArgs) throws -> SavedView {
        guard let before = try? SavedRoutes.decode(a.file.map { Data($0.utf8) }) else {
            return SavedView(problem: RoutePages.savedUnreadable)
        }
        var inputs = RoutePages.planInputs(stored: a.stored.map { Data($0.utf8) }, now: a.now)
        if let id = a.aircraft { inputs.aircraftID = id }
        var routes = before
        if let plan = a.plan, let name = a.save { routes = routes.saving(plan, inputs: inputs, name: name, load: a.load) }
        if let id = a.rename, let name = a.name { routes = routes.renaming(id, to: name) }
        if let id = a.remove { routes = routes.removing(id) }
        if let plan = a.plan, a.recent == true { routes = routes.noting(plan, inputs: inputs) }
        let offset = a.localOffset ?? LocalOffset(seconds: 0)
        return SavedView(saved: routes.savedRows(now: a.now, localOffset: offset),
                         recent: routes.recentRows(localOffset: offset),
                         defaultName: a.plan.map(SavedRoutes.defaultName),
                         file: routes == before ? nil : try savedFile(routes))
    }

    static func loadRoute(_ nav: NavSession, _ a: LoadRouteArgs) throws -> LoadedRoute {
        let routes = try SavedRoutes.decode(a.file.map { Data($0.utf8) })
        guard let saved = routes.route(a.id) else { throw Failure.notFound(a.id.uuidString) }
        let inputs = RoutePages.planInputs(stored: a.stored.map { Data($0.utf8) }, now: a.now)
        let aircraft = a.aircraft.flatMap { try? AircraftProfile.decodeList(Data($0.utf8)) } ?? []
        let loaded = SavedRoutes.load(saved, inputs: inputs, database: nav.database, now: a.now, aircraft: aircraft)
        let noted = loaded.plan.map { routes.noting($0, inputs: loaded.inputs) }
        return LoadedRoute(text: loaded.text, plan: loaded.plan, problems: loaded.problems, notes: loaded.notes,
                           inputs: planInputs(loaded.inputs), load: loaded.load, file: try noted.map(savedFile))
    }
}
