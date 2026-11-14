import Foundation
import Testing
@testable import FlightCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func file(_ layer: String, _ region: String, cycle: String = "c1",
                  effective: Date = .distantPast, expires: Date = .distantFuture) -> PackFile {
    PackFile(pack: InstalledPack(id: PackID(cycle: cycle, layer: layer, region: region),
                                 effective: effective, expires: expires),
             url: URL(fileURLWithPath: "/packs/\(cycle)/\(layer)/\(region).pmtiles"))
}

private func identifiers(_ spec: MapStyleSpec) -> [String] {
    if case .charts(let rasters) = spec.content { return rasters.map(\.identifier) }
    return []
}

@Suite struct MapStyleSpecTests {
    @Test func chartsAreOrderedOverviewThenStateThenTerminal() {
        let installed = [file("vfr-tac", "TX"), file("vfr", "TX"), file("vfr", "overview"),
                         file("vfr", "OK"), file("ifr-low", "TX")]
        let spec = MapStyleSpec.make(base: .vfr, installed: installed, night: false, now: now)
        #expect(identifiers(spec) == ["vfr:overview", "vfr:OK", "vfr:TX", "vfr-tac:TX"])
    }

    // Two sources with one name would stop the map, so a dash in a region must not read as part of the layer.
    @Test func layerAndRegionNamesThatJoinAlikeStayDistinct() {
        let installed = [file("vfr", "tac-TX"), file("vfr-tac", "TX")]
        let found = identifiers(MapStyleSpec.make(base: .vfr, installed: installed, night: false, now: now))
        #expect(found == ["vfr:tac-TX", "vfr-tac:TX"])
        #expect(Set(found).count == 2)
    }

    @Test func ifrLowUsesTheSameTwoLayerPattern() {
        let installed = [file("ifr-area", "TX"), file("ifr-low", "TX"), file("vfr", "TX")]
        let spec = MapStyleSpec.make(base: .ifrLow, installed: installed, night: false, now: now)
        #expect(identifiers(spec) == ["ifr-low:TX", "ifr-area:TX"])
    }

