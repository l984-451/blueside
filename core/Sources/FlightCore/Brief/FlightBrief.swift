/// The preflight brief as display-ready sections, in the order of the FAA standard briefing (JO 7110.10, 5-2-5).
/// Synopsis and "VFR not recommended" are left out: no free source carries the one, the other is a briefer's call.
public struct FlightBrief: Equatable, Sendable, Encodable {
    public struct Section: Equatable, Sendable, Encodable {
        public var title: String
        public var lines: [NavPages.Line]
        /// Shown when there are no lines.
        public var empty: String?
        /// How old the section's weather is, such as "Data 12 min old".
        public var age: String?
        /// Shown in amber: a source behind the section is not current.
        public var warning: String?
        /// Hazards, tinted orange.
        public var adverse = false
    }

    public static let corridorNM = 25.0
    public static let notice = "Not an official briefing. No record is kept. Get a standard briefing at 1800wxbrief.com or from Flight Service."
    public static let atAltitude = "At your altitude"
    public static let altitudeUnknown = "Altitude not given"
    public static let notamsBlocked = "NOTAMs are not in Blueside yet"
    public static let notCovered = "Not covered: takeoff and landing distance, density altitude, runway length."

    public var title: String
    public var notice = Self.notice
    /// For the shared PDF, such as "Brief KAUS-KDAL 2026-10-15 1400Z.pdf".
    public var fileName: String
    public var sections: [Section]
    public var graphics: BriefGraphics

