import Foundation
import Testing
@testable import FlightCore

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private let octStart = date("2026-10-01T09:01:00Z")
private let novStart = date("2026-11-26T09:01:00Z")
private let janStart = date("2027-01-21T09:01:00Z")
private let midOct = date("2026-10-15T00:00:00Z")
private let hash = String(repeating: "ab", count: 32)

private func installed(_ cycle: String, _ region: String = "TX", layer: String = "vfr",
                       sha256: String? = hash) -> InstalledPack {
    let (start, end) = cycle == "2026-10-01" ? (octStart, novStart) : (novStart, janStart)
    return InstalledPack(id: PackID(cycle: cycle, layer: layer, region: region), effective: start, expires: end,
                         sha256: sha256)
}

private func manifest() -> Manifest {
    func packs(_ cycle: String) -> [Manifest.Pack] {
        ["TX", "OK", "overview"].map {
            Manifest.Pack(layer: "vfr", region: $0, path: "charts/\(cycle)/vfr/\($0).pmtiles", bytes: 10, sha256: hash)
        }
    }
    return Manifest(version: 1, cycles: [
        .init(id: "2026-10-01", effective: octStart, expires: novStart, packs: packs("2026-10-01")),
        .init(id: "2026-11-26", effective: novStart, expires: janStart, packs: packs("2026-11-26")),
    ])
}

@Test func showsNothingWhenNothingIsInstalled() {
    #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: [], now: midOct) == nil)
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: [], transfers: [:], now: midOct) == .notDownloaded)
}

@Test func currentPackIsReady() {
    let have = [installed("2026-10-01")]
    #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: midOct) == have[0])
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: [:], now: midOct) == .ready)
}

@Test func otherLayersAndRegionsDoNotCount() {
    let have = [installed("2026-10-01", "OK"), installed("2026-10-01", "TX", layer: "ifr-low")]
    #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: midOct) == nil)
}

// A next-cycle pack does not replace the current one early, and takes over at the exact instant.
@Test func nextCyclePackWaitsForItsEffectiveInstant() {
    let have = [installed("2026-10-01"), installed("2026-11-26")]
    let before = ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: novStart.addingTimeInterval(-1))
    let at = ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: novStart)
    #expect(before?.id.cycle == "2026-10-01")
    #expect(at?.id.cycle == "2026-11-26")
}

// Nothing in effect: show what is on disk and label it as not current, never a blank map.
@Test func onlyAFutureCyclePackIsShownButNotReady() {
    let have = [installed("2026-11-26")]
    #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: midOct) == have[0])
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: [:], now: midOct) == .expired)
}

@Test func clockFarBehindStillShowsTheEarliestPack() {
    let have = [installed("2026-11-26"), installed("2026-10-01")]
    let year2001 = date("2001-01-01T00:00:00Z")
    #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: year2001)?.id.cycle == "2026-10-01")
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: [:], now: year2001) == .expired)
    #expect(ChartLibrary.packsToDelete(installed: have, now: year2001).isEmpty)
}

@Test func clockFarAheadDeletesNothing() {
    let have = [installed("2026-10-01"), installed("2026-11-26")]
    #expect(ChartLibrary.packsToDelete(installed: have, now: date("2027-06-01T00:00:00Z")).isEmpty)
}

// the old cycle has left the manifest, the pack is still on disk.
@Test func packPastItsExpiryStaysShownAndReportsExpired() {
    let have = [installed("2026-10-01")]
    let later = novStart.addingTimeInterval(3600)
    #expect(ChartLibrary.packToShow(layer: "vfr", region: "TX", installed: have, now: later) == have[0])
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: [:], now: later) == .expired)
}

@Test func expiryIsExclusiveAtTheExactInstant() {
    let have = [installed("2026-10-01")]
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: [:], now: novStart.addingTimeInterval(-1)) == .ready)
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: [:], now: novStart) == .expired)
}

@Test func readyIsNotHiddenByABackgroundFetch() {
    let have = [installed("2026-10-01")]
    let transfers = [PackID(cycle: "2026-11-26", layer: "vfr", region: "TX"): Transfer.downloading(0.4)]
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: transfers, now: midOct) == .ready)
}

@Test func downloadingShowsProgress() {
    let transfers = [PackID(cycle: "2026-10-01", layer: "vfr", region: "TX"): Transfer.downloading(0.25)]
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: [], transfers: transfers, now: midOct) == .downloading(0.25))
}

@Test func expiredPackWithReplacementInTransferShowsDownloading() {
    let have = [installed("2026-10-01")]
    let transfers = [PackID(cycle: "2026-11-26", layer: "vfr", region: "TX"): Transfer.downloading(0.6)]
    let later = novStart.addingTimeInterval(60)
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: have, transfers: transfers, now: later) == .downloading(0.6))
}

@Test func failedOnlyWhenNothingToShow() {
    let id = PackID(cycle: "2026-11-26", layer: "vfr", region: "TX")
    let transfers = [id: Transfer.failed("checksum")]
    let later = novStart.addingTimeInterval(60)
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: [], transfers: transfers, now: later) == .failed("checksum"))
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: [installed("2026-10-01")], transfers: transfers, now: later) == .expired)
}

