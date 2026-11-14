import FlightCore

/// An open navigation database and what the screens keep between calls: the nearest list and quick lines.
final class NavSession {
    let database: NavDatabase
    var nearest = NearestList()
    var quickLines: [Int64: String?] = [:]

    init(path: String) throws { database = try NavDatabase(path: path) }

    func quick(_ airport: Airport) -> String? {
        if let line = quickLines[airport.id] { return line }
        let line = database.quickLine(airport)
        quickLines[airport.id] = line
        return line
    }
}

/// Nav ops on an open handle: the search panel, the airport page, the place card and map picks.
extension Bridge {
    /// A place as both sides name it. The app sends it back to open or route the place.
    struct Place: Codable, Equatable {
        var kind: WaypointKind
        var ident: String
        var icao: String?
        var name: String
        var latitude: Double
        var longitude: Double

        init(_ m: WaypointMatch) {
            (kind, ident, icao, name) = (m.kind, m.ident, m.icao, m.name)
            (latitude, longitude) = (m.coordinate.latitude, m.coordinate.longitude)
        }

        init(_ a: Airport) { self.init(WaypointMatch(kind: .airport, ident: a.ident, icao: a.icao, name: a.name, coordinate: a.coordinate)) }

        var match: WaypointMatch {
            WaypointMatch(kind: kind, ident: ident, icao: icao, name: name,
                          coordinate: Coordinate(latitude: latitude, longitude: longitude))
        }
    }

    struct Item: Encodable { var row: NavPages.Row; var place: Place }

    struct ListSection: Encodable {
        var title: String?
        var items: [Item]
        var empty: String?
        /// The favorites, whose rows offer Remove.
        var removable = false
    }

    /// The fixed words of the nav screens.
    struct Labels: Encodable {
        var searchTitle = NavPages.searchTitle
        var searchPrompt = NavPages.searchPrompt
        var direct = NavPages.Action.direct
        var add = NavPages.Action.add
        var showOnMap = NavPages.Action.showOnMap
        var remove = NavPages.Action.remove
        var download = NavPages.Action.download
        var addFavorite = NavPages.Action.addFavorite
        var removeFavorite = NavPages.Action.removeFavorite
        var copyHint = NavPages.Action.copyHint
        var notDownloaded = NavPages.notDownloaded
        var unreadable = NavPages.unreadable
        var here = NavPages.hereTitle
        var pickLayers = NavPages.pickLayers
        var pickBox = NavPages.pickBox
        var showOnMapZoom = NavPages.showOnMapZoom
    }

    struct SearchArgs: Decodable {
        var text: String
        var favorites: [String]
        var fix: Fix?
        var approximate: Bool?
        var now: Date
    }

    struct SearchPage: Encodable {
        /// The amber not current line.
        var warning: String?
        var problem: String?
        var sections: [ListSection]
        /// When the warning can next change. Nil for never.
        var next: Date?
    }

    static func position(_ fix: Fix?) -> Position? {
        fix.flatMap {
            Position(latitude: $0.latitude, longitude: $0.longitude, courseDegrees: $0.course, speedMetersPerSecond: $0.speed,
                     altitudeMeters: $0.altitude, ellipsoidAltitudeMeters: $0.ellipsoidAltitude, timestamp: $0.time)
        }
    }

    static func item(_ airport: Airport, _ nav: NavSession) -> Item {
        Item(row: NavPages.row(airport, quick: nav.quick(airport)), place: Place(airport))
    }

    /// Search results as typed; with an empty field, favorites then the nearest airports.
    static func search(_ nav: NavSession, _ a: SearchArgs) -> SearchPage {
        let db = nav.database
        let warning = NavText.dataDates(db.metadata, now: a.now).warning
        let next = db.metadata.nextChange(after: a.now)
        let approximate = Bridge.approximate(a.approximate, a.fix)
        let position = position(a.fix)
        nav.nearest.update(db, from: position, approximate: approximate, now: a.now)
        guard a.text.allSatisfy(\.isWhitespace) else {
            do {
                let found = try db.search(a.text)
                return SearchPage(warning: warning, sections: [
                    ListSection(items: found.map { item($0, nav) }, empty: NavPages.noMatch)], next: next)
            } catch {
                return SearchPage(warning: warning, problem: NavPages.searchFailed, sections: [], next: next)
            }
        }
        var sections: [ListSection] = []
        let favorites = a.favorites.compactMap { try? db.airport(identifier: $0) }
        if !favorites.isEmpty {
            sections.append(ListSection(title: NavPages.favoritesTitle, items: favorites.map { item($0, nav) }, removable: true))
        }
        let shown = nav.nearest.shown(position: position, approximate: approximate, now: a.now, quick: nav.quick)
        sections.append(ListSection(title: shown.header, items: shown.rows.map { Item(row: $0.row, place: Place($0.airport)) }))
        return SearchPage(warning: warning, sections: sections, next: next)
    }

