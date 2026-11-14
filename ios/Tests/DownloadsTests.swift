import CryptoKit
import FlightCore
import Foundation
import Observation
import os
import Testing
@testable import Blueside

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &* 31 &+ seed })
}

private func staged(_ data: Data, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(UUID().uuidString + ".tmp")
    try data.write(to: url)
    return url
}

private func pending(_ layer: String = "vfr", _ region: String = "TX", cycle: String = "c1", data: Data,
                     effective: Date = t0 - day, expires: Date = t0 + 55 * day,
                     sha256: String? = nil) -> PendingPack {
    PendingPack(id: PackID(cycle: cycle, layer: layer, region: region),
                url: URL(string: "http://127.0.0.1:9/\(cycle)/\(layer)/\(region).pmtiles")!,
                sha256: sha256 ?? sha(data), bytes: data.count, effective: effective, expires: expires, attempt: 1)
}

private func install(_ pack: PendingPack, data: Data, in store: PackStore) throws {
    try store.install(pack, from: staged(data, in: store.root))
}

private func manifestData(_ cycles: [(id: String, effective: Date, packs: [(layer: String, region: String, data: Data)])]) -> Data {
    let iso = ISO8601DateFormatter()
    let list = cycles.map { cycle -> [String: Any] in
        ["id": cycle.id, "effective": iso.string(from: cycle.effective),
         "expires": iso.string(from: cycle.effective + 56 * day),
         "packs": cycle.packs.map { pack -> [String: Any] in
             ["layer": pack.layer, "region": pack.region,
              "path": "charts/\(cycle.id)/\(pack.layer)/\(pack.region).pmtiles",
              "bytes": pack.data.count, "sha256": sha(pack.data)]
         }]
    }
    return try! JSONSerialization.data(withJSONObject: ["version": 1, "cycles": list])
}

private struct Offline: Error {}

/// Takes every request and never answers, like a server that has gone quiet.
private final class SilentServer: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private var silentSession: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SilentServer.self]
    return configuration
}

private func filesUnder(_ folder: URL) -> [String] {
    (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { !$0.hasDirectoryPath }.map(\.lastPathComponent).sorted()
}

@Suite struct ChecksumTests {
    @Test func hashesAFileReadInPieces() throws {
        let folder = try tempFolder()
        let large = bytes(3_000_000)
        #expect(try Checksum.sha256(of: staged(large, in: folder)) == sha(large))
        #expect(try Checksum.sha256(of: staged(Data("abc".utf8), in: folder))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct PackStoreTests {
    @Test func installMovesTheVerifiedFileIntoPlaceAndRecordsIt() throws {
        let store = PackStore(root: try tempFolder())
        let data = bytes(5000)
        let pack = pending(data: data)
        let file = try staged(data, in: store.root)
        try store.install(pack, from: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let installed = store.installedFiles()
        #expect(installed.map(\.pack) == [InstalledPack(id: pack.id, effective: pack.effective, expires: pack.expires,
                                                         sha256: pack.sha256)])
        #expect(installed.first?.url == store.fileURL(for: pack.id))
        #expect(try Data(contentsOf: store.fileURL(for: pack.id)) == data)
    }

    @Test func checksumMismatchDeletesTheFileAndInstallsNothing() throws {
        let store = PackStore(root: try tempFolder())
        let data = bytes(5000)
        let file = try staged(data, in: store.root)
        #expect(throws: PackStore.StoreError.checksumMismatch) {
            try store.install(pending(data: data, sha256: String(repeating: "0", count: 64)), from: file)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.installedFiles().isEmpty)
        #expect(filesUnder(store.root).filter { $0.hasSuffix(".pmtiles") }.isEmpty)
    }

    @Test func installedFileIsExcludedFromBackup() throws {
        let store = PackStore(root: try tempFolder())
        let data = bytes(100)
        try install(pending(data: data), data: data, in: store)
        var url = store.fileURL(for: pending(data: data).id)
        url.removeAllCachedResourceValues()
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func indexSurvivesANewStoreObject() throws {
        let root = try tempFolder()
        let data = bytes(100)
        try install(pending(data: data), data: data, in: PackStore(root: root))
        PackStore(root: root).setRegions(["TX", "OK"])
        let reopened = PackStore(root: root)
        #expect(reopened.installedFiles().map(\.pack.id) == [pending(data: data).id])
        #expect(reopened.regions == ["TX", "OK"])
    }

    @Test func entryWithAMissingFileIsDropped() throws {
        let store = PackStore(root: try tempFolder())
        let data = bytes(100)
        try install(pending(data: data), data: data, in: store)
        try FileManager.default.removeItem(at: store.fileURL(for: pending(data: data).id))
        #expect(store.installedFiles().isEmpty)
    }

    @Test func notEnoughSpaceIsRefusedBeforeAnythingIsWritten() throws {
        let store = PackStore(root: try tempFolder(), freeBytes: { DownloadPolicy.spaceMargin + 400 })
        try store.checkSpace(for: 400)
        #expect(throws: PackStore.StoreError.notEnoughSpace(needed: 401, free: 400)) {
            try store.checkSpace(for: 401)
        }
    }

    // No injected reading here: a real one of nil or zero would refuse every download.
    @Test func realFreeSpaceReadingAllowsASmallPack() throws {
        try PackStore(root: try tempFolder()).checkSpace(for: 1_000_000)
    }

    @Test func removeDeletesTheFileAndTheEntry() throws {
        let store = PackStore(root: try tempFolder())
        let data = bytes(100)
        try install(pending(data: data), data: data, in: store)
        store.remove(try #require(store.installedFiles().first).pack)
        #expect(store.installedFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: pending(data: data).id).path))
    }

    @Test func packPathsHaveNoSpaces() {
        let id = PackID(cycle: "2026-09-03", layer: "vfr-tac", region: "TX")
        #expect(!PackStore(root: PackStore.standardRoot).fileURL(for: id).path.contains(" "))
    }
}

