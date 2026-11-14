public struct Pirep: Equatable, Sendable, WeatherTimed {
    public var observed: Date
    public var coordinate: Coordinate
    /// Nil when the report gave no usable altitude, such as "during descent".
    public var altitudeFtMSL: Int?
    public var urgent: Bool
    public var aircraft: String?
    public var turbulence: String?
    public var icing: String?
    public var raw: String

    public var time: Date { observed }

    public static func decode(_ data: Data) throws -> [Pirep] {
        struct Wire: Decodable {
            var t: Date, lat: Double, lon: Double, alt: Int?, urgent: Bool
            var acft: String?, turb: String?, ice: String?, raw: String
        }
        return try WeatherJSON.decode([Wire].self, from: data, what: "pireps").map {
            Pirep(observed: $0.t, coordinate: Coordinate(latitude: $0.lat, longitude: $0.lon),
                  altitudeFtMSL: $0.alt, urgent: $0.urgent, aircraft: $0.acft,
                  turbulence: $0.turb, icing: $0.ice, raw: $0.raw)
        }
    }
}
