import FlightCore
import Foundation
import os
import Testing
@testable import Blueside

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Installs bytes as a pack, staged outside the store as a download would be.
private func install(_ id: PackID, _ text: String, in store: PackStore) throws {
    let file = try folder().appendingPathComponent("download.tmp")
    try Data(text.utf8).write(to: file)
    try store.install(PendingPack(id: id, url: URL(string: "http://127.0.0.1:9/x")!, sha256: Checksum.sha256(of: file),
                                  bytes: text.utf8.count, effective: t0 - day, expires: t0 + 55 * day, attempt: 1),
                      from: file)
}

// One cycle listing Texas at 2 bytes and the overview at 99, and a street pack for every cycle at 10.
private func listing(_ cycle: String, effective: Date) -> Data {
    let iso = ISO8601DateFormatter()
    func pack(_ layer: String, _ region: String, _ bytes: Int, _ hash: Character) -> [String: Any] {
        ["layer": layer, "region": region, "path": "charts/\(cycle)/\(layer)/\(region).pmtiles", "bytes": bytes,
         "sha256": String(repeating: hash, count: 64)]
    }
    let list: [String: Any] = ["version": 1, "base": [pack("street", "TX", 10, "c")],
                               "cycles": [["id": cycle, "effective": iso.string(from: effective),
                                           "expires": iso.string(from: effective + 56 * day),
                                           "packs": [pack("vfr", "TX", 2, "a"), pack("vfr", "overview", 99, "b")]]]]
    return try! JSONSerialization.data(withJSONObject: list)
}

@Suite struct PackRecordTests {
    private let tx = PackID(cycle: "c1", layer: "vfr", region: "TX")
    private let overview = PackID(cycle: "c1", layer: "vfr", region: "overview")
    private let old = PackID(cycle: "c0", layer: "vfr", region: "OK")

    @Test func anUnreadableRecordIsKeptAsideAndRebuiltFromThePackFiles() throws {
        let root = try folder()
        let store = PackStore(root: root)
        let street = PackID(cycle: "c0", layer: "street", region: "TX")
        for id in [tx, overview, old] { try install(id, id.region, in: store) }
        try install(street, "street map", in: store)
        store.setRegions(["TX", "OK"])
        let list = listing("c1", effective: t0 - day)
        try list.write(to: root.appendingPathComponent("manifest.json"))
        let damaged = Data("{\"packs\": [{".utf8)
        try damaged.write(to: root.appendingPathComponent("index.json"))

        let reopened = PackStore(root: root)
        let packs = Dictionary(uniqueKeysWithValues: reopened.installedFiles().map { ($0.pack.id, $0.pack) })
        #expect(Set(packs.keys) == [tx, overview, old, street])
        // The cached list dates its own cycle; a cycle it no longer names reads as expired.
        #expect(packs[tx]?.effective == t0 - day)
        #expect(packs[tx]?.expires == t0 + 55 * day)
        #expect(packs[old].map { ChartLibrary.state(layer: "vfr", region: "OK", installed: [$0], transfers: [:], now: t0) }
            == .expired)
        // A file of the listed size keeps the listed hash, a street pack's from any cycle; others have none.
        #expect(packs[tx]?.sha256 == String(repeating: "a", count: 64))
        #expect(packs[street]?.sha256 == String(repeating: "c", count: 64))
        #expect(packs[overview]?.sha256 == nil)
        #expect(packs[old]?.sha256 == nil)
        // So only the file of another size is fetched again.
        let fetch = ChartLibrary.packsToFetch(regions: reopened.regions, manifest: try Manifest.decode(list),
                                              installed: Array(packs.values), now: t0)
        #expect(fetch.map(\.id) == [overview])
        #expect(reopened.regions == ["TX", "OK"])
        // Nothing was deleted, the damaged record was kept, and the rebuilt one reads back.
        for id in packs.keys { #expect(FileManager.default.fileExists(atPath: store.fileURL(for: id).path)) }
        #expect(try Data(contentsOf: root.appendingPathComponent("index-unreadable.json")) == damaged)
        #expect(PackStore(root: root).installedFiles().map(\.pack) == reopened.installedFiles().map(\.pack))
    }

    @Test func aMissingRecordIsRebuiltFromThePackFiles() throws {
        let root = try folder()
        try install(tx, "TX", in: PackStore(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("index.json"))
        #expect(PackStore(root: root).installedFiles().map(\.pack.id) == [tx])
    }

    @Test func replacingAPackSwapsTheNewFileIn() throws {
        let store = PackStore(root: try folder())
        try install(tx, "first", in: store)
        try install(tx, "second", in: store)
        #expect(try String(contentsOf: store.fileURL(for: tx), encoding: .utf8) == "second")
        let listed = store.installedFiles().map(\.pack)
        #expect(listed.map(\.id) == [tx])
        #expect(listed.first?.sha256 == Checksum.sha256("second"))
    }

    // A record that cannot be written fails the install. A new file goes; a replaced one stays listed.
    @Test func aRecordThatCannotBeWrittenFailsTheInstall() throws {
        let root = try folder()
        let store = PackStore(root: root)
        try install(tx, "first", in: store)
        let ok = PackID(cycle: "c1", layer: "vfr", region: "OK")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        #expect(throws: (any Error).self) { try install(ok, "OK", in: store) }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: ok).path))
        #expect(throws: (any Error).self) { try install(tx, "second", in: store) }
        #expect(try String(contentsOf: store.fileURL(for: tx), encoding: .utf8) == "second")
        #expect(store.installedFiles().map(\.pack.id) == [tx])
    }

    // Progress is passed on once per whole percent.
    @Test func progressIsToldOncePerPercent() async throws {
        let events = OSAllocatedUnfairLock(initialState: [PackDownloader.Event]())
        let downloader = PackDownloader(store: PackStore(root: try folder()), configuration: .ephemeral) { event in
            events.withLock { $0.append(event) }
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: URL(string: "http://127.0.0.1:9/x")!)
        let pending = PendingPack(id: tx, url: URL(string: "http://127.0.0.1:9/x")!, sha256: "", bytes: 10_000,
                                  effective: t0, expires: t0 + day, attempt: 1)
        task.taskDescription = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        for (sent, written) in [(10, 10), (90, 100), (5, 105), (9_895, 10_000)] as [(Int64, Int64)] {
            downloader.urlSession(session, downloadTask: task, didWriteData: sent, totalBytesWritten: written,
                                  totalBytesExpectedToWrite: 10_000)
        }
        #expect(events.withLock { $0 } == [.progress(tx, 0.01), .progress(tx, 1)])
        session.invalidateAndCancel()
    }
}
