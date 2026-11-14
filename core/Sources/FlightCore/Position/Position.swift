public struct Position: Equatable, Sendable {
    public static let staleAfter: TimeInterval = 5
    /// A fix with a wider horizontal error than this, in meters, is shown as approximate.
    public static let approximateBeyondMeters = 500.0

    public var coordinate: Coordinate
    public var trackTrue: Double?
    public var groundspeedKt: Double?
    public var altitudeFtMSL: Double?
    public var timestamp: Date

    /// Builds a position from raw GPS values. Negative course or speed means "unknown".
    /// `altitudeMeters` is above MSL. A height above the WGS-84 ellipsoid goes in `ellipsoidAltitudeMeters`
    /// instead and is converted through the geoid, or left unknown where the geoid table has no value.
    public init?(latitude: Double, longitude: Double, courseDegrees: Double,
                 speedMetersPerSecond: Double, altitudeMeters: Double?, ellipsoidAltitudeMeters: Double? = nil,
                 timestamp: Date) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        coordinate = Coordinate(latitude: latitude, longitude: longitude)
        trackTrue = courseDegrees >= 0 && courseDegrees.isFinite ? courseDegrees : nil
        groundspeedKt = speedMetersPerSecond >= 0 && speedMetersPerSecond.isFinite
            ? speedMetersPerSecond * 1.943844 : nil
        let msl = altitudeMeters ?? ellipsoidAltitudeMeters.flatMap { h in
            Geoid.height(latitude: latitude, longitude: longitude).map { h - $0 }
        }
        altitudeFtMSL = msl.flatMap { $0.isFinite ? $0 * 3.28084 : nil }
        self.timestamp = timestamp
    }

    public func isStale(at now: Date) -> Bool {
        // A fix dated well after "now" means the clock moved; treat it as stale too.
        abs(now.timeIntervalSince(timestamp)) > Self.staleAfter
    }
}
