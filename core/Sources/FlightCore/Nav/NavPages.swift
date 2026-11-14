/// The navigation screens as display rows: search and nearest lists, the airport page and the place card.
/// Both apps only lay these out.
public enum NavPages {
    public static let searchTitle = "Airports"
    public static let searchPrompt = "Search airports"
    public static let noMatch = "No airport matches"
    public static let favoritesTitle = "Favorites"
    public static let nonePublished = "None published"
    public static let closed = "Closed"
    public static let nothingNearby = "Nothing within 10 NM"
    public static let nearbyRadiusNM = 10.0
    public static let notDownloaded = "Navigation data is not downloaded"
    public static let unreadable = "Navigation data could not be read"
    public static let searchFailed = "Search failed"

    /// The words on a place's buttons and row menus.
    public enum Action {
        public static let direct = "Direct To"
        public static let add = "Add to Route"
        public static let showOnMap = "Show on Map"
        public static let remove = "Remove"
        public static let download = "Download"
        public static let addFavorite = "Add to favorites"
        public static let removeFavorite = "Remove from favorites"
        public static let copyHint = "Copies the frequency"
        public static let remarks = "Remarks"
    }

    /// One list row: an airport, navaid, fix or pin, with its range when the list measures one.
    public struct Row: Equatable, Sendable, Encodable {
        public var kind: WaypointKind
        /// The FAA identifier the app hands back to open or route the place.
        public var ident: String
        /// The code shown: an airport's ICAO code when it has one.
        public var title: String
        public var name: String?
        public var closed: String?
        public var kindLabel: String?
        public var quick: String?
        public var distance: String?
        public var bearing: String?
        /// Degrees to turn from the aircraft's track; from north when the track is unknown.
        public var turn: Double?
        public var coordinate: Coordinate

        public init(kind: WaypointKind, ident: String, title: String, name: String? = nil, closed: String? = nil,
                    kindLabel: String? = nil, quick: String? = nil, distance: String? = nil, bearing: String? = nil,
                    turn: Double? = nil, coordinate: Coordinate) {
            (self.kind, self.ident, self.title, self.name, self.closed) = (kind, ident, title, name, closed)
            (self.kindLabel, self.quick, self.distance, self.bearing, self.turn) = (kindLabel, quick, distance, bearing, turn)
            self.coordinate = coordinate
        }
    }

    /// Name shown under a code, unless it only repeats the code.
    public static func name(_ name: String, ident: String) -> String? {
        name.isEmpty || name == ident ? nil : NavText.capitalized(name)
    }

    public static func row(_ airport: Airport, quick: String?) -> Row {
        Row(kind: .airport, ident: airport.ident, title: NavText.title(airport), name: name(airport.name, ident: NavText.title(airport)),
            closed: airport.isOperational ? nil : closed, kindLabel: NavText.kindLabel(airport),
            quick: quick.flatMap { $0.isEmpty ? nil : $0 }, coordinate: airport.coordinate)
    }

    /// A navaid or fix row. An airport place is better shown by row(_:quick:) from its database record.
    public static func row(_ place: WaypointMatch, from: Coordinate? = nil) -> Row {
        Row(kind: place.kind, ident: place.ident, title: place.kind == .airport ? (place.icao ?? place.ident) : place.ident,
            name: name(place.kind == .airport ? place.name : NavText.placeRowName(place), ident: place.ident),
            distance: from.map { NavText.distance(Geo.distanceNM(from: $0, to: place.coordinate)) },
            coordinate: place.coordinate)
    }

    /// A pin dropped on the map, named by where it is.
    public static func pin(at point: Coordinate) -> WaypointMatch {
        WaypointMatch(kind: .user, ident: NavText.degreesMinutes(point), name: "", coordinate: point)
    }

    /// What a tap on the map opens: one airport's page, one place's card, or the Here list.
    public enum Tap: Equatable, Sendable {
        case nothing
        case airport(String)
        case place(WaypointMatch)
        case here([WaypointMatch])
    }

    public static func tap(_ places: [WaypointMatch]) -> Tap {
        guard let first = places.first else { return .nothing }
        if places.count > 1 { return .here(places) }
        return first.kind == .airport ? .airport(first.ident) : .place(first)
    }

    public static let hereTitle = "Here"
    /// The map layers a tap picks from, and the box searched around the finger, in points.
    public static let pickLayers = ["airports", "airports-private", "navaids", "fixes"]
    public static let pickBox = 44.0
    /// The zoom Show on Map puts a place at.
    public static let showOnMapZoom = 10.0
    public static let bendTitle = "Bend Route To"

    /// Where a point would join the route, and the add button's title for it.
    public static func addSpot(_ point: Coordinate, route: RoutePlan?, position: Position?, approximate: Bool = false,
                               now: Date) -> (target: Int?, title: String) {
        guard let route, let target = route.insertTarget(for: point, position: position, approximate: approximate, now: now)
        else { return (nil, Action.add) }
        return (target, "Insert after " + route.route.waypoints[target].ident)
    }

