/// The brief's pictures as data: the hazard summary, the map styles, the route profile and the airport panels.
/// The platforms only snapshot the styles and draw the shapes; every choice of what and where is made here.
public struct BriefGraphics: Equatable, Sendable, Encodable {
    public struct Hazard: Equatable, Sendable, Encodable {
        public var text: String
        /// Red; otherwise amber.
        public var severe: Bool
    }

    /// Such as "2 SIGMETs · 1 TFR".
    public var counts: String
    /// Worst first, at most `hazardLimit`.
    public var hazards: [Hazard]
    public var map: BriefMap
    public var profile: BriefProfile
    public var airports: [BriefAirport]

    public static let hazardLimit = 6
    public static let noHazards = "No advisories, TFRs or urgent PIREPs along the route"
    public static let building = "Building brief…"
    public static let hazardsTitle = "Hazard summary"
    public static let profileTitle = "Route profile"
    public static let airportsTitle = "Airports"
    public static let picturesTitle = "Radar and satellite"

    /// Map hex and panel color names per category, as the map's station dots and the airport page use them.
    static let hex: [FlightCategory: String] = [.vfr: "#1a8f3c", .mvfr: "#1f5fd0", .ifr: "#d32020", .lifr: "#b0189e",
                                                .unknown: "#6b6b6b"]
    static let names: [FlightCategory: String] = [.vfr: "green", .mvfr: "blue", .ifr: "red", .lifr: "magenta",
                                                  .unknown: "gray"]
}

/// What the route map can be drawn over: installed packs, the light street style text and the bundled assets.
public struct BriefMapBase: Sendable {
    public var installed: [PackFile]
    public var streetTemplate: String?
    /// What __ASSETS__ becomes, such as file:///…/MapAssets or asset:/.
    public var assets: String

    public init(installed: [PackFile], streetTemplate: String?, assets: String) {
        self.installed = installed
        self.streetTemplate = streetTemplate
        self.assets = assets
    }
}

/// Map styles to snapshot over one camera box.
public struct BriefMap: Equatable, Sendable, Encodable {
    public struct Picture: Equatable, Sendable, Encodable {
        /// route, radar or satellite.
        public var id: String
        public var title: String
        /// A complete MapLibre style document.
        public var style: String
    }

    /// The snapshot size in points.
    public static let width = 600.0
    public static let height = 360.0
    public static let routeTitle = "Route map"

    public var bounds: MapStyleSpec.Box
    public var pictures: [Picture]
}

/// A side view along the route: x is nautical miles from departure, y is feet MSL.
public struct BriefProfile: Equatable, Sendable, Encodable {
    public struct Tick: Equatable, Sendable, Encodable {
        public var value: Double
        public var text: String
    }

    /// The highest terrain, or failing tiles the highest airport, near one stretch of the route.
    public struct Ground: Equatable, Sendable, Encodable {
        public var fromNM: Double
        public var toNM: Double
        public var ft: Int
    }

    /// The tallest obstacle near one stretch of the route.
    public struct Obstacle: Equatable, Sendable, Encodable {
        public var nm: Double
        /// Top in feet MSL.
        public var ft: Int
    }

    /// One station's lowest layer at the time the plan passes it.
    public struct Cloud: Equatable, Sendable, Encodable {
        public var nm: Double
        /// Base in feet MSL. Nil for a clear sky or a station of unknown elevation.
        public var ft: Int?
        public var station: String
        /// Such as BKN 035, or CLR.
        public var text: String
        public var ceiling: Bool
        /// green, blue, red, magenta or gray.
        public var color: String
    }

    /// A wind barb at cruise, in points around its anchor, y down, already turned.
    public struct Barb: Equatable, Sendable, Encodable {
        public var nm: Double
        public var ft: Int
        public var lineWidth: Double
        public var lines: [[Double]]
        public var triangles: [[Double]]
        public var ring: Double?
    }

