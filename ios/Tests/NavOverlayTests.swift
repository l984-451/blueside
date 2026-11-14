import CoreLocation
import FlightCore
import Foundation
import MapLibre
import Testing
import UIKit
@testable import Blueside

private let assets = Bundle.main.resourceURL!.appendingPathComponent("MapAssets")
private let navTiles = assets.appendingPathComponent("nav-tiles.pmtiles")
private let austinChart = assets.appendingPathComponent("nav-vfr.pmtiles")
private let austin = CLLocationCoordinate2D(latitude: 30.1945, longitude: -97.6699)

private func resolved() throws -> (text: String, json: [String: Any]) {
    let text = try NavOverlay.json(tiles: navTiles, assets: assets)
    let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    return (text, json)
}

// The nav style cut down to the named layers (nil keeps them all). With chart true the Austin chart
// goes straight above the background, where the map screen puts its charts.
private func styleFile(keeping ids: Set<String>?, chart: Bool) throws -> URL {
    var style = try resolved().json
    var layers = try #require(style["layers"] as? [[String: Any]])
    if let ids { layers = layers.filter { ids.contains($0["id"] as? String ?? "") } }
    if chart {
        var sources = try #require(style["sources"] as? [String: Any])
        let source: [String: Any] = ["type": "raster", "url": "pmtiles://file://" + austinChart.path, "tileSize": 256]
        sources["vfr"] = source
        style["sources"] = sources
        layers.insert(["id": "vfr", "type": "raster", "source": "vfr"], at: 1)
    }
    style["layers"] = layers
    let name = "nav-test-" + (ids?.sorted().joined(separator: "-") ?? "all") + (chart ? "-chart" : "") + ".json"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: style).write(to: file)
    return file
}

// Notes when the map has drawn every tile it asked for.
@MainActor private final class DrawWatcher: NSObject, @preconcurrency MLNMapViewDelegate {
    var finished = false
    func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
        if fullyRendered { finished = true }
    }
}

// Draws a style in a live map view at zoom 9 over Austin and saves the picture where the screenshots go.
// The off-screen snapshotter is not used: it also draws the edges where polygons are cut at tile borders.
@MainActor private func render(_ style: URL, name: String) async throws -> Data {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let map = MLNMapView(frame: window.bounds, styleURL: style)
    let watcher = DrawWatcher()
    map.delegate = watcher
    let host = UIViewController()
    host.view.addSubview(map)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    map.setCenter(austin, zoomLevel: 9, animated: false)
    for _ in 0..<100 where !watcher.finished { try await Task.sleep(for: .milliseconds(100)) }
    try #require(watcher.finished, "the map did not finish drawing \(name) in 10 s")
    // Labels and chart tiles fade in after the last tile arrives.
    try await Task.sleep(for: .seconds(1))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let data = try #require(image.pngData(), "no picture for \(name)")
    if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    return data
}

// The red, green, blue and alpha bytes of a PNG, row by row.
private func pixels(of png: Data) throws -> [UInt8] {
    let image = try #require(UIImage(data: png)?.cgImage)
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
}

// The share of pixels within a tolerance of one color.
private func share(of png: Data, near red: Int, _ green: Int, _ blue: Int, tolerance: Int) throws -> Double {
    let bytes = try pixels(of: png)
    var hits = 0
    for at in stride(from: 0, to: bytes.count, by: 4) {
        if abs(Int(bytes[at]) - red) <= tolerance, abs(Int(bytes[at + 1]) - green) <= tolerance,
           abs(Int(bytes[at + 2]) - blue) <= tolerance { hits += 1 }
    }
    return Double(hits) / Double(bytes.count / 4)
}

// The share of pixels where two pictures of one size differ by more than 40 in red, green or blue.
private func difference(_ first: Data, _ second: Data) throws -> Double {
    let one = try pixels(of: first)
    let two = try pixels(of: second)
    try #require(one.count == two.count)
    var hits = 0
    for at in stride(from: 0, to: one.count, by: 4) {
        if abs(Int(one[at]) - Int(two[at])) > 40 || abs(Int(one[at + 1]) - Int(two[at + 1])) > 40
            || abs(Int(one[at + 2]) - Int(two[at + 2])) > 40 { hits += 1 }
    }
    return Double(hits) / Double(one.count / 4)
}

