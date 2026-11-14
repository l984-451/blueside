/// Climb and descent: where the plan puts top of climb and top of descent, and what they cost.
extension FlightPlan {
    /// One climb or descent as the POH gives it.
    public struct Phase: Equatable, Sendable {
        public var rateFPM: Double
        public var tasKt: Double
        public var burnGPH: Double

        public init(rateFPM: Double, tasKt: Double, burnGPH: Double) {
            self.rateFPM = rateFPM
            self.tasKt = tasKt
            self.burnGPH = burnGPH
        }

        var isUsable: Bool {
            [rateFPM, tasKt].allSatisfy { $0.isFinite && $0 > 0 } && burnGPH.isFinite && burnGPH >= 0
        }
    }

    public struct Vertical: Equatable, Sendable {
        public var climb: Phase
        public var descent: Phase

        public init(climb: Phase, descent: Phase) {
            self.climb = climb
            self.descent = descent
        }
    }

    /// What a leg of the log is doing.
    public enum Segment: Equatable, Sendable { case climb, cruise, descent }

    public static let verticalMissingNote = "Climb and descent aren't counted: type the aircraft's climb and descent numbers to add top of climb and top of descent."
    public static let calmNote = "Climb and descent flown in calm air."

    struct Profiled {
        var log: NavLog
        var aloft: [LegWindAloft?]
        var segments: [Segment]
        /// The altitude at the end of each leg, in feet.
        var endAltitudesFt: [Int]
        /// Legs that end at an inserted top of climb or top of descent.
        var markerLegs: Set<Int>
        var note: String?
    }

    /// The route flown at one cruise altitude, with climb and descent when given. Distance for each phase is still air
    /// (speed x time, from and to field elevation, 0 ft when unknown); only the cruise legs take wind.
    /// In flight there is no climb; the descent still counts.
    static func profiled(_ route: Route, _ vertical: Vertical?, _ cruiseFt: Int, _ tas: Double, _ burn: Double,
                         _ departure: Date, _ winds: WindsAloft?, inFlight: Bool = false) -> Profiled {
        let plain = {
            let (log, aloft) = flown(route, tas, burn, Double(cruiseFt), departure, winds)
            return Profiled(log: log, aloft: aloft, segments: log.legs.map { _ in .cruise },
                            endAltitudesFt: log.legs.map { _ in cruiseFt }, markerLegs: [], note: nil)
        }
        let total = route.totalDistanceNM
        let from = inFlight ? Double(cruiseFt) : max(0, route.waypoints.first?.elevationFt ?? 0)
        let to = max(0, route.waypoints.last?.elevationFt ?? 0)
        guard let vertical, vertical.climb.isUsable, vertical.descent.isUsable, Double(cruiseFt) >= from,
              Double(cruiseFt) > to, total > 0
        else { return plain() }
        // Nautical miles per foot of altitude gained or lost.
        let climbPerFt = vertical.climb.tasKt / 60 / vertical.climb.rateFPM
        let descentPerFt = vertical.descent.tasKt / 60 / vertical.descent.rateFPM
        var peak = Double(cruiseFt), note: String?
        if total < (peak - from) * climbPerFt + (peak - to) * descentPerFt {
            peak = (total + from * climbPerFt + to * descentPerFt) / (climbPerFt + descentPerFt)
            guard !inFlight, peak > max(from, to) else { return plain() }
            let shown = Int((peak / 100).rounded()) * 100
            note = "The route is too short to reach \(cruiseFt) ft: climb and descent peak at about \(shown) ft."
        }
        let toc = climbPerFt * (peak - from), tod = total - descentPerFt * (peak - to)
        let markers = note != nil ? [(toc, "-TOC/TOD-")] : inFlight ? [(tod, "-TOD-")] : [(toc, "-TOC-"), (tod, "-TOD-")]

        var points = [route.waypoints[0]]
        var ends: [Double] = [], marked = Set<Int>()
        let slack = 0.05
        for leg in route.legs(date: departure) {
            let start = leg.cumulativeDistanceNM - leg.distanceNM
            for (d, title) in markers where d > start + slack && d < leg.cumulativeDistanceNM - slack {
                guard let at = Geo.destination(from: leg.from.coordinate, bearingTrue: leg.trueCourse, distanceNM: d - start)
                else { continue }
                points.append(RouteWaypoint(kind: .user, ident: title, name: title, coordinate: at))
                marked.insert(ends.count)
                ends.append(d)
            }
            points.append(leg.to)
            ends.append(leg.cumulativeDistanceNM)
        }
        guard let split = Route(waypoints: points, navCycle: route.navCycle) else { return plain() }

        var segments: [Segment] = [], altitudes: [Int] = []
        for (index, end) in ends.enumerated() {
            let start = index == 0 ? 0 : ends[index - 1]
            if toc > 0, end <= toc + 0.001 {
                segments.append(.climb)
                altitudes.append(Int((toc > 0 ? from + end / toc * (peak - from) : peak).rounded()))
            } else if start >= tod - 0.001 {
                segments.append(.descent)
                altitudes.append(Int((total > tod ? to + (total - end) / (total - tod) * (peak - to) : to).rounded()))
            } else {
                segments.append(.cruise)
                altitudes.append(Int(peak.rounded()))
            }
        }

        func calm(_ row: NavLogLeg, _ phase: Phase) -> NavLogLeg {
            var out = row
            out.windIsAssumedCalm = true
            out.trueHeading = row.leg.trueCourse
            out.magneticHeading = row.leg.magneticCourse
            out.groundspeedKt = phase.tasKt
            let hours = row.leg.distanceNM / phase.tasKt
            out.time = hours * 3600
            out.fuel = hours * phase.burnGPH
            return out
        }
        // The cruise legs as navLog flies them, the others in calm air at their own speed and burn.
        func log(_ legWinds: [LegWind?]) -> NavLog {
            let base = split.navLog(trueAirspeedKt: tas, fuelBurnPerHour: burn, winds: legWinds, date: departure)
            let rows = zip(base.legs, segments).map { row, segment in
                segment == .cruise ? row : calm(row, segment == .climb ? vertical.climb : vertical.descent)
            }
            func sum(_ values: [Double]) -> Double? {
                let s = values.reduce(0, +)
                return values.count == rows.count && s.isFinite ? s : nil
            }
            return NavLog(legs: rows, totalDistanceNM: base.totalDistanceNM,
                          totalTime: sum(rows.compactMap(\.time)), totalFuel: sum(rows.compactMap(\.fuel)))
        }
        let calmLog = log([])
        var aloft: [LegWindAloft?] = calmLog.legs.map { _ in nil }
        var result = calmLog
        if let winds {
            var elapsed = 0.0
            aloft = zip(calmLog.legs, segments).map { row, segment in
                defer { elapsed += row.time ?? 0 }
                guard segment == .cruise else { return nil }
                return winds.leg(from: row.leg.from.coordinate, to: row.leg.to.coordinate, altitudeFt: Double(cruiseFt),
                                 at: departure + elapsed + (row.time ?? 0) / 2)
            }
            result = log(aloft.map { $0?.wind })
        }
        return Profiled(log: result, aloft: aloft, segments: segments, endAltitudesFt: altitudes, markerLegs: marked, note: note)
    }
}
