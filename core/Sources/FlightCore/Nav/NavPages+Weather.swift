/// The airport page's at-a-glance weather, from its newest METAR.
extension NavPages {
    public static let noCurrentMetar = "No current METAR"

    /// One runway end against the reported wind.
    public struct RunwayWindLine: Equatable, Sendable, Encodable {
        public var end: String
        /// The steady wind, such as 15 head · 4 cross from left.
        public var wind: String
        /// The same for the gust, when the report has one.
        public var gust: String?
        /// Best, beside the end the glance row names.
        public var tag: String?
    }

    public struct AirportWeather: Equatable, Sendable, Encodable {
        public var title = "Weather"
        /// VFR, MVFR, IFR, LIFR or Unknown as the value. Nil with no current METAR.
        public var category: Line?
        /// The category's color name: green, blue, red, magenta or gray.
        public var color: String?
        /// Wind, visibility, ceiling, temperature and dewpoint, altimeter and density altitude.
        public var lines: [Line]
        /// Open runway ends, most headwind first.
        public var runways: [RunwayWindLine]
        /// Observed 12 min ago, or No current METAR.
        public var note: String
        /// The METAR itself, only while it is current.
        public var raw: String?
    }

    /// The weather block and the best runway for the glance row.
    /// A METAR older than two hours, or another station's, counts as none.
    static func airportWeather(_ detail: AirportDetail, metar: Metar?, now: Date) -> (AirportWeather, RunwayChoice?) {
        guard let metar, metar.station == NavText.title(detail.airport), WeatherGeoJSON.isFresh(metar.age(at: now)) else {
            return (AirportWeather(lines: [], runways: [], note: noCurrentMetar), nil)
        }
        let open = NavText.runways(detail).filter { NavText.runwayNote($0, in: detail.remarks) != "CLOSED" }
        let best = metar.bestRunwayEnd(of: open)
        // End ids are magnetic names; the components use the stored true heading against the true METAR wind.
        let ends = (metar.windSpeedKt ?? 0) > 0 ? open.flatMap { runway in
            runway.ends.compactMap { end in metar.runwayWind(trueHeading: end.trueHeading).map { (runway, end, $0) } }
        } : []
        let sorted = ends.enumerated().sorted { a, b in
            let key = { (w: RunwayWind) in (-w.steady.headwindKt, abs(w.steady.crosswindFromRightKt)) }
            let ka = key(a.element.2), kb = key(b.element.2)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        let colors: [FlightCategory: String] = [.vfr: "green", .mvfr: "blue", .ifr: "red", .lifr: "magenta", .unknown: "gray"]
        let weather = AirportWeather(
            category: Line(title: "Flight category", value: metar.category == .unknown ? "Unknown" : metar.category.rawValue),
            color: colors[metar.category],
            lines: weatherLines(metar, elevationFt: detail.airport.elevationFt),
            runways: sorted.map { runway, end, wind in
                let isBest = best.map { $0.runway.id == runway.id && $0.end.id == end.id } ?? false
                return RunwayWindLine(end: end.id, wind: components(wind.steady),
                                      gust: wind.gust.map { "Gust " + components($0) }, tag: isBest ? "Best" : nil)
            },
            note: observed(metar, at: now), raw: metar.raw)
        return (weather, best)
    }

    /// Observed 12 min ago.
    public static func observed(_ metar: Metar, at now: Date) -> String {
        "Observed \(WeatherText.age(now.timeIntervalSince(metar.observed))) ago"
    }

    /// 15 head · 0 cross, or 3 tail · 10 cross from right, in whole knots.
    static func components(_ wind: WindComponents) -> String {
        let along = Int(wind.headwindKt.rounded()), across = Int(wind.crosswindFromRightKt.rounded())
        let side = across == 0 ? "" : across > 0 ? " from right" : " from left"
        return (along < 0 ? "\(-along) tail" : "\(along) head") + " · \(abs(across)) cross" + side
    }

    private static func weatherLines(_ metar: Metar, elevationFt: Double?) -> [Line] {
        // Int(exactly:) is nil out of range, where Int(_:) would trap; it also keeps -0 from showing.
        let whole = { (value: Double) in Int(exactly: value.rounded()).map(String.init) ?? NavText.dashes }
        let wind: String
        switch (metar.windSpeedKt, metar.windDirection) {
        case (nil, _): wind = NavText.dashes
        case (0?, _): wind = "Calm"
        case let (speed?, direction):
            let from = metar.windVariable ? "Variable" : direction.map { NavText.pad($0, 3) + "° true" } ?? NavText.dashes
            wind = "\(from) at \(speed) kt" + (metar.windGustKt.map { ", gusts \($0)" } ?? "")
        }
        let visibility = metar.visibilityMiles.map { WeatherText.general($0) + (metar.visibilityOrMore ? "+" : "") + " SM" }
        let ceiling = metar.ceilingFtAGL.map { NavText.grouped($0) + " ft" } ?? (metar.sky.isEmpty ? nil : "None")
        let temperatures = metar.temperatureC.map { t in
            "\(whole(t))°C / " + (metar.dewpointC.map { whole($0) + "°C" } ?? NavText.dashes)
        }
        let altimeter = metar.altimeterInHg.map { NavText.fixed($0, 2) + " inHg" }
        var density: String?
        if let elevation = elevationFt, let setting = metar.altimeterInHg, let t = metar.temperatureC,
           let pressure = Atmosphere.pressureAltitudeFt(fieldElevationFt: elevation, altimeterInHg: setting),
           let feet = Atmosphere.densityAltitudeFt(pressureAltitudeFt: pressure, temperatureC: t, dewpointC: metar.dewpointC) {
            density = NavText.grouped(Int(feet.rounded())) + " ft"
        }
        let rows: [(String, String?)] = [("Wind", wind), ("Visibility", visibility), ("Ceiling", ceiling),
                                         ("Temperature / dewpoint", temperatures), ("Altimeter", altimeter),
                                         ("Density altitude", density)]
        return rows.map { Line(title: $0.0, value: $0.1 ?? NavText.dashes) }
    }
}