    /// The brief for a planned route. Weather counts from departure to ETA plus 1 hour, within 25 nm of the route.
    /// `localOffsetSeconds` is the device's offset from UTC at departure, for local times beside Z.
    /// The database gives the panels their runways and the profile its ground; `mapBase` puts the map over charts.
    public static func make(route: Route, inputs: FlightPlanInputs, plan: FlightPlan, aircraft: AircraftProfile?,
                            balance: WeightBalance?, weather: WeatherData, now: Date,
                            localOffsetSeconds: Int? = nil, database: NavDatabase? = nil,
                            mapBase: BriefMapBase? = nil, terrain: TerrainTiles? = nil) -> FlightBrief {
        let start = plan.departure, end = (plan.eta ?? plan.departure) + 3600
        let corridor = Corridor(route)
        let cruise = inputs.cruiseAltitudeFt
        func flag(_ base: Int?, _ top: Int?) -> String? {
            guard base != nil || top != nil else { return altitudeUnknown }
            return (base ?? 0) <= cruise && cruise <= (top ?? .max) ? atAltitude : nil
        }
        func span(_ from: Date, _ to: Date) -> String { "Valid \(WeatherText.zulu(from, withDay: true)) to \(WeatherText.zulu(to, withDay: true))" }
        func lines(_ parts: String?...) -> String? {
            let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
            return kept.isEmpty ? nil : kept.joined(separator: "\n")
        }
        func section(_ title: String, _ lines: [NavPages.Line], empty: String? = nil, sources: [WeatherSource] = [],
                     adverse: Bool = false) -> Section {
            let times = sources.compactMap { weather.time(of: $0) }
            let warnings = sources.compactMap { s in
                WeatherText.notUpdated(sourceName(s), status: weather.status(of: s, at: now), time: weather.time(of: s), now: now)
            }
            return Section(title: title, lines: lines, empty: empty,
                           age: times.min().map { "Data \(WeatherText.age(now.timeIntervalSince($0))) old" },
                           warning: warnings.isEmpty ? nil : warnings.joined(separator: ". "), adverse: adverse)
        }

        // Adverse conditions: SIGMETs, CWAs, G-AIRMETs, TFRs and urgent PIREPs that meet the corridor in the window.
        var adverse: [NavPages.Line] = []
        let sigmets = weather.sigmets.filter { $0.validFrom < end && $0.validTo > start && corridor.meets($0.shape) }
        let cwas = weather.cwas.filter { $0.validFrom < end && $0.validTo > start && corridor.meets($0.shape) }
        for s in sigmets {
            adverse.append(NavPages.Line(title: "\(s.hazard) \(s.kind ?? "SIGMET")",
                                         value: "\(s.baseFtMSL.map(feet) ?? "?") to \(s.topFtMSL.map(feet) ?? "?")",
                                         detail: lines(span(s.validFrom, s.validTo), s.raw), tag: flag(s.baseFtMSL, s.topFtMSL), copy: s.raw))
        }
        for c in cwas {
            adverse.append(NavPages.Line(title: "\(c.hazard) CWA \(c.center) \(c.series)",
                                         value: "\(c.baseFtMSL.map(feet) ?? "?") to \(c.topFtMSL.map(feet) ?? "?")",
                                         detail: lines(span(c.validFrom, c.validTo), c.raw), tag: flag(c.baseFtMSL, c.topFtMSL), copy: c.raw))
        }
        // Each snapshot is its own feature; one row per tag spans the snapshots that hit.
        var airmets: [(key: String?, item: GAirmet, to: Date)] = []
        for g in weather.gairmets.sorted(by: { $0.valid < $1.valid }) {
            let to = g.valid + GAirmet.snapshotSpacing
            guard g.valid < end, to > start, corridor.meets(g.shape) else { continue }
            if let i = airmets.firstIndex(where: { $0.key != nil && $0.key == g.tag }) { airmets[i].to = to; continue }
            airmets.append((g.tag, g, to))
        }
        for (_, g, to) in airmets {
            let base = level(g.base, freezing: g.freezingBase), top = level(g.top, freezing: g.freezingTop)
            adverse.append(NavPages.Line(title: "G-AIRMET \(g.hazard)",
                                         value: "\(g.base.map(levelText) ?? "?") to \(g.top.map(levelText) ?? "?")",
                                         detail: lines(span(g.valid, to), g.severity, g.dueTo), tag: flag(base, top)))
        }
        func inWindow(_ t: Tfr) -> Bool { (t.effective.map { $0 < end } ?? true) && (t.expires.map { $0 > start } ?? true) }
        func tfrLine(_ t: Tfr) -> NavPages.Line {
            let when = "\(t.effective.map(WeatherText.dated) ?? "In force") to "
                + (t.expires.map(WeatherText.dated) ?? "further notice")
            // An unreadable notice has no times or levels to give, only that its area is unknown.
            return NavPages.Line(title: "TFR \(t.notam)",
                                 value: t.unreadable ? nil : "\(t.lower?.text ?? "?") to \(t.upper?.text ?? "?")",
                                 detail: lines(t.title ?? t.name, t.unreadable ? Tfr.unreadableNote : when),
                                 tag: flag(tfrFeet(t.lower, top: false), tfrFeet(t.upper, top: true)))
        }
        let tfrs = weather.tfrs.filter(inWindow)
        let drawnTfrs = tfrs.filter { $0.shape.map(corridor.meets) ?? false }
        adverse += drawnTfrs.map(tfrLine)
        let pireps = weather.pireps.filter { corridor.distanceNM(to: $0.coordinate) <= corridorNM }.sorted { $0.observed > $1.observed }
        func pirepLine(_ p: Pirep, flagAltitude: Bool) -> NavPages.Line {
            // A report is at your altitude within 2000 ft of cruise.
            let near = p.altitudeFtMSL.map { abs($0 - cruise) <= 2000 } ?? false
            return NavPages.Line(title: (p.urgent ? "Urgent PIREP " : "PIREP ") + (p.altitudeFtMSL.map(feet) ?? "altitude not given"),
                                 value: "\(WeatherText.age(now.timeIntervalSince(p.observed))) ago", detail: p.raw,
                                 tag: flagAltitude && near ? atAltitude : nil, copy: p.raw)
        }
        let urgent = pireps.filter(\.urgent)
        adverse += urgent.map { pirepLine($0, flagAltitude: true) }

        // Current conditions and destination forecast at the airports.
        let points = route.waypoints
        let airports = [("Departure", points.first), ("Destination", points.last), ("Alternate", inputs.alternate)]
            .compactMap { role, w in w.flatMap { $0.kind == .airport ? (role, $0.ident) : nil } }
        let metarLines = airports.map { role, ident -> NavPages.Line in
            guard let m = weather.metars.filter({ $0.station == ident }).max(by: { $0.observed < $1.observed }) else {
                return NavPages.Line(title: "\(role) \(ident)", value: NavText.dashes, detail: "No METAR held")
            }
            return NavPages.Line(title: "\(role) \(ident)",
                                 value: "\(m.category.rawValue) · \(WeatherText.age(now.timeIntervalSince(m.observed))) ago",
                                 detail: m.raw, copy: m.raw)
        }
        let eta = plan.eta ?? plan.departure
        let tafLines = airports.filter { $0.0 != "Departure" }.map { role, ident -> NavPages.Line in
            guard let t = weather.tafs.filter({ $0.station == ident }).max(by: { $0.issued < $1.issued }) else {
                return NavPages.Line(title: "\(role) \(ident)", value: NavText.dashes, detail: "No TAF held")
            }
            return NavPages.Line(title: "\(role) \(ident)", value: categories(t, around: eta), detail: t.raw, copy: t.raw)
        }

        // Winds aloft per leg, then the altitude table.
        let legs = zip(plan.log.legs, plan.legWinds).map { row, w in
            NavPages.Line(title: "\(row.leg.from.ident) to \(row.leg.to.ident)", value: w.wind ?? NavText.dashes, detail: w.note)
        }

        var planLines = plan.lines
        if let alt = plan.alternate { planLines.append(NavPages.Line(title: "Alternate rule", value: nil, detail: alt.text)) }
        planLines.append(balance.map {
            NavPages.Line(title: "Weight and balance", value: $0.status ?? NavText.dashes, detail: lines(($0.problems + $0.notes).joined(separator: "\n")))
        } ?? NavPages.Line(title: "Weight and balance", value: NavText.dashes, detail: "Not worked out"))
        planLines += plan.sunLines
        planLines.append(NavPages.Line(title: notCovered, value: nil))

        func when(_ date: Date?) -> String {
            guard let date else { return NavText.dashes }
            let local = localOffsetSeconds.map { o -> String in
                let t = UTCTime(date + TimeInterval(o))
                return " (\(NavText.pad(t.hour, 2))\(NavText.pad(t.minute, 2)) local)"
            }
            return WeatherText.dated(date) + (local ?? "")
        }
        let header = [
            NavPages.Line(title: "Route", value: nil, detail: route.routeText),
            NavPages.Line(title: "Aircraft", value: aircraft.map { [$0.tail, $0.type].compactMap { $0 }.joined(separator: " · ") } ?? NavText.dashes),
            NavPages.Line(title: "Cruise", value: "\(feet(cruise)) · \(inputs.rules.rawValue.uppercased())"),
            NavPages.Line(title: "Departure", value: when(plan.departure)),
            NavPages.Line(title: "ETA", value: when(plan.eta)),
        ]
        let ends = "\(points.first?.ident ?? "")-\(points.last?.ident ?? "")"
        let graphics = BriefGraphics.make(.init(
            route: route, inputs: inputs, plan: plan, weather: weather, now: now, corridor: corridor, sigmets: sigmets,
            cwas: cwas, airmets: airmets.map(\.item), tfrs: drawnTfrs, pireps: urgent,
            airports: airports.map { ($0.0, $0.1) }, database: database, base: mapBase, terrain: terrain))
        return FlightBrief(
            title: "Brief \(ends)", fileName: "Brief \(ends) \(WeatherText.dated(plan.departure)).pdf",
            sections: [
                section("Flight", header),
                section("Adverse conditions", adverse, empty: "None found along the route",
                        sources: [.sigmets, .cwas, .gairmets, .tfrs, .pireps], adverse: true),
                section(Tfr.listTitle, tfrs.filter { $0.shape == nil }.map(tfrLine),
                        sources: [.tfrs], adverse: true),
                section("Current conditions", metarLines, empty: "No airports on the route", sources: [.metars]),
                section("Destination forecast", tafLines, empty: "No destination airport", sources: [.tafs]),
                section("Winds aloft", legs + plan.altitudeLines, sources: [.winds]),
                section("NOTAMs", [NavPages.Line(title: notamsBlocked, value: nil, detail: "Check them before you fly.")]),
                section("PIREPs", pireps.map { pirepLine($0, flagAltitude: false) }, empty: "None within 25 nm of the route",
                        sources: [.pireps]),
                section("Plan", planLines),
            ], graphics: graphics)
    }

