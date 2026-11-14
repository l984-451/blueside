/// The base map choices. Raw values are the names used in launch options.
public enum BaseLayer: String, CaseIterable, Sendable {
    case vfr
    case vfrFlyway = "vfr-flyway"
    case ifrLow = "ifr-low"
    case ifrHigh = "ifr-high"
    case street
    case aerial
    case terrain

    /// Chart pack layers drawn for this base, bottom first.
    public var packLayers: [String] {
        switch self {
        case .vfr: ["vfr", "vfr-tac"]
        case .vfrFlyway: ["vfr-flyway"]
        case .ifrLow: ["ifr-low", "ifr-area"]
        case .ifrHigh: ["ifr-high"]
        case .street, .aerial, .terrain: []
        }
    }

    /// The name the layer picker and the empty map use.
    public var title: String {
        switch self {
        case .vfr: "VFR chart"
        case .vfrFlyway: "VFR Flyway"
        case .ifrLow: "IFR Low chart"
        case .ifrHigh: "IFR High chart"
        case .street: "Street map"
        case .aerial: "Aerial imagery"
        case .terrain: "Terrain map"
        }
    }
}

public enum MapOrientation: String, CaseIterable, Sendable {
    case northUp
    case trackUp
}

/// An installed pack and the file that holds it.
public struct PackFile: Equatable, Sendable {
    public var pack: InstalledPack
    public var url: URL

    public init(pack: InstalledPack, url: URL) {
        self.pack = pack
        self.url = url
    }
}


/// What the map should draw for one base layer. Plain data, so it is tested without a map.
public struct MapStyleSpec: Equatable, Sendable {
    public struct Raster: Equatable, Sendable {
        public var identifier: String
        public var url: URL

        public init(identifier: String, url: URL) {
            self.identifier = identifier
            self.url = url
        }
    }

    public enum Content: Equatable, Sendable {
        /// Chart packs, bottom first.
        case charts([Raster])
        /// Nothing to draw. The text is shown in the middle of the map.
        case nothing(String)
        /// Street packs, at most `streetLimit`, in pack order.
        case street([URL])
        case aerial
        /// Terrain packs, one per state, drawn like charts but dimmed rather than inverted at night.
        case terrain([Raster])
    }

    public var content: Content
    public var night: Bool

    public init(content: Content, night: Bool) {
        self.content = content
        self.night = night
    }

    public static let streetLayer = "street"
    public static let terrainLayer = "terrain"
    public static let terrainCredit = "Elevation: Mapzen, USGS, NASA"

    /// A pack's extent in degrees.
    public struct Box: Equatable, Sendable, Codable {
        public var minLatitude, minLongitude, maxLatitude, maxLongitude: Double

        public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
            (self.minLatitude, self.minLongitude) = (minLatitude, minLongitude)
            (self.maxLatitude, self.maxLongitude) = (maxLatitude, maxLongitude)
        }

