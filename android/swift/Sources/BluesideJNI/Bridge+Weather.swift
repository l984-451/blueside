import FlightCore

/// The weather folder and what it holds, as iOS WeatherCache keeps it. Kotlin makes the requests and hands
/// each reply here as a file; every decision, the held tags and the words stay here.
final class WeatherSession {
    typealias Held = WeatherPolicy.Held

    let root: URL
    private(set) var data = WeatherData()
    private var held: [String: Held] = [:]
    private var loop: RadarLoop?

    init(root: String) {
        self.root = URL(fileURLWithPath: root)
        try? FileManager.default.createDirectory(at: radarFolder, withIntermediateDirectories: true)
        held = contents(heldFile).flatMap { try? JSONDecoder().decode([String: Held].self, from: $0) } ?? [:]
        for source in WeatherSource.allCases where source.fileName != nil {
            guard let entry = held[source.rawValue], let json = contents(file(source)),
                  (try? data.take(source, json: json)) != nil else {
                held[source.rawValue] = nil
                continue
            }
            data.checkedAt[source] = entry.checkedAt
        }
        data.index = contents(indexFile).flatMap { try? WeatherIndex.decode($0) }
        data.frames = framesOnDisk()
        data.satellite = satelliteOnDisk()
    }

    private func contents(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }
    private func file(_ source: WeatherSource) -> URL { root.appendingPathComponent("\(source.rawValue).json") }
    private var indexFile: URL { root.appendingPathComponent("index.json") }
    private var heldFile: URL { root.appendingPathComponent("held.json") }
    private var radarFolder: URL { root.appendingPathComponent("radar", isDirectory: true) }

