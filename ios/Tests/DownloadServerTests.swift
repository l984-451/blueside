import FlightCore
import Foundation
import Testing
@testable import Blueside

private let server = ProcessInfo.processInfo.environment["RANGE_SERVER"].flatMap { URL(string: $0) }
private let relaunchStep = ProcessInfo.processInfo.environment["RELAUNCH_STEP"]

/// Collects downloader events so a test can wait for one.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [PackDownloader.Event] = []

    func add(_ event: PackDownloader.Event) { lock.withLock { all.append(event) } }
    var list: [PackDownloader.Event] { lock.withLock { all } }

    func wait(seconds: Double, until done: @Sendable ([PackDownloader.Event]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done(list) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return done(list)
    }
}

private func freshStore() throws -> PackStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return PackStore(root: root)
}

private func pack(_ path: String, region: String, sha256: String? = nil) async throws -> PendingPack {
    let base = try #require(server)
    let name = path.split(separator: "/").last.map(String.init) ?? path
    let hash = try await ManifestClient.http(base.appendingPathComponent("sha256/" + name))
    return PendingPack(id: PackID(cycle: "c1", layer: "vfr", region: region), url: base.appendingPathComponent(path),
                       sha256: sha256 ?? String(decoding: hash, as: UTF8.self), bytes: 1,
                       effective: .distantPast, expires: .distantFuture, attempt: 1)
}

@Suite(.enabled(if: server != nil && relaunchStep == nil), .serialized) struct DownloadServerTests {
    @Test func aGoodFileIsVerifiedAndInstalled() async throws {
        let store = try freshStore()
        let events = Events()
        let downloader = PackDownloader(store: store, configuration: .ephemeral) { events.add($0) }
        let wanted = try await pack("small.bin", region: "GOOD")
        downloader.start(wanted)
        #expect(await events.wait(seconds: 30) { $0.contains(.installed(wanted.id)) })
        #expect(try Checksum.sha256(of: store.fileURL(for: wanted.id)) == wanted.sha256)
        #expect(store.installedFiles().map(\.pack.id) == [wanted.id])
    }

    @Test func aDamagedFileIsDeletedRetriedOnceThenMarkedFailed() async throws {
        let store = try freshStore()
        let events = Events()
        let downloader = PackDownloader(store: store, configuration: .ephemeral) { events.add($0) }
        let wanted = try await pack("small.bin", region: "BAD", sha256: String(repeating: "0", count: 64))
        downloader.start(wanted)
        #expect(await events.wait(seconds: 30) { $0.contains(.failed(wanted.id, "Checksum failed twice")) })
        #expect(events.list.filter { $0 == .started(wanted.id) }.count == 2)
        #expect(store.installedFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: wanted.id).path))
    }

    @Test func aFileDamagedOnceInstallsOnTheRetry() async throws {
        let store = try freshStore()
        let events = Events()
        let downloader = PackDownloader(store: store, configuration: .ephemeral) { events.add($0) }
        let wanted = try await pack("once/small.bin", region: "ONCE\(Int.random(in: 0..<1_000_000))")
        // A query makes the path new to the server, so its first answer is the damaged one.
        var again = wanted
        again.url = URL(string: wanted.url.absoluteString + "?run=\(UUID().uuidString)")!
        downloader.start(again)
        let id = again.id
        #expect(await events.wait(seconds: 30) { $0.contains(.installed(id)) })
        #expect(events.list.filter { $0 == .started(again.id) }.count == 2)
        #expect(try Checksum.sha256(of: store.fileURL(for: again.id)) == again.sha256)
    }

    // The server cuts the first answer short. The system session must carry on from where it stopped.
    @Test func aDroppedConnectionResumesWithARangeRequest() async throws {
        let store = try freshStore()
        let events = Events()
        let session = PackDownloader.backgroundConfiguration(identifier: "drop-check-\(UUID().uuidString)")
        let downloader = PackDownloader(store: store, configuration: session) { events.add($0) }
        var wanted = try await pack("drop/big.bin", region: "DROP")
        let run = UUID().uuidString
        wanted.url = URL(string: wanted.url.absoluteString + "?run=\(run)")!
        downloader.start(wanted)
        let id = wanted.id
        #expect(await events.wait(seconds: 50) { $0.contains(.installed(id)) })
        #expect(try Checksum.sha256(of: store.fileURL(for: wanted.id)) == wanted.sha256)
        let count = try await ManifestClient.http(
            try #require(URL(string: "ranges/big.bin?run=\(run)", relativeTo: try #require(server))))
        #expect((Int(String(decoding: count, as: UTF8.self)) ?? 0) >= 1, "the transfer restarted from zero")
    }
}

/// Two launches of the test host: the first starts a slow transfer and ends, the second finds it done.
@Suite(.enabled(if: server != nil && relaunchStep != nil)) struct RelaunchTests {
    @Test func transferOutlivesTheApp() async throws {
        let root = PackStore.standardRoot.deletingLastPathComponent().appendingPathComponent("RelaunchCheck")
        if relaunchStep == "1" { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let events = Events()
        let downloader = PackDownloader(store: store,
                                        configuration: PackDownloader.backgroundConfiguration(identifier: "relaunch-check")) {
            events.add($0)
        }
        let wanted = try await pack("slow/big.bin", region: "SLOW")
        if relaunchStep == "1" {
            downloader.start(wanted)
            let moving = await events.wait(seconds: 60) { list in
                list.contains { if case .progress(_, let value) = $0 { return value > 0.05 } else { return false } }
            }
            #expect(moving, "the transfer never started moving")
            #expect(store.installedFiles().isEmpty)
        } else {
            let end = Date().addingTimeInterval(120)
            while Date() < end, store.installedFiles().isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            #expect(store.installedFiles().map(\.pack.id) == [wanted.id])
            #expect(try Checksum.sha256(of: store.fileURL(for: wanted.id)) == wanted.sha256)
            #expect(events.list.filter { $0 == .started(wanted.id) }.isEmpty, "the second launch started it again")
        }
    }
}
