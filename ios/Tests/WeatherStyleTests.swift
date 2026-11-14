import FlightCore
import Foundation
import MapLibre
import Testing
import UIKit
@testable import Blueside

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct WeatherStyleTests {
    private var assets: URL { Bundle.main.resourceURL!.appendingPathComponent("MapAssets") }
    private func emptyStyle() throws -> Data { try Data(contentsOf: assets.appendingPathComponent("empty.json")) }
    private var allLayers: [[String: Any]] { WeatherStyle.drawn.flatMap(WeatherStyle.layers(for:)) }

    @Test func mergedStyleKeepsTheBaseAndAddsWeatherOnTop() throws {
        let style = try object(try WeatherStyle.merged(into: try emptyStyle(), assets: assets))
        let ids = try #require(style["layers"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        #expect(ids.first == "background")
        #expect(Array(ids.dropFirst()) == WeatherStyle.drawn.flatMap(WeatherStyle.layerIDs(for:)))
        #expect(ids.last == "wx-stations-label")
        #expect(style["glyphs"] as? String == "file://\(assets.path)/fonts/{fontstack}/{range}.pbf")
        let sources = try #require(style["sources"] as? [String: Any])
        #expect(Set(sources.keys) == ["wx-satellite", "wx-radar", "wx-lightning", "wx-gairmets", "wx-sigmets", "wx-cwas", "wx-tfrs", "wx-pireps", "wx-winds", "wx-stations"])
        #expect(style["version"] as? Int == 8)
    }

    @Test func whatTheBaseStyleAlreadySetsIsKept() throws {
        let base = Data(#"{"version":8,"glyphs":"x/{fontstack}/{range}.pbf","sources":{"nav":{"type":"vector"}},"layers":[]}"#.utf8)
        let style = try object(try WeatherStyle.merged(into: base, assets: assets))
        #expect(style["glyphs"] as? String == "x/{fontstack}/{range}.pbf")
        #expect((style["sources"] as? [String: Any])?["nav"] != nil)
        #expect(throws: (any Error).self) { try WeatherStyle.merged(into: Data("[]".utf8), assets: assets) }
    }

    @Test func noAddressInTheStyleLeavesThePhone() throws {
        let text = String(decoding: try WeatherStyle.merged(into: try emptyStyle(), assets: assets), as: UTF8.self)
        #expect(!text.contains("http"))
    }

    @Test func aBaseWithNoFontsGetsTheBundledOnesNotAToken() throws {
        let raster = Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8)
        let text = String(decoding: try WeatherStyle.merged(into: raster, assets: assets), as: UTF8.self)
        #expect(!text.contains("__ASSETS__"))
        #expect(text.contains("file://\(assets.path)/fonts/{fontstack}/{range}.pbf"))
    }

    @Test func outsideTheRadarGridIsShadedAsNoCoverage() throws {
        let layers = WeatherStyle.layers(for: .radar)
        #expect(layers.count == 1)
        let paint = try #require(layers.first?["paint"] as? [String: Any])
        // The same gray and alpha the pipeline's color ramp gives no coverage inside the grid: 128,128,128 at 70.
        #expect(paint["fill-color"] as? String == "#808080")
        #expect(paint["fill-opacity"] as? Double == 70.0 / 255)
        let feature = WeatherStyle.radarOutside
        let rings = try #require((feature["geometry"] as? [String: Any])?["coordinates"] as? [[[Double]]])
        #expect(rings.count == 2)
        let hole = rings[1]
        #expect(hole.map { $0[0] }.min() == -130 && hole.map { $0[0] }.max() == -60)
        #expect(hole.map { $0[1] }.min() == 20 && hole.map { $0[1] }.max() == 55)
    }

    @Test func anOldStationReportIsDrawnFaded() throws {
        let layers = WeatherStyle.layers(for: .stations)
        for id in ["wx-stations-dot", "wx-stations-cue"] {
            let layer = try #require(layers.first { $0["id"] as? String == id })
            #expect(String(describing: layer["paint"] ?? "").contains("age_min"), "\(id)")
        }
    }

    @Test func textUsesOnlyBundledFontsAndOnlyBarbsAndStationPillsUseAnImage() {
        var fonts = Set<String>()
        let pilled: Set = ["wx-stations-value", "wx-stations-label"]
        for layer in allLayers {
            let layout = layer["layout"] as? [String: Any] ?? [:]
            let id = layer["id"] as? String ?? ""
            #expect((layout["icon-image"] == nil) == (id != "wx-winds-barb" && !pilled.contains(id)), "\(id)")
            if pilled.contains(id) {
                #expect(layout["icon-image"] as? String == WeatherStyle.pill && layout["icon-text-fit"] as? String == "both")
                #expect(layout["text-allow-overlap"] == nil, "\(id) must still collide")
            }
            if layer["type"] as? String == "symbol", layout["icon-image"] == nil || pilled.contains(id) {
                #expect(layout["text-font"] != nil, "\(layer["id"] ?? "")")
            }
            fonts.formUnion(layout["text-font"] as? [String] ?? [])
        }
        #expect(!fonts.isEmpty)
        for font in fonts {
            let glyphs = assets.appendingPathComponent("fonts/\(font)/0-255.pbf")
            #expect(FileManager.default.fileExists(atPath: glyphs.path), "\(font)")
        }
    }

    @Test func layerNamesAreUniqueAndEveryLayerReadsItsOwnSource() {
        let ids = allLayers.compactMap { $0["id"] as? String }
        #expect(ids.count == allLayers.count && Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("wx-") })
        for overlay in WeatherStyle.drawn {
            for layer in WeatherStyle.layers(for: overlay) {
                #expect(layer["source"] as? String == WeatherStyle.sourceID(overlay))
            }
        }
    }

    @Test func theCategoryLetterIsDrawnWheneverTheDotIs() throws {
        let layers = WeatherStyle.layers(for: .stations)
        let dot = try #require(layers.first { $0["id"] as? String == "wx-stations-dot" })
        let cue = try #require(layers.first { $0["id"] as? String == "wx-stations-cue" })
        #expect(dot["minzoom"] as? Double == cue["minzoom"] as? Double)
        let layout = try #require(cue["layout"] as? [String: Any])
        #expect(layout["text-allow-overlap"] as? Bool == true && layout["text-ignore-placement"] as? Bool == true)
        #expect(layout["text-field"] as? [String] == ["get", "cue"])
    }

    @Test func upcomingTfrsAreDashedAndUnfilled() throws {
        let layers = WeatherStyle.layers(for: .tfrs)
        let upcoming = try #require(layers.first { $0["id"] as? String == "wx-tfrs-upcoming" })
        #expect((upcoming["paint"] as? [String: Any])?["line-dasharray"] != nil)
        let fill = try #require(layers.first { $0["id"] as? String == "wx-tfrs-fill" })
        #expect(String(describing: fill["filter"] ?? "").contains("active"))
    }

    // The window is held so the map keeps working until the checks are done.
    @Test @MainActor func theMapAcceptsEveryWeatherLayerAndSource() async throws {
        let text = String(decoding: try WeatherStyle.merged(into: try emptyStyle(), assets: assets), as: UTF8.self)
            .replacingOccurrences(of: "__ASSETS__", with: "file://" + assets.path)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wx-style-\(UUID().uuidString).json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), styleURL: file)
        let host = UIViewController()
        host.view.addSubview(map)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 where map.style == nil { try await Task.sleep(for: .milliseconds(100)) }
        let style = try #require(map.style, "the merged style did not load in 10 s")
        for overlay in WeatherStyle.drawn {
            #expect(style.source(withIdentifier: WeatherStyle.sourceID(overlay)) is MLNShapeSource, "\(overlay)")
            for id in WeatherStyle.layerIDs(for: overlay) {
                #expect(style.layer(withIdentifier: id) != nil, "\(id)")
            }
        }
        let metars = try Metar.decode(try WeatherFixture.json("metars.json.gz"))
        let shape = try MLNShape(data: WeatherGeoJSON.stations(metars, now: WeatherFixture.now),
                                 encoding: String.Encoding.utf8.rawValue)
        #expect((shape as? MLNShapeCollectionFeature)?.shapes.count == 2547)
        let source = try #require(style.source(withIdentifier: "wx-stations") as? MLNShapeSource)
        source.shape = shape
        window.isHidden = true
    }
}