@Suite struct ManifestClientTests {
    private let body = manifestData([("c1", t0 - day, [("vfr", "TX", bytes(10))])])

    @Test func freshManifestIsReturnedAndCached() async throws {
        let cache = try tempFolder().appendingPathComponent("manifest.json")
        let body = self.body
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!, cache: cache, load: { url in
            #expect(url.absoluteString == "http://127.0.0.1:9/manifest.json")
            return body
        })
        let result = await client.fetch()
        #expect(result.failure == nil)
        #expect(result.manifest?.cycles.first?.id == "c1")
        #expect(client.cached() == result.manifest)
    }

    @Test func fetchFailureReturnsTheCachedManifest() async throws {
        let cache = try tempFolder().appendingPathComponent("manifest.json")
        try body.write(to: cache)
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!, cache: cache, load: { _ in throw Offline() })
        let result = await client.fetch()
        #expect(result.failure == .noConnection)
        #expect(result.manifest?.cycles.first?.id == "c1")
    }

    @Test func badManifestDoesNotReplaceTheCachedOne() async throws {
        let cache = try tempFolder().appendingPathComponent("manifest.json")
        try body.write(to: cache)
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!, cache: cache,
                                    load: { _ in Data(#"{"version":1,"cycles":[{"id":"../x"}]}"#.utf8) })
        let result = await client.fetch()
        #expect(result.failure == .server)
        #expect(result.manifest?.cycles.first?.id == "c1")
        #expect(try Data(contentsOf: cache) == body)
    }

    @Test func noCacheAndNoNetworkGivesNothing() async throws {
        let cache = try tempFolder().appendingPathComponent("manifest.json")
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!, cache: cache, load: { _ in throw Offline() })
        let result = await client.fetch()
        #expect(result.manifest == nil)
        #expect(result.failure == .noConnection)
    }

    @Test func fetchFailuresAreToldApart() async throws {
        func failure(_ load: @escaping @Sendable (URL) async throws -> Data) async throws -> ListFailure? {
            let cache = try tempFolder().appendingPathComponent("manifest.json")
            return await ManifestClient(base: URL(string: "http://127.0.0.1:9")!, cache: cache, load: load)
                .fetch().failure
        }
        let body = self.body
        #expect(try await failure { _ in body } == nil)
        #expect(try await failure { _ in throw URLError(.notConnectedToInternet) } == .noConnection)
        #expect(try await failure { _ in throw ManifestClient.BadStatus(code: 503) } == .server)
        #expect(try await failure { _ in Data("<html>".utf8) } == .server)
        #expect(try await failure { _ in Data(#"{"version":2,"cycles":[]}"#.utf8) } == .unreadable)
    }

    @Test func launchOptionOverridesTheBuiltInAddress() {
        let info: [String: Any] = ["ManifestBaseURL": "https://charts.example"]
        let override = LaunchOptions(arguments: ["-manifestBase", "http://127.0.0.1:8765"])
        #expect(ManifestClient.baseURL(options: override, info: info)?.absoluteString == "http://127.0.0.1:8765")
        #expect(ManifestClient.baseURL(options: LaunchOptions(arguments: []), info: info)?.absoluteString
            == "https://charts.example")
        #expect(ManifestClient.baseURL(options: LaunchOptions(arguments: []), info: [:]) == nil)
        #expect(ManifestClient.baseURL(options: LaunchOptions(arguments: []), info: ["ManifestBaseURL": ""]) == nil)
    }
}

