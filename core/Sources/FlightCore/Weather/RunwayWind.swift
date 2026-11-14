public struct WindComponents: Equatable, Sendable {
    /// Along the runway: positive on the nose, negative on the tail.
    public var headwindKt: Double
    /// Across the runway: positive from the right, negative from the left.
    public var crosswindFromRightKt: Double

    /// Wind from a true direction against a true heading. Nil for values that are not real.
    public init?(windFromTrue: Double, speedKt: Double, runwayTrueHeading: Double) {
        guard windFromTrue.isFinite, speedKt.isFinite, runwayTrueHeading.isFinite, speedKt >= 0 else { return nil }
        let angle = (windFromTrue - runwayTrueHeading) * .pi / 180
        headwindKt = speedKt * cos(angle)
        crosswindFromRightKt = speedKt * sin(angle)
    }
}

public struct RunwayWind: Equatable, Sendable {
    public var steady: WindComponents
    /// Nil unless the report has a gust.
    public var gust: WindComponents?
}

public struct RunwayChoice: Equatable, Sendable {
    public var runway: Runway
    public var end: RunwayEnd
    public var wind: RunwayWind
}

extension Metar {
    /// Components on a runway end's true heading. A METAR wind direction is true, so nothing is converted.
    /// Nil when the wind has no single direction or the heading is missing. Calm gives zeros.
    public func runwayWind(trueHeading: Int?) -> RunwayWind? {
        guard let trueHeading, let speed = windSpeedKt, speed >= 0 else { return nil }
        let hasDirection = windDirection != nil && !windVariable
        // Calm needs no direction. Any other wind needs one.
        guard speed == 0 || hasDirection else { return nil }
        let from = Double(windDirection ?? 0)
        let heading = Double(trueHeading)
        guard let steady = WindComponents(windFromTrue: from, speedKt: Double(speed), runwayTrueHeading: heading) else {
            return nil
        }
        var gust: WindComponents?
        if let reported = windGustKt, hasDirection {
            gust = WindComponents(windFromTrue: from, speedKt: Double(reported), runwayTrueHeading: heading)
        }
        return RunwayWind(steady: steady, gust: gust)
    }

    /// The end with the most steady headwind, then the least crosswind, then the longest runway.
    /// Nil for calm, variable or missing wind, an end with no true heading, or a tie with the wind on different sides.
    public func bestRunwayEnd(of runways: [Runway]) -> RunwayChoice? {
        guard let speed = windSpeedKt, speed > 0, windDirection != nil, !windVariable else { return nil }
        var best: RunwayChoice?
        var tied = false
        // A pad with one end has no direction to choose.
        for runway in runways where runway.ends.count == 2 {
            for end in runway.ends {
                // A runway whose heading is not known could be the better one, so nothing is picked.
                guard let wind = runwayWind(trueHeading: end.trueHeading) else { return nil }
                let choice = RunwayChoice(runway: runway, end: end, wind: wind)
                guard let current = best, Self.rank(choice) <= Self.rank(current) else {
                    best = choice
                    tied = false
                    continue
                }
                // Equal ends with the same wind, as on parallel runways, are one answer. Otherwise it is a guess.
                if Self.rank(choice) == Self.rank(current), Self.crossTenths(choice) != Self.crossTenths(current) {
                    tied = true
                }
            }
        }
        return tied ? nil : best
    }

    // Tenths of a knot, so parallel runways tie and the longer one wins.
    private static func tenths(_ value: Double) -> Int { Int((value * 10).rounded()) }

    private static func crossTenths(_ choice: RunwayChoice) -> Int { tenths(choice.wind.steady.crosswindFromRightKt) }

    /// Higher is better: headwind, then the smaller crosswind, then length.
    private static func rank(_ choice: RunwayChoice) -> (Int, Int, Int) {
        (tenths(choice.wind.steady.headwindKt), -abs(crossTenths(choice)), choice.runway.lengthFt ?? 0)
    }
}