    struct PageArgs: Decodable {
        var ident: String
        var plan: RoutePlan?
        var fix: Fix?
        var approximate: Bool?
        /// The airport's newest METAR, as the weather station op returns it.
        var metar: Metar?
        var now: Date
    }

    struct AirportPageResult: Encodable {
        var page: NavPages.AirportPage
        var header: NavPages.Header
        var place: Place
        /// When the page can next change with no new fix or report: its warning, or its METAR's age or freshness.
        var next: Date?
        /// Shown where the plates hold no FAA diagram.
        var sketch: SketchRef?
    }

    struct SketchRef: Encodable {
        var sketch: AirportSketch
        var title = AirportSketch.title
        var fullScreen = "Full Screen"
        var showOnMap = "Show on Map"
        var unavailable = "Chart unavailable"
    }

    static func airportPage(_ nav: NavSession, _ a: PageArgs) throws -> AirportPageResult {
        let db = nav.database
        guard let airport = try db.airport(identifier: a.ident), let detail = try db.detail(airportID: airport.id) else {
            throw Failure.notFound(a.ident)
        }
        return AirportPageResult(
            page: NavPages.airportPage(detail, metadata: db.metadata, metar: a.metar, now: a.now),
            header: NavPages.header(airport.coordinate, route: a.plan, position: position(a.fix),
                                    approximate: Bridge.approximate(a.approximate, a.fix), now: a.now),
            place: Place(airport),
            next: NextChange.earliest(after: a.now, [
                db.metadata.nextChange(after: a.now), NavPages.airportWeatherChange(metar: a.metar, after: a.now),
                a.metar.map { NextChange.minute(since: $0.observed, after: a.now) }]),
            sketch: NavPages.airportSketch(detail).map { SketchRef(sketch: $0) })
    }

    struct CardArgs: Decodable {
        var place: Place
        var plan: RoutePlan?
        var fix: Fix?
        var approximate: Bool?
        var now: Date
    }

    struct PlaceCardResult: Encodable {
        var card: NavPages.PlaceCard
        var header: NavPages.Header
        var nearby: [Item]
    }

    static func placeCard(_ nav: NavSession, _ a: CardArgs) -> PlaceCardResult {
        let db = nav.database
        let place = a.place.match
        let near = place.kind == .user ? db.nearby(place.coordinate) : []
        let card = NavPages.placeCard(place, navaid: place.kind == .navaid ? db.navaid(for: place) : nil,
                                      fix: place.kind == .fix ? db.fix(for: place) : nil)
        return PlaceCardResult(
            card: card,
            header: NavPages.header(place.coordinate, route: a.plan, position: position(a.fix),
                                    approximate: Bridge.approximate(a.approximate, a.fix), now: a.now),
            nearby: near.map { item($0, NavPages.row($0, from: place.coordinate), nav) })
    }

    /// An airport place shows its database row; a navaid or fix its own.
    static func item(_ match: WaypointMatch, _ row: NavPages.Row, _ nav: NavSession) -> Item {
        guard match.kind == .airport, let airport = try? nav.database.airport(identifier: match.ident) else {
            return Item(row: row, place: Place(match))
        }
        var shown = NavPages.row(airport, quick: nav.quick(airport))
        shown.distance = row.distance
        return Item(row: shown, place: Place(airport))
    }

    struct Hit: Decodable { var place: Place; var distance: Double }
    struct StationHit: Decodable { var station: String; var latitude: Double; var longitude: Double; var distance: Double }
    struct PickArgs: Decodable { var hits: [Hit]?; var stations: [StationHit]?; var pin: Coordinate? }

