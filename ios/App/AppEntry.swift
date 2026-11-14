import FlightCore
import SwiftUI

@main struct AppEntry: App {
    @UIApplicationDelegateAdaptor(BackgroundEvents.self) private var backgroundEvents
    @State private var model = AppModel(options: .current)
    @State private var downloads: DownloadsModel
    @State private var navDownloads: DownloadsModel
    @State private var streetDownloads: DownloadsModel
    @State private var terrainDownloads: DownloadsModel
    @State private var plateDownloads: DownloadsModel

    // Made here rather than as state defaults, which wait for a scene: a relaunch in the background for a finished
    // transfer has none, and each model's session must exist then to take its events.
    init() {
        let options = LaunchOptions.current
        // Charts first: a seed for them fills the street and terrain stores too.
        _downloads = State(initialValue: Self.makeDownloads(options: options))
        _navDownloads = State(initialValue: Self.makeNavDownloads(options: options))
        _streetDownloads = State(initialValue: .baseMap(MapStyleSpec.streetLayer, root: PackStore.streetRoot, options: options))
        _terrainDownloads = State(initialValue: .baseMap(MapStyleSpec.terrainLayer, root: PackStore.terrainRoot, options: options))
        _plateDownloads = State(initialValue: .plates(options: options))
    }

    var body: some Scene {
        WindowGroup {
            // The map fills the screen at all times. Everything else is drawn over it.
            MapScreen(model: model, downloads: downloads, navDownloads: navDownloads, streetDownloads: streetDownloads,
                      terrainDownloads: terrainDownloads, plateDownloads: plateDownloads)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                ForEach(MapCommand.allCases, id: \.self) { command in
                    if let title = command.title, let shortcut = command.shortcut {
                        Button(title) { model.command = command }.keyboardShortcut(shortcut)
                    }
                }
            }
        }
    }

    // A test can ask for an empty navigation store before the download state reads it.
    private static func makeNavDownloads(options: LaunchOptions) -> DownloadsModel {
        if options.string("seedNav") == "empty" {
            let store = PackStore(root: PackStore.navRoot)
            for old in store.installedFiles() { store.remove(old.pack) }
            try? FileManager.default.removeItem(at: store.root.appendingPathComponent("manifest.json"))
        }
        return DownloadsModel.nav(options: options)
    }

    // A seed asked for at launch is applied before the download state reads the store.
    private static func makeDownloads(options: LaunchOptions) -> DownloadsModel {
        if let seed = options.string("seedPacks") {
            let files = AppModel.bundledPacks(named: "test")
            let own = [MapStyleSpec.streetLayer: PackStore.streetRoot, MapStyleSpec.terrainLayer: PackStore.terrainRoot]
            PackSeed.apply(seed, store: PackStore(root: PackStore.standardRoot),
                           files: files.filter { own[$0.pack.id.layer] == nil })
            for (layer, root) in own {
                PackSeed.apply(seed, store: PackStore(root: root), files: files.filter { $0.pack.id.layer == layer })
            }
        }
        return DownloadsModel.standard(options: options)
    }
}
