/// The plan part of the route panel: what the pilot sets, the plan, and its figures per editor row.
extension RoutePages {
    public static let planInputsKey = "flightPlanInputs"
    public static let planSection = "Plan"
    public static let departureTitle = "Departure"
    public static let rulesTitle = "Rules"
    public static let altitudeTitle = "Cruise altitude"
    public static let alternateTitle = "Alternate"
    public static let alternatePrompt = "None"
    public static let altitudesSection = "Altitudes"
    public static let altitudesFooter = "Time and fuel with winds aloft. Tap one to fly it."
    public static let sunSection = "Sun"
    public static let notCovered = "Not covered: takeoff and landing distance, density altitude, runway length."
    public static let defaultAltitudeFt = 5500
    public static let briefTitle = "Brief"
    public static let share = "Share"

    public static func rulesName(_ rules: FlightPlanInputs.Rules) -> String { rules.rawValue.uppercased() }

    /// The inputs kept on the device; a departure already past rolls on to the next quarter hour.
    public static func planInputs(stored: Data?, now: Date) -> FlightPlanInputs {
        var inputs = stored.flatMap { try? JSONDecoder().decode(FlightPlanInputs.self, from: $0) }
            ?? FlightPlanInputs(cruiseAltitudeFt: defaultAltitudeFt, departure: FlightPlanInputs.defaultDeparture(now: now))
        if inputs.departure < now { inputs.departure = FlightPlanInputs.defaultDeparture(now: now) }
        return inputs
    }

    public static func storing(_ inputs: FlightPlanInputs) -> Data { (try? JSONEncoder().encode(inputs)) ?? Data() }

    /// The airport or fix an alternate field names exactly; nil for anything else.
    public static func alternate(_ text: String, database: NavDatabase) -> RouteWaypoint? {
        let word = text.trimmed.uppercased()
        guard !word.isEmpty else { return nil }
        return ((try? database.waypointSearch(prefix: word, limit: 6)) ?? []).first { ident($0) == word }
            .map(RouteWaypoint.init(match:))
    }

    /// One editor row's leg as planned: time with wind, and the wind, temperature and groundspeed.
    public struct PlanLeg: Equatable, Sendable {
        /// Nil on the active leg while airborne, which keeps its live time.
        public var time: String?
        public var wind: String
        public var note: String?
        /// The nav log's cells after the waypoint, in `logColumns` order.
        public var cells: [String] = []
        /// Top of climb and top of descent rows that come before this waypoint's row, each with its title first.
        public var before: [[String]] = []
    }

    public struct PlanPage: Equatable, Sendable {
        public var plan: FlightPlan
        /// Keyed by the editor point's target.
        public var legs: [Int: PlanLeg]
        /// The departure row's cells after the waypoint: everything still to go.
        public var start: [String] = []
        /// The answer first: distance, departure, time en route, ETA, fuel required and margin, each with a number.
        /// With time and burn known, an unknown fuel required stays beside the advice that says why.
        public var summary: [NavPages.Line] {
            ([distance] + plan.answerLines).filter {
                $0.value != NavText.dashes || plan.fuelUnknown && $0.title == FlightPlan.fuelRequired
            }
        }
        /// How the fuel required adds up, each line with a number.
        public var fuelLines: [NavPages.Line] { plan.fuelParts.filter { $0.value != NavText.dashes } }
        private var distance: NavPages.Line { NavPages.Line(title: "Distance", value: NavText.distance(plan.log.totalDistanceNM)) }
    }

