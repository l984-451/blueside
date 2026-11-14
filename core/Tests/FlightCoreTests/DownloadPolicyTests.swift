import Foundation
import Testing
@testable import FlightCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func request(_ region: String, _ bytes: Int) -> PackRequest {
    PackRequest(id: PackID(cycle: "c1", layer: "vfr", region: region), path: "\(region).pmtiles", bytes: bytes,
                sha256: "x", effective: t0, expires: t0 + 86400)
}

@Suite struct DownloadPolicyTests {
    // Linux ByteCountFormatter words sizes differently.
    #if canImport(Darwin)
    // The system's file style is the reference; the core must write what the app wrote before.
    @Test func sizesMatchTheSystemFileStyle() {
        var generator = SystemRandomNumberGenerator()
        let fixed: [Int64] = [0, 1, 2, 999, 1000, 1499, 1500, 2500, 999_499, 999_500, 1_049_999, 1_050_000, 1_250_000,
                              100_000_000, 999_949_999, 999_950_000, 1_225_000_000, 12_345_678_901, 1_500_000_000_000,
                              -5, -1_500_000, 400, 401]
        let random = (0..<20000).map { _ in
            Int64.random(in: 0...Int64(10).power(Int.random(in: 1...14, using: &generator)), using: &generator)
        }
        for bytes in fixed + random {
            #expect(DownloadPolicy.byteCount(bytes) == ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                    "\(bytes)")
        }
    }
    #endif

    @Test func aChecksumFailureIsFetchedOnceMoreThenHeldSixHours() {
        #expect(DownloadPolicy.retriesChecksum(attempt: 1))
        #expect(!DownloadPolicy.retriesChecksum(attempt: 2))
        let held = PackID(cycle: "c1", layer: "vfr", region: "TX")
        let other = PackID(cycle: "c1", layer: "vfr", region: ChartLibrary.overviewRegion)
        let hidden = PackID(cycle: "c1", layer: "vfr", region: "OK")
        let transfers: [PackID: Transfer] = [held: .failed(DownloadPolicy.checksumFailure), other: .failed("Server answered 500"),
                                             hidden: .failed("x")]
        let installed = [InstalledPack(id: PackID(cycle: "c0", layer: "vfr", region: "TX"), effective: t0, expires: t0),
                         InstalledPack(id: PackID(cycle: "c0", layer: "vfr", region: "OK"), effective: t0, expires: t0)]
        let soon = DownloadPolicy.failuresToRetry(transfers: transfers, installed: installed, heldSince: [held: t0],
                                                  now: t0 + 3600)
        #expect(Set(soon) == [other, hidden])
        let later = DownloadPolicy.failuresToRetry(transfers: transfers, installed: installed, heldSince: [held: t0],
                                                   now: t0 + 6 * 3600)
        #expect(Set(later) == [held, other, hidden])
        // A chosen region with nothing installed keeps its Retry button, so a refresh leaves it.
        #expect(DownloadPolicy.failuresToRetry(transfers: transfers, installed: [], heldSince: [:], now: t0) == [other])
        #expect(DownloadPolicy.holds(DownloadPolicy.unreadableFailure))
        #expect(!DownloadPolicy.holds("Server answered 500"))
    }

    @Test func aPassStartsWhatFitsBesideRunningTransfersAndFailsTheRest() {
        let free = DownloadPolicy.spaceMargin + 1_000_000
        let steps = DownloadPolicy.pass(wanted: [request("TX", 600_000), request("OK", 600_000), request("NM", 100_000)],
                                        transfers: [:], committed: 200_000, freeBytes: free)
        #expect(steps == [.start(request("TX", 600_000)),
                          .fail(request("OK", 0).id, "Not enough storage for OK vfr: needs 1.4 MB, 1 MB free"),
                          .start(request("NM", 100_000))])
        // One already under way is left alone.
        #expect(DownloadPolicy.pass(wanted: [request("TX", 1)], transfers: [request("TX", 1).id: .downloading(0.5)],
                                    committed: 0, freeBytes: free).isEmpty)
        #expect(DownloadPolicy.shortfall(needed: 400, freeBytes: DownloadPolicy.spaceMargin + 400) == nil)
        #expect(DownloadPolicy.shortfall(needed: 401, freeBytes: DownloadPolicy.spaceMargin + 400)! == (401, 400))
    }

    @Test func theCycleSwitchWakesOneSecondAfterTheNextChangeover() {
        let pack = InstalledPack(id: PackID(cycle: "c1", layer: "vfr", region: "TX"), effective: t0, expires: t0 + 100)
        #expect(DownloadPolicy.switchDelay(installed: [pack], now: t0 - 10) == 11)
        #expect(DownloadPolicy.switchDelay(installed: [pack], now: t0 + 50) == 51)
        #expect(DownloadPolicy.switchDelay(installed: [pack], now: t0 + 100) == nil)
    }

    @Test func navigationTilesGoOnlyOnceALaterDatabaseIsInUse() {
        func pack(_ cycle: String, _ layer: String, _ start: Date) -> InstalledPack {
            InstalledPack(id: PackID(cycle: cycle, layer: layer, region: "US"), effective: start, expires: start + 28 * 86400)
        }
        let old = [pack("c1", "nav-db", t0), pack("c1", "nav-tiles", t0)]
        let new = [pack("c2", "nav-db", t0 + 28 * 86400), pack("c2", "nav-tiles", t0 + 28 * 86400)]
        #expect(DownloadPolicy.superseded(installed: old + new, now: t0 + 86400).isEmpty)
        #expect(Set(DownloadPolicy.superseded(installed: old + new, now: t0 + 29 * 86400).map(\.id.cycle)) == ["c1"])
    }
}

private extension Int64 {
    func power(_ exponent: Int) -> Int64 { (0..<exponent).reduce(1) { value, _ in value * self } }
}

@Test func nextCycleWaitsForTheCurrentOneOfTheSameLayerAndRegion() {
    let oct = Date(timeIntervalSince1970: 1_790_000_000), nov = oct.addingTimeInterval(28 * 86400)
    func request(_ cycle: String, _ layer: String, _ effective: Date) -> PackRequest {
        PackRequest(id: PackID(cycle: cycle, layer: layer, region: "US"), path: "", bytes: 1, sha256: "",
                    effective: effective, expires: effective.addingTimeInterval(28 * 86400))
    }
    let wanted = [request("10-01", "nav-db", oct), request("10-29", "nav-db", nov), request("10-29", "nav-tiles", nov)]
    let started = DownloadPolicy.currentFirst(wanted, installed: [], now: oct.addingTimeInterval(60))
    #expect(started.map(\.id.cycle) == ["10-01", "10-29"])
    #expect(started.map(\.id.layer) == ["nav-db", "nav-tiles"])
}

@Test func aRefetchOfAPackInEffectDoesNotHoldBackTheNextCycle() {
    let oct = Date(timeIntervalSince1970: 1_790_000_000), nov = oct.addingTimeInterval(28 * 86400)
    let id = PackID(cycle: "10-01", layer: "vfr", region: "TX")
    let wanted = [PackRequest(id: id, path: "", bytes: 1, sha256: "b", effective: oct, expires: nov),
                  PackRequest(id: PackID(cycle: "10-29", layer: "vfr", region: "TX"), path: "", bytes: 1, sha256: "",
                              effective: nov, expires: nov.addingTimeInterval(28 * 86400))]
    let have = [InstalledPack(id: id, effective: oct, expires: nov, sha256: "a")]
    #expect(DownloadPolicy.currentFirst(wanted, installed: have, now: oct.addingTimeInterval(60)).count == 2)
}