    private func namesOnDisk() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: radarFolder.path)) ?? [] }

    private func framesOnDisk() -> [RadarLoopFrame] {
        (data.index?.frames ?? []).map { RadarLoopFrame(valid: $0.valid, file: radarFolder.appendingPathComponent(WeatherPolicy.frameName($0))) }
            .filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    /// The index's satellite picture when it is on disk. It shares the radar folder under its own prefix.
    private func satelliteOnDisk() -> RadarLoopFrame? {
        data.index?.satellite.map { RadarLoopFrame(valid: $0.valid, file: radarFolder.appendingPathComponent(WeatherPolicy.frameName($0))) }
            .flatMap { FileManager.default.fileExists(atPath: $0.file.path) ? $0 : nil }
    }

    /// A reply as Kotlin hands it: the status and the body saved to a file, or why the request failed.
    struct Reply: Decodable {
        var status: Int?
        var file: String?
        var etag: String?
        /// offline, timeout, tls or other.
        var failed: String?
    }

    private static func words(_ failed: String) -> String {
        switch failed {
        case "offline": "No connection"
        case "timeout": WeatherPolicy.timedOut
        case "tls": "Secure connection failed"
        default: "Server not reachable"
        }
    }

    /// The body, read and then deleted, or the failure.
    private func body(_ reply: Reply) throws -> (status: Int, data: Data) {
        if let failed = reply.failed { throw Unreached(reason: Self.words(failed)) }
        defer { if let file = reply.file { try? FileManager.default.removeItem(atPath: file) } }
        return (reply.status ?? 0, reply.file.flatMap { FileManager.default.contents(atPath: $0) } ?? Data())
    }

    /// A request that got no answer, in the platform's words.
    private struct Unreached: Error { var reason: String }

    private static func reason(_ error: any Error) -> String {
        (error as? Unreached)?.reason ?? WeatherPolicy.reason(error) ?? "\(error)"
    }

    struct Fetch: Encodable { var source: String; var path: String; var etag: String? }
    struct Plan: Encodable { var jobs: [Fetch]; var frames: [Fetch] }

    /// Starts a pass with the index reply: the source files and the radar picture to fetch.
    func index(_ reply: Reply, now: Date) -> Plan {
        data.failures = [:]
        let index: WeatherIndex
        do {
            let (status, body) = try body(reply)
            index = try WeatherPolicy.index(status: status, body: body)
            try? body.write(to: indexFile, options: .atomic)
        } catch {
            // Without a good index nothing can be dated, so every copy on hand stays as it is.
            for source in WeatherSource.allCases { data.failures[source] = Self.reason(error) }
            return Plan(jobs: [], frames: [])
        }
        data.index = index
        let frames = WeatherPolicy.framePlan(index: index, now: now, onDisk: namesOnDisk(), keeping: loop?.names ?? [])
        for name in frames.delete { try? FileManager.default.removeItem(at: radarFolder.appendingPathComponent(name)) }
        data.frames = framesOnDisk()
        data.satellite = satelliteOnDisk()
        return Plan(jobs: WeatherPolicy.jobs(index: index, held: held).map { Fetch(source: $0.source.rawValue, path: $0.path, etag: $0.etag) },
                    frames: frames.fetch.map { Fetch(source: $0.source.rawValue, path: $0.path) })
    }

    struct SourceArgs: Decodable { var source: String; var reply: Reply }

    func source(_ a: SourceArgs) {
        guard let source = WeatherSource(rawValue: a.source), let checked = data.index?.checkedAt[source] else { return }
        do {
            let (status, body) = try body(a.reply)
            switch try WeatherPolicy.source(status: status, body: body, isHeld: held[source.rawValue] != nil) {
            case .unchanged:
                held[source.rawValue]?.checkedAt = checked
            case .file(let json):
                // Decoded before written, so a bad file never replaces the last good one.
                try data.take(source, json: json)
                if (try? json.write(to: file(source), options: .atomic)) != nil {
                    held[source.rawValue] = Held(checkedAt: checked, etag: a.reply.etag)
                }
            }
            data.checkedAt[source] = checked
        } catch {
            data.failures[source] = Self.reason(error)
        }
        if let text = try? JSONEncoder().encode(held) { try? text.write(to: heldFile, options: .atomic) }
    }

    struct FrameArgs: Decodable { var path: String; var reply: Reply }

    /// Keeps a radar or satellite picture. False when it failed, which ends the pass's picture fetches.
    func frame(_ a: FrameArgs) -> Bool {
        let picture = RadarFrame(valid: Date(), path: a.path)
        do {
            let (status, body) = try body(a.reply)
            try WeatherPolicy.frame(status: status, body: body)
            try body.write(to: radarFolder.appendingPathComponent(WeatherPolicy.frameName(picture)), options: .atomic)
            data.frames = framesOnDisk()
            data.satellite = satelliteOnDisk()
            return true
        } catch {
            data.failures[picture.source] = Self.reason(error)
            return false
        }
    }

    struct LoopFetch: Encodable { var path: String; var loading: String }

    /// Starts the radar loop: its missing pictures in order, each with the progress words to show while it downloads.
    /// Nil when there is nothing to loop.
    func loopStart(now: Date) -> [LoopFetch]? {
        stopLoop()
        guard let index = data.index, let started = RadarLoop(index: index, now: now) else { return nil }
        loop = started
        let missing = started.toFetch(onDisk: namesOnDisk())
        return missing.enumerated().map { LoopFetch(path: $1.path, loading: RadarLoop.loading($0, of: missing.count)) }
    }

    /// Keeps a loop picture. False when it failed or the loop stopped, which ends the downloads.
    func loopFrame(_ a: FrameArgs) -> Bool {
        guard let frame = loop?.frames.first(where: { $0.path == a.path }) else {
            if let file = a.reply.file { try? FileManager.default.removeItem(atPath: file) }
            return false
        }
        guard self.frame(a) else { return false }
        loop?.kept(frame)
        return true
    }

    struct LoopShow: Encodable { var file: String; var clock: String; var seconds: Double }

    /// One turn of the loop, oldest first. Empty when the loop has run its time or has under two pictures.
    func loopPlay(now: Date) -> [LoopShow] {
        guard let loop, !loop.isExpired(at: now) else { return [] }
        let frames = loop.playable(onDisk: namesOnDisk())
        guard frames.count > 1 else { return [] }
        return frames.enumerated().map {
            LoopShow(file: radarFolder.appendingPathComponent(WeatherPolicy.frameName($1)).path, clock: RadarLoop.clock($1.valid),
                     seconds: RadarLoop.hold($0, of: frames.count))
        }
    }

    /// Deletes the pictures the loop downloaded.
    func stopLoop() {
        for name in loop?.cleanup(index: data.index) ?? [] { try? FileManager.default.removeItem(at: radarFolder.appendingPathComponent(name)) }
        loop = nil
    }

    struct ShowArgs: Decodable {
        var now: Date
        /// Ids of the switches that are on.
        var on: [String]
        var show: String?
        /// The winds aloft level the pilot picked, and the route's cruise altitude when there is a route.
        var windsLevel: Int?
        var cruiseFt: Int?

        var level: Int { WindsMap.level(chosen: windsLevel, cruiseFt: cruiseFt) }
    }

    static func shown(_ ids: [String]) -> [WeatherOverlay] {
        var list = OverlayList(groups: [WeatherSwitches.layerGroup, WeatherSwitches.withTfrs(LayerGroup(id: "", title: "", overlays: []))])
        for id in ids { list.setOverlay(id, on: true) }
        return WeatherSwitches.shown(list)
    }

    struct Notices: Encodable, Equatable {
        struct Label: Encodable, Equatable { var id: String; var text: String }
        var labels: [Label]
        var clock: String?
        var legend: String?
        /// Radar is on and drawn, so the clock offers the loop.
        var radar = false
        /// The winds aloft forecast and level drawn, under the clock.
        var winds: String?
        /// When any of these can next change with no new data. Nil for never.
        var next: Date?
    }

    /// The stale labels and the clock, and when they can next change.
    func notices(_ a: ShowArgs) -> Notices {
        let on = Self.shown(a.on)
        let labels = on.compactMap { o in data.staleLabel(for: o, at: a.now).map { Notices.Label(id: o.rawValue, text: $0) } }
        let clock = data.clock(on, at: a.now).map { (on.contains(.radar) ? "Radar " : "Weather ") + WeatherText.zulu($0) }
        let legends = WeatherText.legends(on)
        return Notices(labels: labels, clock: clock, legend: clock == nil || legends.isEmpty ? nil : legends.joined(separator: "\n"),
                       radar: clock != nil && on.contains(.radar),
                       winds: clock != nil && on.contains(.winds) ? WindsMap.label(data.winds, level: a.level, at: a.now) : nil,
                       next: data.nextChange(on, after: a.now))
    }

    /// A listed notice; `note` says when its shape could not be read.
    struct Tfr: Encodable, Equatable { var title: String; var detail: String?; var levels: String?; var note: String? }

    struct Layers: Encodable {
        /// GeoJSON for each source of an overlay that is on.
        var sources: [String: String]
        /// Layers shown or hidden by what the station dot shows.
        var visible: [String: Bool]
        /// The newest radar picture to draw, nil when radar is off or not current.
        var radar: String?
        /// The satellite picture to draw, nil when satellite is off or not current.
        var satellite: String?
        var tfrsWithoutArea: [Tfr]
        /// The winds aloft level drawn: the pick or the default.
        var windsLevel: Int
    }

    /// What the weather layers draw now.
    func layers(_ a: ShowArgs) -> Layers {
        let on = Self.shown(a.on)
        let show = a.show.flatMap(StationShow.init(rawValue:)) ?? .category
        var sources: [String: String] = [:]
        for o in on where o != .radar && o != .satellite {
            sources[WeatherStyleJSON.sourceID(o)] = String(decoding: WeatherGeoJSON.overlay(o, data, show: show, windsLevel: a.level, now: a.now), as: UTF8.self)
        }
        let stations = on.contains(.stations)
        let tfrs = WeatherGeoJSON.tfrsWithoutArea(data.tfrs, now: a.now).map {
            Tfr(title: "TFR \($0.notam)", detail: $0.title ?? $0.name,
                levels: $0.unreadable ? nil : "\($0.lower?.text ?? "?") to \($0.upper?.text ?? "?")",
                note: $0.unreadable ? FlightCore.Tfr.unreadableNote : nil)
        }
        return Layers(sources: sources,
                      visible: ["wx-stations-cue": stations && show == .category, "wx-stations-wind": stations && show == .wind,
                                "wx-stations-value": stations && show != .category],
                      radar: on.contains(.radar) ? data.radarLoop(at: a.now).last?.file.path : nil,
                      satellite: on.contains(.satellite) ? data.satelliteShown(at: a.now)?.file.path : nil,
                      tfrsWithoutArea: on.contains(.tfrs) ? tfrs : [], windsLevel: a.level)
    }

    struct StationArgs: Decodable { var ident: String; var icao: String? }

    /// The newest raw TAF for an airport, and its newest METAR for the nav airportPage op.
    struct Station: Encodable { var lines: [String]; var metar: Metar? }

    /// Beside `FlightPlanArgs`: the W&B loading, and the device's UTC offset in seconds at departure.
    struct BriefArgs: Decodable {
        var weights: [Double]?
        var burned: Double?
        var localOffset: Int?
        /// Pack stores, the MapAssets folder and what __ASSETS__ becomes, for the map's base.
        var stores: [String]?
        var templates: String?
        var assets: String?
    }

    /// The route panel's plan with the winds and TAFs held here.
    func planView(_ a: Bridge.FlightPlanArgs) -> Bridge.PlanView? { Bridge.planView(a, winds: data.winds, tafs: data.tafs) }

    /// The W&B verdict for the loading sent, fuel burned defaulting as on the W&B screen.
    private func balance(_ plan: Bridge.FlightPlanArgs, _ a: BriefArgs, _ p: FlightPlan) -> WeightBalance? {
        plan.aircraft.flatMap { profile in
            a.weights.flatMap { WeightBalance(profile: profile, stationWeightsLb: $0, startFuelGal: plan.startFuel,
                                              burnedGal: a.burned ?? AircraftPages.burnedDefault(profile, tripFuelGal: p.fuel?.trip,
                                                                                                 startFuelGal: plan.startFuel,
                                                                                                 airborne: p.airborne)) }
        }
    }

    /// The printable nav log from the winds held here. Nil when no route is drawn.
    func navlog(_ plan: Bridge.FlightPlanArgs, _ a: BriefArgs) -> RoutePages.Navlog? {
        let position = Bridge.position(plan.fix), approximate = Bridge.approximate(plan.approximate, plan.fix)
        guard let page = RoutePages.planPage(plan.plan, position: position, approximate: approximate, now: plan.now,
                                             inputs: plan.inputs, trueAirspeedKt: plan.speedKt, burnGPH: plan.burnGPH,
                                             taxiFuelGal: plan.taxiGal, fuelOnBoardGal: plan.onBoardGal, winds: data.winds,
                                             tafs: data.tafs, destinationHasApproach: plan.hasApproach,
                                             vertical: plan.vertical) else { return nil }
        return RoutePages.navlog(plan.plan, page: page, position: position, approximate: approximate, now: plan.now,
                                 aircraft: plan.aircraft, balance: balance(plan, a, page.plan), localOffsetSeconds: a.localOffset,
                                 database: plan.navDatabase.flatMap { try? NavDatabase(path: $0) })
    }

    /// The brief from the weather held here. Nil when no route is drawn.
    func brief(_ plan: Bridge.FlightPlanArgs, _ a: BriefArgs) -> FlightBrief? {
        guard let (route, p) = Bridge.planned(plan, winds: data.winds, tafs: data.tafs) else { return nil }
        let balance = balance(plan, a, p)
        let base = a.assets.map { assets in
            BriefMapBase(installed: Bridge.charts(a.stores ?? []), streetTemplate: a.templates.flatMap { Bridge.read($0, "street-light.json") },
                         assets: assets)
        }
        return FlightBrief.make(route: route, inputs: plan.inputs, plan: p, aircraft: plan.aircraft, balance: balance,
                                weather: data, now: plan.now, localOffsetSeconds: a.localOffset,
                                database: plan.navDatabase.flatMap { try? NavDatabase(path: $0) }, mapBase: base)
    }

    func station(_ a: StationArgs) -> Station {
        let station = a.icao ?? a.ident
        let metar = data.metars.filter { $0.station == station }.max { $0.observed < $1.observed }
        let taf = data.tafs.filter { $0.station == station }.max { $0.issued < $1.issued }
        return Station(lines: [taf?.raw].compactMap { $0 }, metar: metar)
    }
}

