import FlightCore
import MapLibre
import UIKit

/// Puts the weather overlays, their switches and the newest radar picture on a loaded map style.
enum WeatherLayers {
    private static func key(_ id: String) -> String { "overlay-" + id }

    static func restore(_ groups: [LayerGroup], from defaults: UserDefaults) -> [LayerGroup] {
        groups.map { group in
            var group = group
            for index in group.overlays.indices where WeatherSwitches.saved.contains(group.overlays[index].id) {
                if let on = defaults.object(forKey: key(group.overlays[index].id)) as? Bool {
                    group.overlays[index].isOn = on
                }
            }
            return group
        }
    }

    static func save(_ groups: [LayerGroup], to defaults: UserDefaults) {
        for overlay in groups.flatMap(\.overlays) where WeatherSwitches.saved.contains(overlay.id) {
            defaults.set(overlay.isOn, forKey: key(overlay.id))
        }
    }

    @MainActor static func shown(_ catalog: LayerCatalog) -> [WeatherOverlay] { WeatherSwitches.shown(catalog.list) }

    /// The base style with the weather sources and layers added, written to a temporary file named for the base.
    static func styleFile(_ base: URL) -> URL? {
        guard let assets = Bundle.main.resourceURL?.appendingPathComponent("MapAssets"),
              let data = try? WeatherStyle.merged(into: Data(contentsOf: base), assets: assets) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wx-\(Checksum.sha256(base.path)).json")
        return (try? data.write(to: file, options: .atomic)) == nil ? nil : file
    }

    /// Overlay shapes parsed and ready for `fill`. Built once, then only read on the main thread.
    struct Shapes: @unchecked Sendable {
        // Nil for GeoJSON that would not parse, which clears its overlay.
        fileprivate(set) var parsed: [WeatherOverlay: MLNShape?] = [:]
    }

    /// The shape of each switched-on overlay drawn from a shape source. Thousands of stations make the GeoJSON
    /// and its parse slow, so both happen off the main thread. A cancelled task stops between overlays.
    static func shapes(_ on: [WeatherOverlay], data: WeatherData, show: StationShow, windsLevel: Int,
                       now: Date) -> Shapes {
        var shapes = Shapes()
        for overlay in WeatherStyle.drawn where on.contains(overlay) && overlay != .radar && overlay != .satellite {
            if Task.isCancelled { break }
            let json = WeatherGeoJSON.overlay(overlay, data, show: show, windsLevel: windsLevel, now: now)
            shapes.parsed[overlay] = .some(try? MLNShape(data: json, encoding: String.Encoding.utf8.rawValue))
        }
        return shapes
    }

    /// `shapes` off the main thread in the calling task, so cancelling the caller stops the build.
    @concurrent static func build(_ on: [WeatherOverlay], data: WeatherData, show: StationShow, windsLevel: Int,
                                  now: Date) async -> Shapes {
        shapes(on, data: data, show: show, windsLevel: windsLevel, now: now)
    }

    @MainActor static func fill(_ shapes: Shapes, on style: MLNStyle) {
        for (overlay, shape) in shapes.parsed {
            (style.source(withIdentifier: WeatherStyle.sourceID(overlay)) as? MLNShapeSource)?.shape = shape
        }
    }

    /// Shows the switched-on overlays and hides the rest. Their shapes arrive through `fill`.
    @MainActor static func apply(_ catalog: LayerCatalog, data: WeatherData, show: StationShow, now: Date, to style: MLNStyle) {
        let on = Set(shown(catalog))
        if on.contains(.winds) { installBarbs(on: style) }
        for overlay in WeatherStyle.drawn {
            for id in WeatherStyle.layerIDs(for: overlay) { style.layer(withIdentifier: id)?.isVisible = on.contains(overlay) }
        }
        if on.contains(.stations) {
            style.layer(withIdentifier: "wx-stations-cue")?.isVisible = show == .category
            style.layer(withIdentifier: "wx-stations-wind")?.isVisible = show == .wind
            style.layer(withIdentifier: "wx-stations-value")?.isVisible = show != .category
        }
        radar(on.contains(.radar) ? data.radarLoop(at: now).last : nil, on: style)
        satellite(on.contains(.satellite) ? data.satelliteShown(at: now) : nil, on: style)
    }

    static let satelliteID = "wx-satellite-frame"

    /// The newest satellite picture as a raster under every other weather layer. Linear resampling blurs the
    /// 2 km pixels when zoomed past the pack's zoom 6.
    @MainActor private static func satellite(_ frame: RadarLoopFrame?, on style: MLNStyle) {
        let url = frame.flatMap { URL(string: "pmtiles://" + $0.file.absoluteString) }
        guard url != (style.source(withIdentifier: satelliteID) as? MLNRasterTileSource)?.configurationURL else { return }
        removeRadar(satelliteID, from: style)
        guard let url, let anchor = style.layer(withIdentifier: WeatherStyle.satelliteAnchor) else { return }
        let source = MLNRasterTileSource(identifier: satelliteID, configurationURL: url, tileSize: 256)
        style.addSource(source)
        let layer = MLNRasterStyleLayer(identifier: satelliteID, source: source)
        layer.rasterOpacity = NSExpression(forConstantValue: SatelliteStyle.opacity)
        layer.rasterResamplingMode = NSExpression(forConstantValue: "linear")
        style.insertLayer(layer, below: anchor)
    }