    public var lengthNM: Double
    public var topFt: Int
    public var cruiseFt: Int
    public var grid: [Tick]
    public var waypoints: [Tick]
    public var ground: [Ground]
    /// At most one per 5 nm stretch, tallest by MSL, within `groundReachNM` of the route.
    public var obstacles: [Obstacle]
    /// Runs of [nm, ft] where the 0°C level is known.
    public var freezing: [[[Double]]]
    public var clouds: [Cloud]
    public var winds: [Barb]
    public var caption: String

    public static let groundReachNM = 10.0
}

/// One airport's panel: its weather block and the TAF across its time.
public struct BriefAirport: Equatable, Sendable, Encodable {
    public struct Span: Equatable, Sendable, Encodable {
        /// Fractions of the bar.
        public var from: Double
        public var to: Double
        public var color: String
    }

    public var title: String
    public var weather: NavPages.AirportWeather
    /// Empty with no TAF covering the window.
    public var spans: [Span]
    /// Where the planned time sits on the bar.
    public var mark: Double
    /// Start, planned time and end, such as 1300Z, ETA 1500Z, 1700Z.
    public var times: [String]
    public var tafNote: String?

    public static let windowHours = 2.0
}

extension BriefGraphics {
    struct Inputs {
        var route: Route
        var inputs: FlightPlanInputs
        var plan: FlightPlan
        var weather: WeatherData
        var now: Date
        var corridor: Corridor
        var sigmets: [Sigmet]
        var cwas: [Cwa]
        var airmets: [GAirmet]
        var tfrs: [Tfr]
        var pireps: [Pirep]
        var airports: [(role: String, ident: String)]
        var database: NavDatabase?
        var base: BriefMapBase?
        var terrain: TerrainTiles?
    }

