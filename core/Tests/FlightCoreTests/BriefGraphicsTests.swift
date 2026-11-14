import Foundation
import Testing
@testable import FlightCore

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func point(_ ident: String, _ lat: Double, _ lon: Double, _ kind: WaypointKind = .airport) -> RouteWaypoint {
    RouteWaypoint(kind: kind, ident: ident, name: ident, coordinate: Coordinate(latitude: lat, longitude: lon))
}

/// KAUS KDAL, about 165 nm north-northeast; its middle is near 31.52 N 97.26 W.
private let kaus = point("KAUS", 30.1945, -97.6699), kdal = point("KDAL", 32.8471, -96.8518)
private let direct = Route(waypoints: [kaus, kdal], navCycle: "2026-10-01")!
private let departure = at("2026-10-15T14:00:00Z")
private let inputs = FlightPlanInputs(cruiseAltitudeFt: 5500, departure: departure)

private func box(_ lat: Double, _ lon: Double, half: Double) -> WeatherShape {
    .polygon([(lat - half, lon - half), (lat - half, lon + half), (lat + half, lon + half), (lat + half, lon - half),
              (lat - half, lon - half)].map { Coordinate(latitude: $0.0, longitude: $0.1) })
}

private func sigmet(_ hazard: String, _ shape: WeatherShape) -> Sigmet {
    Sigmet(hazard: hazard, severity: nil, kind: "SIGMET", validFrom: departure - 3600, validTo: departure + 7200,
           baseFtMSL: 0, topFtMSL: 12000, raw: hazard, shape: shape)
}

private func metar(_ station: String, _ c: RouteWaypoint, _ category: FlightCategory, sky: [SkyLayer]) -> Metar {
    Metar(station: station, coordinate: c.coordinate, category: category, ceilingFtAGL: sky.first?.baseFtAGL, sky: sky,
          visibilityMiles: 10, visibilityOrMore: true, windDirection: 180, windVariable: false, windSpeedKt: 10,
          windGustKt: nil, temperatureC: 30, dewpointC: 20, altimeterInHg: 29.92, observed: departure - 2400, raw: station)
}

private func brief(_ weather: WeatherData, route: Route = direct, database: NavDatabase? = nil) -> FlightBrief {
    let plan = FlightPlan.make(route: route, inputs: inputs, trueAirspeedKt: 120, burnGPH: 9, winds: nil, tafs: [])
    return FlightBrief.make(route: route, inputs: inputs, plan: plan, aircraft: nil, balance: nil, weather: weather,
                            now: departure - 1800, database: database)
}

