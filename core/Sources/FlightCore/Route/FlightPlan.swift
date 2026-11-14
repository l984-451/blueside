/// What the pilot sets for a flight. The route itself is the active RoutePlan, kept on its own.
public struct FlightPlanInputs: Codable, Equatable, Sendable {
    public enum Rules: String, Codable, Sendable { case vfr, ifr }

    public var aircraftID: UUID?
    public var cruiseAltitudeFt: Int
    public var departure: Date
    public var rules: Rules
    public var alternate: RouteWaypoint?

    public init(aircraftID: UUID? = nil, cruiseAltitudeFt: Int, departure: Date, rules: Rules = .vfr,
                alternate: RouteWaypoint? = nil) {
        self.aircraftID = aircraftID
        self.cruiseAltitudeFt = cruiseAltitudeFt
        self.departure = departure
        self.rules = rules
        self.alternate = alternate
    }

    /// Now rounded up to the next quarter hour.
    public static func defaultDeparture(now: Date) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 900).rounded(.up) * 900)
    }
}

/// A nav log with winds aloft, fuel against the reserve rules, the alternate advice and sun times.
public struct FlightPlan: Equatable, Sendable {
    /// The FB levels the altitude table offers, beside the picked altitude.
    /// Four cruising levels to compare, the legal ones for the course and rules.
    public static func tableLevels(magneticCourse: Double?, rules: FlightPlanInputs.Rules) -> [Int] {
        let east = magneticCourse.map(isEastbound) ?? true
        let thousands = east ? [3, 5, 7, 9] : [4, 6, 8, 10]
        return thousands.map { $0 * 1000 + (rules == .vfr ? 500 : 0) }
    }

    /// 0° through 179° magnetic, judged on the whole degrees the course is printed in.
    static func isEastbound(_ magneticCourse: Double) -> Bool { RouteMath.normalized(magneticCourse.rounded()) < 180 }

    public struct Fuel: Equatable, Sendable {
        public var taxi: Double
        public var trip: Double
        /// Destination to alternate at cruise; nil with no alternate.
        public var alternate: Double?
        public var reserve: Double
        public var required: Double { taxi + trip + (alternate ?? 0) + reserve }
    }

    public struct Altitude: Equatable, Sendable {
        public var ft: Int
        public var time: TimeInterval?
        public var fuel: Double?
        /// Fits the direction of flight on the first leg; nil where the rule says nothing. A hint only.
        public var legal: Bool?
        public var picked: Bool
    }

    public struct Alternate: Equatable, Sendable {
        /// Nil when it could not be told.
        public var required: Bool?
        public var text: String
    }

    public var log: NavLog
    public var winds: [LegWindAloft?]
    public var departure: Date
    public var eta: Date?
    public var night: Bool
    public var reserveMinutes: Double
    /// The rule the reserve comes from, in words.
    public var reserveRule: String
    /// Nil without a time for every leg or a burn rate.
    public var fuel: Fuel?
    /// Time and burn are known but the fuel required is not, as when IFR needs an alternate and none is picked.
    public var fuelUnknown = false
    /// The W&B start fuel as given. Airborne it no longer tells what is in the tanks, so nothing is worked out from it.
    public var fuelOnBoard: Double?
    /// Planned from a live fix moving faster than any taxi.
    public var airborne = false
    /// Only for IFR.
    public var alternate: Alternate?
    public var altitudes: [Altitude]
    /// What each leg of the log is doing, and its altitude at the end, in feet.
    public var segments: [Segment] = []
    public var endAltitudesFt: [Int] = []
    /// The log legs that end at an inserted top of climb or top of descent.
    public var markerLegs: Set<Int> = []
    /// What the pilot should know about the profile, such as why there is no top of climb.
    public var notes: [String] = []
    public var departureSun: SunTimes?
    public var destinationSun: SunTimes?