    static func make(_ i: Inputs) -> BriefGraphics {
        let c = i.corridor
        let start = i.plan.departure, eta = i.plan.eta ?? i.plan.departure
        // The time the plan passes a point, evenly between departure and ETA.
        func time(at nm: Double) -> Date { start + eta.timeIntervalSince(start) * (c.lengthNM > 0 ? nm / c.lengthNM : 0) }

        // Airports in the box around the route, for the ground line, station elevations and the panels.
        let box = c.box(padNM: FlightBrief.corridorNM + 5)
        let nearby = (try? i.database?.airports(in: box)) ?? []
        let obstacles = (try? i.database?.obstacles(in: c.box(padNM: BriefProfile.groundReachNM))) ?? []
        var elevations: [String: Double] = [:]
        for a in nearby { if let e = a.elevationFt { elevations[NavText.title(a)] = e; elevations[a.ident] = e } }

        // Hazards: airport categories, then advisories, TFRs and urgent PIREPs by where they meet the route.
        var hazards: [(Hazard, Double)] = []
        for (role, ident) in i.airports {
            let at = role == "Departure" ? start : eta
            let when = role == "Departure" ? "departure" : "ETA"
            let taf = i.weather.tafs.filter { $0.station == ident }.max { $0.issued < $1.issued }
            let metar = newestMetar(ident, i.weather, i.now)
            let found: (FlightCategory, String)? = taf?.conditions(at: at).map { ($0.category, "forecast at \(ident) at \(when)") }
                ?? metar.map { ($0.category, "at \(ident) now") }
            guard let found, [.mvfr, .ifr, .lifr].contains(found.0) else { continue }
            hazards.append((Hazard(text: "\(found.0.rawValue) \(found.1)", severe: found.0 != .mvfr), -1))
        }
        func add(_ title: String, _ shape: WeatherShape, severe: Bool) {
            guard let spot = c.nearest(shape) else { return }
            hazards.append((Hazard(text: "\(title) \(c.words(spot))", severe: severe), spot.offNM))
        }
        for s in i.sigmets { add("\(s.hazard) \(s.kind ?? "SIGMET")", s.shape, severe: true) }
        for w in i.cwas { add("\(w.hazard) CWA", w.shape, severe: true) }
        for g in i.airmets { add("G-AIRMET \(g.hazard)", g.shape, severe: false) }
        for t in i.tfrs { if let shape = t.shape { add("TFR \(t.notam)", shape, severe: true) } }
        for p in i.pireps {
            let spot = c.locate(c.project(p.coordinate))
            hazards.append((Hazard(text: "Urgent PIREP \(c.words(spot))", severe: true), spot.offNM))
        }
        let worst = hazards.enumerated().sorted { a, b in
            let ka = (a.element.0.severe ? 0 : 1, a.element.1), kb = (b.element.0.severe ? 0 : 1, b.element.1)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.prefix(hazardLimit).map(\.element.0)
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        let counted = [count(i.sigmets.count, "SIGMET", "SIGMETs"), count(i.cwas.count, "CWA", "CWAs"),
                       count(i.airmets.count, "G-AIRMET", "G-AIRMETs"), count(i.tfrs.count, "TFR", "TFRs"),
                       count(i.pireps.count, "urgent PIREP", "urgent PIREPs")].compactMap { $0 }

        // Stations within the corridor, newest report each.
        var stations: [String: Metar] = [:]
        for m in i.weather.metars where c.distanceNM(to: m.coordinate) <= FlightBrief.corridorNM {
            if let held = stations[m.station], held.observed >= m.observed { continue }
            stations[m.station] = m
        }
        let shown = stations.values.sorted { $0.station < $1.station }

        let map = BriefMap(bounds: c.box(padNM: 20, share: 0.12),
                           pictures: pictures(i, shown, start: start, end: eta + 3600))
        let profile = profile(i, shown, nearby: nearby, obstacles: obstacles, elevations: elevations, time: time)
        let panels = i.airports.map { panel($0.role, $0.ident, i, at: $0.role == "Departure" ? start : eta) }
        return BriefGraphics(counts: counted.isEmpty ? noHazards : counted.joined(separator: " · "), hazards: Array(worst),
                             map: map, profile: profile, airports: panels)
    }

    static func newestMetar(_ station: String, _ weather: WeatherData, _ now: Date) -> Metar? {
        weather.metars.filter { $0.station == station && WeatherGeoJSON.isFresh($0.age(at: now)) }.max { $0.observed < $1.observed }
    }

    // MARK: Map

    /// True when the packs' boxes hold every corner of the map's box, taken in parts either side of 180.
    static func covers(_ box: MapStyleSpec.Box, _ packs: [MapStyleSpec.Box]) -> Bool {
        NavDatabase.wrapped(box).allSatisfy { b in
            [(b.minLatitude, b.minLongitude), (b.minLatitude, b.maxLongitude),
             (b.maxLatitude, b.minLongitude), (b.maxLatitude, b.maxLongitude)].allSatisfy { lat, lon in
                packs.contains { $0.minLatitude <= lat && lat <= $0.maxLatitude && $0.minLongitude <= lon && lon <= $0.maxLongitude }
            }
        }
    }

    static func pictures(_ i: Inputs, _ stations: [Metar], start: Date, end: Date) -> [BriefMap.Picture] {
        let c = i.corridor
        func feature(_ kind: String, _ geometry: JSON, _ more: [String: JSON] = [:]) -> JSON {
            var props = more
            props["kind"] = .string(kind)
            return ["type": "Feature", "properties": .object(props), "geometry": geometry]
        }
        // The box keeps counting past 180 as the route does; each point goes on the copy of the world nearest its middle.
        let box = c.box(padNM: 20, share: 0.12), middle = (box.minLongitude + box.maxLongitude) / 2
        func pair(_ p: Coordinate) -> JSON { [.number(middle + remainder(p.longitude - middle, 360)), .number(p.latitude)] }
        func area(_ kind: String, _ shape: WeatherShape, _ color: String) -> JSON? {
            guard case .polygon(let ring) = shape else { return nil }
            return feature(kind, ["type": "Polygon", "coordinates": [.array(ring.map(pair))]], ["color": .string(color)])
        }
        var line = [feature("route", ["type": "LineString", "coordinates": .array(c.points.map(pair))])]
        line += i.route.waypoints.map {
            feature("waypoint", ["type": "Point", "coordinates": pair($0.coordinate)], ["ident": .string($0.ident)])
        }
        var weather: [JSON] = []
        weather += i.airmets.compactMap { area("airmet", $0.shape, "#7a4fc0") }
        weather += i.sigmets.compactMap { area("sigmet", $0.shape, "#d98400") }
        weather += i.cwas.compactMap { area("cwa", $0.shape, "#00838f") }
        weather += i.tfrs.compactMap { t in t.shape.flatMap { area("tfr", $0, "#d32020") } }
        weather += stations.map {
            feature("station", ["type": "Point", "coordinates": pair($0.coordinate)], ["color": .string(hex[$0.category] ?? "#6b6b6b")])
        }

        var out = [BriefMap.Picture(id: "route", title: BriefMap.routeTitle,
                                    style: style(i, features: weather + line, under: [:], layers: []))]
        if let frame = i.weather.radarLoop(at: i.now).last {
            let fill: [JSON] = ["step", ["get", "dbz"], .string(rgba(RadarStyle.noCoverage.color, RadarStyle.noCoverage.opacity))]
                + RadarStyle.bands.flatMap { [.number($0.dbz), .string(rgba($0.color, RadarStyle.echoOpacity))] as [JSON] }
            out.append(.init(id: "radar", title: RadarLoop.clock(frame.valid), style: style(
                i, features: line, under: ["brief-radar": ["type": "vector", "url": .string("pmtiles://" + frame.file.absoluteString)]],
                layers: [["id": "brief-radar", "type": "fill", "source": "brief-radar", "source-layer": "radar",
                          "paint": ["fill-color": .array(fill)]]])))
        }
        if let frame = i.weather.satelliteShown(at: i.now) {
            out.append(.init(id: "satellite", title: "Satellite " + WeatherText.zulu(frame.valid), style: style(
                i, features: line,
                under: ["brief-satellite": ["type": "raster", "tileSize": 256, "url": .string("pmtiles://" + frame.file.absoluteString)]],
                layers: [["id": "brief-satellite", "type": "raster", "source": "brief-satellite",
                          "paint": ["raster-opacity": .number(SatelliteStyle.opacity), "raster-resampling": "linear"]]])))
        }
        return out
    }

    static func rgba(_ hex: String, _ alpha: Double) -> String {
        let rgb = Int(hex.dropFirst(), radix: 16) ?? 0
        return "rgba(\(rgb >> 16 & 255), \(rgb >> 8 & 255), \(rgb & 255), \(alpha))"
    }

    /// The base (street, else VFR chart, else plain), then `layers` over `under`, then the brief's own shapes on top.
    static func style(_ i: Inputs, features: [JSON], under: [String: JSON], layers: [JSON]) -> String {
        let bounds = i.corridor.box(padNM: 20, share: 0.12)
        var style: JSON = ["version": 8, "sources": [:],
                           "layers": [["id": "background", "type": "background", "paint": ["background-color": "#eceff1"]]]]
        if let base = i.base {
            style["glyphs"] = .string(base.assets + "/fonts/{fontstack}/{range}.pbf")
            let street = MapStyleSpec.make(base: .street, installed: base.installed, night: false, now: i.now,
                                           view: bounds, bounds: PackCoverage.bounds)
            let charts = MapStyleSpec.make(base: .vfr, installed: base.installed, night: false, now: i.now)
            // A base only when its packs hold every corner, so the picture is never half map, half gray.
            // ponytail: corners only; a gap between packs inside the box still shows. Test the union if one does.
            func covers(_ packs: [URL]) -> Bool { Self.covers(bounds, packs.compactMap(PackCoverage.bounds)) }
            if case .street(let packs) = street.content, covers(packs), let template = base.streetTemplate,
               let text = try? MapStyleSpec.streetStyle(template: template, assets: base.assets, packs: packs),
               let made = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) {
                style = made
            } else if case .charts(let rasters) = charts.content, covers(rasters.map(\.url)), case .array(var list)? = style["layers"] {
                var sources: [String: JSON] = [:]
                for r in rasters {
                    sources[r.identifier] = ["type": "raster", "tileSize": 256, "url": .string("pmtiles://file://" + r.url.path)]
                    list.append(["id": .string(r.identifier), "type": "raster", "source": .string(r.identifier)])
                }
                style["sources"] = .object(sources)
                style["layers"] = .array(list)
            }
        }
        guard case .object(var sources)? = style["sources"], case .array(var list)? = style["layers"] else { return "{}" }
        sources.merge(under) { _, new in new }
        sources["brief"] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": .array(features)]]
        list += layers
        let polygon: JSON = ["==", ["geometry-type"], "Polygon"]
        func kind(_ k: String) -> JSON { ["==", ["get", "kind"], .string(k)] }
        let route = "#d11fb6"
        list += [
            ["id": "brief-area", "type": "fill", "source": "brief", "filter": polygon,
             "paint": ["fill-color": ["get", "color"], "fill-opacity": 0.14]],
            ["id": "brief-area-line", "type": "line", "source": "brief", "filter": polygon,
             "paint": ["line-color": ["get", "color"], "line-width": 1.5]],
            ["id": "brief-route-casing", "type": "line", "source": "brief", "filter": kind("route"),
             "layout": ["line-cap": "round", "line-join": "round"], "paint": ["line-color": "#ffffff", "line-width": 6]],
            ["id": "brief-route", "type": "line", "source": "brief", "filter": kind("route"),
             "layout": ["line-cap": "round", "line-join": "round"], "paint": ["line-color": .string(route), "line-width": 3]],
            ["id": "brief-stations", "type": "circle", "source": "brief", "filter": kind("station"),
             "paint": ["circle-radius": 5, "circle-color": ["get", "color"], "circle-stroke-color": "#ffffff",
                       "circle-stroke-width": 1.5]],
            ["id": "brief-waypoints", "type": "circle", "source": "brief", "filter": kind("waypoint"),
             "paint": ["circle-radius": 4, "circle-color": .string(route), "circle-stroke-color": "#ffffff", "circle-stroke-width": 2]],
        ]
        if style["glyphs"] != nil {
            list.append(["id": "brief-labels", "type": "symbol", "source": "brief", "filter": kind("waypoint"),
                         "layout": ["text-field": ["get", "ident"], "text-font": ["Noto Sans Medium"], "text-size": 13,
                                    "text-anchor": "bottom", "text-offset": [0, -0.6]],
                         "paint": ["text-color": .string(route), "text-halo-color": "#ffffff", "text-halo-width": 2]])
        }
        style["sources"] = .object(sources)
        style["layers"] = .array(list)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(style)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Profile

    static func profile(_ i: Inputs, _ stations: [Metar], nearby: [Airport], obstacles: [Obstacle],
                        elevations: [String: Double], time: (Double) -> Date) -> BriefProfile {
        let c = i.corridor
        let length = c.lengthNM
        let cruise = i.inputs.cruiseAltitudeFt

        // Highest terrain within reach of each 5 nm bin; airports stand in where tiles are missing.
        let bin = 5.0
        let last = max(0, Int((length / bin).rounded(.up)) - 1)
        var bins: [Int: Double] = [:]
        for a in nearby {
            guard let e = a.elevationFt else { continue }
            let spot = c.locate(c.project(a.coordinate))
            guard spot.offNM <= BriefProfile.groundReachNM else { continue }
            let k = min(Int(spot.alongNM / bin), last)
            bins[k] = max(bins[k] ?? -.infinity, e)
        }
        if let tiles = i.terrain {
            let zoom = TerrainSampler.zoom(atLatitude: c.origin.latitude)
            let sampler = TerrainSampler(zoom: zoom, tiles: tiles)
            let step = TerrainSampler.cellNM(zoom: zoom, latitude: c.origin.latitude)
            for p in c.band(reachNM: BriefProfile.groundReachNM, step: step) {
                guard let ft = sampler.feet(at: p.coordinate) else { continue }
                let k = min(Int(p.alongNM / bin), last)
                bins[k] = max(bins[k] ?? -.infinity, ft)
            }
        }
        let ground = bins.keys.sorted().map {
            BriefProfile.Ground(fromNM: Double($0) * bin, toNM: min(length, Double($0 + 1) * bin), ft: Int(bins[$0]!.rounded()))
        }

        var tallest: [Int: BriefProfile.Obstacle] = [:]
        for o in obstacles {
            let spot = c.locate(c.project(o.coordinate))
            guard spot.offNM <= BriefProfile.groundReachNM else { continue }
            let k = min(Int(spot.alongNM / bin), last)
            if o.mslFt > tallest[k]?.ft ?? .min { tallest[k] = .init(nm: spot.alongNM, ft: o.mslFt) }
        }
        let towers = tallest.keys.sorted().map { tallest[$0]! }

        // Each station's lowest layer when the plan passes it: the TAF if it covers that time, else the METAR.
        var clouds: [BriefProfile.Cloud] = []
        for m in stations {
            let spot = c.locate(c.project(m.coordinate))
            let at = time(spot.alongNM)
            let taf = i.weather.tafs.filter { $0.station == m.station }.max { $0.issued < $1.issued }
            let sky: [SkyLayer], category: FlightCategory
            if let found = taf?.conditions(at: at) {
                sky = found.prevailing.sky ?? []
                category = found.category
            } else {
                sky = m.sky
                category = m.category
            }
            let layer = sky.first { $0.isCeiling && $0.baseFtAGL != nil } ?? sky.first { $0.baseFtAGL != nil } ?? sky.first
            let elevation = elevations[m.station]
            let ft = layer?.baseFtAGL.flatMap { base in elevation.map { Int($0.rounded()) + base } }
            clouds.append(.init(nm: spot.alongNM, ft: ft, station: m.station, text: layer?.text ?? "No clouds",
                                ceiling: layer?.isCeiling ?? false, color: names[category] ?? "gray"))
        }
        clouds.sort { ($0.nm, $0.station) < ($1.nm, $1.station) }

        // The 0°C level from the winds aloft temperatures, every 10 nm. Unknown at or below the lowest level with a temperature.
        var freezing: [[[Double]]] = []
        var run: [[Double]] = []
        var barbs: [BriefProfile.Barb] = []
        if let winds = i.weather.winds?.unexpired(at: i.now) {
            let steps = max(1, min(40, Int((length / 10).rounded(.up))))
            for k in 0...steps {
                let nm = length * Double(k) / Double(steps)
                guard let stations = winds.forecast(at: time(nm))?.forecast.stations,
                      let ft = freezingLevel(stations, at: c.coordinate(at: nm)) else {
                    if !run.isEmpty { freezing.append(run) }
                    run = []
                    continue
                }
                run.append([nm, ft])
            }
            if !run.isEmpty { freezing.append(run) }

            let count = max(1, min(8, Int(length / 25)))
            for k in 0..<count {
                let nm = length * (Double(k) + 0.5) / Double(count)
                guard let stations = winds.forecast(at: time(nm))?.forecast.stations,
                      let s = WindsAloft.sample(stations, at: c.coordinate(at: nm), altitudeFt: Double(cruise)) else { continue }
                let wind = WindsAloft.wind(u: s.u, v: s.v)
                barbs.append(barb(WindBarb(directionDeg: Int(wind.directionTrue.rounded()), speedKt: Int(wind.speedKt.rounded())),
                                  nm: nm, ft: cruise))
            }
        }

        let highest = max(Double(cruise), ground.map { Double($0.ft) }.max() ?? 0, towers.map { Double($0.ft) }.max() ?? 0)
        let top = max(4000, Int(((highest + 2500) / 2000).rounded(.up)) * 2000)
        let step = top <= 8000 ? 2000 : top <= 20000 ? 4000 : 10000
        let grid = stride(from: step, to: top, by: step).map { BriefProfile.Tick(value: Double($0), text: NavText.grouped($0)) }
        var marks: [BriefProfile.Tick] = []
        for (n, w) in i.route.waypoints.enumerated() {
            let nm = n == i.route.waypoints.count - 1 ? length : c.legStart(n)
            marks.append(.init(value: nm, text: w.ident))
        }
        let caption = "Cruise \(NavText.grouped(cruise)) ft in magenta, 0°C in blue, highest terrain within "
            + "\(Int(BriefProfile.groundReachNM)) nm in gray, tallest tower in each 5 nm in black, lowest cloud layer at each station when you pass it"
        return BriefProfile(lengthNM: length, topFt: top, cruiseFt: cruise, grid: grid, waypoints: marks, ground: ground,
                            obstacles: towers, freezing: freezing, clouds: clouds, winds: barbs, caption: caption)
    }

    /// Feet MSL where the forecast temperature reaches 0°C, between the lowest level with a temperature and 30,000 ft.
    static func freezingLevel(_ stations: [WindsAloft.Station], at point: Coordinate) -> Double? {
        let floor = stations.compactMap { $0.levels.first { $0.temp != nil }?.ft }.min() ?? 6000
        var below: (ft: Double, temp: Double)?
        for ft in stride(from: Double(floor), through: 30000, by: 500) {
            guard let temp = WindsAloft.sample(stations, at: point, altitudeFt: ft)?.temp else { return nil }
            if temp <= 0 {
                guard let below else { return nil }
                return below.ft + (ft - below.ft) * below.temp / (below.temp - temp)
            }
            below = (ft, temp)
        }
        return nil
    }

    /// The core's barb drawing turned to the wind and scaled to about 34 points across.
    static func barb(_ b: WindBarb, nm: Double, ft: Int) -> BriefProfile.Barb {
        let d = WindBarb.drawing(b.bucket)
        let scale = 0.4, r = Double(b.rotation) * .pi / 180, mid = d.size / 2
        func turn(_ x: Double, _ y: Double) -> [Double] {
            let dx = x - mid, dy = y - mid
            return [(dx * cos(r) - dy * sin(r)) * scale, (dx * sin(r) + dy * cos(r)) * scale]
        }
        func points(_ list: [[Double]]) -> [[Double]] {
            list.map { p in stride(from: 0, to: p.count - 1, by: 2).flatMap { turn(p[$0], p[$0 + 1]) } }
        }
        return .init(nm: nm, ft: ft, lineWidth: d.lineWidth * scale, lines: points(d.lines), triangles: points(d.triangles),
                     ring: d.ring.map { $0 * scale })
    }

    // MARK: Airports

    static func panel(_ role: String, _ ident: String, _ i: Inputs, at time: Date) -> BriefAirport {
        let found = try? i.database?.airport(identifier: ident)
        let detail = found.flatMap { try? i.database?.detail(airportID: $0.id) } ?? AirportDetail(
            airport: Airport(id: 0, ident: ident, icao: ident, name: ident, city: "", state: "", type: "A", use: "PU",
                             coordinate: Coordinate(latitude: 0, longitude: 0), elevationFt: nil, magneticVariation: nil,
                             patternAltitude: nil, tower: "", fuel: nil, artcc: nil, status: "O"),
            runways: [], frequencies: [], remarks: [])
        let station = NavText.title(detail.airport)
        let metar = i.weather.metars.filter { $0.station == station }.max { $0.observed < $1.observed }
        let weather = NavPages.airportWeather(detail, metar: metar, now: i.now).0
        let taf = i.weather.tafs.filter { $0.station == station }.max { $0.issued < $1.issued }
        let hours = BriefAirport.windowHours, from = time - hours * 3600
        let steps = Int(hours * 8)
        var spans: [BriefAirport.Span] = []
        for k in 0..<steps {
            let at = from + Double(k) * 900
            guard let category = taf?.conditions(at: at)?.category, let color = names[category] else { continue }
            let a = Double(k) / Double(steps), b = Double(k + 1) / Double(steps)
            if let last = spans.last, last.color == color, last.to == a { spans[spans.count - 1].to = b; continue }
            spans.append(.init(from: a, to: b, color: color))
        }
        let label = role == "Departure" ? "Departure" : "ETA"
        let note = taf == nil ? "No TAF held" : spans.isEmpty ? "TAF does not cover this time" : nil
        return BriefAirport(title: "\(role) \(station)", weather: weather, spans: spans, mark: 0.5,
                            times: [WeatherText.zulu(from), "\(label) \(WeatherText.zulu(time))", WeatherText.zulu(time + hours * 3600)],
                            tafNote: note)
    }
}

extension Corridor {
    /// The nearest place on the route to a point.
    struct Spot {
        var alongNM: Double
        var offNM: Double
        var leg: Int
        /// Compass word from the route toward the point, such as north.
        var side: String
    }

