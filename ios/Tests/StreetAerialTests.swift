import FlightCore
import CoreLocation
import Foundation
import MapLibre
import Testing
import UIKit
@testable import Blueside

private let assets = Bundle.main.resourceURL!.appendingPathComponent("MapAssets")
private let testPack = assets.appendingPathComponent("test-street.pmtiles")
private let liveAerial = ProcessInfo.processInfo.environment["LIVE_AERIAL"] == "1"

private func resolved(dark: Bool) throws -> (text: String, json: [String: Any]) {
    let text = try StreetStyle.json(packs: [testPack], dark: dark, assets: assets)
    let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    return (text, json)
}

// Font names are a plain list of strings, or the list that follows "literal" inside an expression.
private func fontNames(in value: Any, top: Bool = true) -> [String] {
    guard let list = value as? [Any] else { return [] }
    if top, let names = list as? [String] { return names }
    if list.first as? String == "literal" { return list.dropFirst().flatMap { $0 as? [String] ?? [] } }
    return list.flatMap { fontNames(in: $0, top: false) }
}

// Draws a style to a PNG with no view on screen, and saves it where the screenshots go.
@MainActor private func render(_ style: URL, zoom: Double, name: String,
                               center: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 32.8968, longitude: -97.0380)) async throws -> Data {
    let camera = MLNMapCamera(lookingAtCenter: center, altitude: 10_000, pitch: 0, heading: 0)
    let options = MLNMapSnapshotOptions(styleURL: style, camera: camera, size: CGSize(width: 1024, height: 768))
    options.zoomLevel = zoom
    let snapshotter = MLNMapSnapshotter(options: options)
    let result: (png: Data?, error: String?) = await withCheckedContinuation { continuation in
        snapshotter.start { snapshot, error in
            continuation.resume(returning: (snapshot?.image.pngData(), error.map { "\($0)" }))
        }
    }
    withExtendedLifetime(snapshotter) {}
    // A snapshot fails as a whole when any tile, font range or icon it asks for cannot be read.
    let data = try #require(result.png, "the map drew nothing for \(name): \(result.error ?? "no error given")")
    if let folder = ProcessInfo.processInfo.environment["SHOT_DIR"] {
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    return data
}

@Suite @MainActor struct StreetAerialTests {
    @Test func streetStylesHoldNoRemoteAddress() throws {
        for dark in [false, true] {
            let style = try resolved(dark: dark)
            #expect(!style.text.contains("http://"), "dark \(dark)")
            #expect(!style.text.contains("https://"), "dark \(dark)")
            #expect(!style.text.contains("__ASSETS__"))
            #expect(!style.text.contains("__PMTILES__"))
            #expect((style.json["glyphs"] as? String)?.hasPrefix("file:///") == true)
            #expect((style.json["sprite"] as? String)?.hasSuffix(dark ? "/sprites/dark" : "/sprites/light") == true)
            let sources = try #require(style.json["sources"] as? [String: [String: Any]])
            #expect(sources.count == 1)
            #expect(sources.values.first?["url"] as? String == "pmtiles://file://" + testPack.path)
            #expect((style.json["layers"] as? [Any])?.count ?? 0 > 50)
        }
    }

    @Test func everyFontTheStyleNamesIsBundled() throws {
        for dark in [false, true] {
            let layers = try #require(try resolved(dark: dark).json["layers"] as? [[String: Any]])
            let fonts = Set(layers.compactMap { ($0["layout"] as? [String: Any])?["text-font"] }
                .flatMap { fontNames(in: $0) })
            // Operators such as "case" or "get" in this set mean the reader walked into an expression.
            #expect(fonts.allSatisfy { $0.hasPrefix("Noto Sans ") }, "\(fonts.sorted())")
            #expect(fonts.count == 3, "\(fonts.sorted())")
            // A label can also switch font inside its text, so every font named anywhere must be one of these.
            let named = Set(try resolved(dark: dark).text.matches(of: /"(Noto Sans [^"]*)"/).map { String($0.1) })
            #expect(named == fonts, "\(named.sorted())")
            // One unreadable range leaves a whole tile without labels, so every range must be there.
            for font in fonts {
                let missing = (0..<256).map { "\($0 * 256)-\($0 * 256 + 255)" }.filter {
                    !FileManager.default.fileExists(atPath: assets.appendingPathComponent("fonts/\(font)/\($0).pbf").path)
                }
                #expect(missing.isEmpty, "\(font) lacks \(missing.count) ranges, first \(missing.prefix(3))")
            }
        }
    }

    @Test func spritesAreBundledForBothFlavors() {
        for name in ["light", "dark", "light@2x", "dark@2x"] {
            for kind in ["json", "png"] {
                let file = assets.appendingPathComponent("sprites/\(name).\(kind)")
                #expect(FileManager.default.fileExists(atPath: file.path), "\(name).\(kind) is not bundled")
            }
        }
    }

    @Test func streetPackBoundsComeFromItsHeader() throws {
        let box = try #require(PackCoverage.bounds(testPack))
        #expect(box.minLatitude < box.maxLatitude && box.minLongitude < box.maxLongitude)
        #expect((-180...180).contains(box.minLongitude) && (-90...90).contains(box.maxLatitude))
    }

    // A PMTiles v3 header holds the tile type at byte 99; 1 is vector tiles.
    @Test func testStreetPackIsASmallVectorPack() throws {
        let header = try Data(contentsOf: testPack)
        #expect(header.count < 5_000_000)
        #expect(Array(header.prefix(7)) == Array("PMTiles".utf8))
        #expect(header[99] == 1)
        #expect(header[101] == 10)
    }

    @Test func aerialStopsAtZoom16AndCarriesItsCredit() {
        #expect(AerialSource.maximumZoom == 16)
        #expect(AerialSource.template.hasSuffix("/tile/{z}/{y}/{x}"))
        #expect(AerialSource.template.hasPrefix("https://basemap.nationalmap.gov/"))
        #expect(AerialSource.credit.contains("USGS"))
        #expect(AerialSource.make().identifier == "aerial")
    }

    @Test func streetDrawsFromBundledFiles() async throws {
        for dark in [false, true] {
            let style = try #require(StreetStyle.styleURL(packs: [testPack], dark: dark))
            let png = try await render(style, zoom: 9, name: dark ? "street-dark" : "street-light")
            #expect(png.count > 60_000, "the street map is flat, dark \(dark)")
        }
    }

    // Two packs over one place draw as one map: same tiles, labels kept once by collision.
    @Test func twoStreetPacksDrawTogether() async throws {
        let style = try #require(StreetStyle.styleURL(packs: [testPack, testPack], dark: false))
        let png = try await render(style, zoom: 9, name: "street-two-packs")
        #expect(png.count > 60_000, "two packs drew a flat map")
    }

    // The world tile in every pack names places in Cyrillic, Arabic and Han next to their English names.
    @Test func streetDrawsWhereNamesUseOtherScripts() async throws {
        let style = try #require(StreetStyle.styleURL(packs: [testPack], dark: false))
        let png = try await render(style, zoom: 1, name: "street-world",
                                   center: CLLocationCoordinate2D(latitude: 40, longitude: -100))
        #expect(png.count > 20_000, "the world view is flat")
    }

    // Needs the internet, so it is off by default. Zoom 17 is past the deepest tiles the service has.
    @Test(.enabled(if: liveAerial)) func aerialDrawsPastItsDeepestZoom() async throws {
        let json = """
        {"version":8,"sources":{"aerial":{"type":"raster","tiles":["\(AerialSource.template)"],\
        "tileSize":256,"maxzoom":\(AerialSource.maximumZoom)}},\
        "layers":[{"id":"aerial","type":"raster","source":"aerial"}]}
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aerial-check.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let png = try await render(file, zoom: 17, name: "aerial")
        #expect(png.count > 300_000, "the imagery did not draw")
        // A wider view, so the saved picture shows the whole airfield.
        let wide = try await render(file, zoom: 12, name: "aerial-wide")
        #expect(wide.count > 300_000, "the wide imagery did not draw")
    }
}
