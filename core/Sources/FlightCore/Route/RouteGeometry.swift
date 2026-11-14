/// A point on the unit sphere. Vector math has no trouble at the 180 degree meridian.
struct RouteVector {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ c: Coordinate) {
        let latitude = c.latitude * .pi / 180
        let longitude = c.longitude * .pi / 180
        self.init(cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
    }

    func dot(_ o: RouteVector) -> Double { x * o.x + y * o.y + z * o.z }

    func cross(_ o: RouteVector) -> RouteVector {
        RouteVector(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    var length: Double { dot(self).squareRoot() }

    /// Nil for a vector too short to have a direction.
    var unit: RouteVector? {
        let l = length
        return l.isFinite && l > 1e-12 ? RouteVector(x / l, y / l, z / l) : nil
    }
}

enum RouteMath {
    /// Into the range from 0 up to but excluding 360.
    static func normalized(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        let positive = remainder < 0 ? remainder + 360 : remainder
        return positive >= 360 ? 0 : positive
    }

    /// A true direction as a magnetic one: east variation is subtracted.
    static func magnetic(_ trueDegrees: Double, at point: Coordinate, altitudeFt: Double = 0, date: Date) -> Double {
        normalized(trueDegrees - MagneticModel.declination(at: point, altitudeFt: altitudeFt, date: date))
    }

    /// The point a fraction of the way along the great circle from a to b.
    static func intermediate(from a: Coordinate, to b: Coordinate, fraction f: Double) -> Coordinate {
        if f <= 0 { return a }
        if f >= 1 { return b }
        let va = RouteVector(a)
        let vb = RouteVector(b)
        let angle = acos(min(1, max(-1, va.dot(vb))))
        let s = sin(angle)
        // The same point, or opposite points, which no single great circle joins.
        guard s > 1e-12 else { return a }
        let wa = sin((1 - f) * angle) / s
        let wb = sin(f * angle) / s
        let x = wa * va.x + wb * vb.x
        let y = wa * va.y + wb * vb.y
        let z = wa * va.z + wb * vb.z
        return Coordinate(latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
                          longitude: atan2(y, x) * 180 / .pi)
    }

    /// Distance right of the great circle from a to b (left is negative) and distance along it from a.
    /// Nil when a and b are the same point or opposite points.
    static func offsets(from a: Coordinate, to b: Coordinate, point p: Coordinate) -> (crossNM: Double, alongNM: Double)? {
        let va = RouteVector(a)
        let vp = RouteVector(p)
        let normal = va.cross(RouteVector(b))
        let length = normal.length
        guard length.isFinite, length > 1e-12 else { return nil }
        // The unit normal points to the left of the direction of flight.
        let left = RouteVector(normal.x / length, normal.y / length, normal.z / length)
        let cross = -asin(min(1, max(-1, vp.dot(left)))) * Geo.earthRadiusNM
        let along = atan2(vp.dot(left.cross(va)), vp.dot(va)) * Geo.earthRadiusNM
        guard cross.isFinite, along.isFinite else { return nil }
        return (cross, along)
    }
}

extension Route {
    /// Points along the great circle of every leg, for drawing. Longitudes keep counting past
    /// 180 degrees instead of wrapping, so a line across the date line does not jump.
    public func linePoints(maxSegmentNM: Double = 20) -> [Coordinate] {
        let step = maxSegmentNM.isFinite && maxSegmentNM > 0 ? max(1, maxSegmentNM) : 20
        var out: [Coordinate] = []
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let distance = Geo.distanceNM(from: a.coordinate, to: b.coordinate)
            let pieces = max(1, Int((distance / step).rounded(.up)))
            for k in 0..<pieces {
                out.append(RouteMath.intermediate(from: a.coordinate, to: b.coordinate,
                                                  fraction: Double(k) / Double(pieces)))
            }
        }
        out.append(waypoints[waypoints.count - 1].coordinate)
        for i in out.indices.dropFirst() {
            var longitude = out[i].longitude
            while longitude - out[i - 1].longitude > 180 { longitude -= 360 }
            while longitude - out[i - 1].longitude < -180 { longitude += 360 }
            out[i].longitude = longitude
        }
        return out
    }
}