@Suite struct CycleSwitcherTests {
    private func twoCycles(in store: PackStore) throws -> (old: PendingPack, new: PendingPack) {
        let old = pending(cycle: "c1", data: bytes(100, seed: 1), effective: t0 - 56 * day, expires: t0)
        let new = pending(cycle: "c2", data: bytes(100, seed: 2), effective: t0, expires: t0 + 56 * day)
        try install(old, data: bytes(100, seed: 1), in: store)
        try install(new, data: bytes(100, seed: 2), in: store)
        return (old, new)
    }

    @Test func nextCyclePackIsHeldUnusedUntilItsEffectiveTime() throws {
        let store = PackStore(root: try tempFolder())
        let packs = try twoCycles(in: store)
        let left = CycleSwitcher.deleteSuperseded(store: store, now: t0 - 1)
        #expect(Set(left.map(\.pack.id)) == [packs.old.id, packs.new.id])
        #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: left.map(\.pack), now: t0 - 1)?.id
            == packs.old.id)
        #expect(DownloadPolicy.nextChangeover(installed: left.map(\.pack), now: t0 - 1) == t0)
    }

    @Test func supersededPackIsDeletedAtTheEffectiveTime() throws {
        let store = PackStore(root: try tempFolder())
        let packs = try twoCycles(in: store)
        let left = CycleSwitcher.deleteSuperseded(store: store, now: t0 + 1)
        #expect(left.map(\.pack.id) == [packs.new.id])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: packs.old.id).path))
        #expect(store.installedFiles().map(\.pack.id) == [packs.new.id])
        // The pack left on disk expires next, and that moment changes its state too.
        #expect(DownloadPolicy.nextChangeover(installed: left.map(\.pack), now: t0 + 1) == t0 + 56 * day)
    }

    @Test func nextChangeIsTheEarliestEffectiveOrExpiryInstant() {
        let pack = InstalledPack(id: PackID(cycle: "c1", layer: "vfr", region: "TX"),
                                 effective: t0 - day, expires: t0 + day)
        let next = InstalledPack(id: PackID(cycle: "c2", layer: "vfr", region: "OK"),
                                 effective: t0 + 2 * day, expires: t0 + 58 * day)
        #expect(DownloadPolicy.nextChangeover(installed: [pack, next], now: t0) == t0 + day)
        #expect(DownloadPolicy.nextChangeover(installed: [pack, next], now: t0 + day) == t0 + 2 * day)
        #expect(DownloadPolicy.nextChangeover(installed: [pack], now: t0 + day) == nil)
    }

    @Test func expiredPackIsKeptAndFlaggedWhenNoNewCycleIsOnDisk() throws {
        let store = PackStore(root: try tempFolder())
        let old = pending(data: bytes(100), effective: t0 - 56 * day, expires: t0)
        try install(old, data: bytes(100), in: store)
        let left = CycleSwitcher.deleteSuperseded(store: store, now: t0 + day)
        #expect(left.map(\.pack.id) == [old.id])
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: old.id).path))
        let installed = left.map(\.pack)
        #expect(MapPlan.currency(layer: "vfr", region: "TX", installed: installed, now: t0 + day) == .expired(t0))
        #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: installed, transfers: [:], now: t0 + day)
            == .expired)
    }

    @Test func packNotYetInEffectIsFlaggedNotExpired() {
        let future = InstalledPack(id: PackID(cycle: "c2", layer: "vfr", region: "TX"),
                                   effective: t0 + 7 * day, expires: t0 + 63 * day)
        #expect(MapPlan.currency(layer: "vfr", region: "TX", installed: [future], now: t0)
            == .notYetEffective(t0 + 7 * day))
    }

    @Test func currencyOverLayersReportsTheWorstCase() {
        let good = InstalledPack(id: PackID(cycle: "c1", layer: "vfr", region: "TX"), effective: t0 - day, expires: t0 + day)
        let old = InstalledPack(id: PackID(cycle: "c0", layer: "vfr-tac", region: "TX"),
                                effective: t0 - 60 * day, expires: t0 - 4 * day)
        #expect(MapPlan.currency(layers: ["vfr", "vfr-tac"], installed: [good], now: t0) == .current)
        #expect(MapPlan.currency(layers: ["vfr", "vfr-tac"], installed: [good, old], now: t0)
            == .expired(t0 - 4 * day))
        #expect(MapPlan.currency(layers: ["ifr-low"], installed: [good], now: t0) == nil)
    }
}