    /// Distance and bearing from the aircraft, and the action row titles. Shared by the airport page and place card.
    public struct Header: Equatable, Sendable, Encodable {
        public var distance: String
        public var bearing: String
        public var addTitle: String?
    }

    public static func header(_ point: Coordinate, route: RoutePlan?, position: Position?, approximate: Bool = false,
                              canAdd: Bool = true, now: Date) -> Header {
        let direct = NavText.directTo(from: position, to: point, approximate: approximate, now: now)
        let add = canAdd ? addSpot(point, route: route, position: position, approximate: approximate, now: now).title : nil
        return Header(distance: direct.distance, bearing: direct.bearing, addTitle: add)
    }

    /// One line of a page section: a title, an optional value at the trailing edge and lines under it.
    public struct Line: Equatable, Sendable, Encodable {
        public var title: String
        public var value: String?
        /// Secondary text under the title.
        public var detail: String?
        /// A red tag beside the title, such as Closed.
        public var tag: String?
        /// A red line under the title, such as Out of service or a runway closure.
        public var alert: String?
        /// What a tap copies.
        public var copy: String?
    }

    public struct Section: Equatable, Sendable, Encodable {
        public var title: String
        public var lines: [Line]
        /// Shown when there are no lines. Nil leaves an empty section out.
        public var empty: String?
    }

    public struct AirportPage: Equatable, Sendable, Encodable {
        public var ident: String
        public var title: String
        public var subtitle: String
        /// Closed, or a closed runway, at the top in red.
        public var closed: String?
        /// The amber not current line.
        public var warning: String?
        public var place: String
        public var glance: [Line]
        public var weather: AirportWeather
        public var runways: Section
        public var frequencies: Section
        public var remarks: Section
        public var details: Section
        /// The data dates and the airspace snapshot, under the details.
        public var footer: [String]
    }

    /// metar is the airport's newest report; one older than two hours counts as none.
    public static func airportPage(_ detail: AirportDetail, metadata: NavMetadata, metar: Metar? = nil,
                                   now: Date) -> AirportPage {
        let airport = detail.airport
        let (weather, best) = airportWeather(detail, metar: metar, now: now)
        let closed = NavText.closedLabel(airport) ?? NavText.closedRunway(detail).map { "Runway \($0.id) closed" }
        let runways = NavText.runways(detail).map { runway in
            let note = NavText.runwayNote(runway, in: detail.remarks)
            return Line(title: runway.id, detail: NavText.runwayLine(runway), tag: note == "CLOSED" ? "Closed" : nil,
                        alert: note == "CLOSED" ? nil : note)
        }
        let frequencies = NavText.frequencies(detail.frequencies).map { f in
            Line(title: NavText.frequencyLabel(f), value: f.frequency, detail: f.remark,
                 alert: NavText.outOfService(use: f.use, frequency: f.frequency, remark: f.remark) ? "Out of service" : nil,
                 copy: f.frequency)
        }
        var footer = [NavText.dataDates(metadata, now: metadata.effective).line]
        if let sua = metadata.suaSnapshot { footer.append("Special use airspace as of \(NavText.day(sua))") }
        return AirportPage(
            ident: airport.ident, title: NavText.title(airport), subtitle: NavText.capitalized(airport.name),
            closed: closed, warning: NavText.dataDates(metadata, now: now).warning, place: NavText.placeLine(airport),
            glance: NavText.glance(detail, best: best).map { Line(title: $0.label, value: $0.value, copy: $0.copy) },
            weather: weather,
            runways: Section(title: "Runways", lines: runways, empty: nonePublished),
            frequencies: Section(title: "Frequencies", lines: frequencies, empty: nonePublished),
            remarks: Section(title: Action.remarks, lines: detail.remarks.map { Line(title: NavText.remarkLine($0)) }),
            details: Section(title: "Details", lines: NavText.facts(airport).map { Line(title: $0.title, value: $0.value) }),
            footer: footer)
    }

    public struct PlaceCard: Equatable, Sendable, Encodable {
        public var title: String
        public var subtitle: String
        public var lines: [Line]
        /// The Nearby list title for a dropped pin; nil for a navaid or fix.
        public var nearbyTitle: String?
        public var nearbyEmpty: String?
        public var showOnMap: Bool
    }