    /// The plan for a route. Burn is gal/h; fuel on board is the W&B start fuel. `inFlight` drops the climb. Airborne,
    /// there is no taxi, the fuel on board is unknown and, given `now`, the plan departs now. Given `now`, winds whose
    /// use window has ended are not used.
    public static func make(route: Route, inputs: FlightPlanInputs, trueAirspeedKt: Double, burnGPH: Double,
                            taxiFuelGal: Double = 0, fuelOnBoardGal: Double? = nil, winds: WindsAloft?, tafs: [Taf],
                            destinationHasApproach: Bool? = nil, vertical: Vertical? = nil, inFlight: Bool = false,
                            airborne: Bool = false, now: Date? = nil) -> FlightPlan {
        let departure = airborne ? (now ?? inputs.departure) : inputs.departure
        var winds = winds
        if let now { winds = winds?.unexpired(at: now) }
        let altitude = Double(inputs.cruiseAltitudeFt)
        let profile = profiled(route, vertical, inputs.cruiseAltitudeFt, trueAirspeedKt, burnGPH, departure, winds,
                               inFlight: inFlight)
        let (log, aloft) = (profile.log, profile.aloft)
        let hasVertical = profile.segments.contains { $0 != .cruise }
        let eta = log.totalTime.map { departure + $0 }
        let start = route.waypoints.first?.coordinate, end = route.waypoints.last?.coordinate
        // 14 CFR 91.151(a) counts night by 1.1: past evening civil twilight; at either end of the flight.
        let night = [(start, departure), (end, eta)].contains { point, time in
            guard let point, let time else { return false }
            return Sun.isNight(at: time, point: point)
        }
        let minutes: Double, rule: String
        switch inputs.rules {
        case .vfr: (minutes, rule) = night ? (45, "45 min at night, 14 CFR 91.151(a)(2)") : (30, "30 min by day, 14 CFR 91.151(a)(1)")
        case .ifr: (minutes, rule) = (45, "45 min, 14 CFR 91.167(a)(3)")
        }
        var alternateFuel: Double?
        if let dest = route.waypoints.last, let alt = inputs.alternate,
           let leg = Route(waypoints: [dest, alt], navCycle: route.navCycle) {
            alternateFuel = flown(leg, trueAirspeedKt, burnGPH, altitude, eta ?? departure, winds).0.totalFuel
        }
        let burnUsable = burnGPH.isFinite && burnGPH > 0
        let advice = inputs.rules == .ifr
            ? alternateAdvice(route.waypoints.last, eta: eta, tafs: tafs, hasApproach: destinationHasApproach) : nil
        // 91.167(a)(2): a required alternate with none picked leaves the fuel total unknown, not short of it.
        let missingAlternate = advice?.required == true && inputs.alternate == nil
        let fuel = log.totalFuel.flatMap { trip -> Fuel? in
            guard burnUsable, !missingAlternate, inputs.alternate == nil || alternateFuel != nil else { return nil }
            return Fuel(taxi: airborne ? 0 : max(0, taxiFuelGal), trip: trip, alternate: alternateFuel,
                        reserve: minutes / 60 * burnGPH)
        }
        let picked = inputs.cruiseAltitudeFt
        let course = log.legs.first?.leg.magneticCourse
        let altitudes = Set(tableLevels(magneticCourse: course, rules: inputs.rules) + [picked]).sorted().map { ft in
            let l = ft == picked ? log : profiled(route, vertical, ft, trueAirspeedKt, burnGPH, departure, winds, inFlight: inFlight).log
            return Altitude(ft: ft, time: l.totalTime, fuel: l.totalFuel,
                            legal: course.flatMap { isLegal(ft, magneticCourse: $0, rules: inputs.rules) }, picked: ft == picked)
        }
        return FlightPlan(
            log: log, winds: aloft, departure: departure, eta: eta, night: night, reserveMinutes: minutes,
            reserveRule: rule, fuel: fuel, fuelUnknown: fuel == nil && burnUsable && log.totalTime != nil,
            fuelOnBoard: fuelOnBoardGal, airborne: airborne,
            alternate: advice,
            altitudes: altitudes,
            segments: profile.segments, endAltitudesFt: profile.endAltitudesFt, markerLegs: profile.markerLegs,
            notes: [profile.note, vertical == nil ? verticalMissingNote : nil, hasVertical ? calmNote : nil].compactMap { $0 },
            departureSun: start.map { Sun.times(near: departure, at: $0) },
            destinationSun: end.map { Sun.times(near: eta ?? departure, at: $0) })
    }