    var lengthNM: Double { along.last ?? 0 }

    func locate(_ q: Point) -> Spot {
        var best = Spot(alongNM: 0, offNM: .infinity, leg: 0, side: "")
        guard let first = path.first else { return best }
        if path.count == 1 { return Spot(alongNM: 0, offNM: Self.gap(q, first, first), leg: 0, side: Self.compass(first, q)) }
        for k in 0..<(path.count - 1) {
            let a = path[k], b = path[k + 1]
            let dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy
            let t = length2 > 0 ? max(0, min(1, ((q.x - a.x) * dx + (q.y - a.y) * dy) / length2)) : 0
            let foot = (x: a.x + t * dx, y: a.y + t * dy)
            let off = ((q.x - foot.x) * (q.x - foot.x) + (q.y - foot.y) * (q.y - foot.y)).squareRoot()
            if off < best.offNM {
                best = Spot(alongNM: along[k] + t * (along[k + 1] - along[k]), offNM: off, leg: legs[k], side: Self.compass(foot, q))
            }
        }
        return best
    }

    /// Where an area meets the route: on it when a sample is inside, else its nearest edge or corner.
    func nearest(_ shape: WeatherShape) -> Spot? {
        guard case .polygon(let points) = shape, !points.isEmpty else { return nil }
        let ring = points.map(project)
        if let k = path.indices.first(where: { Polygon.contains(path[$0].x, path[$0].y, in: ring) }) {
            return Spot(alongNM: along[k], offNM: 0, leg: legs[k], side: "")
        }
        var best = ring.map(locate).min { $0.offNM < $1.offNM }
        // A long edge can pass a sample closer than any corner does.
        for (k, p) in path.enumerated() {
            for (a, b) in zip(ring, ring.dropFirst()) {
                let d = Self.gap(p, a, b)
                guard d < best?.offNM ?? .infinity else { continue }
                let dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy
                let t = length2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0
                best = Spot(alongNM: along[k], offNM: d, leg: legs[k], side: Self.compass(p, (a.x + t * dx, a.y + t * dy)))
            }
        }
        return best
    }