@Test func transfersForOtherRegionsAreIgnored() {
    let transfers = [PackID(cycle: "2026-10-01", layer: "vfr", region: "OK"): Transfer.downloading(0.5)]
    #expect(ChartLibrary.state(layer: "vfr", region: "TX", installed: [], transfers: transfers, now: midOct) == .notDownloaded)
}

@Test func deletesOnlySupersededPacks() {
    let have = [installed("2026-10-01"), installed("2026-11-26"), installed("2026-10-01", "OK")]
    #expect(ChartLibrary.packsToDelete(installed: have, now: midOct).isEmpty)
    let deleted = ChartLibrary.packsToDelete(installed: have, now: novStart)
    #expect(deleted == [installed("2026-10-01")])
}

@Test func fetchesCurrentAndNextForChosenRegionsPlusOverview() {
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: manifest(), installed: [], now: midOct)
    #expect(requests.map(\.id) == [
        PackID(cycle: "2026-10-01", layer: "vfr", region: "TX"),
        PackID(cycle: "2026-10-01", layer: "vfr", region: "overview"),
        PackID(cycle: "2026-11-26", layer: "vfr", region: "TX"),
        PackID(cycle: "2026-11-26", layer: "vfr", region: "overview"),
    ])
    #expect(requests[0].path == "charts/2026-10-01/vfr/TX.pmtiles")
    #expect(requests[0].effective == octStart && requests[0].expires == novStart)
}

@Test func doesNotRefetchInstalledPacks() {
    let have = [installed("2026-10-01"), installed("2026-10-01", "overview")]
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: manifest(), installed: have, now: midOct)
    #expect(requests.map(\.id.cycle) == ["2026-11-26", "2026-11-26"])
}

@Test func refetchesARepublishedPackOrOneWithNoKnownHash() {
    let have = [installed("2026-10-01", sha256: "old"), installed("2026-10-01", "overview", sha256: nil)]
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: manifest(), installed: have, now: midOct)
    #expect(requests.filter { $0.id.cycle == "2026-10-01" }.map(\.id.region) == ["TX", "overview"])
}

@Test func fetchesOnlyOverviewWhenNoRegionChosen() {
    let requests = ChartLibrary.packsToFetch(regions: [], manifest: manifest(), installed: [], now: midOct)
    #expect(requests.allSatisfy { $0.id.region == "overview" })
    #expect(requests.count == 2)
}

@Test func doesNotFetchCyclesThatAreAlreadyOver() {
    let afterNov = novStart.addingTimeInterval(60)
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: manifest(), installed: [], now: afterNov)
    #expect(Set(requests.map(\.id.cycle)) == ["2026-11-26"])
}

// Street and terrain do not follow the chart cycle: one copy, kept until its hash changes.
private func streetManifest(_ sha: String) -> Manifest {
    var listed = manifest()
    let street = Manifest.Pack(layer: "street", region: "TX", path: "charts/base/street/TX-\(sha.prefix(16)).pmtiles",
                               bytes: 10, sha256: sha)
    for index in listed.cycles.indices { listed.cycles[index].packs.append(street) }
    return listed
}

@Test func aCycleFreePackIsFetchedOnceForBothCycles() {
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: streetManifest(hash), installed: [], now: midOct)
    #expect(requests.filter { $0.id.layer == "street" }.map(\.id.cycle) == ["2026-10-01"])
}

@Test func aNewCycleDoesNotRefetchACycleFreePackWithTheSameHash() {
    let have = [installed("2026-10-01", layer: "street")]
    let later = novStart.addingTimeInterval(60)
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: streetManifest(hash), installed: have, now: later)
    #expect(!requests.contains { $0.id.layer == "street" })
    #expect(ChartLibrary.state(layer: "street", region: "TX", installed: have, transfers: [:], now: later) == .ready)
    #expect(MapPlan.currency(layer: "street", region: "TX", installed: have, now: later) == .current)
    #expect(DownloadPolicy.nextChangeover(installed: have, now: later) == nil)
    #expect(ChartLibrary.packsToDelete(installed: have, now: later).isEmpty)
}

@Test func aCycleFreePackWithANewHashIsFetchedAndReplacesTheOldOne() {
    let have = [installed("2026-10-01", layer: "street")]
    let later = novStart.addingTimeInterval(60)
    let newer = String(repeating: "cd", count: 32)
    let requests = ChartLibrary.packsToFetch(regions: ["TX"], manifest: streetManifest(newer), installed: have, now: later)
    #expect(requests.filter { $0.id.layer == "street" }.map(\.id) == [PackID(cycle: "2026-11-26", layer: "street", region: "TX")])
    let both = have + [installed("2026-11-26", layer: "street", sha256: newer)]
    #expect(ChartLibrary.packsToDelete(installed: both, now: later) == have)
}
