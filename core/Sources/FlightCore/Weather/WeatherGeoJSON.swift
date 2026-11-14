/// Turns decoded weather into the GeoJSON the map draws. Every builder takes the time and leaves out what is not in force.
public enum WeatherGeoJSON {
    /// A station or pilot report older than this is no longer drawn as it was reported.
    public static let reportLife: TimeInterval = 2 * 3600

    /// A JSON value, so features encode without JSONSerialization.
    enum Value: Encodable, ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral {
        case string(String), int(Int), double(Double), array([Value]), object([String: Value])

        init(stringLiteral value: String) { self = .string(value) }
        init(integerLiteral value: Int) { self = .int(value) }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    static func collection(_ features: [Value]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Built from strings and finite numbers only, so the fallback is never reached.
        return (try? encoder.encode(Value.object(["type": "FeatureCollection", "features": .array(features)])))
            ?? Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)
    }

    private static func position(_ at: Coordinate) -> Value { .array([.double(at.longitude), .double(at.latitude)]) }

    static func point(_ at: Coordinate, _ properties: [String: Value]) -> Value {
        .object(["type": "Feature", "properties": .object(properties),
                 "geometry": .object(["type": "Point", "coordinates": position(at)])])
    }

    private static func area(_ shape: WeatherShape, _ properties: [String: Value]) -> Value {
        let geometry: [String: Value]
        switch shape {
        case .polygon(let ring):
            geometry = ["type": "Polygon", "coordinates": .array([.array(ring.map(position))])]
        case .line(let points):
            geometry = ["type": "LineString", "coordinates": .array(points.map(position))]
        }
        return .object(["type": "Feature", "properties": .object(properties), "geometry": .object(geometry)])
    }

    // A report from the future, beyond what two clocks can differ by, is as untrustworthy as an old one.
    static func isFresh(_ age: TimeInterval) -> Bool {
        age <= reportLife && age >= -WeatherIndex.clockAllowance
    }

    /// The letter drawn inside a station dot, so color is never the only cue.
    public static func cue(_ category: FlightCategory) -> String {
        switch category {
        case .vfr: "V"
        case .mvfr: "M"
        case .ifr: "I"
        case .lifr: "L"
        case .unknown: "?"
        }
    }

    private static func visibility(_ metar: Metar) -> String {
        guard let miles = metar.visibilityMiles else { return "VIS --" }
        // Int(exactly:) is nil out of range, where Int(_:) would trap.
        let number = Int(exactly: miles).map(String.init) ?? String(miles)
        return "VIS \(number)\(metar.visibilityOrMore ? "+" : "")SM"
    }

    private static func wind(_ metar: Metar) -> String {
        guard let speed = metar.windSpeedKt else { return "WIND --" }
        if speed == 0 { return "CALM" }
        let from = metar.windVariable ? "VRB" : metar.windDirection.map { NavText.pad($0, 3) } ?? "---"
        return "\(from)\(NavText.pad(speed, 2))\(metar.windGustKt.map { "G\($0)" } ?? "")KT"
    }

    private static func whole(_ value: Double) -> String { Int(exactly: value.rounded()).map(String.init) ?? "--" }

    private static func temperatures(_ metar: Metar) -> (temp: String, spread: String) {
        guard let t = metar.temperatureC, let d = metar.dewpointC else { return ("--/--°C", "spread --") }
        return ("\(whole(t))/\(whole(d))°C", "spread \(whole(t - d))°")
    }

    /// The short text beside a station dot for the chosen reading. Empty for the category, which the dot shows.
    public static func stationValue(_ metar: Metar, show: StationShow) -> String {
        switch show {
        case .category: return ""
        case .wind:
            guard let speed = metar.windSpeedKt else { return "" }
            if speed == 0 { return "CALM" }
            return "\(metar.windVariable ? "VRB " : "")\(speed)\(metar.windGustKt.map { "G\($0)" } ?? "")"
        case .temperature: return metar.temperatureC.map { "\(whole($0))°" } ?? ""
        case .spread:
            guard let t = metar.temperatureC, let d = metar.dewpointC else { return "" }
            return "\(whole(t - d))°"
        case .visibility:
            guard let miles = metar.visibilityMiles else { return "" }
            return WeatherText.general(miles) + (metar.visibilityOrMore ? "+" : "") + " SM"
        case .ceiling: return metar.ceilingFtAGL.map { "\($0) ft" } ?? ""
        case .sky: return metar.skyCover?.text ?? ""
        }
    }