    /// "on leg 2", or "20 nm north of leg 2"; a one-leg route says "the route".
    func words(_ s: Spot) -> String {
        let leg = (legs.last ?? 0) > 0 ? "leg \(s.leg + 1)" : "the route"
        let nm = Int(s.offNM.rounded())
        return nm < 1 ? "on \(leg)" : "\(nm) nm \(s.side) of \(leg)"
    }

    static func compass(_ from: Point, _ to: Point) -> String {
        let angle = atan2(to.x - from.x, to.y - from.y) * 180 / .pi
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[Int(((angle + 360 + 22.5) / 45).rounded(.down)) % 8]
    }

    /// Distance along the route where leg n starts.
    func legStart(_ n: Int) -> Double { legs.firstIndex(of: n).map { along[$0] } ?? lengthNM }

    /// The route point this far from departure.
    func coordinate(at nm: Double) -> Coordinate {
        guard let k = along.lastIndex(where: { $0 <= nm }), k + 1 < points.count else { return points.last ?? origin }
        let span = along[k + 1] - along[k], f = span > 0 ? (nm - along[k]) / span : 0
        let a = points[k], b = points[k + 1]
        return Coordinate(latitude: a.latitude + f * (b.latitude - a.latitude), longitude: a.longitude + f * (b.longitude - a.longitude))
    }

    /// A box around the route, padded by a share of its size and at least `padNM`.
    func box(padNM: Double, share: Double = 0) -> MapStyleSpec.Box {
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let south = lats.min() ?? 0, north = lats.max() ?? 0, west = lons.min() ?? 0, east = lons.max() ?? 0
        let scale = max(cos((south + north) / 2 * .pi / 180), 0.1)
        let padLat = max(padNM / 60, (north - south) * share), padLon = max(padNM / 60 / scale, (east - west) * share)
        return MapStyleSpec.Box(minLatitude: south - padLat, minLongitude: west - padLon,
                                maxLatitude: north + padLat, maxLongitude: east + padLon)
    }
}