    /// Calm first to time each leg, then again with the wind at each leg's midpoint time.
    static func flown(_ route: Route, _ tas: Double, _ burn: Double, _ altitudeFt: Double, _ departure: Date,
                      _ winds: WindsAloft?) -> (NavLog, [LegWindAloft?]) {
        let calm = route.navLog(trueAirspeedKt: tas, fuelBurnPerHour: burn, date: departure)
        guard let winds else { return (calm, calm.legs.map { _ in nil }) }
        var elapsed = 0.0
        let aloft = calm.legs.map { row -> LegWindAloft? in
            let mid = departure + elapsed + (row.time ?? 0) / 2
            elapsed += row.time ?? 0
            return winds.leg(from: row.leg.from.coordinate, to: row.leg.to.coordinate, altitudeFt: altitudeFt, at: mid)
        }
        return (route.navLog(trueAirspeedKt: tas, fuelBurnPerHour: burn, winds: aloft.map { $0?.wind }, date: departure),
                aloft)
    }

    /// Cruising altitudes by magnetic course: VFR odd thousands plus 500 eastbound, even plus 500 westbound
    /// (14 CFR 91.159(a)); IFR odd thousands eastbound, even westbound (14 CFR 91.179(b)(1)).
    /// Nil at or above 18000 ft, where other rules apply, and for VFR at or below 3000 ft MSL, which is never
    /// more than 3000 ft above the surface.
    public static func isLegal(_ ft: Int, magneticCourse: Double, rules: FlightPlanInputs.Rules) -> Bool? {
        guard ft < 18000, ft > 0, rules == .ifr || ft > 3000 else { return nil }
        let base = rules == .vfr ? ft - 500 : ft
        guard base % 1000 == 0 else { return false }
        return (base / 1000 % 2 == 1) == isEastbound(magneticCourse)
    }

    /// 14 CFR 91.169(b): no alternate when the destination has an instrument approach and, from 1 hour before
    /// to 1 hour after the ETA, the forecast is at least 2000 ft ceiling and 3 SM visibility.
    static func alternateAdvice(_ destination: RouteWaypoint?, eta: Date?, tafs: [Taf], hasApproach: Bool?) -> Alternate {
        guard let destination, let eta else {
            return Alternate(required: nil, text: "No ETA: check the alternate rule yourself.")
        }
        let ident = destination.ident
        if hasApproach == false {
            return Alternate(required: true, text: "Alternate required: no instrument approach at \(ident) (14 CFR 91.169(b)).")
        }
        guard let taf = tafs.filter({ $0.station == ident }).max(by: { $0.issued < $1.issued }) else {
            return Alternate(required: nil, text: "No TAF: check the alternate rule yourself.")
        }
        // ponytail: 5-minute steps; every TAF change time on the grid would be exact.
        for step in 0...24 {
            let time = eta - 3600 + Double(step) * 300
            guard let conditions = taf.conditions(at: time) else {
                return Alternate(required: nil, text: "TAF for \(ident) does not cover 1 hour either side of the ETA: check the alternate rule yourself.")
            }
            // TEMPO and PROB groups count: any forecast below the line requires one.
            let groups = [conditions.prevailing] + conditions.overlays.map { conditions.prevailing.overlaid(by: $0.group) }
            for g in groups where (g.ceilingFtAGL ?? .max) < 2000 || (g.visibilityMiles ?? 0) < 3 {
                return Alternate(required: true, text: "Alternate required: \(ident) forecast below 2000 ft ceiling or 3 SM near \(zulu(time)) (14 CFR 91.169(b)).")
            }
        }
        let approach = hasApproach == nil ? " Could not check for an instrument approach at \(ident)." : ""
        return Alternate(required: approach.isEmpty ? false : nil,
                         text: "Alternate not required by forecast (14 CFR 91.169(b))." + approach)
    }

