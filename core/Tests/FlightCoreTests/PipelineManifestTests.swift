import Foundation
import Testing
@testable import FlightCore

// The server pipeline and the app must agree on the manifest format.
@Test func decodesAManifestBuiltByThePipeline() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("pipeline/tests/fixtures/manifest.json")
    let manifest = try Manifest.decode(Data(contentsOf: fixture))
    #expect(manifest.cycles.map(\.id) == ["2026-09-03", "2026-10-29"])
    #expect(manifest.cycles[0].packs.map(\.layer) == ["vfr", "vfr", "vfr-tac", "street"])
    #expect(manifest.cycles[0].packs[0].path == "charts/2026-09-03/vfr/TX.pmtiles")
    #expect(manifest.cycles.map { $0.packs.last?.path } == Array(repeating: "charts/base/street/TX-cdcdcdcdcdcdcdcd.pmtiles", count: 2))
    #expect(manifest.cycles[1].effective == manifest.cycles[0].expires)
}