    public static func stations(_ metars: [Metar], now: Date, show: StationShow = .category) -> Data {
        collection(metars.map { metar in
            let age = metar.age(at: now)
            let fresh = isFresh(age)
            let ahead = age < -WeatherIndex.clockAllowance
            let category = fresh ? metar.category : .unknown
            let ceiling = metar.ceilingFtAGL.map { "CIG \($0)" } ?? "CIG --"
            let ageText = ahead ? "dated ahead of clock" : WeatherText.age(age)
            let (temp, spread) = temperatures(metar)
            let full = "\(metar.station) \(ageText)\n\(ceiling) \(visibility(metar))\n\(wind(metar)) \(temp) \(spread)"
            return point(metar.coordinate, [
                "station": .string(metar.station),
                "cat": .string(category.rawValue),
                "cue": .string(cue(category)),
                "ceiling": .string(ceiling),
                "visibility": .string(visibility(metar)),
                "wind": .string(wind(metar)),
                "temp": .string(temp),
                "spread": .string(spread),
                "obs": .string(WeatherText.zulu(metar.observed, withDay: true)),
                "age": .string(ageText),
                // Negative only for a report dated ahead of the clock.
                "age_min": .int(ahead ? Int(age / 60) : max(Int(age / 60), 0)),
                "label": .string(fresh ? full : "\(metar.station) \(ageText)\(ahead ? "" : " old")"),
                "raw": .string(metar.raw),
                // An old report shows no value, so it never reads as current.
                "value": .string(fresh ? stationValue(metar, show: show) : ""),
                "dir": .int(fresh && !metar.windVariable && (metar.windSpeedKt ?? 0) > 0 ? metar.windDirection ?? -1 : -1),
            ])
        })
    }

    public static func sigmets(_ sigmets: [Sigmet], now: Date) -> Data {
        collection(sigmets.valid(at: now).map { sigmet in
            let title = "\(sigmet.hazard) \(sigmet.kind ?? "SIGMET")"
            return area(sigmet.shape, [
                "title": .string(title),
                "label": "\(title)\nto \(WeatherText.zulu(sigmet.validTo))",
                "hazard": .string(sigmet.hazard),
                "severity": .string(sigmet.severity ?? ""),
                "from": .string(WeatherText.zulu(sigmet.validFrom, withDay: true)),
                "to": .string(WeatherText.zulu(sigmet.validTo, withDay: true)),
                "base": .string(sigmet.baseFtMSL.map { "\($0) ft MSL" } ?? ""),
                "top": .string(sigmet.topFtMSL.map { "\($0) ft MSL" } ?? ""),
                "raw": .string(sigmet.raw),
            ])
        })
    }

    public static func cwas(_ cwas: [Cwa], now: Date) -> Data {
        collection(cwas.valid(at: now).map { cwa in
            let title = "\(cwa.center) CWA \(cwa.series)"
            return area(cwa.shape, [
                "title": .string(title),
                "label": "\(title) \(cwa.hazard)\nto \(WeatherText.zulu(cwa.validTo))",
                "hazard": .string(cwa.hazard),
                "qualifier": .string(cwa.qualifier),
                "from": .string(WeatherText.zulu(cwa.validFrom, withDay: true)),
                "to": .string(WeatherText.zulu(cwa.validTo, withDay: true)),
                "base": .string(cwa.baseFtMSL.map { "\($0) ft MSL" } ?? ""),
                "top": .string(cwa.topFtMSL.map { "\($0) ft MSL" } ?? ""),
                "raw": .string(cwa.raw),
            ])
        })
    }

    public static func gairmets(_ gairmets: [GAirmet], now: Date) -> Data {
        collection(gairmets.valid(at: now).map { item in
            area(item.shape, [
                "title": "G-AIRMET \(item.hazard)",
                // A snapshot shown ahead of its time says when it starts.
                "label": .string(([item.hazard, item.severity].compactMap { $0 }
                    + (item.valid > now ? ["from \(WeatherText.zulu(item.valid))"] : [])).joined(separator: " ")),
                "hazard": .string(item.hazard),
                "product": .string(item.product ?? ""),
                "severity": .string(item.severity ?? ""),
                "issued": .string(WeatherText.zulu(item.issued, withDay: true)),
                "valid": .string(WeatherText.zulu(item.valid, withDay: true)),
                "due_to": .string(item.dueTo ?? ""),
                "base": .string(item.base ?? ""),
                "top": .string(item.top ?? ""),
                "level": .string(item.level ?? ""),
                "fzl_base": .string(item.freezingBase ?? ""),
                "fzl_top": .string(item.freezingTop ?? ""),
            ])
        })
    }