    /// A navaid, fix or dropped pin. The Nearby rows come from row(_:from:) over NavDatabase.nearby.
    public static func placeCard(_ place: WaypointMatch, navaid: Navaid?, fix: Fix?) -> PlaceCard {
        let isPin = place.kind == .user
        var lines: [Line] = []
        if let navaid {
            lines.append(Line(title: "Frequency", value: navaid.frequency ?? NavText.dashes))
            lines.append(Line(title: "Channel", value: navaid.channel ?? NavText.dashes))
        }
        lines.append(Line(title: "Coordinates", value: NavText.degreesMinutes(place.coordinate)))
        return PlaceCard(
            title: isPin ? NavText.degreesMinutes(place.coordinate) : place.ident,
            subtitle: NavText.placeSubtitle(place, navaidType: navaid?.type, fixState: place.kind == .fix ? fix?.state : nil),
            lines: lines,
            nearbyTitle: isPin ? "Nearby" : nil, nearbyEmpty: isPin ? nothingNearby : nil,
            showOnMap: !isPin)
    }
}

extension NavDatabase {
    /// The navaid a map symbol or list row stands for: the one with its identifier closest to its position.
    public func navaid(for place: WaypointMatch) -> Navaid? {
        (try? navaids(ident: place.ident))?.filter(\.isRoutePoint)
            .min { Geo.distanceNM(from: $0.coordinate, to: place.coordinate) < Geo.distanceNM(from: $1.coordinate, to: place.coordinate) }
    }

    public func fix(for place: WaypointMatch) -> Fix? {
        (try? fixes(ident: place.ident))?
            .min { Geo.distanceNM(from: $0.coordinate, to: place.coordinate) < Geo.distanceNM(from: $1.coordinate, to: place.coordinate) }
    }

    /// Airports, navaids and fixes near a dropped pin, closest first.
    public func nearby(_ point: Coordinate) -> [WaypointMatch] {
        (try? waypoints(near: point, withinNM: NavPages.nearbyRadiusNM)) ?? []
    }

    /// The airport's at-a-glance line for list rows. Nil when it has none.
    public func quickLine(_ airport: Airport) -> String? {
        let line = (try? detail(airportID: airport.id)).flatMap { $0.map(NavText.quickLine) } ?? ""
        return line.isEmpty ? nil : line
    }
}

/// The nearest public airports, kept from the last live exact fix.
public struct NearestList: Equatable, Sendable {
    public var airports: [NearbyAirport] = []
    public var from: Position?
    public var failed = false

    public init() {}

    public struct Item: Equatable, Sendable {
        public var airport: Airport
        public var row: NavPages.Row
    }

    public struct Shown: Equatable, Sendable {
        public var header: String
        public var rows: [Item]
    }

    /// Works the list out again from a live, exact fix. With no fix, a stale or approximate one, or a failed read,
    /// the last list stays.
    public mutating func update(_ database: NavDatabase?, from position: Position?, approximate: Bool = false, now: Date) {
        guard let database, let position, !approximate, !position.isStale(at: now) else { return }
        // A held fix moves only its time, and the same spot gives the same list without a query.
        if !failed, from?.coordinate == position.coordinate {
            from = position
            return
        }
        do {
            airports = try database.nearest(to: position.coordinate, count: 10, publicAirportsOnly: true)
            from = position
            failed = false
        } catch {
            failed = true
        }
    }

    /// The list as shown, under a header that says where and when it was worked out.
    /// Numbers appear only with a live fix and a list no older than the stale limit.
    public func shown(position: Position?, approximate: Bool = false, now: Date,
                      quick: (Airport) -> String? = { _ in nil }) -> Shown {
        func rows(_ live: Bool, _ from: Position) -> [Item] {
            airports.map { near in
                var row = NavPages.row(near.airport, quick: quick(near.airport))
                row.distance = live ? NavText.distance(near.distanceNM) : NavText.dashes
                row.bearing = live ? NavText.bearing(near.bearingTrue, from: from.coordinate,
                                                     altitudeFt: from.altitudeFtMSL ?? 0, date: from.timestamp)
                    : NavText.dashes
                row.turn = live ? near.bearingTrue - (position?.trackTrue ?? 0) : nil
                return Item(airport: near.airport, row: row)
            }
        }
        if approximate {
            guard let from else { return Shown(header: "Position is approximate: nearest airports not shown", rows: []) }
            return Shown(header: "Position is approximate. Order from \(NavText.degreesMinutes(from.coordinate)) at \(NavText.stamp(from.timestamp))",
                         rows: rows(false, from))
        }
        guard let from else {
            let hasFix = position.map { !$0.isStale(at: now) } ?? false
            if failed { return Shown(header: "Nearest airports could not be read", rows: []) }
            return Shown(header: hasFix ? "Nearest airports not available" : "No position", rows: [])
        }
        let live = position.map {
            !$0.isStale(at: now) && abs($0.timestamp.timeIntervalSince(from.timestamp)) <= Position.staleAfter
        } ?? false
        let place = NavText.degreesMinutes(from.coordinate)
        let header = live
            ? "Nearest airports from \(place) at \(NavText.clock(from.timestamp))"
            : "From last known position, \(place) at \(NavText.stamp(from.timestamp))"
        return Shown(header: header, rows: rows(live, from))
    }
}