/// The weather style, as iOS WeatherStyle draws it. Text uses the bundled fonts; the only images are the wind barbs.
enum WeatherStyleJSON {
    /// Bottom first. The radar picture goes in below the radar's own shading layer.
    /// The satellite picture goes in below its own empty anchor layer, so under everything else.
    static let drawn: [WeatherOverlay] = [.satellite, .radar, .gairmets, .sigmets, .cwas, .tfrs, .pireps, .lightning, .winds, .stations]
    static let radarGrid = (west: -130.0, south: 20.0, east: -60.0, north: 55.0)
    /// A station report this old missed its hourly successor, so its dot is faded.
    static let staleStationMinutes: JSON = 75
    static let frameID = "wx-radar-frame"
    static let shadingID = "wx-radar-outside"
    static let satelliteID = "wx-satellite-frame"
    static let satelliteAnchor = "wx-satellite-anchor"

    private static let regular: JSON = ["Noto Sans Regular"]
    private static let medium: JSON = ["Noto Sans Medium"]
    private static let polygons: JSON = ["==", "$type", "Polygon"]

    static func sourceID(_ overlay: WeatherOverlay) -> String { "wx-" + overlay.rawValue }

    /// The world with the radar grid cut out, shaded as no coverage while radar is on.
    static var radarOutside: JSON {
        let g = radarGrid
        let world: JSON = [[-180, -85], [180, -85], [180, 85], [-180, 85], [-180, -85]]
        let hole = JSON.array([(g.west, g.south), (g.west, g.north), (g.east, g.north), (g.east, g.south), (g.west, g.south)]
            .map { [.number($0.0), .number($0.1)] })
        return ["type": "Feature", "properties": [:], "geometry": ["type": "Polygon", "coordinates": [world, hole]]]
    }

