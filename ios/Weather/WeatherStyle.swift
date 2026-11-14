import FlightCore
import Foundation

/// Style sources and layers for the weather overlays, as style JSON. Text uses the bundled fonts; the only images are the wind barbs, drawn at runtime.
enum WeatherStyle {
    static func glyphs(assets: URL) -> String { "file://\(assets.path)/fonts/{fontstack}/{range}.pbf" }
    /// The overlays drawn from GeoJSON, bottom first. The radar pictures are vector tiles added by the map itself,
    /// below the radar's own GeoJSON layer.
    /// The satellite picture goes in below its own empty anchor layer, so under everything else.
    static let drawn: [WeatherOverlay] = [.satellite, .radar, .gairmets, .sigmets, .cwas, .tfrs, .pireps, .lightning, .winds, .stations]
    static let satelliteAnchor = "wx-satellite-anchor"
    /// The radar mosaic's grid: west, south, east, north. Outside it there are no pictures at all.
    static let radarGrid = (west: -130.0, south: 20.0, east: -60.0, north: 55.0)
    /// A station report this old misses its hourly successor, so its dot is drawn faded.
    static let staleStationMinutes = 75

    private static let regular = ["Noto Sans Regular"]
    private static let medium = ["Noto Sans Medium"]
    // Computed, because a stored value holding Any cannot be shared between threads.
    private static var polygons: [Any] { ["==", "$type", "Polygon"] }

    static func sourceID(_ overlay: WeatherOverlay) -> String { "wx-" + overlay.rawValue }

    /// The world with the radar grid cut out, shaded as no coverage while radar is on.
    static var radarOutside: [String: Any] {
        let g = radarGrid
        let world: [[Double]] = [[-180, -85], [180, -85], [180, 85], [-180, 85], [-180, -85]]
        let hole: [[Double]] = [[g.west, g.south], [g.west, g.north], [g.east, g.north], [g.east, g.south], [g.west, g.south]]
        return ["type": "Feature", "properties": [String: Any](),
                "geometry": ["type": "Polygon", "coordinates": [world, hole]] as [String: Any]]
    }

    /// One GeoJSON source per overlay, empty but for radar's. The map fills the rest through their shape sources.
    static var sources: [String: Any] {
        var all: [String: Any] = [:]
        for overlay in drawn {
            let features: [Any] = overlay == .radar ? [radarOutside] : []
            all[sourceID(overlay)] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": features]]
        }
        return all
    }

    static func layerIDs(for overlay: WeatherOverlay) -> [String] {
        layers(for: overlay).compactMap { $0["id"] as? String }
    }

    // Typed parameters give every nested literal a type, which a bare literal inside Any would lack.
    private static func layer(_ id: String, _ type: String, _ source: String, minzoom: Double? = nil,
                              filter: [Any]? = nil, layout: [String: Any]? = nil,
                              paint: [String: Any]) -> [String: Any] {
        var layer: [String: Any] = ["id": id, "type": type, "source": source, "paint": paint]
        if let minzoom { layer["minzoom"] = minzoom }
        if let filter { layer["filter"] = filter }
        if let layout { layer["layout"] = layout }
        return layer
    }

    private static func label(_ id: String, _ source: String, minzoom: Double, offset: Double? = nil) -> [String: Any] {
        var layout: [String: Any] = ["text-field": ["get", "label"], "text-font": regular, "text-size": 11]
        if let offset {
            layout["text-anchor"] = "top"
            layout["text-offset"] = [0, offset]
        }
        return layer(id, "symbol", source, minzoom: minzoom, layout: layout,
                     paint: ["text-color": "#111111", "text-halo-color": "#ffffff", "text-halo-width": 1.5])
    }

    /// The rounded image stretched behind station text, so it reads over a busy chart.
    static let pill = "wx-label-pill"

    /// Station text on the pill instead of a halo. It still collides, so labels never pile up.
    /// Glyph boxes already carry room above and below, so the padding trims height and adds width.
    private static func onPill(_ layer: [String: Any], size: Double) -> [String: Any] {
        var layer = layer
        var layout = layer["layout"] as? [String: Any] ?? [:]
        layout.merge(["text-font": medium, "text-size": size, "icon-image": pill, "icon-text-fit": "both",
                      "icon-text-fit-padding": [-1, 3, -1, 3]]) { _, new in new }
        layer["layout"] = layout
        layer["paint"] = ["text-color": "#111111"]
        return layer
    }

    /// Short letters on a point, never hidden by another label.
    private static func letters(_ id: String, _ source: String, field: String, size: Double,
                                paint: [String: Any]) -> [String: Any] {
        layer(id, "symbol", source, minzoom: 5,
              layout: ["text-field": ["get", field], "text-font": medium, "text-size": size,
                       "text-allow-overlap": true, "text-ignore-placement": true],
              paint: paint)
    }