    static func feet(_ ft: Int) -> String { ft == 0 ? "SFC" : "\(ft) ft" }

    static func sourceName(_ s: WeatherSource) -> String {
        switch s {
        case .metars: "METARs"
        case .tafs: "TAFs"
        case .sigmets: "SIGMETs"
        case .gairmets: "G-AIRMETs"
        case .cwas: "CWAs"
        case .pireps: "PIREPs"
        case .tfrs: "TFRs"
        case .radar: "Radar"
        case .winds: "Winds aloft"
        case .satellite: "Satellite"
        case .lightning: "Lightning"
        }
    }

    /// G-AIRMET altitude text from the pipeline: digits in feet, SFC, or FZL for the freezing level.
    static func level(_ text: String?, freezing: String?) -> Int? {
        switch text {
        case "SFC": 0
        case "FZL": level(freezing, freezing: nil)
        default: text.flatMap { Int($0) }
        }
    }

    static func levelText(_ text: String) -> String { Int(text).map(feet) ?? text }

    /// Feet MSL for the altitude flag. AGL is unknown without terrain: a floor counts from the surface, a ceiling is open.
    static func tfrFeet(_ a: TfrAltitude?, top: Bool) -> Int? {
        guard let a else { return nil }
        if a.unit == "FL" { return a.value * 100 }
        if a.reference == "AGL" { return top ? nil : 0 }
        return a.value
    }

