import FlightCore

/// Map ops: the style to load, notices over it, coverage, the layer list, fixes and the tracking button.
extension Bridge {
    struct FileRef: Codable, Equatable { var identifier: String; var path: String }

    struct StyleArgs: Decodable {
        var base: String
        var night: Bool
        var now: Date
        /// Pack store folders whose packs the map may draw.
        var stores: [String]
        var navStore: String?
        /// Folder holding the style files from MapAssets.
        var templates: String
        /// What __ASSETS__ becomes, such as asset:/ so glyphs read asset://fonts/...
        var assets: String
        /// What the map showed when the camera last settled; picks the street packs.
        var view: MapStyleSpec.Box?
        var online: Bool?
    }

    struct StyleResult: Encodable {
        var style: String
        /// Chart files drawn, for the coverage check.
        var rasters: [FileRef]
        /// Words in the middle of the map when it has nothing to draw.
        var notice: String?
        var credit: String?
        var creditLink: String?
        var navDatabase: String?
        var navTiles: String?
        var overlay: Bool
        /// Night paint for rasters drawn over the base, such as a plate: [brightness min, brightness max, hue rotate].
        var rasterPaint: [Double]
    }

    static let aerialTiles = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}"

    static func base(_ name: String) throws -> BaseLayer {
        guard let base = BaseLayer(rawValue: name) else { throw Failure.unknownOp("base \(name)") }
        return base
    }

    static func charts(_ stores: [String]) -> [PackFile] { stores.flatMap(PackSession.installedFiles(root:)) }

    /// The navigation database in use and the tile file of its cycle.
    static func navFiles(_ store: String?, now: Date) -> (database: String, tiles: String?)? {
        guard let store else { return nil }
        let files = PackSession.installedFiles(root: store)
        guard let shown = ChartLibrary.packToShow(layer: DownloadPolicy.navDatabaseLayer, region: DownloadPolicy.navRegion,
                                                  installed: files.map(\.pack), now: now),
              let database = files.first(where: { $0.pack == shown }) else { return nil }
        let tiles = PackID(cycle: shown.id.cycle, layer: DownloadPolicy.navTilesLayer, region: DownloadPolicy.navRegion)
        return (database.url.path, files.first { $0.pack.id == tiles }?.url.path)
    }

    static func read(_ folder: String, _ name: String) -> String? {
        FileManager.default.contents(atPath: folder + "/" + name).map { String(decoding: $0, as: UTF8.self) }
    }

    static func style(_ a: StyleArgs) throws -> StyleResult {
        let base = try base(a.base)
        let made = MapStyleSpec.make(base: base, installed: charts(a.stores), night: a.night, now: a.now,
                                     view: a.view, bounds: PackCoverage.bounds)
        let nav = navFiles(a.navStore, now: a.now)
        let navText = nav?.tiles.flatMap { tiles in
            read(a.templates, "nav-style.json")?.replacing("__NAV__", with: "pmtiles://file://" + tiles)
        }
        var streetText: String?
        if case .street(let packs) = made.content,
           let text = read(a.templates, a.night ? "street-dark.json" : "street-light.json") {
            streetText = try? MapStyleSpec.streetStyle(template: text, assets: a.assets, packs: packs,
                                                       overlay: navText, night: a.night)
        }
        let spec = made.resolved(streetStyle: streetText.map { _ in URL(fileURLWithPath: a.templates) })
        let text = streetText ?? navText?.replacing("__ASSETS__", with: a.assets)
        let overlay = navText != nil
        var style = try decoder.decode(JSON.self, from: Data((text ?? read(a.templates, "empty.json") ?? "{}").utf8))

        var rasters: [FileRef] = []
        var sources: [(String, JSON)] = []
        // Tile size 256 makes a pack's top zoom show 1.5 camera zooms earlier than 512 would.
        func packs(_ list: [MapStyleSpec.Raster]) -> [(String, JSON)] {
            list.map { ($0.identifier, .object(["type": .string("raster"), "tileSize": .number(256),
                                                "url": .string("pmtiles://file://" + $0.url.path)])) }
        }
        var basePaint: NightPaint.Values?
        switch spec.content {
        case .charts(let list):
            rasters = list.map { FileRef(identifier: $0.identifier, path: $0.url.path) }
            sources = packs(list)
            basePaint = NightPaint.values(night: a.night)
        case .terrain(let list):
            sources = packs(list)
            basePaint = NightPaint.terrainValues(night: a.night)
        case .aerial:
            sources = [("aerial", .object(["type": .string("raster"), "tileSize": .number(256), "maxzoom": .number(16),
                                           "tiles": .array([.string(aerialTiles)])]))]
        case .street, .nothing:
            break
        }
        let paint = NightPaint.values(night: a.night)
        if streetText == nil, case .array(var layers) = style["layers"] {
            let white = Int(NightPaint.backgroundWhite(night: a.night) * 255)
            let level = String(white, radix: 16)
            let hex = "#" + String(repeating: (level.count < 2 ? "0" : "") + level, count: 3)
            layers = layers.map { layer in
                var layer = layer
                if layer["id"]?.string == "background" {
                    layer["paint"] = .object(["background-color": .string(hex)])
                } else if a.night {
                    layer = NightInk.inked(layer)
                }
                return layer
            }
            // Base rasters sit straight above the background, under everything else.
            let rasterLayers: [JSON] = sources.map { id, _ in
                var p: [String: JSON] = ["raster-fade-duration": .number(0)]
                if let basePaint {
                    p["raster-brightness-min"] = .number(basePaint.minimumBrightness)
                    p["raster-brightness-max"] = .number(basePaint.maximumBrightness)
                    p["raster-hue-rotate"] = .number(basePaint.hueRotation)
                }
                return .object(["id": .string(id), "type": .string("raster"), "source": .string(id), "paint": .object(p)])
            }
            layers.insert(contentsOf: rasterLayers, at: min(1, layers.count))
            style["layers"] = .array(layers)
            if case .object(var s) = style["sources"] ?? .object([:]) {
                for (id, source) in sources { s[id] = source }
                style["sources"] = .object(s)
            }
        }

        WeatherStyleJSON.merge(into: &style, night: a.night, assets: a.assets)

        var notice: String?
        if case .nothing(let words) = spec.content { notice = words }
        if base == .aerial, a.online == false { notice = "Aerial imagery needs an internet connection" }
        // Every base carries the OpenStreetMap credit: the street map, or the airports' taxiways and buildings.
        let osm = "© OpenStreetMap"
        let credit: (String, String?)? = switch base {
        case .aerial: ("USGS The National Map: Orthoimagery · " + osm, "https://www.openstreetmap.org/copyright")
        case .terrain: (MapStyleSpec.terrainCredit + " · " + osm, "https://www.openstreetmap.org/copyright")
        default: (osm, "https://www.openstreetmap.org/copyright")
        }
        return StyleResult(style: String(decoding: try encoder.encode(style), as: UTF8.self), rasters: rasters,
                           notice: notice, credit: credit?.0, creditLink: credit?.1, navDatabase: nav?.database, navTiles: nav?.tiles,
                           overlay: overlay, rasterPaint: [paint.minimumBrightness, paint.maximumBrightness, paint.hueRotation])
    }

    struct StreetArgs: Decodable { var stores: [String]; var now: Date; var view: MapStyleSpec.Box? }

    /// The street packs a view shows, as one key: a settled view changes the street style only when the key changes.
    static func streetKey(_ a: StreetArgs) -> [String: String] {
        let made = MapStyleSpec.make(base: .street, installed: charts(a.stores), night: false, now: a.now, view: a.view,
                                     bounds: PackCoverage.bounds)
        guard case .street(let packs) = made.content else { return ["key": ""] }
        return ["key": packs.map(\.path).joined(separator: "\n")]
    }

    struct NoticeArgs: Decodable {
        var base: String
        var stores: [String]
        var now: Date
        var nav: NavState?
        var overlayWanted: Bool
        var center: Coordinate?
        /// The plates pack store folder.
        var plates: String?

        struct NavState: Decodable {
            var cycle: String?
            var effective: Date?
            var expires: Date?
            var unreadable: Bool
            var hasTiles: Bool
        }
    }

    struct Notices: Encodable {
        var banner: String?
        var nav: String?
        /// The same banner for the plates, shown over the procedures and the chart.
        var plates: String?
        /// When any of them can next change with nothing else changing. Nil for never.
        var next: Date?
    }

    /// The amber chart and plates banners and the navigation data notice.
    static func notices(_ a: NoticeArgs) throws -> Notices {
        let base = try base(a.base)
        let packs = charts(a.stores)
        let plates = a.plates.map { PackSession.installedFiles(root: $0).map(\.pack) } ?? []
        var out = Notices()
        out.banner = MapPlan.banner(MapPlan.currency(layers: base.packLayers, installed: packs.map(\.pack), now: a.now))
        out.plates = MapPlan.banner(MapPlan.currency(layers: [PlateLibrary.layer], installed: plates, now: a.now),
                                    subject: PlateLibrary.subject)
        let metadata = a.nav.flatMap { n -> NavMetadata? in
            guard let cycle = n.cycle, let effective = n.effective, let expires = n.expires else { return nil }
            return NavMetadata(schemaVersion: 0, cycle: cycle, effective: effective, expires: expires, builtAt: effective)
        }
        out.nav = NavText.mapNotice(metadata: metadata, unreadable: a.nav?.unreadable ?? false,
                                    hasTiles: a.nav?.hasTiles ?? false, overlayWanted: a.overlayWanted, now: a.now)
        out.next = NextChange.earliest(after: a.now, [
            MapPlan.nextChange(layers: base.packLayers, installed: packs.map(\.pack), after: a.now),
            MapPlan.nextChange(layers: [PlateLibrary.layer], installed: plates, after: a.now),
            metadata?.nextChange(after: a.now)])
        return out
    }

    struct GapArgs: Decodable { var rasters: [FileRef]; var latitude: Double; var longitude: Double; var zoom: Double }

    static func gap(_ coverage: PackCoverage, _ a: GapArgs) -> [String: String] {
        // The wide-area pack under the state packs is too coarse to stand in for them up close.
        let overviews = a.rasters.filter { $0.identifier.hasSuffix(":" + ChartLibrary.overviewRegion) }
        let files = a.rasters.map { URL(fileURLWithPath: $0.path) }
        let text = coverage.gap(files, overviews: Set(overviews.map { URL(fileURLWithPath: $0.path) }),
                                latitude: a.latitude, longitude: a.longitude, zoom: a.zoom)?.text
        return text.map { ["text": $0] } ?? [:]
    }

    struct Catalog: Encodable {
        struct Base: Encodable { var id: String; var title: String }
        struct Group: Encodable { var id: String; var title: String; var startsOn: Bool; var layers: [String] }
        var bases: [Base]
        var title: String
        var overlays: [Group]
        var traffic = Group(id: TrafficStore.switchID, title: TrafficStore.layerGroup.title, startsOn: true, layers: TrafficStore.layers)
        /// Where the map setup is stored.
        var memoryKey = MapMemory.key
        var menu = Menu()
        /// The aerial imagery's top tile, asked for to learn whether the service answers.
        var aerialProbe = aerialTiles.replacing("{z}/{y}/{x}", with: "0/0/0")
    }

    /// The picker's order and grouping. A row is a switch id or a station dot readout.
    struct Menu: Encodable {
        struct Row: Encodable { var id: String?; var station: String? }
        struct Section: Encodable {
            var title: String?
            var rows: [Row]
            init(_ s: LayerMenu.Section) {
                title = s.title
                rows = s.rows.map {
                    switch $0 {
                    case .overlay(let id): Row(id: id)
                    case .station(let show): Row(station: show.rawValue)
                    }
                }
            }
        }
        var bases = LayerMenu.bases.map { $0.map(\.rawValue) }
        var aeronautical = Section(LayerMenu.aeronautical)
        var overlays = LayerMenu.overlays.map(Section.init)
        var onMap = LayerMenu.onMap
        var removeAll = LayerMenu.removeAll
    }

    static var catalog: Catalog {
        Catalog(bases: BaseLayer.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                title: AeronauticalLayers.layerGroup.title,
                overlays: AeronauticalLayers.groups.map { .init(id: $0.id, title: $0.title, startsOn: $0.startsOn, layers: $0.layers) })
    }

    struct Fix: Decodable {
        var latitude: Double
        var longitude: Double
        var course: Double
        var speed: Double
        /// Meters above MSL.
        var altitude: Double?
        /// Meters above the WGS-84 ellipsoid, sent in place of `altitude` when the device has no MSL height.
        var ellipsoidAltitude: Double?
        var time: Date
        /// Horizontal error in meters; nil when unknown.
        var accuracy: Double?
    }

    /// A coarse-only grant, or a fix too wide to place the aircraft on a chart, reads as approximate.
    static func approximate(_ granted: Bool?, _ fix: Fix?) -> Bool {
        (granted ?? false) || (fix?.accuracy ?? 0) > Position.approximateBeyondMeters
    }

    struct PositionArgs: Decodable {
        var fix: Fix?
        var now: Date
        var approximate: Bool?
        var accessOff: Bool?
        var following: Bool
        var orientation: String
        var heading: Double
        var zoom: Double
        var zoomedToFirstFix: Bool
    }

    struct PositionResult: Encodable {
        struct Strip: Encodable { var groundspeed: String; var track: String; var altitude: String; var message: String? }
        struct Ownship: Encodable { var latitude: Double; var longitude: Double; var track: Double; var image: String }
        struct Camera: Encodable { var latitude: Double?; var longitude: Double?; var heading: Double; var zoom: Double? }
        var strip: Strip
        var ownship: Ownship?
        /// Where to move the camera now. Nil leaves it alone.
        var camera: Camera?
        /// When the strip's numbers go to dashes if no new fix comes. Nil with no live fix.
        var staleAt: Date?
    }

    /// Everything one fix changes: the strip text, the aircraft symbol and the camera.
    static func position(_ a: PositionArgs) -> PositionResult {
        let orientation = MapOrientation(rawValue: a.orientation) ?? .northUp
        let fix = position(a.fix), approximate = Bridge.approximate(a.approximate, a.fix)
        let r = NavText.readout(for: fix, accessOff: a.accessOff ?? false, approximate: approximate, now: a.now)
        let unit = { (value: String, unit: String) in value == NavText.dashes ? value : value + unit }
        let strip = PositionResult.Strip(groundspeed: unit(r.groundspeed, " kt"), track: r.track,
                                         altitude: unit(r.altitude, " ft"), message: r.message)
        guard let fix else {
            return PositionResult(strip: strip, camera: orientation == .northUp ? .init(heading: 0) : nil)
        }
        let ownship = PositionResult.Ownship(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                             track: fix.trackTrue ?? 0,
                                             image: MapPlan.ownshipImage(for: fix, approximate: approximate, now: a.now))
        let heading = MapPlan.heading(for: fix, orientation: orientation, current: a.heading)
        let camera: PositionResult.Camera? = a.following
            ? .init(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, heading: heading,
                    zoom: MapPlan.firstFixZoom(current: a.zoom, alreadyZoomed: a.zoomedToFirstFix))
            : heading == a.heading ? nil : .init(heading: heading)
        return PositionResult(strip: strip, ownship: ownship, camera: camera,
                              staleAt: fix.isStale(at: a.now) ? nil : fix.staleAt)
    }

    /// tap false names the given state without moving on.
    struct TrackingArgs: Decodable { var following: Bool; var orientation: String; var tap: Bool? }
    struct TrackingResult: Encodable { var following: Bool; var orientation: String; var label: String }

    /// The tracking button's next state after a tap.
    static func tracking(_ a: TrackingArgs) -> TrackingResult {
        let given = (following: a.following, orientation: MapOrientation(rawValue: a.orientation) ?? .northUp)
        let next = a.tap == false ? given : MapPlan.nextTracking(following: given.following, orientation: given.orientation)
        return TrackingResult(following: next.following, orientation: next.orientation.rawValue,
                              label: MapPlan.trackingLabel(following: next.following, orientation: next.orientation))
    }

    /// A place, where it is drawn now, the part of the map no panel covers and the whole map, all in dp.
    struct RevealArgs: Decodable {
        var place: Coordinate; var x: Double; var y: Double; var open: ScreenRect; var width: Double; var height: Double
        var zoom: Double; var bearing: Double; var force: Bool?
    }

    /// Where to ease the camera so an open panel's place sits clear of it. An empty object leaves the map alone.
    static func reveal(_ a: RevealArgs) -> [String: MapReveal.Camera] {
        MapReveal.camera(place: a.place, at: ScreenPoint(x: a.x, y: a.y), open: a.open,
                         size: ScreenPoint(x: a.width, y: a.height), zoom: a.zoom, bearing: a.bearing,
                         force: a.force ?? false).map { ["camera": $0] } ?? [:]
    }

    /// The saved setup's text, and the launch options that win over it.
    struct LaunchArgs: Decodable {
        var saved: String?
        var base: String?
        var night: Bool?
        var orientation: String?
        var center: Coordinate?
        var zoom: Double?
        var follow: Bool
    }
    struct LaunchResult: Encodable {
        var base: String
        var night: Bool
        var orientation: String
        var following: Bool
        var label: String
        var camera: MapMemory.Camera
        var route: String?
        var plates: [MapMemory.PlacedPlate]
    }

    /// The saved map setup with launch options laid over it: the first map state.
    static func launch(_ a: LaunchArgs) -> LaunchResult {
        let m = MapMemory(text: a.saved).launched(base: a.base.flatMap(BaseLayer.init(rawValue:)), night: a.night,
                                                  orientation: a.orientation.flatMap(MapOrientation.init(rawValue:)),
                                                  center: a.center, zoom: a.zoom, follow: a.follow)
        return LaunchResult(base: m.base.rawValue, night: m.night, orientation: m.orientation.rawValue, following: m.following,
                            label: MapPlan.trackingLabel(following: m.following, orientation: m.orientation),
                            camera: m.camera, route: m.route, plates: m.plates)
    }

    /// The map setup as it stands, as the text to store under MapMemory.key.
    static func mapMemory(_ m: MapMemory) -> [String: String] { ["text": m.text] }
}
