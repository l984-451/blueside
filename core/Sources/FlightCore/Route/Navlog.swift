/// The printable nav log as display-ready blocks. Both apps only draw it onto pages.
extension RoutePages {
    public static let actualColumn = "Actual"
    public static let navlogTitle = "Navlog"
    public static let shareNavlog = "Share Navlog"
    public static let flightBlock = "Flight"
    public static let fuelBlock = "Fuel"
    public static let weightsBlock = "Weights"
    public static let frequenciesBlock = "Frequencies"
    public static let timesBlock = "Times"
    public static let boxLabels = ["Out", "Off", "On", "In", "Hobbs"]

    public struct Navlog: Equatable, Sendable, Encodable {
        public struct Block: Equatable, Sendable, Encodable {
            public var title: String
            public var lines: [NavPages.Line]
        }

        public struct Table: Equatable, Sendable, Encodable {
            public var title: String
            public var columns: [String]
            public var rows: [[String]]
        }

        public var title: String
        /// For the shared PDF, such as "Navlog KAUS-KEDC 2026-10-15 1400Z.pdf".
        public var fileName: String
        /// The leg table's headers: the nav log columns, then Actual to write in.
        public var columns: [String]
        /// One row per point, each ending in an empty Actual cell.
        public var rows: [[String]]
        public var totals: [String]
        public var summary: Block
        public var fuel: Block
        /// Only when weight and balance is filled in.
        public var weights: Block?
        public var frequencies: Table
        public var boxesTitle: String
        /// Empty boxes to write in: out, off, on, in and Hobbs.
        public var boxes: [String]
    }

    /// The page for a planned route. Local times need the device's UTC offset; frequencies need the nav database.
    public static func navlog(_ route: RoutePlan, page: PlanPage, position: Position?, approximate: Bool = false, now: Date,
                              aircraft: AircraftProfile?, balance: WeightBalance?, localOffsetSeconds: Int?,
                              database: NavDatabase?) -> Navlog {
        let d = NavText.dashes
        let plan = page.plan
        let editor = editor(route, position: position, approximate: approximate, now: now, trueAirspeedKt: 0, fuelBurnPerHour: 0)
        let ends = route.route.waypoints.dropFirst(route.fromAircraft ? 1 : 0)
        let pair = [ends.first, ends.count > 1 ? ends.last : nil]
        func when(_ date: Date?) -> String {
            guard let date else { return d }
            let z = FlightPlan.zulu(date)
            return localOffsetSeconds.map { o in
                let t = UTCTime(date + TimeInterval(o))
                return "\(NavText.pad(t.hour, 2))\(NavText.pad(t.minute, 2)) local · \(z)"
            } ?? z
        }
        let summary = [
            ("Aircraft", aircraft.map { [$0.tail, $0.type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
                .flatMap { $0.isEmpty ? nil : $0 } ?? d),
            ("Route", route.text),
            // The highest the profile reaches, which a short route caps below the planned cruise.
            ("Altitude", NavText.grouped(plan.endAltitudesFt.max() ?? plan.altitudes.first { $0.picked }?.ft ?? 0) + " ft"),
            ("Distance", NavText.distance(plan.log.totalDistanceNM)),
            ("ETD", when(plan.departure)),
            ("ETE", plan.log.totalTime.map(NavText.duration) ?? d),
            ("ETA", when(plan.eta)),
        ].map { NavPages.Line(title: $0.0, value: $0.1) }

        func gallons(_ value: Double?) -> String { value.map(NavText.fuel) ?? d }
        let f = plan.fuel
        let fuel = [("Taxi", f?.taxi), ("Trip", f?.trip), ("Reserve", f?.reserve), ("Alternate", f?.alternate),
                    ("Total", f?.required)].map { NavPages.Line(title: $0.0, value: gallons($0.1)) }
        func pounds(_ value: Double) -> String { NavText.grouped(Int(value.rounded())) + " lb" }
        // Weights only once something is loaded; empty stations read as zero.
        let loaded = balance.flatMap { wb in aircraft?.emptyWeightLb.map { wb.zeroFuel.weightLb - $0 > 0.5 } } ?? (balance != nil)
        let weights = balance.flatMap { wb in loaded ? wb : nil }.map { wb in
            Navlog.Block(title: weightsBlock, lines: [
                ("Payload", aircraft?.emptyWeightLb.map { pounds(wb.zeroFuel.weightLb - $0) } ?? d),
                ("Zero fuel weight", pounds(wb.zeroFuel.weightLb)), ("Takeoff weight", pounds(wb.takeoff.weightLb)),
                ("Landing weight", wb.landing.map { pounds($0.weightLb) } ?? d),
            ].map { NavPages.Line(title: $0.0, value: $0.1) })
        }

        let airports = pair.map { waypoint in
            waypoint.flatMap { $0.kind == .airport ? try? database?.airport(identifier: $0.ident) : nil }
                .flatMap { try? database?.detail(airportID: $0.id) }
        }
        let names = ["ATIS/AWOS", "Tower/CTAF", "Clearance", "Ground", "Elevation", "Longest runway"]
        let cells = airports.map { detail in detail.map(frequencyCells) ?? names.map { _ in d } }
        let tableRows = names.indices.map { i in [names[i]] + cells.map { $0[i] } }
        let ident = { (i: Int) in pair[i]?.ident ?? "" }
        let name = "\(ident(0))-\(ident(1))"
        return Navlog(
            title: "\(navlogTitle) \(name)", fileName: "\(navlogTitle) \(name) \(WeatherText.dated(plan.departure)).pdf",
            columns: logColumns + [actualColumn],
            rows: editor.points.flatMap { p in logInserts(p, page: page).map { $0 + [""] } + [logCells(p, page: page) + [""]] }, totals: logTotals(page) + [""],
            summary: .init(title: flightBlock, lines: summary), fuel: .init(title: fuelBlock, lines: fuel), weights: weights,
            frequencies: .init(title: frequenciesBlock, columns: [""] + pair.map { $0?.ident ?? d }, rows: tableRows),
            boxesTitle: timesBlock, boxes: boxLabels)
    }

    // One airport's cells for ATIS/AWOS, tower or CTAF, clearance, ground, elevation and longest runway.
    private static func frequencyCells(_ detail: AirportDetail) -> [String] {
        let d = NavText.dashes
        let live = NavText.frequencies(detail.frequencies).filter {
            !NavText.outOfService(use: $0.use, frequency: $0.frequency, remark: $0.remark)
        }
        // The primary facility (use ending /P) ahead of a secondary one.
        func pick(_ kinds: [FrequencyKind]) -> Frequency? {
            for kind in kinds {
                let found = live.filter { $0.kind == kind }
                if let f = found.first(where: { $0.use.hasSuffix("/P") }) ?? found.first { return f }
            }
            return nil
        }
        func named(_ f: Frequency?) -> String { f.map { NavText.frequencyLabel($0) + " " + $0.frequency } ?? d }
        let longest = detail.runways.filter { $0.lengthFt != nil }.max { $0.lengthFt! < $1.lengthFt! }
        return [named(pick([.atis, .weather])), named(pick([.tower, .ctaf])), pick([.clearance])?.frequency ?? d,
                pick([.ground])?.frequency ?? d, detail.airport.elevationFt.map(NavText.elevation) ?? d,
                longest.map { NavText.grouped($0.lengthFt!) + " ft (\($0.id))" } ?? d]
    }
}
