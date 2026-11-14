import Foundation
import Testing
@testable import FlightCore

private let hash = String(repeating: "ab", count: 32)

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func json(version: Int = 1, path: String = "charts/2026-10-01/vfr/TX.pmtiles",
                  bytes: Int = 1_048_576, sha: String = hash, region: String = "TX",
                  expires: String = "2026-11-26T09:01:00Z") -> Data {
    Data("""
    {"version": \(version), "cycles": [
      {"id": "2026-10-01", "effective": "2026-10-01T09:01:00Z", "expires": "\(expires)",
       "packs": [{"layer": "vfr", "region": "\(region)", "path": "\(path)",
                  "bytes": \(bytes), "sha256": "\(sha)"}]},
      {"id": "2026-11-26", "effective": "2026-11-26T09:01:00Z", "expires": "2027-01-21T09:01:00Z",
       "packs": []}
    ]}
    """.utf8)
}

@Test func decodesAValidManifest() throws {
    let m = try Manifest.decode(json())
    #expect(m.cycles.count == 2)
    #expect(m.cycles[0].effective == date("2026-10-01T09:01:00Z"))
    #expect(m.cycles[0].packs[0] == Manifest.Pack(layer: "vfr", region: "TX",
        path: "charts/2026-10-01/vfr/TX.pmtiles", bytes: 1_048_576, sha256: hash))
}

// a version this app does not know.
@Test func rejectsUnknownVersionWithTypedError() {
    #expect(throws: ManifestError.unsupportedVersion(2)) { try Manifest.decode(json(version: 2)) }
}

// paths become file locations on the device.
@Test(arguments: ["/etc/passwd", "charts/../../x.pmtiles", "../x", "charts//x", "charts/./x",
                  "charts/x y.pmtiles", "charts\\\\x", ""])
func rejectsUnsafePaths(path: String) {
    #expect(throws: ManifestError.self) { try Manifest.decode(json(path: path)) }
}

@Test func rejectsBadSizesHashesAndRegions() {
    #expect(throws: ManifestError.self) { try Manifest.decode(json(bytes: 0)) }
    #expect(throws: ManifestError.self) { try Manifest.decode(json(bytes: -5)) }
    #expect(throws: ManifestError.self) { try Manifest.decode(json(sha: "abc")) }
    #expect(throws: ManifestError.self) { try Manifest.decode(json(sha: String(repeating: "AB", count: 32))) }
    #expect(throws: ManifestError.self) { try Manifest.decode(json(region: "../TX")) }
    #expect(throws: ManifestError.self) { try Manifest.decode(json(region: "")) }
}

@Test func rejectsCycleThatExpiresBeforeItStarts() {
    #expect(throws: ManifestError.self) { try Manifest.decode(json(expires: "2026-09-01T09:01:00Z")) }
}

@Test func rejectsGarbage() {
    #expect(throws: (any Error).self) { try Manifest.decode(Data("not json".utf8)) }
    #expect(throws: (any Error).self) { try Manifest.decode(Data("{}".utf8)) }
}

@Test func picksCurrentAndNextCycle() throws {
    let m = try Manifest.decode(json())
    let mid = date("2026-10-15T00:00:00Z")
    #expect(m.currentCycle(at: mid)?.id == "2026-10-01")
    #expect(m.nextCycle(at: mid)?.id == "2026-11-26")
}

@Test func cycleSwitchesAtTheExactEffectiveInstant() throws {
    let m = try Manifest.decode(json())
    let instant = date("2026-11-26T09:01:00Z")
    #expect(m.currentCycle(at: instant.addingTimeInterval(-1))?.id == "2026-10-01")
    #expect(m.currentCycle(at: instant)?.id == "2026-11-26")
    #expect(m.nextCycle(at: instant) == nil)
}

@Test func noCurrentCycleBeforeTheFirstOne() throws {
    let m = try Manifest.decode(json())
    #expect(m.currentCycle(at: date("2026-01-01T00:00:00Z")) == nil)
    #expect(m.nextCycle(at: date("2026-01-01T00:00:00Z"))?.id == "2026-10-01")
}

private func pack(_ region: String, _ path: String) -> String {
    #"{"layer": "vfr", "region": "\#(region)", "path": "\#(path)", "bytes": 10, "sha256": "\#(hash)"}"#
}

private func twoCycles(firstPacks: String, secondPacks: String = "", secondEffective: String = "2026-11-26T09:01:00Z") -> Data {
    Data("""
    {"version": 1, "cycles": [
      {"id": "a", "effective": "2026-10-01T09:01:00Z", "expires": "2026-11-26T09:01:00Z", "packs": [\(firstPacks)]},
      {"id": "b", "effective": "\(secondEffective)", "expires": "2027-01-21T09:01:00Z", "packs": [\(secondPacks)]}
    ]}
    """.utf8)
}

@Test func acceptsDistinctPacks() throws {
    _ = try Manifest.decode(twoCycles(firstPacks: pack("TX", "a/TX") + "," + pack("OK", "a/OK"), secondPacks: pack("TX", "b/TX")))
}

// Two packs with one identity would race for one file on the device.
@Test func rejectsDuplicatePackInOneCycle() {
    #expect(throws: ManifestError.self) {
        try Manifest.decode(twoCycles(firstPacks: pack("TX", "a/TX") + "," + pack("TX", "a/TX2")))
    }
}

@Test func rejectsTwoPacksSharingAPath() {
    #expect(throws: ManifestError.self) {
        try Manifest.decode(twoCycles(firstPacks: pack("TX", "a/TX"), secondPacks: pack("TX", "a/TX")))
    }
}

private func withBase(_ base: String, firstPacks: String = "") -> Data {
    Data("""
    {"version": 1, "cycles": [
      {"id": "a", "effective": "2026-10-01T09:01:00Z", "expires": "2026-11-26T09:01:00Z", "packs": [\(firstPacks)]},
      {"id": "b", "effective": "2026-11-26T09:01:00Z", "expires": "2027-01-21T09:01:00Z", "packs": []}
    ], "base": [\(base)]}
    """.utf8)
}

private func street(_ path: String) -> String {
    #"{"layer": "street", "region": "TX", "path": "\#(path)", "bytes": 10, "sha256": "\#(hash)", "version": "1"}"#
}

// Base packs are listed once and offered by every cycle, in place of a cycle's own copy.
@Test func everyCycleOffersTheBasePacks() throws {
    let firstPacks = pack("TX", "a/TX") + "," + street("a/street/TX")
    let m = try Manifest.decode(withBase(street("charts/base/street/TX-ab.pmtiles"), firstPacks: firstPacks))
    #expect(m.cycles.map { $0.packs.map(\.path) } == [["a/TX", "charts/base/street/TX-ab.pmtiles"],
                                                       ["charts/base/street/TX-ab.pmtiles"]])
}

@Test func rejectsABasePackThatIsBadOrSharesAPath() {
    #expect(throws: ManifestError.self) { try Manifest.decode(withBase(street("../x"))) }
    #expect(throws: ManifestError.self) { try Manifest.decode(withBase(street("x") + "," + street("y"))) }
    #expect(throws: ManifestError.self) { try Manifest.decode(withBase(street("a/TX"), firstPacks: pack("TX", "a/TX"))) }
}

@Test func rejectsTwoCyclesWithTheSameEffectiveTime() {
    #expect(throws: ManifestError.self) {
        try Manifest.decode(twoCycles(firstPacks: "", secondEffective: "2026-10-01T09:01:00Z"))
    }
}