    struct PickResult: Encodable {
        /// nothing, airport, place or here.
        var open: String
        var ident: String?
        var place: Place?
        var here: [Item]
    }

    /// What a tap or a long press on the map opens.
    static func pick(_ nav: NavSession, _ a: PickArgs) -> PickResult {
        if let pin = a.pin { return PickResult(open: "place", place: Place(NavPages.pin(at: pin)), here: []) }
        let hits = (a.hits ?? []).map { ($0.place.match, $0.distance) }
        // A station dot opens its airport, unless the airport's own dot was hit too.
        let stations = (a.stations ?? []).filter { s in
            !hits.contains { $0.0.kind == .airport && ($0.0.icao == s.station || $0.0.ident == s.station) }
        }.map { s in
            (WaypointMatch(kind: .airport, ident: s.station, icao: s.station, name: s.station,
                           coordinate: Coordinate(latitude: s.latitude, longitude: s.longitude)), s.distance)
        }
        let places = MapPick.here(hits + stations)
        switch NavPages.tap(places) {
        case .nothing: return PickResult(open: "nothing", here: [])
        case .airport(let ident): return PickResult(open: "airport", ident: ident, here: [])
        case .place(let one): return PickResult(open: "place", place: Place(one), here: [])
        case .here(let list):
            return PickResult(open: "here", here: list.map { item($0, NavPages.row($0), nav) })
        }
    }

    /// The stored plan inputs (RoutePages.storing's text), with any of them changed. `alternate` is the typed field.
    struct PlanInputArgs: Decodable {
        var stored: String?
        var now: Date
        var departure: Date?
        var rules: FlightPlanInputs.Rules?
        var altitude: Int?
        var alternate: String?
        var aircraft: String?
    }

    struct PlanInputs: Encodable {
        var inputs: FlightPlanInputs
        /// Text to keep under RouteLabels.planInputsKey.
        var stored: String
        var alternate: String
    }

    static func planInputs(_ nav: NavSession, _ a: PlanInputArgs) -> PlanInputs {
        var inputs = RoutePages.planInputs(stored: a.stored.map { Data($0.utf8) }, now: a.now)
        if let d = a.departure { inputs.departure = max(d, a.now) }
        if let r = a.rules { inputs.rules = r }
        if let ft = a.altitude { inputs.cruiseAltitudeFt = ft }
        if let id = a.aircraft.flatMap(UUID.init(uuidString:)) { inputs.aircraftID = id }
        if let text = a.alternate { inputs.alternate = RoutePages.alternate(text, database: nav.database) }
        return planInputs(inputs)
    }

    static func planInputs(_ inputs: FlightPlanInputs) -> PlanInputs {
        // RoutePages.storing's format with sorted keys, so the golden file stays put.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stored = (try? encoder.encode(inputs)) ?? RoutePages.storing(inputs)
        return PlanInputs(inputs: inputs, stored: String(decoding: stored, as: UTF8.self),
                          alternate: inputs.alternate?.ident ?? "")
    }

    struct NearArgs: Decodable { var latitude: Double; var longitude: Double }
    struct PrefixArgs: Decodable { var prefix: String }

    static func navCall(_ nav: NavSession, _ op: String, _ args: Data) throws -> any Encodable {
        func arg<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: args) }
        switch op {
        case "metadata":
            let m = nav.database.metadata
            return Metadata(cycle: m.cycle, effective: m.effective, expires: m.expires)
        case "search": return search(nav, try arg(SearchArgs.self))
        case "airportPage": return try airportPage(nav, try arg(PageArgs.self))
        case "placeCard": return placeCard(nav, try arg(CardArgs.self))
        case "pick": return pick(nav, try arg(PickArgs.self))
        case "route": return route(nav, try arg(RouteArgs.self))
        case "waypointsNear":
            let a = try arg(NearArgs.self)
            return nav.database.nearby(Coordinate(latitude: a.latitude, longitude: a.longitude)).map(Place.init)
        case "planInputs": return planInputs(nav, try arg(PlanInputArgs.self))
        case "loadRoute": return try loadRoute(nav, arg(LoadRouteArgs.self))
        case "waypointSearch":
            return try nav.database.waypointSearch(prefix: try arg(PrefixArgs.self).prefix).map(Place.init)
        default: throw Failure.unknownOp(op)
        }
    }
}
