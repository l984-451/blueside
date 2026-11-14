import FlightCore
import Foundation
import Testing
@testable import Blueside

// -reset clears what an earlier UI run saved, such as night mode.
private let fresh = LaunchOptions(arguments: ["-reset", "1"])

@MainActor @Test func modelDefaultsWithNoOptions() {
    let model = AppModel(options: fresh)
    #expect(model.baseLayer == .vfr)
    #expect(!model.nightMode)
    #expect(model.orientation == .northUp)
    #expect(model.position == nil)
    #expect(model.installedPacks.isEmpty)
}

@MainActor @Test func optionsSetTheStartingState() {
    let model = AppModel(options: LaunchOptions(arguments: [
        "-base", "ifr-low", "-night", "1", "-orientation", "trackUp",
    ]))
    #expect(model.baseLayer == .ifrLow)
    #expect(model.nightMode)
    #expect(model.orientation == .trackUp)
}

@MainActor @Test func unknownOptionValuesFallBackToDefaults() {
    let model = AppModel(options: LaunchOptions(arguments: [
        "-base", "moon", "-orientation", "sideways", "-basePack", "missing",
    ]))
    #expect(model.baseLayer == .vfr)
    #expect(model.orientation == .northUp)
    #expect(model.installedPacks.isEmpty)
}

// Night mode makes the interface dark. With it off the device decides, unless the launch asks for dark.
@MainActor @Test func theInterfaceIsForcedDarkOnlyByNightModeOrTheLaunchOption() {
    let model = AppModel(options: fresh)
    #expect(!model.forcesDark)
    model.nightMode = true
    #expect(model.forcesDark)
    #expect(AppModel(options: LaunchOptions(arguments: ["-appearance", "dark"])).forcesDark)
    #expect(!AppModel(options: LaunchOptions(arguments: ["-reset", "1", "-appearance", "light"])).forcesDark)
}

@MainActor @Test func basePackOptionLoadsTheBundledPacks() {
    let model = AppModel(options: LaunchOptions(arguments: ["-basePack", "test"]))
    #expect(model.installedPacks.map(\.pack.id.layer) == ["vfr", "vfr-tac", "ifr-low", "ifr-area", "street"])
    #expect(model.installedPacks.allSatisfy { $0.pack.id.region == "test" })
    #expect(model.installedPacks.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    let shown = ChartLibrary.packToShow(layer: "vfr", region: "test",
                                        installed: model.installedPacks.map(\.pack), now: Date())
    #expect(shown == model.installedPacks.first?.pack)
}

@Test func baseLayersNameTheirChartPacks() {
    #expect(BaseLayer.vfr.packLayers == ["vfr", "vfr-tac"])
    #expect(BaseLayer.ifrLow.packLayers == ["ifr-low", "ifr-area"])
    #expect(BaseLayer.street.packLayers.isEmpty)
    #expect(BaseLayer.aerial.packLayers.isEmpty)
    #expect(BaseLayer(rawValue: "ifr-low") == .ifrLow)
    #expect(BaseLayer(rawValue: "ifr-high")?.packLayers == ["ifr-high"])
}

// A PMTiles v3 header holds the tile type at byte 99 (4 is WebP) and min and max zoom at 100 and 101.
@Test func bundledPacksHaveTheZoomRangesTheMapReliesOn() throws {
    let expected: [(name: String, minZoom: UInt8, maxZoom: UInt8)] = [
        ("test-vfr", 5, 12), ("test-vfr-tac", 13, 13), ("test-ifr-low", 5, 12), ("test-ifr-area", 13, 13),
    ]
    for pack in expected {
        let url = try #require(Bundle.main.url(forResource: pack.name, withExtension: "pmtiles",
                                               subdirectory: "MapAssets"), "\(pack.name) is not bundled")
        let header = try Data(contentsOf: url)
        #expect(header.count < 5_000_000, "\(pack.name) is too large to keep in the repo")
        #expect(Array(header.prefix(7)) == Array("PMTiles".utf8), "\(pack.name) magic")
        #expect(header[99] == 4, "\(pack.name) tile type")
        #expect(header[100] == pack.minZoom, "\(pack.name) min zoom")
        #expect(header[101] == pack.maxZoom, "\(pack.name) max zoom")
    }
}