    @Test func noPackForTheSelectedChartSaysSo() {
        let onlyVFR = [file("vfr", "TX")]
        #expect(MapStyleSpec.make(base: .ifrLow, installed: onlyVFR, night: false, now: now).content
            == .nothing("No IFR Low chart downloaded"))
        #expect(MapStyleSpec.make(base: .vfr, installed: [], night: false, now: now).content
            == .nothing("No VFR chart downloaded"))
        #expect(MapStyleSpec.make(base: .ifrHigh, installed: onlyVFR + [file("ifr-low", "TX")], night: false, now: now)
            .content == .nothing("No IFR High chart downloaded"))
        #expect(identifiers(MapStyleSpec.make(base: .ifrHigh, installed: [file("ifr-high", "TX")], night: false, now: now))
            == ["ifr-high:TX"])
        #expect(MapStyleSpec.make(base: .vfrFlyway, installed: onlyVFR, night: false, now: now).content
            == .nothing("No VFR Flyway downloaded"))
        #expect(identifiers(MapStyleSpec.make(base: .vfrFlyway, installed: [file("vfr-flyway", "CA")], night: false,
                                              now: now)) == ["vfr-flyway:CA"])
    }

    @Test func packNotYetInEffectIsStillDrawn() {
        let future = file("vfr", "TX", cycle: "c2", effective: now + 7 * day, expires: now + 63 * day)
        let spec = MapStyleSpec.make(base: .vfr, installed: [future], night: false, now: now)
        #expect(spec.content == .charts([MapStyleSpec.Raster(identifier: "vfr:TX", url: future.url)]))
    }

    @Test func currentCycleIsDrawnUntilTheNextOneTakesEffect() {
        let current = file("vfr", "TX", cycle: "c1", effective: now - 50 * day, expires: now + 6 * day)
        let next = file("vfr", "TX", cycle: "c2", effective: now + 6 * day, expires: now + 62 * day)
        let before = MapStyleSpec.make(base: .vfr, installed: [next, current], night: false, now: now)
        #expect(before.content == .charts([MapStyleSpec.Raster(identifier: "vfr:TX", url: current.url)]))
        let after = MapStyleSpec.make(base: .vfr, installed: [next, current], night: false, now: now + 7 * day)
        #expect(after.content == .charts([MapStyleSpec.Raster(identifier: "vfr:TX", url: next.url)]))
    }

    @Test func expiredPackIsStillDrawn() {
        let old = file("vfr", "TX", effective: now - 80 * day, expires: now - 24 * day)
        #expect(identifiers(MapStyleSpec.make(base: .vfr, installed: [old], night: false, now: now)) == ["vfr:TX"])
    }

    @Test func streetShowsEveryPackInView() {
        let street = MapStyleSpec.streetLayer
        let texas = file(street, "TX"), oklahoma = file(street, "OK"), arkansas = file(street, "AR")
        var boxes = [texas.url: MapStyleSpec.Box(minLatitude: 25.8, minLongitude: -106.7, maxLatitude: 36.5, maxLongitude: -93.5),
                     oklahoma.url: MapStyleSpec.Box(minLatitude: 33.6, minLongitude: -103, maxLatitude: 37, maxLongitude: -94.4),
                     arkansas.url: MapStyleSpec.Box(minLatitude: 33, minLongitude: -94.6, maxLatitude: 36.5, maxLongitude: -89.6)]
        func shown(_ latitude: Double, _ longitude: Double, span: Double = 0.2,
                   _ installed: [PackFile] = [oklahoma, texas, arkansas]) -> MapStyleSpec.Content {
            let view = MapStyleSpec.Box(minLatitude: latitude - span, minLongitude: longitude - span,
                                        maxLatitude: latitude + span, maxLongitude: longitude + span)
            return MapStyleSpec.make(base: .street, installed: installed, night: false, now: now,
                                     view: view, bounds: { boxes[$0] }).content
        }
        #expect(shown(30.2, -97.7) == .street([texas.url]))
        // The Red River near Denison: both sides draw, in pack order.
        #expect(shown(33.8, -96.6) == .street([oklahoma.url, texas.url]))
        // Texarkana meets Arkansas and Texas.
        #expect(shown(33.4, -94.05) == .street([arkansas.url, texas.url]))
        // Kansas is in no box; Oklahoma is nearest.
        #expect(shown(38.5, -98) == .street([oklahoma.url]))
        // A view over many packs keeps the four nearest its middle.
        let many = (0..<6).map { file(street, "S\($0)") }
        for (index, pack) in many.enumerated() {
            boxes[pack.url] = MapStyleSpec.Box(minLatitude: 30, minLongitude: -100 + Double(index),
                                               maxLatitude: 31, maxLongitude: -99 + Double(index))
        }
        #expect(shown(30.5, -97.2, span: 4, many) == .street(many[1...4].map(\.url)))
        // With no view the first in order is shown.
        #expect(MapStyleSpec.make(base: .street, installed: [texas, oklahoma], night: false, now: now).content
            == .street([oklahoma.url]))
    }

    @Test func streetStyleRepeatsLayersPerPack() throws {
        let template = """
        {"version":8,"glyphs":"__ASSETS__/fonts/{fontstack}/{range}.pbf",
         "sources":{"protomaps":{"type":"vector","url":"__PMTILES__"},"other":{"type":"geojson","data":"x"}},
         "layers":[{"id":"background","type":"background"},
                   {"id":"water","type":"fill","source":"protomaps"},
                   {"id":"pin","type":"circle","source":"other"},
                   {"id":"label","type":"symbol","source":"protomaps"}]}
        """
        let packs = [URL(fileURLWithPath: "/p/OK.pmtiles"), URL(fileURLWithPath: "/p/TX.pmtiles")]
        let text = try MapStyleSpec.streetStyle(template: template, assets: "asset:/", packs: packs)
        let style = try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
        guard case .array(let layers)? = style["layers"], case .object(let sources)? = style["sources"] else {
            Issue.record("no layers or sources"); return
        }
        #expect(layers.map { $0["id"]?.string } == ["background", "water", "water~1", "pin", "label", "label~1"])
        #expect(layers.map { $0["source"]?.string } == [nil, "protomaps", "protomaps~1", "other", "protomaps", "protomaps~1"])
        #expect(sources["protomaps"]?["url"]?.string == "pmtiles://file:///p/OK.pmtiles")
        #expect(sources["protomaps~1"]?["url"]?.string == "pmtiles://file:///p/TX.pmtiles")
        #expect(sources["other"] != nil && sources.count == 3)
        #expect(style["glyphs"]?.string == "asset://fonts/{fontstack}/{range}.pbf")
    }

    @Test func streetStyleCarriesTheNavOverlay() throws {
        let template = """
        {"version":8,"sources":{"protomaps":{"type":"vector","url":"__PMTILES__"}},
         "layers":[{"id":"background","type":"background"},
                   {"id":"water","type":"fill","source":"protomaps"},
                   {"id":"label","type":"symbol","source":"protomaps"}]}
        """
        let overlay = """
        {"version":8,"sources":{"nav":{"type":"vector","url":"pmtiles://file:///n.pmtiles"}},
         "layers":[{"id":"background","type":"background","paint":{"background-color":"#7f7f7f"}},
                   {"id":"airspace","type":"line","source":"nav","paint":{"line-color":"#1557b0"}},
                   {"id":"airports","type":"circle","source":"nav","paint":{"circle-color":"#ffffff"}},
                   {"id":"airports-label","type":"symbol","source":"nav"}]}
        """
        let packs = [URL(fileURLWithPath: "/p/OK.pmtiles"), URL(fileURLWithPath: "/p/TX.pmtiles")]
        let text = try MapStyleSpec.streetStyle(template: template, assets: "asset:/", packs: packs,
                                                overlay: overlay, night: true)
        let style = try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
        guard case .array(let layers)? = style["layers"] else { Issue.record("no layers"); return }
        // Airspace sits under the street labels; airports and their labels sit over them.
        #expect(layers.map { $0["id"]?.string }
            == ["background", "water", "water~1", "airspace", "label", "label~1", "airports", "airports-label"])
        #expect(style["sources"]?["nav"]?["url"]?.string == "pmtiles://file:///n.pmtiles")
        #expect(layers[3]["paint"]?["line-color"]?.string == NightInk.swap("#1557b0"))
        #expect(layers[6]["paint"]?["circle-color"]?.string == "#1e1d1b")
    }

    @Test func streetNeedsAPackAndAerialNeedsNone() {
        let street = file(MapStyleSpec.streetLayer, "TX")
        #expect(MapStyleSpec.make(base: .street, installed: [street], night: false, now: now).content
            == .street([street.url]))
        #expect(MapStyleSpec.make(base: .street, installed: [], night: false, now: now).content
            == .nothing("No street map downloaded"))
        #expect(MapStyleSpec.make(base: .aerial, installed: [], night: true, now: now)
            == MapStyleSpec(content: .aerial, night: true))
    }

    @Test func terrainDrawsEveryStatePackAndNoChartBanner() {
        let packs = [file(MapStyleSpec.terrainLayer, "AL"), file(MapStyleSpec.terrainLayer, "GA"), file("vfr", "AL")]
        guard case .terrain(let shown) = MapStyleSpec.make(base: .terrain, installed: packs, night: false, now: now).content
        else { Issue.record("no terrain"); return }
        #expect(shown.map(\.identifier) == ["terrain:AL", "terrain:GA"])
        #expect(MapStyleSpec.make(base: .terrain, installed: [packs[2]], night: false, now: now).content
            == .nothing("No terrain map downloaded"))
        #expect(BaseLayer.terrain.packLayers.isEmpty)
        #expect(LayerMenu.bases[0] == [.street, .aerial, .terrain])
    }

    @Test func terrainDimsAtNightWithoutInverting() {
        let night = NightPaint.terrainValues(night: true)
        #expect(night.hueRotation == 0 && night.minimumBrightness == 0 && night.maximumBrightness < 0.6)
        #expect(NightPaint.terrainValues(night: false) == NightPaint.values(night: false))
    }

    @Test func streetWithNoStyleSaysSo() {
        let pack = URL(fileURLWithPath: "/tmp/street.pmtiles")
        let street = MapStyleSpec(content: .street([pack]), night: true)
        #expect(street.resolved(streetStyle: nil)
            == MapStyleSpec(content: .nothing("Street map unavailable"), night: true))
        #expect(street.resolved(streetStyle: pack) == street)
        let aerial = MapStyleSpec(content: .aerial, night: false)
        #expect(aerial.resolved(streetStyle: nil) == aerial)
    }

    @Test func nightChangesTheSpecAndThePaint() {
        let installed = [file("vfr", "TX")]
        #expect(MapStyleSpec.make(base: .vfr, installed: installed, night: true, now: now)
            != MapStyleSpec.make(base: .vfr, installed: installed, night: false, now: now))
        #expect(NightPaint.values(night: true)
            == NightPaint.Values(minimumBrightness: 0.8, maximumBrightness: 0, hueRotation: 180))
        #expect(NightPaint.values(night: false)
            == NightPaint.Values(minimumBrightness: 0, maximumBrightness: 1, hueRotation: 0))
    }

    @Test func nightBackgroundIsDarkAndDayIsMidGray() {
        #expect(NightPaint.backgroundWhite(night: true) < 0.15)
        #expect(NightPaint.backgroundWhite(night: false) > 0.4)
    }
}