    /// Notices in force or still to come that have a drawn area. An expired one is never drawn.
    public static func tfrs(_ tfrs: [Tfr], now: Date) -> Data {
        collection(tfrs.compactMap { tfr in
            let status = tfr.status(at: now)
            guard status != .expired, let shape = tfr.shape else { return nil }
            let levels = "\(tfr.lower?.text ?? "?") to \(tfr.upper?.text ?? "?")"
            let from = tfr.effective.map(WeatherText.dated) ?? ""
            // No end time means it has not ended.
            let until = tfr.expires.map { "until " + WeatherText.dated($0) } ?? "until canceled"
            return area(shape, [
                "title": "TFR \(tfr.notam)",
                "label": "TFR \(tfr.notam)\n\(levels)\n\(status == .upcoming ? "from \(from)" : until)",
                "notam": .string(tfr.notam),
                "status": status == .upcoming ? "upcoming" : "active",
                "kind": .string(tfr.kind ?? ""),
                "name": .string(tfr.name ?? ""),
                "rule": .string(tfr.rule ?? ""),
                "facility": .string(tfr.facility ?? ""),
                "detail": .string(tfr.title ?? ""),
                "levels": .string(levels),
                "from": .string(from),
                "until": .string(until),
            ])
        })
    }

    /// Notices in force or still to come with no drawn area. They cannot go on the map, so they must be listed.
    public static func tfrsWithoutArea(_ tfrs: [Tfr], now: Date) -> [Tfr] {
        tfrs.filter { $0.shape == nil && $0.status(at: now) != .expired }
    }

    public static func pireps(_ pireps: [Pirep], now: Date) -> Data {
        collection(pireps.compactMap { pirep in
            let age = pirep.age(at: now)
            guard isFresh(age) else { return nil }
            // UA and UUA are the report's own type codes, so an urgent one differs in letters as well as color.
            let type = pirep.urgent ? "UUA" : "UA"
            return point(pirep.coordinate, [
                "type": .string(type),
                "label": "\(type) \(WeatherText.age(age))",
                "altitude": .string(pirep.altitudeFtMSL.map { "\($0) ft" } ?? "altitude not given"),
                "aircraft": .string(pirep.aircraft ?? ""),
                "turbulence": .string(pirep.turbulence ?? ""),
                "icing": .string(pirep.icing ?? ""),
                "obs": .string(WeatherText.zulu(pirep.observed, withDay: true)),
                "age": .string(WeatherText.age(age)),
                "raw": .string(pirep.raw),
            ])
        })
    }

    /// A barb per FB station at the level, from the forecast in use now. Stations with no wind there are left out.
    public static func winds(_ winds: WindsAloft?, level: Int, now: Date) -> Data {
        collection((WindsMap.forecast(winds, at: now)?.stations ?? []).compactMap { station in
            guard let at = station.levels.first(where: { $0.ft == level }) else { return nil }
            let barb = WindBarb(directionDeg: at.dir, speedKt: at.kt)
            return point(Coordinate(latitude: station.lat, longitude: station.lon), [
                "station": .string(station.id),
                "barb": .string(barb.image),
                "rotate": .int(barb.rotation),
                "label": .string(WindsMap.text(at)),
            ])
        })
    }

    /// Flashes of the last half hour with their age in whole minutes, oldest first so the newest draw on top.
    public static func lightning(_ groups: [LightningGroup], now: Date) -> Data {
        collection(groups.sorted { $0.time < $1.time }.flatMap { group -> [Value] in
            let age = group.age(at: now)
            guard age <= LightningStyle.life, age >= -WeatherIndex.clockAllowance else { return [] }
            return group.flashes.map { point($0, ["age_min": .int(max(Int(age / 60), 0))]) }
        })
    }

    /// The overlay's GeoJSON. Radar and satellite are pictures, not GeoJSON, so they come back empty.
    public static func overlay(_ overlay: WeatherOverlay, _ data: WeatherData, show: StationShow,
                               windsLevel: Int = WindsMap.defaultLevel, now: Date) -> Data {
        switch overlay {
        case .stations: stations(data.metars, now: now, show: show)
        case .sigmets: sigmets(data.sigmets, now: now)
        case .gairmets: gairmets(data.gairmets, now: now)
        case .cwas: cwas(data.cwas, now: now)
        case .tfrs: tfrs(data.tfrs, now: now)
        case .pireps: pireps(data.pireps, now: now)
        case .winds: winds(data.winds, level: windsLevel, now: now)
        case .lightning: lightning(data.lightning, now: now)
        case .radar, .satellite: Data()
        }
    }
}
