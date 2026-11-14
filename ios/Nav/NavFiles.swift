import FlightCore
import Foundation

/// The navigation database in use and the tile file of the same cycle, if it is on disk.
struct NavFiles: Equatable, Sendable {
    var database: URL
    var tiles: URL?

    static let databaseLayer = DownloadPolicy.navDatabaseLayer
    static let tilesLayer = DownloadPolicy.navTilesLayer
    static let region = DownloadPolicy.navRegion

    /// The small files shipped inside the app for tests.
    static var bundledTest: NavFiles? {
        guard let database = Bundle.main.url(forResource: "nav-test", withExtension: "sqlite",
                                             subdirectory: "MapAssets") else { return nil }
        return NavFiles(database: database,
                        tiles: Bundle.main.url(forResource: "nav-tiles", withExtension: "pmtiles",
                                               subdirectory: "MapAssets"))
    }

    /// The test files only when the launch asks for the nav test packs. Otherwise what is installed, or nothing.
    static func pick(options: LaunchOptions, installed: [PackFile], now: Date) -> NavFiles? {
        if options.string("basePack") == "nav" { return bundledTest }
        if options.flag("offline") { return nil }
        let packs = installed.map(\.pack)
        guard let shown = ChartLibrary.packToShow(layer: databaseLayer, region: region, installed: packs, now: now),
              let database = installed.first(where: { $0.pack == shown }) else { return nil }
        let wanted = PackID(cycle: shown.id.cycle, layer: tilesLayer, region: region)
        return NavFiles(database: database.url, tiles: installed.first { $0.pack.id == wanted }?.url)
    }

    /// True for anything but a database the reader refuses.
    static func readable(_ id: PackID, _ file: URL) -> Bool {
        id.layer != databaseLayer || (try? NavDatabase(path: file.path)) != nil
    }
}