        func meets(_ other: Box) -> Bool {
            minLatitude <= other.maxLatitude && other.minLatitude <= maxLatitude
                && minLongitude <= other.maxLongitude && other.minLongitude <= maxLongitude
        }
    }

    /// Most street packs drawn at once; each one repeats every street layer.
    public static let streetLimit = 4

    /// view and bounds pick the street packs; with no view the first pack is shown.
    public static func make(base: BaseLayer, installed: [PackFile], night: Bool, now: Date,
                     view: Box? = nil, bounds: (URL) -> Box? = { _ in nil }) -> MapStyleSpec {
        switch base {
        case .aerial:
            return MapStyleSpec(content: .aerial, night: night)
        case .terrain:
            let shown = rasters(layer: terrainLayer, installed: installed, now: now)
            return MapStyleSpec(content: shown.isEmpty ? .nothing("No terrain map downloaded") : .terrain(shown), night: night)
        case .street:
            let shown = streetPacks(rasters(layer: streetLayer, installed: installed, now: now), view: view, bounds: bounds)
            return MapStyleSpec(content: shown.isEmpty ? .nothing("No street map downloaded") : .street(shown.map(\.url)),
                                night: night)
        case .vfr, .vfrFlyway, .ifrLow, .ifrHigh:
            let shown = base.packLayers.flatMap { rasters(layer: $0, installed: installed, now: now) }
            let name = base.title
            return MapStyleSpec(content: shown.isEmpty ? .nothing("No \(name) downloaded") : .charts(shown),
                                night: night)
        }
    }

    /// A street base whose style file could not be made becomes a label, so the map is never gray with no words.
    public func resolved(streetStyle: URL?) -> MapStyleSpec {
        if case .street = content, streetStyle == nil {
            return MapStyleSpec(content: .nothing("Street map unavailable"), night: night)
        }
        return self
    }

    /// Every pack whose box meets the view, nearest its middle first up to the limit, kept in pack order.
    /// With none in view, the nearest one, so the map past a pack's edge is not blank.
    public static func streetPacks(_ packs: [Raster], view: Box?, bounds: (URL) -> Box?) -> [Raster] {
        guard let view else { return Array(packs.prefix(1)) }
        let middle = Coordinate(latitude: (view.minLatitude + view.maxLatitude) / 2,
                                longitude: (view.minLongitude + view.maxLongitude) / 2)
        func key(_ pack: Raster) -> (Double, Double) {
            guard let box = bounds(pack.url) else { return (.infinity, .infinity) }
            let north = max(box.minLatitude - middle.latitude, 0, middle.latitude - box.maxLatitude)
            let east = max(box.minLongitude - middle.longitude, 0, middle.longitude - box.maxLongitude)
                * cos(middle.latitude * .pi / 180)
            let area = (box.maxLatitude - box.minLatitude) * (box.maxLongitude - box.minLongitude)
            return (north * north + east * east, area)
        }
        let inView = packs.filter { bounds($0.url)?.meets(view) == true }
        let chosen = (inView.isEmpty ? packs : inView).sorted { key($0) < key($1) }
            .prefix(inView.isEmpty ? 1 : streetLimit)
        return packs.filter(chosen.contains)
    }

    /// The street style for the packs: one source per pack, every street layer repeated per source in style order.
    /// Packs share their border tiles, so the copies draw the same lines there and label collision keeps one of each label.
    /// `overlay` is the nav style with its tiles filled in; its layers go in so the street map carries them too.
    public static func streetStyle(template: String, assets: String, packs: [URL],
                                   overlay: String? = nil, night: Bool = false) throws -> String {
        var style = try JSONDecoder().decode(JSON.self, from: Data(template.replacing("__ASSETS__", with: assets).utf8))
        guard case .object(let sources)? = style["sources"], case .array(var layers)? = style["layers"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "street style has no sources or layers"))
        }
        // The first pack keeps the template's names, so one pack gives the template as written.
        func named(_ name: String, _ index: Int) -> String { index == 0 ? name : "\(name)~\(index)" }
        func isPack(_ source: String?) -> Bool { source.flatMap { sources[$0]?["url"]?.string } == "__PMTILES__" }
        var packSources: [String: JSON] = [:]
        if let overlay {
            let nav = try JSONDecoder().decode(JSON.self, from: Data(overlay.replacing("__ASSETS__", with: assets).utf8))
            if case .object(let navSources)? = nav["sources"] { packSources.merge(navSources) { old, _ in old } }
            let navLayers: [JSON] = {
                guard case .array(let list)? = nav["layers"] else { return [] }
                return list.filter { $0["id"]?.string != "background" }.map { night ? NightInk.inked($0) : $0 }
            }()
            // Street ground, airspace and airways, street labels, then airports, navaids and aeronautical labels.
            func isPoint(_ layer: JSON) -> Bool { ["symbol", "circle"].contains(layer["type"]?.string) }
            layers = layers.filter { !isPoint($0) } + navLayers.filter { !isPoint($0) }
                + layers.filter(isPoint) + navLayers.filter(isPoint)
        }
        for (name, source) in sources {
            guard isPack(name) else { packSources[name] = source; continue }
            for (index, pack) in packs.enumerated() {
                var copy = source
                copy["url"] = .string("pmtiles://file://" + pack.path)
                packSources[named(name, index)] = copy
            }
        }
        style["sources"] = .object(packSources)
        style["layers"] = .array(layers.flatMap { layer -> [JSON] in
            guard let source = layer["source"]?.string, isPack(source), let id = layer["id"]?.string else { return [layer] }
            return packs.indices.map { index in
                var copy = layer
                copy["id"] = .string(named(id, index))
                copy["source"] = .string(named(source, index))
                return copy
            }
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(style), as: UTF8.self)
    }

    /// One pack per region of a layer, chosen by the core, with the overview underneath.
    private static func rasters(layer: String, installed: [PackFile], now: Date) -> [Raster] {
        let packs = installed.map(\.pack)
        let regions = Set(packs.filter { $0.id.layer == layer }.map(\.id.region))
        let ordered = regions.sorted {
            ($0 == ChartLibrary.overviewRegion ? 0 : 1, $0) < ($1 == ChartLibrary.overviewRegion ? 0 : 1, $1)
        }
        return ordered.compactMap { region in
            guard let pack = ChartLibrary.packToShow(layer: layer, region: region, installed: packs, now: now),
                  let file = installed.first(where: { $0.pack == pack }) else { return nil }
            // A colon cannot appear in a layer or region name, so two packs never share an identifier.
            return Raster(identifier: "\(layer):\(region)", url: file.url)
        }
    }
}