    /// The range of TAF categories from 1 hour before to 1 hour after the ETA, TEMPO and PROB included.
    static func categories(_ taf: Taf, around eta: Date) -> String {
        let order = FlightCategory.allCases
        var seen: [FlightCategory] = []
        for step in 0...8 {
            guard let c = taf.conditions(at: eta - 3600 + Double(step) * 900) else { continue }
            for found in [c.category] + c.overlays.map(\.category) where !seen.contains(found) { seen.append(found) }
        }
        let sorted = seen.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        guard let best = sorted.first, let worst = sorted.last else { return "Does not cover the ETA" }
        return "ETA ±1 h: " + (best == worst ? best.rawValue : "\(best.rawValue) to \(worst.rawValue)")
    }
}

/// The route on a flat grid in nautical miles, equirectangular around its middle: close enough within 25 nm.
struct Corridor {
    typealias Point = (x: Double, y: Double)
    let origin: Coordinate
    /// Route samples every 5 nm, their leg, and their distance from departure on the grid.
    var points: [Coordinate] = []
    var path: [Point] = []
    var legs: [Int] = []
    var along: [Double] = []

    init(_ route: Route) {
        let samples = route.linePoints(maxSegmentNM: 5)
        points = samples
        origin = samples[samples.count / 2]
        path = samples.map(project)
        // Pieces per leg as linePoints cuts them; the last point closes the last leg.
        for (n, (a, b)) in zip(route.waypoints, route.waypoints.dropFirst()).enumerated() {
            let pieces = max(1, Int((Geo.distanceNM(from: a.coordinate, to: b.coordinate) / 5).rounded(.up)))
            legs += Array(repeating: n, count: pieces)
        }
        legs.append(max(0, route.waypoints.count - 2))
        along = path.map { _ in 0 }
        for k in path.indices.dropFirst() { along[k] = along[k - 1] + Self.gap(path[k], path[k - 1], path[k - 1]) }
    }

    func project(_ c: Coordinate) -> Point {
        var dLon = (c.longitude - origin.longitude).truncatingRemainder(dividingBy: 360)
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        // Each point's own latitude sets its east-west scale, so long north-south routes stay true near their ends.
        return (dLon * 60 * cos(c.latitude * .pi / 180), (c.latitude - origin.latitude) * 60)
    }

    func distanceNM(to c: Coordinate) -> Double {
        let p = project(c)
        guard path.count > 1 else { return path.first.map { Self.gap(p, $0, $0) } ?? .infinity }
        return zip(path, path.dropFirst()).map { Self.gap(p, $0, $1) }.min() ?? .infinity
    }

    /// A sample inside the area or within 25 nm of its edge. Lines, such as freezing levels, never meet.
    func meets(_ shape: WeatherShape) -> Bool {
        guard case .polygon(let points) = shape else { return false }
        let ring = points.map(project)
        let edges = Array(zip(ring, ring.dropFirst()))
        return path.contains { p in
            Polygon.contains(p.x, p.y, in: ring) || edges.contains { Self.gap(p, $0.0, $0.1) <= FlightBrief.corridorNM }
        }
    }

    /// Distance from a point to a segment.
    static func gap(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        let ex = p.x - a.x - t * dx, ey = p.y - a.y - t * dy
        return (ex * ex + ey * ey).squareRoot()
    }
}
