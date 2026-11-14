/// Sunrise, sunset and civil twilight from the NOAA solar position equations (gml.noaa.gov/grad/solcalc).
public struct SunTimes: Equatable, Sendable {
    /// Morning civil twilight begins. Nil when the sun never reaches that height that day.
    public var civilDawn: Date?
    public var sunrise: Date?
    public var sunset: Date?
    /// Evening civil twilight ends.
    public var civilDusk: Date?
}

public enum Sun {
    /// Zenith angles: sunrise and sunset carry NOAA's refraction and disc allowance; civil twilight is 6° below.
    static let riseSetZenith = 90.833
    static let civilZenith = 96.0

    /// The events of the solar day whose noon falls nearest the given time, so an evening flight gets that day.
    public static func times(near date: Date, at point: Coordinate) -> SunTimes {
        // The UTC midnight the day's minutes count from; may be the day before or after the given time.
        let mean = (720 - 4 * point.longitude) * 60
        let base = Date(timeIntervalSince1970: ((date.timeIntervalSince1970 - mean) / 86400).rounded() * 86400)
        func event(_ zenith: Double, _ sign: Double) -> Date? {
            var t = base + mean
            // Recomputed once at the first answer, as the NOAA calculator does.
            for _ in 0..<2 {
                let s = solar(at: t)
                guard let ha = hourAngle(zenith: zenith, latitude: point.latitude, declination: s.declination) else {
                    return nil
                }
                let minutes = 720 - 4 * (point.longitude + sign * ha) - s.equationOfTime
                t = base + minutes * 60
            }
            return t
        }
        return SunTimes(civilDawn: event(civilZenith, 1), sunrise: event(riseSetZenith, 1),
                        sunset: event(riseSetZenith, -1), civilDusk: event(civilZenith, -1))
    }

    /// Sun center height above the horizon, degrees, with no refraction.
    public static func elevation(at date: Date, point: Coordinate) -> Double {
        let s = solar(at: date)
        let minutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        let trueSolar = minutes + s.equationOfTime + 4 * point.longitude
        let hourAngle = (trueSolar / 4 - 180) * .pi / 180
        let lat = point.latitude * .pi / 180
        let cosZenith = sin(lat) * sin(s.declination) + cos(lat) * cos(s.declination) * cos(hourAngle)
        return 90 - acos(min(1, max(-1, cosZenith))) * 180 / .pi
    }

    /// Night as 14 CFR 1.1 defines it: between the end of evening and the beginning of morning civil twilight.
    public static func isNight(at date: Date, point: Coordinate) -> Bool {
        elevation(at: date, point: point) < 90 - civilZenith
    }

    /// Hour angle in degrees for a zenith angle; nil when the sun stays above or below it all day.
    private static func hourAngle(zenith: Double, latitude: Double, declination: Double) -> Double? {
        let lat = latitude * .pi / 180
        let arg = cos(zenith * .pi / 180) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
        guard arg >= -1, arg <= 1 else { return nil }
        return acos(arg) * 180 / .pi
    }

    /// Declination in radians and the equation of time in minutes.
    private static func solar(at date: Date) -> (declination: Double, equationOfTime: Double) {
        let rad = Double.pi / 180
        let t = (date.timeIntervalSince1970 / 86400 + 2_440_587.5 - 2_451_545) / 36525
        var l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        if l0 < 0 { l0 += 360 }
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * m * rad) * (0.019993 - 0.000101 * t)
            + sin(3 * m * rad) * 0.000289
        let omega = 125.04 - 1934.136 * t
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(omega * rad)
        let mean = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let epsilon = (mean + 0.00256 * cos(omega * rad)) * rad
        let declination = asin(sin(epsilon) * sin(lambda * rad))
        var y = tan(epsilon / 2)
        y *= y
        let l = l0 * rad, mr = m * rad
        let eot = y * sin(2 * l) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l) - 0.5 * y * y * sin(4 * l)
            - 1.25 * e * e * sin(2 * mr)
        return (declination, eot / rad * 4)
    }
}