    public static func planPage(_ route: RoutePlan, position: Position?, approximate: Bool = false, now: Date,
                                inputs: FlightPlanInputs, trueAirspeedKt: Double, burnGPH: Double,
                                taxiFuelGal: Double = 0, fuelOnBoardGal: Double? = nil,
                                winds: WindsAloft?, tafs: [Taf], destinationHasApproach: Bool? = nil,
                                vertical: FlightPlan.Vertical? = nil) -> PlanPage? {
        guard let flown = route.route(from: position, approximate: approximate, now: now) else { return nil }
        let plan = FlightPlan.make(route: flown, inputs: inputs, trueAirspeedKt: trueAirspeedKt, burnGPH: burnGPH,
                                   taxiFuelGal: taxiFuelGal, fuelOnBoardGal: fuelOnBoardGal, winds: winds, tafs: tafs,
                                   destinationHasApproach: destinationHasApproach,
                                   vertical: vertical, inFlight: inFlight(route, position, approximate: approximate, now: now),
                                   airborne: airborne(position, approximate: approximate, now: now), now: now)
        // Without a fix the aircraft's leg is gone, so plan legs sit one row down.
        let shift = route.route.waypoints.count - flown.waypoints.count
        var legs: [Int: PlanLeg] = [:]
        let log = plan.log, d = NavText.dashes
        let onBoard = plan.airborne ? nil : plan.fuelOnBoard.map { $0 - max(0, taxiFuelGal) }
        var flownNM = 0.0, flownTime: TimeInterval? = 0, flownFuel: Double? = 0
        // What is still to go after this much, as Rem NM, Rem time and Rem fuel.
        func remaining() -> [String] {
            [NavText.fixed(max(0, log.totalDistanceNM - flownNM), 1),
             log.totalTime.flatMap { total in flownTime.map { NavText.duration(max(0, total - $0)) } } ?? d,
             onBoard.flatMap { have in flownFuel.map { NavText.fixed(abs(have - $0) < 0.05 ? 0 : have - $0, 1) } } ?? d]
        }
        let start = [d, d, d, d, d, d, d, d, d] + remaining()
        // One log leg per row; a leg that ends at top of climb or descent rides ahead of the next waypoint's row.
        var editorLeg = 0, before: [[String]] = [], legTime: TimeInterval? = 0, legNote: String?
        for (index, (leg, wind)) in zip(log.legs, plan.legWinds).enumerated() {
            let target = editorLeg + shift
            let parts = [wind.wind, leg.groundspeedKt.map { "GS \(Int($0.rounded())) kt" }].compactMap { $0 }
            // Airborne, the active leg keeps its live time.
            let liveTime = plan.airborne && target == route.activeLeg
            let time = liveTime ? nil : leg.time.map(NavText.duration)
            flownNM += leg.leg.distanceNM
            flownTime = flownTime.flatMap { sum in leg.time.map { sum + $0 } }
            flownFuel = flownFuel.flatMap { sum in leg.fuel.map { sum + $0 } }
            legTime = legTime.flatMap { sum in leg.time.map { sum + $0 } }
            legNote = legNote ?? wind.note
            let altitude = plan.endAltitudesFt.indices.contains(index) ? plan.endAltitudesFt[index] : inputs.cruiseAltitudeFt
            let temperature = plan.winds.indices.contains(index) ? plan.winds[index]?.temperatureC : nil
            let cells = [leg.leg.magneticCourse, leg.magneticHeading].map { $0.map(degrees) ?? d }
            let row = [cells[0], cells[1], NavText.fixed(leg.leg.distanceNM, 1), "\(altitude)",
                       wind.wind ?? d, isaDeviation(temperatureC: temperature, altitudeFt: altitude),
                       leg.groundspeedKt.map { "\(Int($0.rounded()))" } ?? d, time ?? d,
                       leg.fuel.map { NavText.fixed($0, 1) } ?? d] + remaining()
            if plan.markerLegs.contains(index) {
                before.append([leg.leg.to.ident] + row)
                continue
            }
            let whole = before.isEmpty ? time : legTime.map(NavText.duration)
            legs[target] = PlanLeg(time: liveTime ? nil : whole,
                                   wind: parts.isEmpty ? d : parts.joined(separator: " · "), note: legNote,
                                   cells: row, before: before)
            editorLeg += 1
            (before, legTime, legNote) = ([], 0, nil)
        }
        return PlanPage(plan: plan, legs: legs, start: start)
    }

    /// For the climb profile: the route starts at the aircraft, or the aircraft is airborne.
    public static func inFlight(_ route: RoutePlan, _ position: Position?, approximate: Bool, now: Date) -> Bool {
        route.fromAircraft || airborne(position, approximate: approximate, now: now)
    }

    /// A live, exact fix moving faster than any taxi.
    public static func airborne(_ position: Position?, approximate: Bool, now: Date) -> Bool {
        guard let position, !approximate, !position.isStale(at: now) else { return false }
        return (position.groundspeedKt ?? 0) > 40
    }

    /// What the plan page takes from the route, the fix and the clock: equal keys give the same page.
    /// The view watches the inputs, aircraft and weather itself, and `planChange` for the time.
    public struct PlanKey: Equatable, Sendable, Codable {
        /// The route with its active leg.
        public var route: RoutePlan?
        /// A live, exact fix: the active leg is measured from it, and a route from the aircraft starts there.
        public var live: Bool
        /// No climb and no taxi fuel, and the plan departs now.
        public var airborne: Bool
        /// Where a route flown from the aircraft starts. Kept on the ground until the aircraft has moved `startMovesNM`
        /// from it, and airborne until `printed` changes.
        public var start: Coordinate?
        /// Airborne on a route flown from the aircraft: its distance and the course out of the fix, as the page prints them.
        public var printed: [String]?
        /// The minute while airborne, since departure times are printed to the minute.
        public var minute: Int?
    }

    /// Half the tenth of a mile the page prints, so a kept start is never a printed tenth out.
    static let startMovesNM = 0.05

