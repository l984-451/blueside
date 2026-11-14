/// Declination from the World Magnetic Model 2025. The model data is a US Government work in the public domain.
public enum MagneticModel {
    public static let validFrom = 2025.0
    public static let validUntil = 2030.0

    /// Degrees, east positive. Outside 2025 to 2030 the value is extrapolated; ask covers first.
    /// A position that is not a number gives 0.
    public static func declination(at coordinate: Coordinate, altitudeFt: Double, date: Date) -> Double {
        declination(latitude: coordinate.latitude, longitude: coordinate.longitude,
                    altitudeKm: altitudeFt * 0.0003048, decimalYear: decimalYear(date))
    }

    /// False when the date is outside the years the model was made for.
    public static func covers(_ date: Date) -> Bool {
        let year = decimalYear(date)
        return year >= validFrom && year < validUntil
    }

    /// Days from 1970-01-01 to 1 January of a year, Gregorian calendar, years after 1.
    private static func daysToYearStart(_ year: Int) -> Int {
        let y = year - 1
        return y * 365 + y / 4 - y / 100 + y / 400 - 719_162
    }

    /// The date as a year with a fraction, in UTC, by arithmetic alone.
    static func decimalYear(_ date: Date) -> Double {
        let raw = date.timeIntervalSince1970
        guard raw.isFinite else { return validFrom }
        let seconds = min(max(raw, -6e10), 6e11)
        let days = Int((seconds / 86400).rounded(.down))
        var year = 1970 + Int((Double(days) / 365.2425).rounded(.down))
        while daysToYearStart(year + 1) <= days { year += 1 }
        while daysToYearStart(year) > days { year -= 1 }
        let start = Double(daysToYearStart(year)) * 86400
        let length = Double(daysToYearStart(year + 1) - daysToYearStart(year)) * 86400
        return Double(year) + (seconds - start) / length
    }

    static func declination(latitude: Double, longitude: Double, altitudeKm: Double, decimalYear: Double) -> Double {
        let parts = field(latitude: latitude, longitude: longitude, altitudeKm: altitudeKm, decimalYear: decimalYear)
        let degrees = atan2(parts.y, parts.x) * 180 / .pi
        return degrees.isFinite ? degrees : 0
    }

    /// North, east and down parts of the field in nanotesla. Height is above the WGS84 ellipsoid.
    static func field(latitude: Double, longitude: Double, altitudeKm: Double,
                      decimalYear: Double) -> (x: Double, y: Double, z: Double) {
        guard latitude.isFinite, longitude.isFinite, decimalYear.isFinite else { return (0, 0, 0) }
        let height = altitudeKm.isFinite ? altitudeKm : 0
        // The east part divides by the cosine of latitude, so stay a hair off the poles.
        let phi = min(max(latitude, -89.9999), 89.9999) * .pi / 180
        let lambda = longitude * .pi / 180

        // WGS84 ellipsoid: geodetic latitude and height to geocentric radius and latitude.
        let semiMajor = 6378.137
        let flattening = 1 / 298.257223563
        let e2 = flattening * (2 - flattening)
        let curvature = semiMajor / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let p = (curvature + height) * cos(phi)
        let z = (curvature * (1 - e2) + height) * sin(phi)
        let radius = (p * p + z * z).squareRoot()
        let phiCentric = asin(z / radius)
        // In terms of colatitude: its cosine is the sine of latitude.
        let cosT = sin(phiCentric)
        let sinT = cos(phiCentric)

        // Schmidt semi-normalised functions and their slopes, stored at n * size + m.
        let maxDegree = 12
        let size = maxDegree + 1
        var legendre = [Double](repeating: 0, count: size * size)
        var slope = [Double](repeating: 0, count: size * size)
        legendre[0] = 1
        for n in 1...maxDegree {
            for m in 0...n {
                let i = n * size + m
                if n == m {
                    let c = n == 1 ? 1.0 : (Double(2 * n - 1) / Double(2 * n)).squareRoot()
                    let prev = (n - 1) * size + (m - 1)
                    legendre[i] = c * sinT * legendre[prev]
                    slope[i] = c * (sinT * slope[prev] + cosT * legendre[prev])
                } else {
                    let one = (n - 1) * size + m
                    let two = n >= 2 ? (n - 2) * size + m : 0
                    let k = n >= 2 ? Double((n - 1) * (n - 1) - m * m).squareRoot() : 0
                    let norm = Double(n * n - m * m).squareRoot()
                    let scale = Double(2 * n - 1)
                    legendre[i] = (scale * cosT * legendre[one] - k * legendre[two]) / norm
                    slope[i] = (scale * (cosT * slope[one] - sinT * legendre[one]) - k * slope[two]) / norm
                }
            }
        }

        let years = decimalYear - MagneticCoefficients.epoch
        let values = MagneticCoefficients.values
        var north = 0.0, east = 0.0, down = 0.0
        for row in 0..<(values.count / 6) {
            let n = Int(values[row * 6])
            let m = Int(values[row * 6 + 1])
            let g = values[row * 6 + 2] + years * values[row * 6 + 4]
            let h = values[row * 6 + 3] + years * values[row * 6 + 5]
            let ratio = pow(6371.2 / radius, Double(n + 2))
            let cosM = cos(Double(m) * lambda)
            let sinM = sin(Double(m) * lambda)
            let i = n * size + m
            north += ratio * (g * cosM + h * sinM) * slope[i]
            east += ratio * Double(m) * (g * sinM - h * cosM) * legendre[i]
            down -= ratio * Double(n + 1) * (g * cosM + h * sinM) * legendre[i]
        }
        east /= sinT

        // Turn from the geocentric frame to the geodetic one.
        let tilt = phiCentric - phi
        return (north * cos(tilt) - down * sin(tilt), east, north * sin(tilt) + down * cos(tilt))
    }
}
