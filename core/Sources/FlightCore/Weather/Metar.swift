public enum FlightCategory: String, Sendable, CaseIterable, Codable {
    case vfr = "VFR", mvfr = "MVFR", ifr = "IFR", lifr = "LIFR", unknown = "UNKNOWN"
}

extension SkyLayer {
    /// Broken, overcast or sky obscured: the layers that make a ceiling.
    public var isCeiling: Bool { ["BKN", "OVC", "OVX"].contains(cover) }

    /// "BKN 035": cover and base in hundreds of feet. An obscured sky reads VV, as in the report.
    public var text: String {
        let cover = self.cover == "OVX" ? "VV" : self.cover
        return baseFtAGL.map { "\(cover) \(NavText.pad($0 / 100, 3))" } ?? cover
    }
}

extension Metar {
    /// The layer the sky reads as: the ceiling, or with none the highest layer reported.
    public var skyCover: SkyLayer? {
        sky.first { $0.isCeiling && $0.baseFtAGL != nil } ?? sky.last
    }
}

public struct Metar: Equatable, Sendable, Codable, WeatherTimed {
    public var station: String
    public var coordinate: Coordinate
    public var category: FlightCategory
    public var ceilingFtAGL: Int?
    /// Lowest first, as reported.
    public var sky: [SkyLayer] = []
    public var visibilityMiles: Double?
    /// True when the report says "this far or more", such as 10+.
    public var visibilityOrMore: Bool
    public var windDirection: Int?
    public var windVariable: Bool
    public var windSpeedKt: Int?
    public var windGustKt: Int?
    public var temperatureC: Double?
    public var dewpointC: Double?
    public var altimeterInHg: Double?
    public var observed: Date
    public var raw: String

    public var time: Date { observed }

    public static func decode(_ data: Data) throws -> [Metar] {
        struct Wire: Decodable {
            var id: String, lat: Double, lon: Double, cat: String?
            struct Layer: Decodable { var cover: String, base: Int? }
            var ceil: Int?, sky: [Layer]?, vis: Double?, visp: Bool?
            var wdir: Int?, vrb: Bool?, wspd: Int?, gust: Int?
            var temp: Double?, dewp: Double?, altim: Double?
            var t: Date, raw: String
        }
        let rows = try WeatherJSON.decode([Wire].self, from: data, what: "metars")
        guard !rows.isEmpty else { throw WeatherError.empty(.metars) }
        return rows.map { row in
            Metar(station: row.id, coordinate: Coordinate(latitude: row.lat, longitude: row.lon),
                  // A missing or unfamiliar category is unknown. It is never assumed to be VFR.
                  category: FlightCategory(rawValue: row.cat ?? "") ?? .unknown,
                  ceilingFtAGL: row.ceil, sky: (row.sky ?? []).map { SkyLayer(cover: $0.cover, baseFtAGL: $0.base) },
                  visibilityMiles: row.vis, visibilityOrMore: row.visp ?? false,
                  windDirection: row.wdir, windVariable: row.vrb ?? false,
                  windSpeedKt: row.wspd, windGustKt: row.gust,
                  temperatureC: row.temp, dewpointC: row.dewp, altimeterInHg: row.altim,
                  observed: row.t, raw: row.raw)
        }
    }
}