@Suite(.serialized) @MainActor struct NavOverlayTests {
    @Test func bundledDatabaseOpensAndHoldsAustin() throws {
        let database = try NavDatabase(path: assets.appendingPathComponent("nav-test.sqlite").path)
        #expect(database.metadata.cycle == "2026-10-01")
        let found = try database.airport(identifier: "KAUS")
        #expect(found?.ident == "AUS")
    }

    @Test func styleHoldsNoRemoteAddress() throws {
        let style = try resolved()
        #expect(!style.text.contains("http://"))
        #expect(!style.text.contains("https://"))
        #expect(!style.text.contains("__ASSETS__"))
        #expect(!style.text.contains("__NAV__"))
        #expect((style.json["glyphs"] as? String) == "file://" + assets.path + "/fonts/{fontstack}/{range}.pbf")
        #expect(style.json["sprite"] == nil)
        let sources = try #require(style.json["sources"] as? [String: [String: Any]])
        #expect(Array(sources.keys) == ["nav"])
        #expect(sources["nav"]?["type"] as? String == "vector")
        #expect(sources["nav"]?["url"] as? String == "pmtiles://file://" + navTiles.path)
    }

    @Test func everyLabelUsesTheOneBundledFont() throws {
        let style = try resolved()
        let layers = try #require(style.json["layers"] as? [[String: Any]])
        #expect(layers.compactMap { $0["id"] as? String } == [
            "background", "states", "airspace-e5-band", "airspace-e5-band-mid", "airspace-e5-band-near",
            "sua-band", "sua-band-mid", "sua-band-near", "sua", "sua-label",
            "airspace-e-band", "airspace-e-band-mid", "airspace-e-band-near", "airspace-e",
            "airspace-band", "airspace-band-mid", "airspace-band-near",
            "airspace-b", "airspace-c", "airspace-d",
            "airspace-label", "airspace-label-d",
            "airways", "airways-label", "pja", "obstacles", "obstacles-label", "fixes", "fixes-label", "navaids", "navaids-label",
            "surface-aprons", "surface-buildings", "taxiways", "hold-lines", "fbos", "taxiways-label", "fbos-label",
            "runways", "runways-closed", "runway-numbers",
            "fuel-jet", "fuel-100ll", "airports", "airports-label", "airports-private", "airports-private-label"])
        let fonts = layers.compactMap { ($0["layout"] as? [String: Any])?["text-font"] as? [String] }
        #expect(fonts.count == 15)
        #expect(fonts.allSatisfy { $0 == ["Noto Sans Regular"] }, "\(fonts)")
        // A font named anywhere else in the text, such as inside an expression, must be the same one.
        let named = Set(style.text.matches(of: /"(Noto Sans [^"]*)"/).map { String($0.1) })
        #expect(named == ["Noto Sans Regular"])
        #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("fonts/Noto Sans Regular/0-255.pbf").path))
    }

    @Test func everyStyleLayerBelongsToOneSwitch() throws {
        let layers = try #require(try resolved().json["layers"] as? [[String: Any]])
        let drawn = Set(layers.compactMap { $0["id"] as? String }).subtracting(["background", "states"])
        let switched = NavOverlay.groups.flatMap(\.layers)
        #expect(Set(switched) == drawn)
        #expect(switched.count == Set(switched).count)
        #expect(NavOverlay.layerGroup.title == "Aeronautical")
        #expect(NavOverlay.layerGroup.overlays.map(\.id) == ["nav-airports", "nav-private", "nav-navaids", "nav-fixes",
                                                             "nav-airways", "nav-airspace", "nav-sua", "nav-obstacles",
                                                             "nav-fuel-100ll", "nav-fuel-jet"])
        #expect(NavOverlay.layerGroup.overlays.filter(\.isOn).map(\.id)
                == ["nav-airports", "nav-navaids", "nav-airspace", "nav-sua"])
    }

    @Test func privateAirportsAreMarkedInWords() throws {
        let text = try resolved().text
        #expect(text.contains(" PVT"))
    }

    @Test func nightGlassIsHeavierAndInkReachesContrast() {
        #expect(PanelGlass.tint(dark: false, night: false) == 0.50)
        #expect(PanelGlass.tint(dark: true, night: false) > PanelGlass.tint(dark: false, night: false))
        #expect(PanelGlass.tint(dark: true, night: true) > PanelGlass.tint(dark: true, night: false))
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let lightIC = UITraitCollection(traitsFrom: [light, UITraitCollection(accessibilityContrast: .high)])
        let darkIC = UITraitCollection(traitsFrom: [dark, UITraitCollection(accessibilityContrast: .high)])
        for ink in [PanelInk.warningColor, PanelInk.dangerColor] {
            for traits in [light, lightIC] { #expect(PanelInk.contrast(ink.resolvedColor(with: traits), .white) >= 7) }
            for traits in [dark, darkIC] { #expect(PanelInk.contrast(ink.resolvedColor(with: traits), .black) >= 7) }
        }
        for night in [false, true] {
            #expect(PanelInk.contrast(MapInk.route(night: night), MapInk.routeCasing(night: night)) >= 4.5)
        }
        #expect(PanelInk.contrast(MapInk.routeFill(night: false), .white) >= 4.5)
        #expect(PanelInk.contrast(MapInk.routeFill(night: true), .white) >= 7)
    }

    // A military field is private use in the FAA file, and its tower still puts it on the chart.
    @Test func toweredFieldsAreDrawnWithThePublicOnesWhateverTheirUse() throws {
        let layers = try #require(try resolved().json["layers"] as? [[String: Any]])
        func matches(_ id: String, _ feature: [String: Any]) throws -> Bool {
            let layer = try #require(layers.first { $0["id"] as? String == id })
            return NSPredicate(mglJSONObject: try #require(layer["filter"])).evaluate(with: feature)
        }
        let military: [String: Any] = ["type": "A", "use": "PR", "twr": 1]
        let strip: [String: Any] = ["type": "A", "use": "PR", "twr": 0]
        let open: [String: Any] = ["type": "A", "use": "PU", "twr": 0]
        let heliport: [String: Any] = ["type": "H", "use": "PR", "twr": 1]
        for id in ["airports", "airports-label"] {
            #expect(try matches(id, military), "\(id)")
            #expect(try matches(id, open), "\(id)")
            #expect(try !matches(id, strip), "\(id)")
            #expect(try !matches(id, heliport), "\(id)")
        }
        for id in ["airports-private", "airports-private-label"] {
            #expect(try !matches(id, military), "\(id)")
            #expect(try !matches(id, open), "\(id)")
            #expect(try matches(id, strip), "\(id)")
        }
    }

    @Test func privateAirfieldsHaveTheirOwnSwitchOffByDefaultAndNeedZoom10() throws {
        let group = try #require(NavOverlay.layerGroup.overlays.first { $0.id == "nav-private" })
        #expect(!group.isOn)
        let layers = try #require(try resolved().json["layers"] as? [[String: Any]])
        func layer(_ id: String) throws -> [String: Any] { try #require(layers.first { $0["id"] as? String == id }) }
        for id in ["airports-private", "airports-private-label"] {
            let found = try layer(id)
            #expect(found["minzoom"] as? Int == 10)
            #expect("\(found["filter"] ?? "")".contains("!="))
        }
        for id in ["airports", "airports-label"] {
            let found = try layer(id)
            #expect("\(found["filter"] ?? "")".contains("PU") && !"\(found["filter"] ?? "")".contains("!="))
        }
    }

    // As on the sectional: Class E from 700 ft is a soft band inside its edge, never a hard line.
    @Test func classEFrom700FeetIsABandInsideTheEdge() throws {
        let layers = try #require(try resolved().json["layers"] as? [[String: Any]])
        let e5 = layers.filter { $0["source-layer"] as? String == "class_e5" }
        #expect(e5.compactMap { $0["id"] as? String } == ["airspace-e5-band", "airspace-e5-band-mid", "airspace-e5-band-near"])
        for layer in e5 {
            let paint = try #require(layer["paint"] as? [String: Any])
            #expect(paint["line-offset"] != nil && paint["line-dasharray"] == nil)
        }
    }

    // Airport circles share the Class C color, so each layer is drawn with nothing else beside it.
    @Test func inAMapBuiltHereRingsAndLabelsDraw() async throws {
        // The background alone is the baseline: no magenta, and any maker's mark the engine adds is in it.
        let plain = try await render(styleFile(keeping: ["background"], chart: false), name: "nav-overlay-plain")
        let plainMagenta = try share(of: plain, near: 161, 40, 122, tolerance: 30)
        let plainGray = try share(of: plain, near: 127, 127, 127, tolerance: 6)
        #expect(plainMagenta == 0, "magenta \(plainMagenta)")
        #expect(plainGray > 0.98, "gray \(plainGray)")

        // Class C alone: the Austin rings in magenta and the plain background everywhere else.
        let rings = try await render(styleFile(keeping: ["background", "airspace-c"], chart: false),
                                     name: "nav-overlay-rings")
        let magenta = try share(of: rings, near: 156, 39, 136, tolerance: 30)
        let ringGray = try share(of: rings, near: 127, 127, 127, tolerance: 6)
        #expect(magenta > 0.001, "magenta \(magenta)")
        #expect(ringGray > 0.95, "gray \(ringGray)")

        // Airport labels alone: any change from the baseline means glyphs loaded from the bundled folder.
        let labels = try await render(styleFile(keeping: ["background", "airports-label"], chart: false),
                                      name: "nav-overlay-labels")
        let ink = try difference(plain, labels)
        #expect(ink > 0.0003, "label ink \(ink)")

        // Every layer together, from the style file the app itself writes.
        let file = try #require(NavOverlay.styleURL(tiles: navTiles))
        let all = try await render(file, name: "nav-overlay-alone")
        let drawn = try difference(plain, all)
        #expect(drawn > magenta && drawn < 0.5, "drawn \(drawn)")
    }

    @Test func inAMapBuiltHereTheOverlayChangesTheChart() async throws {
        let chartOnly = try await render(styleFile(keeping: ["background"], chart: true), name: "nav-chart-only")
        // The chart covers the background, so almost none of the plain gray is left.
        let gray = try share(of: chartOnly, near: 127, 127, 127, tolerance: 6)
        #expect(gray < 0.3, "gray \(gray)")
        // Drawn above the chart the overlay changes the picture. Drawn under it, or left out, it would change nothing.
        let both = try await render(styleFile(keeping: nil, chart: true), name: "nav-overlay-austin")
        let changed = try difference(chartOnly, both)
        #expect(changed > 0.005, "changed \(changed)")
    }
}

@Suite @MainActor struct NavNightTests {
    private func paints() throws -> [(layer: String, property: String, value: Any)] {
        NavOverlay.colorPaints(try Data(contentsOf: assets.appendingPathComponent("nav-style.json")))
    }

    @Test func nightSwapsEveryDayInkAndLeavesDayAlone() throws {
        let match: [Any] = ["match", ["get", "type"], ["P", "R", "W"], "#1557b0", "#9c2788"]
        #expect(NavOverlay.ink(match, night: true) as? NSArray
            == ["match", ["get", "type"], ["P", "R", "W"], "#7fb0f2", "#d985c6"] as NSArray)
        #expect(NavOverlay.ink(match, night: false) as? NSArray == match as NSArray)
        #expect(NavOverlay.ink("#FFFFFF", night: true) as? String == "#1e1d1b")
        #expect(NavOverlay.property("text-halo-color") == "textHaloColor")
        #expect(NavOverlay.property("line-color") == "lineColor")
    }

    @Test func everyOverlayColorHasANightInk() throws {
        let found = try paints()
        #expect(found.contains { $0.layer == "airports-label" && $0.property == "textHaloColor" })
        #expect(found.contains { $0.layer == "airspace-e5-band" && $0.property == "lineColor" })
        #expect(!found.contains { $0.layer == "background" })
        for paint in found {
            let night = "\(NavOverlay.ink(paint.value, night: true))".lowercased()
            // No day ink survives, so nothing white and no dark text is left on the dark chart.
            for day in NightInk.inks.keys { #expect(!night.contains(day), "\(paint.layer) \(paint.property)") }
        }
    }

    @Test func nightInksAreAcceptedByMapLibre() throws {
        let source = MLNShapeSource(identifier: "s", shape: nil)
        let layers: [String: MLNStyleLayer] = [
            "line": MLNLineStyleLayer(identifier: "l", source: source),
            "symbol": MLNSymbolStyleLayer(identifier: "t", source: source),
            "circle": MLNCircleStyleLayer(identifier: "c", source: source),
            "fill": MLNFillStyleLayer(identifier: "f", source: source),
        ]
        for paint in try paints() {
            let kind = ["text": "symbol", "circle": "circle", "fill": "fill"]
                .first { paint.property.hasPrefix($0.key) }?.value ?? "line"
            let layer = try #require(layers[kind])
            layer.setValue(NavOverlay.expression(NavOverlay.ink(paint.value, night: true)), forKey: paint.property)
            #expect(layer.value(forKey: paint.property) != nil)
        }
    }
}