    /// Fill, outline and label for an area overlay. A dash pattern keeps kinds apart without color.
    private static func areaLayers(_ source: String, color: String, opacity: Double,
                                   width: Double, dash: [Double]?) -> [[String: Any]] {
        var line: [String: Any] = ["line-color": color, "line-width": width]
        if let dash { line["line-dasharray"] = dash }
        return [
            layer("\(source)-fill", "fill", source, filter: polygons,
                  paint: ["fill-color": color, "fill-opacity": opacity]),
            layer("\(source)-line", "line", source, paint: line),
            label("\(source)-label", source, minzoom: 5),
        ]
    }

    static func layers(for overlay: WeatherOverlay) -> [[String: Any]] {
        let source = sourceID(overlay)
        let red = "#d32020"
        switch overlay {
        case .satellite:
            return [layer(satelliteAnchor, "fill", source, paint: ["fill-opacity": 0])]
        case .lightning:
            // Newest flashes brightest and largest.
            let color: [Any] = ["step", ["get", "age_min"], LightningStyle.ages[0].color]
                + LightningStyle.ages.dropFirst().flatMap { [$0.minutes, $0.color] as [Any] }
            let size = { (scale: Double) -> [Any] in ["step", ["get", "age_min"], 4 * scale, 5, 3.2 * scale, 15, 2.5 * scale] }
            return [layer("wx-lightning-dot", "circle", source,
                          paint: ["circle-color": color, "circle-radius": ["interpolate", ["linear"], ["zoom"], 4, size(1), 9, size(1.8)],
                                  "circle-stroke-color": "#111111", "circle-stroke-width": 0.8])]
        case .radar:
            return [layer("wx-radar-outside", "fill", source,
                          paint: ["fill-color": RadarStyle.noCoverage.color,
                                   "fill-opacity": RadarStyle.noCoverage.opacity])]
        case .gairmets:
            return areaLayers(source, color: "#7a4fc0", opacity: 0.08, width: 1.5, dash: [4, 3])
        case .sigmets:
            return areaLayers(source, color: "#d98400", opacity: 0.15, width: 2.5, dash: nil)
        case .cwas:
            return areaLayers(source, color: "#00838f", opacity: 0.12, width: 2, dash: [6, 2])
        case .tfrs:
            let active: [Any] = ["==", "status", "active"]
            return [
                layer("wx-tfrs-fill", "fill", source, filter: ["all", polygons, active],
                      paint: ["fill-color": red, "fill-opacity": 0.12]),
                layer("wx-tfrs-line", "line", source, filter: active, paint: ["line-color": red, "line-width": 2.5]),
                // Not yet in effect: an outline only, dashed.
                layer("wx-tfrs-upcoming", "line", source, filter: ["==", "status", "upcoming"],
                      paint: ["line-color": red, "line-width": 1.5, "line-dasharray": [2, 3]]),
                label("wx-tfrs-label", source, minzoom: 6),
            ]
        case .pireps:
            let color: [Any] = ["match", ["get", "type"], "UUA", red, "#111111"]
            return [
                letters("wx-pireps-type", source, field: "type", size: 12,
                        paint: ["text-color": color, "text-halo-color": "#ffffff", "text-halo-width": 2]),
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
            let color: [Any] = ["match", ["get", "cat"], "VFR", "#1a8f3c", "MVFR", "#1f5fd0",
                                 "IFR", red, "LIFR", "#b0189e", "#6b6b6b"]
            let faded: [Any] = ["step", ["get", "age_min"], 1, staleStationMinutes, 0.45]
            return [
                layer("wx-stations-dot", "circle", source, minzoom: 5,
                      paint: ["circle-radius": 9, "circle-color": color, "circle-opacity": faded,
                              "circle-stroke-color": "#ffffff", "circle-stroke-width": 1.5, "circle-stroke-opacity": faded]),
                // The letter is drawn from the same zoom as the dot, so color is never the only cue.
                letters("wx-stations-cue", source, field: "cue", size: 11,
                        paint: ["text-color": "#ffffff", "text-opacity": faded]),
                // A chevron on the dot points downwind; the bundled font has no arrow glyph.
                layer("wx-stations-wind", "symbol", source, minzoom: 5, filter: [">=", "dir", 0],
                      layout: ["text-field": ">", "text-font": medium, "text-size": 15,
                               "text-rotate": ["+", ["get", "dir"], 90], "text-rotation-alignment": "map",
                               "text-allow-overlap": true, "text-ignore-placement": true],
                      paint: ["text-color": "#ffffff", "text-opacity": faded]),
                onPill(layer("wx-stations-value", "symbol", source, minzoom: 5,
                             layout: ["text-field": ["get", "value"], "text-anchor": "left", "text-offset": [1.3, 0]],
                             paint: [:]), size: 13),
                onPill(label("wx-stations-label", source, minzoom: 8, offset: 1.9), size: 12),
            ]
        }
    }

    /// A style document with the weather sources added and the weather layers on top.
    /// The fonts come from `assets` when the base names none.
    static func merged(into style: Data, assets: URL) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: style) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if root["glyphs"] == nil { root["glyphs"] = glyphs(assets: assets) }
        root["sources"] = (root["sources"] as? [String: Any] ?? [:]).merging(sources) { _, new in new }
        root["layers"] = (root["layers"] as? [Any] ?? []) + drawn.flatMap(layers(for:))
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes, .sortedKeys])
    }
}
