import FlightCore
import Foundation
import os
import Testing
@testable import Blueside

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let assets = Bundle.main.resourceURL!.appendingPathComponent("MapAssets")
private let bundledDatabase = assets.appendingPathComponent("nav-test.sqlite")
private let bundledTiles = assets.appendingPathComponent("nav-tiles.pmtiles")
private let plain = LaunchOptions(arguments: [])

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func id(_ cycle: String, _ layer: String) -> PackID {
    PackID(cycle: cycle, layer: layer, region: NavFiles.region)
}

// Installs a copy of a file as one navigation pack of a cycle that lasts 28 days.
private func install(_ source: URL, _ layer: String, cycle: String, effective: Date, in store: PackStore,
                     sha256: String? = nil) throws {
    let copy = store.root.appendingPathComponent(UUID().uuidString + ".tmp")
    try FileManager.default.copyItem(at: source, to: copy)
    let pending = PendingPack(id: id(cycle, layer), url: URL(string: "http://127.0.0.1:9/nav/\(cycle)/\(layer)")!,
                              sha256: try sha256 ?? Checksum.sha256(of: copy), bytes: 1,
                              effective: effective, expires: effective + 28 * day, attempt: 1)
    try store.install(pending, from: copy)
}

private func listBody() -> Data {
    let iso = ISO8601DateFormatter()
    let packs: [[String: Any]] = [
        ["layer": "nav-db", "region": "US", "path": "nav/2026-10-01/nav.sqlite", "bytes": 2000,
         "sha256": String(repeating: "a", count: 64)],
        ["layer": "nav-tiles", "region": "US", "path": "nav/2026-10-01/nav.pmtiles", "bytes": 1000,
         "sha256": String(repeating: "b", count: 64)],
    ]
    let cycle: [String: Any] = ["id": "2026-10-01", "effective": iso.string(from: t0 - day),
                                "expires": iso.string(from: t0 + 27 * day), "packs": packs]
    return try! JSONSerialization.data(withJSONObject: ["version": 1, "cycles": [cycle]])
}