    static var sources: [String: JSON] {
        Dictionary(uniqueKeysWithValues: drawn.map { o in
            (sourceID(o), ["type": "geojson", "data": ["type": "FeatureCollection", "features": .array(o == .radar ? [radarOutside] : [])]])
        })
    }

    private static func layer(_ id: String, _ type: String, _ source: String, minzoom: Double? = nil, filter: JSON? = nil,
                              layout: JSON? = nil, paint: JSON) -> JSON {
        var layer: JSON = ["id": .string(id), "type": .string(type), "source": .string(source), "paint": paint]
        if let minzoom { layer["minzoom"] = .number(minzoom) }
        if let filter { layer["filter"] = filter }
        if let layout { layer["layout"] = layout }
        return layer
    }

    private static func label(_ id: String, _ source: String, minzoom: Double, offset: Double? = nil) -> JSON {
        var layout: JSON = ["text-field": ["get", "label"], "text-font": regular, "text-size": 11]
        if let offset {
            layout["text-anchor"] = "top"
            layout["text-offset"] = [0, .number(offset)]
        }
        return layer(id, "symbol", source, minzoom: minzoom, layout: layout,
                     paint: ["text-color": "#111111", "text-halo-color": "#ffffff", "text-halo-width": 1.5])
    }

    /// The rounded image the app stretches behind station text, as iOS WeatherStyle.pill.
    static let pill = "wx-label-pill"

