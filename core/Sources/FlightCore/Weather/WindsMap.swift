/// The Winds Aloft map layer: which level and forecast to draw, and a barb per FB station.
public enum WindsMap {
    public static let switchID = "weather-winds"
    public static let levelKey = "weather-winds-level"
    public static let levelTitle = "Altitude"
    public static let levels = [3000, 6000, 9000, 12000, 18000, 24000, 30000]
    public static let defaultLevel = 6000

    public static func title(_ level: Int) -> String { "\(level) ft" }

    /// The chosen level, else the route's cruise rounded to the nearest level, else 6000.
    public static func level(chosen: Int?, cruiseFt: Int?) -> Int {
        if let chosen, levels.contains(chosen) { return chosen }
        guard let cruiseFt else { return defaultLevel }
        return levels.min { abs($0 - cruiseFt) < abs($1 - cruiseFt) } ?? defaultLevel
    }

    /// The forecast whose use window holds now. Nil between windows, so nothing out of date is drawn.
    public static func forecast(_ winds: WindsAloft?, at now: Date) -> WindsAloft.Forecast? {
        winds?.forecasts.first { $0.from <= now && now < $0.to }
    }

    private static func hour(_ date: Date) -> String { NavText.pad(UTCTime(date).hour, 2) + "Z" }

    /// "Winds 06Z-12Z, 9000 ft" for the clock, or why nothing is drawn.
    public static func label(_ winds: WindsAloft?, level: Int, at now: Date) -> String? {
        guard let winds else { return nil }
        guard let f = forecast(winds, at: now) else { return "Winds aloft: no forecast for now" }
        return "Winds \(hour(f.from))-\(hour(f.to)), \(title(level))"
    }

    /// The speed and temperature under a barb.
    static func text(_ level: WindsAloft.Level) -> String {
        let wind: String
        if level.dir == nil { wind = "Light and variable" }
        else if WindBarb(directionDeg: level.dir, speedKt: level.kt).bucket == 0 { wind = "Calm" }
        else { wind = "\(level.kt) kt" }
        return wind + (level.temp.map { " \($0)°C" } ?? "")
    }
}

/// A standard wind barb: staff toward where the wind comes from, pennant 50 kt, full barb 10, half barb 5.
public struct WindBarb: Equatable, Sendable {
    public static let maxKt = 195
    /// Knots to the nearest 5, 0 for calm or light and variable.
    public var bucket: Int
    /// Degrees true the staff points, clockwise from north.
    public var rotation: Int

    public init(directionDeg: Int?, speedKt: Int) {
        let rounded = min((max(speedKt, 0) + 2) / 5 * 5, Self.maxKt)
        bucket = directionDeg == nil ? 0 : rounded
        rotation = bucket == 0 ? 0 : (directionDeg ?? 0) % 360
    }

    public static func image(_ bucket: Int) -> String { "wind-barb-\(bucket)" }
    public var image: String { Self.image(bucket) }

    public static func parts(_ bucket: Int) -> (pennants: Int, full: Int, half: Int) {
        (bucket / 50, bucket % 50 / 10, bucket % 10 / 5)
    }

    /// What a platform draws for one bucket, in a square of `size` points with the station at its center
    /// and the staff pointing up. Drawn in one color as an SDF icon, so the style colors and turns it.
    public struct Drawing: Equatable, Sendable, Encodable {
        public var name: String
        public var size: Double
        public var lineWidth: Double
        /// x1, y1, x2, y2, y down.
        public var lines: [[Double]]
        /// Filled: x1, y1, x2, y2, x3, y3.
        public var triangles: [[Double]]
        /// The calm circle's radius, around the center.
        public var ring: Double?
    }

    public static let buckets = Array(stride(from: 0, through: maxKt, by: 5))
    public static var drawings: [Drawing] { buckets.map(drawing) }

    public static func drawing(_ bucket: Int) -> Drawing {
        let size = 84.0, c = size / 2, staff = 30.0, feather = 13.0, lean = 5.0, pennant = 6.0, gap = 4.0
        var d = Drawing(name: image(bucket), size: size, lineWidth: 3, lines: [], triangles: [], ring: nil)
        guard bucket > 0 else {
            d.ring = 6
            return d
        }
        let (pennants, full, half) = parts(bucket)
        // Distance from the station along the staff, at the tip first.
        let needed = Double(pennants) * pennant + Double(full + half) * gap + (pennants + full == 0 ? gap : 0)
        var s = max(staff, needed)
        d.lines.append([c, c, c, c - s])
        for _ in 0..<pennants {
            d.triangles.append([c, c - s, c, c - s + pennant, c + feather, c - s])
            s -= pennant
        }
        if pennants > 0 { s -= gap / 2 }
        // A lone half barb sits one step in from the tip.
        if pennants + full == 0 { s -= gap }
        for k in 0..<(full + half) {
            let length = k < full ? feather : feather / 2
            d.lines.append([c, c - s, c + length, c - s - lean * length / feather])
            s -= gap
        }
        return d
    }
}
