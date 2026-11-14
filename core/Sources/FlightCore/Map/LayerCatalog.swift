/// A layer drawn above the base map. Image overlays also carry an opacity.
public struct OverlayLayer: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var isImage: Bool
    public var isOn: Bool
    public var opacity: Double

    public init(id: String, title: String, isImage: Bool, isOn: Bool = false, opacity: Double = 1) {
        self.id = id
        self.title = title
        self.isImage = isImage
        self.isOn = isOn
        self.opacity = opacity
    }
}

/// One titled group of overlays in the picker.
public struct LayerGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var overlays: [OverlayLayer]

    public init(id: String, title: String, overlays: [OverlayLayer]) {
        self.id = id
        self.title = title
        self.overlays = overlays
    }
}

/// The overlays the picker offers and which are on.
public struct OverlayList: Equatable, Sendable {
    public private(set) var groups: [LayerGroup]

    public init(groups: [LayerGroup] = []) { self.groups = groups }

    public func overlay(_ id: String) -> OverlayLayer? {
        groups.lazy.flatMap(\.overlays).first { $0.id == id }
    }

    public mutating func setOverlay(_ id: String, on: Bool) {
        change(id) { $0.isOn = on }
    }

    /// Opacity from 0 to 1. Ignored for overlays that are not images.
    public mutating func setOpacity(_ id: String, to value: Double) {
        change(id) { if $0.isImage { $0.opacity = min(max(value, 0), 1) } }
    }

    private mutating func change(_ id: String, _ edit: (inout OverlayLayer) -> Void) {
        for group in groups.indices {
            if let index = groups[group].overlays.firstIndex(where: { $0.id == id }) {
                edit(&groups[group].overlays[index])
            }
        }
    }
}

/// The aeronautical overlay's switches: one per kind of feature, with the style layers it shows and hides.
public enum AeronauticalLayers {
    public static let groupID = "aeronautical"
    public static let obstaclesID = "nav-obstacles"
    public static let fuelIDs = ["nav-fuel-100ll", "nav-fuel-jet"]

    // Each family draws a soft band in three steps under its edge, as the sectional does.
    private static let airspaceLayers = ["airspace-e5", "airspace-e", "airspace"].flatMap { family in
        ["band", "band-mid", "band-near"].map { "\(family)-\($0)" }
    } + ["airspace-e", "airspace-b", "airspace-c", "airspace-d", "airspace-label", "airspace-label-d"]

    public static let groups: [(id: String, title: String, layers: [String], startsOn: Bool)] = [
        // Taxiways, aprons, buildings and FBOs come from OpenStreetMap and show from zoom 13.
        ("nav-airports", "Airports", ["surface-aprons", "surface-buildings", "taxiways", "hold-lines", "fbos",
                                      "taxiways-label", "fbos-label", "runways", "runways-closed", "runway-numbers",
                                      "airports", "airports-label"], true),
        ("nav-private", "Private airfields (zoom 10 and closer)", ["airports-private", "airports-private-label"], false),
        ("nav-navaids", "Navaids", ["navaids", "navaids-label"], true),
        ("nav-fixes", "Fixes", ["fixes", "fixes-label"], false),
        ("nav-airways", "Airways", ["airways", "airways-label"], false),
        ("nav-airspace", "Airspace B, C, D and E", airspaceLayers, true),
        ("nav-sua", "Special use airspace", ["sua-band", "sua-band-mid", "sua-band-near", "sua", "sua-label"], true),
        (obstaclesID, "Obstacles and jump areas", ["obstacles", "obstacles-label", "pja"], false),
        // Rings around public airports that sell the fuel; Jet A covers every grade (A, A+, A1, A1+).
        (fuelIDs[0], "Fuel: 100LL", ["fuel-100ll"], false),
        (fuelIDs[1], "Fuel: Jet A", ["fuel-jet"], false),
    ]

    public static var layerGroup: LayerGroup {
        LayerGroup(id: groupID, title: "Aeronautical", overlays: groups.map {
            OverlayLayer(id: $0.id, title: $0.title, isImage: false, isOn: $0.startsOn)
        })
    }
}

/// The layer picker's order and grouping, so related layers sit together.
public enum LayerMenu {
    public enum Row: Equatable, Sendable {
        /// A switch from the overlay list.
        case overlay(String)
        /// One station dot readout; at most one is on, and it turns the station dots on.
        case station(StationShow)
    }