    /// The core's barb drawings as template images, which MapLibre takes as SDF icons the style colors.
    @MainActor private static func installBarbs(on style: MLNStyle) {
        guard style.image(forName: WindBarb.image(0)) == nil else { return }
        for d in WindBarb.drawings {
            let image = UIGraphicsImageRenderer(size: CGSize(width: d.size, height: d.size)).image { context in
                let g = context.cgContext
                g.setStrokeColor(UIColor.white.cgColor)
                g.setFillColor(UIColor.white.cgColor)
                g.setLineWidth(d.lineWidth)
                g.setLineCap(.round)
                for l in d.lines {
                    g.move(to: CGPoint(x: l[0], y: l[1]))
                    g.addLine(to: CGPoint(x: l[2], y: l[3]))
                }
                g.strokePath()
                for t in d.triangles {
                    g.move(to: CGPoint(x: t[0], y: t[1]))
                    g.addLine(to: CGPoint(x: t[2], y: t[3]))
                    g.addLine(to: CGPoint(x: t[4], y: t[5]))
                    g.closePath()
                }
                g.fillPath()
                if let r = d.ring {
                    g.strokeEllipse(in: CGRect(x: d.size / 2 - r, y: d.size / 2 - r, width: 2 * r, height: 2 * r))
                }
            }
            style.setImage(image.withRenderingMode(.alwaysTemplate), forName: d.name)
        }
    }

    static let radarID = "wx-radar-frame"

    @MainActor private static func radar(_ frame: RadarLoopFrame?, on style: MLNStyle) {
        let url = frame.flatMap { URL(string: "pmtiles://" + $0.file.absoluteString) }
        guard url != (style.source(withIdentifier: radarID) as? MLNVectorTileSource)?.configurationURL else { return }
        removeRadar(radarID, from: style)
        if let url { addRadar(radarID, url, to: style) }
    }

    private static func removeRadar(_ id: String, from style: MLNStyle) {
        if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
        if let source = style.source(withIdentifier: id) { style.removeSource(source) }
    }

    @MainActor private static func addRadar(_ id: String, _ url: URL, to style: MLNStyle, shown: Bool = true) {
        guard let shading = style.layer(withIdentifier: "wx-radar-outside") else { return }
        let source = MLNVectorTileSource(identifier: id, configurationURL: url)
        style.addSource(source)
        let layer = MLNFillStyleLayer(identifier: id, source: source)
        layer.sourceLayerIdentifier = "radar"
        // Alpha rides in the colors so the layer opacity stays a constant MapLibre can fade:
        // a data-driven opacity does not transition and left the old picture up over the new one.
        // Below the first band floor is no coverage.
        layer.fillColor = NSExpression(mglJSONObject: ["step", ["get", "dbz"], rgba(RadarStyle.noCoverage.color, RadarStyle.noCoverage.opacity)]
            + RadarStyle.bands.flatMap { [$0.dbz, rgba($0.color, RadarStyle.echoOpacity)] as [Any] })
        layer.fillOpacity = opacity(shown)
        layer.fillOpacityTransition = MLNTransition(duration: fade, delay: 0)
        style.insertLayer(layer, below: shading)
    }

    /// Crossfade between loop pictures, shorter than the 0.5 s a picture stays up.
    private static let fade: TimeInterval = 0.3

    private static func rgba(_ hex: String, _ alpha: Double) -> String {
        let rgb = Int(hex.dropFirst(), radix: 16) ?? 0
        return "rgba(\(rgb >> 16 & 255), \(rgb >> 8 & 255), \(rgb & 255), \(alpha))"
    }

    private static func loopID(_ i: Int) -> String { "wx-radar-loop-\(i)" }

    @MainActor private static func opacity(_ shown: Bool) -> NSExpression { NSExpression(forConstantValue: shown ? 1 : 0) }

    /// Shows picture `showing` of the loop, fading from the one before. Every picture is its own layer, hidden
    /// at zero opacity so its tiles stay loaded and a swap never flickers. Empty frames removes the loop and shows the newest again.
    @MainActor static func loop(_ frames: [RadarLoopFrame], showing: Int, on style: MLNStyle) {
        if frames.isEmpty {
            var i = 0
            while style.source(withIdentifier: loopID(i)) != nil { removeRadar(loopID(i), from: style); i += 1 }
        } else if style.source(withIdentifier: loopID(0)) == nil {
            for (i, frame) in frames.enumerated() {
                if let url = URL(string: "pmtiles://" + frame.file.absoluteString) { addRadar(loopID(i), url, to: style, shown: false) }
            }
        }
        for i in frames.indices { (style.layer(withIdentifier: loopID(i)) as? MLNFillStyleLayer)?.fillOpacity = opacity(i == showing) }
        (style.layer(withIdentifier: radarID) as? MLNFillStyleLayer)?.fillOpacity = opacity(frames.isEmpty)
    }

    @MainActor private static let dayPaints = NavOverlay.colorPaints(
        (try? JSONSerialization.data(withJSONObject: ["layers": WeatherStyle.drawn.flatMap(WeatherStyle.layers(for:))]))
            ?? Data())

    /// Repaints the weather layers through the same night inks as the nav overlay.
    @MainActor static func paint(night: Bool, style: MLNStyle) {
        NavOverlay.paint(dayPaints, night: night, style: style)
        installPill(on: style, night: night)
    }

    /// The station text's rounded ground: white by day, the map ground by night, both 85% with a thin edge.
    /// Cap insets keep the corners when MapLibre stretches it around the text.
    @MainActor private static func installPill(on style: MLNStyle, night: Bool) {
        let side = 12.0, inset = 5.0
        let fill = night ? UIColor(red: 0x1e / 255, green: 0x1d / 255, blue: 0x1b / 255, alpha: 0.85)
                         : UIColor(white: 1, alpha: 0.85)
        let edge = night ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.18)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1), cornerRadius: 5)
            fill.setFill()
            path.fill()
            edge.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let insets = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        style.setImage(image.resizableImage(withCapInsets: insets, resizingMode: .stretch), forName: WeatherStyle.pill)
    }
}