/// Whether the chart shown for a layer is the one in effect.
public enum ChartCurrency: Equatable, Sendable {
    case current
    /// The date it stopped being current.
    case expired(Date)
    /// The date it takes effect.
    case notYetEffective(Date)
}

/// Map decisions that are not one style: chart standing, the banner over it, and the first-fix zoom.
public enum MapPlan {
    /// The standing of the pack the map shows for one layer and region. Nil when none is installed.
    public static func currency(layer: String, region: String, installed: [InstalledPack], now: Date) -> ChartCurrency? {
        guard let shown = ChartLibrary.packToShow(layer: layer, region: region, installed: installed, now: now)
        else { return nil }
        if ChartLibrary.cycleFreeLayers.contains(layer) { return .current }
        if shown.effective > now { return .notYetEffective(shown.effective) }
        if now >= shown.expires { return .expired(shown.expires) }
        return .current
    }

    /// The worst standing over every region of the layers: expired, then not yet effective.
    public static func currency(layers: [String], installed: [InstalledPack], now: Date) -> ChartCurrency? {
        let keys = Set(installed.filter { layers.contains($0.id.layer) }.map { [$0.id.layer, $0.id.region] })
        let all = keys.compactMap { currency(layer: $0[0], region: $0[1], installed: installed, now: now) }
        func rank(_ value: ChartCurrency) -> Int {
            switch value {
            case .expired: 2
            case .notYetEffective: 1
            case .current: 0
            }
        }
        return all.max { rank($0) < rank($1) }
    }

    /// The banner over the map, or nil when the charts are current.
    public static func banner(_ currency: ChartCurrency?, subject: String = "Charts") -> String? {
        switch currency {
        case .expired(let date): "\(subject) expired \(NavText.day(date)) UTC"
        case .notYetEffective(let date): "\(subject) not yet in effect until \(NavText.day(date)) UTC"
        case .current, nil: nil
        }
    }

    /// The zoom the first fix moves a whole-country view to. Nil leaves the camera alone.
    public static func firstFixZoom(current: Double, alreadyZoomed: Bool) -> Double? {
        !alreadyZoomed && current < 7 ? 10 : nil
    }

    /// A tap goes none, north up, track up, and back to none with the map turned north.
    public static func nextTracking(following: Bool, orientation: MapOrientation)
        -> (following: Bool, orientation: MapOrientation) {
        if !following { return (true, .northUp) }
        return orientation == .northUp ? (true, .trackUp) : (false, .northUp)
    }

    /// Center on Aircraft: follow in the orientation the map has. Nil when already following, so nothing changes.
    public static func centerTracking(following: Bool, orientation: MapOrientation)
        -> (following: Bool, orientation: MapOrientation)? {
        following ? nil : (true, orientation)
    }

    public static func trackingLabel(following: Bool, orientation: MapOrientation) -> String {
        !following ? "Not following" : orientation == .northUp ? "Following, north up" : "Following, track up"
    }


    /// Map heading for a fix. Track up with no track keeps the heading the map already has.
    public static func heading(for position: Position, orientation: MapOrientation, current: Double) -> Double {
        orientation == .trackUp ? (position.trackTrue ?? current) : 0
    }

    /// The aircraft image: an arrow along track, a dot with no track, a ring when not precise; gray when stale.
    public static func ownshipImage(for position: Position, approximate: Bool, now: Date) -> String {
        (position.isStale(at: now) ? "ownship-stale" : "ownship-live")
            + (approximate ? "-ring" : position.trackTrue == nil ? "-dot" : "")
    }
}