    /// Station text on the pill instead of a halo. It still collides, so labels never pile up.
    /// Glyph boxes already carry room above and below, so the padding trims height and adds width.
    private static func onPill(_ id: String, _ source: String, minzoom: Double, field: String, size: Double,
                               place: [String: JSON]) -> JSON {
        var layout: JSON = ["text-field": ["get", .string(field)], "text-font": medium, "text-size": .number(size),
                            "icon-image": .string(pill), "icon-text-fit": "both", "icon-text-fit-padding": [-1, 3, -1, 3]]
        for (key, value) in place { layout[key] = value }
        return layer(id, "symbol", source, minzoom: minzoom, layout: layout, paint: ["text-color": "#111111"])
    }

    /// Short letters on a point, never hidden by another label.
    private static func letters(_ id: String, _ source: String, field: String, size: Double, paint: JSON) -> JSON {
        layer(id, "symbol", source, minzoom: 5,
              layout: ["text-field": ["get", .string(field)], "text-font": medium, "text-size": .number(size),
                       "text-allow-overlap": true, "text-ignore-placement": true],
              paint: paint)
    }

    /// Fill, outline and label for an area. A dash pattern keeps kinds apart without color.
    private static func areaLayers(_ source: String, color: String, opacity: Double, width: Double, dash: JSON?) -> [JSON] {
        var line: JSON = ["line-color": .string(color), "line-width": .number(width)]
        if let dash { line["line-dasharray"] = dash }
        return [
            layer("\(source)-fill", "fill", source, filter: polygons, paint: ["fill-color": .string(color), "fill-opacity": .number(opacity)]),
            layer("\(source)-line", "line", source, paint: line),
            label("\(source)-label", source, minzoom: 5),
        ]
    }