    public struct Section: Equatable, Sendable {
        public var title: String?
        public var rows: [Row]
    }

    /// The section above the rest listing plates placed on the map, shown only while one is.
    public static let onMap = "On Map"
    public static let removeAll = "Remove All"

    /// Base maps in groups: street, aerial and terrain, then the VFR and IFR charts, then the flyway chart.
    public static let bases: [[BaseLayer]] = [[.street, .aerial, .terrain], [.vfr, .ifrLow, .ifrHigh], [.vfrFlyway]]

    /// The aeronautical features, shown above the base maps.
    public static let aeronautical = Section(title: AeronauticalLayers.layerGroup.title, rows: [
        "nav-airports", "nav-private", "nav-navaids", "nav-fixes", "nav-airways", "nav-airspace", "nav-sua",
    ].map(Row.overlay))

    /// Overlays after the base maps, one section per group of related layers.
    public static let overlays: [Section] = [
        Section(title: "Overlays", rows: [.overlay("weather-radar"), .overlay("weather-satellite")]),
        Section(title: nil, rows: [.overlay(TrafficStore.switchID)]),
        Section(title: nil, rows: [.overlay("weather-airsigmet"), .overlay(WeatherSwitches.tfrsID)]),
        Section(title: nil, rows: [.station(.category), .station(.wind), .overlay(WindsMap.switchID), .station(.spread),
                                   .station(.temperature), .station(.visibility), .station(.ceiling), .station(.sky)]),
        Section(title: nil, rows: [.overlay("weather-pireps"), .overlay("weather-lightning")]),
        Section(title: nil, rows: [AeronauticalLayers.obstaclesID, AeronauticalLayers.fuelIDs[0], AeronauticalLayers.fuelIDs[1]].map(Row.overlay)),
    ]
}

/// Night inks for the overlay and the raster paint that turns a chart dark.
public enum NightInk {
    /// Night ink for each day ink in nav-style.json. White halos and fills become the map ground.
    public static let inks: [String: String] = [
        "#1557b0": "#7fb0f2", "#9c2788": "#d985c6", "#ffffff": "#1e1d1b",
        "#333333": "#c4c1ba", "#4a4a4a": "#a19e97", "#555555": "#b0ada6",
        "#111111": "#e8e6e1",
    ]

    /// The night ink for a day ink, or the text unchanged when it is not one.
    public static func swap(_ text: String) -> String { inks[text.lowercased()] ?? text }

    /// A paint value with every day ink in it swapped for its night one.
    public static func ink(_ value: JSON) -> JSON {
        switch value {
        case .string(let s): .string(swap(s))
        case .array(let list): .array(list.map(ink))
        default: value
        }
    }

    /// A style layer with its color paints in night inks.
    public static func inked(_ layer: JSON) -> JSON {
        guard case .object(var paint)? = layer["paint"] else { return layer }
        for key in paint.keys where key.hasSuffix("-color") { paint[key] = ink(paint[key]!) }
        var layer = layer
        layer["paint"] = .object(paint)
        return layer
    }
}

/// Raster paint for night: inverted, with the hue turned back so blue and magenta keep their meaning.
public enum NightPaint {
    public struct Values: Equatable, Sendable {
        public var minimumBrightness: Double
        public var maximumBrightness: Double
        public var hueRotation: Double

        public init(minimumBrightness: Double, maximumBrightness: Double, hueRotation: Double) {
            self.minimumBrightness = minimumBrightness
            self.maximumBrightness = maximumBrightness
            self.hueRotation = hueRotation
        }
    }

    public static func values(night: Bool) -> Values {
        night ? Values(minimumBrightness: 0.8, maximumBrightness: 0, hueRotation: 180)
              : Values(minimumBrightness: 0, maximumBrightness: 1, hueRotation: 0)
    }

    /// Gray level of the map behind the tiles, 0 black to 1 white.
    public static func backgroundWhite(night: Bool) -> Double { night ? 0.08 : 0.5 }

    /// Terrain at night: dimmed, not inverted, so relief stays lit from the northwest and colors keep their meaning.
    public static func terrainValues(night: Bool) -> Values {
        Values(minimumBrightness: 0, maximumBrightness: night ? 0.4 : 1, hueRotation: 0)
    }
}