@Suite @MainActor struct DownloadsModelTests {
    private func makeModel(free: Int64, body: Data?, root: URL) -> DownloadsModel {
        let store = PackStore(root: root, freeBytes: { free })
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: root.appendingPathComponent("manifest.json"),
                                    load: { _ in if let body { return body } else { throw Offline() } })
        return DownloadsModel(store: store, client: client, configuration: .ephemeral, now: { t0 })
    }

    private let body = manifestData([("c1", t0 - day, [
        ("vfr", "TX", bytes(5000, seed: 1)), ("vfr-tac", "TX", bytes(2500, seed: 2)),
        ("vfr", "OK", bytes(4000, seed: 3)), ("vfr", "overview", bytes(1000, seed: 4)),
    ])])

    // An open list must change at the moment a pack expires, with no tap and no new list.
    @Test func packStatesAreReadAgainAtTheMomentAPackExpires() async throws {
        let store = PackStore(root: try tempFolder(), freeBytes: { 10_000_000_000 })
        let soon = Date().addingTimeInterval(1.5)
        try install(pending(data: bytes(100), effective: soon - 56 * day, expires: soon), data: bytes(100), in: store)
        let model = DownloadsModel(store: store, client: nil, configuration: .ephemeral)
        await model.refresh()
        #expect(model.state(of: "TX") == .ready)
        let told = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = model.rows } onChange: { told.withLock { $0 = true } }
        try await Task.sleep(for: .seconds(4))
        #expect(told.withLock { $0 }, "nothing told the open list to read the states again")
        #expect(model.state(of: "TX") == .expired)
    }

    @Test func rowsListEachRegionWithItsTotalSize() async throws {
        let model = makeModel(free: 0, body: body, root: try tempFolder())
        await model.refresh()
        #expect(model.rows.map(\.id) == ["OK", "TX"])
        #expect(model.rows.map(\.bytes) == [4000, 7500])
        #expect(model.manifestIsFresh)
    }

    @Test func fullStorageStopsTheDownloadWithAMessageBeforeAnythingIsWritten() async throws {
        let root = try tempFolder()
        let model = makeModel(free: 1000, body: body, root: root)
        await model.refresh()
        await model.choose("TX")
        #expect(model.message?.contains("Not enough storage") == true)
        guard case .failed(let reason) = model.state(of: "TX") else {
            Issue.record("TX should be failed, got \(model.state(of: "TX"))")
            return
        }
        #expect(reason.contains("Not enough storage"))
        #expect(await model.activeCount() == 0)
        #expect(filesUnder(root) == ["index.json", "manifest.json"])
    }

    @Test func overviewIsFetchedWithoutBeingChosen() async throws {
        let model = makeModel(free: 10_000_000_000, body: body, root: try tempFolder())
        await model.refresh()
        let overview = PackID(cycle: "c1", layer: "vfr", region: "overview")
        #expect(model.transfers[overview] != nil)
        #expect(model.transfers.keys.allSatisfy { $0.region == "overview" })
    }

    private final class Space: @unchecked Sendable { var free: Int64 = 1000 }

    @Test func failedOverviewIsTriedAgainOnTheNextRefresh() async throws {
        let root = try tempFolder()
        let space = Space()
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: root.appendingPathComponent("manifest.json"),
                                    load: { [body] _ in body })
        let model = DownloadsModel(store: PackStore(root: root, freeBytes: { space.free }), client: client,
                                   configuration: .ephemeral, now: { t0 })
        let overview = PackID(cycle: "c1", layer: "vfr", region: "overview")
        await model.refresh()
        #expect("\(String(describing: model.transfers[overview]))".contains("Not enough storage"))
        space.free = 10_000_000_000
        await model.refresh()
        #expect(model.transfers[overview] != nil)
        #expect(!"\(String(describing: model.transfers[overview]))".contains("Not enough storage"),
                "the failed overview was not tried again")
    }

    private let twoCycles = manifestData([
        ("c1", t0 - day, [("vfr", "TX", bytes(5000, seed: 1))]),
        ("c2", t0 + 55 * day, [("vfr", "TX", bytes(5000, seed: 5))]),
    ])
    private let nextTX = PackID(cycle: "c2", layer: "vfr", region: "TX")

    @Test func failureBehindAnInstalledPackIsTriedAgainOnTheNextRefresh() async throws {
        let root = try tempFolder()
        let space = Space()
        let store = PackStore(root: root, freeBytes: { space.free })
        try install(pending(data: bytes(5000, seed: 1)), data: bytes(5000, seed: 1), in: store)
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: root.appendingPathComponent("manifest.json"),
                                    load: { [twoCycles] _ in twoCycles })
        let model = DownloadsModel(store: store, client: client, configuration: .ephemeral, now: { t0 })
        await model.refresh()
        await model.choose("TX")
        #expect("\(String(describing: model.transfers[nextTX]))".contains("Not enough storage"))
        #expect(model.state(of: "TX") == .ready)
        space.free = 10_000_000_000
        await model.refresh()
        guard case .downloading = model.transfers[nextTX] else {
            Issue.record("the hidden failure was not tried again: \(String(describing: model.transfers[nextTX]))")
            return
        }
    }

    private final class Clock: @unchecked Sendable { var now = t0 }

    // A pack the server holds damaged, or one the app cannot open, must not be fetched in full on every refresh.
    @Test(arguments: [PackDownloader.checksumFailure, PackDownloader.unreadableFailure])
    func aBadFileWithNoRetryButtonRestsSixHoursBeforeTheNextTry(reason: String) async throws {
        let root = try tempFolder()
        let clock = Clock()
        let store = PackStore(root: root, freeBytes: { 10_000_000_000 })
        try install(pending(data: bytes(5000, seed: 1)), data: bytes(5000, seed: 1), in: store)
        let list = manifestData([
            ("c1", t0 - day, [("vfr", "TX", bytes(5000, seed: 1)), ("vfr", "overview", bytes(1000, seed: 4))]),
            ("c2", t0 + 55 * day, [("vfr", "TX", bytes(5000, seed: 5))]),
        ])
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: root.appendingPathComponent("manifest.json"), load: { _ in list })
        let model = DownloadsModel(store: store, client: client, configuration: silentSession,
                                   now: { clock.now })
        await model.refresh()
        await model.choose("TX")
        // Lets the two start events arrive first, so neither is read as a new start after the failure.
        try await Task.sleep(for: .milliseconds(300))
        let failed = Transfer.failed(reason)
        let hidden = [nextTX, PackID(cycle: "c1", layer: "vfr", region: "overview")]
        for id in hidden { model.handle(.failed(id, reason)) }
        #expect(model.state(of: "TX") == .ready)
        for _ in 0..<2 {
            await model.refresh()
            for id in hidden { #expect(model.transfers[id] == failed, "\(id.region) was fetched again at once") }
        }
        clock.now = t0 + 6 * 3600
        await model.refresh()
        for id in hidden {
            guard case .downloading = model.transfers[id] else {
                Issue.record("\(id.region) was never tried again: \(String(describing: model.transfers[id]))")
                continue
            }
        }
    }

    @Test func removeStopsTheRegionsTransfers() async throws {
        let model = makeModel(free: 10_000_000_000, body: body, root: try tempFolder())
        await model.refresh()
        await model.choose("TX")
        #expect(model.transfers.keys.contains { $0.region == "TX" })
        await model.remove("TX")
        #expect(!model.transfers.keys.contains { $0.region == "TX" })
        #expect(model.state(of: "TX") == .notDownloaded)
        // Long enough for the refused connections to report in.
        try await Task.sleep(for: .milliseconds(500))
        #expect(!model.transfers.keys.contains { $0.region == "TX" })
        #expect(await model.activeCount() == 0)
    }

    // Stopping a transfer is not a failure, so it must never be reported as one.
    @Test func stoppedTransferIsNotReportedAsAFailure() async throws {
        let events = OSAllocatedUnfairLock(initialState: [PackDownloader.Event]())
        let downloader = PackDownloader(store: PackStore(root: try tempFolder()), configuration: silentSession) {
            event in events.withLock { $0.append(event) }
        }
        let pack = pending(data: bytes(100))
        downloader.start(pack)
        await downloader.cancel(region: "TX")
        try await Task.sleep(for: .milliseconds(500))
        let seen = events.withLock { $0 }
        #expect(seen.count == 2, "the stop was not reported at all: \(seen)")
        #expect(!seen.contains { if case .failed = $0 { true } else { false } }, "a stop was reported as a failure")
    }

    // A transfer kept from an earlier launch is stopped only when its region is no longer wanted.
    @Test func onlyTransfersForRegionsNoLongerWantedAreStopped() {
        let active = ["TX", "OK", "overview"].map { PackID(cycle: "c1", layer: "vfr", region: $0) }
        #expect(DownloadPolicy.unwanted(active, chosen: ["TX"]) == ["OK"])
        #expect(DownloadPolicy.unwanted(active, chosen: []) == ["OK", "TX"])
        #expect(DownloadPolicy.unwanted(active, chosen: ["TX", "OK"]).isEmpty)
    }

    // Remove then Download again: the old transfer's stop arrives after the new request and must not fail it.
    @Test func downloadAskedForWhileAnOldTransferIsStoppingKeepsDownloading() async throws {
        let root = try tempFolder()
        let client = ManifestClient(base: URL(string: "http://127.0.0.1:9")!,
                                    cache: root.appendingPathComponent("manifest.json"),
                                    load: { [body] _ in body })
        let model = DownloadsModel(store: PackStore(root: root, freeBytes: { 10_000_000_000 }), client: client,
                                   configuration: silentSession, now: { t0 })
        await model.refresh()
        await model.choose("TX")
        await model.remove("TX")
        await model.choose("TX")
        try await Task.sleep(for: .milliseconds(500))
        guard case .downloading = model.state(of: "TX") else {
            Issue.record("the new download reads \(model.state(of: "TX"))")
            return
        }
        // Two packs for Texas and the overview, each with one live transfer.
        let active = await model.activeCount()
        #expect(active == 3)
    }

    @Test func packOfACycleNotYetStartedReadsNotYetInEffect() async throws {
        let root = try tempFolder()
        let data = bytes(5000, seed: 5)
        try install(pending(cycle: "c2", data: data, effective: t0 + 7 * day, expires: t0 + 63 * day),
                    data: data, in: PackStore(root: root))
        let model = makeModel(free: 0, body: manifestData([("c2", t0 + 7 * day, [("vfr", "TX", data)])]), root: root)
        await model.refresh()
        let row = try #require(model.rows.first)
        #expect(row.effective == t0 + 7 * day)
        #expect(DownloadPolicy.statusText(row.state, effective: row.effective) == "Not yet in effect until 22 Jan 2027 UTC")
        #expect(DownloadPolicy.statusText(.expired) == "Expired")
    }

    @Test func futurePackTheListOmitsReadsNotYetInEffectAndNeverExpired() async throws {
        let root = try tempFolder()
        let data = bytes(5000, seed: 5)
        try install(pending(cycle: "c2", data: data, effective: t0 + 7 * day, expires: t0 + 63 * day),
                    data: data, in: PackStore(root: root))
        let onlyOK = manifestData([("c1", t0 - day, [("vfr", "OK", bytes(4000, seed: 3))])])
        let model = makeModel(free: 0, body: onlyOK, root: root)
        await model.refresh()
        let row = try #require(model.rows.first { $0.id == "TX" })
        let text = DownloadPolicy.statusText(row.state, effective: row.effective)
        #expect(text == "Not yet in effect until 22 Jan 2027 UTC")
        #expect(!text.contains("Expired"))
    }

    @Test func listThisVersionCannotReadSaysUpdateTheAppAndKeepsTheLastKnownList() async throws {
        let root = try tempFolder()
        try body.write(to: root.appendingPathComponent("manifest.json"))
        let model = makeModel(free: 0, body: Data(#"{"version":2,"cycles":[]}"#.utf8), root: root)
        await model.refresh()
        #expect(model.listFailure == .unreadable)
        #expect(!model.manifestIsFresh)
        #expect(model.rows.map(\.id) == ["OK", "TX"])
    }

    @Test func noticeTellsNoConnectionAnUnreadableListAndAServerErrorApart() {
        #expect(DownloadPolicy.listNotice(nil, hasList: true) == nil)
        #expect(DownloadPolicy.listNotice(.noConnection, hasList: true) == "No connection. Showing the last known list.")
        #expect(DownloadPolicy.listNotice(.noConnection, hasList: false)
            == "No chart list yet. Connect to the internet once to fetch it.")
        #expect(DownloadPolicy.listNotice(.unreadable, hasList: true)
            == "Update the app. This version cannot read the chart list. Showing the last known list.")
        #expect(DownloadPolicy.listNotice(.unreadable, hasList: false)
            == "Update the app. This version cannot read the chart list.")
        #expect(DownloadPolicy.listNotice(.server, hasList: true) == "Chart server error. Showing the last known list.")
        #expect(DownloadPolicy.listNotice(.server, hasList: false) == "Chart server error. Try again later.")
    }

    @Test func packSizesAddWithoutOverflow() {
        #expect(DownloadPolicy.total([]) == 0)
        #expect(DownloadPolicy.total([5000, 2500]) == 7500)
        #expect(DownloadPolicy.total([.max, 1]) == .max)
    }

    // Two packs that each fit alone and together pass the largest number a size can hold.
    @Test func hugeSizesInTheListAreSummedAndRefusedWithoutACrash() async throws {
        let iso = ISO8601DateFormatter()
        let half = Int.max / 2 + 1
        func pack(_ layer: String) -> String {
            #"{"layer":"\#(layer)","region":"TX","path":"charts/c1/\#(layer)/TX.pmtiles","bytes":\#(half),"#
                + #""sha256":"\#(String(repeating: "a", count: 64))"}"#
        }
        let body = Data((#"{"version":1,"cycles":[{"id":"c1","effective":"\#(iso.string(from: t0 - day))","#
            + #""expires":"\#(iso.string(from: t0 + 55 * day))","packs":[\#(pack("vfr")),\#(pack("vfr-tac"))]}]}"#).utf8)
        let model = makeModel(free: .max, body: body, root: try tempFolder())
        await model.refresh()
        #expect(model.rows.map(\.bytes) == [.max])
        await model.choose("TX")
        guard case .failed(let reason) = model.state(of: "TX") else {
            Issue.record("TX should be failed, got \(model.state(of: "TX"))")
            return
        }
        #expect(reason.contains("Not enough storage"))
        await model.remove("TX")
    }

    @Test func failedCurrentPackShowsOverAStandInFromTheNextCycle() async throws {
        let root = try tempFolder()
        let data = bytes(5000, seed: 5)
        try install(pending(cycle: "c2", data: data, effective: t0 + 55 * day, expires: t0 + 111 * day),
                    data: data, in: PackStore(root: root))
        let model = makeModel(free: 1000, body: twoCycles, root: root)
        await model.refresh()
        await model.choose("TX")
        guard case .failed = model.state(of: "TX") else {
            Issue.record("the failure is hidden: \(model.state(of: "TX"))")
            return
        }
    }

    @Test func lastKnownListIsShownWhenTheFetchFails() async throws {
        let root = try tempFolder()
        try body.write(to: root.appendingPathComponent("manifest.json"))
        let model = makeModel(free: 0, body: nil, root: root)
        await model.refresh()
        #expect(!model.manifestIsFresh)
        #expect(model.rows.map(\.id) == ["OK", "TX"])
    }

    @Test func installedRegionTheListOmitsIsStillListedAndCanBeRemoved() async throws {
        let root = try tempFolder()
        let data = bytes(5000, seed: 1)
        try install(pending(data: data, effective: t0 - 60 * day, expires: t0 - 4 * day),
                    data: data, in: PackStore(root: root))
        let onlyOK = manifestData([("c2", t0 - day, [("vfr", "OK", bytes(4000, seed: 3))])])
        let model = makeModel(free: 0, body: onlyOK, root: root)
        await model.refresh()
        #expect(model.rows.map(\.id) == ["OK", "TX"])
        #expect(model.rows.last?.bytes == 5000)
        #expect(model.rows.last?.state == .expired)
        await model.remove("TX")
        #expect(model.rows.map(\.id) == ["OK"])
    }

    @Test func installedRegionsAreListedWithNoChartListAtAll() async throws {
        let root = try tempFolder()
        let data = bytes(5000, seed: 1)
        try install(pending(data: data), data: data, in: PackStore(root: root))
        let model = makeModel(free: 0, body: nil, root: root)
        await model.refresh()
        #expect(model.manifest == nil)
        #expect(model.rows.map(\.id) == ["TX"])
        #expect(model.rows.first?.state == .ready)
    }

    @Test func progressCountsBytesSoASmallFinishedFileDoesNotJumpTheBar() {
        // A 1 MB file done and a 99 MB file not started is 1 percent, not half.
        let state = DownloadPolicy.combined([.ready, .downloading(0)], sizes: [1_000_000, 99_000_000])
        #expect(state == .downloading(0.01))
        #expect(DownloadPolicy.combined([.downloading(0.5), .downloading(1)], sizes: [100, 300]) == .downloading(0.875))
        // With a size missing, each file counts the same.
        #expect(DownloadPolicy.combined([.ready, .downloading(0)], sizes: [0, 100]) == .downloading(0.5))
    }

    @Test func combinedStateReportsFailureFirstThenProgress() {
        #expect(DownloadPolicy.combined([]) == .notDownloaded)
        #expect(DownloadPolicy.combined([.ready, .ready]) == .ready)
        #expect(DownloadPolicy.combined([.ready, .failed("x"), .downloading(0.5)]) == .failed("x"))
        #expect(DownloadPolicy.combined([.ready, .downloading(0.5)]) == .downloading(0.75))
        #expect(DownloadPolicy.combined([.ready, .notDownloaded]) == .notDownloaded)
        #expect(DownloadPolicy.combined([.ready, .expired]) == .expired)
    }

    @Test func statusTextNamesEveryState() {
        #expect(DownloadPolicy.statusText(.notDownloaded) == "Not downloaded")
        #expect(DownloadPolicy.statusText(.downloading(0.426)) == "Downloading 43%")
        #expect(DownloadPolicy.statusText(.ready) == "Ready")
        #expect(DownloadPolicy.statusText(.expired) == "Expired")
        #expect(DownloadPolicy.statusText(.expired, effective: t0) == "Not yet in effect until 15 Jan 2027 UTC")
        #expect(DownloadPolicy.statusText(.failed("Checksum failed twice")) == "Failed: Checksum failed twice")
    }
}

@Suite struct StateNameTests {
    @Test func regionsShowTheirFullName() {
        #expect(DownloadPolicy.regionName("TX") == "Texas")
        #expect(DownloadPolicy.regionName("DC") == "District of Columbia")
        #expect(DownloadPolicy.regionName("overview") == "overview")
    }
}

@Suite struct StreetSplitTests {
    @Test func chartsSkipTheStreetLayerAndStreetKeepsOnlyIt() throws {
        let data = Data("x".utf8)
        let manifest = try Manifest.decode(manifestData([("c1", Date(), [
            ("vfr", "TX", data), ("street", "TX", data), ("street", "OK", data), ("vfr", "overview", data),
        ])]))
        let charts = DownloadPolicy.keeping(manifest, { $0 != MapStyleSpec.streetLayer })
        let street = DownloadPolicy.keeping(manifest, { $0 == MapStyleSpec.streetLayer })
        #expect(charts?.cycles[0].packs.map(\.layer) == ["vfr", "vfr"])
        #expect(street?.cycles[0].packs.map(\.region) == ["TX", "OK"])
        #expect(DownloadPolicy.keeping(nil, { _ in true }) == nil)
    }
}