    static func layers(for overlay: WeatherOverlay) -> [JSON] {
        let source = sourceID(overlay)
        let red: JSON = "#d32020"
        switch overlay {
        case .satellite:
            return [layer(satelliteAnchor, "fill", source, paint: ["fill-opacity": 0])]
        case .lightning:
            // Newest flashes brightest and largest.
            let color = JSON.array(["step", ["get", "age_min"], .string(LightningStyle.ages[0].color)]
                + LightningStyle.ages.dropFirst().flatMap { [.number(Double($0.minutes)), .string($0.color)] as [JSON] })
            func size(_ scale: Double) -> JSON { ["step", ["get", "age_min"], .number(4 * scale), 5, .number(3.2 * scale), 15, .number(2.5 * scale)] }
            return [layer("wx-lightning-dot", "circle", source,
                          paint: ["circle-color": color,
                                  "circle-radius": ["interpolate", ["linear"], ["zoom"], 4, size(1), 9, size(1.8)],
                                  "circle-stroke-color": "#111111", "circle-stroke-width": 0.8])]
        case .radar:
            return [layer(shadingID, "fill", source,
                          paint: ["fill-color": .string(RadarStyle.noCoverage.color), "fill-opacity": .number(RadarStyle.noCoverage.opacity)])]
        case .gairmets:
            return areaLayers(source, color: "#7a4fc0", opacity: 0.08, width: 1.5, dash: [4, 3])
        case .sigmets:
            return areaLayers(source, color: "#d98400", opacity: 0.15, width: 2.5, dash: nil)
        case .cwas:
            return areaLayers(source, color: "#00838f", opacity: 0.12, width: 2, dash: [6, 2])
        case .tfrs:
            let active: JSON = ["==", "status", "active"]
            return [
                layer("wx-tfrs-fill", "fill", source, filter: ["all", polygons, active], paint: ["fill-color": red, "fill-opacity": 0.12]),
                layer("wx-tfrs-line", "line", source, filter: active, paint: ["line-color": red, "line-width": 2.5]),
                // Not yet in effect: an outline only, dashed.
                layer("wx-tfrs-upcoming", "line", source, filter: ["==", "status", "upcoming"],
                      paint: ["line-color": red, "line-width": 1.5, "line-dasharray": [2, 3]]),
                label("wx-tfrs-label", source, minzoom: 6),
            ]
        case .pireps:
            return [
                letters("wx-pireps-type", source, field: "type", size: 12,
                        paint: ["text-color": ["match", ["get", "type"], "UUA", red, "#111111"], "text-halo-color": "#ffffff", "text-halo-width": 2]),
                label("wx-pireps-label", source, minzoom: 8, offset: 0.9),
            ]
        case .winds:
            // One SDF barb per 5 kt bucket, turned toward where the wind comes from.
            return [
                layer("wx-winds-barb", "symbol", source,
                      layout: ["icon-image": ["get", "barb"], "icon-rotate": ["get", "rotate"],
                               "icon-rotation-alignment": "map", "icon-allow-overlap": true, "icon-ignore-placement": true,
                               "icon-size": ["interpolate", ["linear"], ["zoom"], 3, 0.6, 8, 0.9]],
                      paint: ["icon-color": "#111111", "icon-halo-color": "#ffffff", "icon-halo-width": 1.5]),
                layer("wx-winds-label", "symbol", source, minzoom: 6,
                      layout: ["text-field": ["get", "label"], "text-font": medium, "text-size": 11,
                               "text-anchor": "top", "text-offset": [0, 0.6]],
                      paint: ["text-color": "#111111", "text-halo-color": "#ffffff", "text-halo-width": 1.5]),
            ]
        case .stations:
            let color: JSON = ["match", ["get", "cat"], "VFR", "#1a8f3c", "MVFR", "#1f5fd0", "IFR", red, "LIFR", "#b0189e", "#6b6b6b"]
            let faded: JSON = ["step", ["get", "age_min"], 1, staleStationMinutes, 0.45]
            return [
                layer("wx-stations-dot", "circle", source, minzoom: 5,
                      paint: ["circle-radius": 9, "circle-color": color, "circle-opacity": faded,
                              "circle-stroke-color": "#ffffff", "circle-stroke-width": 1.5, "circle-stroke-opacity": faded]),
                // The letter is drawn from the same zoom as the dot, so color is never the only cue.
                letters("wx-stations-cue", source, field: "cue", size: 11, paint: ["text-color": "#ffffff", "text-opacity": faded]),
                // A chevron on the dot points downwind; the bundled font has no arrow glyph.
                layer("wx-stations-wind", "symbol", source, minzoom: 5, filter: [">=", "dir", 0],
                      layout: ["text-field": ">", "text-font": medium, "text-size": 15,
                               "text-rotate": ["+", ["get", "dir"], 90], "text-rotation-alignment": "map",
                               "text-allow-overlap": true, "text-ignore-placement": true],
                      paint: ["text-color": "#ffffff", "text-opacity": faded]),
                onPill("wx-stations-value", source, minzoom: 5, field: "value", size: 13,
                       place: ["text-anchor": "left", "text-offset": [1.3, 0]]),
                onPill("wx-stations-label", source, minzoom: 8, field: "label", size: 12,
                       place: ["text-anchor": "top", "text-offset": [0, 1.9]]),
            ]
        }
    }