@Suite struct BriefGraphicsTests {
    @Test func hazardsPutIFRAndAreasOnTheRouteFirstWithWhereTheyAre() {
        var w = WeatherData()
        w.metars = [metar("KDAL", kdal, .ifr, sky: [SkyLayer(cover: "OVC", baseFtAGL: 600)])]
        w.sigmets = [sigmet("BESIDE", box(31.52, -96.71, half: 0.1)), sigmet("CROSSING", box(31.52, -97.26, half: 0.3))]
        w.gairmets = [GAirmet(product: "SIERRA", tag: "1S", hazard: "IFR", severity: nil, issued: departure - 3600,
                              valid: departure - 3600, expires: departure + 7200, dueTo: nil, base: nil, top: nil, level: nil,
                              freezingBase: nil, freezingTop: nil, shape: box(31.52, -97.26, half: 0.5))]
        let g = brief(w).graphics
        #expect(g.counts == "2 SIGMETs · 1 G-AIRMET")
        #expect(g.hazards.map(\.text) == ["IFR at KDAL now", "CROSSING SIGMET on the route", "BESIDE SIGMET 21 nm east of the route",
                                          "G-AIRMET IFR on the route"])
        #expect(g.hazards.map(\.severe) == [true, true, true, false])
    }

    @Test func aTwoLegRouteNamesTheLegAndNothingHeldSaysSo() {
        let viaWaco = Route(waypoints: [kaus, point("ACT", 31.6625, -97.2697, .navaid), kdal], navCycle: "2026-10-01")!
        var w = WeatherData()
        // West of the second leg, inside the corridor.
        w.sigmets = [sigmet("WEST", box(32.0, -97.55, half: 0.05))]
        let g = brief(w, route: viaWaco).graphics
        #expect(g.hazards.map(\.text) == ["WEST SIGMET 16 nm west of leg 2"])
        #expect(brief(WeatherData()).graphics.counts == BriefGraphics.noHazards)
        #expect(brief(WeatherData()).graphics.hazards.isEmpty)
    }

    @Test func profileHasGroundCloudsFreezingLevelAndBarbsOnFixedGeometry() throws {
        let db = try NavDatabase(path: try makeNavDatabase())
        var w = WeatherData()
        w.metars = [metar("KAUS", kaus, .mvfr, sky: [SkyLayer(cover: "FEW", baseFtAGL: 900), SkyLayer(cover: "BKN", baseFtAGL: 1500)])]
        // One station over the middle: 4°C at 6000 ft, -2°C at 9000 ft, so 0°C at 8000 ft.
        let station = WindsAloft.Station(id: "ACT", lat: 31.6, lon: -97.2, levels: [
            .init(ft: 3000, dir: 180, kt: 10, temp: nil), .init(ft: 6000, dir: 270, kt: 20, temp: 4),
            .init(ft: 9000, dir: 270, kt: 30, temp: -2)])
        w.winds = WindsAloft(forecasts: [.init(based: departure - 7200, valid: departure, from: departure - 7200,
                                               to: departure + 7200, stations: [station])])
        let p = brief(w, database: db).graphics.profile
        #expect(abs(p.lengthNM - 164.4) < 1)
        #expect(p.waypoints.map(\.text) == ["KAUS", "KDAL"] && p.waypoints[0].value == 0 && p.waypoints[1].value == p.lengthNM)
        #expect(p.topFt == 8000 && p.cruiseFt == 5500)
        #expect(p.grid.map(\.text) == ["2,000", "4,000", "6,000"])
        // Austin's airports near the start; Fredericksburg is too far off the line.
        #expect(p.ground.first?.fromNM == 0 && p.ground.first?.toNM == 5)
        #expect(p.ground.contains { $0.ft == 620 } && !p.ground.contains { $0.ft == 1695 })
        // The ceiling, not the lower few layer, over field elevation.
        #expect(p.clouds == [BriefProfile.Cloud(nm: 0, ft: 2042, station: "KAUS", text: "BKN 015", ceiling: true, color: "blue")])
        #expect(p.freezing.count == 1 && p.freezing[0].allSatisfy { abs($0[1] - 8000) < 1 })
        #expect(p.winds.count == 6 && p.winds.allSatisfy { $0.ft == 5500 })
        // A westerly wind: the staff points from the anchor toward the west.
        let staff = try #require(p.winds.first?.lines.first)
        #expect(staff[0] == 0 && staff[1] == 0 && staff[2] < -10 && abs(staff[3]) < 4)
    }

    @Test func airportPanelsCarryTheWeatherBlockAndTheTafBar() throws {
        let db = try NavDatabase(path: try makeNavDatabase())
        var w = WeatherData()
        w.metars = [metar("KAUS", kaus, .vfr, sky: [])]
        let groups = [TafGroup(kind: .initial, from: departure - 7200, to: departure + 3600, windVariable: false,
                               visibilityMiles: 6, visibilityOrMore: true, sky: [SkyLayer(cover: "SCT", baseFtAGL: 5000)]),
                      TafGroup(kind: .from, from: departure + 3600, to: departure + 21600, windVariable: false,
                               visibilityMiles: 2, visibilityOrMore: false, sky: [SkyLayer(cover: "OVC", baseFtAGL: 400)])]
        w.tafs = [Taf(station: "KAUS", issued: departure - 7200, validFrom: departure - 7200, validTo: departure + 21600,
                      raw: "TAF KAUS", groups: groups)]
        let panels = brief(w, database: db).graphics.airports
        #expect(panels.map(\.title) == ["Departure KAUS", "Destination KDAL"])
        let aus = panels[0]
        #expect(aus.weather.color == "green")
        #expect(aus.weather.lines.contains { $0.title == "Density altitude" && $0.value != NavText.dashes })
        #expect(aus.spans == [.init(from: 0, to: 0.75, color: "green"), .init(from: 0.75, to: 1, color: "magenta")])
        #expect(aus.times == ["1200Z", "Departure 1400Z", "1600Z"])
        #expect(panels[1].tafNote == "No TAF held")
    }

    @Test func mapStylesCarryTheRouteStationsAndAreasOverAPlainBase() throws {
        var w = WeatherData()
        w.metars = [metar("KDAL", kdal, .ifr, sky: [])]
        w.sigmets = [sigmet("CROSSING", box(31.52, -97.26, half: 0.3))]
        let map = brief(w).graphics.map
        #expect(map.pictures.map(\.id) == ["route"])
        let style = try JSONDecoder().decode(JSON.self, from: Data(map.pictures[0].style.utf8))
        guard case .array(let layers)? = style["layers"], case .array(let features)? = style["sources"]?["brief"]?["data"]?["features"]
        else { Issue.record("no layers"); return }
        let ids = layers.compactMap { $0["id"]?.string }
        #expect(ids.contains("brief-route"))
        let kinds = features.compactMap { $0["properties"]?["kind"]?.string }.sorted()
        #expect(kinds == ["route", "sigmet", "station", "waypoint", "waypoint"])
        // No glyphs without the bundled assets, so no labels.
        #expect(style["glyphs"] == nil && !layers.contains { $0["id"]?.string == "brief-labels" })
        #expect(map.bounds.minLatitude < 30.1945 && map.bounds.maxLatitude > 32.8471)
    }

    // Adak to Shemya crosses 180°: one box over both ends, and every shape drawn inside it.
    @Test func aRouteAcrossTheDateLineIsOneMapWithEverythingOnIt() throws {
        let adak = point("PADK", 51.878, -176.646), shemya = point("PASY", 52.7183, 174.1136)
        let route = try #require(Route(waypoints: [adak, shemya], navCycle: "2026-10-01"))
        var w = WeatherData()
        w.metars = [metar("PASY", shemya, .vfr, sky: []), metar("PADK", adak, .vfr, sky: [])]
        let map = brief(w, route: route).graphics.map
        let b = map.bounds
        #expect(b.maxLongitude - b.minLongitude < 20 && b.minLongitude < 174.1136 - 360 && b.maxLongitude > -176.646)
        let style = try JSONDecoder().decode(JSON.self, from: Data(map.pictures[0].style.utf8))
        guard case .array(let features)? = style["sources"]?["brief"]?["data"]?["features"] else { Issue.record("no features"); return }
        var longitudes: [Double] = []
        for f in features {
            switch f["geometry"]?["coordinates"] {
            case .array(let pair)? where pair.count == 2 && pair.allSatisfy({ if case .number = $0 { true } else { false } }):
                if case .number(let lon) = pair[0] { longitudes.append(lon) }
            case .array(let line)?:
                for case .array(let pair) in line { if case .number(let lon)? = pair.first { longitudes.append(lon) } }
            default: break
            }
        }
        #expect(longitudes.count > 6 && longitudes.allSatisfy { b.minLongitude < $0 && $0 < b.maxLongitude })
        // Packs either side of 180 hold the box between them; one side alone does not.
        let west = MapStyleSpec.Box(minLatitude: 50, minLongitude: 170, maxLatitude: 55, maxLongitude: 180)
        let east = MapStyleSpec.Box(minLatitude: 50, minLongitude: -180, maxLatitude: 55, maxLongitude: -170)
        #expect(BriefGraphics.covers(b, [west, east]) && !BriefGraphics.covers(b, [east]))
    }
}