    /// The key for this fix, given the last key. A start the aircraft is still within `startMovesNM` of is kept, so GPS
    /// jitter changes nothing; airborne it is also kept while what the page prints from it is the same.
    public static func planKey(_ route: RoutePlan?, position: Position?, approximate: Bool = false, now: Date,
                               after last: PlanKey? = nil) -> PlanKey {
        let live = position.map { !approximate && !$0.isStale(at: now) } ?? false
        let up = airborne(position, approximate: approximate, now: now)
        let fromAircraft = live && route?.fromAircraft == true
        // Tenths of a mile and whole degrees; the first leg's own distance can lag a tenth until the total moves.
        var printed = fromAircraft && up ? route?.route(from: position, now: now).map { flown -> [String] in
            let (a, b) = (flown.waypoints[0].coordinate, flown.waypoints[1].coordinate)
            let course = RouteMath.magnetic(Geo.initialBearing(from: a, to: b), at: a, date: now)
            return [NavText.distance(flown.totalDistanceNM), "\(Int(course.rounded()) % 360)"]
        } : nil
        var start = fromAircraft ? position?.coordinate : nil
        if let kept = last?.start, let here = start, last?.airborne == up,
           Geo.distanceNM(from: kept, to: here) < startMovesNM || up && printed == last?.printed {
            (start, printed) = (kept, last?.printed)
        }
        return PlanKey(route: route, live: live, airborne: up, start: start, printed: printed,
                       minute: up ? Int((now.timeIntervalSince1970 / 60).rounded(.down)) : nil)
    }

    /// From the plates on the device. With the destination's state pack installed, no approach chart means none is
    /// published; elsewhere it is unknown.
    public static func hasApproach(_ charts: [Plate], regionInstalled: Bool) -> Bool? {
        if charts.contains(where: { $0.group == .approaches }) { return true }
        return regionInstalled || !charts.isEmpty ? false : nil
    }

    /// The top of climb and top of descent rows that go ahead of a point's row.
    public static func logInserts(_ point: Point, page: PlanPage?) -> [[String]] { page?.legs[point.target]?.before ?? [] }

    public static let expand = "Expand"
    public static let collapse = "Collapse"
    public static let logColumns = ["Waypoint", "Course", "Hdg", "NM", "Alt", "Wind", "ISA", "GS", "Time", "Fuel",
                                    "Rem NM", "Rem time", "Rem fuel"]
    /// Most needed first. Where the page is too narrow for every column shown, the last drop first.
    public static let logPriority = [0, 3, 8, 1, 9, 7, 5, 2, 4, 6, 10, 11, 12]
    /// Where Time sits in `logColumns`.
    public static let logTime = 8

    /// The columns some row holds a value in; the waypoint always shows.
    public static func logShown(_ rows: [[String]]) -> [Int] {
        logColumns.indices.filter { i in i == 0 || rows.contains { $0.indices.contains(i) && !["", NavText.dashes].contains($0[i]) } }
    }

    /// What a table must keep of the columns shown: the waypoint, its distance and its time.
    static let logNeeded = [0, 3, 8]

    /// The shown columns that fit in `room`, each as wide as `widths` gives by column, in `logPriority` order until one
    /// does not fit. Nil when any shown column of `logNeeded` does not fit, so the page lists the route instead.
    public static func logFitted(_ shown: [Int], widths: [Double], room: Double) -> [Int]? {
        var used = 0.0, kept: Set<Int> = []
        for column in logPriority where shown.contains(column) {
            used += widths.indices.contains(column) ? widths[column] : 0
            guard used <= room else { break }
            kept.insert(column)
        }
        return logNeeded.allSatisfy { !shown.contains($0) || kept.contains($0) } ? shown.filter(kept.contains) : nil
    }

    /// One nav log row in `logColumns` order. The first point has no leg into it, so it shows what is left to go.
    public static func logCells(_ point: Point, page: PlanPage?) -> [String] {
        let dashes = Array(repeating: NavText.dashes, count: logColumns.count - 1)
        guard let leg = point.leg else { return [point.title] + (page.map { $0.start } ?? dashes) }
        if let planned = page?.legs[point.target], !planned.cells.isEmpty {
            var out = [point.title] + planned.cells
            // Airborne, the active leg keeps its live time.
            if planned.time == nil { out[logTime] = leg.time ?? NavText.dashes }
            return out
        }
        var out = [point.title] + dashes
        (out[1], out[3]) = (leg.course, leg.distance)
        return out
    }

    public static func logTotals(_ page: PlanPage) -> [String] {
        let log = page.plan.log
        var out = ["Total"] + Array(repeating: "", count: logColumns.count - 1)
        out[3] = NavText.fixed(log.totalDistanceNM, 1)
        out[logTime] = log.totalTime.map(NavText.duration) ?? NavText.dashes
        out[logTime + 1] = log.totalFuel.map { NavText.fixed($0, 1) } ?? NavText.dashes
        return out
    }

    /// Temperature against the standard atmosphere at that altitude, as "+6"; dashes without a forecast temperature.
    public static func isaDeviation(temperatureC: Double?, altitudeFt: Int) -> String {
        guard let t = temperatureC else { return NavText.dashes }
        let deviation = Int((t - (15 - 1.98 * Double(altitudeFt) / 1000)).rounded())
        return deviation > 0 ? "+\(deviation)" : "\(deviation)"
    }

    // Magnetic, north as 360, as the route rows write it.
    private static func degrees(_ value: Double) -> String {
        let whole = Int(RouteMath.normalized(value).rounded()) % 360
        return NavText.pad(whole == 0 ? 360 : whole, 3) + "°M"
    }
}