    /// A UTC time such as 1432Z, to the nearest minute like the durations.
    static func zulu(_ date: Date) -> String {
        let t = UTCTime(Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60))
        return NavText.pad(t.hour, 2) + NavText.pad(t.minute, 2) + "Z"
    }

    // MARK: Rows

    static let fuelRequired = "Fuel required"

    /// Fuel and time summary, ready to lay out.
    public var lines: [NavPages.Line] { parted.map(\.line) }

    /// How the fuel required adds up: taxi, trip, alternate, reserve and on board.
    public var fuelParts: [NavPages.Line] { parted.filter(\.part).map(\.line) }
    /// The rest: departure, time en route, ETA, fuel required and margin.
    public var answerLines: [NavPages.Line] { parted.filter { !$0.part }.map(\.line) }

    /// The summary lines in order, each marked when it is one of the fuel parts.
    private var parted: [(line: NavPages.Line, part: Bool)] {
        var out = [
            (NavPages.Line(title: "Departure", value: Self.zulu(departure)), false),
            (NavPages.Line(title: "Time en route", value: log.totalTime.map(NavText.duration) ?? NavText.dashes), false),
            (NavPages.Line(title: "ETA", value: eta.map(Self.zulu) ?? NavText.dashes), false),
        ]
        guard let fuel else {
            // With time and burn known, the alternate advice says why.
            out.append((NavPages.Line(title: Self.fuelRequired, value: NavText.dashes,
                                      detail: fuelUnknown ? nil : "Needs cruise speed and fuel burn for the aircraft"), false))
            return out
        }
        out += [
            (NavPages.Line(title: "Taxi", value: NavText.fuel(fuel.taxi)), true),
            (NavPages.Line(title: "Trip", value: NavText.fuel(fuel.trip)), true),
        ]
        if let alt = fuel.alternate { out.append((NavPages.Line(title: "Alternate", value: NavText.fuel(alt)), true)) }
        out += [
            (NavPages.Line(title: "Reserve", value: NavText.fuel(fuel.reserve), detail: reserveRule), true),
            (NavPages.Line(title: Self.fuelRequired, value: NavText.fuel(fuel.required)), false),
        ]
        if fuelOnBoard != nil, airborne {
            out += [(NavPages.Line(title: "On board", value: NavText.dashes), true),
                    (NavPages.Line(title: "Margin", value: NavText.dashes), false)]
        } else if let onBoard = fuelOnBoard {
            let margin = onBoard - fuel.required
            let burn = fuel.reserve / reserveMinutes * 60
            let time = burn > 0 ? " · " + (margin < 0 ? "-" : "") + NavText.duration(abs(margin) / burn * 3600) : ""
            out.append((NavPages.Line(title: "On board", value: NavText.fuel(onBoard)), true))
            out.append((NavPages.Line(title: "Margin", value: NavText.fuel(margin) + time, tag: margin < 0 ? "Short" : nil), false))
        }
        return out
    }

    /// Per leg: the wind and temperature at cruise, and what is wrong with them.
    public var legWinds: [(wind: String?, note: String?)] {
        winds.enumerated().map { index, aloft in
            if segments.indices.contains(index), segments[index] != .cruise { return (nil, nil) }
            guard let aloft else { return (nil, "No winds aloft: calm assumed") }
            let w = aloft.wind
            let speed = Int(w.speedKt.rounded())
            var text = speed == 0 ? "Calm" : NavText.pad(Int(w.directionTrue.rounded()) % 360 == 0 ? 360
                : Int(w.directionTrue.rounded()), 3) + "° \(speed) kt"
            if let t = aloft.temperatureC { text += " \(Int(t.rounded()))°C" }
            let note = !aloft.inUseWindow ? "Forecast outside use window"
                : aloft.calmSamples > 0 ? "No winds station near part of this leg" : nil
            return (text, note)
        }
    }

    /// The altitude table: one line per altitude with time and fuel, legal ones marked.
    public var altitudeLines: [NavPages.Line] {
        altitudes.map { a in
            let value = [a.time.map(NavText.duration), a.fuel.map(NavText.fuel)].compactMap { $0 }.joined(separator: " · ")
            return NavPages.Line(title: "\(a.ft) ft" + (a.picked ? " (picked)" : ""), value: value.isEmpty ? NavText.dashes : value,
                                 detail: a.legal.map { $0 ? "Fits direction of flight" : "Wrong for direction of flight" })
        }
    }

    /// Sunrise, sunset and civil twilight at both ends.
    public var sunLines: [NavPages.Line] {
        func line(_ title: String, _ sun: SunTimes?) -> NavPages.Line? {
            guard let sun else { return nil }
            let parts = [("Dawn", sun.civilDawn), ("Rise", sun.sunrise), ("Set", sun.sunset), ("Dusk", sun.civilDusk)]
                .map { "\($0.0) \($0.1.map(Self.zulu) ?? NavText.dashes)" }
            return NavPages.Line(title: title, value: nil, detail: parts.joined(separator: " · "))
        }
        return [line("Sun at departure", departureSun), line("Sun at destination", destinationSun)].compactMap { $0 }
    }
}
