import FlightCore
import Foundation
import Observation

/// App-wide state shared by the map and everything drawn over it.
@MainActor @Observable final class AppModel {
    var baseLayer: BaseLayer
    var nightMode: Bool
    var orientation: MapOrientation
    var position: Position?
    var installedPacks: [PackFile]
    /// A keyboard command for the map screen, which takes it and clears it.
    var command: MapCommand?
    let options: LaunchOptions
    /// The map setup the app started with: what was saved, with launch options laid over it.
    let launch: MapMemory

    /// True when the interface is dark whatever the device says: at night, or when the launch asks for it.
    var forcesDark: Bool { nightMode || options.string("appearance") == "dark" }

    init(options: LaunchOptions = LaunchOptions(arguments: [])) {
        self.options = options
        // Tests pass -reset 1 so each run starts from a first launch.
        if options.flag("reset"), let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            for file in [SavedRouteStore.defaultFile, AircraftStore.defaultFile, WeatherCache.standardRoot, PlateMarkup.root] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        launch = MapMemory(text: UserDefaults.standard.string(forKey: MapMemory.key))
            .launched(base: options.string("base").flatMap(BaseLayer.init(rawValue:)),
                      night: options.string("night").map { _ in options.flag("night") },
                      orientation: options.string("orientation").flatMap(MapOrientation.init(rawValue:)),
                      center: options.coordinate("center"), zoom: options.double("zoom"), follow: options.flag("follow"))
        baseLayer = launch.base
        nightMode = launch.night
        orientation = launch.orientation
        installedPacks = options.string("basePack").map(Self.bundledPacks(named:)) ?? []
    }

    /// Packs shipped inside the app as MapAssets/<name>-<layer>.pmtiles, dated so they never expire.
    static func bundledPacks(named name: String) -> [PackFile] {
        (BaseLayer.allCases.flatMap(\.packLayers) + [MapStyleSpec.streetLayer, MapStyleSpec.terrainLayer]).compactMap { layer in
            guard let url = Bundle.main.url(forResource: "\(name)-\(layer)", withExtension: "pmtiles",
                                            subdirectory: "MapAssets") else { return nil }
            let id = PackID(cycle: name, layer: layer, region: name)
            return PackFile(pack: InstalledPack(id: id, effective: .distantPast, expires: .distantFuture), url: url)
        }
    }
}
