public struct Coordinate: Equatable, Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    public static let earthRadiusNM = 3440.065

    /// Great-circle distance in nautical miles (haversine, spherical earth).
    public static func distanceNM(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        // min() would turn NaN into 1, giving a plausible wrong distance.
        guard h.isFinite else { return .nan }
        return 2 * earthRadiusNM * asin(min(1, h.squareRoot()))
    }

    /// Initial true bearing in degrees, from 0 up to but excluding 360.
    public static func initialBearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point a distance along the great circle that leaves on a true bearing. Longitude from -180 up to 180.
    /// Nil for values that are not real.
    public static func destination(from a: Coordinate, bearingTrue: Double, distanceNM: Double) -> Coordinate? {
        guard a.latitude.isFinite, a.longitude.isFinite, bearingTrue.isFinite, distanceNM.isFinite else { return nil }
        let lat1 = a.latitude * .pi / 180
        let bearing = bearingTrue * .pi / 180
        let arc = distanceNM / earthRadiusNM
        let lat2 = asin(min(1, max(-1, sin(lat1) * cos(arc) + cos(lat1) * sin(arc) * cos(bearing))))
        let lon2 = a.longitude * .pi / 180
            + atan2(sin(bearing) * sin(arc) * cos(lat1), cos(arc) - sin(lat1) * sin(lat2))
        let longitude = (lon2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: longitude)
    }
}
