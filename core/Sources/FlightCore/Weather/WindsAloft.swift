/// Winds and temperatures aloft at the forecast stations, published by the weather job from the GFS:
/// one forecast per model run and lead time.
public struct WindsAloft: Equatable, Sendable {
    public static let supportedVersion = 1
    /// Leg samples are this far apart.
    public static let sampleNM = 25.0
    /// Stations farther than this from a sample are not used.
    public static let reachNM = 300.0
    public static let stationsPerSample = 4

    public struct Level: Equatable, Sendable, Decodable {
        public var ft: Int
        /// Degrees true; nil is light and variable.
        public var dir: Int?
        public var kt: Int
        /// °C; nil at 3000 ft, which carries none.
        public var temp: Int?
    }

    public struct Station: Equatable, Sendable, Decodable {
        public var id: String
        public var lat: Double
        public var lon: Double
        /// Lowest first. Levels near the ground that the forecast leaves out are absent.
        public var levels: [Level]
    }

    public struct Forecast: Equatable, Sendable, Decodable {
        public var based: Date
        public var valid: Date
        /// The use window, from..<to.
        public var from: Date
        public var to: Date
        public var stations: [Station]
    }

    public var forecasts: [Forecast]

    public static func decode(_ data: Data) throws -> WindsAloft {
        struct VersionOnly: Decodable { var version: Int }
        struct Wire: Decodable { var forecasts: [Forecast] }
        let version = try WeatherJSON.decode(VersionOnly.self, from: data, what: "winds").version
        guard version == supportedVersion else { throw WeatherError.unsupportedVersion(version) }
        var forecasts = try WeatherJSON.decode(Wire.self, from: data, what: "winds").forecasts
        guard forecasts.contains(where: { !$0.stations.isEmpty }) else { throw WeatherError.empty(.winds) }
        for f in forecasts.indices {
            for s in forecasts[f].stations.indices { forecasts[f].stations[s].levels.sort { $0.ft < $1.ft } }
        }
        return WindsAloft(forecasts: forecasts)
    }

    /// Without the forecasts whose use window has ended by now, so stale winds never drive a plan; nil when none is left.
    func unexpired(at now: Date) -> WindsAloft? {
        let kept = forecasts.filter { $0.to > now }
        return kept.isEmpty ? nil : WindsAloft(forecasts: kept)
    }

    /// The forecast whose use window holds the time, else the one whose window is nearest.
    public func forecast(at time: Date) -> (forecast: Forecast, inWindow: Bool)? {
        if let held = forecasts.first(where: { $0.from <= time && time < $0.to }) { return (held, true) }
        func gap(_ f: Forecast) -> TimeInterval { time < f.from ? f.from.timeIntervalSince(time) : time.timeIntervalSince(f.to) }
        return forecasts.min { gap($0) < gap($1) }.map { ($0, false) }
    }

    /// The wind and temperature for a leg flown at one altitude, centered on a time. Nil when no forecast
    /// is held or no sample has a station in reach, so the nav log flies it calm.
    public func leg(from a: Coordinate, to b: Coordinate, altitudeFt: Double, at time: Date) -> LegWindAloft? {
        guard let (forecast, inWindow) = forecast(at: time) else { return nil }
        let pieces = max(1, Int((Geo.distanceNM(from: a, to: b) / Self.sampleNM).rounded(.up)))
        var u = 0.0, v = 0.0, temps: [Double] = [], reached = 0
        for k in 0...pieces {
            let point = RouteMath.intermediate(from: a, to: b, fraction: Double(k) / Double(pieces))
            // A sample with no station in reach counts as calm.
            guard let s = Self.sample(forecast.stations, at: point, altitudeFt: altitudeFt) else { continue }
            reached += 1
            u += s.u
            v += s.v
            if let t = s.temp { temps.append(t) }
        }
        guard reached > 0 else { return nil }
        let count = Double(pieces + 1)
        return LegWindAloft(wind: Self.wind(u: u / count, v: v / count),
                            temperatureC: temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count),
                            calmSamples: pieces + 1 - reached, inUseWindow: inWindow, forecast: forecast.valid)
    }

    /// Wind as the vector it blows from, so 350° and 010° average to 360°, not 180°.
    static func vector(direction: Double, speed: Double) -> (u: Double, v: Double) {
        (speed * sin(direction * .pi / 180), speed * cos(direction * .pi / 180))
    }

    static func wind(u: Double, v: Double) -> LegWind {
        let speed = (u * u + v * v).squareRoot()
        return LegWind(directionTrue: speed < 1e-9 ? 0 : RouteMath.normalized(atan2(u, v) * 180 / .pi), speedKt: speed)
    }

    /// Inverse distance weighting, power 2, over the nearest stations in reach.
    static func sample(_ stations: [Station], at point: Coordinate, altitudeFt: Double)
        -> (u: Double, v: Double, temp: Double?)? {
        // ponytail: scans every station per sample; a grid index if forecasts grow past a few hundred stations.
        let near = stations.lazy.map { ($0, Geo.distanceNM(from: point, to: Coordinate(latitude: $0.lat, longitude: $0.lon))) }
            .filter { $0.1 <= reachNM }.sorted { $0.1 < $1.1 }.prefix(stationsPerSample)
        var u = 0.0, v = 0.0, weights = 0.0, temp = 0.0, tempWeights = 0.0
        for (station, distance) in near {
            guard let at = station.at(altitudeFt: altitudeFt) else { continue }
            // A station on the sample decides it alone.
            if distance < 0.01 { return (at.u, at.v, at.temp) }
            let w = 1 / (distance * distance)
            u += w * at.u
            v += w * at.v
            weights += w
            if let t = at.temp {
                temp += w * t
                tempWeights += w
            }
        }
        guard weights > 0 else { return nil }
        return (u / weights, v / weights, tempWeights > 0 ? temp / tempWeights : nil)
    }
}

extension WindsAloft.Station {
    /// Linear between the two levels around the altitude; below the lowest or above the top, that level.
    func at(altitudeFt: Double) -> (u: Double, v: Double, temp: Double?)? {
        func between<T>(_ items: [T], _ ft: (T) -> Int, _ value: (T) -> [Double]) -> [Double]? {
            guard let first = items.first, let last = items.last else { return nil }
            if altitudeFt <= Double(ft(first)) { return value(first) }
            if altitudeFt >= Double(ft(last)) { return value(last) }
            let upper = items.firstIndex { Double(ft($0)) >= altitudeFt }!
            let lo = items[upper - 1], hi = items[upper]
            let f = (altitudeFt - Double(ft(lo))) / Double(ft(hi) - ft(lo))
            return zip(value(lo), value(hi)).map { $0 + f * ($1 - $0) }
        }
        guard let wind = between(levels, \.ft, { level in
            let w = WindsAloft.vector(direction: Double(level.dir ?? 0), speed: level.dir == nil ? 0 : Double(level.kt))
            return [w.u, w.v]
        }) else { return nil }
        let temp = between(levels.filter { $0.temp != nil }, \.ft) { [Double($0.temp!)] }?.first
        return (wind[0], wind[1], temp)
    }
}

/// One leg's wind at cruise, ready for the nav log, with what the leg row says about it.
public struct LegWindAloft: Equatable, Sendable {
    public var wind: LegWind
    public var temperatureC: Double?
    /// Samples with no station in reach, flown calm.
    public var calmSamples: Int
    /// False when the leg's time falls outside every forecast's use window and the nearest was used.
    public var inUseWindow: Bool
    /// The forecast's valid time.
    public var forecast: Date
}
