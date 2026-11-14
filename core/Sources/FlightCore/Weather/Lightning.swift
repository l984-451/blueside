/// GOES lightning flashes, grouped by the 20 s file they came in.
public struct LightningGroup: Equatable, Sendable, WeatherTimed {
    public var time: Date
    public var flashes: [Coordinate]

    public static func decode(_ data: Data) throws -> [LightningGroup] {
        struct Wire: Decodable { var t: Date; var p: [[Double]] }
        return try WeatherJSON.decode([Wire].self, from: data, what: "lightning").map {
            LightningGroup(time: $0.t, flashes: $0.p.compactMap { $0.count == 2 ? Coordinate(latitude: $0[0], longitude: $0[1]) : nil })
        }
    }
}

/// How flashes are drawn: colored and sized by age, newest brightest.
public enum LightningStyle {
    /// Flashes older than this are not drawn.
    public static let life: TimeInterval = 30 * 60
    /// Age floors in minutes and their colors, newest first.
    public static let ages: [(minutes: Int, color: String)] = [(0, "#fff176"), (5, "#ffb300"), (15, "#e65100")]
    public static let legend = "Lightning: yellow under 5 min, orange under 15, dark orange under 30"
}

/// The satellite picture, colored by the pipeline.
public enum SatelliteStyle {
    public static let opacity = 0.85
    public static let legend = "Satellite: infrared cloud tops; blue, green, yellow, red are colder and higher"
}