    static func layerIDs(_ overlays: [WeatherOverlay]) -> [String] {
        overlays.flatMap(layers(for:)).compactMap { $0["id"]?.string }
    }

    /// The style with the weather sources and layers on top, in night ink when asked.
    static func merge(into style: inout JSON, night: Bool, assets: String) {
        if style["glyphs"] == nil { style["glyphs"] = .string(assets + "/fonts/{fontstack}/{range}.pbf") }
        var all: [String: JSON] = [:]
        if case .object(let s) = style["sources"] ?? [:] { all = s }
        for (id, source) in sources { all[id] = source }
        style["sources"] = .object(all)
        var layers: [JSON] = []
        if case .array(let list) = style["layers"] ?? [] { layers = list }
        layers += drawn.flatMap(layers(for:)).map { night ? NightInk.inked($0) : $0 }
        style["layers"] = .array(layers)
    }
}

extension Bridge {
    struct WeatherCatalog: Encodable {
        struct Choice: Encodable { var id: String; var title: String }
        struct Band: Encodable { var dbz: Double; var color: String }
        var title = "Weather"
        var toggles: [Catalog.Group]
        /// The TFR switch, which goes at the end of the Aeronautical group.
        var tfrs: Catalog.Group
        /// Switches kept across launches.
        var saved = WeatherSwitches.saved.sorted()
        var stationsID = "weather-stations"
        var showTitle = "Dot shows"
        var showKey = StationShow.key
        var shows = StationShow.allCases.map { Choice(id: $0.rawValue, title: $0.title) }
        var tfrsID = WeatherSwitches.tfrsID
        var tfrListTitle = FlightCore.Tfr.listTitle
        /// Put before the count, as in "3 not drawn on the map".
        var tfrCountSuffix = " not drawn on the map"
        var refreshSeconds = WeatherPolicy.refreshInterval
        var passLimitSeconds = WeatherPolicy.passLimit
        var indexPath = WeatherPolicy.indexPath
        var frameID = WeatherStyleJSON.frameID
        var shadingID = WeatherStyleJSON.shadingID
        var satelliteID = WeatherStyleJSON.satelliteID
        var satelliteAnchor = WeatherStyleJSON.satelliteAnchor
        var satelliteOpacity = SatelliteStyle.opacity
        var noCoverageColor = RadarStyle.noCoverage.color
        var noCoverageOpacity = RadarStyle.noCoverage.opacity
        var echoOpacity = RadarStyle.echoOpacity
        var bands = RadarStyle.bands.map { Band(dbz: $0.dbz, color: $0.color) }
        var stationLayer = "wx-stations-dot"
        var windsID = WindsMap.switchID
        var windsLevelTitle = WindsMap.levelTitle
        var windsLevelKey = WindsMap.levelKey
        var windsLevels = WindsMap.levels.map { Level(ft: $0, title: WindsMap.title($0)) }
        /// The barb icons to draw into the style as SDF images.
        var barbs = WindBarb.drawings
        struct Level: Encodable { var ft: Int; var title: String }
    }

