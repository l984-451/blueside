public struct RouteLeg: Equatable, Sendable {
    public var from: RouteWaypoint
    public var to: RouteWaypoint
    public var distanceNM: Double
    /// Degrees true at the start of the leg.
    public var trueCourse: Double
    /// Degrees magnetic at the start of the leg.
    public var magneticCourse: Double
    /// Distance from the first waypoint to the end of this leg.
    public var cumulativeDistanceNM: Double
}

public struct LegWind: Equatable, Sendable {
    /// Where the wind blows from, degrees true.
    public var directionTrue: Double
    public var speedKt: Double

    public init(directionTrue: Double, speedKt: Double) {
        self.directionTrue = directionTrue
        self.speedKt = speedKt
    }
}

/// One leg of a nav log. The last five values are absent when the wind makes the leg unflyable.
public struct NavLogLeg: Equatable, Sendable {
    public var leg: RouteLeg
    /// True when no wind was given for this leg and calm was used.
    public var windIsAssumedCalm: Bool
    public var trueHeading: Double?
    public var magneticHeading: Double?
    public var groundspeedKt: Double?
    /// Seconds.
    public var time: TimeInterval?
    /// In the unit of the burn rate.
    public var fuel: Double?
}

public struct NavLog: Equatable, Sendable {
    public var legs: [NavLogLeg]
    public var totalDistanceNM: Double
    /// Seconds. Absent when any leg has no time.
    public var totalTime: TimeInterval?
    /// Absent when any leg has no fuel figure.
    public var totalFuel: Double?
}

extension Route {
    /// One great circle leg per pair of waypoints. The date sets the magnetic variation.
    public func legs(date: Date) -> [RouteLeg] {
        var out: [RouteLeg] = []
        var total = 0.0
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let distance = Geo.distanceNM(from: a.coordinate, to: b.coordinate)
            let course = Geo.initialBearing(from: a.coordinate, to: b.coordinate)
            total += distance
            out.append(RouteLeg(from: a, to: b, distanceNM: distance, trueCourse: course,
                                magneticCourse: RouteMath.magnetic(course, at: a.coordinate, date: date),
                                cumulativeDistanceNM: total))
        }
        return out
    }

    public var totalDistanceNM: Double {
        var total = 0.0
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            total += Geo.distanceNM(from: a.coordinate, to: b.coordinate)
        }
        return total
    }

    /// Headings, groundspeed, time and fuel per leg. A leg with no wind given is flown in calm air and says so.
    public func navLog(trueAirspeedKt: Double, fuelBurnPerHour: Double, winds: [LegWind?] = [], date: Date) -> NavLog {
        let speedIsUsable = trueAirspeedKt.isFinite && trueAirspeedKt > 0
        let burnIsUsable = fuelBurnPerHour.isFinite && fuelBurnPerHour > 0
        var rows: [NavLogLeg] = []
        for (index, leg) in legs(date: date).enumerated() {
            let given: LegWind? = index < winds.count ? winds[index] : nil
            var row = NavLogLeg(leg: leg, windIsAssumedCalm: given == nil, trueHeading: nil,
                                magneticHeading: nil, groundspeedKt: nil, time: nil, fuel: nil)
            let wind = given ?? LegWind(directionTrue: 0, speedKt: 0)
            if speedIsUsable, wind.directionTrue.isFinite, wind.speedKt.isFinite, wind.speedKt >= 0 {
                let angle = (wind.directionTrue - leg.trueCourse) * .pi / 180
                let crosswind = wind.speedKt * sin(angle)
                let headwind = wind.speedKt * cos(angle)
                if abs(crosswind) < trueAirspeedKt {
                    let correction = asin(crosswind / trueAirspeedKt)
                    let groundspeed = trueAirspeedKt * cos(correction) - headwind
                    let hours = leg.distanceNM / groundspeed
                    let fuel = hours * fuelBurnPerHour
                    // Under 1 kt over the ground is no progress, and absurd inputs can overflow; such legs are unflyable.
                    if groundspeed >= 1, groundspeed.isFinite, (hours * 3600).isFinite {
                        let heading = RouteMath.normalized(leg.trueCourse + correction * 180 / .pi)
                        row.trueHeading = heading
                        row.magneticHeading = RouteMath.magnetic(heading, at: leg.from.coordinate, date: date)
                        row.groundspeedKt = groundspeed
                        row.time = hours * 3600
                        row.fuel = burnIsUsable && fuel.isFinite ? fuel : nil
                    }
                }
            }
            rows.append(row)
        }
        // A total needs a value from every leg and a finite sum.
        func total(_ values: [Double]) -> Double? {
            let sum = values.reduce(0, +)
            return values.count == rows.count && sum.isFinite ? sum : nil
        }
        return NavLog(legs: rows, totalDistanceNM: rows.last?.leg.cumulativeDistanceNM ?? 0,
                      totalTime: total(rows.compactMap(\.time)), totalFuel: total(rows.compactMap(\.fuel)))
    }
}