@Suite @MainActor struct NavInstallTests {
    @Test func theListIsAskedForUnderItsOwnPathAndPacksResolveFromTheBase() async {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString),
                                    list: "nav/manifest.json",
                                    load: { url in
                                        asked.withLock { $0.append(url.absoluteString) }
                                        throw URLError(.notConnectedToInternet)
                                    })
        _ = await client.fetch()
        #expect(asked.withLock { $0 } == ["http://127.0.0.1:9/nav/manifest.json"])
        #expect(client.url(for: "nav/2026-10-01/nav.sqlite").absoluteString
                == "http://127.0.0.1:9/nav/2026-10-01/nav.sqlite")
    }

    @Test func aStoredDatabaseOpensFromThePackStore() throws {
        let store = PackStore(root: try tempFolder())
        try install(bundledDatabase, "nav-db", cycle: "2026-10-01", effective: t0 - day, in: store)
        try install(bundledTiles, "nav-tiles", cycle: "2026-10-01", effective: t0 - day, in: store)
        let files = try #require(NavFiles.pick(options: plain, installed: store.installedFiles(), now: t0))
        #expect(files.database == store.fileURL(for: id("2026-10-01", "nav-db")))
        #expect(files.tiles == store.fileURL(for: id("2026-10-01", "nav-tiles")))
        #expect(try NavDatabase(path: files.database.path).metadata.cycle == "2026-10-01")
    }

    @Test func aDatabaseThatFailsItsChecksumIsNeverInstalledOrPicked() throws {
        let store = PackStore(root: try tempFolder())
        #expect(throws: PackStore.StoreError.checksumMismatch) {
            try install(bundledDatabase, "nav-db", cycle: "2026-10-01", effective: t0 - day, in: store,
                        sha256: String(repeating: "0", count: 64))
        }
        try install(bundledTiles, "nav-tiles", cycle: "2026-10-01", effective: t0 - day, in: store)
        #expect(store.installedFiles().map(\.pack.id.layer) == ["nav-tiles"])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: id("2026-10-01", "nav-db")).path))
        // Tiles with no database of their cycle are not used: their dates live in the database.
        #expect(NavFiles.pick(options: plain, installed: store.installedFiles(), now: t0) == nil)
    }

    @Test func tilesOfAnotherCycleAreNotPairedWithTheDatabase() throws {
        let store = PackStore(root: try tempFolder())
        try install(bundledDatabase, "nav-db", cycle: "2026-10-01", effective: t0 - day, in: store)
        try install(bundledTiles, "nav-tiles", cycle: "2026-09-03", effective: t0 - 29 * day, in: store)
        let files = try #require(NavFiles.pick(options: plain, installed: store.installedFiles(), now: t0))
        #expect(files.tiles == nil)
    }

    @Test func theCycleInEffectIsUsedAndTheOldOneIsDeletedAtTheChangeover() throws {
        let store = PackStore(root: try tempFolder())
        for (cycle, effective) in [("2026-10-01", t0 - day), ("2026-10-29", t0 + 27 * day)] {
            try install(bundledDatabase, "nav-db", cycle: cycle, effective: effective, in: store)
            try install(bundledTiles, "nav-tiles", cycle: cycle, effective: effective, in: store)
        }
        let before = NavFiles.pick(options: plain, installed: store.installedFiles(), now: t0)
        #expect(before?.database == store.fileURL(for: id("2026-10-01", "nav-db")))
        let switched = t0 + 27 * day + 1
        let after = NavFiles.pick(options: plain, installed: store.installedFiles(), now: switched)
        #expect(after?.database == store.fileURL(for: id("2026-10-29", "nav-db")))
        #expect(after?.tiles == store.fileURL(for: id("2026-10-29", "nav-tiles")))
        let left = CycleSwitcher.deleteSuperseded(store: store, now: switched)
        #expect(Set(left.map(\.pack.id.cycle)) == ["2026-10-29"])
    }

    @Test func aTestLaunchGetsTheBundledFilesAndNoOtherLaunchDoes() {
        let test = NavFiles.pick(options: LaunchOptions(arguments: ["-basePack", "nav"]), installed: [], now: t0)
        #expect(test?.database.lastPathComponent == "nav-test.sqlite")
        #expect(test?.tiles?.lastPathComponent == "nav-tiles.pmtiles")
        let others = [[], ["-basePack", "test"], ["-offline", "1"], ["-navQuery", "AUS"], ["-show", "nav"],
                      ["-navNow", "2026-10-13T12:00:00Z"]]
        for arguments in others {
            #expect(NavFiles.pick(options: LaunchOptions(arguments: arguments), installed: [], now: t0) == nil,
                    "\(arguments)")
        }
    }

    @Test func navigationDataIsWantedWithoutBeingChosenAndHasOneRow() async throws {
        let root = try tempFolder()
        let body = listBody()
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: root.appendingPathComponent("manifest.json"),
                                    list: "nav/manifest.json", load: { _ in body })
        let model = DownloadsModel(store: PackStore(root: root, freeBytes: { 10_000_000_000 }), client: client,
                                   configuration: .ephemeral, now: { t0 }, always: [NavFiles.region])
        #expect(model.rows.map(\.id) == ["US"])
        #expect(model.state(of: "US") == .notDownloaded)
        await model.refresh()
        #expect(model.rows.map(\.bytes) == [3000])
        #expect(Set(model.transfers.keys.map(\.layer)) == ["nav-db", "nav-tiles"])
    }

    // Expired long ago unless the caller gives a later date.
    private func pending(_ file: URL, cycle: String,
                         expires: Date = Date(timeIntervalSince1970: 1)) throws -> PendingPack {
        PendingPack(id: PackID(cycle: cycle, layer: NavFiles.databaseLayer, region: NavFiles.region), url: file,
                    sha256: try Checksum.sha256(of: file), bytes: 0,
                    effective: Date(timeIntervalSince1970: 0), expires: expires, attempt: 1)
    }

    @Test func aRefusedDatabaseIsNeverInstalledAndTheOlderCycleStays() throws {
        let folder = try tempFolder()
        let store = PackStore(root: folder.appendingPathComponent("store"), accepts: NavFiles.readable)
        let now = Date()
        // The older cycle expired yesterday.
        try install(bundledDatabase, "nav-db", cycle: "2026-09-03", effective: now - 29 * day, in: store)
        try install(bundledTiles, "nav-tiles", cycle: "2026-09-03", effective: now - 29 * day, in: store)
        let junk = folder.appendingPathComponent("junk")
        try Data("not a database".utf8).write(to: junk)
        // In effect now, so it would replace the older cycle if it were installed.
        #expect(throws: PackStore.StoreError.rejected) {
            try store.install(try pending(junk, cycle: "2026-10-01", expires: .distantFuture), from: junk)
        }
        #expect(!FileManager.default.fileExists(atPath: junk.path))
        // The tiles of the refused cycle are sound, so they arrive all the same.
        try install(bundledTiles, "nav-tiles", cycle: "2026-10-01", effective: now - day, in: store)
        let left = CycleSwitcher.deleteSuperseded(store: store, now: now)
        #expect(left.filter { $0.pack.id.layer == "nav-db" }.map(\.pack.id.cycle) == ["2026-09-03"])
        // The older database still has its own tiles, so the map keeps its airports and airspace.
        let files = try #require(NavFiles.pick(options: plain, installed: left, now: now))
        #expect(files.database == store.fileURL(for: id("2026-09-03", "nav-db")))
        #expect(files.tiles == store.fileURL(for: id("2026-09-03", "nav-tiles")))
    }

    @Test func tilesAreDeletedOnlyOnceADatabaseOfALaterCycleIsInUse() throws {
        let store = PackStore(root: try tempFolder())
        // Tiles whose database never arrived, then a whole cycle that expired yesterday.
        try install(bundledTiles, "nav-tiles", cycle: "2026-08-06", effective: t0 - 57 * day, in: store)
        try install(bundledDatabase, "nav-db", cycle: "2026-09-03", effective: t0 - 29 * day, in: store)
        try install(bundledTiles, "nav-tiles", cycle: "2026-09-03", effective: t0 - 29 * day, in: store)
        // The new tiles land first. The database in use is still the old one, so its tiles stay.
        try install(bundledTiles, "nav-tiles", cycle: "2026-10-01", effective: t0 - day, in: store)
        var left = CycleSwitcher.deleteSuperseded(store: store, now: t0)
        #expect(left.count == 4)
        #expect(NavFiles.pick(options: plain, installed: left, now: t0)?.tiles
                == store.fileURL(for: id("2026-09-03", "nav-tiles")))
        // The new database lands. Everything older goes, tiles with no database included.
        try install(bundledDatabase, "nav-db", cycle: "2026-10-01", effective: t0 - day, in: store)
        left = CycleSwitcher.deleteSuperseded(store: store, now: t0)
        #expect(left.map(\.pack.id.cycle) == ["2026-10-01", "2026-10-01"])
        #expect(NavFiles.pick(options: plain, installed: left, now: t0)?.tiles
                == store.fileURL(for: id("2026-10-01", "nav-tiles")))
    }

    @Test func aDamagedInstalledDatabaseIsRemovedAtLaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plain = PackStore(root: folder.appendingPathComponent("store"))
        let junk = folder.appendingPathComponent("junk")
        try Data("not a database".utf8).write(to: junk)
        try plain.install(try pending(junk, cycle: "2026-10-01"), from: junk)
        let checked = PackStore(root: plain.root, accepts: NavFiles.readable)
        #expect(checked.installedFiles().count == 1)
        checked.removeRefused()
        #expect(checked.installedFiles().isEmpty)
    }

    @Test func theAirspaceDateIsReadOnlyWhenTheFileCarriesIt() throws {
        let test = try NavDatabase(path: try #require(NavFiles.bundledTest).database.path)
        #expect(test.metadata.suaSnapshot == nil)
        if let national = ProcessInfo.processInfo.environment["NAV_NATIONAL_DB"] {
            #expect(try NavDatabase(path: national).metadata.suaSnapshot
                == ISO8601DateFormatter().date(from: "2026-09-28T13:54:26Z"))
        }
    }
}