    /// A switch with the style layers it shows and hides.
    static func toggle(_ t: (id: String, title: String, overlays: [WeatherOverlay])) -> Catalog.Group {
        // Station layers that follow the dot choice are shown by the layers op.
        let chosen: Set = ["wx-stations-cue", "wx-stations-wind", "wx-stations-value"]
        return .init(id: t.id, title: t.title, startsOn: false,
                     layers: WeatherStyleJSON.layerIDs(t.overlays).filter { !chosen.contains($0) } + (t.overlays.contains(.radar) ? [WeatherStyleJSON.frameID] : [])
                         + (t.overlays.contains(.satellite) ? [WeatherStyleJSON.satelliteID] : []))
    }

    static var weatherCatalog: WeatherCatalog {
        let tfrs = WeatherSwitches.toggles.filter { $0.id == WeatherSwitches.tfrsID }.map(toggle)
        return WeatherCatalog(toggles: WeatherSwitches.toggles.filter { $0.id != WeatherSwitches.tfrsID }.map(toggle), tfrs: tfrs[0])
    }

    static func weatherCall(_ s: WeatherSession, _ op: String, _ args: Data) throws -> any Encodable {
        func arg<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: args) }
        struct IndexArgs: Decodable { var reply: WeatherSession.Reply; var now: Date }
        struct NowArgs: Decodable { var now: Date }
        switch op {
        case "index":
            let a = try arg(IndexArgs.self)
            return s.index(a.reply, now: a.now)
        case "source": s.source(try arg(WeatherSession.SourceArgs.self)); return Empty()
        case "frame": return ["kept": s.frame(try arg(WeatherSession.FrameArgs.self))]
        case "loopStart": return ["fetch": s.loopStart(now: try arg(NowArgs.self).now)]
        case "loopFrame": return ["kept": s.loopFrame(try arg(WeatherSession.FrameArgs.self))]
        case "loopPlay": return ["frames": s.loopPlay(now: try arg(NowArgs.self).now)]
        case "loopStop": s.stopLoop(); return Empty()
        case "notices": return s.notices(try arg(WeatherSession.ShowArgs.self))
        case "layers": return s.layers(try arg(WeatherSession.ShowArgs.self))
        case "station": return s.station(try arg(WeatherSession.StationArgs.self))
        case "flightBrief": return s.brief(try arg(FlightPlanArgs.self), try arg(WeatherSession.BriefArgs.self))
        case "navlog": return s.navlog(try arg(FlightPlanArgs.self), try arg(WeatherSession.BriefArgs.self))
        case "planView": return s.planView(try arg(FlightPlanArgs.self))
        default: throw Failure.unknownOp(op)
        }
    }
}
