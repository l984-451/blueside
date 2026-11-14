import FlightCore
import Foundation
import Testing
@testable import Blueside

@MainActor @Suite struct PackCoverageTests {
    // The bundled chart holds zooms 5 to 12 over a small box around DFW.
    private let pack = Bundle.main.url(forResource: "test-vfr", withExtension: "pmtiles", subdirectory: "MapAssets")!
    private let coverage = PackCoverage()

    @Test func tileNumbersFollowTheFileFormat() {
        #expect(PackCoverage.tileID(zoom: 0, latitude: 0, longitude: 0) == 0)
        // Zoom 1 runs north-west, south-west, south-east, north-east.
        #expect(PackCoverage.tileID(zoom: 1, latitude: 45, longitude: -90) == 1)
        #expect(PackCoverage.tileID(zoom: 1, latitude: -45, longitude: -90) == 2)
        #expect(PackCoverage.tileID(zoom: 1, latitude: -45, longitude: 90) == 3)
        #expect(PackCoverage.tileID(zoom: 1, latitude: 45, longitude: 90) == 4)
        #expect(PackCoverage.tileID(zoom: 2, latitude: 80, longitude: -170) == 5)
        // The poles are past the edge of the projection and must not stop the app.
        #expect(PackCoverage.tileID(zoom: 3, latitude: 90, longitude: 180)
            == PackCoverage.tileID(zoom: 3, latitude: 86, longitude: 179.9))
    }

    @Test func pointInsideThePackIsCovered() {
        #expect(coverage.covers([pack], latitude: 32.8968, longitude: -97.0380, zoom: 10))
        // Deeper than the pack's last zoom, the map stretches that last zoom.
        #expect(coverage.covers([pack], latitude: 32.8968, longitude: -97.0380, zoom: 15))
    }

    @Test func pointOutsideEveryPackIsNotCovered() {
        #expect(!coverage.covers([pack], latitude: 40.0, longitude: -75.0, zoom: 10))
        #expect(!coverage.covers([pack], latitude: 0, longitude: 0, zoom: 10))
        #expect(!coverage.covers([], latitude: 32.8968, longitude: -97.0380, zoom: 10))
    }

    // West of the pack only its two widest zooms have a tile, and those are empty there.
    @Test func wideTileOverAPointTheDetailedZoomsLackIsNotCoverage() {
        #expect(!coverage.covers([pack], latitude: 35.0, longitude: -100.0, zoom: 10))
        #expect(coverage.covers([pack], latitude: 35.0, longitude: -100.0, zoom: 5))
    }

    @Test func oneCoveringPackIsEnough() {
        // The terminal chart holds zoom 13 only, so on its own it draws nothing at this camera zoom.
        let close = Bundle.main.url(forResource: "test-vfr-tac", withExtension: "pmtiles", subdirectory: "MapAssets")!
        #expect(!coverage.covers([close], latitude: 32.8968, longitude: -97.0380, zoom: 10))
        #expect(coverage.covers([close, pack], latitude: 32.8968, longitude: -97.0380, zoom: 10))
        #expect(coverage.covers([close], latitude: 32.8968, longitude: -97.0380, zoom: 12))
    }

    // The map draws nothing from a pack while the camera is wider than the pack's first zoom.
    @Test func cameraWiderThanThePacksFirstZoomIsNotCovered() {
        #expect(coverage.covers([pack], latitude: 32.8968, longitude: -97.0380, zoom: 4))
        #expect(!coverage.covers([pack], latitude: 32.8968, longitude: -97.0380, zoom: 3.4))
    }

    // A wide-area pack may fill in one zoom past its last. Stretched further it is a smear, not a chart.
    @Test func limitedPackStopsCountingOnceStretchedPastOneZoom() {
        #expect(coverage.covers([pack], limited: [pack], latitude: 32.8968, longitude: -97.0380, zoom: 12))
        #expect(!coverage.covers([pack], limited: [pack], latitude: 32.8968, longitude: -97.0380, zoom: 13))
        #expect(coverage.covers([pack], latitude: 32.8968, longitude: -97.0380, zoom: 15))
    }

    @Test func gapTellsNoChartFromNoDetailedChart() {
        #expect(coverage.gap([pack], overviews: [pack], latitude: 32.8968, longitude: -97.0380, zoom: 10) == nil)
        #expect(coverage.gap([pack], overviews: [pack], latitude: 32.8968, longitude: -97.0380, zoom: 14) == .detail)
        #expect(coverage.gap([pack], overviews: [], latitude: 32.8968, longitude: -97.0380, zoom: 14) == nil)
        #expect(coverage.gap([pack], overviews: [pack], latitude: 40.0, longitude: -75.0, zoom: 14) == .chart)
    }

    @Test func fileThatIsNotAPackIsNotCovered() {
        let other = Bundle.main.url(forResource: "empty", withExtension: "json", subdirectory: "MapAssets")!
        #expect(!coverage.covers([other], latitude: 32.8968, longitude: -97.0380, zoom: 10))
        #expect(!coverage.covers([URL(fileURLWithPath: "/nowhere.pmtiles")], latitude: 32.9, longitude: -97, zoom: 10))
    }
}
